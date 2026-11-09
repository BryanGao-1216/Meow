import Foundation
import KokosukiCloud
import KokosukiMemory

/// 使用临时目录和注入的整理器，绝不读取主人的小本本或调用真实 API。
@MainActor
enum MemorySelfTest {
    private final class DelayedExtractor {
        var continuation: CheckedContinuation<String, Never>?
        var calls = 0
        func run() async -> String {
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }
    }

    static func run() async -> Int {
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1; print("memory integration FAIL: \(label)") }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kokosuki-memory-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.json")
        let gate = DelayedExtractor()
        let memory = PetMemory(storageURL: url, respectsSettings: false, extractor: { _, _ in await gate.run() })
        let date = Date()
        memory.migrate([
            Brain.Message(role: "user", text: "我喜欢茉莉花茶", date: date),
            Brain.Message(role: "assistant", text: "我喜欢南瓜", date: date)
        ])
        check(memory.journal.facts.contains { $0.text == "主人喜欢茉莉花茶" }, "迁移主人原话")
        check(!memory.journal.facts.contains { $0.text.contains("南瓜") }, "宠物回复不能变成主人事实")
        check(memory.journal.facts.contains { $0.key == "主人.称呼" && $0.origin == .initialPersona }, "原有人设的称呼只迁入一次")
        memory.flush()
        let restored = PetMemory(storageURL: url, respectsSettings: false)
        check(restored.journal.facts == memory.journal.facts, "控制器重启恢复")

        var resetCount = 0
        memory.onForget = { resetCount += 1; return nil }
        let source = "我喜欢在下雨的时候看书"
        let config = ArkConfiguration(baseURL: "https://example.invalid/v3", model: "test", apiKey: "fake")
        memory.consolidate(source, at: date, configuration: config)
        for _ in 0..<100 where gate.continuation == nil { await Task.yield() }
        check(gate.calls == 1, "只用注入整理器，无网络请求")
        _ = memory.handleCommand("清空记忆")
        gate.continuation?.resume(returning: """
        {"facts":[{"kind":"preference","key":"喜好.读书","text":"主人喜欢雨天看书","evidence":"我喜欢在下雨的时候看书"}]}
        """)
        gate.continuation = nil
        for _ in 0..<20 { await Task.yield() }
        check(memory.journal.facts.isEmpty, "遗忘后拒绝旧请求回写")
        check(resetCount == 1, "遗忘通知清除短期上下文")
        memory.migrate([Brain.Message(role: "user", text: "我喜欢咖啡", date: date)])
        check(memory.journal.facts.isEmpty, "遗忘后不重新导入原有人设或历史")
        memory.flush()
        check(PetMemory(storageURL: url, respectsSettings: false).journal.facts.isEmpty, "遗忘后重启仍为空")
        memory.onForget = { "模拟旧聊天文件删除失败" }
        let deletionReply = memory.handleCommand("清空记忆") ?? ""
        check(memory.forgetError != nil && deletionReply.contains("旧聊天文件"), "聊天文件清除失败不会声称遗忘成功")
        memory.onForget = { nil }
        memory.retryForgettingContext()
        check(memory.forgetError == nil, "可以重试清除短期聊天文件")

        let organizedURL = directory.appendingPathComponent("organized.json")
        let habitSource = "我习惯每晚睡前读半小时书"
        var extractedPrompt = ""
        let organized = PetMemory(storageURL: organizedURL, respectsSettings: false, extractor: { _, prompt in
            extractedPrompt = prompt
            return """
            {"facts":[{"kind":"habit","key":"习惯.睡前阅读","text":"主人习惯每晚睡前读半小时书","evidence":"我习惯每晚睡前读半小时书"}]}
            """
        })
        organized.consolidate(habitSource, at: date, configuration: config)
        for _ in 0..<100 where organized.journal.facts.isEmpty { await Task.yield() }
        check(organized.journal.activeFacts().count == 1, "正常整理提交有证据的事实")
        check(organized.context(for: "睡前读书").contains("半小时"), "整理后的记忆参与下一轮检索")
        check(extractedPrompt.contains(habitSource) && !extractedPrompt.contains("南瓜"), "整理只接收本轮主人原话和已有事实")
        organized.flush()

        let birthdayURL = directory.appendingPathComponent("birthday.json")
        let birthdayMemory = PetMemory(storageURL: birthdayURL, respectsSettings: false)
        let question = Brain.Message(role: "user", text: "你知道我生日是什么时候吗", date: date)
        let reply = Brain.Message(role: "user", text: "是10月9号哦", date: date.addingTimeInterval(13))
        birthdayMemory.observe(reply.text, at: reply.date,
                               previousUserMessage: PetMemory.birthdayContext(question, at: reply.date))
        check(birthdayMemory.journal.activeFacts().contains { $0.text == "主人的生日是10月9日" }, "生日短句当场写入小本本")
        birthdayMemory.flush()
        check(PetMemory(storageURL: birthdayURL, respectsSettings: false).context(for: "我的生日").contains("10月9日"), "生日短句保存并参与重启后的检索")
        check(PetMemory.birthdayContext(question, at: date.addingTimeInterval(901)) == nil, "不沿用超过十五分钟的生日话题")
        let petQuestion = Brain.Message(role: "assistant", text: "主人的生日是什么时候", date: date)
        check(PetMemory.birthdayContext(petQuestion, at: reply.date) == nil, "不依据宠物生成的话猜测主人生日")

        let upgradeURL = directory.appendingPathComponent("birthday-upgrade.json")
        var legacy = MemoryJournal()
        legacy.migratedHistory = true
        try? legacy.write(to: upgradeURL)
        let upgrade = PetMemory(storageURL: upgradeURL, respectsSettings: false)
        upgrade.migrate([question, reply])
        check(upgrade.journal.facts.count == 1 && upgrade.journal.facts[0].text == "主人的生日是10月9日", "为已迁移过的旧版小本本补回漏记生日")
        upgrade.migrate([question, reply])
        check(upgrade.journal.facts.first?.confirmations == 1, "生日补记只执行一次")
        upgrade.forgetAll()
        upgrade.migrate([question, reply])
        check(upgrade.journal.facts.isEmpty, "升级补记也不能恢复已遗忘的生日")
        upgrade.flush()

        let broken = directory.appendingPathComponent("broken.json")
        let original = Data("{broken".utf8)
        try? original.write(to: broken)
        let blocked = PetMemory(storageURL: broken, respectsSettings: false)
        blocked.observe("我喜欢咖啡")
        blocked.presence()
        blocked.forgetAll()
        blocked.flush()
        check(blocked.hasUnreadableFile, "损坏文件进入保护状态")
        check((try? Data(contentsOf: broken)) == original, "损坏的原文件不被覆盖")
        let isolated = PetMemory(persistent: false)
        isolated.observe("我喜欢咖啡")
        check(isolated.journal.facts.isEmpty, "模型自测与真实记忆隔离")
        let chat = ChatModel()
        chat.beginStream()
        chat.reset()
        check(chat.messages.isEmpty && !chat.busy, "遗忘时聊天退出等待状态")
        memory.cancelLearning()
        memory.flush()
        print("memory integration: \(checks - failures)/\(checks) OK（临时目录、模拟整理、无网络）")
        return failures
    }
}
