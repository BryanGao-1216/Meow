import Foundation
import Combine
import CoreGraphics

/// Single source of truth the renderer observes. Mutated only by PetEngine (main actor).
@MainActor
final class PetCore: ObservableObject {

    // Rendering state — the Canvas redraws every frame via TimelineView; these don't
    // need @Published (we avoid 60Hz objectWillChange storms). The few that drive
    // SwiftUI layout/visibility elsewhere are @Published.
    var emotion: Emotion = .neutral
    var activity: Activity = .idle
    var facingRight = true
    var walkPhase: Double = 0          // advances while walking
    var talkLevel: Double = 0          // 0..1 mouth-open while speaking
    var pickupWiggle: Double = 0       // flail intensity while dragged
    var dizzy: Double = 0              // >0 after hard landing
    var eyeOffset: CGPoint = .zero     // pupil tracking toward cursor
    var blink: Double = 0              // 0 open … 1 closed
    var earTwitch: Double = 0
    var squash: Double = 0             // -0.3…0.3 vertical squash(+)/stretch(-)
    var breathe = true
    var particles: [Particle] = []
    var actionPhase: Double = 0        // generic progress for dance/spin/jump/stretch/eat
    var lookAway: Double = 0           // sulk: turn head away 0..1
    var attention: Double = 0          // ears-perk when owner is chatting
    var wallSide: WallSide?            // 独立于聊天、进食和睡眠，保持贴墙
    var wallReveal: Double = 0         // 0 收至眼睛下方，1 鼠标靠近时探出身体
    var unreadLetters = 0              // 来信未读时抱信；由信箱控制器更新

    // Stats & meta. `stats` is written every engine tick, so it must NOT be @Published
    // (that would invalidate SwiftUI 60x/s). `uiPulse` is bumped ~2x/s to refresh the
    // chat header bars instead.
    var stats = PetStats()
    @Published var uiPulse = 0
    @Published var isSleeping = false
    @Published var brainState: BrainState = .loading

    // Emotion hold: LLM/events set an emotion with an expiry; engine reverts to baseline.
    var emotionUntil: Date = .distantPast

    func setEmotion(_ e: Emotion, hold: TimeInterval, at now: Date = Date()) {
        emotion = e
        emotionUntil = now.addingTimeInterval(hold)
    }

    /// Baseline emotion from stats when nothing is held.
    var baselineEmotion: Emotion {
        if isSleeping { return .sleepy }
        if stats.fullness < 22 { return .hungry }
        if stats.energy < 20 { return .sleepy }
        if stats.happiness < 25 { return .sad }
        if stats.happiness >= 80 { return .happy }
        return .neutral
    }

    func spawn(_ kind: Particle.Kind, count: Int = 1, near: CGPoint = .zero, spread: Double = 26) {
        for _ in 0..<count {
            particles.append(Particle(
                kind: kind,
                x: near.x + .random(in: -spread...spread),
                y: near.y + .random(in: -spread * 0.5...spread * 0.5),
                vx: .random(in: -9...9),
                vy: .random(in: 22...42),
                lifetime: .random(in: 1.1...1.9),
                scale: .random(in: 0.8...1.25)))
        }
    }
}

enum BrainState: Equatable {
    case loading
    case ready
    case failed(String)
    case generating
}

/// Immutable value snapshot handed to the (nonisolated) Canvas painter each frame.
struct PetRenderState {
    var emotion: Emotion
    var activity: Activity
    var facingRight: Bool
    var walkPhase: Double
    var talkLevel: Double
    var pickupWiggle: Double
    var dizzy: Double
    var eyeOffset: CGPoint
    var blink: Double
    var earTwitch: Double
    var squash: Double
    var particles: [Particle]
    var actionPhase: Double
    var lookAway: Double
    var attention: Double
    var isSleeping: Bool
    var happiness: Double
    var wallSide: WallSide?
    var wallReveal: Double
    var unreadLetters: Int
}

extension PetCore {
    func snapshot() -> PetRenderState {
        PetRenderState(
            emotion: emotion, activity: activity, facingRight: facingRight,
            walkPhase: walkPhase, talkLevel: talkLevel, pickupWiggle: pickupWiggle,
            dizzy: dizzy, eyeOffset: eyeOffset, blink: blink, earTwitch: earTwitch,
            squash: squash, particles: particles, actionPhase: actionPhase,
            lookAway: lookAway, attention: attention, isSleeping: isSleeping,
            happiness: stats.happiness, wallSide: wallSide, wallReveal: wallReveal, unreadLetters: unreadLetters)
    }
}
