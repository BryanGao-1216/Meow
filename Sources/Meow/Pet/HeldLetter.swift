import Foundation
import CoreGraphics

/// 信封、抓信的前爪和角标使用同一变换；点击范围覆盖整轮晃动，避免按下后信跑走。
enum HeldLetter {
    static let period: TimeInterval = 1.5
    static let contentBounds = CGRect(x: 74, y: 113, width: 68, height: 42)
    // 包含转动、左右贴墙时的上下移动，以及朝向翻转、呼吸和走路的余量。
    static let hitBounds = CGRect(x: 48, y: 94, width: 104, height: 72)

    static func transform(at time: TimeInterval, wallSide: WallSide?, sleeping: Bool) -> CGAffineTransform {
        let phase = time * 2 * .pi / period
        let sway = CGFloat(sin(phase)) * (sleeping ? 2 : 7)
        let dx: CGFloat = wallSide.map { $0 == .left ? sway : -sway } ?? 0
        let dy: CGFloat = wallSide == nil ? sway - 4 : -4
        let angle = CGFloat(sin(phase + .pi / 5)) * .pi / (sleeping ? 180 : 60)
        // 贴墙的猫旋转了 90°，沿本地横轴移动，屏幕上仍然是上下晃。
        return CGAffineTransform(translationX: 100 + dx, y: 138 + dy)
            .rotated(by: angle).translatedBy(x: -100, y: -138)
    }
}
