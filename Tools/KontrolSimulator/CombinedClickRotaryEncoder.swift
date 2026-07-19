import AppKit

/// Shared simulator presentation for the physical 4-D control. The control behaves like its
/// push surface by default and visibly changes into a rotary while Command is held.
enum CombinedClickRotaryEncoder {
    enum Mode {
        case push
        case rotate
    }

    enum PushZone: CaseIterable {
        case center
        case up
        case right
        case down
        case left
    }

    static func pushZone(at point: NSPoint, in rect: NSRect) -> PushZone? {
        guard rect.contains(point) else { return nil }
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        let radius = min(rect.width, rect.height) / 2
        guard hypot(dx, dy) <= radius else { return nil }
        if hypot(dx, dy) <= radius * 0.32 { return .center }
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .down : .up
    }

    static func draw(
        in rect: NSRect,
        mode: Mode,
        rotationAngle: Double,
        touched: Bool,
        activePush: PushZone?,
        directionColor: (PushZone) -> NSColor = { _ in NSColor(white: 0.46, alpha: 1) }
    ) {
        let accent = NSColor.systemBlue
        let outer = NSBezierPath(ovalIn: rect)
        NSColor(white: touched ? 0.19 : 0.135, alpha: 1).setFill()
        outer.fill()
        (touched || mode == .rotate ? accent : NSColor(white: 0.36, alpha: 1)).setStroke()
        outer.lineWidth = touched || mode == .rotate ? 3 : 1.75
        outer.stroke()

        switch mode {
            case .push:
                drawPushFace(in: rect, activePush: activePush, accent: accent, directionColor: directionColor)
            case .rotate:
                drawRotaryFace(in: rect, angle: rotationAngle, accent: accent)
        }
    }

    private static func drawPushFace(
        in rect: NSRect,
        activePush: PushZone?,
        accent: NSColor,
        directionColor: (PushZone) -> NSColor
    ) {
        let radius = min(rect.width, rect.height) / 2
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let offset = radius * 0.57
        let positions: [(PushZone, CGFloat, CGFloat)] = [
            (.up, 0, -offset), (.right, offset, 0),
            (.down, 0, offset), (.left, -offset, 0),
        ]
        for (zone, dx, dy) in positions {
            let active = activePush == zone
            let dotRadius = active ? radius * 0.10 : radius * 0.067
            let dot = NSBezierPath(ovalIn: NSRect(
                x: center.x + dx - dotRadius,
                y: center.y + dy - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))
            (active ? accent : directionColor(zone)).setFill()
            dot.fill()
        }

        let centerRadius = radius * 0.27
        let centerPath = NSBezierPath(ovalIn: NSRect(
            x: center.x - centerRadius,
            y: center.y - centerRadius,
            width: centerRadius * 2,
            height: centerRadius * 2
        ))
        (activePush == .center ? accent : NSColor(white: 0.235, alpha: 1)).setFill()
        centerPath.fill()
        NSColor(white: activePush == .center ? 0.92 : 0.47, alpha: 1).setStroke()
        centerPath.lineWidth = 1
        centerPath.stroke()
    }

    private static func drawRotaryFace(in rect: NSRect, angle: Double, accent: NSColor) {
        let radius = min(rect.width, rect.height) / 2
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let knobRect = rect.insetBy(dx: radius * 0.19, dy: radius * 0.19)
        let knob = NSBezierPath(ovalIn: knobRect)
        NSColor(white: 0.095, alpha: 1).setFill()
        knob.fill()
        NSColor(white: 0.29, alpha: 1).setStroke()
        knob.lineWidth = 1
        knob.stroke()

        for index in 0..<12 {
            let detentAngle = Double(index) / 12 * .pi * 2
            let detentCenter = NSPoint(
                x: center.x + CGFloat(sin(detentAngle)) * radius * 0.78,
                y: center.y - CGFloat(cos(detentAngle)) * radius * 0.78
            )
            let detent = NSBezierPath(ovalIn: NSRect(
                x: detentCenter.x - 1.4, y: detentCenter.y - 1.4,
                width: 2.8, height: 2.8
            ))
            NSColor(white: 0.55, alpha: 1).setFill()
            detent.fill()
        }

        let marker = NSBezierPath()
        marker.move(to: center)
        marker.line(to: NSPoint(
            x: center.x + CGFloat(sin(angle)) * radius * 0.57,
            y: center.y - CGFloat(cos(angle)) * radius * 0.57
        ))
        accent.setStroke()
        marker.lineWidth = 2.5
        marker.stroke()
    }
}

enum SimulatorDisplayBezel {
    /// Draws a recessed display opening with light entering from the upper-left.
    static func draw(around displayRect: NSRect, outset: CGFloat) {
        let opening = displayRect.insetBy(dx: -outset, dy: -8)
        let surround = NSBezierPath(roundedRect: opening, xRadius: 4, yRadius: 4)
        NSColor(calibratedWhite: 0.018, alpha: 1).setFill()
        surround.fill()

        NSGraphicsContext.saveGraphicsState()
        surround.addClip()
        NSColor(calibratedWhite: 0.32, alpha: 1).setFill()
        NSRect(x: opening.minX, y: opening.minY, width: opening.width, height: 2).fill()
        NSRect(x: opening.minX, y: opening.minY, width: 2, height: opening.height).fill()
        NSColor(calibratedWhite: 0.005, alpha: 1).setFill()
        NSRect(x: opening.minX, y: opening.maxY - 3, width: opening.width, height: 3).fill()
        NSRect(x: opening.maxX - 3, y: opening.minY, width: 3, height: opening.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(calibratedWhite: 0.08, alpha: 1).setStroke()
        let inner = NSBezierPath(roundedRect: displayRect.insetBy(dx: -1, dy: -1), xRadius: 1, yRadius: 1)
        inner.lineWidth = 1
        inner.stroke()
    }
}
