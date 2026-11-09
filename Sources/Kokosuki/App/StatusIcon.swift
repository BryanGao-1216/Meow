import AppKit

/// Menu-bar icon: hand-drawn cat-face silhouette as a template image
/// (monochrome; the system tints it for light/dark menu bars).
enum StatusIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            // head: rounded blob
            let head = NSBezierPath(
                roundedRect: NSRect(x: 1.5, y: 1.0, width: 15, height: 12.5),
                xRadius: 6.2, yRadius: 6.2)

            // ears: two triangles poking above the head
            let leftEar = NSBezierPath()
            leftEar.move(to: NSPoint(x: 3.2, y: 10.5))
            leftEar.line(to: NSPoint(x: 4.6, y: 17.0))
            leftEar.line(to: NSPoint(x: 8.4, y: 12.8))
            leftEar.close()
            let rightEar = NSBezierPath()
            rightEar.move(to: NSPoint(x: 14.8, y: 10.5))
            rightEar.line(to: NSPoint(x: 13.4, y: 17.0))
            rightEar.line(to: NSPoint(x: 9.6, y: 12.8))
            rightEar.close()

            // fill separately — appending into one path cancels where ears overlap
            // the head (opposite winding)
            NSColor.black.setFill()
            head.fill()
            leftEar.fill()
            rightEar.fill()

            // knock out eyes + ω mouth so the face reads at 18px
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 5.0, y: 6.2, width: 2.2, height: 2.8)).fill()
            NSBezierPath(ovalIn: NSRect(x: 10.8, y: 6.2, width: 2.2, height: 2.8)).fill()
            let mouth = NSBezierPath()
            mouth.lineWidth = 1.1
            mouth.lineCapStyle = .round
            mouth.move(to: NSPoint(x: 6.9, y: 4.4))
            mouth.curve(
                to: NSPoint(x: 9.0, y: 4.2),
                controlPoint1: NSPoint(x: 7.6, y: 3.4), controlPoint2: NSPoint(x: 8.6, y: 3.6))
            mouth.curve(
                to: NSPoint(x: 11.1, y: 4.4),
                controlPoint1: NSPoint(x: 9.4, y: 3.6), controlPoint2: NSPoint(x: 10.4, y: 3.4))
            NSColor.black.setStroke()
            mouth.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }
}
