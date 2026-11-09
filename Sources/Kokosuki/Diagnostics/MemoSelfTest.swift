import AppKit
import KokosukiMemos

@MainActor
enum MemoSelfTest {
    private final class Harness {
        var date = MemoPrompts.parseDate("2026-11-09T16:00:00+08:00")!
        var available = true, deliverable = true, earlyDecision = true, badIDs = false
        var plan = "{\"action\":\"none\"}"
        var plans = 0, reviews = 0, dues = 0
        var delivered: [MemoNotice] = []
        var delayPlan = false
        var delayReview = false
        var gate: CheckedContinuation<String?, Never>?
        var reviewGate: CheckedContinuation<String?, Never>?
        var dependencies: MemoDependencies {
            MemoDependencies(complete: { system, input in
                if system == MemoPrompts.plannerSystem {
                    self.plans += 1
                    if self.delayPlan { return await withCheckedContinuation { self.gate = $0 } }
                    return self.plan
                }
                let data = try JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any]
                let kind = data["类型"] as! String
                if kind == "due" { self.dues += 1 } else { self.reviews += 1 }
                let rows = data["本轮允许提醒的任务"] as! [[String: String]]
                let ids = self.badIDs ? [UUID().uuidString] : rows.compactMap { $0["id"] }
                let notify = kind == "due" || self.earlyDecision
                if kind == "early", self.delayReview { return await withCheckedContinuation { self.reviewGate = $0 } }
                return MemoPrompts.json(["should_remind": notify, "ids": notify ? ids : [],
                    "text": notify ? "主人，记得今晚七点的测试聚会喵，提前准备一下！" : "",
                    "reason": "需要留出准备时间"])
            }, canEvaluate: { _ in self.available }, deliver: { item in
                guard self.deliverable else { return false }
                self.delivered.append(item); return true
            }, persona: { "你是高小喵。" }, preferences: { ["主人喜欢简短提醒"] })
        }
    }
    private static func settle(_ memos: MemoController) async {
        for _ in 0..<400 where memos.isBusy { await Task.yield() }
    }
    static func run() async -> Int {
        var failures = 0, checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1; print("memo FAIL: \(label)") }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meow-memo-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let h = Harness()
        let url = directory.appendingPathComponent("memos.json")
        let memos = MemoController(storageURL: url, now: { h.date }, dependencies: h.dependencies)
        let party = h.date.addingTimeInterval(3 * 3600)
        do {
            try memos.saveItem(title: "测试聚会", dueAt: party)
            let id = memos.book.active[0].id
            check((try? MemoBook.read(from: url))?.active.count == 1, "直接编辑写入真实本机备忘录")
            try memos.saveItem(title: "测试聚会", dueAt: party)
            check(memos.book.active.count == 1, "同一任务和时间不会重复创建")
            do { try memos.saveItem(title: "过去时间", dueAt: h.date.addingTimeInterval(-1)); check(false, "拒绝过去时间") } catch { check(true, "拒绝过去时间") }
            do { try memos.saveItem(title: "  ", dueAt: party); check(false, "拒绝空任务") } catch { check(true, "拒绝空任务") }
            check(memos.book.active.count == 1, "非法编辑不影响已经保存的任务")
            h.deliverable = false
            memos.checkSchedule(); await settle(memos)
            check(h.reviews == 1 && memos.book.pending?.kind == .early && h.delivered.isEmpty, "半小时巡看由模型判断并生成提前提醒，忙碌时排队")
            memos.checkSchedule(); check(h.reviews == 1, "已有待讲文案时不重复调用模型")
            memos.shutdown()
            let restarted = MemoController(storageURL: url, now: { h.date }, dependencies: h.dependencies)
            check(restarted.book.pending?.kind == .early, "重启后保留已生成但尚未说出的提醒")
            h.deliverable = true
            restarted.checkSchedule(); restarted.checkSchedule()
            check(h.delivered.count == 1 && restarted.book.pending == nil && restarted.book.active[0].earlyCount == 1,
                  "真正讲出后才记录一次提醒，不重复播报")
            h.date = h.date.addingTimeInterval(1800)
            restarted.checkSchedule(); await settle(restarted)
            check(h.reviews == 1 && h.delivered.count == 1, "同一任务一小时内不再次提前催促")
            h.date = h.date.addingTimeInterval(1800); h.earlyDecision = false
            restarted.checkSchedule(); await settle(restarted)
            check(h.reviews == 2 && h.delivered.count == 1 && restarted.book.pending == nil, "模型判断没有必要时保持安静")
            restarted.shutdown()
            let again = MemoController(storageURL: url, now: { h.date }, dependencies: h.dependencies)
            again.checkSchedule(); await settle(again)
            check(h.reviews == 2, "巡看时间持久化，重启不会重跑同一轮")
            h.date = party.addingTimeInterval(90)
            again.checkSchedule(); await settle(again)
            check(h.dues == 1 && h.delivered.last?.kind == .due && again.book.active[0].dueNotifiedAt != nil,
                  "提前提醒不会替代到点提醒，错过时间会补提醒")
            let deliveredCount = h.delivered.count
            again.checkSchedule(); await settle(again)
            check(h.dues == 1 && h.delivered.count == deliveredCount, "到点只提醒一次，任务仍可由主人标记完成")
            try again.saveItem(id: id, title: "改时间后的聚会", dueAt: h.date.addingTimeInterval(3600))
            check(again.book.active[0].dueNotifiedAt == nil && again.book.active[0].earlyCount == 0, "修改时间重新安排提醒并重置旧记录")
            try again.setStatus(.completed, id: id)
            again.checkSchedule(); await settle(again)
            check(again.book.active.isEmpty && h.delivered.count == deliveredCount, "完成任务不再提醒")
            try again.remove(id: id)
            check(again.book.items.isEmpty, "直接删除使用同一份数据")
            again.shutdown()
        } catch { check(false, "本机编辑与调度流程：\(error.localizedDescription)") }

        let chat = Harness()
        let chatMemos = MemoController(storageURL: directory.appendingPathComponent("chat.json"), now: { chat.date }, dependencies: chat.dependencies)
        chat.plan = "{\"action\":\"add\",\"title\":\"买猫粮\",\"due_at\":\"2026-11-10T19:00:00+08:00\"}"
        let result = await chatMemos.prepare("明天晚上七点提醒我买猫粮")
        check(chatMemos.book.active.count == 1 && result.contains("已验证"), "聊天先执行保存，成功结果交给角色模型回复")
        chat.plan = "{\"action\":\"clarify\",\"question\":\"哪一天、早上还是晚上七点喵？\"}"
        let question = await chatMemos.prepare("七点提醒我去聚会")
        check(chatMemos.book.active.count == 1 && question.contains("尚未写入") && chatMemos.accepts("明天晚上七点"), "时间含糊先追问，下一轮能补齐")
        chat.plan = "{\"action\":\"add\",\"title\":\"聚会\",\"due_at\":\"2026-11-10T19:00:00+08:00\"}"
        _ = await chatMemos.prepare("明天晚上七点")
        check(chatMemos.book.active.count == 2 && !chatMemos.accepts("随便聊聊"), "补齐后真实保存，结束待澄清状态")
        chat.plan = "{\"action\":\"none\"}"
        _ = await chatMemos.prepare("讲一个七点提醒小猫的故事")
        check(chatMemos.book.active.count == 2, "故事类解析不执行写入")
        let target = chatMemos.book.active[0]
        chat.plan = MemoPrompts.json(["action": "update", "id": target.id.uuidString, "title": target.title, "due_at": "2026-11-10T20:00:00+08:00"])
        _ = await chatMemos.prepare("把买猫粮改到晚上八点")
        check(chatMemos.book.active.first(where: { $0.id == target.id })?.dueAt == MemoPrompts.parseDate("2026-11-10T20:00:00+08:00"), "聊天按真实编号修改时间")
        chat.plan = MemoPrompts.json(["action": "cancel", "id": UUID().uuidString])
        let invalid = await chatMemos.prepare("取消那个")
        check(invalid.contains("失败") && chatMemos.book.active.count == 2, "不存在或含糊的编号不会误改其他任务")
        chat.delayPlan = true
        let delayed = Task { await chatMemos.prepare("再加一个提醒") }
        for _ in 0..<100 where chat.gate == nil { await Task.yield() }
        try? chatMemos.setStatus(.completed, id: target.id)
        chat.gate?.resume(returning: "{\"action\":\"add\",\"title\":\"过时的模型操作\",\"due_at\":\"2026-11-11T19:00:00+08:00\"}")
        chat.gate = nil
        let stale = await delayed.value
        check(stale.contains("已有变化") && !chatMemos.book.items.contains { $0.title == "过时的模型操作" }, "主人手动编辑后拒绝旧的异步工具结果")
        chatMemos.shutdown()

        let failing = Harness(); failing.badIDs = true
        let retry = MemoController(storageURL: directory.appendingPathComponent("retry.json"), now: { failing.date }, dependencies: failing.dependencies)
        try? retry.saveItem(title: "测试聚会", dueAt: failing.date.addingTimeInterval(60))
        failing.date = failing.date.addingTimeInterval(61)
        retry.checkSchedule(); await settle(retry)
        check(failing.delivered.isEmpty && retry.book.active[0].dueNotifiedAt == nil, "模型引用错误任务时不发送也不标记已提醒")
        retry.checkSchedule(); await settle(retry)
        check(failing.dues == 1, "模型失败有重试间隔，不会每五秒重复调用")
        failing.badIDs = false; failing.date = failing.date.addingTimeInterval(61)
        retry.checkSchedule(); await settle(retry)
        check(failing.dues == 2 && failing.delivered.count == 1, "恢复后重新判断并生成真正的到点提醒")
        retry.shutdown()

        let priority = Harness(); priority.delayReview = true
        let priorityMemos = MemoController(storageURL: directory.appendingPathComponent("priority.json"), now: { priority.date }, dependencies: priority.dependencies)
        try? priorityMemos.saveItem(title: "测试聚会", dueAt: priority.date.addingTimeInterval(30))
        priorityMemos.checkSchedule()
        for _ in 0..<100 where priority.reviewGate == nil { await Task.yield() }
        priority.date = priority.date.addingTimeInterval(31)
        priorityMemos.checkSchedule(); await settle(priorityMemos)
        check(priority.dues == 1 && priority.delivered.count == 1 && priority.delivered[0].kind == .due,
              "慢速的提前判断不阻塞到点提醒，到点优先切换任务")
        priority.reviewGate?.resume(returning: "{\"should_remind\":false,\"ids\":[],\"text\":\"\",\"reason\":\"安静\"}")
        priority.reviewGate = nil
        for _ in 0..<20 { await Task.yield() }
        check(priorityMemos.book.pending == nil && priorityMemos.book.active[0].dueNotifiedAt != nil,
              "取消后的提前判断不会覆盖已经发出的到点提醒")
        priorityMemos.shutdown()

        let corrupt = directory.appendingPathComponent("broken.json")
        let original = Data("broken".utf8); try? original.write(to: corrupt)
        let broken = MemoController(storageURL: corrupt, now: { failing.date }, dependencies: failing.dependencies)
        do { try broken.saveItem(title: "不可覆盖", dueAt: failing.date.addingTimeInterval(3600)); check(false, "保护损坏文件") } catch { check(true, "保护损坏文件") }
        broken.checkSchedule(); broken.shutdown()
        check((try? Data(contentsOf: corrupt)) == original, "损坏文件不会被空白备忘录覆盖")
        let block = directory.appendingPathComponent("not-a-directory")
        try? Data("file".utf8).write(to: block)
        let unavailable = MemoController(storageURL: block.appendingPathComponent("memos.json"), now: { failing.date }, dependencies: failing.dependencies)
        do { try unavailable.saveItem(title: "写入失败", dueAt: failing.date.addingTimeInterval(3600)); check(false, "写入失败不虚报成功") } catch { check(unavailable.book.items.isEmpty, "写入失败回滚，不虚报成功") }
        unavailable.shutdown()
        check(MemoPrompts.parseDate("2026-11-10T19:00:00") == nil && MemoPrompts.parseDate("2026-11-10T19:00:00+08:00") != nil, "模型时间必须携带明确时区")
        check(MemoPrompts.matches("明天七点提醒我出门") && !MemoPrompts.matches("我喜欢猫咪"), "常规闲聊不额外调用备忘录规划模型")

        let core = PetCore(), brain = Brain(loadPersistedHistory: false)
        let screen = WallScreen(id: "memo", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let pinned = WallAttachment(side: .left, screenID: "memo", heightFraction: 0.5)
        let engine = PetEngine(core: core, brain: brain, wallAttachment: pinned, screens: { [screen] })
        engine.rescaled(); engine.fallAsleep(commanded: true)
        check(!engine.canReceiveProactive(wakeForAlarm: false) && engine.canReceiveProactive(wakeForAlarm: true), "提前提醒不吵醒小猫，到点闹钟可以唤醒")
        var mirrored = ""; engine.proactiveMirror = { mirrored = $0 }
        check(engine.speakProactively("主人，到聚会时间啦喵。", wakeForAlarm: true) && !core.isSleeping && engine.wallAttachment == pinned,
              "到点提醒唤醒后保持贴墙，不乱跑")
        check(mirrored.contains("聚会") && brain.history.last?.text == mirrored, "主动提醒进入聊天记录，主人可以追问")
        check(!engine.speakProactively("不能覆盖当前提醒", wakeForAlarm: true), "当前气泡未结束时不覆盖")
        engine.beginDrag()
        check(!engine.canReceiveProactive(wakeForAlarm: true), "拖拽时延后投递，不打断主人的操作")
        print("memo integration: \(checks - failures)/\(checks) OK（临时文件、模拟时钟与模型，无网络）")
        return failures
    }
}
