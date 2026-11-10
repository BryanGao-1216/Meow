import Foundation

/// Headless validation: command detection, output sanitizing, and a batched
/// 中文模型质量检查（`--selftest [rounds]`）。
@MainActor
enum SelfTest {

    static func run() {
        let rounds = CommandLine.arguments
            .drop(while: { $0 != "--selftest" }).dropFirst().first.flatMap { Int($0) } ?? 2

        var unitFails = 0
        unitFails += runDetectionCases()
        unitFails += runSanitizerCases()
        unitFails += runChineseContentCases()
        unitFails += CredentialSelfTest.run()
        unitFails += ActionSelfTest.run()
        unitFails += WallSelfTest.run()
        unitFails += WallHoverSelfTest.run()
        if unitFails > 0 {
            print("selftest FAILED: \(unitFails) unit failures")
            exit(1)
        }

        if CommandLine.arguments.contains("--unit-only") {
            Task { @MainActor in
                let failures = await MemorySelfTest.run()
                let newsFailures = await NewsSelfTest.run()
                let memoFailures = await MemoSelfTest.run()
                let mailboxFailures = await MailboxSelfTest.run()
                print("中文逻辑、动作、贴墙、记忆、热点、备忘录与信箱自检完成；信箱使用本机回环连接，未向公网或模型发送请求。")
                exit(failures + newsFailures + memoFailures + mailboxFailures == 0 ? 0 : 1)
            }
            return
        }

        let brain = Brain(loadPersistedHistory: false)   // isolate from the user's real chats
        print("selftest: loading model… (batch rounds: \(rounds))")
        brain.onStateChange = { state in
            switch state {
            case .ready:
                Task { @MainActor in await runBatch(brain, rounds: rounds) }
            case .failed(let msg):
                print("selftest FAILED: brain load error: \(msg)")
                exit(1)
            default: break
            }
        }
        brain.load()
    }

    // MARK: - Unit: command detection

    private static func runDetectionCases() -> Int {
        let cases: [(String, PetAction?)] = [
            ("跳个舞吧!", .dance), ("快过来!", .come), ("去睡觉吧", .sleep),
            ("别睡了快起床!", .wake), ("跳上窗口去", .climb), ("下来啦", .down),
            ("转个圈看看", .spin), ("陪我玩一会", .play), ("吃鱼鱼吗?", .eat),
            ("别闹了停下", .stop), ("跳一下试试", .jump), ("今天天气真好", nil),
            ("散个步吧，去散步", .walk), ("伸个懒腰", .stretch),
        ]
        var fails = 0
        for (text, expected) in cases {
            let got = Persona.detectCommand(text)
            if got != expected {
                print("detect FAIL: \"\(text)\" → \(got.map(\.rawValue) ?? "nil") (expected \(expected.map(\.rawValue) ?? "nil"))")
                fails += 1
            }
        }
        print("command detection: \(cases.count - fails)/\(cases.count) OK")
        return fails
    }

    // MARK: - Unit: sanitizer

    private static func runSanitizerCases() -> Int {
        // (raw model output, substrings that must NOT survive, substring that must survive)
        let cases: [(String, [String], String)] = [
            ("[happy] 40字以内 你好呀主人!", ["40字以内"], "你好呀主人"),
            ("[calm] (用中文短句回复) 我在晒太阳~", ["短句", "("], "晒太阳"),
            ("[love] 你: 蹭蹭你喵~", ["你:"], "蹭蹭你喵"),
            ("[playful] 「一起玩吧!」", ["「"], "一起玩吧"),
            ("[proud] 示例\n看我跳得多高!", ["示例"], "跳得多高"),
            ("[happy] 好呀!(悄悄溜走)", ["悄悄", "("], "好呀"),
            ("[love] *蹭蹭* 最喜欢主人了", ["*", "蹭蹭"], "最喜欢主人了"),
        ]
        var fails = 0
        for (raw, banned, kept) in cases {
            let out = Persona.parse(raw).text
            for b in banned where out.contains(b) {
                print("sanitize FAIL: \"\(b)\" survived in \"\(out)\"")
                fails += 1
            }
            if !out.contains(kept) {
                print("sanitize FAIL: lost content \"\(kept)\" in \"\(out)\"")
                fails += 1
            }
        }
        // think blocks: tags inside reasoning must not leak; unclosed think = empty
        let thought = Persona.parse("<think>这里可能要用[sad]情绪</think>\n\n[happy] 你好呀!")
        if thought.emotion != .happy || thought.text.contains("think") || thought.text.contains("sad") {
            print("think-strip FAIL: \(thought.emotion.map(\.rawValue) ?? "nil") / \(thought.text)")
            fails += 1
        }
        if !Persona.parse("<think>思考没有结束").text.isEmpty {
            print("think-strip FAIL: unclosed think not treated as empty")
            fails += 1
        }

        // recombined self-plagiarism must be caught by the repeat gate
        let poem = "欢欣鼓舞展翅飞,\n晨起乘风舞翩跹。\n笑语盈盈伴我游。\n乐在其中任我行。"
        let rehash = "晨起乘风舞翩跹, 笑语盈盈伴我游, 乐在其中任我行。"
        if Persona.qualityIssue(reply: rehash, user: "写一篇小说", recentReplies: [poem]) != "verbatim repeat" {
            print("repeat-gate FAIL: recombined rehash not caught")
            fails += 1
        }
        // detection of previously-missed phrasings
        for (text, kind) in [("写一篇小说", Persona.CreativeKind.story), ("写一首唐诗", .poem), ("写一篇文章", .essay), ("来个绕口令", .poem)] {
            if Persona.detectCreative(text) != kind {
                print("creative detect FAIL: \(text)")
                fails += 1
            }
        }
        print("sanitizer+gates: \(cases.count + 5) cases, \(fails) failures")
        return fails
    }

    private static func runChineseContentCases() -> Int {
        var failures = 0
        let categories: [L10n.CannedCategory] = [
            .poke, .pokeAnnoyed, .petted, .fedFish, .fedCookie, .fullTummy,
            .wokenGrumpy, .landingOuch, .playStart, .morning, .afternoon,
            .evening, .night, .hungry, .bored, .sleepy, .confused,
        ]
        for category in categories where !Persona.isChineseReply(L10n.canned(category)) {
            print("中文互动台词缺失：\(category)")
            failures += 1
        }
        let kinds: [Persona.CreativeKind] = [.joke, .story, .poem, .essay, .riddle, .game, .song, .fortune, .praise]
        for kind in kinds where !Persona.isChineseReply(L10n.creativeCanned(kind)) {
            print("中文创作兜底缺失：\(kind)")
            failures += 1
        }
        let context = makeContext()
        if !Persona.statusLine(context).contains("15:20") || !Persona.system(context).contains("主人") {
            print("中文状态或人设提示词缺失")
            failures += 1
        }
        if Emotion.fromTag("happy") != .happy || Emotion.fromTag("开心") != .happy
            || PetAction.fromTag("dance") != .dance || PetAction.fromTag("跳舞") != .dance {
            print("情绪或动作协议标签解析失败")
            failures += 1
        }
        print("中文文案与协议检查：\(categories.count + kinds.count + 2) 项，\(failures) 个失败")
        return failures
    }

    // MARK: - Batch LLM quality matrix

    private struct Metrics {
        var total = 0
        var empty = 0
        var noEmotion = 0
        var junkLeaks = 0
        var overLength = 0
        var nonChinese = 0
        var echoes = 0
        var assistantSpeak = 0
        var commandAgreed = 0
        var commandTotal = 0
        var samples: [String] = []
    }

    private static let junkMarkers = [
        "中文短句", "字以内", "[标签]", "markdown", "示例", "你:",
    ]

    private static func makeContext() -> PetContext {
        PetContext(
            stats: PetStats(fullness: 55, energy: 70, happiness: 75),
            activityHint: "待在桌面上",
            timeOfDay: Persona.timeOfDay(hour: 15),
            clockString: "15:20",
            recentEvents: [],
            companionMinutes: 42)
    }

    /// Deliberately different from the few-shot examples in the system prompt,
    /// so scores measure generalization instead of example-copying.
    private static func prompts() -> [(text: String, command: PetAction?)] {
        return [
        ("早上好呀!", nil),
        ("你喜欢我吗?", nil),
        ("我刚被老板批评了,有点沮丧", nil),
        ("转个圈看看!", .spin),
        ("介绍一下你自己吧", nil),
        ("你想吃点什么?", nil),
        ]
    }

    private static func runBatch(_ brain: Brain, rounds: Int) async {
        var m = Metrics()
        let start = Date()
        for round in 1...rounds {
            for (text, command) in prompts() {
                let hint = command.map { Persona.commandHint($0) }
                let reply = await roundTrip(brain, user: text, hint: hint)
                m.total += 1
                guard let reply, !reply.text.isEmpty else {
                    m.empty += 1
                    m.samples.append(" EMPTY ← \(text)")
                    continue
                }
                if reply.emotion == nil { m.noEmotion += 1 }
                let maxChars = 78
                if reply.text.count > maxChars { m.overLength += 1 }
                let lower = reply.text.lowercased()
                if junkMarkers.contains(where: { lower.contains($0.lowercased()) }) {
                    m.junkLeaks += 1
                    m.samples.append(" JUNK: \(reply.text)")
                }
                var flags = ""
                if !Persona.isChineseReply(reply.text) {
                    m.nonChinese += 1
                    flags += " LANG!"
                }
                if text.count >= 8,
                    Persona.longestCommonRun(reply.text.lowercased(), text.lowercased())
                        >= (6)
                {
                    m.echoes += 1
                    flags += " ECHO!"
                }
                if ["帮你", "帮助您"].contains(where: { lower.contains($0) }) {
                    m.assistantSpeak += 1
                    flags += " ASSIST!"
                }
                if command != nil {
                    m.commandTotal += 1
                    if reply.action == command || reply.text.count > 2 { m.commandAgreed += 1 }
                }
                if round == 1 || !flags.isEmpty {
                    let e = reply.emotion.map(\.rawValue) ?? "-"
                    let a = reply.action.map(\.rawValue) ?? "-"
                    m.samples.append(" (\(e)/\(a))\(flags) \(text) → \(reply.text.replacingOccurrences(of: "\n", with: " ⏎ "))")
                }
            }
        }
        let dt = Date().timeIntervalSince(start)

        print("\n=== batch results (\(m.total) generations in \(Int(dt))s) ===")
        for s in m.samples { print("  \(s)") }
        let answered = max(1, m.total - m.empty)
        let emotionRate = Double(answered - m.noEmotion) / Double(answered)
        let chineseRate = Double(answered - m.nonChinese) / Double(answered)
        print(String(format: "empty: %d | tag rate %.0f%% | 中文比例 %.0f%% | echoes: %d | assistant-speak: %d | junk: %d | over-length: %d",
                     m.empty, emotionRate * 100, chineseRate * 100, m.echoes, m.assistantSpeak, m.junkLeaks, m.overLength))

        let chatPass = m.junkLeaks == 0 && m.overLength == 0 && m.empty <= m.total / 12
            && emotionRate >= 0.8 && chineseRate >= 0.85
            && m.echoes <= m.total / 8 && m.assistantSpeak <= 1

        let creativePass = await runCreativeBatch(brain, rounds: max(1, rounds - 1))
        let recallPass = await runRecallBatch(brain)
        let thinkingPass = await runThinkingSmoke(brain)

        let pass = chatPass && creativePass && recallPass && thinkingPass
        print(pass ? "selftest PASSED" : "selftest FAILED (chat: \(chatPass), creative: \(creativePass), recall: \(recallPass), thinking: \(thinkingPass))")
        exit(pass ? 0 : 1)
    }

    // MARK: - Thinking-mode smoke test

    private static func runThinkingSmoke(_ brain: Brain) async -> Bool {
        let cases = ["我该先写作业还是先打游戏?"]
        var ok = 0
        print("\n=== thinking mode (\(cases.count) generations) ===")
        for q in cases {
            brain.clearHistory()
            let reply = await withCheckedContinuation { (cont: CheckedContinuation<Persona.ParsedReply?, Never>) in
                brain.generate(
                    userContent: q, context: makeContext(), recordHistory: false,
                    thinking: true,
                    onEmotion: { _ in }, onText: { _ in },
                    onDone: { cont.resume(returning: $0) })
            }
            let text = reply?.text ?? ""
            let leaked = text.contains("think") || text.contains("<") || text.contains("思考:")
            let good = !text.isEmpty && !leaked
            if good { ok += 1 }
            print("  \(good ? "" : " FAIL!") \(q) → \(text.replacingOccurrences(of: "\n", with: " ⏎ "))")
        }
        print("thinking: \(ok)/\(cases.count) clean")
        return ok == cases.count
    }

    // MARK: - Multi-turn context recall

    /// Teach the pet a fact in turn 1, probe it in turn 2 — measures whether the
    /// conversation history actually carries context.
    private static func runRecallBatch(_ brain: Brain) async -> Bool {
        let cases: [(teach: String, probe: String, expect: [String])] = [
            ("告诉你哦,我给你准备的新玩具是一个红色毛线球", "我给你准备的新玩具是什么?", ["红", "毛线"]),
            ("我今天买了草莓蛋糕当下午茶", "我下午茶买了什么?", ["草莓", "蛋糕"]),
        ]
        var hits = 0
        var samples: [String] = []
        for c in cases {
            brain.clearHistory()
            _ = await roundTripHistory(brain, user: c.teach)
            let reply = await roundTripHistory(brain, user: c.probe)
            let text = reply?.text ?? ""
            let hit = c.expect.contains { text.lowercased().contains($0.lowercased()) }
            if hit { hits += 1 }
            samples.append("\(hit ? "" : " MISS!") \(c.probe) → \(text.replacingOccurrences(of: "\n", with: " "))")
        }
        // repeat-question probe: asking the same thing twice must not photocopy
        let repeatQs = ["你是什么星座?"]
        var varied = 0
        for q in repeatQs {
            brain.clearHistory()
            let r1 = await roundTripHistory(brain, user: q)
            let r2 = await roundTripHistory(brain, user: q)
            let t1 = r1?.text ?? "", t2 = r2?.text ?? ""
            let different = !t2.isEmpty && t1 != t2
            if different { varied += 1 }
            samples.append("\(different ? "" : " PHOTOCOPY!") repeat-ask → 1: \(t1.prefix(40))… / 2: \(t2.prefix(40))…")
        }
        brain.clearHistory()
        print("\n=== context recall (\(cases.count) dialogs + \(repeatQs.count) repeat probes) ===")
        for s in samples { print("  \(s)") }
        print("recall: \(hits)/\(cases.count) | repeat-variation: \(varied)/\(repeatQs.count)")
        return hits == cases.count && varied == repeatQs.count
    }

    // MARK: - Common-scenario suite (broad coverage; results reviewed by hand)

    static func runScenarios(rounds: Int) {
        let brain = Brain(loadPersistedHistory: false)
        print("scenarios: loading model… (rounds: \(rounds))")
        brain.onStateChange = { state in
            switch state {
            case .ready:
                Task { @MainActor in await scenarioBatch(brain, rounds: rounds) }
            case .failed(let msg):
                print("scenarios FAILED: \(msg)")
                exit(1)
            default: break
            }
        }
        brain.load()
    }

    private static func scenarioPrompts() -> [String] {
        return [
        "晚安,我去睡觉啦",
        "谢谢你一直陪着我",
        "我升职加薪了!!",
        "烦死了,代码一直报错",
        "我有点孤独",
        "你几岁啦?",
        "你的名字有什么来历?",
        "你会做什么呀?",
        "你讨厌什么东西?",
        "你饿不饿?",
        "你现在在做什么?",
        "陪陪我嘛",
        "1加1等于几?",
        "天空为什么是蓝色的?",
        "今天天气怎么样?",
        "。。。",
        "哈哈哈哈哈",
        "在吗",
        ]
    }

    private static func scenarioBatch(_ brain: Brain, rounds: Int) async {
        var total = 0, empty = 0, nonChinese = 0, flagged = 0
        for round in 1...rounds {
            for text in scenarioPrompts() {
                brain.clearHistory()
                // mirror the app's full routing
                let goodnight = Persona.detectGoodnight(text)
                let creative = goodnight ? nil : Persona.detectCreative(text)
                let intent = (goodnight || creative != nil) ? nil : Persona.detectCommand(text)
                let hint = goodnight
                    ? Persona.goodnightHint()
                    : creative.map { Persona.creativeInstruction($0) }
                        ?? intent.map { Persona.commandHint($0) }
                let reply = await withCheckedContinuation { (cont: CheckedContinuation<Persona.ParsedReply?, Never>) in
                    brain.generate(
                        userContent: text, context: makeContext(), recordHistory: false,
                        commandHint: hint,
                        creative: creative.map { ($0, L10n.creativeCanned($0)) },
                        onEmotion: { _ in }, onText: { _ in },
                        onDone: { cont.resume(returning: $0) })
                }
                total += 1
                let text2 = reply?.text ?? ""
                var flags = ""
                if text2.isEmpty { empty += 1; flags += " EMPTY!" }
                else if !Persona.isChineseReply(text2) { nonChinese += 1; flags += " LANG!" }
                let route = goodnight ? "night" : creative.map { $0.rawValue } ?? intent.map { $0.rawValue } ?? "chat"
                if !flags.isEmpty { flagged += 1 }
                if round == 1 || !flags.isEmpty {
                    print("  [\(route)]\(flags) \(text) → \(text2.replacingOccurrences(of: "\n", with: " ⏎ "))")
                }
            }
        }
        print("scenarios: \(total) generations | empty: \(empty) | 非中文回复: \(nonChinese)")
        exit(flagged == 0 ? 0 : 1)
    }

    private static func roundTripHistory(
        _ brain: Brain, user: String
    ) async -> Persona.ParsedReply? {
        await withCheckedContinuation { cont in
            brain.generate(
                userContent: user, context: makeContext(), recordHistory: true,
                onEmotion: { _ in }, onText: { _ in },
                onDone: { cont.resume(returning: $0) })
        }
    }

    private static func roundTrip(
        _ brain: Brain, user: String, hint: String?
    ) async -> Persona.ParsedReply? {
        await withCheckedContinuation { cont in
            var emotionSeen: Emotion? = nil
            brain.generate(
                userContent: user,
                context: makeContext(),
                recordHistory: false,
                commandHint: hint,
                onEmotion: { emo in emotionSeen = emo },
                onText: { _ in },
                onDone: { parsed in
                    var p = parsed
                    if p != nil && p!.emotion == nil { p!.emotion = emotionSeen }
                    cont.resume(returning: p)
                })
        }
    }

    // MARK: - Creative delivery batch

    private static func creativePrompts() -> [(String, Persona.CreativeKind)] {
        return [("给我讲个笑话吧!", .joke), ("写一篇小说", .story), ("我们玩游戏吧!", .game), ("写一首唐诗", .poem), ("写一篇文章", .essay)]
    }

    private static func runCreativeBatch(_ brain: Brain, rounds: Int) async -> Bool {
        var total = 0, nativeDelivered = 0, fallbacks = 0, failures = 0
        var samples: [String] = []
        for round in 1...rounds {
            for (text, kind) in creativePrompts() {
                guard Persona.detectCreative(text) == kind else {
                    print("creative detect FAIL: \(text)")
                    continue
                }
                // exercise the full delivery path incl. curated fallback
                let hint = Persona.creativeInstruction(kind)
                let fallback = L10n.creativeCanned(kind)
                let reply = await withCheckedContinuation { (cont: CheckedContinuation<Persona.ParsedReply?, Never>) in
                    brain.generate(
                        userContent: text, context: makeContext(), recordHistory: false,
                        commandHint: hint, creative: (kind, fallback),
                        onEmotion: { _ in }, onText: { _ in },
                        onDone: { cont.resume(returning: $0) })
                }
                total += 1
                guard let reply, !reply.text.isEmpty else {
                    failures += 1
                    samples.append(" \(kind.rawValue) TOTAL-FAIL (no text at all)")
                    continue
                }
                let usedFallback = reply.text == fallback
                if usedFallback { fallbacks += 1 } else { nativeDelivered += 1 }
                if round == 1 {
                    samples.append(" \(kind.rawValue)\(usedFallback ? " (curated)" : "") \(reply.text.replacingOccurrences(of: "\n", with: " ⏎ "))")
                }
            }
        }
        print("\n=== creative delivery (\(total) generations) ===")
        for s in samples { print("  \(s)") }
        let nativeRate = Double(nativeDelivered) / Double(max(1, total))
        print(String(format: "LLM-native: %d (%.0f%%) | curated fallback: %d | total failures: %d",
                     nativeDelivered, nativeRate * 100, fallbacks, failures))
        // guaranteed delivery must be airtight; native quality should stay meaningful
        return failures == 0 && nativeRate >= 0.5
    }
}
