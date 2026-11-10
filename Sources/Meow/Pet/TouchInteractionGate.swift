import Foundation

/// 轻互动首次响应后等待完整反应结束；连续戳只保留一次待执行的抗议。
struct TouchInteractionGate {
    enum Kind { case poke, stroke }
    private(set) var kind: Kind?
    private(set) var until = Date.distantPast
    private(set) var pendingAnnoyance = false
    private var recentPokes: [Date] = []

    func isHolding(at now: Date) -> Bool { now < until }

    mutating func hold(_ kind: Kind, for duration: TimeInterval, bubbleUntil: Date, at now: Date) {
        self.kind = kind
        until = max(now.addingTimeInterval(duration), bubbleUntil)
    }

    mutating func recordPoke(at now: Date) {
        guard !pendingAnnoyance else { return }
        recentPokes = recentPokes.filter { (0..<3).contains(now.timeIntervalSince($0)) }
        recentPokes.append(now)
        if recentPokes.count >= 4 {
            pendingAnnoyance = true
            recentPokes.removeAll(keepingCapacity: true)
        }
    }

    mutating func consumeAnnoyance() { pendingAnnoyance = false; recentPokes.removeAll(keepingCapacity: true) }
    mutating func cancel() { self = TouchInteractionGate() }
}
