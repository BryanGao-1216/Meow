import Foundation

/// 贴墙的局部探身动画，不解除固定、不调用模型。进出阈值分开，避免边缘反复抖动。
struct WallHover {
    static let greetings = [
        "探头！主人，是来找我的吗？",
        "抓到你啦，陪我玩一小会儿喵～",
        "我在墙边乖乖待着呢，喵！",
        "嘿嘿，你一靠近我就知道啦。",
    ]
    private(set) var isNear = false
    private(set) var reveal: Double = 0
    private(set) var bounce: Double = 0
    private var velocity = 0.0
    private var armed = false
    private var nearSince: Date?
    private var enteredAt = Date.distantPast
    private var lastGreeting = Date.distantPast
    private var greetingIndex = 0

    mutating func reset() {
        isNear = false
        reveal = 0
        bounce = 0
        velocity = 0
        armed = false
        nearSince = nil
        enteredAt = .distantPast
    }

    mutating func update(distance: CGFloat, scale: CGFloat, enabled: Bool, canGreet: Bool,
                         now: Date, dt: TimeInterval, forceReveal: Bool = false) -> String? {
        let enter = max(45, 60 * scale)
        let leave = max(80, 110 * scale)
        var greeting: String?
        if !enabled {
            isNear = false
            nearSince = nil
            armed = false
        } else if distance > leave {
            isNear = false
            nearSince = nil
            armed = true // 刚拖到墙边时鼠标就在 Meow 身上，先移开一次才算新的靠近。
        } else if !isNear && armed && distance <= enter {
            if nearSince == nil { nearSince = now }
            if now.timeIntervalSince(nearSince!) >= 0.12 {
                isNear = true
                armed = false
                enteredAt = now
                nearSince = nil
                if canGreet && now.timeIntervalSince(lastGreeting) >= 25 {
                    greeting = Self.greetings[greetingIndex % Self.greetings.count]
                    greetingIndex += 1
                    lastGreeting = now
                }
            }
        } else if !isNear {
            nearSince = nil
        }

        let target = isNear || forceReveal ? 1.0 : 0.0
        var remaining = min(max(0, dt), 0.1)
        while remaining > 0 {
            let step = min(remaining, 1.0 / 120)
            velocity += ((target - reveal) * 100 - velocity * 14) * step
            reveal = min(1.06, max(0, reveal + velocity * step))
            remaining -= step
        }
        if abs(reveal - target) < 0.0005 && abs(velocity) < 0.005 { reveal = target; velocity = 0 }
        let jump = min(1, max(0, now.timeIntervalSince(enteredAt) / 0.55))
        bounce = sin(jump * .pi) * 8 * min(1, reveal)
        if jump >= 1 { bounce = 0 }
        return greeting
    }
}
