import AppKit
import CoreGraphics

/// A standable surface: the top edge of someone else's window.
struct Platform: Equatable {
    var id: CGWindowID
    var y: CGFloat        // Cocoa y of the window's top edge
    var minX: CGFloat
    var maxX: CGFloat

    func contains(x: CGFloat) -> Bool { x >= minX && x <= maxX }
}

/// Tracks other apps' windows so the cat can jump onto them, walk along their
/// tops, and ride them when they move. Uses only public window-bounds info
/// (no screen recording / accessibility permission required).
@MainActor
final class PlatformTracker {
    private(set) var platforms: [Platform] = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Cocoa <-> CG conversion uses the primary display height.
    private var primaryHeight: CGFloat {
        (NSScreen.screens.first?.frame.height ?? 1080)
    }

    func refresh() {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            platforms = []
            return
        }
        let h = primaryHeight
        var result: [Platform] = []
        var occluders: [CGRect] = []   // frontmost-first bounds of normal windows

        for w in list {
            // parse via NSNumber to survive CFNumber bridging quirks
            guard let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.intValue,
                pid != Int(ownPID),
                (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.5,
                let b = w[kCGWindowBounds as String] as? [String: Any],
                let x = (b["X"] as? NSNumber).map({ CGFloat($0.doubleValue) }),
                let y = (b["Y"] as? NSNumber).map({ CGFloat($0.doubleValue) }),
                let width = (b["Width"] as? NSNumber).map({ CGFloat($0.doubleValue) }),
                let height = (b["Height"] as? NSNumber).map({ CGFloat($0.doubleValue) }),
                let id = (w[kCGWindowNumber as String] as? NSNumber).map({ CGWindowID($0.uint32Value) })
            else { continue }

            let rect = CGRect(x: x, y: y, width: width, height: height)
            defer { occluders.append(rect) }

            guard width >= 220, height >= 120 else { continue }
            let cocoaTop = h - y
            // skip tops jammed against the menu bar or below usable height
            guard y > 40 else { continue }

            // occlusion: sample 3 points just below the top edge; usable if any is visible
            let inset: CGFloat = 30
            let samples = [x + inset, x + width / 2, x + width - inset]
                .map { CGPoint(x: $0, y: y + 8) }
            let visibleSamples = samples.filter { p in
                !occluders.contains { $0.contains(p) }
            }
            guard !visibleSamples.isEmpty else { continue }

            // narrow the platform to the visible span (approximate: use visible samples' extremes)
            let minX = visibleSamples.map(\.x).min()! - inset + 10
            let maxX = visibleSamples.map(\.x).max()! + inset - 10
            guard maxX - minX > 90 else { continue }

            result.append(Platform(id: id, y: cocoaTop, minX: minX, maxX: maxX))
        }
        platforms = result
    }

    func platform(withID id: CGWindowID) -> Platform? {
        platforms.first { $0.id == id }
    }

    /// Highest platform whose top the pet (descending at x, feet at feetY) is crossing.
    func landingPlatform(x: CGFloat, feetY: CGFloat, previousFeetY: CGFloat) -> Platform? {
        platforms
            .filter { $0.contains(x: x) }
            .filter { p in previousFeetY >= p.y - 2 && feetY <= p.y + 4 }
            .max(by: { $0.y < $1.y })
    }

    /// Platforms reachable by a jump from the given surface height.
    /// Cartoon physics: the little sprite can leap almost a full screen.
    func reachable(from surfaceY: CGFloat, maxRise: CGFloat = 950) -> [Platform] {
        platforms.filter { $0.y > surfaceY + 40 && $0.y < surfaceY + maxRise }
    }
}
