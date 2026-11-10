import Foundation
import MeowNews

@MainActor
enum NewsSelfTest {
    private final class Harness {
        var date = ISO8601DateFormatter().date(from: "2026-11-09T16:00:00+08:00")!
        var fetches = 0
        var completions = 0
        var deliveries: [NewsBulletin] = []
        var deliverable = false
        var failFetch = false
        var modelAvailable = true
        var gate: CheckedContinuation<[WeiboTopic], Never>?
        var waitForFetch = false
        let topic = WeiboTopic(title: "测试：人工智能新模型发布", category: "科技", rank: 1)
        var dependencies: NewsDependencies {
            NewsDependencies(fetchTopics: { _, date in
                self.fetches += 1
                if self.failFetch { throw NewsError.http(503) }
                if self.waitForFetch { return await withCheckedContinuation { self.gate = $0 } }
                var topic = self.topic; topic.fetchedAt = date; return [topic]
            }, fetchExcerpts: { _, _ in throw NewsError.loginRequired }, complete: { system, _ in
                self.completions += 1
                guard self.modelAvailable else { return nil }
                return system == NewsPrompts.selectionSystem ? "{\"index\":1}" : "[curious] 刷到一条人工智能热搜，想和你一起看看喵。"
            }, cookie: { "" }, taste: { NewsTaste(statements: ["主人关注人工智能"]) }, deliver: { item in
                guard self.deliverable else { return false }
                self.deliveries.append(item); return true
            }, persona: { "你是 Meow。" })
        }
    }

    private static func settle(_ controller: HotNewsController) async {
        for _ in 0..<300 where controller.isBusy { await Task.yield() }
    }

    static func run() async -> Int {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1; print("news integration FAIL: \(label)") }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meow-news-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = Harness()
        let url = directory.appendingPathComponent("news.json")
        let news = HotNewsController(storageURL: url, respectsSettings: false, now: { harness.date }, dependencies: harness.dependencies)
        news.checkSchedule(); await settle(news)
        check(harness.fetches == 1 && harness.completions == 2, "定时抓取、选题与写稿，不调用真实 API")
        check(news.hasPending && harness.deliveries.isEmpty, "忙碌时保留待讲话题")
        check(news.state.pending?.excerpts.isEmpty == true && news.state.pending?.detailNote?.contains("只分享热搜题目") == true, "详情不可用时保留真实题目并注明限制")
        news.checkSchedule()
        check(harness.fetches == 1, "待讲期间不重复抓取")
        news.shutdown()
        let restarted = HotNewsController(storageURL: url, respectsSettings: false, now: { harness.date }, dependencies: harness.dependencies)
        check(restarted.hasPending, "重启恢复尚未讲出的本期话题")
        harness.deliverable = true
        restarted.checkSchedule(); restarted.checkSchedule()
        check(harness.deliveries.count == 1 && restarted.state.bulletins.count == 1, "空闲后讲一次，并阻止本期重复")
        check(restarted.state.bulletins.first?.topic.sourceURL.host == "s.weibo.com", "保留微博来源")
        check(restarted.followupContext(for: "刚才的新闻是什么").contains(harness.topic.title), "追问时提供当时真实抓取的资料")
        harness.date = harness.date.addingTimeInterval(3 * 3600)
        restarted.checkSchedule(); await settle(restarted)
        check(harness.fetches == 2 && harness.deliveries.count == 1, "下一期跳过三天内相同话题")
        restarted.shutdown()

        let failing = Harness(); failing.failFetch = true
        let retry = HotNewsController(storageURL: directory.appendingPathComponent("retry.json"), respectsSettings: false,
            now: { failing.date }, dependencies: failing.dependencies)
        retry.checkSchedule(); await settle(retry)
        failing.date = failing.date.addingTimeInterval(100); retry.checkSchedule(); await settle(retry)
        check(failing.fetches == 1, "失败后五分钟内不重试")
        failing.date = failing.date.addingTimeInterval(200); retry.checkSchedule(); await settle(retry)
        failing.date = failing.date.addingTimeInterval(300); retry.checkSchedule(); await settle(retry)
        failing.date = failing.date.addingTimeInterval(300); retry.checkSchedule(); await settle(retry)
        check(failing.fetches == 3, "每期重试上限三次")
        retry.shutdown()

        let delayed = Harness(); delayed.waitForFetch = true
        let cancel = HotNewsController(storageURL: directory.appendingPathComponent("cancel.json"), respectsSettings: false,
            now: { delayed.date }, dependencies: delayed.dependencies)
        cancel.fetchNow()
        for _ in 0..<100 where delayed.gate == nil { await Task.yield() }
        cancel.discardPersonalizedContent()
        delayed.gate?.resume(returning: [delayed.topic]); delayed.gate = nil
        for _ in 0..<30 { await Task.yield() }
        check(!cancel.hasPending && cancel.state.bulletins.isEmpty && delayed.completions == 0, "遗忘后拒绝旧新闻任务回写")
        cancel.shutdown()

        let offline = Harness(); offline.modelAvailable = false
        let local = HotNewsController(storageURL: directory.appendingPathComponent("local.json"), respectsSettings: false,
            now: { offline.date }, dependencies: offline.dependencies)
        local.fetchNow(); await settle(local)
        check(local.state.pending?.line == NewsPrompts.fallbackLine(offline.topic), "没有模型时本机选题并忠实分享标题")
        local.shutdown()

        let updated = Harness()
        let refreshed = HotNewsController(storageURL: directory.appendingPathComponent("credentials.json"), respectsSettings: false,
            now: { updated.date }, dependencies: updated.dependencies)
        refreshed.fetchNow(); await settle(refreshed)
        check(refreshed.hasPending && refreshed.state.pending?.excerpts.isEmpty == true, "准备模拟旧凭据生成的标题小报")
        refreshed.credentialsChanged()
        check(!refreshed.hasPending && !refreshed.isBusy, "更新凭据后撤下未讲出的旧标题，允许立即重试")
        refreshed.fetchNow(); await settle(refreshed)
        check(updated.fetches == 2 && refreshed.hasPending, "新凭据保存后手动抓取不被旧待讲标题挡住")
        updated.deliverable = true; refreshed.checkSchedule()
        refreshed.credentialsChanged()
        check(refreshed.state.bulletins.count == 1, "已分享的小报和去重记录继续保留")
        refreshed.shutdown()

        let memory = PetMemory(storageURL: directory.appendingPathComponent("memory.json"), respectsSettings: false)
        memory.observe("我叫测试。我生日是10月9号。我关注人工智能。我不喜欢娱乐八卦")
        let preferences = memory.newsPreferenceStatements
        check(preferences.count == 2 && !preferences.joined().contains("生日") && !preferences.joined().contains("名字"), "选题只读取偏好，不读取姓名生日")
        var forgotten = false
        memory.onPersonalDataForgotten = { forgotten = true }
        memory.forgetAll()
        check(forgotten, "遗忘会通知清除个性化新闻文案")
        memory.flush()

        let broken = directory.appendingPathComponent("broken.json")
        let original = Data("broken".utf8); try? original.write(to: broken)
        let protected = HotNewsController(storageURL: broken, respectsSettings: false, dependencies: offline.dependencies)
        let before = offline.fetches
        protected.fetchNow(); protected.shutdown()
        check(protected.storageError != nil && (try? Data(contentsOf: broken)) == original && offline.fetches == before, "损坏缓存不被覆盖或继续抓取")

        let originalChat = Data("[{\"role\":\"assistant\",\"text\":\"你好喵\",\"date\":0}]".utf8)
        check((try? JSONDecoder().decode([Brain.Message].self, from: originalChat))?.count == 1, "旧聊天记录兼容新增来源字段")
        let chat = ChatModel()
        chat.appendNews("测试热点", sourceURL: harness.topic.sourceURL)
        check(chat.messages.first?.sourceURL == harness.topic.sourceURL && !chat.busy, "主动新闻在聊天中保留可点击来源，不占用输入")
        print("news integration: \(checks - failures)/\(checks) OK（模拟时钟、数据与模型，无网络）")
        return failures + (await WeiboClientSelfTest.run())
    }

    static func probe() async {
        do {
            let topics = try await WeiboClient().fetchTopics()
            print("微博公开热榜读取成功：\(topics.count)条；未读取登录凭据、未调用模型。")
            exit(0)
        } catch {
            print("微博公开热榜检查失败：\(error.localizedDescription)")
            exit(1)
        }
    }
}
