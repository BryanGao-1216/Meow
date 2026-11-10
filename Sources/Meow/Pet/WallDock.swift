import AppKit

enum WallSide: String, Codable {
    case left, right
}

/// 屏幕快照也供几何测试使用，不依赖测试机器的显示器布局。
struct WallScreen {
    var id: String
    var frame: CGRect
    var visibleFrame: CGRect

    @MainActor static var current: [WallScreen] {
        NSScreen.screens.map {
            WallScreen(id: ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "main",
                       frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
    }
}

struct WallAttachment: Codable, Equatable {
    var side: WallSide
    var screenID: String
    /// 以可用区域中的相对高度保存，分辨率和宠物尺寸改变后仍可见。
    var heightFraction: Double
}

enum WallDock {
    static let topY: CGFloat = 26
    static let tuckedCutoff: CGFloat = 108 // 截止到眼睛下方；嘴巴从 y=111 开始，留在墙后。
    static let revealedCutoff: CGFloat = 176
    static let designHeight: CGFloat = 132
    // 尾巴会超出身体侧面，探身时沿尾巴方向扩展画布，容纳最宽的摇尾幅度。
    private static let tailClearance: CGFloat = 44

    static func cutoff(reveal: Double) -> CGFloat {
        tuckedCutoff + (revealedCutoff - tuckedCutoff) * min(1.06, max(0, reveal))
    }

    static func designSize(reveal: Double = 0) -> CGSize {
        CGSize(width: cutoff(reveal: reveal) - topY,
               height: designHeight + tailClearance * min(1, max(0, reveal)))
    }

    static func size(scale: CGFloat, reveal: Double = 0) -> CGSize {
        let design = designSize(reveal: reveal)
        let k = PetLayout.windowSize(scale: scale) / PetLayout.designSide
        // AppKit 会将窗口尺寸向上取整，几何和绘图使用同一尺寸，避免每帧重复调整。
        return CGSize(width: ceil(design.width * k), height: ceil(design.height * k))
    }

    static func screen(at point: CGPoint, in screens: [WallScreen]) -> WallScreen? {
        screens.first { $0.frame.contains(point) } ?? screens.min {
            distance(point, to: $0.frame) < distance(point, to: $1.frame)
        }
    }

    /// 只在拖拽松手时吸附。相邻显示器的接缝仍可穿过，不当作墙。
    static func attachment(center: CGPoint, pointer: CGPoint?, scale: CGFloat,
                           screens: [WallScreen]) -> WallAttachment? {
        let anchor = pointer ?? center
        guard let screen = screen(at: anchor, in: screens) else { return nil }
        let f = screen.visibleFrame
        let reach = 58 * scale + 16  // 身体边缘接近墙，或鼠标直接抵到墙边
        let candidates: [(WallSide, CGFloat)] = [(.left, f.minX), (.right, f.maxX)]
        let side = candidates.filter { side, x in
            let near = abs(center.x - x) <= reach || (pointer.map { abs($0.x - x) <= 18 } ?? false)
            return near && exposed(side, on: screen, at: center.y, screens: screens)
        }.min { abs(center.x - $0.1) < abs(center.x - $1.1) }?.0
        guard let side else { return nil }
        let half = size(scale: scale).height / 2 + 6
        let lo = f.minY + half, hi = max(lo, f.maxY - half)
        let fraction = hi > lo ? (center.y - lo) / (hi - lo) : 0.5
        return WallAttachment(side: side, screenID: screen.id, heightFraction: min(1, max(0, fraction)))
    }

    static func center(for attachment: WallAttachment, screen: WallScreen, scale: CGFloat,
                       reveal: Double = 0, bounce: Double = 0) -> CGPoint {
        let f = screen.visibleFrame
        let size = size(scale: scale, reveal: reveal)
        let tuckedSize = Self.size(scale: scale)
        let tuckedLo = f.minY + tuckedSize.height / 2 + 6
        let tuckedHi = max(tuckedLo, f.maxY - tuckedSize.height / 2 - 6)
        let lo = f.minY + size.height / 2 + 6
        let hi = max(lo, f.maxY - size.height / 2 - 6)
        let fraction = attachment.heightFraction.isFinite ? min(1, max(0, attachment.heightFraction)) : 0.5
        // 左墙的尾巴朝下，右墙朝上；只向尾巴一侧扩展，保持小脸在原来的高度。
        let extra = (size.height - tuckedSize.height) / 2
        let y = tuckedLo + (tuckedHi - tuckedLo) * fraction + bounce * scale
            + (attachment.side == .left ? -extra : extra)
        return CGPoint(x: attachment.side == .left ? f.minX + size.width / 2 : f.maxX - size.width / 2,
                       y: min(hi, max(lo, y)))
    }

    static func hoverDistance(pointer: CGPoint, attachment: WallAttachment, screen: WallScreen, scale: CGFloat) -> CGFloat {
        // 用收起时的区域判断距离，不随探身后的窗口尺寸移动，防止反复进出。
        let center = center(for: attachment, screen: screen, scale: scale)
        let size = size(scale: scale)
        let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        return distance(pointer, to: rect)
    }

    static func exposed(_ side: WallSide, on screen: WallScreen, at y: CGFloat, screens: [WallScreen]) -> Bool {
        let x = side == .left ? screen.frame.minX : screen.frame.maxX
        let beyond = CGPoint(x: x + (side == .left ? -1 : 1), y: y)
        return !screens.contains { $0.id != screen.id && $0.frame.contains(beyond) }
    }

    private static func distance(_ point: CGPoint, to frame: CGRect) -> CGFloat {
        hypot(max(frame.minX - point.x, 0, point.x - frame.maxX),
              max(frame.minY - point.y, 0, point.y - frame.maxY))
    }
}

extension PetAction {
    /// 只有主人的明确移动指令才能离墙；模型随手加的动作标签不能解除固定。
    var leavesWall: Bool {
        ActionLibrary.entry(self).leavesWall
    }
}
