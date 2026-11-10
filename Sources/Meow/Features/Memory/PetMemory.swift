import Foundation
import Combine
import MeowCloud
import MeowMemory

/// AppKit/SwiftUI 与纯 Swift 记忆内核之间的边界，所有写入在主线程串行提交。
@MainActor
final class PetMemory: ObservableObject {
    typealias Extractor = @MainActor (ArkConfiguration, String) async throws -> String
    @Published private(set) var journal = MemoryJournal()
    @Published private(set) var storageError: String?
    @Published private(set) var learningStatus = "本机记忆已就绪"
    @Published private(set) var hasUnreadableFile = false
    @Published private(set) var forgetError: String?
    var onForget: (() -> String?)?
    var onPersonalDataForgotten: (() -> Void)?

    private let url: URL?
    private let respectsSettings: Bool
    private let extract: Extractor
    private var saveTask: Task<Void, Never>?
    private var learningTask: Task<Void, Never>?
    private var learningEpoch = 0
    private var pending: [(String, Date, ArkConfiguration)] = []
    private(set) var reunion: String?
    private var cachedTendencies = MemoryTendencies.neutral

    init(persistent: Bool = true, storageURL: URL? = nil, respectsSettings: Bool = true,
         extractor: Extractor? = nil) {
        url = persistent ? (storageURL ?? Persistence.supportDir.appendingPathComponent("pet-memory.json")) : nil
        self.respectsSettings = respectsSettings
        extract = extractor ?? { configuration, prompt in
            try await ArkClient(configuration: configuration).generate(
                messages: [ArkMessage(role: "user", content: prompt)],
                thinking: false, maxTokens: 900, maxCharacters: 6000, onText: { _ in })
        }
        reload()
    }

    var enabled: Bool { url != nil && (!respectsSettings || AppSettings.shared.memoryEnabled) && !hasUnreadableFile }
    private var cloudLearningEnabled: Bool { !respectsSettings || AppSettings.shared.memoryAIEnabled }
    var tendencies: MemoryTendencies { enabled ? cachedTendencies : .neutral }
    var newsPreferenceStatements: [String] {
        guard enabled else { return [] }
        return journal.activeFacts().filter {
            ($0.kind == .preference || $0.kind == .habit) && !$0.key.hasPrefix("相处.")
        }.prefix(20).map(\.text)
    }

    func reload() {
        guard let url else { return }
        cancelLearning()
        saveTask?.cancel()
        do {
            journal = try MemoryJournal.read(from: url)
            storageError = nil
            hasUnreadableFile = false
            learningStatus = "本机记忆已就绪"
            cachedTendencies = journal.tendencies()
            if let seen = journal.lastSeen, Date().timeIntervalSince(seen) >= 4 * 3600 {
                reunion = "这次启动时，距离上次相见约\(Int(Date().timeIntervalSince(seen) / 3600))小时。可以自然地欢迎主人回来，不要反复提起或责怪。"
            }
        } catch {
            storageError = error.localizedDescription
            hasUnreadableFile = true
        }
    }

    func migrate(_ history: [Brain.Message]) {
        guard enabled else { return }
        let fullMigration = !journal.migratedHistory
        let repairBirthdays = (journal.birthdayExtractionVersion ?? 0) < 1
        guard fullMigration || repairBirthdays else { return }
        // 将原有人设中的主人资料迁入一次。清空后 migratedHistory 仍为 true，不会自动长回来。
        if fullMigration {
            let initialDate = (history.map(\.date).min() ?? Date()).addingTimeInterval(-1)
            for fact in MemoryLearning.explicitFacts(in: Persona.initialOwnerProfile) {
                journal.learn(fact, source: Persona.initialOwnerProfile, at: initialDate, origin: .initialPersona)
            }
        }
        var previous: Brain.Message?
        for message in history.filter({ $0.role == "user" }).sorted(by: { $0.date < $1.date }) {
            let context = Self.birthdayContext(previous, at: message.date)
            for fact in MemoryLearning.explicitFacts(in: message.text, previousUserMessage: context)
                where fullMigration || fact.key == "主人.生日" {
                journal.learn(fact, source: message.text, at: message.date, origin: .previousChat)
            }
            previous = message
        }
        journal.migratedHistory = true
        journal.birthdayExtractionVersion = 1
        changed()
    }

    static func birthdayContext(_ previous: Brain.Message?, at date: Date) -> String? {
        guard let previous, previous.role == "user",
              (0...900).contains(date.timeIntervalSince(previous.date)) else { return nil }
        return previous.text
    }

    func observe(_ source: String, at date: Date = .now, previousUserMessage: String? = nil) {
        guard enabled else { return }
        for fact in MemoryLearning.explicitFacts(in: source, previousUserMessage: previousUserMessage) {
            journal.learn(fact, source: source, at: date)
        }
        journal.record(.conversation, at: date)
        changed()
    }

    func record(_ kind: PetInteraction) {
        guard enabled, journal.record(kind) else { return }
        changed()
    }

    func presence() {
        guard enabled else { return }
        journal.markPresence()
        changed()
    }

    func context(for query: String) -> String {
        guard enabled else { return "" }
        return journal.promptContext(for: query) + (reunion.map { "\n" + $0 } ?? "")
    }

    func consolidate(_ source: String, at date: Date, configuration: ArkConfiguration) {
        guard enabled, cloudLearningEnabled, MemoryLearning.shouldConsolidate(source) else { return }
        // 不形成无界后台请求队列；直接记忆和聊天均不依赖整理完成。
        if pending.count >= 6 { pending.removeFirst() }
        pending.append((source, date, configuration))
        startLearningIfNeeded()
    }

    private func startLearningIfNeeded() {
        guard learningTask == nil, !pending.isEmpty else { return }
        let revision = learningEpoch
        learningTask = Task { [weak self] in
            guard let self else { return }
            while !self.pending.isEmpty, self.learningEpoch == revision, !Task.isCancelled {
                let (source, date, configuration) = self.pending.removeFirst()
                self.learningStatus = "正在整理主人刚说的话…"
                let prompt = MemoryLearning.extractionPrompt(source: source, existing: self.journal.activeFacts())
                do {
                    let result = try await self.extract(configuration, prompt)
                    guard self.learningEpoch == revision, !Task.isCancelled, self.enabled,
                          self.cloudLearningEnabled else { return }
                    for fact in MemoryLearning.parseExtraction(result, source: source) {
                        // 本轮的确定性规则优先，不让模型再用另一种措辞覆盖它。
                        let explicit = MemoryLearning.explicitFacts(in: source)
                        if explicit.contains(where: { MemoryLearning.normalizedKey($0.key) == MemoryLearning.normalizedKey(fact.key) }) { continue }
                        self.journal.learn(fact, source: source, at: date)
                    }
                    self.changed()
                    self.learningStatus = "整理完成；只保留有主人原话依据的记忆"
                } catch {
                    guard self.learningEpoch == revision, !Task.isCancelled else { return }
                    self.learningStatus = "云端整理失败，本机记忆仍可用：\(error.localizedDescription)"
                }
            }
            if self.learningEpoch == revision { self.learningTask = nil }
        }
    }

    func cancelLearning() {
        learningEpoch += 1
        learningTask?.cancel()
        learningTask = nil
        pending.removeAll()
        learningStatus = "云端整理已停止；本机记忆仍保留"
    }

    @discardableResult
    func handleCommand(_ text: String) -> String? {
        guard let command = MemoryLearning.command(in: text) else { return nil }
        guard !hasUnreadableFile else { return "小本本暂时打不开，原文件还在，请先到小本本检查。" }
        cancelLearning()
        let reply: String
        switch command {
        case .forgetAll:
            journal.forgetAll()
            reunion = nil
            reply = "好喵，小本本和聊天记录都清空了，我们从这一刻重新认识。"
        case .forget(let topic):
            let count = journal.forget(topic: topic)
            reply = count > 0 ? "好喵，关于这件事的小本本记录和旧聊天都清掉了。" : "小本本里没有找到这件事，旧聊天也清掉了。你也可以打开小本本逐条检查。"
        }
        retryForgettingContext()
        changed()
        flush()
        if storageError != nil { return "这次聊天里先忘掉了，但小本本还没成功保存，请到小本本检查。" }
        if forgetError != nil { return "小本本已经清除了，但旧聊天文件还没删成功，请到小本本重试清除。" }
        return reply
    }

    func forget(_ fact: MemoryFact) {
        guard !hasUnreadableFile else { return }
        cancelLearning()
        journal.forget(key: fact.key)
        retryForgettingContext()
        changed(); flush()
    }

    func forget(_ experience: PetExperience) {
        guard !hasUnreadableFile else { return }
        cancelLearning()
        journal.forgetExperience(id: experience.id)
        retryForgettingContext()
        changed(); flush()
    }

    func forgetAll() { _ = handleCommand("清空记忆") }

    func retryForgettingContext() {
        onPersonalDataForgotten?()
        forgetError = onForget?()
    }

    private func changed() {
        cachedTendencies = journal.tendencies()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let url, !hasUnreadableFile else { return }
        do { try journal.write(to: url); storageError = nil }
        catch { storageError = "记忆暂未写入磁盘：\(error.localizedDescription)" }
    }
}
