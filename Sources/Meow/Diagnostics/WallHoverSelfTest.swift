import AppKit

/// 模拟鼠标、屏幕和时钟；不加载模型、不联网、不读写主人数据。
@MainActor
enum WallHoverSelfTest {
    static func run() -> Int {
        var checks = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1; print("wall hover FAIL: \(label)") }
        }
        var hover = WallHover()
        var elapsed = 0.0, peakBounce = 0.0
        var lines: [String] = []
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        func advance(_ seconds: Double, distance: CGFloat, enabled: Bool = true, canGreet: Bool = true) {
            for _ in 0..<Int(ceil(seconds * 60)) {
                elapsed += 1.0 / 60
                if let line = hover.update(distance: distance, scale: 1, enabled: enabled, canGreet: canGreet,
                                           now: epoch.addingTimeInterval(elapsed), dt: 1.0 / 60) { lines.append(line) }
                peakBounce = max(peakBounce, hover.bounce)
            }
        }
        advance(0.5, distance: 0)
        check(!hover.isNear && hover.reveal == 0 && lines.isEmpty, "拖到墙边后不会因鼠标仍在身上立即弹出")
        advance(0.05, distance: 200)
        advance(0.05, distance: 0)
        advance(0.05, distance: 200)
        check(!hover.isNear && lines.isEmpty, "短暂划过不触发招呼")
        advance(0.8, distance: 0)
        check(hover.isNear && abs(hover.reveal - 1) < 0.02, "停留靠近后平滑探身")
        check(lines == [WallHover.greetings[0]], "第一次靠近只说一句固定招呼")
        check(peakBounce > 3 && hover.bounce == 0, "入场轻跳一次，停留时不持续蹦跳")
        advance(0.5, distance: 90)
        check(hover.isNear && lines.count == 1, "进出阈值分开，轻微移动不会反复收回")
        advance(1, distance: 200)
        check(!hover.isNear && hover.reveal < 0.001, "移开后缩回原来的露出范围")
        advance(0.6, distance: 0)
        check(hover.isNear && lines.count == 1, "冷却期间仍会探身但不重复招呼")
        advance(0.8, distance: 0, enabled: false)
        check(!hover.isNear && hover.reveal < 0.01, "睡眠关闭探身并收回")
        advance(0.5, distance: 0)
        check(!hover.isNear, "睡醒时鼠标未离开不会再次弹出")
        advance(0.1, distance: 200)
        elapsed += 26
        advance(0.6, distance: 0, canGreet: false)
        check(hover.isNear && lines.count == 1, "聊天忙碌时可探身但不抢话")
        advance(0.3, distance: 0)
        check(lines.count == 1, "本次靠近被跳过的招呼不会延迟补说")
        advance(0.6, distance: 200)
        advance(0.6, distance: 0)
        check(lines == Array(WallHover.greetings.prefix(2)), "冷却后新一次靠近轮到下一句")
        hover.reset()
        check(hover.reveal == 0 && !hover.isNear && hover.bounce == 0, "拖走重置探身动画")
        advance(0.1, distance: 200)
        advance(0.5, distance: 0)
        check(lines.count == 2, "重新贴墙不绕过招呼冷却")
        for _ in 0..<8 {
            advance(0.6, distance: 200)
            elapsed += 26
            advance(0.6, distance: 0)
        }
        check(lines.enumerated().allSatisfy { $0.element == WallHover.greetings[$0.offset % WallHover.greetings.count] }, "四句台词轮流使用，无额外生成")
        for scale: CGFloat in [0.5, 0.8, 1, 1.3] {
            var motion = WallHover()
            var bounded = true
            for step in 0..<300 {
                let distance: CGFloat = step < 5 || step > 130 ? 300 : 0
                _ = motion.update(distance: distance, scale: scale, enabled: true, canGreet: true,
                                  now: epoch.addingTimeInterval(Double(step) / 30), dt: 1.0 / 30)
                bounded = bounded && (0...1.06).contains(motion.reveal) && motion.bounce.isFinite
            }
            check(bounded && motion.reveal == 0, "尺寸 \(scale) 动画有界并能完全收回")
        }

        let screen = WallScreen(id: "test", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 850))
        for side: WallSide in [.left, .right] {
            let attachment = WallAttachment(side: side, screenID: screen.id, heightFraction: 0.5)
            for scale: CGFloat in [0.5, 0.8, 1, 1.3] {
                let center = WallDock.center(for: attachment, screen: screen, scale: scale)
                let size = WallDock.size(scale: scale)
                check(WallDock.hoverDistance(pointer: center, attachment: attachment, screen: screen, scale: scale) == 0,
                      "\(side) \(scale) 收起区域内部距离为零")
                let expanded = WallDock.center(for: attachment, screen: screen, scale: scale, reveal: 1)
                let expandedSize = WallDock.size(scale: scale, reveal: 1)
                let edge = side == .left ? expanded.x - expandedSize.width / 2 : expanded.x + expandedSize.width / 2
                let alignedY = expanded.y + (side == .left ? expandedSize.height / 2 : -expandedSize.height / 2)
                let originalY = center.y + (side == .left ? size.height / 2 : -size.height / 2)
                check(abs(edge - (side == .left ? screen.visibleFrame.minX : screen.visibleFrame.maxX)) < 0.001 && abs(alignedY - originalY) < 0.001,
                      "\(side) \(scale) 为尾巴扩展窗口时小脸保持原高度")
                for height in [0.0, 1.0] {
                    let extreme = WallAttachment(side: side, screenID: screen.id, heightFraction: height)
                    let position = WallDock.center(for: extreme, screen: screen, scale: scale, reveal: 1.06, bounce: 8)
                    let bounds = WallDock.size(scale: scale, reveal: 1.06)
                    check(screen.visibleFrame.contains(CGRect(x: position.x - bounds.width / 2, y: position.y - bounds.height / 2,
                                                             width: bounds.width, height: bounds.height)),
                          "\(side) \(scale) 高度 \(height) 处探身与尾巴不超出可见屏幕")
                }
                let pointer = CGPoint(x: center.x + (side == .left ? 1 : -1) * (size.width / 2 + 50), y: center.y)
                check(abs(WallDock.hoverDistance(pointer: pointer, attachment: attachment, screen: screen, scale: scale) - 50) < 0.001,
                      "\(side) \(scale) 靠近使用稳定的收起区域")
            }
        }

        let core = PetCore(), brain = Brain(loadPersistedHistory: false)
        var pointer = CGPoint(x: 20, y: 450)
        let engine = PetEngine(core: core, brain: brain, screens: { [screen] }, mouseLocation: { pointer })
        let bubble = HoverTestBubble()
        engine.bubble = bubble
        engine.beginDrag()
        engine.dragTo(pointer)
        engine.endDrag(velocity: .zero)
        let pinned = engine.wallAttachment
        var engineTime = Date()
        func tick(_ seconds: Double) {
            for _ in 0..<Int(ceil(seconds * 60)) {
                engineTime = engineTime.addingTimeInterval(1.0 / 60)
                engine.tick(at: engineTime)
            }
        }
        tick(0.2)
        check(core.wallReveal == 0 && bubble.lines.isEmpty, "真实引擎刚贴墙不自动招呼")
        pointer = CGPoint(x: 700, y: 450)
        tick(0.1)
        pointer = CGPoint(x: 20, y: 450)
        tick(0.8)
        check(core.wallReveal > 0.98 && bubble.lines == [WallHover.greetings[0]] && !brain.isReady,
              "模型未加载时，真实引擎仍本地探身并说固定台词")
        check(engine.wallAttachment == pinned && core.activity == .idle, "招呼不会解除贴墙或启动自主移动")
        let width = WallDock.size(scale: engine.scale, reveal: core.wallReveal).width
        check(abs(engine.petCenter.x - width / 2) < 0.001, "引擎位置与扩展的窗口宽度同步")
        check((bubble.anchor?.y ?? -.infinity) + PetLayout.windowSize(scale: engine.scale) * 0.34
              >= engine.petCenter.y + WallDock.size(scale: engine.scale, reveal: core.wallReveal).height / 2 - 0.01,
              "固定招呼气泡放在包含尾巴的完整造型上方")
        let newerLine = engine.showCanned(.confused, emotion: .curious)
        let hides = bubble.hides
        pointer = CGPoint(x: 700, y: 450)
        tick(0.9)
        check(core.wallReveal < 0.01 && bubble.hides == hides && bubble.lines.last == newerLine,
              "移开只收回身体，不误关后来的聊天气泡")
        core.activity = .idle
        pointer = CGPoint(x: 20, y: 450)
        tick(0.6)
        check(bubble.lines.count == 2 && core.wallReveal > 0.95, "已有气泡与冷却阻止重复招呼")
        engine.fallAsleep(commanded: true)
        tick(0.9)
        check(core.isSleeping && core.wallReveal < 0.01 && engine.wallAttachment == pinned, "睡眠时收回身体，靠近也不被唤醒")
        engine.beginDrag()
        check(core.wallSide == nil && core.wallReveal == 0 && engine.wallAttachment == nil, "拖走清除探身状态，恢复普通造型")

        // 独立引擎验证没有新气泡覆盖时，鼠标移开确实收起本次招呼。
        let secondCore = PetCore()
        let second = PetEngine(core: secondCore, brain: brain, wallAttachment: pinned,
                               screens: { [screen] }, mouseLocation: { pointer })
        let secondBubble = HoverTestBubble()
        second.bubble = secondBubble
        pointer = CGPoint(x: 700, y: 450)
        var secondTime = Date()
        for step in 1...100 {
            if step == 4 { pointer = CGPoint(x: 20, y: 450) }
            if step == 60 { pointer = CGPoint(x: 700, y: 450) }
            secondTime = secondTime.addingTimeInterval(1.0 / 60)
            second.tick(at: secondTime)
        }
        check(secondBubble.lines.count == 1 && secondBubble.hides == 1 && secondCore.wallReveal < 0.02,
              "鼠标移开时仅收起自己的固定招呼气泡")
        print("wall hover: \(checks - failures)/\(checks) OK（模拟鼠标与时钟、无模型与网络）")
        return failures
    }
}

@MainActor
private final class HoverTestBubble: BubbleController {
    var lines: [String] = []
    var hides = 0
    var anchor: CGPoint?
    func show(text: String, above petCenter: CGPoint, petScale: CGFloat) { lines.append(text); anchor = petCenter }
    func update(text: String) {}
    func reposition(above petCenter: CGPoint, petScale: CGFloat) { anchor = petCenter }
    func hide() { hides += 1 }
}
