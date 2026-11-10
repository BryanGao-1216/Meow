import AppKit
import SwiftUI
import MeowMailbox

/// 信箱与抱信造型实窗检查；样例、身份均临时，不启动网络或读取钥匙串。
@MainActor
enum MailboxPreview {
    static func render(outDir: String) async -> Int {
        NSApplication.shared.setActivationPolicy(.accessory)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("meow-mail-ui-" + UUID().uuidString)
        let out = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures += 1; print("mail render FAIL: \(label)") } }
        var book = MailBook(); book.enabled = true
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        book.localDeviceID = b; book.peer = MailPeer(deviceID: a, ticket: "endpoint-preview", name: "另一只测试 Meow")
        let first = MailLetter(senderID: a, recipientID: b, body: "给主人的一封信：\n\n今天也有认真陪你工作喵。\n记得好好吃饭，忙完也来看看我！\n\n—— 另一台 Mac 上的 Meow 💌", createdAt: Date())
        do {
            _ = try book.receive(first, authenticatedID: a, now: Date())
            _ = try book.receive(MailLetter(senderID: a, recipientID: b, body: "还有一封问候，等你慢慢拆开。", createdAt: Date().addingTimeInterval(1)), authenticatedID: a, now: Date())
            book.enabled = false
            book.localPairingCode = try MailDeviceCode(deviceID: b, ticket: "endpoint-preview").encoded()
            try book.write(to: temp.appendingPathComponent("mail.json"))
        } catch { print(error.localizedDescription); return 1 }
        let mailbox = MailboxController(storageURL: temp.appendingPathComponent("mail.json"), transport: OfflineMailTransport(), key: { fatalError("实窗样例不得读取真实身份") })
        mailbox.select(first.id)
        let mailboxWindow = MailboxWindowController(mailbox: mailbox)
        defer { mailboxWindow.panel.close(); mailbox.shutdown() }
        mailboxWindow.show(activate: false)
        func capture(_ view: NSView, window: NSWindow, name: String) async -> NSBitmapImageRep? {
            view.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(240))
            view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: out.appendingPathComponent(name + ".png")) }
            return rep
        }
        if let view = mailboxWindow.panel.contentView {
            check(await capture(view, window: mailboxWindow.panel, name: "mailbox-window") != nil && view.bounds.width >= 700, "信箱窗口可展示列表与信件正文")
        }
        mailbox.updateBindingDraft(localName: "书房里的 Meow", peerName: "另一只测试 Meow")
        do { try mailbox.flushBindingDraft() } catch { check(false, "绑定样例可以保存") }
        let restored = MailboxController(storageURL: mailbox.fileURL, transport: OfflineMailTransport(), key: { fatalError("绑定实窗不得读取真实身份") })
        let bindingPanel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 560, height: 580), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        bindingPanel.appearance = NSAppearance(named: .aqua)
        let bindingHost = NSHostingView(rootView: MailBindingView(mailbox: restored)); bindingHost.sizingOptions = []
        bindingPanel.contentView = bindingHost; bindingPanel.setContentSize(CGSize(width: 560, height: 620)); bindingPanel.center(); bindingPanel.orderFrontRegardless()
        check(restored.bindingDraft == mailbox.bindingDraft && !restored.bindingDraft.peerCode.isEmpty && !restored.deviceCode.isEmpty,
              "重开绑定窗口回显本机名、对方名与完整设备码")
        check(await capture(bindingHost, window: bindingPanel, name: "mailbox-binding") != nil, "绑定窗口的实际布局可以完整捕获")
        bindingPanel.close(); restored.shutdown()
        let core = PetCore(), brain = Brain(loadPersistedHistory: false)
        let engine = PetEngine(core: core, brain: brain)
        let panel = PetPanel(size: PetLayout.windowSize(scale: 1))
        let container = PetContainerView(core: core); container.engine = engine; panel.contentView = container
        var clicked = 0; container.openMail = { clicked += 1 }
        let frame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1400, height: 900)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        panel.orderFrontRegardless()
        defer { panel.close() }
        func redPixels(_ rep: NSBitmapImageRep, rect: CGRect, size: CGSize) -> Int {
            let loX = max(0, Int(rect.minX / size.width * CGFloat(rep.pixelsWide))), hiX = min(rep.pixelsWide, Int(ceil(rect.maxX / size.width * CGFloat(rep.pixelsWide))))
            let loY = max(0, Int(rect.minY / size.height * CGFloat(rep.pixelsHigh))), hiY = min(rep.pixelsHigh, Int(ceil(rect.maxY / size.height * CGFloat(rep.pixelsHigh))))
            guard loX < hiX, loY < hiY else { return 0 }
            var count = 0
            for y in loY..<hiY { for x in loX..<hiX {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5,
                   c.redComponent > 0.75, c.greenComponent < 0.5, c.blueComponent < 0.55 { count += 1 }
            } }
            return count
        }
        func heartCenter(_ rep: NSBitmapImageRep, rect: CGRect, size: CGSize) -> CGPoint? {
            let loX = max(0, Int(rect.minX / size.width * CGFloat(rep.pixelsWide))), hiX = min(rep.pixelsWide, Int(ceil(rect.maxX / size.width * CGFloat(rep.pixelsWide))))
            let loY = max(0, Int(rect.minY / size.height * CGFloat(rep.pixelsHigh))), hiY = min(rep.pixelsHigh, Int(ceil(rect.maxY / size.height * CGFloat(rep.pixelsHigh))))
            guard loX < hiX, loY < hiY else { return nil }
            var totalX = 0.0, totalY = 0.0, count = 0.0
            for y in loY..<hiY { for x in loX..<hiX {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5,
                   c.redComponent > 0.75, c.greenComponent < 0.5, c.blueComponent < 0.55 {
                    totalX += Double(x); totalY += Double(y); count += 1
                }
            } }
            guard count > 5 else { return nil }
            return CGPoint(x: totalX / count * size.width / CGFloat(rep.pixelsWide),
                           y: totalY / count * size.height / CGFloat(rep.pixelsHigh))
        }
        for scale: CGFloat in [1, 0.5, 0.8, 1.3] {
            for side: WallSide? in [nil, .left, .right] {
                core.wallSide = side; core.wallReveal = side == nil ? 0 : 1; core.unreadLetters = 1
                panel.place(at: center, core: core, scale: scale, container: container)
                let name = "letter-\(side?.rawValue ?? "desktop")-\(scale)"
                let rect = PetLayout.letterHitRect(size: container.bounds.size, wallSide: side, reveal: core.wallReveal)
                var centers: [CGPoint] = []
                if let rep = await capture(container, window: panel, name: name) {
                    check(redPixels(rep, rect: rect, size: container.bounds.size) > 5, "\(name) · 怀中真实 emoji 信封完整可见")
                    if let heart = heartCenter(rep, rect: rect, size: container.bounds.size) { centers.append(heart) }
                } else { check(false, "\(name) · 可以捕获真实窗口") }
                let point = CGPoint(x: rect.midX, y: container.bounds.height - rect.midY)
                check(container.hitTest(point) === container, "\(name) · 信封命中区域可点击")
                let before = clicked
                if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                   let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.1, windowNumber: panel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) {
                    container.mouseDown(with: down); container.mouseUp(with: up)
                }
                check(clicked == before + 1 && core.activity != .drag, "\(name) · 单击展开信，不触发戳猫或聊天")
                let press = centers.first ?? CGPoint(x: rect.midX, y: rect.midY)
                let pressPoint = CGPoint(x: press.x, y: container.bounds.height - press.y)
                let beforeMotion = clicked
                if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: pressPoint, modifierFlags: [], timestamp: 1, windowNumber: panel.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1) {
                    container.mouseDown(with: down)
                }
                for phase in 1...2 {
                    if let rep = await capture(container, window: panel, name: name + "-wave-\(phase)"),
                       let heart = heartCenter(rep, rect: rect, size: container.bounds.size) { centers.append(heart) }
                }
                if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: pressPoint, modifierFlags: [], timestamp: 1.6, windowNumber: panel.windowNumber, context: nil, eventNumber: 4, clickCount: 1, pressure: 0) {
                    container.mouseUp(with: up)
                }
                let k = PetLayout.windowSize(scale: scale) / PetLayout.designSide
                let travel = (centers.map(\.y).max() ?? 0) - (centers.map(\.y).min() ?? 0)
                check(centers.count == 3 && travel > 1.5 * k, "\(name) · 连续真实画面中信封上下移动")
                check(clicked == beforeMotion + 1 && core.activity != .drag, "\(name) · 按住时信继续晃动，原位置松开仍可拆信")
            }
        }
        core.unreadLetters = 0
        if let rep = await capture(container, window: panel, name: "letter-read") {
            let rect = PetLayout.letterHitRect(size: container.bounds.size, wallSide: core.wallSide, reveal: core.wallReveal)
            check(redPixels(rep, rect: rect, size: container.bounds.size) == 0, "读完后信封和未读角标消失")
        }
        print("mail render: \(checks - failures)/\(checks) OK（真实窗口与鼠标事件，独立样例，无网络）")
        return failures + (await TouchInteractionSelfTest.mouseEvents())
    }
}
