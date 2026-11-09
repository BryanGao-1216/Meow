import Foundation
import KokosukiCloud
#if canImport(MLXLLM)
import MLX
import MLXLLM
import MLXLMCommon
#endif

/// The pet's mind: uses a bundled MLX model or a configured cloud service for
/// structured, state-aware replies. All callbacks are delivered on the main actor.
final class Brain: @unchecked Sendable {

    @MainActor private final class StreamProgress {
        var announcedEmotion = false
        var text = ""
    }

    struct Message: Codable {
        var role: String   // "user" | "assistant"
        var text: String
        var date: Date
        var sourceURL: URL? = nil
    }

    #if canImport(MLXLLM)
    private var container: ModelContainer?
    #endif
    @MainActor private var cloudConfiguration: ArkConfiguration?
    @MainActor private var ready = false
    @MainActor private var loading: Task<Void, Never>?
    @MainActor private var loadEpoch = 0
    @MainActor private(set) var lastError: String?
    private(set) var history: [Message] = []
    private let historyURL: URL
    private var generation: Task<Void, Never>?
    private var epoch = 0   // stale-generation guard: callbacks from cancelled runs are dropped
    @MainActor let memory: PetMemory
    @MainActor var onHistoryReset: (() -> Void)?
    @MainActor var newsContext: ((String) -> String)?
    @MainActor var toolContext: ((String) -> String)?

    @MainActor var onStateChange: ((BrainState) -> Void)?

    /// `loadPersistedHistory: false` gives an isolated brain (selftest) that neither
    /// reads nor pollutes the user's real conversation history.
    private let persistHistory: Bool

    @MainActor init(loadPersistedHistory: Bool = true) {
        memory = PetMemory(persistent: loadPersistedHistory)
        persistHistory = loadPersistedHistory
        let dir = Persistence.supportDir
        historyURL = dir.appendingPathComponent("chat-history.json")
        if loadPersistedHistory,
            let data = try? Data(contentsOf: historyURL),
            let saved = try? JSONDecoder().decode([Message].self, from: data)
        {
            history = saved
        }
        memory.onForget = { [weak self] in self?.clearHistory() }
        memory.migrate(history)
    }

    // MARK: - Loading

    static func locateModelDir() -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("model"))
        }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("model"))
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("model"))
        return candidates.first {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("model.safetensors").path)
        }
    }

    @MainActor
    func load() {
        cancelGeneration()
        loading?.cancel()
        loadEpoch += 1
        let thisLoad = loadEpoch
        ready = false
        cloudConfiguration = nil
        lastError = nil
        #if canImport(MLXLLM)
        container = nil
        #endif
        onStateChange?(.loading)
        let settings = AppSettings.shared
        if settings.brainProvider == .volcengine {
            do {
                let configuration = ArkConfiguration(
                    baseURL: settings.cloudBaseURL, model: settings.cloudModel,
                    apiKey: try APIKeyStore.load())
                _ = try configuration.endpoint()
                cloudConfiguration = configuration
                ready = true
                onStateChange?(.ready)
            } catch {
                lastError = error.localizedDescription
                onStateChange?(.failed(error.localizedDescription))
            }
            return
        }
        #if canImport(MLXLLM)
        loading = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                guard let dir = Brain.locateModelDir() else {
                    throw NSError(domain: "Kokosuki", code: 1, userInfo: [NSLocalizedDescriptionKey: "model directory not found"])
                }
                // keep MLX's buffer cache small; a desktop pet should stay lightweight
                MLX.GPU.set(cacheLimit: 128 * 1024 * 1024)
                replacementTokenizers["TokenizersBackend"] = "PreTrainedTokenizer"
                let config = ModelConfiguration(
                    directory: dir, overrideTokenizer: "PreTrainedTokenizer",
                    extraEOSTokens: ["<|im_end|>"])
                let container = try await LLMModelFactory.shared.loadContainer(configuration: config)

                // Warm up: tiny generation compiles the JIT metal kernels now,
                // so the first real reply isn't slow.
                try await container.perform { context in
                    let tokens = context.tokenizer.encode(text: "<|im_start|>user\n你好<|im_end|>\n<|im_start|>assistant\n")
                    let input = LMInput(tokens: MLXArray(tokens))
                    let params = GenerateParameters(maxTokens: 2, temperature: 0.7)
                    let stream = try MLXLMCommon.generate(input: input, parameters: params, context: context)
                    for await _ in stream {}
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.loadEpoch == thisLoad else { return }
                    self.container = container
                    self.ready = true
                    self.onStateChange?(.ready)
                }
            } catch {
                let msg = "\(error)"
                await MainActor.run {
                    guard self.loadEpoch == thisLoad else { return }
                    self.lastError = msg
                    self.onStateChange?(.failed(msg))
                }
            }
        }
        #else
        lastError = L10n.t("settings.localUnavailable")
        onStateChange?(.failed(lastError!))
        #endif
    }

    @MainActor var isReady: Bool { ready }
    var isGenerating: Bool { generation != nil }

    /// 独立的选题/写稿调用，不改变聊天生成状态，也不把外部新闻学习为主人事实。
    @MainActor func newsCompletion(system: String, input: String) async throws -> String? {
        try await featureCompletion(system: system, input: input, maxTokens: 450, maxCharacters: 1200)
    }

    /// 功能模块的结构化请求；不进入聊天历史或长期记忆，复用已加载的云端配置。
    @MainActor func featureCompletion(system: String, input: String, maxTokens: Int = 1600, maxCharacters: Int = 9000) async throws -> String? {
        guard ready, let configuration = cloudConfiguration else { return nil }
        return try await ArkClient(configuration: configuration).generate(
            messages: [ArkMessage(role: "system", content: system), ArkMessage(role: "user", content: input)],
            thinking: false, maxTokens: maxTokens, maxCharacters: maxCharacters, onText: { _ in })
    }

    // MARK: - Prompt assembly (manual ChatML; empty think block = fast non-thinking mode)

    /// Manual ChatML. Fast mode closes the think block empty and prefills "[" so
    /// the reply is forced to start with an emotion tag. Thinking mode opens a
    /// real `<think>` block — the model reasons first (never shown), then answers.
    private func buildPrompt(system: String, turns: [Message], user: String, thinking: Bool) -> String {
        var p = "<|im_start|>system\n\(system)<|im_end|>\n"
        for m in turns {
            p += "<|im_start|>\(m.role)\n\(m.text)<|im_end|>\n"
        }
        p += "<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        p += thinking ? "<think>\n" : "<think>\n\n</think>\n\n["
        return p
    }

    // MARK: - Generation

    /// Stream a reply. `recordHistory` false for spontaneous chatter/events so canned
    /// context lines don't pollute the visible chat log (they still get persona context).
    /// Callbacks: `onEmotion` fires as soon as the leading tag parses; `onText` receives
    /// the running de-tagged text; `onDone` the final parse (nil text on cancel/error).
    @MainActor
    func generate(
        userContent: String,
        context ctx: PetContext,
        recordHistory: Bool,
        historyUserText: String? = nil,
        commandHint: String? = nil,
        creative: (kind: Persona.CreativeKind, fallback: String)? = nil,
        thinking: Bool = false,
        onEmotion: @escaping @MainActor (Emotion) -> Void,
        onText: @escaping @MainActor (String) -> Void,
        onDone: @escaping @MainActor (Persona.ParsedReply?) -> Void
    ) {
        guard ready else {
            onDone(nil)
            return
        }
        let cloudConfiguration = self.cloudConfiguration
        #if canImport(MLXLLM)
        let container = self.container
        #endif
        lastError = nil
        generation?.cancel()
        epoch += 1
        let myEpoch = epoch
        let longform = creative != nil
        let source = historyUserText ?? userContent
        let sourceDate = Date()
        if recordHistory {
            let previous = history.last { $0.role == "user" }
            memory.observe(source, at: sourceDate,
                           previousUserMessage: PetMemory.birthdayContext(previous, at: sourceDate))
        }

        var system = Persona.system(ctx)
        system += "\n\n" + memory.context(for: userContent)
        if recordHistory, let news = newsContext?(userContent), !news.isEmpty { system += "\n\n" + news }
        if recordHistory, let tools = toolContext?(userContent), !tools.isEmpty { system += "\n\n" + tools }
        if longform { system += "\n\n" + Persona.creativeExample() }
        // window balances multi-turn coherence against bad-habit contamination, and
        // 只取中文历史，避免旧的其他语言回复影响当前人设
        let turns = Array(
            history.suffix(18)
                .filter { $0.role == "user" || Persona.isChineseReply($0.text) }
                .suffix(10))
        var wrapped = userContent
        if let commandHint { wrapped += "\n" + commandHint }
        wrapped += "\n" + Persona.reminder()
        // pass 1 honors the thinking preference; retries always drop to fast mode
        // (reliable format beats a second slow think)
        let prompt = buildPrompt(system: system, turns: turns, user: wrapped, thinking: thinking)
        let fastPrompt = thinking
            ? buildPrompt(system: system, turns: turns, user: wrapped, thinking: false)
            : prompt
        // for verbatim-repeat retries: fast prompt plus an explicit variation nudge
        let nudgedPrompt = buildPrompt(
            system: system, turns: turns,
            user: wrapped + "\n" + Persona.repeatNudge(), thinking: false)
        let recentReplies = history.suffix(8).filter { $0.role == "assistant" }.map(\.text)

        generation = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // One streamed sampling pass; returns the raw accumulated text.
            // In thinking mode nothing is emitted until `</think>` closes — the UI
            // keeps its "thinking…" state; only the answer part ever streams out.
            func onePass(temperature: Float, prompt: String, thinks: Bool, varied: Bool = false) async throws -> String {
                if let cloudConfiguration {
                    let progress = await MainActor.run { StreamProgress() }
                    let messages = [ArkMessage(role: "system", content: system)]
                        + turns.map { ArkMessage(role: $0.role, content: $0.text) }
                        + [ArkMessage(role: "user", content: wrapped + (varied ? "\n" + Persona.repeatNudge() : ""))]
                    return try await ArkClient(configuration: cloudConfiguration).generate(
                        messages: messages, thinking: thinks,
                        maxTokens: thinks ? 4096 : (longform ? 768 : 256),
                        maxCharacters: longform ? 560 : 200,
                        onText: { raw in
                            await MainActor.run {
                                guard self.epoch == myEpoch else { return }
                                // Parsing strips inline thinking, emotion/action tags,
                                // and caps the bubble. Hide incomplete trailing tags too.
                                var partial = raw
                                if let start = partial.lastIndex(of: "["), !partial[start...].contains("]") {
                                    partial = String(partial[..<start])
                                }
                                let parsed = Persona.parse(partial, longform: longform)
                                if !progress.announcedEmotion, let emotion = parsed.emotion {
                                    progress.announcedEmotion = true
                                    onEmotion(emotion)
                                }
                                if !parsed.text.isEmpty, parsed.text != progress.text {
                                    progress.text = parsed.text
                                    onText(parsed.text)
                                }
                            }
                        })
                }
                #if canImport(MLXLLM)
                guard let container else { throw ArkError.invalidResponse }
                var raw = thinks ? "" : "["   // fast mode mirrors the prefilled tag opener
                var answer = ""               // the post-think (visible) portion
                var thinkDone = !thinks
                var announcedEmotion = false
                var emittedLen = 0
                try await container.perform { context in
                    let tokens = context.tokenizer.encode(text: prompt)
                    let input = LMInput(tokens: MLXArray(tokens))
                    let params = GenerateParameters(
                        maxTokens: thinks ? (longform ? 640 : 448) : (longform ? 280 : 90),
                        temperature: temperature, topP: 0.85,
                        repetitionPenalty: 1.12, repetitionContextSize: 60)
                    let stream = try MLXLMCommon.generate(input: input, parameters: params, context: context)
                    let answerCap = longform ? 560 : 200
                    for await item in stream {
                        if Task.isCancelled { break }
                        if case .chunk(let piece) = item {
                            raw += piece
                            if !thinkDone {
                                if let r = raw.range(of: "</think>") {
                                    thinkDone = true
                                    answer = String(raw[r.upperBound...])
                                } else if raw.count > 2400 {
                                    break  // runaway thinker — bail, retry will go fast
                                } else {
                                    continue
                                }
                            } else {
                                answer = thinks ? answer + piece : raw
                            }
                            if answer.count > answerCap { break }  // pet-sized replies only
                            if !announcedEmotion, let (emo, _) = Persona.earlyTag(from: answer) {
                                announcedEmotion = true
                                if let emo {
                                    await MainActor.run {
                                        if self.epoch == myEpoch { onEmotion(emo) }
                                    }
                                }
                            }
                            // stream the de-tagged running text (flattened + capped so
                            // the bubble can never balloon mid-stream)
                            if announcedEmotion || answer.count > 6 {
                                var visible = answer
                                if let (_, rest) = Persona.earlyTag(from: answer) { visible = rest }
                                visible = visible
                                    .replacingOccurrences(of: "[", with: " ")
                                    .replacingOccurrences(of: "]", with: " ")
                                    .replacingOccurrences(of: "\n", with: " ")
                                while visible.contains("  ") {
                                    visible = visible.replacingOccurrences(of: "  ", with: " ")
                                }
                                let streamCap = longform ? 420 : 150
                                if visible.count > streamCap { visible = String(visible.prefix(streamCap)) + "…" }
                                if visible.count > emittedLen {
                                    emittedLen = visible.count
                                    let v = visible.trimmingCharacters(in: .whitespaces)
                                    await MainActor.run {
                                        if self.epoch == myEpoch { onText(v) }
                                    }
                                }
                            }
                        }
                    }
                }
                // a think block that never closed produced no usable answer
                if thinks && !raw.contains("</think>") { return "" }
                return raw
                #else
                throw ArkError.invalidResponse
                #endif
            }

            // Rejection sampling: a coherent first pass at low temperature; if it's
            // empty, off-language, a parrot-echo, or assistant-speak, resample once
            // hotter and keep the better of the two.
            func issue(_ p: Persona.ParsedReply) -> String? {
                if p.text.isEmpty { return "empty" }
                // echo reference covers everything we injected: command hint,
                // reminder, and the status block (reciting one's stat sheet is weird)
                let injected = [commandHint, Persona.reminder(), Persona.statusLine(ctx)]
                    .compactMap { $0 }.joined(separator: "\n")
                return Persona.qualityIssue(
                    reply: p.text, user: userContent,
                    creativeKind: creative?.kind, hint: injected,
                    recentReplies: recentReplies)
            }
            var parsed: Persona.ParsedReply?
            var generationError: String?
            do {
                let first = Persona.parse(
                    try await onePass(temperature: longform ? 0.7 : 0.5, prompt: prompt, thinks: thinking),
                    longform: longform)
                let firstIssue = issue(first)
                if firstIssue == nil || Task.isCancelled {
                    parsed = first
                } else {
                    // repeats get an explicit "say it differently" nudge; all retries
                    // run in fast (non-thinking) mode for reliability
                    let retryPrompt = firstIssue == "verbatim repeat" ? nudgedPrompt : fastPrompt
                    let second = Persona.parse(
                        try await onePass(temperature: 0.9, prompt: retryPrompt, thinks: false,
                                          varied: firstIssue == "verbatim repeat"),
                        longform: longform)
                    if issue(second) == nil {
                        parsed = second
                    } else if first.text.isEmpty {
                        parsed = second   // anything beats silence
                    } else if second.text.isEmpty {
                        parsed = first
                    } else {
                        // both flawed: prefer the one in the right language
                        parsed = Persona.isChineseReply(second.text) && !Persona.isChineseReply(first.text)
                            ? second : first
                    }
                    if var p = parsed {
                        p.qualityFlag = issue(p)
                        parsed = p
                    }
                }
            } catch {
                parsed = nil
                if !Task.isCancelled { generationError = error.localizedDescription }
            }

            let cancelled = Task.isCancelled
            var result = parsed
            // creative ask that the model fumbled twice: deliver curated content
            // instead, and record IT in history so follow-up turns stay coherent
            if !cancelled, generationError == nil, let creative,
                result == nil || result!.text.isEmpty || result!.qualityFlag != nil
            {
                result = Persona.ParsedReply(
                    emotion: result?.emotion ?? .playful, action: nil, text: creative.fallback)
            }
            // simple arithmetic the model kept fumbling: answer deterministically
            if !cancelled, result?.qualityFlag == "math unanswered",
                let ans = Persona.arithmeticResult(in: userContent)
            {
                result = Persona.ParsedReply(
                    emotion: .proud, action: nil, text: Persona.mathFallback(ans))
            }
            let final = result
            let finalError = generationError
            await MainActor.run {
                // a newer generation superseded us — vanish silently
                guard self.epoch == myEpoch else { return }
                self.generation = nil
                self.lastError = finalError
                guard let result = final, !cancelled, !result.text.isEmpty else {
                    onDone(cancelled ? nil : final)
                    return
                }
                if recordHistory {
                    self.history.append(Message(role: "user", text: historyUserText ?? userContent, date: .now))
                    self.history.append(Message(role: "assistant", text: result.text, date: .now))
                    self.trimAndSaveHistory()
                    if let cloudConfiguration {
                        self.memory.consolidate(source, at: sourceDate, configuration: cloudConfiguration)
                    }
                }
                onDone(result)
            }
        }
    }

    @MainActor
    func cancelGeneration() {
        let previous = generation
        generation = nil
        epoch += 1
        previous?.cancel()
    }

    // MARK: - History

    private func trimAndSaveHistory() {
        if history.count > 60 { history.removeFirst(history.count - 60) }
        guard persistHistory else { return }
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }

    @MainActor
    @discardableResult
    func clearHistory() -> String? {
        cancelGeneration()
        history.removeAll()
        var errorMessage: String?
        if persistHistory, FileManager.default.fileExists(atPath: historyURL.path) {
            do { try FileManager.default.removeItem(at: historyURL) }
            catch { errorMessage = "旧聊天文件未清除：\(error.localizedDescription)" }
        }
        onHistoryReset?()
        return errorMessage
    }

    /// Record a line the pet said on its own (spontaneous chatter, canned or LLM),
    /// so later chat turns remember it was said.
    @MainActor
    func noteAssistantLine(_ text: String, sourceURL: URL? = nil) {
        guard !text.isEmpty else { return }
        history.append(Message(role: "assistant", text: text, date: .now, sourceURL: sourceURL))
        trimAndSaveHistory()
    }
}
