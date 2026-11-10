import AppKit

/// 模拟时钟与假气泡，检查重复轻互动不会改写动作、气泡和数值。
@MainActor
enum TouchInteractionSelfTest {
    static func run() -> Int {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1; print("touch FAIL: \(label)") }
        }
        let now = Date()
        let screen = WallScreen(id: "touch", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        func make(attached: Bool = true) -> (PetCore, PetEngine, TouchTestBubble) {
            let core = PetCore(), brain = Brain(loadPersistedHistory: false)
            let engine = PetEngine(core: core, brain: brain,
                wallAttachment: attached ? WallAttachment(side: .left, screenID: screen.id, heightFraction: 0.5) : nil,
                screens: { [screen] }, mouseLocation: { CGPoint(x: 700, y: 450) })
            let bubble = TouchTestBubble(); engine.bubble = bubble; engine.rescaled()
            if !attached { engine.dragTo(CGPoint(x: 700, y: PetLayout.feetDrop(scale: engine.scale))) }
            return (core, engine, bubble)
        }
        do {
            let (core, engine, bubble) = make()
            check(engine.pokeTap(at: now), "第一次戳正常响应")
            core.squash = 0.035
            let expiry = core.emotionUntil, lineCount = bubble.lines.count, happiness = core.stats.happiness
            check(!engine.pokeTap(at: now.addingTimeInterval(0.6)), "反应进行中忽略第二次戳")
            check(core.squash == 0.035 && core.emotionUntil == expiry && bubble.lines.count == lineCount,
                  "忽略重复戳不会重置形变、表情时长或气泡")
            check(!engine.petStroke(at: now.addingTimeInterval(0.7)) && core.stats.happiness == happiness,
                  "戳猫与抚摸共用保护，不交替刷回复或快乐值")
            engine.tick(at: now.addingTimeInterval(6))
            check(engine.pokeTap(at: now.addingTimeInterval(6.1)), "完整反应结束后可再次戳")
        }
        do {
            let (core, engine, bubble) = make(attached: false)
            check(engine.requestAction(.roll, at: now) && core.activity == .rollPose, "开始打滚")
            core.actionPhase = 1.1
            check(!engine.pokeTap(at: now.addingTimeInterval(0.2)) && !engine.petStroke(at: now.addingTimeInterval(0.3)),
                  "打滚未结束时不接受戳或抚摸")
            check(core.activity == .rollPose && core.actionPhase == 1.1 && bubble.lines.isEmpty,
                  "已有动作进度完整保留")
            check(engine.requestAction(.stop, at: now.addingTimeInterval(0.4)) && core.activity == .idle,
                  "明确停止指令仍立即生效")
        }
        do {
            let (core, engine, bubble) = make()
            check(engine.speakProactively("测试中的备忘录提醒", wakeForAlarm: false, at: now), "显示已有提醒")
            let expiry = core.emotionUntil
            check(!engine.pokeTap(at: now.addingTimeInterval(0.5)) && !engine.petStroke(at: now.addingTimeInterval(0.6)),
                  "已有对话或提醒时轻互动不抢话")
            check(bubble.lines == ["测试中的备忘录提醒"] && core.emotionUntil == expiry, "原气泡和表情不被替换")
            core.activity = .think
            check(!engine.pokeTap(at: now.addingTimeInterval(20)), "思考状态也受保护")
        }
        do {
            let (core, engine, bubble) = make()
            check(engine.petStroke(at: now), "第一次抚摸正常响应")
            let happiness = core.stats.happiness, hearts = core.particles.count, expiry = core.emotionUntil
            check(!engine.petStroke(at: now.addingTimeInterval(3)) && !engine.pokeTap(at: now.addingTimeInterval(3.1)),
                  "抚摸反应未结束，即使过了旧的 2.5 秒限制也不打断")
            check(core.stats.happiness == happiness && core.particles.count == hearts && core.emotionUntil == expiry,
                  "重复抚摸不刷数值和粒子")
            check(core.emotion == .love && bubble.lines.count <= 1, "保留完整撒娇表情")
        }
        do {
            let (core, engine, bubble) = make()
            core.isSleeping = true; core.activity = .sleep
            check(engine.pokeTap(at: now) && !core.isSleeping, "戳睡着的 Meow 仍能叫醒")
            let expiry = core.emotionUntil
            check(!engine.pokeTap(at: now.addingTimeInterval(0.5)) && bubble.lines.count == 1 && core.emotionUntil == expiry,
                  "醒来的反应不会被下一戳替换")
        }
        do {
            let (core, engine, _) = make()
            core.isSleeping = true; core.activity = .sleep
            check(engine.petStroke(at: now) && core.isSleeping && core.particles.count == 1, "睡觉时抚摸只出现一颗爱心")
            check(!engine.petStroke(at: now.addingTimeInterval(1)) && !engine.pokeTap(at: now.addingTimeInterval(1.1)) && core.isSleeping,
                  "睡眠中的轻互动也防止交替连触")
        }
        do {
            let (core, engine, bubble) = make()
            core.isSleeping = true; core.activity = .sleep
            _ = engine.pokeTap(at: now)
            for step in 1...12 { _ = engine.pokeTap(at: now.addingTimeInterval(Double(step) * 0.1)) }
            check(bubble.lines.count == 1 && core.emotion != .angry, "连戳不会提前抢断醒来反应")
            let happiness = core.stats.happiness
            engine.tick(at: now.addingTimeInterval(6))
            check(core.emotion == .angry && bubble.lines.count == 2 && core.stats.happiness < happiness - 1.9,
                  "连戳合并成一次抗议，等前一反应完整结束再播放")
            engine.tick(at: now.addingTimeInterval(7)); engine.tick(at: now.addingTimeInterval(12))
            check(bubble.lines.count == 2, "停止连戳后不积压重放多个抗议")
        }
        for cancel in ["chat", "drag", "stop"] {
            let (core, engine, bubble) = make()
            core.isSleeping = true; core.activity = .sleep
            _ = engine.pokeTap(at: now)
            for step in 1...4 { _ = engine.pokeTap(at: now.addingTimeInterval(Double(step) * 0.1)) }
            let before = bubble.lines.count
            switch cancel {
            case "chat": engine.chatOpened()
            case "drag":
                engine.beginDrag()
                check(core.activity == .drag && !engine.pokeTap(at: now.addingTimeInterval(0.8)), "拖拽可立即接管，拖动中不会被戳打断")
                engine.endDrag(velocity: .zero, pointer: CGPoint(x: 0, y: 450))
            default: _ = engine.requestAction(.stop, at: now.addingTimeInterval(0.8))
            }
            engine.tick(at: now.addingTimeInterval(6))
            check(bubble.lines.count == before && core.emotion != .angry, "\(cancel) 接管后取消过时的排队抗议")
        }
        print("touch interaction: \(checks - failures)/\(checks) OK（模拟时钟、动作与气泡保护、连戳合并，无模型请求）")
        return failures
    }

    /// 真实 NSView 鼠标回调与 DispatchWorkItem，验证排队单击与双击的取消行为。
    static func mouseEvents() async -> Int {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1; print("touch mouse FAIL: \(label)") }
        }
        let core = PetCore(), brain = Brain(loadPersistedHistory: false)
        let engine = PetEngine(core: core, brain: brain), bubble = TouchTestBubble()
        engine.bubble = bubble
        let panel = PetPanel(size: PetLayout.windowSize(scale: 1))
        let view = PetContainerView(core: core); view.engine = engine; panel.contentView = view
        panel.center(); panel.orderFrontRegardless()
        defer { panel.close() }
        var chats = 0
        view.openChat = { chats += 1; engine.chatOpened() }
        func click(_ count: Int) {
            let point = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0) {
                    if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
                }
            }
        }
        for _ in 0..<4 { click(1) }
        try? await Task.sleep(for: .milliseconds(350))
        check(core.emotion == .surprised, "排队的重复单击只触发一次正常反应")
        core.activity = .idle
        _ = engine.pokeTap(at: Date().addingTimeInterval(6))
        check(core.emotion == .surprised, "被取消的单击任务没有暗中累计为连戳")
        engine.resetConversationContext(); core.activity = .idle; core.emotion = .neutral; core.squash = 0
        bubble.lines.removeAll()
        click(1); click(2)
        try? await Task.sleep(for: .milliseconds(350))
        check(chats == 1 && core.squash == 0 && core.emotion == .neutral && bubble.lines.isEmpty,
              "双击仍打开聊天，前一单击不会随后补戳")
        click(1); engine.beginDrag()
        let expiry = core.emotionUntil
        try? await Task.sleep(for: .milliseconds(350))
        check(core.activity == .drag && core.emotionUntil == expiry && bubble.lines.isEmpty,
              "拖拽接管后延迟单击不能覆盖拖拽状态")
        print("touch mouse: \(checks - failures)/\(checks) OK（真实 NSView 事件与延迟回调）")
        return failures
    }
}

@MainActor
private final class TouchTestBubble: BubbleController {
    var lines: [String] = []
    func show(text: String, above petCenter: CGPoint, petScale: CGFloat) { lines.append(text) }
    func update(text: String) {}
    func reposition(above petCenter: CGPoint, petScale: CGFloat) {}
    func hide() {}
}
