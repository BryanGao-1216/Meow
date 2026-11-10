import AppKit

/// 使用假气泡、临时大脑与模拟时钟验证报信排队，不读取钥匙串或请求模型。
@MainActor
enum MailPresentationSelfTest {
    static func run() -> Int {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1; print("mail presentation FAIL: \(label)") }
        }
        let core = PetCore(), brain = Brain(loadPersistedHistory: false)
        core.stats.energy = 100
        let screen = WallScreen(id: "letter", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let wall = WallAttachment(side: .right, screenID: screen.id, heightFraction: 0.5)
        let engine = PetEngine(core: core, brain: brain, wallAttachment: wall,
                               screens: { [screen] }, mouseLocation: { CGPoint(x: 700, y: 450) })
        let bubble = MailTestBubble(); engine.bubble = bubble
        var now = Date()
        engine.updateUnreadLetters(1)
        check(!engine.deliverPendingMailArrival(at: now), "恢复已有未读只举信，不把旧信重复报成新信")
        engine.receivedLetter()
        check(!engine.deliverPendingMailArrival(at: now), "墙边先探出身体，再开始报信")
        core.wallReveal = 1
        core.activity = .think
        check(!engine.deliverPendingMailArrival(at: now) && bubble.lines.isEmpty, "对话思考期间保留报信，不抢话")
        for step in 1...60 { engine.tick(at: now.addingTimeInterval(Double(step) / 60)) }
        now = now.addingTimeInterval(1)
        check(core.wallReveal > 0.99 && bubble.lines.isEmpty, "思考期间先完成探身，报信继续等待")
        core.activity = .sleep; core.isSleeping = true
        check(!engine.deliverPendingMailArrival(at: now) && core.isSleeping, "睡觉时等待醒来，不强制叫醒")
        core.activity = .idle; core.isSleeping = false
        engine.hasPriorityNotice = { true }
        check(!engine.deliverPendingMailArrival(at: now), "到点的备忘录提醒优先")
        engine.hasPriorityNotice = { false }
        check(engine.speakProactively("测试中的备忘录提醒", wakeForAlarm: false, at: now), "测试气泡先展示已有提醒")
        check(!engine.deliverPendingMailArrival(at: now) && bubble.lines.count == 1, "已有气泡期间不替换内容")
        engine.tick(at: now.addingTimeInterval(10))
        check(bubble.lines.count == 2 && bubble.lines.last?.contains("来信啦") == true
              && core.activity == .talk && !brain.isReady, "提醒结束后自动补报，固定中文台词无需模型")
        check(engine.wallAttachment == wall && core.wallReveal > 0.95, "报信保持贴墙及探身状态")
        check(!engine.deliverPendingMailArrival(at: now.addingTimeInterval(11)), "同一批来信不反复报信")
        engine.updateUnreadLetters(2); engine.receivedLetter()
        engine.updateUnreadLetters(3); engine.receivedLetter()
        engine.tick(at: now.addingTimeInterval(25))
        check(bubble.lines.count == 2, "连续来信至少间隔三十秒报信")
        engine.tick(at: now.addingTimeInterval(41))
        check(bubble.lines.count == 3 && bubble.lines.last?.contains("3 封") == true, "短时间多封来信合并报未读数")
        engine.updateUnreadLetters(4); engine.receivedLetter()
        engine.updateUnreadLetters(0)
        engine.tick(at: now.addingTimeInterval(50))
        check(bubble.lines.count == 3 && core.unreadLetters == 0, "主人先读完时取消排队的报信")

        // 一整轮实际变换的范围：含 99+ 角标，四档尺寸、朝向、左右墙边均可点击且不裁切。
        for side: WallSide? in [nil, .left, .right] {
            for sleeping in [false, true] {
                var bounds = CGRect.null
                for step in 0..<120 {
                    let motion = HeldLetter.transform(at: Double(step) * HeldLetter.period / 120,
                                                      wallSide: side, sleeping: sleeping)
                    bounds = bounds.union(HeldLetter.contentBounds.applying(motion))
                }
                check(HeldLetter.hitBounds.contains(bounds), "\(side?.rawValue ?? "桌面") · \(sleeping ? "轻晃" : "举信") 全程命中范围包含信、爪和角标")
                if side == nil {
                    let mirrored = CGRect(x: 200 - bounds.maxX, y: bounds.minY, width: bounds.width, height: bounds.height)
                    check(HeldLetter.hitBounds.contains(mirrored), "转向另一侧后仍可点击晃动的信")
                }
            }
            for scale: CGFloat in [0.5, 0.8, 1, 1.3] {
                let size = PetLayout.renderSize(scale: scale, wallSide: side, wallReveal: 1)
                let rect = PetLayout.letterHitRect(size: size, wallSide: side, reveal: 1)
                check(CGRect(origin: .zero, size: size).contains(rect), "\(side?.rawValue ?? "桌面") · \(scale) 动画范围完整位于画布中")
            }
        }
        print("mail presentation: \(checks - failures)/\(checks) OK（举信范围、报信排队、合并与取消，无模型请求）")
        return failures
    }
}

@MainActor
private final class MailTestBubble: BubbleController {
    var lines: [String] = []
    func show(text: String, above petCenter: CGPoint, petScale: CGFloat) { lines.append(text) }
    func update(text: String) {}
    func reposition(above petCenter: CGPoint, petScale: CGFloat) {}
    func hide() {}
}
