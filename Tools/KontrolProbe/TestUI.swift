import AppKit
import Foundation
import KompleteKontrol

enum KontrolProbeTestUI {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = TestUIDelegate()
        app.delegate = delegate
        app.run()
        exit(0)
    }
}

private final class TestUIDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let controller = KKTestUIController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = KKTestSurfaceView(controller: controller)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1420, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "KontrolProbe S25 Test UI"
        window.minSize = NSSize(width: 980, height: 580)
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        controller.attach(view: view)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private final class KKTestUIController: @unchecked Sendable {
    private static let glyphDisplayIndex = KKDisplayFrame.displayCount - 1
    private static let glyphEncoderIndex = 8
    private static let visibleGlyphCount = KKDisplayFrame.characterCount

    private struct EncoderDemoRange {
        let label: String
        let min: Double
        let max: Double
        let slowStep: Double
        let mediumStep: Double
        let fastStep: Double

        var span: Double { max - min }
    }

    private let device = KompleteKontrolS25MK1()
    private weak var view: KKTestSurfaceView?
    private var keyColors = [Int: KKRGB]()
    private var buttonValues = [String: UInt8]()
    private var displayValues = [Bool](repeating: false, count: 9)
    private var encoderValues: [Double]
    private var lastEncoderTurnAt = [Date?](repeating: nil, count: 8)
    private var lastEncoderDirection = [Int](repeating: 0, count: 8)
    private var velocityFactorIndex = 3
    private var displayRefreshScheduled = false
    private var displayRefreshGeneration = 0
    private var glyphSelectionIndex = 0
    private var buttonInputToLED: [String: String] = [:]
    private let traceEnabled = ProcessInfo.processInfo.environment["LOGLEVEL"]?.uppercased() == "TRACE"
    private let lightGuideBaseNote: UInt8 = 48
    private let manualDisplayLabels = ["SID", "TEXT", "BAR", "BOX", "DRAW", "NOTE", "MOD", "PITCH", "GLYPH"]
    private let velocityFactors = [0.05, 0.10, 0.15, 0.20, 0.30, 0.45, 0.65, 0.90, 1.20]
    private let encoderRanges = [
        EncoderDemoRange(label: "0-15", min: 0, max: 15, slowStep: 0.10, mediumStep: 0.25, fastStep: 0.70),
        EncoderDemoRange(label: "0-127", min: 0, max: 127, slowStep: 0.20, mediumStep: 0.65, fastStep: 2.40),
        EncoderDemoRange(label: "0-8192", min: 0, max: 8192, slowStep: 6, mediumStep: 22, fastStep: 96),
        EncoderDemoRange(label: "0-4095", min: 0, max: 4095, slowStep: 3, mediumStep: 12, fastStep: 56),
        EncoderDemoRange(label: "0-255", min: 0, max: 255, slowStep: 0.35, mediumStep: 1.0, fastStep: 4.0),
        EncoderDemoRange(label: "0-100", min: 0, max: 100, slowStep: 0.20, mediumStep: 0.65, fastStep: 2.20),
        EncoderDemoRange(label: "0-1023", min: 0, max: 1023, slowStep: 0.90, mediumStep: 3.0, fastStep: 14),
        EncoderDemoRange(label: "-64+63", min: -64, max: 63, slowStep: 0.20, mediumStep: 0.65, fastStep: 2.40),
    ]

    var status = "Starting..."
    var lastEvent = "No input yet"
    var demoModeEnabled = false

    init() {
        encoderValues = encoderRanges.map { ($0.min + $0.max) / 2.0 }
    }

    func attach(view: KKTestSurfaceView) {
        self.view = view
        buttonInputToLED = Dictionary(uniqueKeysWithValues: KKTestSurfaceView.buttonElements.map { ($0.inputName, $0.ledName) })
        device.monitorMode = .changed
        device.log = { [weak self] message in
            DispatchQueue.main.async { [weak self] in
                self?.trace("device \(message)")
                self?.status = message
                self?.view?.needsDisplay = true
            }
        }
        device.onInputReport = { [weak self] report in
            DispatchQueue.main.async { [weak self] in
                self?.handle(report: report)
            }
        }
        device.onMIDIEvent = { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                self?.handle(midi: event)
            }
        }

        status = "Daemon transport"
        trace("starting daemon transport input")
        device.startInputMonitoring()
        device.handshakeAsync()
        enableDemoMode()
        trace("handshake queued")
        view.needsDisplay = true
    }

    func toggleDemoMode() {
        demoModeEnabled.toggle()
        if demoModeEnabled {
            resetDemoState()
        } else {
            device.clearDisplaysAsync()
        }
        status = demoModeEnabled ? "Demo mode: buttons, encoders and LCD text" : "Manual test mode"
        trace("demo mode \(demoModeEnabled ? "on" : "off")")
        view?.needsDisplay = true
    }

    private func enableDemoMode() {
        demoModeEnabled = true
        resetDemoState()
        status = "Demo mode: encoder 8 \(glyphSelectionLabel)"
    }

    private func resetDemoState() {
        displayValues = [Bool](repeating: false, count: displayValues.count)
        encoderValues = encoderRanges.map { ($0.min + $0.max) / 2.0 }
        lastEncoderTurnAt = [Date?](repeating: nil, count: encoderRanges.count)
        lastEncoderDirection = [Int](repeating: 0, count: encoderRanges.count)
        velocityFactorIndex = 3
        glyphSelectionIndex = 0
        sendDemoDisplayFrame()
    }

    func toggleKey(_ index: Int) {
        let palette = [
            KKRGB.off,
            KKRGB(red: 0x7f, green: 0x00, blue: 0x00),
            KKRGB(red: 0x00, green: 0x7f, blue: 0x00),
            KKRGB(red: 0x00, green: 0x20, blue: 0x7f),
            KKRGB(red: 0x7f, green: 0x60, blue: 0x00),
            KKRGB(red: 0x7f, green: 0x00, blue: 0x7f),
            KKRGB(red: 0x60, green: 0x60, blue: 0x60),
        ]
        let current = keyColors[index] ?? .off
        let nextIndex = ((palette.firstIndex(of: current) ?? 0) + 1) % palette.count
        let next = palette[nextIndex]
        keyColors[index] = next
        _ = device.setKey(index, color: next, flush: false)
        device.sendGuideAsync()
        status = "key \(index) queued"
        trace("output key \(index) rgb=\(next.red),\(next.green),\(next.blue) queued")
        view?.needsDisplay = true
    }

    func toggleButtonLED(_ name: String) {
        let current = buttonValues[name] ?? 0
        let next: UInt8 = current == 0 ? 0x7f : 0
        buttonValues[name] = next
        _ = device.setButtonLED(name: name, value: next, flush: false)
        device.sendButtonLEDsAsync()
        status = "button \(name) LED \(next == 0 ? "off" : "on") queued"
        trace("output button \(name) value=0x\(String(format: "%02x", next)) queued")
        view?.needsDisplay = true
    }

    func toggleDisplayTest(index: Int) {
        guard displayValues.indices.contains(index) else { return }
        guard !demoModeEnabled else {
            var statusMessage: String
            var sendImmediately = false
            if index == 0 {
                velocityFactorIndex = min(velocityFactors.count - 1, velocityFactorIndex + 1)
                statusMessage = "velocity x\(velocityFactorLabel)"
            } else if index == Self.glyphDisplayIndex {
                advanceGlyphSelection(by: 1)
                statusMessage = glyphSelectionLabel
                sendImmediately = true
            } else if encoderValues.indices.contains(index - 1) {
                let range = encoderRanges[index - 1]
                encoderValues[index - 1] = encoderValues[index - 1] >= range.max ? range.min : range.max
                statusMessage = "display \(index) demo value"
            } else {
                statusMessage = "display \(index) demo"
            }
            if sendImmediately {
                sendDemoDisplayFrameImmediately()
            } else {
                scheduleDemoDisplayFrame()
            }
            status = statusMessage
            view?.pulse(id: "display:\(index)")
            view?.needsDisplay = true
            return
        }
        displayValues[index].toggle()
        if displayValues[index] {
            setManualDisplayContent(index)
        } else {
            clearDisplay(index)
        }
        device.sendDisplaysAsync()
        let state = displayValues[index] ? "on" : "off"
        status = "display \(index + 1) \(state) text queued"
        trace("output display \(index + 1) \(state) text queued")
        view?.pulse(id: "display:\(index)")
        view?.needsDisplay = true
    }

    func displayIsOn(_ index: Int) -> Bool {
        if demoModeEnabled, index == Self.glyphDisplayIndex {
            return true
        }
        if demoModeEnabled {
            return displayProgress(index) > 0
        }
        return displayValues.indices.contains(index) && displayValues[index]
    }

    func displayProgress(_ index: Int) -> Int {
        if demoModeEnabled, index == 0 {
            return pageProgress()
        }
        if demoModeEnabled, index == Self.glyphDisplayIndex {
            return glyphProgress()
        }
        let encoderIndex = demoModeEnabled ? index - 1 : index
        guard encoderValues.indices.contains(encoderIndex) else { return 0 }
        return Int((normalizedEncoderValue(encoderIndex) * 64.0).rounded())
    }

    private func setManualDisplayContent(_ index: Int) {
        clearDisplay(index)
        switch index {
            case 0:
                _ = device.setDisplayText("SID", display: index, row: 0, alignment: .center, flush: false)
                _ = device.setDisplayText("STUDIO", display: index, row: 1, alignment: .center, flush: false)
                _ = device.setDisplayText("READY", display: index, row: 2, alignment: .center, flush: false)
            case 1:
                _ = device.setDisplayText("TEXT", display: index, row: 0, alignment: .center, flush: false)
                _ = device.setDisplayText("ABC123", display: index, row: 1, alignment: .center, flush: false)
                _ = device.setDisplayText("=+-/*<>", display: index, row: 2, alignment: .center, flush: false)
            case 2:
                _ = device.setDisplayBar(0.75, display: index, row: 0, flush: false)
                _ = device.setDisplayText("BAR", display: index, row: 1, alignment: .center, flush: false)
                _ = device.setDisplayText("75 PCT", display: index, row: 2, alignment: .center, flush: false)
            case 3:
                _ = device.setDisplayBox(display: index, flush: false)
            case 4:
                _ = device.setDisplayText("+----+", display: index, row: 0, alignment: .center, flush: false)
                _ = device.setDisplayText("|DRAW|", display: index, row: 1, alignment: .center, flush: false)
                _ = device.setDisplayText("+----+", display: index, row: 2, alignment: .center, flush: false)
            default:
                let label = manualDisplayLabels.indices.contains(index) ? manualDisplayLabels[index] : "LCD"
                _ = device.setDisplayText(label, display: index, row: 0, alignment: .center, flush: false)
                _ = device.setDisplayText("CONFIG", display: index, row: 1, alignment: .center, flush: false)
                _ = device.setDisplayText("TEXT", display: index, row: 2, alignment: .center, flush: false)
        }
    }

    private func clearDisplay(_ index: Int) {
        for row in 0..<KKDisplayFrame.rowCount {
            _ = device.setDisplayText("", display: index, row: row, alignment: .left, flush: false)
        }
    }

    private func sendDemoDisplayFrame() {
        _ = device.clearDisplays(flush: false)
        _ = device.setDisplayBar(Double(pageProgress()) / 64.0, display: 0, row: 0, flush: false)
        _ = device.setDisplayText("VELOCITY", display: 0, row: 1, alignment: .center, flush: false)
        _ = device.setDisplayText("X\(velocityFactorLabel)", display: 0, row: 2, alignment: .center, flush: false)

        for index in encoderValues.indices {
            let display = index + 1
            if display == Self.glyphDisplayIndex {
                setGlyphTestDisplayFrame()
                continue
            }
            let range = encoderRanges[index]
            _ = device.setDisplayBar(normalizedEncoderValue(index), display: display, row: 0, flush: false)
            _ = device.setDisplayText(range.label, display: display, row: 1, alignment: .center, flush: false)
            _ = device.setDisplayText(displayValue(encoderValues[index]), display: display, row: 2, alignment: .center, flush: false)
        }
        device.sendDisplaysAsync()
    }

    private func setGlyphTestDisplayFrame() {
        let total = max(1, KKDisplayFrame.availableGlyphCount)
        _ = device.setDisplayBar(Double(glyphProgress()) / 64.0, display: Self.glyphDisplayIndex, row: 0, flush: false)
        for slot in 0..<Self.visibleGlyphCount {
            let glyphIndex = glyphSelectionIndex + slot
            let glyph = glyphIndex < total ? KKDisplayFrame.glyph(at: glyphIndex) ?? 0 : 0
            _ = device.setDisplayGlyph(glyph, display: Self.glyphDisplayIndex, row: 1, column: slot, flush: false)
        }
        _ = device.setDisplayText(glyphIndexDisplayValue, display: Self.glyphDisplayIndex, row: 2, alignment: .center, flush: false)
    }

    private func pageProgress() -> Int {
        normalizedVelocityFactorStep()
    }

    func colorForKey(_ index: Int) -> KKRGB {
        keyColors[index] ?? .off
    }

    func buttonLEDValue(_ name: String) -> UInt8 {
        buttonValues[name] ?? 0
    }

    private func handle(report: KKInputReport) {
        if report.events.isEmpty {
            lastEvent = KKInputReportDecoder.summary(reportID: report.reportID, bytes: report.bytes)
        } else {
            lastEvent = report.events.map(\.description).joined(separator: " | ")
        }
        trace("input report=0x\(String(format: "%02x", report.reportID)) bytes=\(KKInputReportDecoder.hexDump(report.bytes)) events=\(lastEvent)")
        for event in report.events {
            switch event {
                case let .button(name, pressed):
                    view?.setPulse(id: "button:\(name)", active: pressed)
                    if demoModeEnabled, pressed {
                        toggleDemoButton(named: name)
                    }
                case let .touchEncoder(index, touched):
                    view?.setPulse(id: "encoder:\(index)", active: touched)
                case .mainEncoderState, .mainEncoder:
                    view?.pulse(id: "main")
                case let .rotaryEncoder(index, delta, _):
                    view?.pulse(id: "encoder:\(index)")
                    if demoModeEnabled {
                        updateEncoderProgress(index: index, delta: delta)
                    }
                case let .touchStrip(name, _):
                    view?.pulse(id: "strip:\(name)")
            }
        }
        view?.needsDisplay = true
    }

    private func handle(midi event: KKMIDIEvent) {
        guard demoModeEnabled else { return }

        switch event.kind {
            case .noteOn where event.velocity > 0:
                guard let index = lightGuideIndex(for: event.note) else {
                    lastEvent = "MIDI ON \(event.note) outside S25 range"
                    view?.needsDisplay = true
                    return
                }
                let level = UInt8(max(0x18, min(0x7f, Int(event.velocity))))
                let color = KKRGB(red: level, green: UInt8(min(0x7f, Int(level) * 5 / 6)), blue: 0x00)
                keyColors[index] = color
                _ = device.setKey(index, color: color, flush: false)
                device.sendGuideAsync()
                lastEvent = "MIDI ON note \(event.note) key \(index)"
                status = "demo MIDI note \(event.note) -> key \(index)"
                view?.pulse(id: "key:\(index)")
            case .noteOn, .noteOff:
                guard let index = lightGuideIndex(for: event.note) else {
                    lastEvent = "MIDI OFF \(event.note) outside S25 range"
                    view?.needsDisplay = true
                    return
                }
                keyColors[index] = .off
                _ = device.setKey(index, color: .off, flush: false)
                device.sendGuideAsync()
                lastEvent = "MIDI OFF note \(event.note) key \(index)"
                status = "demo MIDI note \(event.note) -> key \(index)"
                view?.pulse(id: "key:\(index)")
            case .controlChange:
                if event.control == 1 {
                    lastEvent = "MIDI mod strip \(event.controlValue)"
                    status = "demo mod strip \(event.controlValue)/127"
                    view?.pulse(id: "strip:mod")
                } else {
                    lastEvent = "MIDI CC \(event.control) value \(event.controlValue)"
                }
            case .pitchBend:
                lastEvent = "MIDI pitch strip \(event.pitchBendCentered)"
                status = "demo pitch strip \(event.pitchBendCentered)"
                view?.pulse(id: "strip:pitch")
        }

        view?.needsDisplay = true
    }

    private func lightGuideIndex(for note: UInt8) -> Int? {
        guard note >= lightGuideBaseNote else { return nil }
        let index = Int(note - lightGuideBaseNote)
        guard index < KompleteKontrolS25MK1Protocol.keyCount else { return nil }
        return index
    }

    private func toggleDemoButton(named inputName: String) {
        guard let ledName = buttonInputToLED[inputName] else { return }
        if inputName == "page left" {
            velocityFactorIndex = max(0, velocityFactorIndex - 1)
            sendDemoDisplayFrame()
            status = "velocity x\(velocityFactorLabel)"
        } else if inputName == "page right" {
            velocityFactorIndex = min(velocityFactors.count - 1, velocityFactorIndex + 1)
            sendDemoDisplayFrame()
            status = "velocity x\(velocityFactorLabel)"
        }
        let current = buttonValues[ledName] ?? 0
        let next: UInt8 = current == 0 ? 0x7f : 0
        buttonValues[ledName] = next
        _ = device.setButtonLED(name: ledName, value: next, flush: false)
        device.sendButtonLEDsAsync()
        if inputName != "page left" && inputName != "page right" {
            status = "demo button \(inputName) \(next == 0 ? "off" : "on")"
        }
        trace("demo button \(inputName) led=\(ledName) value=0x\(String(format: "%02x", next))")
    }

    private func updateEncoderProgress(index: Int, delta: Int) {
        if index == Self.glyphEncoderIndex {
            updateGlyphSelection(delta: delta)
            return
        }
        let slot = index - 1
        guard encoderValues.indices.contains(slot) else { return }
        let range = encoderRanges[slot]
        let now = Date()
        let elapsed = lastEncoderTurnAt[slot].map { now.timeIntervalSince($0) } ?? 1.0
        lastEncoderTurnAt[slot] = now
        let step = adaptiveEncoderStep(delta: delta, elapsed: elapsed, range: range)
        encoderValues[slot] = min(range.max, max(range.min, encoderValues[slot] + step))
        let direction = delta < 0 ? -1 : 1
        if lastEncoderDirection[slot] != 0 && lastEncoderDirection[slot] != direction {
            sendDemoDisplayFrameImmediately()
        } else {
            scheduleDemoDisplayFrame()
        }
        lastEncoderDirection[slot] = direction
        status = "demo encoder \(index) \(range.label) \(displayValue(encoderValues[slot])) d=\(delta)"
        trace("demo encoder \(index) delta=\(delta) elapsed=\(String(format: "%.3f", elapsed)) step=\(step) value=\(encoderValues[slot])")
    }

    private func updateGlyphSelection(delta: Int) {
        guard delta != 0 else { return }
        advanceGlyphSelection(by: delta < 0 ? -1 : 1)
        sendDemoDisplayFrameImmediately()
        status = "\(glyphSelectionLabel) d=\(delta)"
        trace("demo glyph encoder \(Self.glyphEncoderIndex) delta=\(delta) index=\(glyphSelectionIndex)")
    }

    private func advanceGlyphSelection(by delta: Int) {
        glyphSelectionIndex = max(0, min(maxGlyphSelectionIndex, glyphSelectionIndex + delta))
    }

    private func scheduleDemoDisplayFrame() {
        guard !displayRefreshScheduled else { return }
        displayRefreshScheduled = true
        displayRefreshGeneration += 1
        let generation = displayRefreshGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.010) { [weak self] in
            guard let self else { return }
            guard generation == self.displayRefreshGeneration else { return }
            self.displayRefreshScheduled = false
            self.sendDemoDisplayFrame()
        }
    }

    private func sendDemoDisplayFrameImmediately() {
        displayRefreshGeneration += 1
        displayRefreshScheduled = false
        sendDemoDisplayFrame()
    }

    private func adaptiveEncoderStep(delta: Int, elapsed: TimeInterval, range: EncoderDemoRange) -> Double {
        let direction = delta < 0 ? -1.0 : 1.0
        let magnitude = 1.0 + log2(Double(abs(delta)))
        let perTick: Double
        if abs(delta) >= 5 || elapsed < 0.035 {
            perTick = range.fastStep
        } else if abs(delta) >= 2 || elapsed < 0.090 {
            perTick = range.mediumStep
        } else {
            perTick = range.slowStep
        }
        return direction * magnitude * perTick * velocityFactors[velocityFactorIndex]
    }

    private var velocityFactorLabel: String {
        String(format: "%.2f", velocityFactors[velocityFactorIndex])
    }

    private func normalizedVelocityFactorStep() -> Int {
        guard velocityFactors.count > 1 else { return 64 }
        return max(1, Int((Double(velocityFactorIndex) / Double(velocityFactors.count - 1) * 64.0).rounded()))
    }

    private func glyphProgress() -> Int {
        guard maxGlyphSelectionIndex > 0 else { return 64 }
        return max(1, Int((Double(glyphSelectionIndex) / Double(maxGlyphSelectionIndex) * 64.0).rounded()))
    }

    private var glyphSelectionLabel: String {
        "glyph 0x\(String(format: "%02X", glyphSelectionIndex)) \(glyphSelectionIndex + 1)/\(KKDisplayFrame.availableGlyphCount)"
    }

    private var glyphIndexDisplayValue: String {
        String(format: "%03d/%03d", glyphSelectionIndex, max(0, KKDisplayFrame.availableGlyphCount - 1))
    }

    private var maxGlyphSelectionIndex: Int {
        max(0, KKDisplayFrame.availableGlyphCount - Self.visibleGlyphCount)
    }

    private func normalizedEncoderValue(_ index: Int) -> Double {
        let range = encoderRanges[index]
        guard range.span > 0 else { return 0 }
        return (encoderValues[index] - range.min) / range.span
    }

    private func displayValue(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.01 {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", value)
    }

    private func trace(_ message: String) {
        guard traceEnabled else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[kk-ui] \(timestamp) \(message)")
        fflush(stdout)
    }
}

private final class KKTestSurfaceView: NSView {
    private let controller: KKTestUIController
    private var pulses: [String: Date] = [:]
    private var active: Set<String> = []

    init(controller: KKTestUIController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setPulse(id: String, active: Bool) {
        if active {
            self.active.insert(id)
            pulses[id] = Date()
        } else {
            self.active.remove(id)
            pulses[id] = Date()
        }
        needsDisplay = true
    }

    func pulse(id: String) {
        pulses[id] = Date()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if demoToggleRect(in: bounds).contains(point) {
            controller.toggleDemoMode()
            return
        }
        let surfaceRect = fittedSurfaceRect()
        for index in 0..<Self.displaySlots.count where rect(Self.displaySlots[index], in: surfaceRect).contains(point) {
            controller.toggleDisplayTest(index: index)
            return
        }
        for element in Self.buttonElements where rect(element.rect, in: surfaceRect).contains(point) {
            controller.toggleButtonLED(element.ledName)
            return
        }
        for index in 0..<KompleteKontrolS25MK1Protocol.keyCount {
            if rect(Self.keyLightRect(index), in: surfaceRect).contains(point) {
                controller.toggleKey(index)
                return
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        let surfaceRect = fittedSurfaceRect()
        drawSurface(in: surfaceRect)
        drawKeyOverlays(in: surfaceRect)
        drawButtonOverlays(in: surfaceRect)
        drawEncoderOverlays(in: surfaceRect)
        drawStatus(in: bounds)
    }

    private func fittedSurfaceRect() -> NSRect {
        let insetBounds = NSRect(x: 12, y: 42, width: max(10, bounds.width - 24), height: max(10, bounds.height - 84))
        let aspect = Self.designSize.width / Self.designSize.height
        let size: NSSize
        if insetBounds.width / insetBounds.height > aspect {
            size = NSSize(width: insetBounds.height * aspect, height: insetBounds.height)
        } else {
            size = NSSize(width: insetBounds.width, height: insetBounds.width / aspect)
        }
        return NSRect(
            x: insetBounds.midX - size.width / 2,
            y: insetBounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func drawSurface(in surfaceRect: NSRect) {
        NSColor(calibratedWhite: 0.055, alpha: 1).setFill()
        rounded(surfaceRect, radius: 12).fill()

        NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
        rounded(rect(NSRect(x: 14, y: 18, width: 972, height: 88), in: surfaceRect), radius: 10).fill()

        let panel = rect(NSRect(x: 18, y: 28, width: 964, height: 190), in: surfaceRect)
        NSColor(calibratedWhite: 0.035, alpha: 1).setFill()
        rounded(panel, radius: 8).fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        rounded(panel, radius: 8).stroke()

        let leftCheek = rect(NSRect(x: 18, y: 218, width: 238, height: 184), in: surfaceRect)
        let keybed = rect(NSRect(x: 260, y: 218, width: 642, height: 184), in: surfaceRect)
        let rightCheek = rect(NSRect(x: 902, y: 218, width: 80, height: 184), in: surfaceRect)
        NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
        rounded(leftCheek, radius: 5).fill()
        rounded(rightCheek, radius: 5).fill()

        drawTouchStrips(in: leftCheek)
        drawKeyboard(in: keybed)
        drawPanelLabels(in: surfaceRect)
        drawDisplaySlots(in: surfaceRect)
    }

    private func drawTouchStrips(in rect: NSRect) {
        let stripWidth = rect.width * 0.18
        let strips: [(offset: CGFloat, id: String, label: String)] = [
            (0.34, "strip:pitch", "PITCH"),
            (0.66, "strip:mod", "MOD"),
        ]
        for stripInfo in strips {
            let strip = NSRect(
                x: rect.minX + rect.width * stripInfo.offset - stripWidth / 2,
                y: rect.minY + rect.height * 0.12,
                width: stripWidth,
                height: rect.height * 0.60
            )
            let highlighted = isFresh(stripInfo.id)
            NSColor(calibratedWhite: 0.02, alpha: 1).setFill()
            rounded(strip, radius: 4).fill()
            if highlighted {
                NSColor.systemCyan.withAlphaComponent(0.58).setFill()
                rounded(strip.insetBy(dx: 4, dy: 4), radius: 3).fill()
            }
            NSColor.systemTeal.withAlphaComponent(highlighted ? 0.95 : 0.35).setStroke()
            rounded(strip.insetBy(dx: 3, dy: 3), radius: 3).stroke()
            drawString(stripInfo.label, in: NSRect(x: strip.minX - 8, y: strip.maxY + 4, width: strip.width + 16, height: 14), size: 8, color: highlighted ? .labelColor : .secondaryLabelColor)
        }
    }

    private func drawKeyboard(in keybed: NSRect) {
        NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
        rounded(keybed, radius: 6).fill()

        let whiteCount = 15
        let whiteWidth = keybed.width / CGFloat(whiteCount)
        for index in 0..<whiteCount {
            let key = NSRect(
                x: keybed.minX + CGFloat(index) * whiteWidth + 1,
                y: keybed.minY + 3,
                width: whiteWidth - 2,
                height: keybed.height - 6
            )
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
            rounded(key, radius: 3).fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            rounded(key, radius: 3).stroke()
        }

        let blackWidth = whiteWidth * 0.58
        for boundary in Self.blackKeyBoundaries {
            let key = NSRect(
                x: keybed.minX + boundary * whiteWidth - blackWidth / 2,
                y: keybed.minY + keybed.height * 0.40,
                width: blackWidth,
                height: keybed.height * 0.60
            )
            NSColor(calibratedWhite: 0.02, alpha: 1).setFill()
            rounded(key, radius: 4).fill()
            NSColor.white.withAlphaComponent(0.18).setStroke()
            rounded(key, radius: 4).stroke()
        }
    }

    private func drawPanelLabels(in surfaceRect: NSRect) {
        drawString("KOMPLETE KONTROL S25", in: rect(NSRect(x: 36, y: 40, width: 210, height: 20), in: surfaceRect), size: 15, color: .white)
        drawString("PERFORM", in: rect(NSRect(x: 54, y: 70, width: 80, height: 14), in: surfaceRect), size: 9, color: .secondaryLabelColor)
        drawString("TRANSPORT", in: rect(NSRect(x: 54, y: 138, width: 92, height: 14), in: surfaceRect), size: 9, color: .secondaryLabelColor)
        drawString("NAVIGATE", in: rect(NSRect(x: 820, y: 56, width: 90, height: 14), in: surfaceRect), size: 9, color: .secondaryLabelColor)
        drawString("TRANSPOSE", in: rect(NSRect(x: 84, y: 222, width: 100, height: 14), in: surfaceRect), size: 9, color: .secondaryLabelColor)
    }

    private func drawDisplaySlots(in surfaceRect: NSRect) {
        for index in 0..<Self.displaySlots.count {
            let slot = rect(Self.displaySlots[index], in: surfaceRect)
            let highlighted = isFresh("display:\(index)")
            let isOn = controller.displayIsOn(index)
            (isOn ? NSColor.systemYellow.withAlphaComponent(0.35) : NSColor(calibratedWhite: 0.01, alpha: 1)).setFill()
            rounded(slot, radius: 3).fill()
            let progress = controller.displayProgress(index)
            if controller.demoModeEnabled, progress > 0 {
                let fillWidth = slot.width * CGFloat(progress) / 64.0
                let fill = NSRect(x: slot.minX, y: slot.minY, width: fillWidth, height: slot.height)
                NSColor.systemYellow.withAlphaComponent(0.62).setFill()
                rounded(fill, radius: 3).fill()
            }
            if highlighted {
                NSColor.systemYellow.withAlphaComponent(0.45).setFill()
                rounded(slot, radius: 3).fill()
            }
            NSColor.systemCyan.withAlphaComponent(highlighted ? 0.85 : 0.30).setStroke()
            rounded(slot, radius: 3).stroke()
        }
    }

    private func drawKeyOverlays(in imageRect: NSRect) {
        for index in 0..<KompleteKontrolS25MK1Protocol.keyCount {
            let keyRect = rect(Self.keyLightRect(index), in: imageRect)
            let color = controller.colorForKey(index)
            let highlighted = isFresh("key:\(index)")
            if color != .off {
                nsColor(color, alpha: 0.72).setFill()
                rounded(keyRect, radius: 2).fill()
            } else if highlighted {
                NSColor.systemYellow.withAlphaComponent(0.45).setFill()
                rounded(keyRect, radius: 2).fill()
            }
            NSColor(calibratedWhite: 1, alpha: highlighted ? 0.85 : 0.20).setStroke()
            rounded(keyRect, radius: 2).stroke()
        }
    }

    private func drawButtonOverlays(in imageRect: NSRect) {
        for element in Self.buttonElements {
            let r = rect(element.rect, in: imageRect)
            let lit = controller.buttonLEDValue(element.ledName) != 0
            let inputActive = isActive("button:\(element.inputName)") || isFresh("button:\(element.inputName)")
            let color: NSColor
            if inputActive {
                color = NSColor.systemCyan.withAlphaComponent(0.70)
            } else if lit {
                color = NSColor.systemGreen.withAlphaComponent(0.55)
            } else {
                color = NSColor.white.withAlphaComponent(0.12)
            }
            color.setFill()
            rounded(r, radius: 5).fill()
            NSColor.white.withAlphaComponent(inputActive ? 0.90 : 0.28).setStroke()
            rounded(r, radius: 5).stroke()
        }
    }

    private func drawEncoderOverlays(in imageRect: NSRect) {
        for index in 1...8 {
            let center = point(Self.encoderCenters[index - 1], in: imageRect)
            drawCircle(center: center, radius: imageRect.width * 0.015, id: "encoder:\(index)")
        }
        drawCircle(center: point(Self.mainEncoderCenter, in: imageRect), radius: imageRect.width * 0.022, id: "main")
    }

    private func drawCircle(center: NSPoint, radius: CGFloat, id: String) {
        let r = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let highlighted = isActive(id) || isFresh(id)
        (highlighted ? NSColor.systemCyan.withAlphaComponent(0.65) : NSColor.white.withAlphaComponent(0.10)).setFill()
        NSBezierPath(ovalIn: r).fill()
        NSColor.white.withAlphaComponent(highlighted ? 0.90 : 0.25).setStroke()
        NSBezierPath(ovalIn: r).stroke()
    }

    private func drawStatus(in bounds: NSRect) {
        let status = "Status: \(controller.status)"
        drawString(status, in: NSRect(x: 18, y: bounds.height - 38, width: max(100, bounds.width - 220), height: 24), size: 14, color: .labelColor)
        drawDemoToggle(in: demoToggleRect(in: bounds))
        drawString("Input: \(controller.lastEvent)", in: NSRect(x: 18, y: 16, width: bounds.width - 36, height: 26), size: 13, color: .secondaryLabelColor)
    }

    private func drawDemoToggle(in rect: NSRect) {
        let enabled = controller.demoModeEnabled
        (enabled ? NSColor.systemGreen.withAlphaComponent(0.28) : NSColor.white.withAlphaComponent(0.12)).setFill()
        rounded(rect, radius: 6).fill()
        (enabled ? NSColor.systemGreen.withAlphaComponent(0.85) : NSColor.white.withAlphaComponent(0.28)).setStroke()
        rounded(rect, radius: 6).stroke()
        drawString(enabled ? "Demo On" : "Demo Off", in: rect.insetBy(dx: 12, dy: 4), size: 13, color: enabled ? .labelColor : .secondaryLabelColor)
    }

    private func demoToggleRect(in bounds: NSRect) -> NSRect {
        NSRect(x: max(18, bounds.width - 156), y: bounds.height - 40, width: 138, height: 28)
    }

    private func isActive(_ id: String) -> Bool {
        active.contains(id)
    }

    private func isFresh(_ id: String) -> Bool {
        guard let date = pulses[id] else { return false }
        let fresh = Date().timeIntervalSince(date) < 0.22
        if fresh {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
                self?.needsDisplay = true
            }
        }
        return fresh
    }

    private func rect(_ normalized: NSRect, in imageRect: NSRect) -> NSRect {
        let x = normalized.minX / Self.designSize.width
        let y = normalized.minY / Self.designSize.height
        let width = normalized.width / Self.designSize.width
        let height = normalized.height / Self.designSize.height
        return NSRect(
            x: imageRect.minX + x * imageRect.width,
            y: imageRect.minY + (1 - y - height) * imageRect.height,
            width: width * imageRect.width,
            height: height * imageRect.height
        )
    }

    private func point(_ normalized: NSPoint, in imageRect: NSRect) -> NSPoint {
        let x = normalized.x / Self.designSize.width
        let y = normalized.y / Self.designSize.height
        return NSPoint(
            x: imageRect.minX + x * imageRect.width,
            y: imageRect.minY + (1 - y) * imageRect.height
        )
    }

    private func rounded(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    private func nsColor(_ color: KKRGB, alpha: CGFloat) -> NSColor {
        NSColor(
            calibratedRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: alpha
        )
    }

    private func drawString(_ text: String, in rect: NSRect, size: CGFloat, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
        ]
        NSString(string: text).draw(in: rect, withAttributes: attributes)
    }

    // Keybed geometry in design coordinates; the light guide and click targets
    // derive from the same layout as the drawn keys so they stay aligned.
    private static let keybedDesign = NSRect(x: 260, y: 218, width: 642, height: 184)
    private static let whiteKeyCount = 15

    // White-key boundary index (0-based) that each black key is centred on.
    private static let blackKeyBoundaries: [CGFloat] = [1, 2, 4, 5, 6, 8, 9, 11, 12, 13]

    // Per-key light position (design x, isBlack) for all 25 keys, C to C.
    private static let keyLightLayout: [(x: CGFloat, black: Bool)] = {
        let whiteWidth = keybedDesign.width / CGFloat(whiteKeyCount)
        let blackSemitones: Set<Int> = [1, 3, 6, 8, 10]
        var layout: [(CGFloat, Bool)] = []
        var white = 0
        for index in 0..<KompleteKontrolS25MK1Protocol.keyCount {
            if blackSemitones.contains(index % 12) {
                layout.append((keybedDesign.minX + CGFloat(white) * whiteWidth, true))
            } else {
                layout.append((keybedDesign.minX + (CGFloat(white) + 0.5) * whiteWidth, false))
                white += 1
            }
        }
        return layout
    }()

    private static func keyLightRect(_ index: Int) -> NSRect {
        guard keyLightLayout.indices.contains(index) else { return .zero }
        let whiteWidth = keybedDesign.width / CGFloat(whiteKeyCount)
        let position = keyLightLayout[index]
        let width = whiteWidth * (position.black ? 0.42 : 0.62)
        return NSRect(x: position.x - width / 2, y: 206, width: width, height: 10)
    }

    private static let designSize = NSSize(width: 1000, height: 420)

    private static let encoderCenters: [NSPoint] = [
        NSPoint(x: 330, y: 96), NSPoint(x: 388, y: 96),
        NSPoint(x: 446, y: 96), NSPoint(x: 504, y: 96),
        NSPoint(x: 562, y: 96), NSPoint(x: 620, y: 96),
        NSPoint(x: 678, y: 96), NSPoint(x: 736, y: 96),
    ]

    private static let mainEncoderCenter = NSPoint(x: 902, y: 100)

    private static let displaySlots = (0..<9).map {
        NSRect(x: 249 + CGFloat($0) * 58, y: 150, width: 46, height: 24)
    }

    fileprivate struct ButtonElement {
        let inputName: String
        let ledName: String
        let rect: NSRect
    }

    fileprivate static let buttonElements: [ButtonElement] = [
        ButtonElement(inputName: "shift", ledName: "shift", rect: NSRect(x: 54, y: 85, width: 48, height: 24)),
        ButtonElement(inputName: "scale", ledName: "scale", rect: NSRect(x: 118, y: 85, width: 48, height: 24)),
        ButtonElement(inputName: "arp", ledName: "arp", rect: NSRect(x: 173, y: 85, width: 48, height: 24)),
        ButtonElement(inputName: "loop", ledName: "loop", rect: NSRect(x: 54, y: 152, width: 48, height: 24)),
        ButtonElement(inputName: "rewind", ledName: "rwd", rect: NSRect(x: 118, y: 152, width: 48, height: 24)),
        ButtonElement(inputName: "fast forward", ledName: "ffw", rect: NSRect(x: 173, y: 152, width: 48, height: 24)),
        ButtonElement(inputName: "play", ledName: "play", rect: NSRect(x: 54, y: 184, width: 48, height: 28)),
        ButtonElement(inputName: "rec", ledName: "rec", rect: NSRect(x: 118, y: 184, width: 48, height: 28)),
        ButtonElement(inputName: "stop", ledName: "stop", rect: NSRect(x: 173, y: 184, width: 48, height: 28)),
        ButtonElement(inputName: "page left", ledName: "pageleft", rect: NSRect(x: 241, y: 88, width: 22, height: 24)),
        ButtonElement(inputName: "page right", ledName: "pageright", rect: NSRect(x: 269, y: 88, width: 22, height: 24)),
        ButtonElement(inputName: "browse", ledName: "browse", rect: NSRect(x: 820, y: 71, width: 50, height: 22)),
        ButtonElement(inputName: "instance", ledName: "instance", rect: NSRect(x: 820, y: 109, width: 50, height: 22)),
        ButtonElement(inputName: "back", ledName: "back", rect: NSRect(x: 820, y: 147, width: 50, height: 22)),
        ButtonElement(inputName: "preset up", ledName: "presetup", rect: NSRect(x: 936, y: 72, width: 42, height: 20)),
        ButtonElement(inputName: "preset down", ledName: "presetdown", rect: NSRect(x: 936, y: 110, width: 42, height: 20)),
        ButtonElement(inputName: "enter", ledName: "enter", rect: NSRect(x: 936, y: 147, width: 42, height: 22)),
        ButtonElement(inputName: "navigate up", ledName: "navigateup", rect: NSRect(x: 885, y: 148, width: 34, height: 20)),
        ButtonElement(inputName: "navigate left", ledName: "navigateleft", rect: NSRect(x: 828, y: 185, width: 34, height: 20)),
        ButtonElement(inputName: "navigate down", ledName: "navigatedown", rect: NSRect(x: 885, y: 185, width: 34, height: 20)),
        ButtonElement(inputName: "navigate right", ledName: "navigateright", rect: NSRect(x: 940, y: 185, width: 34, height: 20)),
        ButtonElement(inputName: "octave down", ledName: "octavedownwhite", rect: NSRect(x: 82, y: 238, width: 52, height: 26)),
        ButtonElement(inputName: "octave up", ledName: "octaveupwhite", rect: NSRect(x: 150, y: 238, width: 52, height: 26)),
    ]
}
