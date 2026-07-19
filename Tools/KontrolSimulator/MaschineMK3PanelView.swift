import AppKit
import KompleteKontrol
import KontrolSimulatorCore

/// Calibrated, fully interactive MASCHINE MK3 panel. Geometry is defined in millimetre-
/// derived headless descriptors; this view only projects it into AppKit points.
final class MaschineMK3PanelView: NSView, SimulatorPanel {
    static let deviceBackgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1)

    var onInput: ((SimFrame) -> Void)?
    var onDaemonStatus: ((SimulatorDaemonStatus) -> Void)?
    var view: NSView { self }
    var backgroundColor: NSColor { Self.deviceBackgroundColor }
    var keyboardCheatSheetText: String { Self.keyboardCheatSheetText }
    var trueSizeReference: SimulatorTrueSizeReference {
        SimulatorTrueSizeReference(
            physicalWidthMM: CGFloat(MaschineMK3PanelGeometry.physicalWidthMM),
            baseWidthPoints: bounds.width
        )
    }

    private let geometry = MaschineMK3PanelGeometry.calibrated
    private let runtime: SimulatorDeviceRuntime
    private let output: SimulatorOutputState
    private var screenImages: [CGImage?] = [nil, nil]
    private var screenImagesDirty = true
    private var pressedButtons: Set<MaschineMK3Button> = []
    private var heldPads: Set<Int> = []
    private var encoderAngles = [Double](repeating: 0, count: 9)
    private var touchedEncoders = [Bool](repeating: false, count: 9)
    private var stripPositions: [Int?] = [nil, nil]
    private var commandRotationMode = false

    private enum ActiveControl {
        case button(MaschineMK3Button)
        case encoder(index: Int, touchOnly: Bool)
        case pad(number: Int, originY: CGFloat)
        case strip(finger: Int)
    }
    private var activeControl: ActiveControl?
    private var lastDragY: CGFloat = 0
    private var keyboardButtons: [UInt16: MaschineMK3Button] = [:]
    private var keyboardPads: [UInt16: Int] = [:]

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(definition: SimulatorDeviceDefinition) {
        runtime = SimulatorDeviceRuntime(definition: definition)
        output = SimulatorOutputState(definition: definition)
        super.init(frame: NSRect(
            x: 0, y: 0,
            width: MaschineMK3PanelGeometry.panelWidth,
            height: MaschineMK3PanelGeometry.panelHeight
        ))
        runtime.onInputFrame = { [weak self] frame in self?.onInput?(frame) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("MASCHINE MK3 simulator")
    }

    required init?(coder: NSCoder) { fatalError() }

    var displayBlockRect: NSRect {
        geometry.displays.map(rect).reduce(.null) { $0.union($1) }
    }

    var displayWorkAreaRect: NSRect {
        let controls = geometry.displayEncoders.map(rect)
            + geometry.buttons.filter { $0.button.rawValue.hasPrefix("display-button") }.map { rect($0.rect) }
        return controls.reduce(displayBlockRect) { $0.union($1) }
    }

    func apply(_ frame: SimFrame) {
        do {
            guard try output.apply(frame) else { return }
            if frame.type == .displayBlit || frame.type == .displayPacket {
                screenImagesDirty = true
            }
            needsDisplay = true
        } catch {
            onDaemonStatus?(.protocolError)
        }
    }

    func clearAll() {
        output.clear()
        runtime.releaseAllMaschineInputs()
        screenImages = [nil, nil]
        screenImagesDirty = true
        pressedButtons.removeAll()
        heldPads.removeAll()
        touchedEncoders = [Bool](repeating: false, count: 9)
        stripPositions = [nil, nil]
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        Self.deviceBackgroundColor.setFill()
        bounds.fill()

        let chassis = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 5), xRadius: 10, yRadius: 10)
        NSColor(calibratedWhite: 0.105, alpha: 1).setFill()
        chassis.fill()
        NSColor(calibratedWhite: 0.19, alpha: 1).setStroke()
        chassis.lineWidth = 1
        chassis.stroke()

        drawDisplays()
        drawDisplayEncoders()
        drawButtons()
        drawGroupButtons()
        drawPads()
        drawTouchStrip()
    }

    private func drawDisplays() {
        if screenImagesDirty {
            screenImages = output.screens.map { Self.makeImage(snapshot: $0.snapshot()) }
            screenImagesDirty = false
        }
        for (index, descriptor) in geometry.displays.enumerated() {
            let displayRect = rect(descriptor)
            SimulatorDisplayBezel.draw(
                around: displayRect,
                outset: CGFloat(MaschineMK3PanelGeometry.displayBezelOutset)
            )
            if let image = screenImages[index] {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.imageInterpolation = .high
                NSGraphicsContext.current?.shouldAntialias = true
                NSImage(cgImage: image, size: displayRect.size).draw(in: displayRect)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                NSColor(calibratedWhite: 0.015, alpha: 1).setFill(); displayRect.fill()
            }
        }
    }

    private func drawDisplayEncoders() {
        for (offset, descriptor) in geometry.displayEncoders.enumerated() {
            drawEncoder(in: rect(descriptor), index: offset + 1)
        }
        drawMainEncoder()
    }

    private func drawMainEncoder() {
        let activeButton = Self.mainEncoderButtons.first { pressedButtons.contains($0) }
        let mode: CombinedClickRotaryEncoder.Mode = commandRotationMode || isMainEncoderRotating ? .rotate : .push
        CombinedClickRotaryEncoder.draw(
            in: rect(geometry.mainEncoder),
            mode: mode,
            rotationAngle: encoderAngles[0],
            touched: touchedEncoders[0] || activeButton != nil,
            activePush: activeButton.flatMap { Self.pushZone(for: $0) }
        )
        drawLabel(
            mode == .rotate ? "⌘ ROTATE" : "4-D PUSH",
            in: NSRect(x: 54, y: 446, width: 88, height: 15),
            color: mode == .rotate ? .systemBlue : NSColor(calibratedWhite: 0.55, alpha: 1),
            size: 9.5,
            bold: true
        )
    }

    private func drawEncoder(in controlRect: NSRect, index: Int) {
        let outer = NSBezierPath(ovalIn: controlRect)
        NSColor(calibratedWhite: touchedEncoders[index] ? 0.28 : 0.18, alpha: 1).setFill(); outer.fill()
        NSColor(calibratedWhite: 0.38, alpha: 1).setStroke(); outer.lineWidth = 1.5; outer.stroke()
        let knob = NSBezierPath(ovalIn: controlRect.insetBy(dx: controlRect.width * 0.17, dy: controlRect.height * 0.17))
        NSColor(calibratedWhite: 0.11, alpha: 1).setFill(); knob.fill()
        let center = NSPoint(x: controlRect.midX, y: controlRect.midY)
        let angle = encoderAngles[index] - .pi * 0.75
        let radius = controlRect.width * 0.27
        let marker = NSBezierPath()
        marker.move(to: center)
        marker.line(to: NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
        (touchedEncoders[index] ? NSColor.systemCyan : NSColor(calibratedWhite: 0.65, alpha: 1)).setStroke()
        marker.lineWidth = 2; marker.stroke()
    }

    private func drawButtons() {
        let lamps = output.lampSnapshot()
        for descriptor in geometry.buttons where !Self.combinedAndPadStyleButtons.contains(descriptor.button) {
            let controlRect = rect(descriptor.rect)
            let raw = descriptor.button.led.flatMap { led in
                lamps.buttonBytes.indices.contains(led.rawValue) ? lamps.buttonBytes[led.rawValue] : nil
            } ?? 0
            let colorEncoded = descriptor.button.led?.usesColorEncoding == true
            let lamp = Self.lampColor(raw: raw, colorEncoded: colorEncoded)
            let pressed = pressedButtons.contains(descriptor.button)
            let path = NSBezierPath(roundedRect: controlRect, xRadius: 3, yRadius: 3)
            Self.buttonFillColor(raw: raw, lamp: lamp, pressed: pressed, colorEncoded: colorEncoded).setFill()
            path.fill()
            NSColor(calibratedWhite: pressed ? 0.92 : 0.30, alpha: 1).setStroke()
            path.lineWidth = pressed ? 1.5 : 1
            path.stroke()
            let labelColor = Self.buttonLabelColor(
                raw: raw, lamp: lamp, pressed: pressed, colorEncoded: colorEncoded
            )
            drawLabel(descriptor.label, in: controlRect.insetBy(dx: 4, dy: 4),
                      color: labelColor,
                      size: descriptor.label.count > 8 ? 8.2 : 9.2, bold: true)
            if let secondary = descriptor.secondaryLabel {
                drawLabel(secondary, in: controlRect.insetBy(dx: 4, dy: 4).offsetBy(dx: 0, dy: 10),
                          color: labelColor.withAlphaComponent(0.62), size: 7.3)
            }
        }
    }

    private func drawGroupButtons() {
        let lamps = output.lampSnapshot()
        for descriptor in geometry.buttons where Self.groupButtons.contains(descriptor.button) {
            let raw = descriptor.button.led.flatMap { led in
                lamps.buttonBytes.indices.contains(led.rawValue) ? lamps.buttonBytes[led.rawValue] : nil
            } ?? 0
            drawPadSurface(
                in: rect(descriptor.rect),
                label: descriptor.label,
                rawLamp: raw,
                active: pressedButtons.contains(descriptor.button),
                labelInset: NSSize(width: 7, height: 6)
            )
        }
    }

    private func drawPads() {
        let lamps = output.lampSnapshot()
        for (index, descriptor) in geometry.pads.enumerated() {
            let number = index + 1
            let controlRect = rect(descriptor)
            let shiftLabel = geometry.padShiftLabels[index]
            let hardwareIndex = MaschineMK3InputReportBuilder.hardwareIndex(forPhysicalPadNumber: number) ?? 0
            let led = MaschineMK3PadLED(hardwareIndex: hardwareIndex)
            let raw = led.flatMap { lamps.stripAndPadBytes.indices.contains($0.rawValue) ? lamps.stripAndPadBytes[$0.rawValue] : nil } ?? 0
            drawPadSurface(
                in: controlRect,
                label: "\(number) \(shiftLabel)",
                rawLamp: raw,
                active: heldPads.contains(number),
                labelInset: NSSize(width: 7, height: 6)
            )
        }
    }

    private func drawPadSurface(
        in controlRect: NSRect,
        label: String,
        rawLamp: UInt8,
        active: Bool,
        labelInset: NSSize
    ) {
        let color = Self.lampColor(raw: rawLamp, colorEncoded: true)
        let pad = NSBezierPath(roundedRect: controlRect, xRadius: 5, yRadius: 5)
        (active ? NSColor(calibratedWhite: 0.83, alpha: 1) : NSColor(calibratedWhite: 0.68, alpha: 1)).setFill()
        pad.fill()
        if color.alphaComponent > 0 {
            color.withAlphaComponent(active ? 0.8 : 0.42).setFill()
            pad.fill()
        }
        NSColor(calibratedWhite: 0.27, alpha: 1).setStroke()
        pad.lineWidth = 1.2
        pad.stroke()
        drawLabel(
            label,
            in: controlRect.insetBy(dx: labelInset.width, dy: labelInset.height),
            color: NSColor(calibratedWhite: 0.18, alpha: 1),
            size: 10,
            bold: true
        )
    }

    private func drawTouchStrip() {
        let stripRect = rect(geometry.touchStrip)
        let path = NSBezierPath(roundedRect: stripRect, xRadius: 4, yRadius: 4)
        NSColor(calibratedWhite: 0.045, alpha: 1).setFill(); path.fill()
        let lamps = output.lampSnapshot()
        let segmentGap: CGFloat = 2
        let segmentWidth = (stripRect.width - CGFloat(MaschineMK3Protocol.stripLEDCount - 1) * segmentGap)
            / CGFloat(MaschineMK3Protocol.stripLEDCount)
        for index in 0..<MaschineMK3Protocol.stripLEDCount {
            let raw = lamps.stripAndPadBytes.indices.contains(index) ? lamps.stripAndPadBytes[index] : 0
            let color = Self.lampColor(raw: raw, colorEncoded: true)
            (color.alphaComponent > 0 ? color : NSColor(calibratedWhite: 0.12, alpha: 1)).setFill()
            NSRect(x: stripRect.minX + CGFloat(index) * (segmentWidth + segmentGap), y: stripRect.minY + 4,
                   width: segmentWidth, height: 6).fill()
        }
        for (finger, position) in stripPositions.enumerated() {
            guard let position else { continue }
            let x = stripRect.minX + CGFloat(position) / 1023 * stripRect.width
            let marker = NSBezierPath(ovalIn: NSRect(x: x - 5, y: stripRect.midY - 5 + CGFloat(finger * 12), width: 10, height: 10))
            (finger == 0 ? NSColor.systemCyan : NSColor.systemPink).setFill(); marker.fill()
        }
    }

    private func drawLabel(_ text: String, in labelRect: NSRect, color: NSColor, size: CGFloat, bold: Bool = false) {
        let style = NSMutableParagraphStyle(); style.alignment = .left
        NSAttributedString(string: text, attributes: [
            .font: bold ? NSFont.systemFont(ofSize: size, weight: .semibold) : NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]).draw(in: labelRect)
    }

    // MARK: Mouse interaction

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let zone = CombinedClickRotaryEncoder.pushZone(at: point, in: rect(geometry.mainEncoder)) {
            if event.modifierFlags.contains(.command) {
                beginMainEncoderRotation(at: point)
            } else {
                let button = Self.button(for: zone)
                activeControl = .button(button)
                pressedButtons.insert(button)
                runtime.setMaschineButton(button, pressed: true)
                needsDisplay = true
            }
            return
        }
        if let descriptor = geometry.buttons.reversed().first(where: {
            !Self.mainEncoderButtons.contains($0.button) && rect($0.rect).contains(point)
        }) {
            activeControl = .button(descriptor.button)
            pressedButtons.insert(descriptor.button)
            runtime.setMaschineButton(descriptor.button, pressed: true)
            needsDisplay = true
            return
        }
        if let padIndex = geometry.pads.firstIndex(where: { rect($0).contains(point) }) {
            let number = padIndex + 1
            let padRect = rect(geometry.pads[padIndex])
            let velocity = padVelocity(point: point, in: padRect)
            activeControl = .pad(number: number, originY: point.y)
            heldPads.insert(number)
            runtime.touchMaschinePad(physicalPad: number, pressure: min(800, velocity / 4))
            runtime.strikeMaschinePad(physicalPad: number, velocity: velocity)
            needsDisplay = true
            return
        }
        if let encoderIndex = geometry.displayEncoders.firstIndex(where: { rect($0).contains(point) }) {
            beginEncoder(index: encoderIndex + 1, event: event, point: point)
            return
        }
        if rect(geometry.touchStrip).contains(point) {
            let finger = event.modifierFlags.contains(.option) ? 2 : 1
            activeControl = .strip(finger: finger)
            updateStrip(finger: finger, point: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch activeControl {
            case let .encoder(index, touchOnly):
                guard !touchOnly else { return }
                let delta = Int((lastDragY - point.y) / 3)
                if delta != 0 {
                    runtime.turnMaschineEncoder(index, delta: delta)
                    encoderAngles[index] += Double(delta) * 0.075
                    lastDragY = point.y
                    needsDisplay = true
                }
            case let .pad(number, originY):
                let pressure = max(1, min(4095, 1900 + Int((originY - point.y) * 36)))
                runtime.pressureMaschinePad(physicalPad: number, pressure: pressure)
            case let .strip(finger):
                updateStrip(finger: finger, point: point)
            case .button, .none:
                break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch activeControl {
            case let .button(button):
                pressedButtons.remove(button)
                runtime.setMaschineButton(button, pressed: false)
            case let .encoder(index, _):
                touchedEncoders[index] = false
                runtime.setMaschineEncoderTouch(index, touched: false)
            case let .pad(number, _):
                heldPads.remove(number)
                runtime.releaseMaschinePad(physicalPad: number)
            case let .strip(finger):
                stripPositions[finger - 1] = nil
                runtime.setMaschineTouchStrip(finger: finger, position: nil)
            case .none:
                break
        }
        activeControl = nil
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index: Int?
        if let found = geometry.displayEncoders.firstIndex(where: { rect($0).contains(point) }) {
            index = found + 1
        } else if rect(geometry.mainEncoder).contains(point), event.modifierFlags.contains(.command) {
            index = 0
        } else {
            index = nil
        }
        guard let index else { super.scrollWheel(with: event); return }
        let raw = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        let normalized = event.hasPreciseScrollingDeltas ? Int(raw / 2) : Int(raw.sign == .minus ? -4 : 4)
        let delta = normalized == 0 ? (raw < 0 ? -1 : 1) : normalized
        runtime.turnMaschineEncoder(index, delta: delta)
        encoderAngles[index] += Double(delta) * 0.075
        needsDisplay = true
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

    private func beginEncoder(index: Int, event: NSEvent, point: NSPoint) {
        let touchOnly = event.modifierFlags.contains(.command)
        activeControl = .encoder(index: index, touchOnly: touchOnly)
        lastDragY = point.y
        touchedEncoders[index] = true
        runtime.setMaschineEncoderTouch(index, touched: true)
        needsDisplay = true
    }

    private func beginMainEncoderRotation(at point: NSPoint) {
        activeControl = .encoder(index: 0, touchOnly: false)
        lastDragY = point.y
        touchedEncoders[0] = true
        runtime.setMaschineEncoderTouch(0, touched: true)
        needsDisplay = true
    }

    private func updateStrip(finger: Int, point: NSPoint) {
        let stripRect = rect(geometry.touchStrip)
        let position = max(1, min(1023, Int((point.x - stripRect.minX) / stripRect.width * 1023)))
        stripPositions[finger - 1] = position
        runtime.setMaschineTouchStrip(finger: finger, position: position)
        needsDisplay = true
    }

    private func padVelocity(point: NSPoint, in padRect: NSRect) -> Int {
        let normalized = max(0, min(1, (padRect.maxY - point.y) / padRect.height))
        return max(256, min(4095, Int(1200 + normalized * 2895)))
    }

    // MARK: Keyboard interaction

    func handleKeyDown(_ event: NSEvent) -> Bool {
        if keyboardButtons[event.keyCode] != nil || keyboardPads[event.keyCode] != nil { return true }
        if let button = Self.buttonKeyMap[event.keyCode] {
            keyboardButtons[event.keyCode] = button
            pressedButtons.insert(button)
            runtime.setMaschineButton(button, pressed: true)
            needsDisplay = true
            return true
        }
        if let pad = Self.padKeyMap[event.keyCode] {
            keyboardPads[event.keyCode] = pad
            heldPads.insert(pad)
            runtime.touchMaschinePad(physicalPad: pad, pressure: 420)
            runtime.strikeMaschinePad(physicalPad: pad, velocity: 3000)
            needsDisplay = true
            return true
        }
        return false
    }

    func handleKeyUp(_ event: NSEvent) -> Bool {
        if let button = keyboardButtons.removeValue(forKey: event.keyCode) {
            pressedButtons.remove(button)
            runtime.setMaschineButton(button, pressed: false)
            needsDisplay = true
            return true
        }
        if let pad = keyboardPads.removeValue(forKey: event.keyCode) {
            heldPads.remove(pad)
            runtime.releaseMaschinePad(physicalPad: pad)
            needsDisplay = true
            return true
        }
        return false
    }

    func handleFlagsChanged(_ event: NSEvent) -> Bool {
        let shiftKeyCode: UInt16 = 56
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let pressed = flags.contains(.shift)
        let nextCommandRotationMode = flags.contains(.command)
        if commandRotationMode != nextCommandRotationMode {
            commandRotationMode = nextCommandRotationMode
            needsDisplay = true
        }
        if pressed, keyboardButtons[shiftKeyCode] == nil {
            keyboardButtons[shiftKeyCode] = .shift
            pressedButtons.insert(.shift)
            runtime.setMaschineButton(.shift, pressed: true)
        } else if !pressed, keyboardButtons.removeValue(forKey: shiftKeyCode) != nil {
            pressedButtons.remove(.shift)
            runtime.setMaschineButton(.shift, pressed: false)
        }
        needsDisplay = true
        return true
    }

    func releaseKeyboardInputs() {
        for button in keyboardButtons.values { runtime.setMaschineButton(button, pressed: false) }
        for pad in keyboardPads.values { runtime.releaseMaschinePad(physicalPad: pad) }
        keyboardButtons.removeAll(); keyboardPads.removeAll()
        pressedButtons.removeAll(); heldPads.removeAll()
        commandRotationMode = false
        runtime.releaseAllMaschineInputs()
        needsDisplay = true
    }

    override func accessibilityChildren() -> [Any]? {
        var children: [SimulatorAccessibilityControl] = []
        for descriptor in geometry.buttons {
            children.append(accessibilityControl(
                role: .button,
                label: descriptor.secondaryLabel.map { "\(descriptor.label), \($0)" } ?? descriptor.label,
                controlRect: rect(descriptor.rect),
                press: { [weak self] in
                    self?.runtime.setMaschineButton(descriptor.button, pressed: true)
                    self?.runtime.setMaschineButton(descriptor.button, pressed: false)
                }
            ))
        }
        for (index, descriptor) in geometry.pads.enumerated() {
            let pad = index + 1
            let shiftLabel = geometry.padShiftLabels[index]
            children.append(accessibilityControl(
                role: .button,
                label: "Pad \(pad), Shift \(shiftLabel)",
                controlRect: rect(descriptor),
                press: { [weak self] in
                    self?.runtime.strikeMaschinePad(physicalPad: pad, velocity: 3000)
                    self?.runtime.releaseMaschinePad(physicalPad: pad)
                }
            ))
        }
        let encoders = [geometry.mainEncoder] + geometry.displayEncoders
        for (index, descriptor) in encoders.enumerated() {
            let label = index == 0 ? "Main encoder" : "Display encoder \(index)"
            children.append(accessibilityControl(
                role: .incrementor,
                label: label,
                controlRect: rect(descriptor),
                increment: { [weak self] in self?.runtime.turnMaschineEncoder(index, delta: 1) },
                decrement: { [weak self] in self?.runtime.turnMaschineEncoder(index, delta: -1) }
            ))
        }
        children.append(accessibilityControl(
            role: .slider,
            label: "Touch strip",
            controlRect: rect(geometry.touchStrip),
            increment: { [weak self] in self?.runtime.setMaschineTouchStrip(finger: 1, position: 768) },
            decrement: { [weak self] in self?.runtime.setMaschineTouchStrip(finger: 1, position: 256) }
        ))
        for (index, descriptor) in geometry.displays.enumerated() {
            children.append(accessibilityControl(
                role: .image,
                label: "Display \(index + 1)",
                controlRect: rect(descriptor)
            ))
        }
        return children
    }

    private func accessibilityControl(
        role: NSAccessibility.Role,
        label: String,
        controlRect: NSRect,
        press: (() -> Void)? = nil,
        increment: (() -> Void)? = nil,
        decrement: (() -> Void)? = nil
    ) -> SimulatorAccessibilityControl {
        let element = SimulatorAccessibilityControl()
        element.setAccessibilityRole(role)
        element.setAccessibilityLabel(label)
        element.setAccessibilityParent(self)
        let windowRect = convert(controlRect, to: nil)
        element.setAccessibilityFrame(window?.convertToScreen(windowRect) ?? windowRect)
        element.pressHandler = press
        element.incrementHandler = increment
        element.decrementHandler = decrement
        return element
    }

    private static let functionKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100]
    private static let buttonKeyMap: [UInt16: MaschineMK3Button] = {
        var result = Dictionary(uniqueKeysWithValues: zip(functionKeyCodes, [
            MaschineMK3Button.displayButton1, .displayButton2, .displayButton3, .displayButton4,
            .displayButton5, .displayButton6, .displayButton7, .displayButton8,
        ]))
        result[123] = .mainEncoderLeft; result[124] = .mainEncoderRight
        result[125] = .mainEncoderDown; result[126] = .mainEncoderUp
        result[36] = .mainEncoderPress
        result[49] = .play; result[53] = .stop
        result[35] = .padMode; result[40] = .keyboard; result[4] = .chords; result[17] = .step
        return result
    }()

    private static let padKeyMap: [UInt16: Int] = [
        18: 13, 19: 14, 20: 15, 21: 16,
        12: 9, 13: 10, 14: 11, 15: 12,
        0: 5, 1: 6, 2: 7, 3: 8,
        6: 1, 7: 2, 8: 3, 9: 4,
    ]

    static let keyboardCheatSheetText = """
    MASCHINE MK3 Simulator Keys

    Pads (same 4 × 4 shape)
      1 2 3 4              Pads 13…16
      Q W E R              Pads 9…12
      A S D F              Pads 5…8
      Z X C V              Pads 1…4

    Display and Main Encoder
      F1 … F8              Display buttons 1…8
      Arrow keys           Push main encoder directions
      Return               Press main encoder
      Click main encoder   Push center or a direction
      Command-drag/scroll  Rotate main encoder
      Drag display knob    Rotate display encoder
      Command-click knob   Encoder touch only

    Modes and Transport
      P / K / H / T        Pad Mode / Keyboard / Chords / Step
      Space / Escape       Play / Stop
      Shift                SHIFT

    Touch Strip and Pads
      Option-drag strip    Second finger
      Pad vertical click   Strike velocity
      Drag held pad        Pressure
    """

    // MARK: Helpers

    private static let mainEncoderButtons: Set<MaschineMK3Button> = [
        .mainEncoderPress, .mainEncoderUp, .mainEncoderRight, .mainEncoderDown, .mainEncoderLeft,
    ]
    private static let groupButtons: Set<MaschineMK3Button> = [
        .groupA, .groupB, .groupC, .groupD, .groupE, .groupF, .groupG, .groupH,
    ]
    private static let combinedAndPadStyleButtons = mainEncoderButtons.union(groupButtons)

    private var isMainEncoderRotating: Bool {
        if case .encoder(index: 0, touchOnly: false) = activeControl { return true }
        return false
    }

    private static func button(for zone: CombinedClickRotaryEncoder.PushZone) -> MaschineMK3Button {
        switch zone {
            case .center: return .mainEncoderPress
            case .up: return .mainEncoderUp
            case .right: return .mainEncoderRight
            case .down: return .mainEncoderDown
            case .left: return .mainEncoderLeft
        }
    }

    private static func pushZone(
        for button: MaschineMK3Button
    ) -> CombinedClickRotaryEncoder.PushZone? {
        switch button {
            case .mainEncoderPress: return .center
            case .mainEncoderUp: return .up
            case .mainEncoderRight: return .right
            case .mainEncoderDown: return .down
            case .mainEncoderLeft: return .left
            default: return nil
        }
    }

    private func rect(_ value: SimulatorRect) -> NSRect {
        NSRect(x: value.x, y: value.y, width: value.width, height: value.height)
    }

    private static func lampColor(raw: UInt8, colorEncoded: Bool) -> NSColor {
        guard raw != 0 else { return .clear }
        if !colorEncoded {
            let level: CGFloat = switch raw & 0x07 {
                case 4: 0.46
                case 5: 0.28
                case 6: 0.72
                case 7: 1
                default: CGFloat(raw) / 255
            }
            return NSColor(calibratedWhite: level, alpha: 1)
        }
        if raw == 0xff || raw == MaschineMK3Protocol.alternateWhiteColorLEDValue {
            return .white
        }
        let hueCode = Int(raw >> 2)
        let brightness = max(1, Int(raw & 0x03))
        let zeroBasedHue = (hueCode - 1 + 16) % 16
        return NSColor(calibratedHue: CGFloat(zeroBasedHue) / 16,
                       saturation: 0.82, brightness: 0.35 + CGFloat(brightness) * 0.2, alpha: 1)
    }

    private static func buttonFillColor(
        raw: UInt8,
        lamp: NSColor,
        pressed: Bool,
        colorEncoded: Bool
    ) -> NSColor {
        if colorEncoded, raw != 0 { return lamp }
        return pressed ? NSColor(calibratedWhite: 0.08, alpha: 1) : .black
    }

    private static func buttonLabelColor(
        raw: UInt8,
        lamp: NSColor,
        pressed: Bool,
        colorEncoded: Bool
    ) -> NSColor {
        if pressed { return .white }
        guard raw != 0 else { return NSColor(calibratedWhite: 0.22, alpha: 1) }
        return colorEncoded ? NSColor.black.withAlphaComponent(0.8) : lamp
    }

    private static func makeImage(snapshot: SimulatorFramebufferSnapshot) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: snapshot.width * snapshot.height * 4)
        for index in 0..<(snapshot.width * snapshot.height) {
            let value = UInt16(snapshot.pixelsBE[index * 2]) << 8 | UInt16(snapshot.pixelsBE[index * 2 + 1])
            rgba[index * 4] = UInt8(((value >> 11) & 0x1f) * 255 / 31)
            rgba[index * 4 + 1] = UInt8(((value >> 5) & 0x3f) * 255 / 63)
            rgba[index * 4 + 2] = UInt8((value & 0x1f) * 255 / 31)
            rgba[index * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: snapshot.width, height: snapshot.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: snapshot.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

private final class SimulatorAccessibilityControl: NSAccessibilityElement {
    var pressHandler: (() -> Void)?
    var incrementHandler: (() -> Void)?
    var decrementHandler: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let pressHandler else { return false }
        pressHandler()
        return true
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard let incrementHandler else { return false }
        incrementHandler()
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard let decrementHandler else { return false }
        decrementHandler()
        return true
    }
}
