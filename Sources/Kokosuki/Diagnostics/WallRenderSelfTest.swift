import AppKit

/// 检查真正的 NSHostingView 在正常/贴墙之间切换后的像素，而非只验证窗口外框。
/// 独立临时窗口，不启动引擎、模型、联网或读写主人数据。
@MainActor
enum WallRenderSelfTest {
    static func run(outDir: String) async -> Int {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let core = PetCore()
        let panel = PetPanel(size: PetLayout.windowSize(scale: 1))
        panel.title = "Meow · 渲染检查"
        let container = PetContainerView(core: core)
        panel.contentView = container
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let center = CGPoint(x: screen.midX, y: screen.midY)
        panel.place(at: center, core: core, scale: 1, container: container)
        panel.orderFrontRegardless()
        defer { panel.close() }
        let directory = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var failures = 0, checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1; print("wall render FAIL: \(label)") }
        }
        func capture(_ name: String) async -> NSBitmapImageRep? {
            container.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(220))
            container.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return nil }
            container.cacheDisplay(in: container.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent(name + ".png"))
            }
            return rep
        }
        func inkCount(_ rep: NSBitmapImageRep, rect: CGRect, pink: Bool = false, fur: Bool = false, belly: Bool = false) -> Int {
            let loX = max(0, Int(rect.minX * CGFloat(rep.pixelsWide))), hiX = min(rep.pixelsWide, Int(ceil(rect.maxX * CGFloat(rep.pixelsWide))))
            let loY = max(0, Int(rect.minY * CGFloat(rep.pixelsHigh))), hiY = min(rep.pixelsHigh, Int(ceil(rect.maxY * CGFloat(rep.pixelsHigh))))
            guard loX < hiX, loY < hiY else { return 0 }
            var count = 0
            for y in loY..<hiY {
                for x in loX..<hiX {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                    if belly {
                        if color.redComponent > 0.97 && color.greenComponent > 0.95 && color.blueComponent > 0.88 { count += 1 }
                    } else if fur {
                        if color.redComponent > 0.85 && color.greenComponent > 0.80 && color.blueComponent > 0.6 && color.blueComponent < 0.96 { count += 1 }
                    } else if pink {
                        if color.redComponent > 0.85 && color.greenComponent > 0.45 && color.greenComponent < 0.85 && color.blueComponent > 0.55 { count += 1 }
                    } else if color.redComponent < 0.6 && color.greenComponent < 0.5 && color.blueComponent < 0.45 { count += 1 }
                }
            }
            return count
        }
        func inkMask(_ rep: NSBitmapImageRep, rect: CGRect) -> [Bool] {
            let loX = max(0, Int(rect.minX * CGFloat(rep.pixelsWide))), hiX = min(rep.pixelsWide, Int(ceil(rect.maxX * CGFloat(rep.pixelsWide))))
            let loY = max(0, Int(rect.minY * CGFloat(rep.pixelsHigh))), hiY = min(rep.pixelsHigh, Int(ceil(rect.maxY * CGFloat(rep.pixelsHigh))))
            guard loX < hiX, loY < hiY else { return [] }
            return (loY..<hiY).flatMap { y in
                (loX..<hiX).map { x in
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return c.alphaComponent > 0.5 && c.redComponent < 0.6 && c.greenComponent < 0.5 && c.blueComponent < 0.45
                }
            }
        }
        _ = await capture("normal-before")
        for scale: CGFloat in [1, 0.5, 0.8, 1.3] {
            for side: WallSide in [.left, .right] {
                core.wallSide = side
                core.wallReveal = 0
                core.blink = 0
                core.earTwitch = 0
                core.emotion = .neutral
                let size = WallDock.size(scale: scale)
                let edgeCenter = CGPoint(x: side == .left ? screen.minX + size.width / 2 : screen.maxX - size.width / 2,
                                         y: center.y)
                panel.place(at: edgeCenter, core: core, scale: scale, container: container)
                check(abs((side == .left ? panel.frame.minX - screen.minX : panel.frame.maxX - screen.maxX)) < 0.5,
                      "\(side) \(scale) · 窗口正确停在屏幕侧边")
                guard let rep = await capture("\(side)-\(scale)") else {
                    check(false, "可以捕获真实窗口")
                    continue
                }
                for y: CGFloat in [43, 89] {
                    let x: CGFloat = side == .left ? 12 : 70
                    let eye = CGRect(x: (x - 10) / 82, y: (y - 11) / 132, width: 20 / 82.0, height: 22 / 132.0)
                    check(inkCount(rep, rect: eye) > 4, "\(side) \(scale) · 眼睛 \(y) 完整可见")
                }
                for y: CGFloat in [40, 94] {
                    let x: CGFloat = side == .left ? 58 : 24
                    let ear = CGRect(x: (x - 14) / 82, y: (y - 13) / 132, width: 28 / 82.0, height: 26 / 132.0)
                    check(inkCount(rep, rect: ear, pink: true) > 6, "\(side) \(scale) · 耳朵 \(y) 未被裁切")
                }
                let cheekX: CGFloat = side == .left ? 28 : 54
                let cheek = CGRect(x: (cheekX - 6) / 82, y: 60 / 132.0, width: 12 / 82.0, height: 12 / 132.0)
                check(inkCount(rep, rect: cheek, fur: true) > 6, "\(side) \(scale) · 眼睛和耳朵之间有连续的小脸")
                let edge = CGRect(x: side == .left ? 0 : 79 / 82.0, y: 60 / 132.0, width: 3 / 82.0, height: 12 / 132.0)
                check(inkCount(rep, rect: edge) == 0 && inkCount(rep, rect: edge, fur: true) > 6,
                      "\(side) \(scale) · 墙沿只有脸部毛色，嘴巴藏在屏幕外")
                core.blink = 1
                let closed = await capture("\(side)-\(scale)-blink")
                check(closed?.tiffRepresentation != rep.tiffRepresentation, "\(side) \(scale) · 贴墙后仍刷新眨眼")
                core.blink = 0
                core.earTwitch = 1
                let twitch = await capture("\(side)-\(scale)-ear")
                check(twitch?.tiffRepresentation != rep.tiffRepresentation, "\(side) \(scale) · 贴墙后仍刷新耳朵动作")
                core.earTwitch = 0
                core.emotion = .curious // 实际拖到墙边时会先保持这个表情。
                if let curious = await capture("\(side)-\(scale)-curious") {
                    for y: CGFloat in [43, 89] {
                        let x: CGFloat = side == .left ? 12 : 70
                        let eye = CGRect(x: (x - 10) / 82, y: (y - 11) / 132, width: 20 / 82.0, height: 22 / 132.0)
                        check(inkCount(curious, rect: eye) > 4, "\(side) \(scale) · 刚贴墙时的好奇小脸完整")
                    }
                } else { check(false, "可以捕获刚贴墙的表情") }

                core.wallReveal = 1
                core.emotion = .happy
                core.stats.happiness = 90 // 用最大的摇尾幅度检查裁切边缘。
                let expanded = WallDock.size(scale: scale, reveal: 1)
                let height = WallDock.designSize(reveal: 1).height
                let offsetY: CGFloat = side == .right ? height - 132 : 0
                let expandedCenter = CGPoint(x: side == .left ? screen.minX + expanded.width / 2 : screen.maxX - expanded.width / 2,
                                             y: center.y + (side == .left ? -1 : 1) * (expanded.height - size.height) / 2)
                panel.place(at: expandedCenter, core: core, scale: scale, container: container)
                check(panel.frame.size == expanded && abs(side == .left ? panel.frame.minX - screen.minX : panel.frame.maxX - screen.maxX) < 0.5,
                      "\(side) \(scale) · 探身扩大窗口并保持贴墙")
                if let hello = await capture("\(side)-\(scale)-hello") {
                    let mouthX: CGFloat = side == .left ? 62 : 88
                    check(inkCount(hello, rect: CGRect(x: (mouthX - 8) / 150, y: (58 + offsetY) / height, width: 16 / 150.0, height: 16 / height)) > 4,
                          "\(side) \(scale) · 探身后嘴巴可见")
                    let bellyX: CGFloat = side == .left ? 37 : 113
                    check(inkCount(hello, rect: CGRect(x: (bellyX - 6) / 150, y: (60 + offsetY) / height, width: 12 / 150.0, height: 12 / height), belly: true) > 6,
                          "\(side) \(scale) · 探身后肚子可见")
                    let pawX: CGFloat = side == .left ? 14 : 136
                    for y: CGFloat in [48, 84] {
                        check(inkCount(hello, rect: CGRect(x: (pawX - 10) / 150, y: (y - 12 + offsetY) / height, width: 20 / 150.0, height: 24 / height)) > 4,
                              "\(side) \(scale) · 探身后爪子 \(y) 可见")
                    }
                    // 只检查身体与胡须范围以外的尾巴区域，避免身体轮廓冒充尾巴。
                    let tail = CGRect(x: (side == .left ? 36 : 72) / 150.0,
                                      y: (side == .left ? 130 : 4) / height, width: 44 / 150.0, height: 42 / height)
                    check(inkCount(hello, rect: tail) > 1 && inkCount(hello, rect: tail, fur: true) > 6,
                          "\(side) \(scale) · 身体以外的完整尾巴可见")
                    let nextTail = await capture("\(side)-\(scale)-tail-wag")
                    let lastTail = await capture("\(side)-\(scale)-tail-wag-next")
                    let mask = inkMask(hello, rect: tail)
                    check(nextTail.map { inkMask($0, rect: tail) != mask } == true || lastTail.map { inkMask($0, rect: tail) != mask } == true,
                          "\(side) \(scale) · 探身时尾巴持续摇动")
                    let margin = CGRect(x: 36 / 150.0, y: side == .left ? (height - 3) / height : 0,
                                        width: 80 / 150.0, height: 3 / height)
                    check([hello, nextTail, lastTail].compactMap { $0 }.allSatisfy { inkCount($0, rect: margin) == 0 && inkCount($0, rect: margin, fur: true) == 0 },
                          "\(side) \(scale) · 摇尾时尾尖与窗口边缘保留空隙")
                } else { check(false, "可以捕获探身后的窗口") }
                core.wallReveal = 0
                core.emotion = .neutral
                panel.place(at: edgeCenter, core: core, scale: scale, container: container)
                if let tucked = await capture("\(side)-\(scale)-tucked") {
                    check(panel.frame.size == size && inkCount(tucked, rect: edge) == 0 && inkCount(tucked, rect: cheek, fur: true) > 6,
                          "\(side) \(scale) · 收回后恢复上半张脸，无嘴巴残影")
                } else { check(false, "可以捕获收回后的窗口") }
            }
            core.wallSide = nil
            core.wallReveal = 0
            core.emotion = .neutral
            panel.place(at: center, core: core, scale: scale, container: container)
            if let rep = await capture("normal-\(scale)") {
                // 完整造型中央的面部必须恢复，不能残留紧凑窗口的裁切内容。
                check(inkCount(rep, rect: CGRect(x: 0.30, y: 0.40, width: 0.4, height: 0.16)) > 10,
                      "\(scale) · 拖离墙后完整面部恢复")
            } else { check(false, "可以捕获恢复后的窗口") }
        }
        print("wall render: \(checks - failures)/\(checks) OK（真实 NSHostingView、无模型与网络）")
        return failures
    }
}
