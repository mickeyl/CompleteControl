import AppKit

enum SimulatorAppIcon {
    static func make(size: CGFloat = 1024) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        let scale = size / 1024
        NSColor.clear.setFill()
        bounds.fill(using: .copy)

        let deviceRect = NSRect(x: 96, y: 244, width: 832, height: 520).scaled(by: scale)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 34 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -18 * scale)
        shadow.set()

        let body = NSBezierPath(roundedRect: deviceRect, xRadius: 46 * scale, yRadius: 46 * scale)
        NSColor(calibratedWhite: 0.19, alpha: 1).setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()

        let bevel = NSGradient(colors: [
            NSColor(calibratedWhite: 0.31, alpha: 1),
            NSColor(calibratedWhite: 0.16, alpha: 1)
        ])
        bevel?.draw(in: body, angle: 92)

        let displayY = 522 * scale
        drawDisplay(NSRect(x: 260, y: displayY / scale, width: 216, height: 116).scaled(by: scale), accent: .systemTeal)
        drawDisplay(NSRect(x: 512, y: displayY / scale, width: 216, height: 116).scaled(by: scale), accent: .systemGreen)

        let buttonColor = NSColor(calibratedWhite: 0.05, alpha: 1)
        let labelColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        for row in 0..<2 {
            for column in 0..<4 {
                let rect = NSRect(
                    x: 276 + CGFloat(column) * 61,
                    y: 662 + CGFloat(row) * 44,
                    width: 42,
                    height: 25
                ).scaled(by: scale)
                drawButton(rect, fill: buttonColor, label: labelColor)
            }
        }
        for row in 0..<2 {
            for column in 0..<3 {
                let rect = NSRect(
                    x: 532 + CGFloat(column) * 61,
                    y: 662 + CGFloat(row) * 44,
                    width: 42,
                    height: 25
                ).scaled(by: scale)
                drawButton(rect, fill: buttonColor, label: labelColor)
            }
        }

        drawEncoder(center: NSPoint(x: 790 * scale, y: 432 * scale), radius: 66 * scale)
        drawEncoder(center: NSPoint(x: 218 * scale, y: 432 * scale), radius: 50 * scale)

        for i in 0..<8 {
            let x = 246 + CGFloat(i) * 66
            drawTinyEncoder(center: NSPoint(x: x * scale, y: 364 * scale), radius: 20 * scale)
        }

        let title = "SIM" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 86 * scale, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1)
        ]
        title.draw(at: NSPoint(x: 128 * scale, y: 672 * scale), withAttributes: attrs)

        image.isTemplate = false
        return image
    }

    private static func drawDisplay(_ rect: NSRect, accent: NSColor) {
        let bezel = NSBezierPath(roundedRect: rect.insetBy(dx: -8, dy: -8), xRadius: 16, yRadius: 16)
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        bezel.fill()

        let screen = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.black.setFill()
        screen.fill()

        accent.withAlphaComponent(0.9).setStroke()
        for row in 0..<4 {
            let y = rect.minY + 24 + CGFloat(row) * 20
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX + 18, y: y))
            path.line(to: NSPoint(x: rect.maxX - 18, y: y))
            path.lineWidth = row == 1 ? 5 : 3
            path.stroke()
        }
    }

    private static func drawButton(_ rect: NSRect, fill: NSColor, label: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        fill.setFill()
        path.fill()
        NSColor(calibratedWhite: 0.42, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()

        let line = NSBezierPath()
        line.move(to: NSPoint(x: rect.minX + 8, y: rect.midY))
        line.line(to: NSPoint(x: rect.maxX - 8, y: rect.midY))
        label.setStroke()
        line.lineWidth = 3
        line.stroke()
    }

    private static func drawEncoder(center: NSPoint, radius: CGFloat) {
        let outer = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
        outer.fill()
        NSColor(calibratedWhite: 0.58, alpha: 1).setStroke()
        outer.lineWidth = 5
        outer.stroke()

        let innerRadius = radius * 0.72
        let inner = NSBezierPath(ovalIn: NSRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2))
        NSColor(calibratedWhite: 0.30, alpha: 1).setFill()
        inner.fill()
    }

    private static func drawTinyEncoder(center: NSPoint, radius: CGFloat) {
        let path = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
        path.fill()
        NSColor(calibratedWhite: 0.48, alpha: 1).setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}

private extension NSRect {
    func scaled(by scale: CGFloat) -> NSRect {
        NSRect(x: minX * scale, y: minY * scale, width: width * scale, height: height * scale)
    }
}
