import AppKit

/// 模拟显示器、隔离 Brain；不启动计时器、不加载模型、不保存真实数据。
@MainActor
enum WallSelfTest {
    static func run() -> Int {
        var failures = 0, checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1; print("wall FAIL: \(label)") }
        }
        let main = WallScreen(id: "main", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                              visibleFrame: CGRect(x: 0, y: 30, width: 1440, height: 846))
        let other = WallScreen(id: "other", frame: CGRect(x: 1440, y: 300, width: 1280, height: 720),
                               visibleFrame: CGRect(x: 1440, y: 330, width: 1280, height: 666))
        let left = WallDock.attachment(center: CGPoint(x: 40, y: 440), pointer: nil, scale: 1, screens: [main])!
        let right = WallDock.attachment(center: CGPoint(x: 1400, y: 440), pointer: nil, scale: 1, screens: [main])!
        check(left.side == .left && right.side == .right, "左右边缘分别吸附")
        check(WallDock.attachment(center: CGPoint(x: 720, y: 440), pointer: nil, scale: 1, screens: [main]) == nil, "桌面中央不吸附")
        check(WallDock.attachment(center: CGPoint(x: 720, y: 890), pointer: nil, scale: 1, screens: [main]) == nil, "顶部不吸附")
        check(WallDock.attachment(center: CGPoint(x: 85, y: 440), pointer: CGPoint(x: 0, y: 440), scale: 1, screens: [main])?.side == .left, "抓取偏移不妨碍鼠标抵墙")
        check(WallDock.attachment(center: CGPoint(x: 1420, y: 440), pointer: nil, scale: 1, screens: [main, other]) == nil, "显示器接缝不误吸附")
        check(WallDock.attachment(center: CGPoint(x: 1460, y: 440), pointer: nil, scale: 1, screens: [main, other]) == nil, "从相邻屏另一侧也可穿过")
        check(WallDock.attachment(center: CGPoint(x: 1420, y: 200), pointer: nil, scale: 1, screens: [main, other])?.side == .right, "不与相邻屏重叠的边缘仍是墙")
        let negative = WallScreen(id: "negative", frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: -1880, y: -200, width: 1880, height: 1056))
        check(WallDock.attachment(center: CGPoint(x: -1850, y: 200), pointer: nil, scale: 1, screens: [negative, main])?.side == .left, "负坐标显示器与侧边 Dock")
        for scale: CGFloat in [0.5, 0.8, 1, 1.3] {
            for side: WallSide in [.left, .right] {
                let attachment = WallAttachment(side: side, screenID: main.id, heightFraction: 2)
                let center = WallDock.center(for: attachment, screen: main, scale: scale)
                let size = WallDock.size(scale: scale)
                let bounds = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                    width: size.width, height: size.height)
                check(main.visibleFrame.insetBy(dx: -0.01, dy: -0.01).contains(bounds), "尺寸 \(scale)、\(side) 完整可见")
            }
        }
        let stored = try? JSONEncoder().encode(left)
        check(stored.flatMap { try? JSONDecoder().decode(WallAttachment.self, from: $0) } == left, "贴墙位置可跨重启保存")

        let core = PetCore()
        let brain = Brain(loadPersistedHistory: false)
        var available = [main]
        let engine = PetEngine(core: core, brain: brain, screens: { available })
        _ = NSApplication.shared
        let window = PetPanel(size: PetLayout.windowSize(scale: engine.scale))
        let container = PetContainerView(core: core)
        container.engine = engine
        window.contentView = container
        engine.moveWindow = { [weak window, weak container] center in
            guard let window, let container else { return }
            window.place(at: center, core: core, scale: engine.scale, container: container)
        }
        defer { engine.moveWindow = nil; window.close() }
        var changes: [WallAttachment?] = []
        engine.onWallAttachmentChange = { changes.append($0) }
        engine.beginDrag()
        engine.dragTo(CGPoint(x: 10, y: 440))
        engine.endDrag(velocity: CGVector(dx: -900, dy: 1000))
        check(core.wallSide == .left && engine.wallAttachment != nil, "松手吸附优先于投掷速度")
        check(window.frame.size == WallDock.size(scale: engine.scale), "贴墙窗口收紧到小脸大小（实际 \(window.frame.size)，目标 \(WallDock.size(scale: engine.scale))）")
        window.contentView?.layoutSubtreeIfNeeded()
        check(container.hitTest(CGPoint(x: container.bounds.midX, y: container.bounds.midY)) === container, "紧凑窗口可以点击和抓取")
        check(container.hitTest(CGPoint(x: container.bounds.maxX + 5, y: container.bounds.midY)) == nil, "小窗口外部不拦截点击")
        let pinned = engine.petCenter
        let clock = Date()
        for step in 1...120 { engine.tick(at: clock.addingTimeInterval(Double(step) / 30)) }
        check(engine.petCenter == pinned, "贴墙后不受重力或自主移动影响")
        engine.obey(.come, ownerRequested: false)
        engine.perform(.jump, ownerRequested: false)
        check(core.wallSide == .left && engine.petCenter == pinned, "模型动作标签不能解除固定")
        core.activity = .talk
        engine.tick(at: clock.addingTimeInterval(4.1))
        check(core.wallSide == .left && engine.petCenter == pinned, "聊天结束后仍贴墙")
        engine.feed(fish: true)
        engine.tick(at: clock.addingTimeInterval(4.2))
        check(core.wallSide == .left && engine.petCenter == pinned, "喂食时不离墙")
        engine.fallAsleep(commanded: true)
        engine.tick(at: clock.addingTimeInterval(4.3))
        check(core.isSleeping && engine.petCenter == pinned, "可固定在墙上睡觉")
        engine.obey(.wake)
        engine.tick(at: clock.addingTimeInterval(4.4))
        check(!core.isSleeping && core.wallSide == .left && engine.petCenter == pinned, "叫醒后不跳离墙")
        let restored = PetEngine(core: PetCore(), brain: brain, wallAttachment: engine.wallAttachment, screens: { available })
        restored.rescaled()
        check(restored.petCenter == pinned, "恢复位置和尺寸调整后仍贴墙")
        available = [other]
        engine.rescaled()
        check(engine.wallAttachment?.screenID == other.id && other.visibleFrame.contains(engine.petCenter), "显示器移除后迁到可见屏幕")
        available = [main]
        engine.rescaled()
        engine.beginDrag()
        check(core.wallSide == nil && engine.wallAttachment == nil && changes.last! == nil, "拖走解除固定并清除保存位置")
        engine.dragTo(CGPoint(x: 600, y: 500))
        engine.endDrag(velocity: .zero)
        check(core.wallSide == nil && core.activity == .fall, "桌面中央松手恢复落体")
        check(window.frame.width == PetLayout.windowSize(scale: engine.scale) && window.frame.width == window.frame.height, "拖走后恢复完整宠物窗口（实际 \(window.frame.size)，目标 \(PetLayout.windowSize(scale: engine.scale))）")
        engine.beginDrag()
        engine.dragTo(CGPoint(x: 1420, y: 440))
        engine.endDrag(velocity: .zero)
        check(core.wallSide == .right, "拖动后可以重新吸附另一侧")
        engine.callOver()
        check(core.wallSide == nil && core.activity == .fall, "菜单召唤解除贴墙并轻轻落下")
        engine.beginDrag()
        engine.dragTo(CGPoint(x: 20, y: 440))
        engine.endDrag(velocity: .zero)
        engine.obey(.dance)
        let releaseClock = clock.addingTimeInterval(4.5)
        for step in 1...120 where core.activity != .dance {
            engine.tick(at: releaseClock.addingTimeInterval(Double(step) / 60))
        }
        check(core.wallSide == nil && core.activity == .dance && core.dizzy == 0, "明确动作指令在轻柔落地后执行")
        print("wall docking: \(checks - failures)/\(checks) OK（模拟屏幕、无模型与网络）")
        return failures
    }
}
