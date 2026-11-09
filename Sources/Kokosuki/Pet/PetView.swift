import SwiftUI

/// Layout constants shared between the renderer and the engine/window code.
enum PetLayout {
    static let designSide: CGFloat = 200      // design coordinate space
    static let windowSide: CGFloat = 230      // window px at scale 1 (margin for effects)
    static let feetY: CGFloat = 170           // feet line in design space
    static let centerY: CGFloat = 100

    static func windowSize(scale: CGFloat) -> CGFloat { windowSide * scale }
    static func renderSize(scale: CGFloat, wallSide: WallSide?, wallReveal: Double = 0) -> CGSize {
        if wallSide != nil { return WallDock.size(scale: scale, reveal: wallReveal) }
        let side = windowSize(scale: scale)
        return CGSize(width: side, height: side)
    }
    static func feetDrop(scale: CGFloat) -> CGFloat {
        (feetY - centerY) * (windowSize(scale: scale) / designSide)
    }
    /// Rough hit region: is a point (in window coords, top-left origin) on the cat?
    static func hitTest(_ p: CGPoint, windowSide side: CGFloat) -> Bool {
        let k = side / designSide
        let body = CGRect(x: 38 * k, y: 48 * k, width: 124 * k, height: 132 * k)
        return body.contains(p)
    }

    /// 与怀中信件共用的设计坐标；返回画布左上原点的命中区域。
    static func letterHitRect(size: CGSize, wallSide: WallSide?, reveal: Double) -> CGRect {
        let rect = CGRect(x: 65, y: 114, width: 70, height: 47)
        guard let side = wallSide else {
            let k = size.width / designSide
            return CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k)
        }
        let design = WallDock.designSize(reveal: reveal)
        let axisY = WallDock.designHeight / 2 + (side == .right ? design.height - WallDock.designHeight : 0)
        let x = side == .left ? WallDock.cutoff(reveal: reveal) - rect.maxY : rect.minY - WallDock.topY
        let y = side == .left ? axisY + rect.minX - 100 : axisY - (rect.maxX - 100)
        return CGRect(x: x * size.width / design.width, y: y * size.height / design.height,
                      width: rect.height * size.width / design.width, height: rect.width * size.height / design.height)
    }
}

struct PetView: View {
    // deliberately NOT @ObservedObject: the timeline drives redraws and reads a
    // snapshot imperatively, so published churn would only add diffing cost
    let core: PetCore

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let state = core.snapshot()
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas(rendersAsynchronously: false) { ctx, size in
                var painter = PetPainter(s: state, t: t)
                painter.draw(in: &ctx, size: size)
            }
        }
        // AppKit 的窗口/宿主约束决定实际大小。不能在 TimelineView 外读取非 Published
        // 的 wallSide 来固定 frame，否则同尺寸参数下切换模式时会沿用旧的大画布并被裁切。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

// MARK: - Painter

struct PetPainter {
    let s: PetRenderState
    let t: Double

    // palette
    static let cream = Color(red: 1.00, green: 0.93, blue: 0.82)
    static let creamShade = Color(red: 0.96, green: 0.86, blue: 0.72)
    static let belly = Color(red: 1.00, green: 0.97, blue: 0.91)
    static let cocoa = Color(red: 0.36, green: 0.27, blue: 0.21)
    static let pink = Color(red: 1.00, green: 0.70, blue: 0.76)
    static let deepPink = Color(red: 0.98, green: 0.55, blue: 0.63)
    static let blushPink = Color(red: 1.00, green: 0.75, blue: 0.79)

    var line: GraphicsContext.Shading { .color(Self.cocoa) }
    let lw: CGFloat = 3.0

    mutating func draw(in ctx: inout GraphicsContext, size: CGSize) {
        if let side = s.wallSide {
            drawWallPeek(in: &ctx, size: size, side: side)
            return
        }
        let k = size.width / PetLayout.designSide
        ctx.scaleBy(x: k, y: k)

        // ---- whole-body transform ----------------------------------------
        let a = s.activity
        var bob: CGFloat = 0
        var rotate: Angle = .zero
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
        let rolling = a == .rollPose

        let breathe = sin(t * (s.isSleeping ? 1.4 : 2.4)) * (s.isSleeping ? 0.030 : 0.015)
        scaleY += breathe
        scaleX -= breathe * 0.6

        switch a {
        case .walk:
            bob = -abs(sin(s.walkPhase)) * 5
            rotate = .degrees(sin(s.walkPhase) * 2.5)
        case .drag:
            scaleY *= 1.10
            scaleX *= 0.93
            rotate = .degrees(sin(t * 9) * 6 * s.pickupWiggle)
        case .fall:
            scaleY *= 1.08
            rotate = .degrees(sin(t * 13) * 4)
        case .jumpPose:
            scaleY *= 1.10
            scaleX *= 0.94
            rotate = .degrees(4)
        case .sleep:
            scaleY *= 0.80
            scaleX *= 1.10
        case .dance:
            bob = -abs(sin(t * 5.6)) * 7
            rotate = .degrees(sin(t * 5.6) * 9)
        case .spinPose:
            let p = min(1, s.actionPhase / ActionLibrary.entry(.spin).duration)
            let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
            rotate = .degrees(eased * 720)
            bob = -sin(p * .pi) * 10
        case .stretchPose:
            let p = min(1, s.actionPhase / ActionLibrary.entry(.stretch).duration)
            let arc = sin(p * .pi)
            rotate = .degrees(-arc * 10)
            scaleX *= 1 + arc * 0.16
            scaleY *= 1 - arc * 0.10
        case .rollPose:
            let p = min(1, max(0, s.actionPhase / ActionLibrary.entry(.roll).duration))
            let turn = min(1, max(0, (p - 0.12) / 0.76))
            let eased = turn * turn * (3 - 2 * turn)
            rotate = .degrees(eased * 360)
            let tuck = sin(p * .pi)
            scaleX *= 1 - tuck * 0.14
            scaleY *= 1 - tuck * 0.14
            bob = -abs(sin(eased * 2 * .pi)) * 28 - tuck * 7
        case .land:
            scaleY *= (1 - s.squash)
            scaleX *= (1 + s.squash * 0.8)
        default:
            break
        }
        scaleY *= (1 - s.squash)
        scaleX *= (1 + s.squash * 0.7)

        // 打滚绕身体中心翻身，影子留在地上；其他动作仍以脚底为锚点。
        if rolling {
            drawShadow(&ctx, lifted: false)
            ctx.translateBy(x: 0, y: bob)
            bob = 0
        }
        let pivotY: CGFloat = rolling ? 112 : PetLayout.feetY
        ctx.translateBy(x: 100, y: pivotY)
        if !s.facingRight { ctx.scaleBy(x: -1, y: 1) }
        ctx.rotate(by: rotate)
        ctx.scaleBy(x: scaleX, y: scaleY)
        ctx.translateBy(x: -100, y: -pivotY + bob)

        // ---- shadow ------------------------------------------------------
        if !rolling { drawShadow(&ctx, lifted: a == .drag || a == .fall) }

        // ---- tail (behind body) -----------------------------------------
        drawTail(&ctx)

        // ---- body blob ---------------------------------------------------
        drawBody(&ctx)

        // ---- ears --------------------------------------------------------
        var head = ctx
        if a == .nod || a == .shakeHead {
            let action: PetAction = a == .nod ? .nod : .shakeHead
            let p = min(1, s.actionPhase / ActionLibrary.entry(action).duration)
            let gesture = sin(p * .pi * 4) * sin(p * .pi)
            head.translateBy(x: a == .shakeHead ? gesture * 6 : 0, y: a == .nod ? gesture * 5 : 0)
            head.translateBy(x: 100, y: 88)
            head.rotate(by: .degrees(gesture * (a == .shakeHead ? 7 : 2)))
            head.translateBy(x: -100, y: -88)
        }
        drawEars(&head)

        // ---- face --------------------------------------------------------
        drawFace(&head)

        // ---- paws --------------------------------------------------------
        drawPaws(&ctx)

        // ---- extras (food, yarn, dizzy stars, think dots) ----------------
        drawExtras(&ctx)
        drawHeldLetter(&ctx)

        // ---- particles (unrotated space would be nicer, but this is fine) -
        drawParticles(&ctx)
    }

    // MARK: body pieces

    /// 同一只小喵从墙后滑出：收起时裁在眼睛下面，靠近时露出身体和摇动的尾巴。
    private func drawWallPeek(in ctx: inout GraphicsContext, size: CGSize, side: WallSide) {
        let design = WallDock.designSize(reveal: s.wallReveal)
        ctx.scaleBy(x: size.width / design.width, y: size.height / design.height)
        ctx.clip(to: Path(CGRect(origin: .zero, size: design)))
        ctx.translateBy(x: side == .left ? WallDock.cutoff(reveal: s.wallReveal) : -WallDock.topY,
                        y: WallDock.designHeight / 2 + (side == .right ? design.height - WallDock.designHeight : 0))
        ctx.rotate(by: .degrees(side == .left ? 90 : -90))
        ctx.translateBy(x: -100, y: 0)
        // 身体露出后尾巴才一起出现，避免收起时尾尖单独浮在上半张脸旁。
        var tail = ctx
        tail.opacity *= min(1, max(0, (s.wallReveal - 0.45) / 0.3))
        drawTail(&tail)
        drawBody(&ctx)
        drawEars(&ctx)
        drawFace(&ctx)
        drawPaws(&ctx)
        drawHeldLetter(&ctx)
    }

    private func drawHeldLetter(_ ctx: inout GraphicsContext) {
        guard s.unreadLetters > 0 else { return }
        ctx.draw(Text("💌").font(.system(size: 32)), at: CGPoint(x: 100, y: 138))
        for x: CGFloat in [76, 111] {
            let paw = Path(roundedRect: CGRect(x: x, y: 134, width: 13, height: 17), cornerRadius: 6)
            ctx.fill(paw, with: .color(Self.cream)); ctx.stroke(paw, with: line, style: .init(lineWidth: 2.1))
            var crease = Path(); crease.move(to: CGPoint(x: x + 5, y: 139)); crease.addLine(to: CGPoint(x: x + 5, y: 146))
            ctx.stroke(crease, with: .color(Self.cocoa.opacity(0.5)), style: .init(lineWidth: 1.3, lineCap: .round))
        }
        let count = s.unreadLetters > 99 ? "99+" : String(s.unreadLetters)
        let badge = CGRect(x: 116, y: 115, width: s.unreadLetters > 99 ? 24 : 17, height: 17)
        ctx.fill(Path(roundedRect: badge, cornerRadius: 8.5), with: .color(Self.deepPink))
        ctx.draw(Text(count).font(.system(size: 9, weight: .bold)).foregroundStyle(.white), at: CGPoint(x: badge.midX, y: badge.midY))
    }

    private func drawShadow(_ ctx: inout GraphicsContext, lifted: Bool) {
        let w: CGFloat = lifted ? 44 : 78
        let alpha = lifted ? 0.10 : 0.16
        let rect = CGRect(x: 100 - w / 2, y: 168, width: w, height: 12)
        ctx.fill(Path(ellipseIn: rect), with: .color(.black.opacity(alpha)))
    }

    private func bodyPath() -> Path {
        // daifuku blob: wide rounded bottom, gently narrower top
        var p = Path()
        p.move(to: CGPoint(x: 48, y: 128))
        p.addCurve(to: CGPoint(x: 66, y: 66), control1: CGPoint(x: 46, y: 96), control2: CGPoint(x: 52, y: 74))
        p.addCurve(to: CGPoint(x: 134, y: 66), control1: CGPoint(x: 84, y: 56), control2: CGPoint(x: 116, y: 56))
        p.addCurve(to: CGPoint(x: 152, y: 128), control1: CGPoint(x: 148, y: 74), control2: CGPoint(x: 154, y: 96))
        p.addCurve(to: CGPoint(x: 100, y: 170), control1: CGPoint(x: 152, y: 152), control2: CGPoint(x: 132, y: 170))
        p.addCurve(to: CGPoint(x: 48, y: 128), control1: CGPoint(x: 68, y: 170), control2: CGPoint(x: 48, y: 152))
        p.closeSubpath()
        return p
    }

    private func drawBody(_ ctx: inout GraphicsContext) {
        let body = bodyPath()
        ctx.fill(body, with: .color(Self.cream))
        // belly patch
        let bellyRect = CGRect(x: 76, y: 118, width: 48, height: 42)
        ctx.fill(Path(ellipseIn: bellyRect), with: .color(Self.belly))
        drawHeadStripes(&ctx)
        ctx.stroke(body, with: line, style: .init(lineWidth: lw, lineCap: .round, lineJoin: .round))
    }

    private func drawHeadStripes(_ ctx: inout GraphicsContext) {
        var s1 = Path()
        s1.move(to: CGPoint(x: 94, y: 58))
        s1.addQuadCurve(to: CGPoint(x: 92, y: 70), control: CGPoint(x: 91, y: 64))
        var s2 = Path()
        s2.move(to: CGPoint(x: 106, y: 58))
        s2.addQuadCurve(to: CGPoint(x: 108, y: 70), control: CGPoint(x: 109, y: 64))
        ctx.stroke(s1, with: .color(Self.creamShade), style: .init(lineWidth: 4, lineCap: .round))
        ctx.stroke(s2, with: .color(Self.creamShade), style: .init(lineWidth: 4, lineCap: .round))
    }

    private func drawEars(_ ctx: inout GraphicsContext) {
        let flatten: CGFloat = s.emotion == .angry || s.activity == .drag ? 10 : 0
        let twitch = s.earTwitch * sin(t * 26) * 3
        let perk: CGFloat = s.attention > 0.5 || s.emotion == .curious ? -4 : 0

        func ear(cx: CGFloat, dir: CGFloat, extraRot: CGFloat) {
            var p = Path()
            let baseY: CGFloat = 70 + flatten * 0.4
            let tipY: CGFloat = 34 + flatten + perk
            p.move(to: CGPoint(x: cx - 16 * dir, y: baseY))
            p.addQuadCurve(to: CGPoint(x: cx + 6 * dir, y: tipY),
                           control: CGPoint(x: cx - 14 * dir, y: tipY + 4))
            p.addQuadCurve(to: CGPoint(x: cx + 17 * dir, y: baseY - 2),
                           control: CGPoint(x: cx + 18 * dir, y: tipY + 14))
            p.closeSubpath()

            var inner = Path()
            inner.move(to: CGPoint(x: cx - 6 * dir, y: baseY - 3))
            inner.addQuadCurve(to: CGPoint(x: cx + 4 * dir, y: tipY + 10),
                               control: CGPoint(x: cx - 6 * dir, y: tipY + 10))
            inner.addQuadCurve(to: CGPoint(x: cx + 10 * dir, y: baseY - 4),
                               control: CGPoint(x: cx + 11 * dir, y: tipY + 18))
            inner.closeSubpath()

            var c = ctx
            c.translateBy(x: cx, y: baseY)
            c.rotate(by: .degrees(extraRot * dir))
            c.translateBy(x: -cx, y: -baseY)
            c.fill(p, with: .color(Self.cream))
            c.stroke(p, with: line, style: .init(lineWidth: lw, lineCap: .round, lineJoin: .round))
            c.fill(inner, with: .color(Self.pink))
        }
        ear(cx: 72, dir: 1, extraRot: twitch)
        ear(cx: 128, dir: -1, extraRot: s.emotion == .curious ? 8 : 0)
    }

    private func drawFace(_ ctx: inout GraphicsContext) {
        let emo = s.emotion
        // head tilt for curious/shy
        var c = ctx
        if emo == .curious && s.wallSide == nil {
            c.translateBy(x: 100, y: 90)
            c.rotate(by: .degrees(7))
            c.translateBy(x: -100, y: -90)
        }
        let lookAway = s.wallSide == nil ? s.lookAway * 14 : 0
        c.translateBy(x: -lookAway, y: 0)

        let eyeY: CGFloat = 96
        let eyeDX: CGFloat = 23
        var eo = s.eyeOffset
        if emo == .shy { eo = CGPoint(x: 4.5, y: -2) }  // glance aside bashfully
        if let side = s.wallSide {
            eo = side == .left ? CGPoint(x: -eo.y, y: eo.x) : CGPoint(x: eo.y, y: -eo.x)
            eo.y = min(2, max(-2, eo.y)) // 保证收起时眼睛不会越过墙沿被裁掉。
        }
        let blink = s.isSleeping ? 1.0 : s.blink

        func openEye(cx: CGFloat) {
            let h = 15 * (1 - blink * 0.92)
            var rect = CGRect(x: cx - 6.5 + eo.x, y: eyeY - h / 2 - eo.y, width: 13, height: h)
            switch emo {
            case .surprised, .excited:
                rect = rect.insetBy(dx: -1.5, dy: -2)
            case .sleepy:
                rect = CGRect(x: rect.minX, y: eyeY - h * 0.20 - eo.y, width: 13, height: h * 0.55)
            case .sad:
                rect = rect.insetBy(dx: 0.5, dy: 1.5)
            default: break
            }
            let eye = Path(ellipseIn: rect)
            c.fill(eye, with: .color(Self.cocoa))
            if blink < 0.5 {
                let hl1 = CGRect(x: rect.minX + 2.5, y: rect.minY + 2.2, width: 4.4, height: 4.8)
                let hl2 = CGRect(x: rect.minX + 7.4, y: rect.minY + rect.height * 0.55, width: 2.6, height: 2.8)
                c.fill(Path(ellipseIn: hl1), with: .color(.white.opacity(0.95)))
                c.fill(Path(ellipseIn: hl2), with: .color(.white.opacity(0.8)))
            }
        }

        func happyArcEye(cx: CGFloat) {  // ∩ shape
            var p = Path()
            p.move(to: CGPoint(x: cx - 7, y: eyeY + 3))
            p.addQuadCurve(to: CGPoint(x: cx + 7, y: eyeY + 3), control: CGPoint(x: cx, y: eyeY - 8))
            c.stroke(p, with: line, style: .init(lineWidth: lw + 0.4, lineCap: .round))
        }

        func closedEye(cx: CGFloat) {    // ∪ sleeping
            var p = Path()
            p.move(to: CGPoint(x: cx - 7, y: eyeY - 1))
            p.addQuadCurve(to: CGPoint(x: cx + 7, y: eyeY - 1), control: CGPoint(x: cx, y: eyeY + 7))
            c.stroke(p, with: line, style: .init(lineWidth: lw, lineCap: .round))
        }

        func heartEye(cx: CGFloat) {
            let s: CGFloat = 8.5
            c.fill(heartPath(cx: cx, cy: eyeY, size: s), with: .color(Self.deepPink))
        }

        // eyes per emotion
        switch (s.isSleeping, emo) {
        case (true, _):
            closedEye(cx: 100 - eyeDX)
            closedEye(cx: 100 + eyeDX)
        case (_, .happy), (_, .proud), (_, .playful):
            happyArcEye(cx: 100 - eyeDX)
            happyArcEye(cx: 100 + eyeDX)
        case (_, .love):
            heartEye(cx: 100 - eyeDX)
            heartEye(cx: 100 + eyeDX)
        default:
            openEye(cx: 100 - eyeDX)
            openEye(cx: 100 + eyeDX)
        }

        // brows: sad = inner tips raised (worried), angry = inner tips lowered
        if emo == .sad {
            var b1 = Path(); b1.move(to: CGPoint(x: 70, y: 89)); b1.addLine(to: CGPoint(x: 82, y: 84))
            var b2 = Path(); b2.move(to: CGPoint(x: 130, y: 89)); b2.addLine(to: CGPoint(x: 118, y: 84))
            c.stroke(b1, with: line, style: .init(lineWidth: 2.4, lineCap: .round))
            c.stroke(b2, with: line, style: .init(lineWidth: 2.4, lineCap: .round))
        } else if emo == .angry {
            var b1 = Path(); b1.move(to: CGPoint(x: 70, y: 83)); b1.addLine(to: CGPoint(x: 84, y: 90))
            var b2 = Path(); b2.move(to: CGPoint(x: 130, y: 83)); b2.addLine(to: CGPoint(x: 116, y: 90))
            c.stroke(b1, with: line, style: .init(lineWidth: 2.6, lineCap: .round))
            c.stroke(b2, with: line, style: .init(lineWidth: 2.6, lineCap: .round))
        }

        // blush
        let blushAlpha: Double = {
            switch emo {
            case .shy: return 0.95
            case .love, .happy, .excited: return 0.7
            default: return 0.45
            }
        }()
        c.fill(Path(ellipseIn: CGRect(x: 56, y: 108, width: 16, height: 9)),
               with: .color(Self.blushPink.opacity(blushAlpha)))
        c.fill(Path(ellipseIn: CGRect(x: 128, y: 108, width: 16, height: 9)),
               with: .color(Self.blushPink.opacity(blushAlpha)))

        // whiskers
        for (sx, dir) in [(52, -1.0), (148, 1.0)] {
            for dy in [-2, 5] {
                var w = Path()
                w.move(to: CGPoint(x: CGFloat(sx), y: CGFloat(108 + dy)))
                w.addQuadCurve(
                    to: CGPoint(x: CGFloat(sx) + CGFloat(dir * 14), y: CGFloat(105 + dy * 2)),
                    control: CGPoint(x: CGFloat(sx) + CGFloat(dir * 8), y: CGFloat(106 + dy)))
                c.stroke(w, with: .color(Self.cocoa.opacity(0.6)), style: .init(lineWidth: 1.6, lineCap: .round))
            }
        }

        drawMouth(&c, emo: emo)
    }

    private func drawMouth(_ c: inout GraphicsContext, emo: Emotion) {
        let my: CGFloat = 112
        var eating = false
        if case .eat = s.activity { eating = true }
        let talkOpen = s.talkLevel
        let munchOpen = eating ? (0.5 + 0.5 * sin(t * 10)) : 0
        let open = max(talkOpen, munchOpen)

        if open > 0.15 {
            let h = 4 + open * 8
            let mouth = Path(ellipseIn: CGRect(x: 100 - 5.5, y: my - 1, width: 11, height: h))
            c.fill(mouth, with: .color(Self.cocoa))
            let tongue = Path(ellipseIn: CGRect(x: 100 - 3.5, y: my + h - 5, width: 7, height: 4.2))
            c.fill(tongue, with: .color(Self.deepPink))
            return
        }

        switch emo {
        case .sad:
            var p = Path()
            p.move(to: CGPoint(x: 94, y: my + 5))
            p.addQuadCurve(to: CGPoint(x: 106, y: my + 5), control: CGPoint(x: 100, y: my))
            c.stroke(p, with: line, style: .init(lineWidth: 2.4, lineCap: .round))
        case .angry:
            var p = Path()
            p.move(to: CGPoint(x: 95, y: my + 4))
            p.addLine(to: CGPoint(x: 105, y: my + 4))
            c.stroke(p, with: line, style: .init(lineWidth: 2.4, lineCap: .round))
        case .hungry:
            // wavy wanting mouth
            var p = Path()
            p.move(to: CGPoint(x: 93, y: my + 3))
            p.addQuadCurve(to: CGPoint(x: 100, y: my + 5), control: CGPoint(x: 96, y: my + 7))
            p.addQuadCurve(to: CGPoint(x: 107, y: my + 3), control: CGPoint(x: 104, y: my + 7))
            c.stroke(p, with: line, style: .init(lineWidth: 2.2, lineCap: .round))
        default:
            // ω cat mouth
            var p = Path()
            p.move(to: CGPoint(x: 92, y: my))
            p.addQuadCurve(to: CGPoint(x: 100, y: my + 1.5), control: CGPoint(x: 96, y: my + 5.5))
            p.addQuadCurve(to: CGPoint(x: 108, y: my), control: CGPoint(x: 104, y: my + 5.5))
            c.stroke(p, with: line, style: .init(lineWidth: 2.4, lineCap: .round))
        }
    }

    private func drawTail(_ ctx: inout GraphicsContext) {
        let happyWag = s.happiness > 70 ? 1.6 : 1.0
        let speed = s.activity == .walk ? 6.0 : 2.2 * happyWag
        let sway = sin(t * speed) * (s.isSleeping ? 3 : 12) * happyWag
        var p = Path()
        p.move(to: CGPoint(x: 148, y: 138))
        p.addCurve(
            to: CGPoint(x: 176 + sway, y: 108),
            control1: CGPoint(x: 168, y: 138),
            control2: CGPoint(x: 178 + sway * 0.5, y: 128))
        ctx.stroke(p, with: .color(Self.cream), style: .init(lineWidth: 11, lineCap: .round))
        ctx.stroke(p, with: line, style: .init(lineWidth: lw * 0.8, lineCap: .round))
        // tail tip
        let tip = CGRect(x: 176 + sway - 7, y: 101, width: 14, height: 14)
        ctx.fill(Path(ellipseIn: tip), with: .color(Self.creamShade))
        ctx.stroke(Path(ellipseIn: tip), with: line, style: .init(lineWidth: lw * 0.7))
    }

    private func drawPaws(_ ctx: inout GraphicsContext) {
        var lift1: CGFloat = 0
        var lift2: CGFloat = 0
        var spread: CGFloat = 0
        var waveOffset: CGFloat = 0
        var waving: Double = 0
        switch s.activity {
        case .walk:
            lift1 = max(0, sin(s.walkPhase)) * 6
            lift2 = max(0, -sin(s.walkPhase)) * 6
        case .drag, .fall:
            spread = 8
            lift1 = 4 + sin(t * 10) * 3
            lift2 = 4 - sin(t * 10) * 3
        case .jumpPose:
            lift1 = 7
            lift2 = 7
        case .dance:
            lift1 = max(0, sin(t * 5.6)) * 10
            lift2 = max(0, -sin(t * 5.6)) * 10
        case .wave:
            let p = min(1, s.actionPhase / ActionLibrary.entry(.wave).duration)
            waving = max(0, min(1, p * 5, (1 - p) * 5))
            lift1 = waving * 37
            waveOffset = -waving * 32
            var arm = Path()
            arm.move(to: CGPoint(x: 74, y: 151))
            arm.addQuadCurve(to: CGPoint(x: 82 + waveOffset, y: 162 - lift1), control: CGPoint(x: 58, y: 150 - lift1))
            ctx.stroke(arm, with: line, style: .init(lineWidth: 14 * waving, lineCap: .round))
            ctx.stroke(arm, with: .color(Self.cream), style: .init(lineWidth: 10 * waving, lineCap: .round))
        default: break
        }
        func paw(cx: CGFloat, lift: CGFloat, wave: Double = 0) {
            var c = ctx
            if wave > 0 {
                c.translateBy(x: cx, y: 162 - lift)
                c.rotate(by: .degrees(sin(s.actionPhase * 14) * 24 * wave))
                c.translateBy(x: -cx, y: -162 + lift)
            }
            let r = CGRect(x: cx - 9, y: 156 - lift, width: 18, height: 13)
            c.fill(Path(roundedRect: r, cornerRadius: 6.5), with: .color(Self.cream))
            c.stroke(Path(roundedRect: r, cornerRadius: 6.5), with: line, style: .init(lineWidth: 2.2))
            // toe line
            var toe = Path()
            toe.move(to: CGPoint(x: cx, y: 160 - lift))
            toe.addLine(to: CGPoint(x: cx, y: 166 - lift))
            c.stroke(toe, with: .color(Self.cocoa.opacity(0.5)), style: .init(lineWidth: 1.5, lineCap: .round))
        }
        paw(cx: 82 - spread + waveOffset, lift: lift1, wave: waving)
        paw(cx: 118 + spread, lift: lift2)
    }

    private func drawExtras(_ ctx: inout GraphicsContext) {
        // food while eating
        if case .eat(let food) = s.activity {
            let bounce = abs(sin(t * 10)) * 3
            ctx.draw(
                Text(food).font(.system(size: 26)),
                at: CGPoint(x: 100, y: 138 - bounce))
        }
        // yarn ball while playing
        if s.activity == .play {
            let cx = 100 + sin(t * 3.2) * 34
            let ball = CGRect(x: cx - 12, y: 152, width: 24, height: 24)
            ctx.fill(Path(ellipseIn: ball), with: .color(Self.deepPink.opacity(0.85)))
            var arc1 = Path()
            arc1.addArc(center: CGPoint(x: cx, y: 164), radius: 8,
                        startAngle: .degrees(Double(20 + Int(t * 90) % 360)), endAngle: .degrees(200), clockwise: false)
            ctx.stroke(arc1, with: .color(.white.opacity(0.8)), style: .init(lineWidth: 2))
            ctx.stroke(Path(ellipseIn: ball), with: line, style: .init(lineWidth: 2))
        }
        // dizzy stars orbiting head
        if s.dizzy > 0 {
            for i in 0..<3 {
                let ang = t * 5 + Double(i) * 2.1
                let p = CGPoint(x: 100 + cos(ang) * 30, y: 52 + sin(ang) * 8)
                ctx.draw(Text("✦").font(.system(size: 13)).foregroundStyle(.yellow), at: p)
            }
        }
        // thought dots while thinking
        if s.activity == .think {
            for i in 0..<3 {
                let phase = t * 2.4 - Double(i) * 0.35
                let alpha = 0.25 + 0.75 * max(0, sin(phase))
                let r: CGFloat = 3.4 + CGFloat(i) * 0.6
                let p = CGPoint(x: 138 + CGFloat(i) * 12, y: 52 - CGFloat(i) * 9)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                    with: .color(Self.cocoa.opacity(alpha)))
            }
        }
    }

    private func drawParticles(_ ctx: inout GraphicsContext) {
        for p in s.particles {
            let progress = p.age / p.lifetime
            let alpha = progress < 0.7 ? 1.0 : (1 - progress) / 0.3
            let pos = CGPoint(x: 100 + p.x, y: 100 - p.y)
            var c = ctx
            c.opacity = alpha
            switch p.kind {
            case .heart:
                c.fill(heartPath(cx: pos.x, cy: pos.y, size: 7 * p.scale), with: .color(Self.deepPink))
            case .zzz:
                c.draw(Text("z").font(.system(size: 15 * p.scale, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.55, green: 0.62, blue: 0.85)), at: pos)
            case .note:
                c.draw(Text("♪").font(.system(size: 14 * p.scale)).foregroundStyle(Color(red: 0.55, green: 0.5, blue: 0.9)), at: pos)
            case .sparkle:
                c.draw(Text("✦").font(.system(size: 11 * p.scale)).foregroundStyle(.yellow), at: pos)
            case .crumb:
                c.fill(Path(ellipseIn: CGRect(x: pos.x - 2, y: pos.y - 2, width: 4, height: 4)),
                       with: .color(Color(red: 0.8, green: 0.6, blue: 0.35)))
            case .star:
                c.draw(Text("✦").font(.system(size: 14 * p.scale)).foregroundStyle(.orange), at: pos)
            case .sweat:
                c.fill(Path(ellipseIn: CGRect(x: pos.x - 3, y: pos.y - 4.5, width: 6, height: 9)),
                       with: .color(Color(red: 0.55, green: 0.75, blue: 1.0)))
            case .question:
                c.draw(Text("?").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Self.cocoa), at: pos)
            case .exclamation:
                c.draw(Text("!").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Color(red: 0.95, green: 0.5, blue: 0.3)), at: pos)
            }
        }
    }

    private func heartPath(cx: CGFloat, cy: CGFloat, size s: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: cx, y: cy + s * 0.9))
        p.addCurve(to: CGPoint(x: cx - s, y: cy - s * 0.35),
                   control1: CGPoint(x: cx - s * 0.9, y: cy + s * 0.35),
                   control2: CGPoint(x: cx - s, y: cy))
        p.addArc(center: CGPoint(x: cx - s * 0.5, y: cy - s * 0.35), radius: s * 0.5,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addArc(center: CGPoint(x: cx + s * 0.5, y: cy - s * 0.35), radius: s * 0.5,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addCurve(to: CGPoint(x: cx, y: cy + s * 0.9),
                   control1: CGPoint(x: cx + s, y: cy),
                   control2: CGPoint(x: cx + s * 0.9, y: cy + s * 0.35))
        p.closeSubpath()
        return p
    }
}
