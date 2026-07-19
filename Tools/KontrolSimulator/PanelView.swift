import AppKit
import AVFoundation
import KompleteKontrol

/// The virtual S61 MK2 panel: two pixel displays, eight function buttons, side buttons,
/// eight rotary encoders, and the 4-D encoder — all drawn and all interactive. Output frames
/// from the daemon update the pixels and LED colours; mouse/scroll interaction emits semantic
/// input frames back through `onInput`.
final class PanelView: NSView, SimulatorPanel {
    static let deviceBackgroundColor = NSColor(white: 0.12, alpha: 1)

    var onInput: ((SimFrame) -> Void)?
    var onDaemonStatus: ((SimulatorDaemonStatus) -> Void)?

    private let screens = [ScreenBuffer(), ScreenBuffer()]
    private let interactionAudio = InteractionAudio()
    private var ledBytes = [UInt8](repeating: 0, count: KompleteKontrolMK2Protocol.buttonLEDMapSize)
    private var lightGuideBytes = [UInt8](repeating: 0, count: KompleteKontrolMK2Protocol.lightGuideKeyMapSize)
    private var pressedButtons: Set<KKMK2ButtonLED> = []
    private var encoderAngle = [Double](repeating: 0, count: 8)
    private var encoderTouched = [Bool](repeating: false, count: 8)
    private var pressedKeys: Set<Int> = []
    private var pitchValue = 8192
    private var modValue = 0
    private var ribbonPosition: Int?
    private var ribbonTimestamp = 0

    enum KeybedSize: Int, CaseIterable {
        case kk37 = 37
        case kk49 = 49
        case kk61 = 61

        var title: String { "KK\(rawValue)" }
        var baseNote: UInt8 { 36 }
    }

    private struct ButtonControl {
        let led: KKMK2ButtonLED
        let title: String
        let subtitle: String?
        let rect: NSRect
    }
    private struct EncoderControl { let index: Int; let rect: NSRect }
    /// Counts one scroll notch / 4 px drag step feeds into a rotary — matches
    /// the hardware's ~360-counts-per-revolution resolution so the kit's
    /// throw scaling and rate acceleration feel like the real encoders.
    private static let encoderCountsPerScrollTick = 12
    private struct KeyControl {
        let index: Int
        let note: UInt8
        let isBlack: Bool
        let rect: NSRect
    }

    private var buttons: [ButtonControl] = []
    private var encoders: [EncoderControl] = []
    private var keyControls: [KeyControl] = []
    private var keybedSize: KeybedSize = .kk37
    private var fourDCenter = NSPoint.zero
    private var fourDRadius: CGFloat = 56
    private var fourDWheelAngle = 0.0
    private var fourDWheelTouched = false
    private var commandRotationMode = false
    private var pitchWheelRect = NSRect.zero
    private var modWheelRect = NSRect.zero
    private var ribbonRect = NSRect.zero
    private var ribbonLEDRect = NSRect.zero

    // Drag state
    private var activeButton: KKMK2ButtonLED?
    private var activeEncoder: Int?
    private var activeEncoderTouchOnly: Int?
    private var activeKey: Int?
    private var activeKeyPressure: Int?
    private var activeKeyPressureOriginY: CGFloat?
    private var activeWheel: WheelKind?
    private var activeRibbon = false
    private var lastDragY: CGFloat = 0
    private var activeFourD: MK2InputReportBuilder.FourDState?
    private var activeFourDRotation = false
    private var pendingEncoderTouchReleases: [Int: DispatchWorkItem] = [:]
    private var pendingFourDTouchRelease: DispatchWorkItem?
    private var keyboardButtons: Set<KKMK2ButtonLED> = []
    private var keyboardFourD: MK2InputReportBuilder.FourDState?

    private enum WheelKind {
        case pitch
        case mod
    }

    static let keyboardCheatSheetText = """
    Komplete Kontrol MK2 Simulator Keys

    4-D Encoder
      Arrow keys             Push left/up/down/right
      Return / Keypad Enter  Press 4-D encoder
      Click / drag           Push center or a direction
      Command-drag / scroll  Rotate the same encoder

    Core Buttons
      Shift                  SHIFT
      M                      Mute
      S                      Solo
      I                      Instance
      Space                  Play
      R                      Record
      Escape                 Stop

    Mode / Navigation
      B                      Browser
      P                      Plugin
      X                      Mixer
      [ / ]                  Page left / right
      , / .                  Preset down / up
      C                      Clear
      K                      Key Mode
      T                      Track
      L                      Loop

    Function Buttons
      1 ... 8                F1 ... F8
    """

    private enum KeyboardAction {
        case button(KKMK2ButtonLED)
        case fourD(MK2InputReportBuilder.FourDState)
    }

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

    var view: NSView { self }
    var backgroundColor: NSColor { Self.deviceBackgroundColor }
    var keyboardCheatSheetText: String { Self.keyboardCheatSheetText }
    var trueSizeReference: SimulatorTrueSizeReference {
        SimulatorTrueSizeReference(physicalWidthMM: 95, baseWidthPoints: 480)
    }

    func apply(_ frame: SimFrame) {
        switch frame.type {
            case .displayBlit:
                guard frame.payload.count >= 9 else { return }
                applyBlit(
                    screen: Int(frame.payload[0]),
                    x: Int(frame.payload[1]) << 8 | Int(frame.payload[2]),
                    y: Int(frame.payload[3]) << 8 | Int(frame.payload[4]),
                    w: Int(frame.payload[5]) << 8 | Int(frame.payload[6]),
                    h: Int(frame.payload[7]) << 8 | Int(frame.payload[8]),
                    be: Array(frame.payload.dropFirst(9))
                )
            case .displayPacket:
                do {
                    let blit = try sharedDisplayPacketDecoder.decodeAndApply(frame.payload)
                    applyBlit(
                        screen: Int(blit.screen), x: Int(blit.x), y: Int(blit.y),
                        w: Int(blit.width), h: Int(blit.height), be: blit.pixelsBE
                    )
                } catch {
                    onDaemonStatus?(.protocolError)
                }
            case .report:
                guard let reportID = frame.payload.first else { return }
                applyReport(reportID: reportID, bytes: Array(frame.payload.dropFirst()))
            default:
                break
        }
    }

    private var sharedDisplayPacketDecoder = MK2DisplayPacketDecoder()

    func applyBlit(screen: Int, x: Int, y: Int, w: Int, h: Int, be: [UInt8]) {
        guard screens.indices.contains(screen) else { return }
        screens[screen].blit(x: x, y: y, w: w, h: h, be: be)
        needsDisplay = true
    }

    func applyReport(reportID: UInt8, bytes: [UInt8]) {
        switch reportID {
            case KompleteKontrolMK2Protocol.buttonLEDReportID:
                for i in 0..<min(ledBytes.count, bytes.count) { ledBytes[i] = bytes[i] }
                needsDisplay = true
            case KompleteKontrolMK2Protocol.lightGuideReportID:
                for i in 0..<min(lightGuideBytes.count, bytes.count) { lightGuideBytes[i] = bytes[i] }
                needsDisplay = true
            default:
                break
        }
    }

    func clearAll() {
        for screen in screens { screen.clear() }
        for i in ledBytes.indices { ledBytes[i] = 0 }
        for i in lightGuideBytes.indices { lightGuideBytes[i] = 0 }
        pressedKeys.removeAll()
        ribbonPosition = nil
        needsDisplay = true
    }

    func setKeybedSize(_ size: KeybedSize) {
        guard keybedSize != size else { return }
        keybedSize = size
        buildLayout()
        setFrameSize(preferredContentSize)
        needsDisplay = true
    }

    var currentKeybedSize: KeybedSize { keybedSize }
    var displayBlockRect: NSRect { display0.union(display1) }
    var displayWorkAreaRect: NSRect {
        var rect = displayBlockRect
        for button in buttons where (KKMK2ButtonLED.function1.rawValue...KKMK2ButtonLED.function8.rawValue).contains(button.led.rawValue) {
            rect = rect.union(button.rect)
        }
        for encoder in encoders {
            rect = rect.union(encoder.rect)
        }
        return rect
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
        keyControls.removeAll()

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
        addButton(.pageRight, ">", nil, NSRect(x: navBlockX + smallButton + 10, y: funcY + 166, width: controlW - smallButton - 10, height: smallButton))

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
        let encoderLabelBottom = encY + knob + 18
        let keybedTop = encoderLabelBottom + 20 - 3 // light-guide strip starts 3 px into the key.
        let performanceTop = keybedTop - 62
        let wheelAreaX = margin
        let wheelAreaWidth: CGFloat = 188
        let wheelW: CGFloat = 42
        let wheelGap: CGFloat = 18
        let wheelGroupWidth = wheelW * 2 + wheelGap
        let wheelGroupX = wheelAreaX + (wheelAreaWidth - wheelGroupWidth) / 2
        let performanceButtonGap: CGFloat = 6
        let performanceButtonW = (wheelAreaWidth - performanceButtonGap * 2) / 3
        let performanceButtonY = performanceTop + 2
        addButton(.fixedVel, "FIXED", "VEL", NSRect(x: wheelAreaX, y: performanceButtonY, width: performanceButtonW, height: 30))
        addButton(.octaveDown, "OCTAVE", "-", NSRect(x: wheelAreaX + performanceButtonW + performanceButtonGap, y: performanceButtonY, width: performanceButtonW, height: 30))
        addButton(.octaveUp, "OCTAVE", "+", NSRect(x: wheelAreaX + (performanceButtonW + performanceButtonGap) * 2, y: performanceButtonY, width: performanceButtonW, height: 30))
        pitchWheelRect = NSRect(x: wheelGroupX, y: performanceTop + 50, width: wheelW, height: 130)
        modWheelRect = NSRect(x: pitchWheelRect.maxX + wheelGap, y: performanceTop + 50, width: wheelW, height: 130)
        let keybedX = wheelAreaX + wheelAreaWidth + 30
        let keybedWidth = rightControlsRight - keybedX
        let keybedRect = NSRect(x: keybedX, y: performanceTop + 62, width: keybedWidth, height: 213)
        ribbonLEDRect = NSRect(x: wheelAreaX, y: keybedRect.maxY - 8, width: wheelAreaWidth, height: 8)
        ribbonRect = NSRect(x: wheelAreaX, y: ribbonLEDRect.minY - 28, width: wheelAreaWidth, height: 22)
        buildKeybed(in: keybedRect)

        let controlsBottom = max(
            keybedRect.maxY + 34,
            ribbonLEDRect.maxY + 28,
            fourDCenter.y + fourDRadius + 38
        )
        preferredContentSize = NSSize(
            width: rightControlsRight + margin,
            height: controlsBottom)
    }

    private func buildKeybed(in keybedRect: NSRect) {
        keyControls.removeAll()
        let keyCount = keybedSize.rawValue
        let whiteCount = (0..<keyCount).filter { !isBlackKey(index: $0) }.count
        guard whiteCount > 0 else { return }

        let whiteWidth = keybedRect.width / CGFloat(whiteCount)
        let blackWidth = max(8, whiteWidth * 0.62)
        let blackHeight = keybedRect.height * 0.62
        var whiteIndex = 0

        for index in 0..<keyCount {
            if isBlackKey(index: index) {
                let centerX = keybedRect.minX + CGFloat(whiteIndex) * whiteWidth
                let rect = NSRect(
                    x: centerX - blackWidth / 2,
                    y: keybedRect.minY,
                    width: blackWidth,
                    height: blackHeight
                )
                keyControls.append(KeyControl(index: index, note: keybedSize.baseNote + UInt8(index), isBlack: true, rect: rect))
            } else {
                let rect = NSRect(
                    x: keybedRect.minX + CGFloat(whiteIndex) * whiteWidth,
                    y: keybedRect.minY,
                    width: whiteWidth,
                    height: keybedRect.height
                )
                keyControls.append(KeyControl(index: index, note: keybedSize.baseNote + UInt8(index), isBlack: false, rect: rect))
                whiteIndex += 1
            }
        }
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
        drawPerformanceControls()
    }

    private func drawButton(_ button: ButtonControl) {
        let pressed = pressedButtons.contains(button.led)
        let code = ledBytes[button.led.rawValue]
        let path = NSBezierPath(roundedRect: button.rect, xRadius: 5, yRadius: 5)
        buttonFillColor(code: code, pressed: pressed, led: button.led).setFill()
        path.fill()
        (pressed ? NSColor.white : NSColor(white: 0.3, alpha: 1)).setStroke()
        path.lineWidth = pressed ? 2 : 1
        path.stroke()
        drawButtonLabel(button, color: labelColor(for: code, led: button.led))
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
        let mode: CombinedClickRotaryEncoder.Mode = commandRotationMode || activeFourDRotation ? .rotate : .push
        CombinedClickRotaryEncoder.draw(
            in: fourDRect,
            mode: mode,
            rotationAngle: fourDWheelAngle,
            touched: activeFourD != nil || fourDWheelTouched,
            activePush: combinedPushZone(for: activeFourD),
            directionColor: { [weak self] zone in
                guard let self, let led = self.led(for: zone) else {
                    return NSColor(white: 0.46, alpha: 1)
                }
                return self.ledIndicatorColor(for: led)
            }
        )
        drawLabel(
            mode == .rotate ? "⌘ ROTATE" : "4-D PUSH",
            in: NSRect(x: fourDCenter.x - 44, y: fourDCenter.y + fourDRadius + 4, width: 88, height: 14),
            color: mode == .rotate ? .systemBlue : NSColor(white: 0.6, alpha: 1),
            size: 11
        )
    }

    private func drawPerformanceControls() {
        drawWheel(rect: pitchWheelRect, title: "PITCH", value: pitchValue, range: 0...16_383, centered: true, active: activeWheel == .pitch)
        drawWheel(rect: modWheelRect, title: "MOD", value: modValue, range: 0...127, centered: false, active: activeWheel == .mod)
        drawRibbon()
        drawKeybed()
    }

    private func drawWheel(rect: NSRect, title: String, value: Int, range: ClosedRange<Int>, centered: Bool, active: Bool) {
        let slot = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor(white: 0.08, alpha: 1).setFill()
        slot.fill()
        (active ? NSColor.systemBlue : NSColor(white: 0.35, alpha: 1)).setStroke()
        slot.lineWidth = active ? 2.5 : 1.2
        slot.stroke()

        let progress = CGFloat(value - range.lowerBound) / CGFloat(range.upperBound - range.lowerBound)
        let thumbY = rect.maxY - 12 - progress * (rect.height - 24)
        let thumb = NSRect(x: rect.minX + 5, y: thumbY - 10, width: rect.width - 10, height: 20)
        let thumbPath = NSBezierPath(roundedRect: thumb, xRadius: 4, yRadius: 4)
        NSColor(white: 0.58, alpha: 1).setFill()
        thumbPath.fill()

        if centered {
            NSColor(white: 0.28, alpha: 1).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rect.minX + 4, y: rect.midY))
            line.line(to: NSPoint(x: rect.maxX - 4, y: rect.midY))
            line.lineWidth = 1
            line.stroke()
        }

        drawLabel(title, in: NSRect(x: rect.minX - 8, y: rect.maxY + 5, width: rect.width + 16, height: 14),
                  color: NSColor(white: 0.6, alpha: 1), size: 10)
    }

    private func drawRibbon() {
        let plate = NSBezierPath(roundedRect: ribbonRect, xRadius: 8, yRadius: 8)
        NSColor(white: 0.07, alpha: 1).setFill()
        plate.fill()
        NSColor(white: 0.32, alpha: 1).setStroke()
        plate.lineWidth = 1
        plate.stroke()

        if let ribbonPosition {
            let progress = CGFloat(max(1, min(1024, ribbonPosition)) - 1) / 1023
            let x = ribbonRect.minX + progress * ribbonRect.width
            let indicator = NSBezierPath()
            indicator.move(to: NSPoint(x: x, y: ribbonRect.minY + 3))
            indicator.line(to: NSPoint(x: x, y: ribbonRect.maxY - 3))
            NSColor.systemBlue.setStroke()
            indicator.lineWidth = 2
            indicator.stroke()
        }

        let count = 25
        let dotRadius: CGFloat = 2.3
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.shouldAntialias = true
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        for index in 0..<count {
            let progress = count == 1 ? 0 : CGFloat(index) / CGFloat(count - 1)
            let center = NSPoint(
                x: ribbonLEDRect.minX + dotRadius + progress * (ribbonLEDRect.width - dotRadius * 2),
                y: ribbonLEDRect.midY
            )
            let codeIndex = KKMK2ButtonLED.strip1.rawValue + index
            let code = ledBytes.indices.contains(codeIndex) ? ledBytes[codeIndex] : 0
            let path = NSBezierPath(ovalIn: NSRect(
                x: center.x - dotRadius,
                y: center.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))
            paletteColor(code: code, offWhite: 0.1).setFill()
            path.fill()
        }

        drawLabel("RIBBON", in: NSRect(x: ribbonRect.minX, y: ribbonRect.minY - 18, width: 78, height: 14),
                  color: NSColor(white: 0.6, alpha: 1), size: 10, left: true)
    }

    private func drawKeybed() {
        for key in keyControls where !key.isBlack {
            drawKey(key)
        }
        for key in keyControls where key.isBlack {
            drawKey(key)
        }
        if let first = keyControls.first, let last = keyControls.last {
            drawLabel(keybedSize.title, in: NSRect(x: first.rect.minX, y: first.rect.maxY + 6, width: last.rect.maxX - first.rect.minX, height: 16),
                      color: NSColor(white: 0.58, alpha: 1), size: 11)
        }
    }

    private func drawKey(_ key: KeyControl) {
        let color = lightGuideColor(index: key.index)
        let pressed = pressedKeys.contains(key.index)
        let path = NSBezierPath(roundedRect: key.rect, xRadius: key.isBlack ? 4 : 3, yRadius: key.isBlack ? 4 : 3)

        if key.isBlack {
            (pressed ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.015, alpha: 1)).setFill()
        } else {
            (pressed ? NSColor(white: 0.82, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
        }
        path.fill()

        if color.alphaComponent > 0 {
            let glowHeight = key.isBlack ? max(7, key.rect.height * 0.18) : max(8, key.rect.height * 0.12)
            let glowRect = NSRect(x: key.rect.minX + 2, y: key.rect.minY + 3, width: key.rect.width - 4, height: glowHeight)
            let glow = NSBezierPath(roundedRect: glowRect, xRadius: 3, yRadius: 3)
            color.setFill()
            glow.fill()
        }

        (key.isBlack ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.45, alpha: 1)).setStroke()
        path.lineWidth = key.isBlack ? 1.2 : 0.8
        path.stroke()
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

    private func buttonFillColor(code: UInt8, pressed: Bool, led: KKMK2ButtonLED) -> NSColor {
        if led.isMonochromeBacklit {
            return pressed ? NSColor(white: 0.08, alpha: 1) : NSColor.black
        }

        if code == 0 {
            return pressed ? NSColor(white: 0.08, alpha: 1) : NSColor.black
        }
        let rgb = KompleteKontrolSSeriesMK2.paletteColor(forCode: code)
        return NSColor(red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }

    private func labelColor(for code: UInt8, led: KKMK2ButtonLED) -> NSColor {
        if led.isMonochromeBacklit {
            let rgb = KompleteKontrolSSeriesMK2.paletteColor(forCode: code)
            let brightness = CGFloat(max(rgb.red, rgb.green, rgb.blue)) / 255
            let base = led.fixedMonochromeBacklightColor
            let floor: CGFloat = 0.22
            let scale = max(floor, brightness)
            return NSColor(
                red: CGFloat(base.red) / 255 * scale,
                green: CGFloat(base.green) / 255 * scale,
                blue: CGFloat(base.blue) / 255 * scale,
                alpha: 1
            )
        }
        return code == 0 ? NSColor(white: 0.22, alpha: 1) : NSColor.black.withAlphaComponent(0.8)
    }

    private func paletteColor(code: UInt8, offWhite: CGFloat = 0.0, alpha: CGFloat = 1) -> NSColor {
        guard code != 0 else { return NSColor(white: offWhite, alpha: alpha) }
        let rgb = KompleteKontrolSSeriesMK2.paletteColor(forCode: code)
        return NSColor(
            red: CGFloat(rgb.red) / 255,
            green: CGFloat(rgb.green) / 255,
            blue: CGFloat(rgb.blue) / 255,
            alpha: alpha
        )
    }

    private func lightGuideColor(index: Int) -> NSColor {
        guard lightGuideBytes.indices.contains(index), lightGuideBytes[index] != 0 else { return .clear }
        return paletteColor(code: lightGuideBytes[index], alpha: pressedKeys.contains(index) ? 0.95 : 0.78)
    }

    private func ledIndicatorColor(for led: KKMK2ButtonLED) -> NSColor {
        guard ledBytes.indices.contains(led.rawValue) else { return NSColor(white: 0.08, alpha: 1) }
        let code = ledBytes[led.rawValue]
        guard code != 0 else { return NSColor(white: 0.08, alpha: 1) }
        if led.isRGBBacklit {
            return paletteColor(code: code)
        }

        let rgb = KompleteKontrolSSeriesMK2.paletteColor(forCode: code)
        let brightness = CGFloat(max(rgb.red, rgb.green, rgb.blue)) / 255
        let base = led.fixedMonochromeBacklightColor
        return NSColor(
            red: CGFloat(base.red) / 255 * brightness,
            green: CGFloat(base.green) / 255 * brightness,
            blue: CGFloat(base.blue) / 255 * brightness,
            alpha: 1
        )
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let key = key(at: point) {
            activeKey = key.index
            activeKeyPressureOriginY = point.y
            setKey(key, pressed: true, velocity: keyValue(at: point, for: key))
            return
        }
        if pitchWheelRect.contains(point) {
            activeWheel = .pitch
            setWheel(.pitch, at: point)
            return
        }
        if modWheelRect.contains(point) {
            activeWheel = .mod
            setWheel(.mod, at: point)
            return
        }
        if ribbonRect.contains(point) {
            activeRibbon = true
            setRibbon(at: point)
            return
        }
        if let button = buttons.first(where: { $0.rect.contains(point) }) {
            activeButton = button.led
            pressedButtons.insert(button.led)
            interactionAudio.playClick()
            onInput?(.button(led: button.led, pressed: true))
            needsDisplay = true
            return
        }
        if let encoder = encoders.first(where: { $0.rect.contains(point) }) {
            if event.modifierFlags.contains(.command) {
                activeEncoderTouchOnly = encoder.index
                beginEncoderTouch(index: encoder.index)
                return
            }
            activeEncoder = encoder.index
            lastDragY = point.y
            beginEncoderTouch(index: encoder.index)
            return
        }
        if CombinedClickRotaryEncoder.pushZone(at: point, in: fourDRect) != nil {
            if event.modifierFlags.contains(.command) {
                activeFourDRotation = true
                lastDragY = point.y
                beginFourDTouch()
                return
            }
            let state = fourDZone(point)
            activeFourD = state
            interactionAudio.playClick()
            onInput?(.fourDState(state.rawValue))
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if activeEncoderTouchOnly != nil {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        if let activeKey {
            guard let current = keyControls.first(where: { $0.index == activeKey }) else {
                self.activeKey = nil
                activeKeyPressure = nil
                activeKeyPressureOriginY = nil
                return
            }

            let nextKey = key(at: point)
            if nextKey?.index != activeKey {
                if let nextKey {
                    setKey(current, pressed: false)
                    self.activeKey = nextKey.index
                    activeKeyPressureOriginY = point.y
                    setKey(nextKey, pressed: true, velocity: keyValue(at: point, for: nextKey))
                    updateChannelPressure(at: point, for: nextKey, force: true)
                } else if current.rect.minX...current.rect.maxX ~= point.x {
                    updateChannelPressure(at: point, for: current, force: false)
                } else {
                    setKey(current, pressed: false)
                    self.activeKey = nil
                    activeKeyPressureOriginY = nil
                }
            } else {
                updateChannelPressure(at: point, for: current, force: false)
            }
            return
        }
        if let activeWheel {
            setWheel(activeWheel, at: point)
            return
        }
        if activeRibbon {
            setRibbon(at: point)
            return
        }

        if activeFourDRotation {
            let steps = Int((lastDragY - point.y) / 4) // drag up = clockwise/increase
            if steps != 0 {
                emitFourDWheel(delta: steps)
                lastDragY -= CGFloat(steps) * 4
            }
            return
        }

        if activeFourD != nil {
            guard hypot(point.x - fourDCenter.x, point.y - fourDCenter.y) <= fourDRadius else { return }
            let state = fourDZone(point)
            if state != activeFourD {
                activeFourD = state
                onInput?(.fourDState(state.rawValue))
                needsDisplay = true
            }
            return
        }

        guard let index = activeEncoder else { return }
        let steps = Int((lastDragY - point.y) / 4) // drag up = increase (flipped view)
        if steps != 0 {
            emitEncoder(index: index, delta: steps * Self.encoderCountsPerScrollTick)
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
        if let index = activeEncoderTouchOnly {
            endEncoderTouch(index: index)
            activeEncoderTouchOnly = nil
        }
        if let index = activeEncoder {
            endEncoderTouch(index: index)
            activeEncoder = nil
        }
        if activeFourDRotation {
            endFourDTouch()
            activeFourDRotation = false
        }
        if activeFourD != nil {
            onInput?(.fourDState(MK2InputReportBuilder.FourDState.released.rawValue))
            activeFourD = nil
            needsDisplay = true
        }
        if let activeKey, let key = keyControls.first(where: { $0.index == activeKey }) {
            setKey(key, pressed: false)
            self.activeKey = nil
            activeKeyPressureOriginY = nil
        }
        if activeWheel == .pitch {
            pitchValue = 8192
            sendPitchWheel()
        }
        activeWheel = nil
        if activeRibbon {
            activeRibbon = false
            ribbonPosition = nil
            onInput?(.strip(position: nil, time: nextRibbonTimestamp()))
            needsDisplay = true
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let overFourD = CombinedClickRotaryEncoder.pushZone(at: point, in: fourDRect) != nil
        if event.modifierFlags.contains(.command), !overFourD {
            super.scrollWheel(with: event)
            return
        }
        if event.hasPreciseScrollingDeltas,
           enclosingScrollViewCanScroll,
           !(event.modifierFlags.contains(.command) && overFourD) {
            super.scrollWheel(with: event)
            return
        }

        let raw = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 6 : event.scrollingDeltaY
        let delta = raw > 0 ? 1 : (raw < 0 ? -1 : 0)
        guard delta != 0 else {
            super.scrollWheel(with: event)
            return
        }
        if let encoder = encoders.first(where: { $0.rect.contains(point) }) {
            beginEncoderTouch(index: encoder.index)
            // Hardware fidelity: the real rotaries deliver ~900 counts for a
            // slow full sweep (~360 per revolution), so one wheel notch — a
            // ~12° twist — must emit a bundle of counts, not a single one.
            // The 4-D wheel below stays 1:1: its wire counter is 4-bit.
            emitEncoder(index: encoder.index, delta: delta * Self.encoderCountsPerScrollTick)
            scheduleEncoderTouchRelease(index: encoder.index)
        } else if overFourD, event.modifierFlags.contains(.command) {
            beginFourDTouch()
            emitFourDWheel(delta: delta)
            scheduleFourDTouchRelease()
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if handleKeyDown(event) { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if handleKeyUp(event) { return }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if handleFlagsChanged(event) { return }
        super.flagsChanged(with: event)
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command),
              let action = keyboardAction(for: event) else {
            return false
        }
        if event.isARepeat {
            return true
        }
        switch action {
            case let .button(led):
                pressKeyboardButton(led)
            case let .fourD(state):
                pressKeyboardFourD(state)
        }
        return true
    }

    func handleKeyUp(_ event: NSEvent) -> Bool {
        guard let action = keyboardAction(for: event) else { return false }
        switch action {
            case let .button(led):
                releaseKeyboardButton(led)
            case let .fourD(state):
                releaseKeyboardFourD(state)
        }
        return true
    }

    func handleFlagsChanged(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shiftDown = flags.contains(.shift)
        let nextCommandRotationMode = flags.contains(.command)
        if commandRotationMode != nextCommandRotationMode {
            commandRotationMode = nextCommandRotationMode
            needsDisplay = true
        }
        if shiftDown {
            pressKeyboardButton(.shift)
        } else {
            releaseKeyboardButton(.shift)
        }
        return true
    }

    func releaseKeyboardInputs() {
        for led in keyboardButtons {
            pressedButtons.remove(led)
            onInput?(.button(led: led, pressed: false))
        }
        keyboardButtons.removeAll()
        if keyboardFourD != nil {
            onInput?(.fourDState(MK2InputReportBuilder.FourDState.released.rawValue))
            keyboardFourD = nil
            activeFourD = nil
        }
        commandRotationMode = false
        needsDisplay = true
    }

    private var enclosingScrollViewCanScroll: Bool {
        guard let scrollView = enclosingScrollView else { return false }
        let documentSize = NSSize(
            width: frame.width * scrollView.magnification,
            height: frame.height * scrollView.magnification
        )
        return documentSize.width > scrollView.contentSize.width + 0.5
            || documentSize.height > scrollView.contentSize.height + 0.5
    }

    private func keyboardAction(for event: NSEvent) -> KeyboardAction? {
        switch event.keyCode {
            case 36, 76:
                return .fourD(.click)
            case 53:
                return .button(.stop)
            case 123:
                return .fourD(.pushLeft)
            case 124:
                return .fourD(.pushRight)
            case 125:
                return .fourD(.pushDown)
            case 126:
                return .fourD(.pushUp)
            default:
                break
        }

        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        switch key {
            case "1": return .button(.function1)
            case "2": return .button(.function2)
            case "3": return .button(.function3)
            case "4": return .button(.function4)
            case "5": return .button(.function5)
            case "6": return .button(.function6)
            case "7": return .button(.function7)
            case "8": return .button(.function8)
            case " ": return .button(.play)
            case "m": return .button(.m)
            case "s": return .button(.s)
            case "i": return .button(.instance)
            case "r": return .button(.record)
            case "b": return .button(.browser)
            case "p": return .button(.plugin)
            case "x": return .button(.mixer)
            case "[": return .button(.pageLeft)
            case "]": return .button(.pageRight)
            case ",": return .button(.presetDown)
            case ".": return .button(.presetUp)
            case "c": return .button(.clear)
            case "k": return .button(.keyMode)
            case "t": return .button(.track)
            case "l": return .button(.loop)
            default: return nil
        }
    }

    private func pressKeyboardButton(_ led: KKMK2ButtonLED) {
        guard !keyboardButtons.contains(led) else { return }
        keyboardButtons.insert(led)
        pressedButtons.insert(led)
        interactionAudio.playClick()
        onInput?(.button(led: led, pressed: true))
        needsDisplay = true
    }

    private func releaseKeyboardButton(_ led: KKMK2ButtonLED) {
        guard keyboardButtons.contains(led) else { return }
        keyboardButtons.remove(led)
        if activeButton != led {
            pressedButtons.remove(led)
        }
        onInput?(.button(led: led, pressed: false))
        needsDisplay = true
    }

    private func pressKeyboardFourD(_ state: MK2InputReportBuilder.FourDState) {
        guard keyboardFourD != state else { return }
        if keyboardFourD != nil {
            onInput?(.fourDState(MK2InputReportBuilder.FourDState.released.rawValue))
        }
        keyboardFourD = state
        activeFourD = state
        interactionAudio.playClick()
        onInput?(.fourDState(state.rawValue))
        needsDisplay = true
    }

    private func releaseKeyboardFourD(_ state: MK2InputReportBuilder.FourDState) {
        guard keyboardFourD == state else { return }
        keyboardFourD = nil
        activeFourD = nil
        onInput?(.fourDState(MK2InputReportBuilder.FourDState.released.rawValue))
        needsDisplay = true
    }

    private func emitEncoder(index: Int, delta: Int) {
        encoderAngle[index - 1] += Double(delta) * 0.35
        interactionAudio.playRotate()
        onInput?(.encoder(index: index, delta: delta))
        needsDisplay = true
    }

    private func emitFourDWheel(delta: Int) {
        fourDWheelAngle += Double(delta) * 0.35
        interactionAudio.playRotate()
        onInput?(.fourDWheel(delta: delta))
        needsDisplay = true
    }

    private func key(at point: NSPoint) -> KeyControl? {
        keyControls.first { $0.isBlack && $0.rect.contains(point) }
            ?? keyControls.first { !$0.isBlack && $0.rect.contains(point) }
    }

    private func setKey(_ key: KeyControl, pressed: Bool, velocity: UInt8 = 100) {
        if pressed {
            guard !pressedKeys.contains(key.index) else { return }
            pressedKeys.insert(key.index)
            onInput?(.note(key.note, velocity: velocity, on: true))
        } else {
            guard pressedKeys.contains(key.index) else { return }
            if activeKeyPressure != nil {
                onInput?(.midi(status: 0xd0, data1: 0, data2: 0))
                activeKeyPressure = nil
            }
            activeKeyPressureOriginY = nil
            pressedKeys.remove(key.index)
            onInput?(.note(key.note, velocity: 0, on: false))
        }
        needsDisplay = true
    }

    private func updateChannelPressure(at point: NSPoint, for key: KeyControl, force: Bool) {
        if !force, activeKeyPressure == nil, let originY = activeKeyPressureOriginY, abs(point.y - originY) <= 5 {
            return
        }
        let pressure = Int(keyValue(at: point, for: key, minimum: 0))
        guard force || activeKeyPressure != pressure else { return }
        activeKeyPressure = pressure
        onInput?(.midi(status: 0xd0, data1: UInt8(pressure), data2: 0))
        needsDisplay = true
    }

    private func keyValue(at point: NSPoint, for key: KeyControl, minimum: UInt8 = 1) -> UInt8 {
        let clampedY = max(key.rect.minY, min(key.rect.maxY, point.y))
        let progress = 1 - ((clampedY - key.rect.minY) / max(1, key.rect.height))
        return UInt8(max(Int(minimum), min(127, Int((progress * 127).rounded()))))
    }

    private func setWheel(_ wheel: WheelKind, at point: NSPoint) {
        let rect = wheel == .pitch ? pitchWheelRect : modWheelRect
        let clampedY = max(rect.minY, min(rect.maxY, point.y))
        let progress = 1 - ((clampedY - rect.minY) / max(1, rect.height))
        switch wheel {
            case .pitch:
                let next = max(0, min(16_383, Int((progress * 16_383).rounded())))
                guard next != pitchValue else { return }
                pitchValue = next
                sendPitchWheel()
            case .mod:
                let next = max(0, min(127, Int((progress * 127).rounded())))
                guard next != modValue else { return }
                modValue = next
                onInput?(.midi(status: 0xb0, data1: 1, data2: UInt8(next)))
        }
        needsDisplay = true
    }

    private func sendPitchWheel() {
        onInput?(.midi(status: 0xe0, data1: UInt8(pitchValue & 0x7f), data2: UInt8((pitchValue >> 7) & 0x7f)))
    }

    private func setRibbon(at point: NSPoint) {
        let clampedX = max(ribbonRect.minX, min(ribbonRect.maxX, point.x))
        let progress = (clampedX - ribbonRect.minX) / max(1, ribbonRect.width)
        let position = max(1, min(1024, Int((progress * 1023).rounded()) + 1))
        ribbonPosition = position
        onInput?(.strip(position: position, time: nextRibbonTimestamp()))
        needsDisplay = true
    }

    private func nextRibbonTimestamp() -> Int {
        ribbonTimestamp = (ribbonTimestamp + 10) & 0xffff
        return ribbonTimestamp
    }

    private func isBlackKey(index: Int) -> Bool {
        switch index % 12 {
            case 1, 3, 6, 8, 10: true
            default: false
        }
    }

    private func beginEncoderTouch(index: Int) {
        guard encoderTouched.indices.contains(index - 1) else { return }
        pendingEncoderTouchReleases[index]?.cancel()
        pendingEncoderTouchReleases[index] = nil
        if !encoderTouched[index - 1] {
            encoderTouched[index - 1] = true
            onInput?(.encoderTouch(index: index, touched: true))
        }
        needsDisplay = true
    }

    private func endEncoderTouch(index: Int) {
        guard encoderTouched.indices.contains(index - 1) else { return }
        pendingEncoderTouchReleases[index]?.cancel()
        pendingEncoderTouchReleases[index] = nil
        if encoderTouched[index - 1] {
            encoderTouched[index - 1] = false
            onInput?(.encoderTouch(index: index, touched: false))
        }
        needsDisplay = true
    }

    private func scheduleEncoderTouchRelease(index: Int) {
        pendingEncoderTouchReleases[index]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.endEncoderTouch(index: index)
        }
        pendingEncoderTouchReleases[index] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func beginFourDTouch() {
        pendingFourDTouchRelease?.cancel()
        pendingFourDTouchRelease = nil
        if !fourDWheelTouched {
            fourDWheelTouched = true
            onInput?(.fourDTouch(touched: true))
        }
        needsDisplay = true
    }

    private func endFourDTouch() {
        pendingFourDTouchRelease?.cancel()
        pendingFourDTouchRelease = nil
        if fourDWheelTouched {
            fourDWheelTouched = false
            onInput?(.fourDTouch(touched: false))
        }
        needsDisplay = true
    }

    private func scheduleFourDTouchRelease() {
        pendingFourDTouchRelease?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.endFourDTouch()
        }
        pendingFourDTouchRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func fourDZone(_ point: NSPoint) -> MK2InputReportBuilder.FourDState {
        switch CombinedClickRotaryEncoder.pushZone(at: point, in: fourDRect) ?? .center {
            case .center: return .click
            case .up: return .pushUp
            case .right: return .pushRight
            case .down: return .pushDown
            case .left: return .pushLeft
        }
    }

    private var fourDRect: NSRect {
        NSRect(
            x: fourDCenter.x - fourDRadius,
            y: fourDCenter.y - fourDRadius,
            width: fourDRadius * 2,
            height: fourDRadius * 2
        )
    }

    private func combinedPushZone(
        for state: MK2InputReportBuilder.FourDState?
    ) -> CombinedClickRotaryEncoder.PushZone? {
        switch state {
            case .click: return .center
            case .pushUp: return .up
            case .pushRight: return .right
            case .pushDown: return .down
            case .pushLeft: return .left
            case .touched, .released, .none: return nil
        }
    }

    private func led(for zone: CombinedClickRotaryEncoder.PushZone) -> KKMK2ButtonLED? {
        switch zone {
            case .center: return nil
            case .up: return .jogUp
            case .right: return .jogRight
            case .down: return .jogDown
            case .left: return .jogLeft
        }
    }
}

/// Keeps click/turn sounds ready on a warm AVAudioEngine. The buffers are generated once and
/// fired through round-robin player nodes so quick repeats do not wait behind older blips.
private final class InteractionAudio {
    private let engine = AVAudioEngine()
    private let clickBuffer: AVAudioPCMBuffer
    private let rotateBuffer: AVAudioPCMBuffer
    private let clickPlayers: [AVAudioPlayerNode]
    private let rotatePlayers: [AVAudioPlayerNode]
    private var nextClickPlayer = 0
    private var nextRotatePlayer = 0

    init() {
        let hardwareFormat = engine.outputNode.inputFormat(forBus: 0)
        let sampleRate = hardwareFormat.sampleRate > 0 ? hardwareFormat.sampleRate : 48_000
        let channelCount = max(1, min(2, hardwareFormat.channelCount))
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)!

        clickBuffer = Self.makeClickBuffer(format: format)
        rotateBuffer = Self.makeRotateBuffer(format: format)
        clickPlayers = Self.makePlayers(count: 6, engine: engine, format: format)
        rotatePlayers = Self.makePlayers(count: 10, engine: engine, format: format)

        engine.prepare()
        try? engine.start()
    }

    func playClick() {
        play(clickBuffer, players: clickPlayers, nextIndex: &nextClickPlayer)
    }

    func playRotate() {
        play(rotateBuffer, players: rotatePlayers, nextIndex: &nextRotatePlayer)
    }

    private func play(_ buffer: AVAudioPCMBuffer, players: [AVAudioPlayerNode], nextIndex: inout Int) {
        guard !players.isEmpty else { return }
        if !engine.isRunning {
            try? engine.start()
        }

        let player = players[nextIndex]
        nextIndex = (nextIndex + 1) % players.count
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        player.play()
    }

    private static func makePlayers(count: Int, engine: AVAudioEngine, format: AVAudioFormat) -> [AVAudioPlayerNode] {
        (0..<count).map { _ in
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            return player
        }
    }

    private static func makeClickBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
        makeBuffer(format: format, duration: 0.018) { time, progress in
            let envelope = exp(-progress * 9.5)
            let tone = sin(2 * .pi * 1_750 * time)
            let snap = sin(2 * .pi * 3_200 * time) * exp(-progress * 22)
            return Float((tone * 0.42 + snap * 0.18) * envelope)
        }
    }

    private static func makeRotateBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
        makeBuffer(format: format, duration: 0.026) { time, progress in
            let frequency = 620 + progress * 180
            let envelope = sin(.pi * progress) * exp(-progress * 2.8)
            return Float(sin(2 * .pi * frequency * time) * envelope * 0.30)
        }
    }

    private static func makeBuffer(
        format: AVAudioFormat,
        duration: Double,
        sample: (Double, Double) -> Float
    ) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(format.sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        guard let channels = buffer.floatChannelData else { return buffer }
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / format.sampleRate
            let progress = Double(frame) / Double(max(1, Int(frameCount) - 1))
            let value = sample(time, progress)
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = value
            }
        }
        return buffer
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
