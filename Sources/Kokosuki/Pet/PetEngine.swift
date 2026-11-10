import AppKit
import Foundation
import KokosukiMemory
import KokosukiNews

/// Behavior engine: physics, autonomy, stats, particles, and the coupling between
/// LLM output and on-screen behavior. Ticks at 60Hz on the main actor.
@MainActor
final class PetEngine {

    let core: PetCore
    let brain: Brain
    private let settings = AppSettings.shared

    // wired by AppDelegate
    var moveWindow: ((CGPoint) -> Void)?          // pet center, screen coords
    var bubble: BubbleController?
    var chatMirror: ((String, Bool) -> Void)?     // streamed pet line into chat UI (text, done)
    var proactiveMirror: ((String) -> Void)?
    var conversationTools: ConversationToolRouter?
    var hasPriorityNotice: () -> Bool = { false }
    private var preparationTask: Task<Void, Never>?
    private var preparationRevision = 0

    // position & physics (screen coords, pet center)
    private(set) var petCenter: CGPoint = .zero
    private var velocity = CGVector(dx: 0, dy: 0)
    private var airborne = false
    private var prevFeetY: CGFloat = 0
    private var gravity: CGFloat = 2600   // softened during deliberate jumps for a visible arc

    // window-top platforms (jump on, walk along, ride, fall off)
    private let tracker = PlatformTracker()
    private var currentPlatformID: CGWindowID?
    private var lastPlatformMinX: CGFloat = 0
    private var platformRefreshAt = Date.distantPast
    private var deliberateJump = false
    private(set) var wallAttachment: WallAttachment?
    private let screens: @MainActor () -> [WallScreen]
    private let mouseLocation: @MainActor () -> CGPoint
    private var wallHover = WallHover()
    private var wallGreetingDeadline: Date?
    var onWallAttachmentChange: ((WallAttachment?) -> Void)?
    private var motionRevision = 0
    private var actionAfterLanding: PetAction?
    private var gentleWallRelease = false
    private var lastSuggestedActionAt = Date.distantPast
    private var lastActionAt: [PetAction: Date] = [:]

    // walking
    private var walkTargetX: CGFloat = 0
    private var walkDir: CGFloat = 1

    // scheduling
    private var nextDecision = Date().addingTimeInterval(2)
    private var nextBlink = Date().addingTimeInterval(3)
    private var nextEarTwitch = Date().addingTimeInterval(5)
    private var lastChatterAt = Date()
    private var chatterJitter = 1.0
    private var lastWokeAt = Date.distantPast
    private var minSleepUntil = Date.distantPast
    private var pendingSleep: Task<Void, Never>?
    private var nextZzz = Date()
    private var activityEndsAt = Date.distantPast
    private var bubbleHideAt = Date.distantPast
    private var lastStatsSave = Date()
    private var lastHungerNag = Date.distantPast
    private var lastSleepNag = Date.distantPast
    private var mailArrivalPending = false
    private var nextMailNoticeAt = Date.distantPast

    // interaction bookkeeping
    private var recentPokes: [Date] = []
    private var lastPetStroke = Date.distantPast
    private var lastEventLLM = Date.distantPast
    private var blinkUntil = Date.distantPast
    private var dizzyUntil = Date.distantPast
    private var chasingCursor = false

    private var timer: Timer?
    private var lastTick = Date()
    private var lastPulse = Date()
    private var bubbleStreaming = false
    private let sessionStart = Date()
    private var eventLog: [(Date, PetEvent)] = []
    private var lastAffectionApproach = Date()
    var newsMirror: ((String, URL) -> Void)?

    func shareNews(_ bulletin: NewsBulletin) -> Bool {
        guard !hasPriorityNotice(), !core.isSleeping, !brain.isGenerating, !bubbleStreaming, !airborne,
              (core.activity == .idle || core.activity == .walk), bubbleHideAt == .distantPast else { return false }
        let line = bulletin.line
        core.setEmotion(.curious, hold: 15)
        bubble?.show(text: line, above: bubbleAnchor, petScale: scale)
        bubbleHideAt = Date().addingTimeInterval(bubbleDuration(for: line) + 4)
        let transcript = line + "\n微博热搜：" + bulletin.topic.title
        brain.noteAssistantLine(transcript, sourceURL: bulletin.topic.sourceURL)
        newsMirror?(transcript, bulletin.topic.sourceURL)
        lastChatterAt = Date()
        return true
    }

    func canReceiveProactive(wakeForAlarm: Bool) -> Bool {
        !brain.isGenerating && !bubbleStreaming && !airborne && bubbleHideAt == .distantPast
            && (core.activity == .idle || core.activity == .walk || (wakeForAlarm && core.isSleeping))
            && (!core.isSleeping || wakeForAlarm)
    }

    /// 由功能协调器投递已验证的提醒；引擎只负责小猫表现，不读取备忘录存储。
    func speakProactively(_ text: String, wakeForAlarm: Bool, at now: Date = Date()) -> Bool {
        guard canReceiveProactive(wakeForAlarm: wakeForAlarm) else { return false }
        if core.isSleeping { wake(grumpy: false) }
        core.setEmotion(wakeForAlarm ? .curious : .love, hold: 12)
        bubble?.show(text: text, above: bubbleAnchor, petScale: scale)
        bubbleHideAt = now.addingTimeInterval(bubbleDuration(for: text) + 4)
        core.activity = .talk; activityEndsAt = bubbleHideAt
        lastChatterAt = now
        brain.noteAssistantLine(text)
        proactiveMirror?(text)
        return true
    }

    func updateUnreadLetters(_ count: Int) {
        core.unreadLetters = max(0, count)
        if core.unreadLetters == 0 { mailArrivalPending = false }
    }

    func receivedLetter() {
        if core.unreadLetters > 0 { mailArrivalPending = true }
    }

    /// 等聊天、动作和到点提醒结束再报信；短时间多封来信合并，读完即取消待报信。
    @discardableResult
    func deliverPendingMailArrival(at now: Date = Date()) -> Bool {
        guard mailArrivalPending, core.unreadLetters > 0, now >= nextMailNoticeAt,
              !hasPriorityNotice(), core.wallSide == nil || core.wallReveal >= 0.95 else { return false }
        let line = core.unreadLetters == 1
            ? "主人，来信啦！快点我举着的 💌 拆开看看喵～"
            : "主人，来信啦！还有 \(core.unreadLetters) 封没拆，点我举着的 💌 看看喵～"
        guard speakProactively(line, wakeForAlarm: false, at: now) else { return false }
        core.setEmotion(.excited, hold: 12)
        mailArrivalPending = false
        nextMailNoticeAt = now.addingTimeInterval(30)
        return true
    }

    var scale: CGFloat { settings.petScale }
    /// distance from pet center down to feet, in screen px
    private var feetDrop: CGFloat { PetLayout.feetDrop(scale: scale) }

    /// 探身画布还包含尾巴，气泡须放在整个造型上方，不能盖住向上摇的尾巴。
    private var bubbleAnchor: CGPoint {
        guard wallAttachment != nil else { return petCenter }
        let halfHeight = WallDock.size(scale: scale, reveal: core.wallReveal).height / 2
        return CGPoint(x: petCenter.x,
                       y: petCenter.y + max(0, halfHeight - PetLayout.windowSize(scale: scale) * 0.34))
    }

    init(core: PetCore, brain: Brain, wallAttachment: WallAttachment? = nil,
         screens: @escaping @MainActor () -> [WallScreen] = { WallScreen.current },
         mouseLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation }) {
        self.core = core
        self.brain = brain
        self.screens = screens
        self.mouseLocation = mouseLocation
        self.wallAttachment = wallAttachment
        core.wallSide = wallAttachment?.side
    }

    func start(at point: CGPoint?) {
        brain.memory.presence()
        petCenter = point ?? defaultSpot()
        updateWallPosition()
        scheduleChatter(initial: true)
        lastTick = Date()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        moveWindow?(petCenter)
    }

    private func defaultSpot() -> CGPoint {
        let f = screens().first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: f.midX + f.width * 0.25, y: f.minY + feetDrop)
    }

    private func screenFrame() -> CGRect {
        WallDock.screen(at: petCenter, in: screens())?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// 贴墙独立于 activity：说话、进食、睡觉和模型动作都不能把固定状态覆盖掉。
    private func attachToWall(_ attachment: WallAttachment) {
        motionRevision &+= 1
        pendingSleep?.cancel(); pendingSleep = nil
        wallAttachment = attachment
        core.wallSide = attachment.side
        wallHover.reset()
        core.wallReveal = 0
        currentPlatformID = nil
        airborne = false
        deliberateJump = false
        chasingCursor = false
        actionAfterLanding = nil
        gentleWallRelease = false
        velocity = .zero
        gravity = 2600
        core.activity = .idle
        core.squash = 0
        core.dizzy = 0
        core.particles.removeAll()
        core.setEmotion(.curious, hold: 3)
        updateWallPosition()
        onWallAttachmentChange?(wallAttachment)
    }

    private func updateWallPosition() {
        guard var attachment = wallAttachment else { return }
        let available = screens()
        guard let screen = available.first(where: { $0.id == attachment.screenID })
                ?? WallDock.screen(at: petCenter, in: available) else { return }
        if attachment.screenID != screen.id {
            attachment.screenID = screen.id
            wallAttachment = attachment
            onWallAttachmentChange?(attachment)
        }
        petCenter = WallDock.center(for: attachment, screen: screen, scale: scale,
                                   reveal: core.wallReveal, bounce: wallHover.bounce)
        moveWindow?(petCenter)
        bubble?.reposition(above: bubbleAnchor, petScale: scale)
    }

    private func clearWallAttachment() {
        guard wallAttachment != nil else { return }
        motionRevision &+= 1
        wallAttachment = nil
        core.wallSide = nil
        wallHover.reset()
        core.wallReveal = 0
        hideWallGreeting()
        onWallAttachmentChange?(nil)
    }

    private func updateWallHover(_ now: Date, _ dt: TimeInterval) {
        guard let attachment = wallAttachment,
              let screen = screens().first(where: { $0.id == attachment.screenID }) else { return }
        let distance = WallDock.hoverDistance(pointer: mouseLocation(), attachment: attachment, screen: screen, scale: scale)
        let line = wallHover.update(distance: distance, scale: scale,
            enabled: !core.isSleeping && core.activity != .drag,
            canGreet: core.unreadLetters == 0 && !hasPriorityNotice() && !brain.isGenerating && !bubbleStreaming && bubbleHideAt == .distantPast && core.activity == .idle,
            now: now, dt: dt, forceReveal: core.unreadLetters > 0)
        core.wallReveal = wallHover.reveal
        if !wallHover.isNear { hideWallGreeting() }
        if let line {
            core.setEmotion(.happy, hold: 3.5)
            bubble?.show(text: line, above: bubbleAnchor, petScale: scale)
            bubbleHideAt = now.addingTimeInterval(4)
            wallGreetingDeadline = bubbleHideAt
            lastChatterAt = now
        }
    }

    private func hideWallGreeting() {
        guard let deadline = wallGreetingDeadline else { return }
        // 聊天/热点可能已经替换气泡；只收回本次探头招呼，不遮掉后来的内容。
        if bubbleHideAt == deadline && !bubbleStreaming {
            bubble?.hide()
            bubbleHideAt = .distantPast
            if core.activity == .talk { core.activity = .idle }
        }
        wallGreetingDeadline = nil
    }

    /// 主人明确叫它离墙时，先回到屏幕内，再轻轻落下。
    private func leaveWall() {
        guard wallAttachment != nil else { return }
        let f = screenFrame()
        clearWallAttachment()
        let inset = min(f.width / 2, 76 * scale)
        petCenter.x = min(max(petCenter.x, f.minX + inset), f.maxX - inset)
        petCenter.y = max(petCenter.y, groundY)
        gentleWallRelease = true
        startFalling(surprised: false)
        moveWindow?(petCenter)
        bubble?.reposition(above: bubbleAnchor, petScale: scale)
    }

    private var groundY: CGFloat { screenFrame().minY + feetDrop }

    /// y for the pet center on whatever it currently stands on (platform or ground).
    private var standY: CGFloat {
        if let id = currentPlatformID, let p = tracker.platform(withID: id) {
            return p.y + feetDrop
        }
        return groundY
    }

    /// Horizontal span the pet may walk on for the current surface.
    private func surfaceSpan() -> (lo: CGFloat, hi: CGFloat) {
        if let id = currentPlatformID, let p = tracker.platform(withID: id) {
            return (p.minX + 8, p.maxX - 8)
        }
        let f = screenFrame()
        return (f.minX + 50, f.maxX - 50)
    }

    // MARK: - Main tick

    func tick(at now: Date = Date()) {
        let dt = min(now.timeIntervalSince(lastTick), 1.0 / 15.0)
        lastTick = now

        // refresh every tick while standing on a window so rides stay smooth;
        // cheaper cadence otherwise
        if wallAttachment == nil && (currentPlatformID != nil || now > platformRefreshAt) {
            platformRefreshAt = now.addingTimeInterval(0.12)
            tracker.refresh()
            validatePlatform()
        }
        decayStats(dt)
        updateWallHover(now, dt)
        updateWallPosition()
        updatePhysics(dt)
        updateActivity(now, dt)
        updateBubble(now)
        deliverPendingMailArrival(at: now)
        updateAutonomy(now)
        updateFace(now, dt)
        updateParticles(dt)
        updateChatter(now)

        if now.timeIntervalSince(lastStatsSave) > 60 {
            lastStatsSave = now
            Persistence.saveStats(core.stats)
            brain.memory.presence()
        }
        // low-frequency UI refresh for the chat header stat bars
        if now.timeIntervalSince(lastPulse) > 0.5 {
            lastPulse = now
            core.uiPulse &+= 1
        }
    }

    // MARK: - Stats

    private func decayStats(_ dt: TimeInterval) {
        var s = core.stats
        let m = dt / 60.0
        s.fullness -= 0.21 * m                        // empty in ~8h
        if core.isSleeping {
            s.energy += 1.4 * m                       // full nap ~70min
        } else {
            s.energy -= 0.17 * m                      // tired after ~10h
        }
        // happiness drifts toward 55; hunger drags it down
        s.happiness += (55 - s.happiness) * 0.004 * m
        if s.fullness < 20 { s.happiness -= 0.10 * m }
        s.clamp()
        core.stats = s
    }

    // MARK: - Physics & platforms

    /// Keep standing on the tracked window: ride it when it moves, fall when it goes away.
    private func validatePlatform() {
        guard let id = currentPlatformID, core.activity != .drag, !airborne else { return }
        guard let p = tracker.platform(withID: id) else {
            currentPlatformID = nil
            startFalling(surprised: true)
            return
        }
        // ride horizontal motion of the window
        let dx = p.minX - lastPlatformMinX
        if abs(dx) > 0.5 { petCenter.x += dx }
        lastPlatformMinX = p.minX

        if !p.contains(x: petCenter.x) {
            petCenter.x = min(max(petCenter.x, p.minX), p.maxX)
            if !p.contains(x: petCenter.x) {
                currentPlatformID = nil
                startFalling(surprised: true)
                return
            }
        }
        let target = p.y + feetDrop
        if abs(petCenter.y - target) > 0.5 || abs(dx) > 0.5 {
            petCenter.y = target
            moveWindow?(petCenter)
            bubble?.reposition(above: bubbleAnchor, petScale: scale)
        }
    }

    private func startFalling(surprised: Bool) {
        guard wallAttachment == nil else { return }
        if core.isSleeping {
            core.isSleeping = false
            lastWokeAt = Date()
        }
        airborne = true
        velocity = .zero
        prevFeetY = petCenter.y - feetDrop
        core.activity = .fall
        if surprised {
            core.setEmotion(.surprised, hold: 3)
            core.spawn(.exclamation, count: 1, near: CGPoint(x: 0, y: 55), spread: 4)
        }
    }

    /// Deliberate jump toward a target x on a target surface (window top or ground).
    /// Crouches briefly first (anticipation), then launches on a soft, visible arc.
    private func jumpTo(targetX: CGFloat, surfaceY: CGFloat, ontoPlatform: Bool) {
        guard wallAttachment == nil, core.activity != .drag, !airborne else { return }
        core.squash = 0.26                       // wind-up crouch
        core.setEmotion(.excited, hold: 2.5)
        core.facingRight = targetX >= petCenter.x
        let fromPlatform = currentPlatformID
        let revision = motionRevision
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard let self, self.wallAttachment == nil, self.motionRevision == revision,
                self.core.activity != .drag, !self.airborne,
                self.currentPlatformID == fromPlatform
            else { return }
            let g: CGFloat = 1500
            self.gravity = g
            let targetCenterY = surfaceY + self.feetDrop
            let apex = max(self.petCenter.y, targetCenterY) + 80
            let vy = sqrt(2 * g * (apex - self.petCenter.y))
            let tUp = vy / g
            let tDown = sqrt(2 * max(1, apex - targetCenterY) / g)
            let vx = (targetX - self.petCenter.x) / (tUp + tDown)
            self.prevFeetY = self.petCenter.y - self.feetDrop
            self.velocity = CGVector(dx: vx, dy: vy)
            self.airborne = true
            self.currentPlatformID = nil
            self.deliberateJump = ontoPlatform
            self.core.activity = .jumpPose
            self.core.squash = -0.18             // launch stretch
        }
    }

    private func updatePhysics(_ dt: TimeInterval) {
        guard wallAttachment == nil, core.activity != .drag else { return }

        if airborne {
            let feetBefore = petCenter.y - feetDrop
            velocity.dy -= gravity * dt
            petCenter.x += velocity.dx * dt
            petCenter.y += velocity.dy * dt
            let f = screenFrame()
            petCenter.x = min(max(petCenter.x, f.minX + 40), f.maxX - 40)
            if petCenter.x <= f.minX + 40 || petCenter.x >= f.maxX - 40 { velocity.dx *= -0.5 }

            // catch a window top while descending
            if velocity.dy < 0,
                let p = tracker.landingPlatform(
                    x: petCenter.x, feetY: petCenter.y - feetDrop, previousFeetY: feetBefore)
            {
                petCenter.y = p.y + feetDrop
                let impact = -velocity.dy
                velocity = .zero
                airborne = false
                gravity = 2600
                currentPlatformID = p.id
                lastPlatformMinX = p.minX
                land(hard: impact > 1000)
                if deliberateJump {
                    deliberateJump = false
                    logEvent(.climbedWindow)
                    core.setEmotion(.proud, hold: 4)
                    core.spawn(.sparkle, count: 3, near: CGPoint(x: 0, y: 45))
                    maybeCelebratePerch()
                }
            } else if petCenter.y <= groundY {
                petCenter.y = groundY
                let impact = -velocity.dy
                velocity = .zero
                airborne = false
                gravity = 2600
                currentPlatformID = nil
                deliberateJump = false
                land(hard: impact > 900)
            }
            prevFeetY = petCenter.y - feetDrop
            moveWindow?(petCenter)
            bubble?.reposition(above: bubbleAnchor, petScale: scale)
            return
        }

        // stick to the current surface (ground or ridden window)
        if abs(petCenter.y - standY) > 1 {
            petCenter.y = standY
            moveWindow?(petCenter)
        }

        if core.activity == .walk {
            var speed: CGFloat = 55 * scale
            if core.stats.happiness > 75 { speed *= 1.25 }
            if core.stats.energy < 30 { speed *= 0.7 }
            if chasingCursor { speed *= 2.1 }
            petCenter.x += walkDir * speed * dt
            core.walkPhase += dt * (chasingCursor ? 14 : 9)
            core.facingRight = walkDir > 0

            let span = surfaceSpan()
            petCenter.x = min(max(petCenter.x, span.lo), span.hi)
            let arrived = abs(petCenter.x - walkTargetX) < 8
                || petCenter.x <= span.lo || petCenter.x >= span.hi
            if arrived {
                if chasingCursor {
                    chasingCursor = false
                    logEvent(.cameWhenCalled)
                    core.activity = .idle
                    hopInPlace()
                    showCanned(.poke, emotion: .happy)
                } else {
                    core.activity = .idle
                }
            }
            moveWindow?(petCenter)
            bubble?.reposition(above: bubbleAnchor, petScale: scale)
        }
    }

    /// Occasionally brag (LLM) about having climbed onto a window.
    private func maybeCelebratePerch() {
        let now = Date()
        guard now.timeIntervalSince(lastEventLLM) > 120, brain.isReady, !brain.isGenerating,
            Double.random(in: 0..<1) < 0.45
        else { return }
        lastEventLLM = now
        runLLMEvent("你刚刚成功跳到了一个应用窗口的顶上,视野很好")
    }

    /// Pet size changed in settings: re-seat on the current surface without touching activity.
    func rescaled() {
        if wallAttachment != nil { updateWallPosition(); return }
        petCenter.y = standY
        moveWindow?(petCenter)
        bubble?.reposition(above: bubbleAnchor, petScale: scale)
    }

    private func land(hard: Bool) {
        let hard = hard && !gentleWallRelease
        gentleWallRelease = false
        if hard {
            core.activity = .land
            core.squash = 0.30
            core.dizzy = 1
            dizzyUntil = Date().addingTimeInterval(1.6)
            core.spawn(.star, count: 3, near: CGPoint(x: 0, y: 30))
            activityEndsAt = Date().addingTimeInterval(0.5)
            core.setEmotion(.surprised, hold: 2)
            logEvent(.hardFall)
            if !bubbleStreaming { showCanned(.landingOuch, emotion: nil) }
            core.stats.happiness -= 1.5
        } else {
            core.activity = .land
            core.squash = 0.18
            activityEndsAt = Date().addingTimeInterval(0.3)
        }
    }

    private func hopInPlace() {
        guard wallAttachment == nil else { return }
        prevFeetY = petCenter.y - feetDrop
        velocity = CGVector(dx: 0, dy: 520)
        airborne = true
        core.activity = .jumpPose
        core.squash = -0.15
    }

    // MARK: - Timed activities

    private func updateActivity(_ now: Date, _ dt: TimeInterval) {
        core.squash *= pow(0.02, dt)   // relax squash quickly
        if core.dizzy > 0 && now > dizzyUntil { core.dizzy = 0 }

        switch core.activity {
        case .eat, .stretchPose, .dance, .spinPose, .rollPose, .wave, .nod, .shakeHead, .play, .land:
            core.actionPhase += dt
            if now > activityEndsAt {
                finishTimedActivity()
            } else if case .dance = core.activity, Int(core.actionPhase * 3) != Int((core.actionPhase - dt) * 3) {
                core.spawn(.note, count: 1, near: CGPoint(x: 0, y: 40), spread: 30)
            } else if case .play = core.activity, Int(core.actionPhase * 2) != Int((core.actionPhase - dt) * 2) {
                core.spawn(.sparkle, count: 1, near: CGPoint(x: 30, y: -20), spread: 22)
            }
        case .sleep:
            if now > nextZzz {
                nextZzz = now.addingTimeInterval(1.4)
                core.spawn(.zzz, count: 1, near: CGPoint(x: 26, y: 30), spread: 6)
            }
            if core.stats.energy > 96, !isNight(), now > minSleepUntil {
                wake(grumpy: false)
            }
        case .talk:
            // self-heal: never mouth-flap without a visible bubble
            if !bubbleStreaming && bubbleHideAt == .distantPast {
                core.activity = .idle
                core.talkLevel = 0
            } else {
                core.talkLevel = 0.5 + 0.5 * sin(now.timeIntervalSinceReferenceDate * 11)
            }
        default:
            core.talkLevel = max(0, core.talkLevel - dt * 4)
        }
    }

    private func finishTimedActivity() {
        let a = core.activity
        core.actionPhase = 0
        core.activity = bubbleStreaming ? .think : (bubbleHideAt > Date() ? .talk : .idle)
        switch a {
        case .eat:
            core.setEmotion(.happy, hold: 5)
            core.spawn(.heart, count: 2, near: CGPoint(x: 0, y: 20))
        case .play:
            logEvent(.playedYarn)
            core.setEmotion(.happy, hold: 6)
            core.stats.happiness += 8
            core.stats.energy -= 6
        case .dance, .spinPose, .rollPose:
            core.setEmotion(.proud, hold: 4)
        case .land where chasingCursor:
            // was called over mid-parkour: resume running to the cursor
            walkDir = walkTargetX > petCenter.x ? 1 : -1
            core.activity = .walk
        default: break
        }
        core.stats.clamp()
        if a == .land, let action = actionAfterLanding {
            actionAfterLanding = nil
            requestAction(action)
        }
    }

    // MARK: - Autonomy

    private func updateAutonomy(_ now: Date) {
        guard now > nextDecision else { return }
        if wallAttachment != nil {
            // 可以在墙上打盹，但不走动、跳窗或自己靠近鼠标。
            if core.activity == .idle, !core.isSleeping, now.timeIntervalSince(lastWokeAt) > 600,
               core.stats.energy < 15 || (settings.autoSleep && isNight() && core.stats.energy < 80) {
                fallAsleep()
            }
            nextDecision = now.addingTimeInterval(3)
            return
        }
        guard !core.activity.isBusy, core.activity != .drag, !airborne else {
            nextDecision = now.addingTimeInterval(1.5)
            return
        }
        if core.isSleeping { nextDecision = now.addingTimeInterval(3); return }

        // nagging about needs (rate-limited; sometimes via LLM for variety)
        if core.stats.fullness < 22, now.timeIntervalSince(lastHungerNag) > 240 {
            lastHungerNag = now
            sayStateLine(canned: .hungry, emotion: .hungry, llmEvent: "你现在很饿,想吃小鱼干", fallback: (.hungry, .hungry))
            nextDecision = now.addingTimeInterval(8)
            return
        }
        // naps: only when truly tired, and never right after being woken up
        if core.stats.energy < 15 || (settings.autoSleep && isNight() && core.stats.energy < 80) {
            if now.timeIntervalSince(lastSleepNag) > 120,
                now.timeIntervalSince(lastWokeAt) > 600
            {
                lastSleepNag = now
                fallAsleep()
                nextDecision = now.addingTimeInterval(10)
                return
            }
        }
        if core.stats.happiness < 22, core.activity != .sulk {
            core.activity = .sulk
            core.setEmotion(.sad, hold: 30)
            nextDecision = now.addingTimeInterval(20)
            return
        }
        if core.activity == .sulk {
            core.activity = .idle
        }

        // parkour disabled while perched: come back down right away
        let habits = brain.memory.tendencies
        let parkour = settings.windowParkour && !habits.avoidsWindows
        if !parkour, currentPlatformID != nil {
            let f = screenFrame()
            let tx = min(max(petCenter.x, f.minX + 60), f.maxX - 60)
            jumpTo(targetX: tx, surfaceY: f.minY, ontoPlatform: false)
            nextDecision = now.addingTimeInterval(3)
            return
        }

        // weighted idle behaviors
        let span = surfaceSpan()
        let onPlatform = currentPlatformID != nil
        // 熟悉后偶尔自己靠近，不把主动亲近伪装成一次主人召唤。
        if !onPlatform, !habits.prefersQuiet, habits.familiarity > 0.2,
           now.timeIntervalSince(lastAffectionApproach) > 300,
           Double.random(in: 0..<1) < habits.familiarity * 0.2 {
            lastAffectionApproach = now
            walkTargetX = min(max(mouseLocation().x, span.lo), span.hi)
            walkDir = walkTargetX > petCenter.x ? 1 : -1
            core.activity = .walk
            core.setEmotion(.love, hold: 5)
            nextDecision = now.addingTimeInterval(8)
            return
        }
        let ups = parkour ? tracker.reachable(from: standY - feetDrop) : []
        let roll = Double.random(in: 0..<10)
        switch roll {
        case ..<3.0 where span.hi - span.lo > 40:  // wander along the current surface
            walkTargetX = .random(in: span.lo...span.hi)
            walkDir = walkTargetX > petCenter.x ? 1 : -1
            core.activity = .walk
        case ..<5.0:
            let state = ActionLibrary.IdleState(stats: core.stats,
                ownerNearby: core.attention > 0 || hypot(mouseLocation().x - petCenter.x, mouseLocation().y - petCenter.y) < 360 * scale,
                prefersQuiet: habits.prefersQuiet, onPlatform: onPlatform)
            if let action = ActionLibrary.chooseAutonomous(state, unitRoll: Double.random(in: 0..<1)) {
                requestAction(action, ownerRequested: false, at: now)
            }
        case ..<6.4 where !ups.isEmpty && core.stats.energy > 30:
            // parkour: jump onto a window top (favor lower platforms)
            if let p = ups.min(by: { $0.y < $1.y }) {
                let lo = max(p.minX + 20, petCenter.x - 420)
                let hi = min(p.maxX - 20, petCenter.x + 420)
                if lo < hi {
                    jumpTo(targetX: .random(in: lo...hi), surfaceY: p.y, ontoPlatform: true)
                }
            }
        case ..<7.8 where onPlatform:
            // hop back down to the ground (always, when hungry — food lives down there)
            let f = screenFrame()
            let tx = min(max(petCenter.x + .random(in: -140...140), f.minX + 60), f.maxX - 60)
            jumpTo(targetX: tx, surfaceY: f.minY, ontoPlatform: false)
        default:
            break  // keep idling; eyes will track cursor
        }
        nextDecision = now.addingTimeInterval(.random(in: 4...11))
    }

    private func isNight() -> Bool {
        let h = Calendar.current.component(.hour, from: Date())
        return h >= 23 || h < 7
    }

    // MARK: - Face & particles

    private func updateFace(_ now: Date, _ dt: TimeInterval) {
        if now > core.emotionUntil, core.activity != .talk, core.activity != .think {
            core.emotion = core.baselineEmotion
        }

        // blinking
        if core.isSleeping {
            core.blink = 1
        } else if now > nextBlink {
            blinkUntil = now.addingTimeInterval(0.13)
            nextBlink = now.addingTimeInterval(.random(in: 2.4...6.0))
        }
        if !core.isSleeping {
            core.blink = now < blinkUntil ? 1 : 0
        }

        if now > nextEarTwitch {
            core.earTwitch = 1
            nextEarTwitch = now.addingTimeInterval(.random(in: 4...12))
        }
        core.earTwitch = max(0, core.earTwitch - dt * 3)

        // pupils track the cursor when the cat is calm/curious
        let tracking: Bool
        switch core.activity {
        case .idle, .walk, .talk, .think: tracking = !core.isSleeping
        default: tracking = false
        }
        if tracking {
            let mouse = mouseLocation()
            let dx = mouse.x - petCenter.x
            let dy = mouse.y - petCenter.y
            let mag = max(1, hypot(dx, dy))
            let r: CGFloat = min(3.5, mag / 40)
            let target = CGPoint(x: dx / mag * r, y: dy / mag * r)
            core.eyeOffset.x += (target.x - core.eyeOffset.x) * min(1, dt * 8)
            core.eyeOffset.y += (target.y - core.eyeOffset.y) * min(1, dt * 8)
        } else {
            core.eyeOffset.x *= pow(0.1, dt)
            core.eyeOffset.y *= pow(0.1, dt)
        }

        if core.activity == .drag {
            core.pickupWiggle = min(1, core.pickupWiggle + dt * 3)
        } else {
            core.pickupWiggle = max(0, core.pickupWiggle - dt * 4)
        }

        core.lookAway = core.activity == .sulk
            ? min(1, core.lookAway + dt * 2) : max(0, core.lookAway - dt * 2)
    }

    private func updateParticles(_ dt: TimeInterval) {
        var ps = core.particles
        for i in ps.indices {
            ps[i].age += dt
            ps[i].x += ps[i].vx * dt
            ps[i].y += ps[i].vy * dt
            ps[i].vy *= pow(0.5, dt)
        }
        ps.removeAll { $0.age >= $0.lifetime }
        core.particles = ps
    }

    // MARK: - Bubble & speech

    private func updateBubble(_ now: Date) {
        if !bubbleStreaming, bubbleHideAt != .distantPast, now > bubbleHideAt {
            bubble?.hide()
            bubbleHideAt = .distantPast
            wallGreetingDeadline = nil
            if core.activity == .talk { core.activity = .idle }
        }
    }

    private func bubbleDuration(for text: String) -> TimeInterval {
        min(18, max(3.5, 2.0 + Double(text.count) * 0.055))
    }

    /// Show a non-LLM line in the bubble with a matching emotion.
    /// `remember`: record into chat history (for chatter/nags the owner may reply to).
    @discardableResult
    func showCanned(_ cat: L10n.CannedCategory, emotion: Emotion?, remember: Bool = false) -> String {
        let line = L10n.canned(cat)
        if let emotion { core.setEmotion(emotion, hold: bubbleDuration(for: line) + 1) }
        bubble?.show(text: line, above: bubbleAnchor, petScale: scale)
        bubbleHideAt = Date().addingTimeInterval(bubbleDuration(for: line))
        if core.activity == .idle { core.activity = .talk
            activityEndsAt = bubbleHideAt }
        if remember { brain.noteAssistantLine(line) }
        return line
    }

    /// A state nag: canned 40% / LLM 60% when available.
    private func sayStateLine(
        canned: L10n.CannedCategory, emotion: Emotion, llmEvent: String,
        fallback: (L10n.CannedCategory, Emotion)
    ) {
        if brain.isReady, !brain.isGenerating, Double.random(in: 0..<1) < 0.6 {
            runLLMEvent(llmEvent, fallback: fallback)
        } else {
            showCanned(canned, emotion: emotion, remember: true)
        }
    }

    // MARK: - LLM coupling

    /// Relative-time renderer for the event log ("刚刚" / "5分钟前 …").
    /// Dedupes repeats of the same event kind (keeps the most recent), caps at 3.
    private func renderRecentEvents() -> [String] {
        let now = Date()
        var seen = Set<String>()
        var picked: [(Date, PetEvent)] = []
        for entry in eventLog.reversed() {
            let key = String(describing: entry.1)
            if seen.insert(key).inserted { picked.append(entry) }
            if picked.count == 3 { break }
        }
        return picked.reversed().map { entry in
            let mins = Int(now.timeIntervalSince(entry.0) / 60)
            let what = entry.1.render()
            return mins < 1 ? "刚刚\(what)" : "\(mins)分钟前\(what)"
        }
    }

    /// Remember something notable; feeds the LLM's situational awareness.
    func logEvent(_ e: PetEvent) {
        if let kind = PetInteraction(rawValue: String(describing: e)) { brain.memory.record(kind) }
        eventLog.append((Date(), e))
        let cutoff = Date().addingTimeInterval(-15 * 60)
        eventLog.removeAll { $0.0 < cutoff }
        if eventLog.count > 6 { eventLog.removeFirst(eventLog.count - 6) }
    }

    func currentContext() -> PetContext {
        let hour = Calendar.current.component(.hour, from: Date())
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        let hint: String
        let perched = currentPlatformID != nil
        switch (core.isSleeping, core.activity) {
        case (_, _) where wallAttachment != nil:
            let side = wallAttachment?.side == .left ? "左" : "右"
            let pose = core.wallReveal > 0.5 ? "鼠标靠近时正从墙后弹出身子打招呼" : "只探出眼睛以上的小脸，嘴巴和身体藏在墙后"
            hint = "固定在屏幕\(side)侧墙上，\(pose)\(core.isSleeping ? "，正在打盹" : "，看着主人")。鼠标移开会缩回，只有主人拖走或明确要求移动时才离墙"
        case (true, _) where perched:
            hint = "趴在一个应用窗口顶上打盹(刚被吵醒)"
        case (true, _): hint = "睡觉(刚被吵醒)"
        case (_, .walk) where perched:
            hint = "在一个应用窗口的顶边上走来走去"
        case (_, .walk): hint = "在桌面上散步"
        case (_, .play): hint = "玩毛线球"
        case (_, .rollPose): hint = "侧身打滚，翻出小肚皮后站稳"
        case (_, .wave): hint = "挥爪招手"
        case (_, .nod): hint = "点头回应主人"
        case (_, .shakeHead): hint = "轻轻摇头"
        case (_, .dance): hint = "跳舞"
        case (_, .spinPose): hint = "转圈"
        case (_, .stretchPose): hint = "伸懒腰"
        case (_, .eat): hint = "吃东西"
        case (_, .jumpPose), (_, .fall):
            hint = "在空中跳跃"
        default:
            hint = perched
                ? "蹲在一个应用窗口顶上,居高临下看着主人"
                : "待在桌面上陪主人"
        }
        return PetContext(
            stats: core.stats,
            activityHint: hint,
            timeOfDay: Persona.timeOfDay(hour: hour),
            clockString: df.string(from: Date()),
            recentEvents: renderRecentEvents(),
            companionMinutes: Int(Date().timeIntervalSince(sessionStart) / 60))
    }

    /// User chat message → think anim → stream into bubble + chat, apply emotion,
    /// and OBEY: commands detected in the message are executed even if the model
    /// forgets to emit the action tag.
    func userSays(_ text: String) {
        cancelPreparation()
        if let reply = brain.memory.handleCommand(text) {
            bubbleStreaming = false
            bubble?.show(text: reply, above: bubbleAnchor, petScale: scale)
            bubbleHideAt = Date().addingTimeInterval(bubbleDuration(for: reply))
            chatMirror?(reply, false)
            chatMirror?(reply, true)
            return
        }
        if brain.isReady, let tool = conversationTools?.matching(text) {
            let revision = preparationRevision
            if core.isSleeping { wake(grumpy: false) }
            if core.activity == .idle || core.activity == .walk || core.activity == .talk { core.activity = .think }
            bubble?.show(text: "…", above: bubbleAnchor, petScale: scale)
            bubbleStreaming = true
            core.brainState = .generating
            preparationTask = Task { [weak self] in
                let result = await tool.prepare(text)
                guard let self, !Task.isCancelled, self.preparationRevision == revision else { return }
                self.preparationTask = nil
                self.bubbleStreaming = false
                self.core.brainState = .ready
                if self.core.activity == .think { self.core.activity = .idle }
                self.respondToUser(text, toolResult: result)
            }
            return
        }
        respondToUser(text)
    }

    private func cancelPreparation() {
        preparationRevision += 1; preparationTask?.cancel(); preparationTask = nil
        if !brain.isGenerating, brain.isReady { core.brainState = .ready }
    }

    private func respondToUser(_ text: String, toolResult: String? = nil) {
        // priority: goodnight (owner going to bed) > creative asks > motion commands
        let goodnight = Persona.detectGoodnight(text)
        let creative = goodnight ? nil : Persona.detectCreative(text)
        let interpretation = ActionLibrary.interpret(text)
        let intent = (goodnight || creative != nil) ? nil : interpretation.requested
        if core.isSleeping, intent != .sleep, intent != .stop { wake(grumpy: false) }

        // 识别和执行不依赖网络。模型没就绪时，明确指令仍有动作和一句本地回应。
        guard brain.isReady else {
            let action = intent ?? (goodnight ? .sleep : nil)
            var line = action.map { "好喵，\(ActionLibrary.entry($0).name)！" } ?? L10n.t("chat.failed")
            bubbleHideAt = Date().addingTimeInterval(bubbleDuration(for: line))
            if let action, !requestAction(action) { line = "等你放下我，再来做这个动作喵。" }
            bubble?.show(text: line, above: bubbleAnchor, petScale: scale)
            bubbleHideAt = Date().addingTimeInterval(bubbleDuration(for: line))
            chatMirror?(line, false); chatMirror?(line, true)
            return
        }
        var hint = goodnight
            ? Persona.goodnightHint()
            : creative.map { Persona.creativeInstruction($0) }
                ?? intent.map { Persona.commandHint($0) }
        if let toolResult { hint = (hint.map { $0 + "\n" } ?? "") + toolResult }
        if core.activity == .idle || core.activity == .walk || core.activity == .talk { core.activity = .think }
        core.setEmotion(.curious, hold: 30)
        // 明确动作先开始，回复可以同时生成；同一轮完成后不重复执行模型标签。
        let startedExplicitAction = intent != .sleep && intent.map { requestAction($0) } == true
        bubble?.show(text: "…", above: bubbleAnchor, petScale: scale)
        bubbleStreaming = true
        brain.generate(
            userContent: text,
            context: currentContext(),
            recordHistory: true,
            commandHint: hint,
            creative: creative.map { ($0, L10n.creativeCanned($0)) },
            thinking: settings.thinkingEnabled,
            onEmotion: { [weak self] emo in
                guard let self else { return }
                self.core.setEmotion(emo, hold: 20)
                self.applyEmotionBurst(emo)
            },
            onText: { [weak self] text in
                guard let self else { return }
                if self.core.activity == .think { self.core.activity = .talk }
                self.bubble?.update(text: text)
                self.chatMirror?(text, false)
            },
            onDone: { [weak self] parsed in
                guard let self else { return }
                self.bubbleStreaming = false
                if let parsed, !parsed.text.isEmpty {
                    self.bubble?.update(text: parsed.text)
                    self.chatMirror?(parsed.text, true)
                    self.bubbleHideAt = Date().addingTimeInterval(self.bubbleDuration(for: parsed.text) + 2)
                    self.core.stats.happiness += 2.5
                    self.core.stats.clamp()
                    if self.core.activity == .think { self.core.activity = .talk }
                } else {
                    // brain came up empty — react with a cute confused fallback
                    let line = self.brain.lastError.map { L10n.t("chat.requestFailed") + " " + $0 }
                        ?? L10n.canned(.confused)
                    self.core.setEmotion(.curious, hold: 4)
                    self.bubble?.update(text: line)
                    self.chatMirror?(line, true)
                    self.bubbleHideAt = Date().addingTimeInterval(4)
                    if self.core.activity == .think { self.core.activity = .talk }
                }
                // owner said goodnight: she says goodnight back, then tucks in too
                if goodnight {
                    self.obey(.sleep)
                    return
                }
                if !startedExplicitAction,
                   let action = ActionLibrary.select(intent: interpretation, proposed: parsed?.action,
                                                     suppressAll: creative != nil) {
                    self.requestAction(action, ownerRequested: intent != nil)
                }
            })
    }

    /// 对话、空闲活动和主动回复共用的入口。明确指令优先，自动动作有冷却且不打断其他动作。
    @discardableResult
    func requestAction(_ action: PetAction, ownerRequested: Bool = true, at now: Date = Date()) -> Bool {
        let entry = ActionLibrary.entry(action)
        guard core.activity != .drag else { return false }
        if !ownerRequested {
            guard entry.maySuggest, !core.isSleeping, !airborne, core.stats.energy >= entry.minimumEnergy,
                  wallAttachment == nil || !entry.leavesWall,
                  !core.activity.isBusy || core.activity == .think || core.activity == .talk,
                  now.timeIntervalSince(lastSuggestedActionAt) >= 8,
                  now.timeIntervalSince(lastActionAt[action] ?? .distantPast) >= entry.cooldown else { return false }
        }
        if ownerRequested {
            actionAfterLanding = nil
            motionRevision &+= 1
            if action != .come { chasingCursor = false }
        }
        if airborne, action != .stop {
            guard ownerRequested else { return false }
            actionAfterLanding = action
            return true
        }
        if ownerRequested, action != .sleep, action != .stop, core.isSleeping { wake(grumpy: false) }
        if ownerRequested, !airborne, core.activity != .sleep {
            core.activity = .idle
            core.actionPhase = 0
        }
        lastActionAt[action] = now
        if !ownerRequested { lastSuggestedActionAt = now }
        obey(action, ownerRequested: ownerRequested)
        return true
    }

    /// Execute a commanded action, sequenced so it doesn't stomp the reply bubble.
    func obey(_ action: PetAction, ownerRequested: Bool = true) {
        if ownerRequested { actionAfterLanding = nil }
        if wallAttachment != nil, action.leavesWall {
            guard ownerRequested else { return }
            leaveWall()
            if action == .down { return }
            if action != .come {
                actionAfterLanding = action
                return
            }
        }
        if action == .stop { actionAfterLanding = nil }
        if action != .sleep {
            pendingSleep?.cancel()   // a newer command overrides a queued goodnight
            pendingSleep = nil
        }
        switch action {
        case .sleep:
            // let her finish saying goodnight first
            let delay = max(0, bubbleHideAt.timeIntervalSinceNow) + 0.4
            pendingSleep?.cancel()
            pendingSleep = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, !self.core.isSleeping, self.core.activity != .drag else { return }
                self.fallAsleep(commanded: true)
            }
        case .wake:
            wake(grumpy: false)
            core.setEmotion(.happy, hold: 4)
            hopInPlace()
        case .come:
            callOver()
        case .walk:
            // .talk is "busy" but walking while finishing the sentence is fine
            guard !core.activity.isBusy || core.activity == .talk, !airborne else { return }
            let span = surfaceSpan()
            if span.hi - span.lo > 40 {
                walkTargetX = .random(in: span.lo...span.hi)
                walkDir = walkTargetX > petCenter.x ? 1 : -1
                core.activity = .walk
            }
        case .climb:
            guard !airborne else { return }
            let ups = tracker.reachable(from: standY - feetDrop)
            if let p = ups.min(by: { $0.y < $1.y }) {
                let lo = max(p.minX + 20, petCenter.x - 460)
                let hi = min(p.maxX - 20, petCenter.x + 460)
                if lo < hi {
                    jumpTo(targetX: .random(in: lo...hi), surfaceY: p.y, ontoPlatform: true)
                    return
                }
            }
            hopInPlace()  // no window in reach — cute attempt anyway
        case .down:
            guard currentPlatformID != nil, !airborne else { return }
            let f = screenFrame()
            let tx = min(max(petCenter.x, f.minX + 60), f.maxX - 60)
            jumpTo(targetX: tx, surfaceY: f.minY, ontoPlatform: false)
        case .play:
            guard !core.activity.isBusy || core.activity == .talk else { return }
            core.activity = .play
            core.actionPhase = 0
            activityEndsAt = Date().addingTimeInterval(ActionLibrary.entry(.play).duration)
            core.setEmotion(.playful, hold: 8)
        case .eat:
            guard !airborne else { return }
            feed(fish: true)
        case .stop:
            chasingCursor = false
            if core.isSleeping {
                core.activity = .sleep
            } else if core.activity.isBusy || core.activity == .walk {
                core.actionPhase = 0
                if !airborne { core.activity = .idle }
            }
            core.setEmotion(.calm, hold: 4)
            nextDecision = Date().addingTimeInterval(15)  // stay put for a bit
        case .dance, .spin, .roll, .wave, .nod, .shakeHead, .jump, .stretch:
            perform(action, ownerRequested: ownerRequested)
        }
    }

    /// Spontaneous or event-driven LLM line (not recorded into visible chat history).
    /// Falls back to a canned line if the model returns nothing usable.
    private func runLLMEvent(_ event: String, fallback: (L10n.CannedCategory, Emotion)? = nil) {
        runLLMPrompt(Persona.eventPrompt(event), fallback: fallback)
    }

    private func runLLMPrompt(_ prompt: String, fallback: (L10n.CannedCategory, Emotion)? = nil) {
        guard !core.isSleeping, core.activity != .drag, !brain.isGenerating else { return }
        if core.activity == .idle || core.activity == .walk || core.activity == .talk { core.activity = .think }
        bubbleStreaming = true
        bubble?.show(text: "…", above: bubbleAnchor, petScale: scale)
        brain.generate(
            userContent: prompt,
            context: currentContext(),
            recordHistory: false,
            onEmotion: { [weak self] emo in
                self?.core.setEmotion(emo, hold: 15)
                self?.applyEmotionBurst(emo)
            },
            onText: { [weak self] text in
                guard let self else { return }
                if self.core.activity == .think { self.core.activity = .talk }
                self.bubble?.update(text: text)
            },
            onDone: { [weak self] parsed in
                guard let self else { return }
                self.bubbleStreaming = false
                if let parsed, !parsed.text.isEmpty {
                    self.bubble?.update(text: parsed.text)
                    self.bubbleHideAt = Date().addingTimeInterval(self.bubbleDuration(for: parsed.text))
                    // remember what she said on her own — later chats build on it
                    self.brain.noteAssistantLine(parsed.text)
                    // spontaneous/event lines: only motion actions. [sleep] misfires,
                    // [eat] would be self-feeding (mouth moves with no bubble context),
                    if let action = parsed.action {
                        self.requestAction(action, ownerRequested: false)
                    }
                } else if let (cat, emo) = fallback {
                    if self.core.activity == .think { self.core.activity = .idle }
                    self.showCanned(cat, emotion: emo)
                } else {
                    self.bubble?.hide()
                    if self.core.activity == .think || self.core.activity == .talk {
                        self.core.activity = .idle
                    }
                }
            })
    }

    private func applyEmotionBurst(_ emo: Emotion) {
        switch emo {
        case .love: core.spawn(.heart, count: 3, near: CGPoint(x: 0, y: 40))
        case .excited, .happy: core.spawn(.sparkle, count: 3, near: CGPoint(x: 0, y: 45))
        case .surprised: core.spawn(.exclamation, count: 1, near: CGPoint(x: 0, y: 55), spread: 4)
        case .curious: core.spawn(.question, count: 1, near: CGPoint(x: 0, y: 55), spread: 4)
        case .angry: core.spawn(.sweat, count: 1, near: CGPoint(x: 18, y: 45), spread: 4)
        default: break
        }
    }

    func perform(_ action: PetAction, ownerRequested: Bool = true) {
        if wallAttachment != nil, action.leavesWall {
            obey(action, ownerRequested: ownerRequested)
            return
        }
        guard core.activity != .drag, !airborne else { return }
        core.actionPhase = 0
        let entry = ActionLibrary.entry(action)
        if let pose = entry.pose {
            core.activity = pose
            activityEndsAt = Date().addingTimeInterval(entry.duration)
            if ownerRequested || core.emotionUntil < Date() {
                core.setEmotion(ownerRequested && action == .roll ? .playful : core.baselineEmotion,
                                hold: entry.duration + 1)
            }
            return
        }
        switch action {
        case .jump:
            hopInPlace()
        case .sleep:
            fallAsleep()
        case .wake, .come, .walk, .climb, .down, .play, .eat, .stop:
            obey(action, ownerRequested: ownerRequested)
        case .dance, .spin, .roll, .wave, .nod, .shakeHead, .stretch:
            break // 已由动作库中的 pose 执行
        }
    }

    // MARK: - Spontaneous chatter

    /// Due time derives from the last line + current settings, so changing the
    /// chattiness setting takes effect immediately. Once due, we retry every tick
    /// until the pet is actually free to speak — busy moments delay, never skip.
    private func scheduleChatter(initial: Bool = false) {
        chatterJitter = Double.random(in: 0.7...1.5)
        lastChatterAt = initial
            ? Date().addingTimeInterval(-max(2, settings.chatterFreq) * 60 * chatterJitter + .random(in: 60...110))
            : Date()
    }

    private func updateChatter(_ now: Date) {
        guard settings.chatterEnabled, !hasPriorityNotice() else { return }
        let quietFactor = brain.memory.tendencies.prefersQuiet ? 3.0 : 1.0
        let due = lastChatterAt.addingTimeInterval(max(2, settings.chatterFreq) * 60 * chatterJitter * quietFactor)
        guard now > due else { return }
        guard !core.isSleeping, core.activity == .idle || core.activity == .walk,
            bubbleHideAt == .distantPast, !bubbleStreaming, !airborne
        else { return }  // still due — retries next tick

        scheduleChatter()
        let hour = Calendar.current.component(.hour, from: now)
        let timeCat: L10n.CannedCategory = hour < 5 ? .night : hour < 11 ? .morning : hour < 18 ? .afternoon : hour < 23 ? .evening : .night
        if brain.isReady, !brain.isGenerating, Double.random(in: 0..<1) < 0.75 {
            core.activity = .idle
            let prompt = Persona.spontaneousPrompt(currentContext())
            runLLMPrompt(prompt, fallback: (timeCat, .happy))
        } else {
            showCanned(Double.random(in: 0..<1) < 0.5 ? timeCat : .bored, emotion: nil, remember: true)
        }
    }

    // MARK: - User interactions

    func pokeTap() {
        if core.isSleeping {
            wake(grumpy: true)
            return
        }
        let now = Date()
        recentPokes = recentPokes.filter { now.timeIntervalSince($0) < 3 } + [now]
        core.squash = 0.12
        if recentPokes.count >= 4 {
            recentPokes.removeAll()
            logEvent(.pokedALot)
            core.setEmotion(.angry, hold: 5)
            core.spawn(.sweat, count: 1, near: CGPoint(x: 20, y: 45), spread: 4)
            core.stats.happiness -= 2
            core.stats.clamp()
            showCanned(.pokeAnnoyed, emotion: .angry)
        } else {
            core.setEmotion(.surprised, hold: 2.5)
            if Double.random(in: 0..<1) < 0.55 { showCanned(.poke, emotion: nil) }
        }
    }

    func petStroke() {
        let now = Date()
        guard now.timeIntervalSince(lastPetStroke) > 2.5 else { return }
        lastPetStroke = now
        logEvent(.petted)
        guard !core.isSleeping else {
            core.spawn(.heart, count: 1, near: CGPoint(x: 0, y: 40))
            return
        }
        core.setEmotion(.love, hold: 4)
        core.spawn(.heart, count: 3, near: CGPoint(x: 0, y: 42))
        core.stats.happiness += 4
        core.stats.clamp()
        if now.timeIntervalSince(lastEventLLM) > 90, brain.isReady, !brain.isGenerating,
            Double.random(in: 0..<1) < 0.35
        {
            lastEventLLM = now
            runLLMEvent(
                "主人温柔地摸了摸你的头",
                fallback: (.petted, .love))
        } else if Double.random(in: 0..<1) < 0.5 {
            showCanned(.petted, emotion: .love)
        }
    }

    func feed(fish: Bool) {
        if core.isSleeping { wake(grumpy: false) }
        guard !core.activity.isBusy || core.activity == .talk else { return }
        if core.stats.fullness > 92 {
            showCanned(.fullTummy, emotion: .shy)
            return
        }
        core.activity = .eat(food: fish ? "🐟" : "🍪")
        logEvent(fish ? .fedFish : .fedCookie)
        core.actionPhase = 0
        activityEndsAt = Date().addingTimeInterval(ActionLibrary.entry(.eat).duration)
        core.stats.fullness += fish ? 34 : 24
        core.stats.happiness += 6
        core.stats.clamp()
        let now = Date()
        if now.timeIntervalSince(lastEventLLM) > 90, brain.isReady, !brain.isGenerating,
            Double.random(in: 0..<1) < 0.4
        {
            lastEventLLM = now
            let what = fish
                ? "主人喂了你最爱的小鱼干"
                : "主人喂了你小饼干"
            // let the munching play out first; delay the LLM line slightly
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3.4))
                self?.runLLMEvent(what, fallback: (fish ? .fedFish : .fedCookie, .happy))
            }
        } else {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3.4))
                self?.showCanned(fish ? .fedFish : .fedCookie, emotion: .happy)
            }
        }
    }

    func play() {
        if core.isSleeping { wake(grumpy: false) }
        guard !core.activity.isBusy else { return }
        core.activity = .play
        core.actionPhase = 0
        activityEndsAt = Date().addingTimeInterval(ActionLibrary.entry(.play).duration)
        core.setEmotion(.playful, hold: 8)
        showCanned(.playStart, emotion: .playful)
    }

    /// `commanded`: the owner explicitly asked (chat command / menu / quick action).
    /// Commanded naps stick for a while even at full energy — otherwise the
    /// energy>96 auto-wake cancels the nap on the very next tick.
    func fallAsleep(commanded: Bool = false) {
        guard !core.isSleeping else { return }
        core.isSleeping = true
        logEvent(.fellAsleep)
        core.activity = .sleep
        core.setEmotion(.sleepy, hold: 3)
        minSleepUntil = commanded ? Date().addingTimeInterval(300) : .distantPast
        bubble?.hide()
        bubbleHideAt = .distantPast
    }

    func wake(grumpy: Bool) {
        guard core.isSleeping else { return }
        core.isSleeping = false
        core.activity = .idle
        lastWokeAt = Date()
        minSleepUntil = .distantPast
        if grumpy {
            logEvent(.wokenByOwner)
            core.setEmotion(.angry, hold: 4)
            showCanned(.wokenGrumpy, emotion: .sleepy)
            core.stats.happiness -= 1
            core.stats.clamp()
        }
        nextDecision = Date().addingTimeInterval(5)
    }

    func callOver() {
        leaveWall()
        if core.isSleeping { wake(grumpy: false) }
        let mouse = mouseLocation()
        let f = screenFrame()
        let targetX = min(max(mouse.x, f.minX + 60), f.maxX - 60)
        if currentPlatformID != nil {
            // leap down first; walk over after landing
            jumpTo(targetX: min(max(targetX, petCenter.x - 380), petCenter.x + 380),
                   surfaceY: f.minY, ontoPlatform: false)
        }
        walkTargetX = targetX
        walkDir = walkTargetX > petCenter.x ? 1 : -1
        chasingCursor = true
        if !airborne { core.activity = .walk }
        core.setEmotion(.excited, hold: 6)
    }

    // MARK: - Dragging

    func beginDrag() {
        brainInterruptForDrag()
        clearWallAttachment()
        motionRevision &+= 1
        actionAfterLanding = nil
        gentleWallRelease = false
        chasingCursor = false
        deliberateJump = false
        pendingSleep?.cancel(); pendingSleep = nil
        core.activity = .drag
        airborne = false
        gravity = 2600
        currentPlatformID = nil
        if core.isSleeping {
            core.isSleeping = false
            lastWokeAt = Date()
        }
        core.setEmotion(brain.memory.tendencies.cautiousWhenHeld ? .shy : .surprised, hold: 3)
    }

    private func brainInterruptForDrag() {
        cancelPreparation()
        if bubbleStreaming {
            brain.cancelGeneration()
            bubbleStreaming = false
            chatMirror?("", true)
            bubble?.hide()
            bubbleHideAt = .distantPast
        }
    }

    func dragTo(_ point: CGPoint) {
        petCenter = point
        moveWindow?(petCenter)
        bubble?.reposition(above: bubbleAnchor, petScale: scale)
    }

    func endDrag(velocity v: CGVector, pointer: CGPoint? = nil) {
        if let attachment = WallDock.attachment(center: petCenter, pointer: pointer, scale: scale, screens: screens()) {
            attachToWall(attachment)
            return
        }
        velocity = CGVector(dx: max(-900, min(900, v.dx)), dy: max(-200, min(1100, v.dy)))
        prevFeetY = petCenter.y - feetDrop
        if petCenter.y > groundY + 2 || abs(velocity.dy) > 50 {
            airborne = true
        } else {
            petCenter.y = groundY
            core.activity = .idle
            moveWindow?(petCenter)
        }
        if core.activity == .drag { core.activity = airborne ? .fall : .idle }
        nextDecision = Date().addingTimeInterval(2)
    }

    // MARK: - Chat window awareness

    func chatOpened() {
        core.attention = 1
        if core.isSleeping { wake(grumpy: false) }
        if brain.memory.tendencies.familiarity > 0.2 { core.setEmotion(.love, hold: 4) }
    }

    func chatClosed() {
        core.attention = 0
    }

    func reloadBrain() {
        cancelPreparation()
        brain.cancelGeneration()
        bubbleStreaming = false
        bubble?.hide()
        bubbleHideAt = .distantPast
        chatMirror?("", true)
        if core.activity == .think || core.activity == .talk { core.activity = .idle }
        brain.load()
    }

    func shutdown() {
        cancelPreparation()
        timer?.invalidate()
        brain.memory.cancelLearning()
        brain.memory.presence()
        brain.memory.flush()
        Persistence.saveStats(core.stats)
    }

    func resetConversationContext() {
        cancelPreparation()
        conversationTools?.reset()
        bubbleStreaming = false
        bubble?.hide()
        bubbleHideAt = .distantPast
        eventLog.removeAll()
        if core.activity == .think || core.activity == .talk { core.activity = .idle }
    }
}

/// Implemented by the bubble window controller.
@MainActor
protocol BubbleController: AnyObject {
    func show(text: String, above petCenter: CGPoint, petScale: CGFloat)
    func update(text: String)
    func reposition(above petCenter: CGPoint, petScale: CGFloat)
    func hide()
}
