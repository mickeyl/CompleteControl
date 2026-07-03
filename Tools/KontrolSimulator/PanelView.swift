import AppKit
import KompleteKontrol

/// The virtual S61 MK2 panel: two pixel displays, eight function buttons, side buttons,
/// eight rotary encoders, and the 4-D encoder — all drawn and all interactive. Output frames
/// from the daemon update the pixels and LED colours; mouse/scroll interaction emits semantic
/// input frames back through `onInput`.
final class PanelView: NSView {
    static let deviceBackgroundColor = NSColor(white: 0.12, alpha: 1)

    var onInput: ((SimFrame) -> Void)?

    private let screens = [ScreenBuffer(), ScreenBuffer()]
    private var ledBytes = [UInt8](repeating: 0, count: KompleteKontrolMK2Protocol.buttonLEDMapSize)
    private var pressedButtons: Set<KKMK2ButtonLED> = []
    private var encoderAngle = [Double](repeating: 0, count: 8)
    private var encoderTouched = [Bool](repeating: false, count: 8)
    private var connected = false

    private struct ButtonControl {
        let led: KKMK2ButtonLED
        let title: String
        let subtitle: String?
        let rect: NSRect
    }
    private struct EncoderControl { let index: Int; let rect: NSRect }

    private var buttons: [ButtonControl] = []
    private var encoders: [EncoderControl] = []
    private var fourDCenter = NSPoint.zero
    private var fourDRadius: CGFloat = 56

    // Drag state
    private var activeButton: KKMK2ButtonLED?
    private var activeEncoder: Int?
    private var lastDragY: CGFloat = 0
    private var activeFourD: MK2InputReportBuilder.FourDState?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(scale: CGFloat) {
        self.dispScale = scale
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        buildLayout()
        setFrameSize(preferredContentSize)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Output from the daemon

    func setConnected(_ value: Bool) { connected = value; needsDisplay = true }

    func applyBlit(screen: Int, x: Int, y: Int, w: Int, h: Int, be: [UInt8]) {
        guard screens.indices.contains(screen) else { return }
        screens[screen].blit(x: x, y: y, w: w, h: h, be: be)
        needsDisplay = true
    }

    func applyReport(reportID: UInt8, bytes: [UInt8]) {
        guard reportID == KompleteKontrolMK2Protocol.buttonLEDReportID else { return }
        for i in 0..<min(ledBytes.count, bytes.count) { ledBytes[i] = bytes[i] }
        needsDisplay = true
    }

    func clearAll() {
        for screen in screens { screen.clear() }
        for i in ledBytes.indices { ledBytes[i] = 0 }
        needsDisplay = true
    }

    // MARK: - Layout

    private let dispScale: CGFloat
    /// Size the panel needs given the current display scale; the window is fitted to it.
    private(set) var preferredContentSize: NSSize = .zero
    private var dispW: CGFloat { 480 * dispScale }
    private var dispH: CGFloat { 272 * dispScale }
    private var display0 = NSRect.zero
    private var display1 = NSRect.zero

    private func buildLayout() {
        let margin: CGFloat = 24
        let controlW: CGFloat = 82
        let controlH: CGFloat = 34
        let controlGapX: CGFloat = 10
        let controlGapY: CGFloat = 8
        let leftBlockX = margin
        let navBlockX = leftBlockX + controlW * 3 + controlGapX * 2 + 46
        let modeBlockX = navBlockX + controlW + 42
        let displaysX = modeBlockX + controlW + 28
        let funcH: CGFloat = 30
        let funcY = margin
        let dispY = funcY + funcH + 14

        buttons.removeAll()
        encoders.removeAll()

        func leftRect(column: Int, row: Int, yOffset: CGFloat = 0, width: CGFloat = controlW) -> NSRect {
            NSRect(
                x: leftBlockX + CGFloat(column) * (controlW + controlGapX),
                y: funcY + CGFloat(row) * (controlH + controlGapY) + yOffset,
                width: width,
                height: controlH
            )
        }

        func addButton(_ led: KKMK2ButtonLED, _ title: String, _ subtitle: String? = nil, _ rect: NSRect) {
            buttons.append(ButtonControl(led: led, title: title, subtitle: subtitle, rect: rect))
        }

        // Hardware control area left of the displays.
        addButton(.shift, "SHIFT", nil, leftRect(column: 0, row: 0))
        addButton(.scaleEdit, "SCALE", "Edit", leftRect(column: 1, row: 0))
        addButton(.arpEdit, "ARP", "Edit", leftRect(column: 2, row: 0))
        addButton(.undoRedo, "UNDO", "Redo", leftRect(column: 0, row: 1))
        addButton(.quantize, "QUANTIZE", nil, leftRect(column: 1, row: 1))
        addButton(.auto, "AUTOMATION", nil, leftRect(column: 2, row: 1))

        let transportY = funcY + (controlH + controlGapY) * 3 + 8
        addButton(.loop, "LOOP", nil, leftRect(column: 0, row: 0, yOffset: transportY - funcY))
        addButton(.metro, "METRONOME", nil, leftRect(column: 1, row: 0, yOffset: transportY - funcY))
        addButton(.tempo, "TEMPO", nil, leftRect(column: 2, row: 0, yOffset: transportY - funcY))
        addButton(.play, "PLAY", "Restart", leftRect(column: 0, row: 1, yOffset: transportY - funcY))
        addButton(.record, "REC", "Count-In", leftRect(column: 1, row: 1, yOffset: transportY - funcY))
        addButton(.stop, "STOP", nil, leftRect(column: 2, row: 1, yOffset: transportY - funcY))

        let smallButton: CGFloat = 34
        addButton(.m, "M", nil, NSRect(x: navBlockX, y: funcY, width: smallButton, height: smallButton))
        addButton(.s, "S", nil, NSRect(x: navBlockX + smallButton + 10, y: funcY, width: smallButton, height: smallButton))
        addButton(.presetUp, "PRESET ^", nil, NSRect(x: navBlockX, y: funcY + 78, width: controlW, height: controlH))
        addButton(.presetDown, "PRESET v", nil, NSRect(x: navBlockX, y: funcY + 120, width: controlW, height: controlH))
        addButton(.pageLeft, "<", nil, NSRect(x: navBlockX, y: funcY + 166, width: smallButton, height: smallButton))
        addButton(.pageRight, ">", nil, NSRect(x: navBlockX + smallButton + 10, y: funcY + 166, width: smallButton, height: smallButton))

        addButton(.scene, "SCENE", nil, NSRect(x: modeBlockX, y: funcY, width: controlW, height: controlH))
        addButton(.pattern, "PATTERN", nil, NSRect(x: modeBlockX, y: funcY + 42, width: controlW, height: controlH))
        addButton(.track, "TRACK", nil, NSRect(x: modeBlockX, y: funcY + 84, width: controlW, height: controlH))
        addButton(.keyMode, "KEY MODE", nil, NSRect(x: modeBlockX, y: funcY + 126, width: controlW, height: controlH))
        addButton(.clear, "CLEAR", nil, NSRect(x: modeBlockX, y: funcY + 168, width: controlW, height: controlH))

        display0 = NSRect(x: displaysX, y: dispY, width: dispW, height: dispH)
        display1 = NSRect(x: displaysX + dispW + 16, y: dispY, width: dispW, height: dispH)
        let blockLeft = displaysX
        let blockRight = display1.maxX
        let blockWidth = blockRight - blockLeft
        let rightControlsX = blockRight + 28
        let rightControlW: CGFloat = 84
        let rightControlsGapX: CGFloat = 10
        let rightControlsGapY: CGFloat = 8

        func rightControlRect(column: Int, row: Int) -> NSRect {
            NSRect(
                x: rightControlsX + CGFloat(column) * (rightControlW + rightControlsGapX),
                y: dispY + CGFloat(row) * (controlH + rightControlsGapY),
                width: rightControlW,
                height: controlH
            )
        }

        // Function buttons across the display block.
        let fGap: CGFloat = 8
        let fW = (blockWidth - fGap * 7) / 8
        for i in 0..<8 {
            let rect = NSRect(x: blockLeft + CGFloat(i) * (fW + fGap), y: funcY, width: fW, height: funcH)
            let led = KKMK2ButtonLED(rawValue: KKMK2ButtonLED.function1.rawValue + i)!
            addButton(led, "F\(i + 1)", nil, rect)
        }

        // Right-side mode buttons above the 4-D encoder.
        addButton(.browser, "BROWSER", nil, rightControlRect(column: 0, row: 0))
        addButton(.plugin, "PLUGIN", nil, rightControlRect(column: 1, row: 0))
        addButton(.mixer, "MIXER", nil, rightControlRect(column: 2, row: 0))
        addButton(.instance, "INSTANCE", nil, rightControlRect(column: 0, row: 1))
        addButton(.midi, "MIDI", nil, rightControlRect(column: 1, row: 1))
        addButton(.setup, "SETUP", nil, rightControlRect(column: 2, row: 1))

        // Encoders under the displays.
        let encY = display0.maxY + 20
        let step = blockWidth / 8
        let knob: CGFloat = 60
        for i in 0..<8 {
            let cx = blockLeft + step * CGFloat(i) + step / 2
            let rect = NSRect(x: cx - knob / 2, y: encY, width: knob, height: knob)
            encoders.append(EncoderControl(index: i + 1, rect: rect))
        }

        let rightControlsRight = rightControlsX + rightControlW * 3 + rightControlsGapX * 2
        fourDCenter = NSPoint(
            x: (rightControlsX + rightControlsRight) / 2,
            y: dispY + controlH * 2 + rightControlsGapY + fourDRadius + 28
        )

        let controlsBottom = max(encY + knob + 40, fourDCenter.y + fourDRadius + 40)
        preferredContentSize = NSSize(
            width: rightControlsRight + margin,
            height: controlsBottom)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        Self.deviceBackgroundColor.setFill()
        bounds.fill()

        for (i, screen) in screens.enumerated() {
            let rect = i == 0 ? display0 : display1
            NSColor.black.setFill()
            rect.insetBy(dx: -2, dy: -2).fill()
            if let image = screen.image() {
                NSImage(cgImage: image, size: rect.size).draw(in: rect)
            }
        }

        for button in buttons { drawButton(button) }
        for encoder in encoders { drawEncoder(encoder) }
        drawFourD()
        drawStatus()
    }

    private func drawButton(_ button: ButtonControl) {
        let pressed = pressedButtons.contains(button.led)
        let code = ledBytes[button.led.rawValue]
        let path = NSBezierPath(roundedRect: button.rect, xRadius: 5, yRadius: 5)
        ledColor(code, pressed: pressed).setFill()
        path.fill()
        (pressed ? NSColor.white : NSColor(white: 0.3, alpha: 1)).setStroke()
        path.lineWidth = pressed ? 2 : 1
        path.stroke()
        drawButtonLabel(button, color: labelColor(for: code))
    }

    private func drawButtonLabel(_ button: ButtonControl, color: NSColor) {
        if let subtitle = button.subtitle {
            let titleRect = NSRect(x: button.rect.minX + 6, y: button.rect.minY + 5, width: button.rect.width - 12, height: 13)
            let subtitleRect = NSRect(x: button.rect.minX + 6, y: button.rect.minY + 18, width: button.rect.width - 12, height: 12)
            drawLabel(button.title, in: titleRect, color: color, size: 10, left: true)
            drawLabel(subtitle, in: subtitleRect, color: color.withAlphaComponent(0.62), size: 9, left: true)
        } else {
            drawLabel(button.title, in: button.rect, color: color)
        }
    }

    private func drawEncoder(_ encoder: EncoderControl) {
        let rect = encoder.rect
        let path = NSBezierPath(ovalIn: rect)
        NSColor(white: 0.16, alpha: 1).setFill(); path.fill()
        (encoderTouched[encoder.index - 1] ? NSColor.systemBlue : NSColor(white: 0.35, alpha: 1)).setStroke()
        path.lineWidth = encoderTouched[encoder.index - 1] ? 3 : 1.5
        path.stroke()

        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2 - 4
        let angle = encoderAngle[encoder.index - 1]
        let tip = NSPoint(x: center.x + CGFloat(sin(angle)) * radius, y: center.y - CGFloat(cos(angle)) * radius)
        let tick = NSBezierPath()
        tick.move(to: center); tick.line(to: tip)
        NSColor.white.setStroke(); tick.lineWidth = 2; tick.stroke()

        let labelRect = NSRect(x: rect.minX - 10, y: rect.maxY + 2, width: rect.width + 20, height: 16)
        drawLabel("E\(encoder.index)", in: labelRect, color: NSColor(white: 0.6, alpha: 1), size: 11)
    }

    private func drawFourD() {
        let rect = NSRect(x: fourDCenter.x - fourDRadius, y: fourDCenter.y - fourDRadius,
                          width: fourDRadius * 2, height: fourDRadius * 2)
        let outer = NSBezierPath(ovalIn: rect)
        NSColor(white: 0.14, alpha: 1).setFill(); outer.fill()
        NSColor(white: 0.35, alpha: 1).setStroke(); outer.lineWidth = 2; outer.stroke()

        // Direction arrows.
        NSColor(white: 0.55, alpha: 1).setFill()
        let a = fourDRadius * 0.55
        for (dx, dy) in [(0.0, -1.0), (0.0, 1.0), (-1.0, 0.0), (1.0, 0.0)] {
            let p = NSBezierPath()
            let cx = fourDCenter.x + CGFloat(dx) * a
            let cy = fourDCenter.y + CGFloat(dy) * a
            p.appendOval(in: NSRect(x: cx - 4, y: cy - 4, width: 8, height: 8))
            p.fill()
        }
        let inner = NSBezierPath(ovalIn: NSRect(x: fourDCenter.x - 16, y: fourDCenter.y - 16, width: 32, height: 32))
        NSColor(white: 0.22, alpha: 1).setFill(); inner.fill()
        drawLabel("4-D", in: NSRect(x: fourDCenter.x - 20, y: fourDCenter.y + fourDRadius + 4, width: 40, height: 14),
                  color: NSColor(white: 0.6, alpha: 1), size: 11)
    }

    private func drawStatus() {
        let text = connected ? "● daemon connected" : "○ waiting for ccd  (CCD_SIMULATE)"
        drawLabel(text, in: NSRect(x: 24, y: bounds.height - 22, width: 400, height: 16),
                  color: connected ? NSColor.systemGreen : NSColor(white: 0.5, alpha: 1), size: 11, left: true)
    }

    private func drawLabel(_ text: String, in rect: NSRect, color: NSColor, size: CGFloat = 12, left: Bool = false) {
        let style = NSMutableParagraphStyle(); style.alignment = left ? .left : .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: color, .paragraphStyle: style,
        ]
        let textRect = NSRect(x: rect.minX, y: rect.midY - size * 0.75, width: rect.width, height: size * 1.6)
        text.draw(in: textRect, withAttributes: attrs)
    }

    private func ledColor(_ code: UInt8, pressed: Bool) -> NSColor {
        if code == 0 {
            return pressed ? NSColor(white: 0.45, alpha: 1) : NSColor(white: 0.18, alpha: 1)
        }
        let rgb = KompleteKontrolSSeriesMK2.paletteColor(forCode: code)
        return NSColor(red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }

    private func labelColor(for code: UInt8) -> NSColor {
        code == 0 ? NSColor(white: 0.75, alpha: 1) : NSColor.black.withAlphaComponent(0.8)
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let button = buttons.first(where: { $0.rect.contains(point) }) {
            activeButton = button.led
            pressedButtons.insert(button.led)
            onInput?(.button(led: button.led, pressed: true))
            needsDisplay = true
            return
        }
        if let encoder = encoders.first(where: { $0.rect.contains(point) }) {
            activeEncoder = encoder.index
            lastDragY = point.y
            encoderTouched[encoder.index - 1] = true
            onInput?(.encoderTouch(index: encoder.index, touched: true))
            needsDisplay = true
            return
        }
        if hypot(point.x - fourDCenter.x, point.y - fourDCenter.y) <= fourDRadius {
            let state = fourDZone(point)
            activeFourD = state
            onInput?(.fourDState(state.rawValue))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = activeEncoder else { return }
        let point = convert(event.locationInWindow, from: nil)
        let steps = Int((lastDragY - point.y) / 4) // drag up = increase (flipped view)
        if steps != 0 {
            emitEncoder(index: index, delta: steps)
            lastDragY -= CGFloat(steps) * 4
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let led = activeButton {
            pressedButtons.remove(led)
            onInput?(.button(led: led, pressed: false))
            activeButton = nil
            needsDisplay = true
        }
        if let index = activeEncoder {
            encoderTouched[index - 1] = false
            onInput?(.encoderTouch(index: index, touched: false))
            activeEncoder = nil
            needsDisplay = true
        }
        if activeFourD != nil {
            onInput?(.fourDState(MK2InputReportBuilder.FourDState.released.rawValue))
            activeFourD = nil
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let raw = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 6 : event.scrollingDeltaY
        let delta = raw > 0 ? 1 : (raw < 0 ? -1 : 0)
        guard delta != 0 else { return }
        if let encoder = encoders.first(where: { $0.rect.contains(point) }) {
            emitEncoder(index: encoder.index, delta: delta)
        } else if hypot(point.x - fourDCenter.x, point.y - fourDCenter.y) <= fourDRadius {
            onInput?(.fourDWheel(delta: delta))
        }
    }

    private func emitEncoder(index: Int, delta: Int) {
        encoderAngle[index - 1] += Double(delta) * 0.35
        onInput?(.encoder(index: index, delta: delta))
        needsDisplay = true
    }

    private func fourDZone(_ point: NSPoint) -> MK2InputReportBuilder.FourDState {
        let dx = point.x - fourDCenter.x
        let dy = point.y - fourDCenter.y
        if hypot(dx, dy) < 18 { return .click }
        if abs(dx) > abs(dy) { return dx > 0 ? .pushRight : .pushLeft }
        return dy > 0 ? .pushDown : .pushUp // flipped: +y is downward
    }
}

/// One 480×272 display as an RGBA framebuffer with a cached CGImage rebuilt only when blitted.
private final class ScreenBuffer {
    private var rgba = [UInt8](repeating: 0, count: 480 * 272 * 4)
    private var cached: CGImage?
    private var dirty = true

    func blit(x: Int, y: Int, w: Int, h: Int, be: [UInt8]) {
        for row in 0..<h {
            let dy = y + row
            guard dy >= 0, dy < 272 else { continue }
            for col in 0..<w {
                let dx = x + col
                guard dx >= 0, dx < 480 else { continue }
                let si = (row * w + col) * 2
                guard si + 1 < be.count else { continue }
                let value = (UInt16(be[si]) << 8) | UInt16(be[si + 1])
                let r5 = (value >> 11) & 0x1f, g6 = (value >> 5) & 0x3f, b5 = value & 0x1f
                let di = (dy * 480 + dx) * 4
                rgba[di] = UInt8((r5 << 3) | (r5 >> 2))
                rgba[di + 1] = UInt8((g6 << 2) | (g6 >> 4))
                rgba[di + 2] = UInt8((b5 << 3) | (b5 >> 2))
                rgba[di + 3] = 255
            }
        }
        dirty = true
    }

    func clear() {
        for i in rgba.indices { rgba[i] = (i % 4 == 3) ? 255 : 0 }
        dirty = true
    }

    func image() -> CGImage? {
        if dirty || cached == nil {
            let space = CGColorSpaceCreateDeviceRGB()
            if let provider = CGDataProvider(data: Data(rgba) as CFData) {
                cached = CGImage(width: 480, height: 272, bitsPerComponent: 8, bitsPerPixel: 32,
                                 bytesPerRow: 480 * 4, space: space,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            }
            dirty = false
        }
        return cached
    }
}
