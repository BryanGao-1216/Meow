import AppKit
import SwiftUI

/// Cute rounded speech bubble with a tail, floating above the pet.
struct BubbleView: View {
    var text: String

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: 13.5, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.32, green: 0.24, blue: 0.18))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .lineLimit(8)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color(red: 1.0, green: 0.985, blue: 0.94))
                        .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(Color(red: 0.88, green: 0.79, blue: 0.66), lineWidth: 1.5)
                )
            BubbleTail()
                .fill(Color(red: 1.0, green: 0.985, blue: 0.94))
                .overlay(BubbleTailBorder().stroke(Color(red: 0.88, green: 0.79, blue: 0.66), lineWidth: 1.5))
                .frame(width: 16, height: 9)
                .offset(y: -1)
        }
        .frame(maxWidth: 250)
        .fixedSize(horizontal: false, vertical: true)
        .padding(6)
    }
}

struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: CGPoint(x: rect.midX - 3, y: rect.midY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX + 3, y: rect.midY))
        p.closeSubpath()
        return p
    }
}

struct BubbleTailBorder: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: CGPoint(x: rect.midX - 3, y: rect.midY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX + 3, y: rect.midY))
        return p
    }
}

@MainActor
final class BubbleWindowController: BubbleController {
    private let panel: NSPanel
    private let hosting: NSHostingView<BubbleView>
    /// Offscreen measurer: with sizingOptions=[] the display hosting view reports
    /// zero fittingSize, so sizes must come from a separate hosting controller.
    private let measurer = NSHostingController(rootView: BubbleView(text: ""))
    private var lastPetCenter: CGPoint = .zero
    private var lastScale: CGFloat = 1
    private var fadeTimer: Timer?

    init() {
        hosting = NSHostingView(rootView: BubbleView(text: ""))
        hosting.sizingOptions = []   // we size the panel ourselves; stop SwiftUI from fighting the cap
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.alphaValue = 0
    }

    func show(text: String, above petCenter: CGPoint, petScale: CGFloat) {
        lastPetCenter = petCenter
        lastScale = petScale
        hosting.rootView = BubbleView(text: text)
        measurer.rootView = hosting.rootView
        layout()
        panel.orderFrontRegardless()
        fadeTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func update(text: String) {
        guard !text.isEmpty else { return }
        hosting.rootView = BubbleView(text: text)
        measurer.rootView = hosting.rootView
        layout()
        if panel.alphaValue < 1 { panel.alphaValue = 1; panel.orderFrontRegardless() }
    }

    func reposition(above petCenter: CGPoint, petScale: CGFloat) {
        lastPetCenter = petCenter
        lastScale = petScale
        if panel.alphaValue > 0 { layout() }
    }

    func hide() {
        fadeTimer?.invalidate()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.panel.alphaValue == 0 { self?.panel.orderOut(nil) }
        })
    }

    private func layout() {
        var size = measurer.sizeThatFits(in: NSSize(width: 264, height: 460))
        size.height = min(max(size.height, 30), 225)   // hard cap: never cover the pet
        size.width = max(size.width, 40)
        // pet head top ≈ center + 0.34 * windowSide (just above the ear tips)
        let headTop = lastPetCenter.y + PetLayout.windowSize(scale: lastScale) * 0.34
        var x = lastPetCenter.x - size.width / 2
        var y = headTop + 2
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(lastPetCenter) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            x = min(max(x, f.minX + 4), f.maxX - size.width - 4)
            // pet near the top of the screen (perched high): show the bubble below it
            if y + size.height > f.maxY - 4 {
                y = lastPetCenter.y - PetLayout.windowSize(scale: lastScale) * 0.36 - size.height
            }
        }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}
