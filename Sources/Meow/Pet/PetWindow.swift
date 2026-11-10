import AppKit
import SwiftUI

/// Interaction debugging: append-only file log, off unless MEOW_DEBUG=1
/// (unified log proved unreliable for this process).
enum DebugLog {
    nonisolated(unsafe) static var enabled =
        ProcessInfo.processInfo.environment["MEOW_DEBUG"] == "1"
    static func write(_ s: String) {
        guard enabled else { return }
        let line = "\(Date()) \(s)\n"
        let url = URL(fileURLWithPath: "/tmp/meow-debug.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }
}

/// Borderless, transparent, always-on-top panel hosting the pet.
final class PetPanel: NSPanel {
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown:
            DebugLog.write("panel sendEvent \(event.type.rawValue) at \(event.locationInWindow)")
        default: break
        }
        super.sendEvent(event)
    }
    init(size: CGFloat) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        title = AppIdentity.name
        isOpaque = false
        // NOT .clear: a fully transparent window is click-through at the window-server
        // level (layer content is never sampled), so no mouse event ever reaches us.
        // An imperceptible 1% alpha keeps the window clickable.
        backgroundColor = NSColor(white: 0, alpha: 0.01)
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    // Borderless windows that can never become key have long-standing quirks where
    // mouse events aren't delivered. .nonactivatingPanel means becoming key still
    // doesn't activate the app, so this is safe.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func place(at center: CGPoint, core: PetCore, scale: CGFloat, container: PetContainerView) {
        let size = PetLayout.renderSize(scale: scale, wallSide: core.wallSide, wallReveal: core.wallReveal)
        if frame.size != size {
            setContentSize(size)
            container.layoutSubtreeIfNeeded()
        }
        setFrameOrigin(CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }
}

/// Handles all mouse interaction: click (poke), double-click (chat), drag (pickup with
/// toss physics), hover strokes (petting), right-click (menu).
final class PetContainerView: NSView {
    weak var engine: PetEngine?
    var menuProvider: (() -> NSMenu)?
    var openChat: (() -> Void)?
    var openMail: (() -> Void)?
    private let core: PetCore
    private var pressedLetter = false

    private var tracking: NSTrackingArea?

    // drag state
    private var mouseDownAt: CGPoint?       // screen coords
    private var mouseDownWindowOrigin: CGPoint = .zero
    private var dragging = false
    private var grabOffset = CGVector(dx: 0, dy: 0)   // petCenter - mouse
    private var recentDragSamples: [(t: TimeInterval, p: CGPoint)] = []

    // petting stroke detection
    private var strokeSamples: [(t: TimeInterval, x: CGFloat)] = []

    // click vs double-click disambiguation
    private var pendingPoke: DispatchWorkItem?
    private var pokeRevision = 0

    private func cancelPendingPoke() {
        pokeRevision &+= 1
        pendingPoke?.cancel()
        pendingPoke = nil
    }

    init(core: PetCore) {
        self.core = core
        super.init(frame: .zero)
        let host = NSHostingView(rootView: PetView(core: core))
        // 窗口由引擎按贴墙/完整造型设置尺寸，不能被上一帧的 SwiftUI 固定尺寸锁住。
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The app never activates (accessory + nonactivating panel), so EVERY click is a
    /// "first mouse". Without this, no mouse events are ever delivered to the pet.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self)
        addTrackingArea(t)
        tracking = t
    }

    /// Only the cat's body is clickable; transparent margins pass clicks through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // view coords: origin bottom-left; PetLayout.hitTest expects top-left
        let flipped = CGPoint(x: local.x, y: bounds.height - local.y)
        if core.unreadLetters > 0, PetLayout.letterHitRect(size: bounds.size, wallSide: core.wallSide, reveal: core.wallReveal).contains(flipped) { return self }
        if engine?.core.wallSide != nil {
            // 贴墙时窗口本身已收紧，小脸周围的一小块区域可拖拽。
            return bounds.insetBy(dx: 2, dy: 2).contains(local) ? self : nil
        }
        return PetLayout.hitTest(flipped, windowSide: bounds.width) ? self : nil
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        DebugLog.write("view mouseDown")
        let screenPoint = NSEvent.mouseLocation
        mouseDownAt = screenPoint
        mouseDownWindowOrigin = window?.frame.origin ?? .zero
        dragging = false
        pressedLetter = isOnLetter(convert(event.locationInWindow, from: nil))
        if pressedLetter || event.clickCount >= 2 { cancelPendingPoke() }
        recentDragSamples = [(ProcessInfo.processInfo.systemUptime, screenPoint)]
        if let engine {
            grabOffset = CGVector(
                dx: engine.petCenter.x - screenPoint.x,
                dy: engine.petCenter.y - screenPoint.y)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownAt, let engine else { return }
        let p = NSEvent.mouseLocation
        if !dragging {
            if hypot(p.x - start.x, p.y - start.y) > 7 {
                dragging = true
                cancelPendingPoke()
                DebugLog.write("view drag began")
                engine.beginDrag()
            } else {
                return
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        recentDragSamples.append((now, p))
        recentDragSamples.removeAll { now - $0.t > 0.14 }
        engine.dragTo(CGPoint(x: p.x + grabOffset.dx, y: p.y + grabOffset.dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownAt = nil }
        guard let engine else { return }
        if dragging {
            dragging = false
            // release velocity from recent samples
            var v = CGVector.zero
            if recentDragSamples.count >= 2,
                let first = recentDragSamples.first, let last = recentDragSamples.last,
                last.t - first.t > 0.005
            {
                let dt = last.t - first.t
                v = CGVector(dx: (last.p.x - first.p.x) / dt, dy: (last.p.y - first.p.y) / dt)
            }
            engine.endDrag(velocity: v, pointer: NSEvent.mouseLocation)
            return
        }
        if pressedLetter {
            pressedLetter = false
            cancelPendingPoke()
            if isOnLetter(convert(event.locationInWindow, from: nil)) { openMail?() }
            return
        }
        if event.clickCount >= 2 {
            cancelPendingPoke()
            openChat?()
            return
        }
        // delay the poke slightly to see if a double-click follows
        cancelPendingPoke()
        let revision = pokeRevision
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pokeRevision == revision else { return }
            self.pendingPoke = nil
            self.engine?.pokeTap()
        }
        pendingPoke = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    private func isOnLetter(_ point: CGPoint) -> Bool {
        core.unreadLetters > 0 && PetLayout.letterHitRect(size: bounds.size, wallSide: core.wallSide, reveal: core.wallReveal)
            .contains(CGPoint(x: point.x, y: bounds.height - point.y))
    }

    override func mouseMoved(with event: NSEvent) {
        // stroke detection: direction reversals of horizontal movement over the cat
        let now = ProcessInfo.processInfo.systemUptime
        let x = NSEvent.mouseLocation.x
        strokeSamples.append((now, x))
        strokeSamples.removeAll { now - $0.t > 1.3 }
        guard strokeSamples.count >= 6 else { return }

        var reversals = 0
        var totalDist: CGFloat = 0
        var lastDir: CGFloat = 0
        for i in 1..<strokeSamples.count {
            let dx = strokeSamples[i].x - strokeSamples[i - 1].x
            totalDist += abs(dx)
            let dir: CGFloat = dx > 0.5 ? 1 : (dx < -0.5 ? -1 : 0)
            if dir != 0 {
                if lastDir != 0 && dir != lastDir { reversals += 1 }
                lastDir = dir
            }
        }
        if reversals >= 2 && totalDist > 70 {
            strokeSamples.removeAll()
            engine?.petStroke()
        }
    }

    override func mouseExited(with event: NSEvent) {
        strokeSamples.removeAll()
    }
}
