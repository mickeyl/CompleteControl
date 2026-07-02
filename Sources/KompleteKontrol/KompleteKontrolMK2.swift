import Foundation
import Darwin
import IOKit
import IOKit.hid
import KontrolUSB

public enum KompleteKontrolMK2Protocol {
    public static let vendorID = 0x17cc
    public static let initReportID: UInt8 = 0xa0
    // 0xa0 takes mode flags (bench 2026-07-02):
    // [0x00, 0x10] = host-control mode — all LEDs (incl. function buttons + ribbon) are
    //   host-driven via 0x80, and the strip streams raw on input report 0x02.
    // [0x93, 0x00] = mapping-engine mode — the firmware owns function/ribbon LEDs and
    //   generates MIDI from the 0xA1-0xA4 templates (the standalone-controller mode).
    // [0x00, 0x00] = neither: strip and templates silent (the original "dead ribbon").
    public static let initModeHostControl: [UInt8] = [0x00, 0x10]
    public static let initModeMappingEngineOn: [UInt8] = [0x93, 0x00]
    public static let initModeMappingEngineOff: [UInt8] = [0x00, 0x00]
    public static let inputReportID: UInt32 = 0x01
    public static let stripReportID: UInt8 = 0x02
    public static let controllerMirrorReportID: UInt8 = 0xaa
    public static let wheelStripMapReportID: UInt8 = 0xa2
    // Buttons+knobs template: 8 buttons x12 + 8 knobs x12 + 8 backlight + 3 trailer bytes.
    // All-off suppresses the factory MIDI-mode template (rotaries CC14-21) that becomes
    // active as soon as the mapping engine is on; HID report 0x01 is unaffected.
    public static let buttonKnobMapReportID: UInt8 = 0xa1
    public static let allOffButtonKnobMapPayload = [UInt8](repeating: 0x00, count: 203)
    // Factory MIDI-mode knob template (rotaries CC14-21, ch 1): written back on daemon
    // shutdown so the keyboard stays usable as a standalone controller.
    public static let standaloneButtonKnobMapPayload: [UInt8] = {
        var payload = [UInt8](repeating: 0x00, count: 203)
        for knob in 0..<8 {
            let base = 96 + knob * 12
            payload[base] = 0x03
            payload[base + 1] = UInt8(14 + knob)
            payload[base + 3] = 0x3c
            payload[base + 6] = 0x7f
        }
        return payload
    }()
    public static let mapCommitReportID: UInt8 = 0xaf
    public static let mapCommitPayload: [UInt8] = [0x00, 0x02]

    /// One assignment slot of the onboard mapping engine (report 0xa2 carries three:
    /// pitch wheel, mod wheel, touch strip).
    public enum AnalogAssignment: Sendable {
        /// The control emits nothing; for the strip the LEDs stay dark.
        case off
        /// Unipolar: 0…127 on the given CC/channel, LEDs fill from the left,
        /// the value holds where the finger lifts.
        case cc(number: UInt8, channel: UInt8 = 0, min: UInt8 = 0, max: UInt8 = 0x7f)
        /// Bipolar: 14-bit pitch bend, LEDs fan out from the center, springs back
        /// to center on release. `decay` 0…8 sets the return speed (smaller = slower).
        case pitchBend(channel: UInt8 = 0, decay: UInt8 = 4)

        var slotBytes: [UInt8] {
            switch self {
                case .off:
                    [UInt8](repeating: 0x00, count: 12)
                case let .cc(number, channel, min, max):
                    [0x03, number & 0x7f, channel & 0x0f, 0x20, min & 0x7f, 0x00, max & 0x7f, 0x00, 0x00, 0x00, 0x00, 0x00]
                case let .pitchBend(channel, _):
                    [0x06, 0x00, channel & 0x0f, 0x00, 0x00, 0x00, 0xff, 0x3f, 0x00, 0x00, 0x01, 0x00]
            }
        }
    }

    public static func wheelStripMapPayload(
        pitchWheel: AnalogAssignment = .pitchBend(),
        modWheel: AnalogAssignment = .cc(number: 1),
        strip: AnalogAssignment = .cc(number: 11)
    ) -> [UInt8] {
        // Trailer byte 0 = pitch-bend decay, byte 3 = strip LED zero point
        // (0x00 left origin for unipolar, 0x02 center origin for bipolar).
        let trailer: [UInt8] = if case let .pitchBend(_, decay) = strip {
            [min(decay, 8), 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00]
        } else {
            [UInt8](repeating: 0x00, count: 8)
        }
        return pitchWheel.slotBytes + modWheel.slotBytes + strip.slotBytes + trailer
    }

    public static let defaultWheelStripMapPayload: [UInt8] = wheelStripMapPayload()
    public static let buttonLEDReportID: UInt8 = 0x80
    public static let lightGuideReportID: UInt8 = 0x81
    public static let lightGuideReportSize = 250
    public static let lightGuideKeyMapSize = 249
    public static let buttonLEDReportSize = 80
    public static let buttonLEDMapSize = 79
    public static let displayWidth = 480
    public static let displayHeight = 272
}

public enum KompleteKontrolDeviceModel: CaseIterable, Sendable {
    case s49MK2
    case s61MK2
    case s88MK2

    public var productID: Int {
        switch self {
            case .s49MK2: 0x1610
            case .s61MK2: 0x1620
            case .s88MK2: 0x1630
        }
    }

    public var name: String {
        switch self {
            case .s49MK2: "KOMPLETE KONTROL S49 MK2"
            case .s61MK2: "KOMPLETE KONTROL S61 MK2"
            case .s88MK2: "KOMPLETE KONTROL S88 MK2"
        }
    }

    public var keyCount: Int {
        switch self {
            case .s49MK2: 49
            case .s61MK2: 61
            case .s88MK2: 88
        }
    }

    public var lightGuideNoteOffset: Int {
        switch self {
            case .s49MK2, .s61MK2: -36
            case .s88MK2: -21
        }
    }

    public static func productID(_ productID: Int) -> KompleteKontrolDeviceModel? {
        allCases.first { $0.productID == productID }
    }
}

public enum KKMK2ButtonLED: Int, CaseIterable, Sendable {
    case m = 0, s, function1, function2, function3, function4, function5, function6, function7, function8
    case jogLeft = 10, jogUp, jogDown, jogRight
    case scaleEdit = 15, arpEdit, scene, undoRedo, quantize, auto, pattern, presetUp, track, loop, metro, tempo, presetDown, keyMode, play, record, stop, pageLeft, pageRight, clear, browser, plugin, mixer, instance, midi, setup, fixedVel, unused1, unused2
    case strip1 = 44, strip2, strip3, strip4, strip5, strip6, strip7, strip8, strip9, strip10, strip11, strip12, strip13, strip14, strip15, strip16, strip17, strip18, strip19, strip20, strip21, strip22, strip23, strip24

    public var protocolName: String {
        switch self {
            case .m: "m"
            case .s: "s"
            case .function1: "function1"
            case .function2: "function2"
            case .function3: "function3"
            case .function4: "function4"
            case .function5: "function5"
            case .function6: "function6"
            case .function7: "function7"
            case .function8: "function8"
            case .jogLeft: "jogleft"
            case .jogUp: "jogup"
            case .jogDown: "jogdown"
            case .jogRight: "jogright"
            case .scaleEdit: "scaleedit"
            case .arpEdit: "arpedit"
            case .scene: "scene"
            case .undoRedo: "undoredo"
            case .quantize: "quantize"
            case .auto: "auto"
            case .pattern: "pattern"
            case .presetUp: "presetup"
            case .track: "track"
            case .loop: "loop"
            case .metro: "metro"
            case .tempo: "tempo"
            case .presetDown: "presetdown"
            case .keyMode: "keymode"
            case .play: "play"
            case .record: "record"
            case .stop: "stop"
            case .pageLeft: "pageleft"
            case .pageRight: "pageright"
            case .clear: "clear"
            case .browser: "browser"
            case .plugin: "plugin"
            case .mixer: "mixer"
            case .instance: "instance"
            case .midi: "midi"
            case .setup: "setup"
            case .fixedVel: "fixedvel"
            case .unused1: "unused1"
            case .unused2: "unused2"
            case .strip1: "strip1"
            case .strip2: "strip2"
            case .strip3: "strip3"
            case .strip4: "strip4"
            case .strip5: "strip5"
            case .strip6: "strip6"
            case .strip7: "strip7"
            case .strip8: "strip8"
            case .strip9: "strip9"
            case .strip10: "strip10"
            case .strip11: "strip11"
            case .strip12: "strip12"
            case .strip13: "strip13"
            case .strip14: "strip14"
            case .strip15: "strip15"
            case .strip16: "strip16"
            case .strip17: "strip17"
            case .strip18: "strip18"
            case .strip19: "strip19"
            case .strip20: "strip20"
            case .strip21: "strip21"
            case .strip22: "strip22"
            case .strip23: "strip23"
            case .strip24: "strip24"
        }
    }
}

public enum KKMK2InputEvent: Equatable, Sendable, CustomStringConvertible {
    case button(name: String, pressed: Bool)
    case touchEncoder(index: Int, touched: Bool)
    case jog(direction: String)
    case jogTouch(touched: Bool)
    case jogScroll(delta: Int, value: Int)
    /// Raw ribbon stream (host-control mode, report 0x02): position 0…1024, nil = release.
    case strip(position: Int?, time: Int)
    case knob(index: Int, delta: Int, value: Int)
    case touchStrip(name: String, value: Int)
    case rawChanged(indices: [Int])

    public var description: String {
        switch self {
            case let .button(name, pressed):
                "button \(name) \(pressed ? "down" : "up")"
            case let .touchEncoder(index, touched):
                "touch encoder \(index) \(touched ? "on" : "off")"
            case let .jog(direction):
                "jog \(direction)"
            case let .jogTouch(touched):
                "jog touch \(touched ? "on" : "off")"
            case let .strip(position, time):
                position.map { "strip \($0) t=\(time)" } ?? "strip release t=\(time)"
            case let .jogScroll(delta, value):
                "jog scroll \(delta > 0 ? "+" : "")\(delta) value=\(value)"
            case let .knob(index, delta, value):
                "knob \(index) \(delta > 0 ? "+" : "")\(delta) value=\(value)"
            case let .touchStrip(name, value):
                "\(name) strip value=\(value)"
            case let .rawChanged(indices):
                "raw changed \(indices.map(String.init).joined(separator: ","))"
        }
    }
}

public struct KKMK2InputReport: Sendable {
    public var bytes: [UInt8]
    public var previous: [UInt8]?
    public var events: [KKMK2InputEvent]
    public var receptionTimestamp: UInt64
}

public enum KKMK2InputReportDecoder {
    private static let knobBaseOffset = 10
    private static let encoderTouchOffset = 7

    private struct ButtonBit {
        let byte: Int
        let mask: UInt8
        let name: String
    }

    private static let buttonBits: [ButtonBit] = [
        ButtonBit(byte: 1, mask: 0x01, name: "function5"),
        ButtonBit(byte: 1, mask: 0x02, name: "function6"),
        ButtonBit(byte: 1, mask: 0x04, name: "function7"),
        ButtonBit(byte: 1, mask: 0x08, name: "function8"),
        ButtonBit(byte: 1, mask: 0x10, name: "function1"),
        ButtonBit(byte: 1, mask: 0x20, name: "function2"),
        ButtonBit(byte: 1, mask: 0x40, name: "function3"),
        ButtonBit(byte: 1, mask: 0x80, name: "function4"),
        ButtonBit(byte: 2, mask: 0x01, name: "auto"),
        ButtonBit(byte: 2, mask: 0x02, name: "quantize"),
        ButtonBit(byte: 2, mask: 0x04, name: "arp"),
        ButtonBit(byte: 2, mask: 0x08, name: "scale"),
        ButtonBit(byte: 2, mask: 0x10, name: "play"),
        ButtonBit(byte: 2, mask: 0x20, name: "loop"),
        ButtonBit(byte: 2, mask: 0x40, name: "undoredo"),
        ButtonBit(byte: 2, mask: 0x80, name: "shift"),
        ButtonBit(byte: 3, mask: 0x01, name: "stop"),
        ButtonBit(byte: 3, mask: 0x02, name: "record"),
        ButtonBit(byte: 3, mask: 0x04, name: "tempo"),
        ButtonBit(byte: 3, mask: 0x08, name: "metro"),
        ButtonBit(byte: 3, mask: 0x10, name: "presetup"),
        ButtonBit(byte: 3, mask: 0x20, name: "pageright"),
        ButtonBit(byte: 3, mask: 0x40, name: "presetdown"),
        ButtonBit(byte: 3, mask: 0x80, name: "pageleft"),
        ButtonBit(byte: 4, mask: 0x01, name: "mute"),
        ButtonBit(byte: 4, mask: 0x02, name: "solo"),
        ButtonBit(byte: 4, mask: 0x04, name: "scene"),
        ButtonBit(byte: 4, mask: 0x08, name: "pattern"),
        ButtonBit(byte: 4, mask: 0x10, name: "track"),
        ButtonBit(byte: 4, mask: 0x20, name: "clear"),
        ButtonBit(byte: 4, mask: 0x40, name: "keymode"),
        ButtonBit(byte: 5, mask: 0x01, name: "mixer"),
        ButtonBit(byte: 5, mask: 0x02, name: "plugin"),
        ButtonBit(byte: 5, mask: 0x04, name: "browser"),
        ButtonBit(byte: 5, mask: 0x08, name: "setup"),
        ButtonBit(byte: 5, mask: 0x10, name: "instance"),
        ButtonBit(byte: 5, mask: 0x20, name: "midi"),
        ButtonBit(byte: 8, mask: 0x01, name: "octavedown"),
        ButtonBit(byte: 8, mask: 0x02, name: "octaveup"),
        ButtonBit(byte: 8, mask: 0x04, name: "fixedvel"),
    ]

    private static let jogStates: [UInt8: String] = [
        0x0c: "press",
        0x14: "left",
        0x24: "up",
        0x44: "down",
        0x84: "right",
    ]

    public static func hexDump(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    public static func summary(_ bytes: [UInt8]) -> String {
        let head = bytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
        let knobs = (0..<8).compactMap { index -> String? in
            let offset = knobBaseOffset + index * 2
            guard let value = word(bytes, offset) else { return nil }
            return "k\(index + 1):\(value)"
        }.joined(separator: " ")
        return "head[\(head)] \(knobs)"
    }

    /// Report-ID-aware entry point: 0x01 = buttons/encoders/wheels, 0x02 = raw strip.
    public static func eventsForReport(previous: [UInt8]?, current: [UInt8]) -> [KKMK2InputEvent] {
        switch current.first {
            case UInt8(KompleteKontrolMK2Protocol.inputReportID):
                events(previous: previous?.first == current.first ? previous : nil, current: current)
            case KompleteKontrolMK2Protocol.stripReportID:
                stripEvents(current: current)
            default:
                []
        }
    }

    /// Report 0x02 layout (bench 2026-07-02): [u16 const] [u16 const] [u16 time ms]
    /// [u16 position 0…1024, 0 = release] [u16 zero]. Streams ~100 Hz while touched.
    public static func stripEvents(current: [UInt8]) -> [KKMK2InputEvent] {
        guard current.count >= 9, let time = word(current, 5), let position = word(current, 7) else { return [] }
        return [.strip(position: position == 0 ? nil : position, time: time)]
    }

    public static func events(previous: [UInt8]?, current: [UInt8]) -> [KKMK2InputEvent] {
        guard let previous, previous.count == current.count else { return [] }
        var events: [KKMK2InputEvent] = []

        var explained = Set<Int>()

        for bit in buttonBits {
            let was = state(previous, bit)
            let now = state(current, bit)
            if was != now {
                events.append(.button(name: bit.name, pressed: now))
                explained.insert(bit.byte)
            }
        }

        // Byte 6 layout (bench 2026-07-02): 0x04 = cap touched, 0x08 = click,
        // 0x10/0x20/0x40/0x80 = push left/up/down/right — pushes arrive OR'd with touch.
        let jogStateChanged = current.indices.contains(6) && previous[6] != current[6]
        if jogStateChanged {
            let wasTouched = (previous[6] & 0x04) != 0
            let isTouched = (current[6] & 0x04) != 0
            if wasTouched != isTouched {
                events.append(.jogTouch(touched: isTouched))
            }
            if let direction = jogStates[current[6]] {
                events.append(.jog(direction: direction))
            }
            explained.insert(6)
        }

        if current.indices.contains(30), previous[30] != current[30] {
            if jogStateChanged && current.indices.contains(6) && current[6] == 0x04 {
                explained.insert(30)
            } else {
                let delta = KKInputReportDecoder.wrappedDelta(from: Int(previous[30] & 0x0f), to: Int(current[30] & 0x0f), modulo: 16)
                if delta != 0 {
                    events.append(.jogScroll(delta: delta, value: Int(current[30] & 0x0f)))
                    explained.insert(30)
                }
            }
        }

        for index in 0..<8 {
            let offset = knobBaseOffset + index * 2
            guard let old = word(previous, offset), let new = word(current, offset), old != new else { continue }
            let delta = KKInputReportDecoder.wrappedDelta(from: old, to: new)
            if delta != 0 {
                events.append(.knob(index: index + 1, delta: delta, value: new))
                explained.insert(offset)
                explained.insert(offset + 1)
            }
        }

        if previous.indices.contains(encoderTouchOffset), current.indices.contains(encoderTouchOffset), previous[encoderTouchOffset] != current[encoderTouchOffset] {
            for index in 0..<8 {
                let mask = UInt8(0x80 >> index)
                let wasTouched = (previous[encoderTouchOffset] & mask) != 0
                let isTouched = (current[encoderTouchOffset] & mask) != 0
                if wasTouched != isTouched {
                    events.append(.touchEncoder(index: index + 1, touched: isTouched))
                }
            }
            explained.insert(encoderTouchOffset)
        }

        if current.indices.contains(33), previous[33] != current[33] {
            events.append(.touchStrip(name: "pitch", value: Int(current[33])))
            explained.insert(33)
        }
        if current.indices.contains(35), previous[35] != current[35] {
            events.append(.touchStrip(name: "mod", value: Int(current[35])))
            explained.insert(35)
        }

        let changed = current.indices.filter { previous[$0] != current[$0] && !explained.contains($0) }
        if !changed.isEmpty {
            events.append(.rawChanged(indices: changed))
        }
        return events
    }

    private static func state(_ bytes: [UInt8], _ bit: ButtonBit) -> Bool {
        guard bytes.indices.contains(bit.byte) else { return false }
        return (bytes[bit.byte] & bit.mask) != 0
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard bytes.indices.contains(offset + 1) else { return nil }
        return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }
}

public final class KompleteKontrolSSeriesMK2: @unchecked Sendable {
    public var onInputReport: (@Sendable (KKMK2InputReport) -> Void)?
    public var onMountChanged: (@Sendable (Bool) -> Void)?
    public var log: (@Sendable (String) -> Void)?

    public private(set) var model: KompleteKontrolDeviceModel?
    public private(set) var guide = [UInt8](repeating: 0, count: KompleteKontrolMK2Protocol.lightGuideKeyMapSize)
    public private(set) var buttonLEDs = [UInt8](repeating: 0, count: KompleteKontrolMK2Protocol.buttonLEDMapSize)

    private let seizeHID: Bool
    private var hidManager: IOHIDManager?
    private var hidDevice: IOHIDDevice?
    private var inputBuffer: UnsafeMutablePointer<UInt8>?
    private var inputBufferLength = 64
    private var inputRunLoop: CFRunLoop?
    private var inputThread: Thread?
    private var lastReport: [UInt8]?

    public init(seizeHID: Bool = false) {
        self.seizeHID = seizeHID
    }

    deinit {
        close()
    }

    public func open(logOpen: Bool = true) throws {
        guard mountIfAvailable(logOpen: logOpen) else {
            throw KKDriverError.openFailed
        }
    }

    @discardableResult
    public func mountIfAvailable(logOpen: Bool = false) -> Bool {
        guard hidDevice == nil else { return true }
        guard let opened = Self.openHIDDevice(seize: seizeHID, logOpen: logOpen, logger: log) else { return false }
        hidManager = opened.manager
        hidDevice = opened.device
        model = opened.model
        inputBufferLength = max(opened.maxInputReportSize, 64)
        guide = [UInt8](repeating: 0, count: KompleteKontrolMK2Protocol.lightGuideKeyMapSize)
        buttonLEDs = [UInt8](repeating: 0, count: KompleteKontrolMK2Protocol.buttonLEDMapSize)
        scheduleInputIfNeeded()
        log?("\(opened.model.name) mounted.")
        onMountChanged?(true)
        return true
    }

    public func startInputMonitoring() {
        guard inputThread == nil else { return }
        let thread = Thread { [weak self] in
            Thread.current.qualityOfService = .userInteractive
            guard let self else { return }
            let runLoop = CFRunLoopGetCurrent()!
            self.inputRunLoop = runLoop
            self.scheduleInput(on: runLoop)
            CFRunLoopRun()
        }
        thread.qualityOfService = .userInteractive
        thread.stackSize = 1 << 20
        inputThread = thread
        thread.start()
    }

    public func close() {
        if let runLoop = inputRunLoop {
            CFRunLoopStop(runLoop)
        }
        if let device = hidDevice {
            IOHIDDeviceClose(device, hidOpenOptions)
        }
        if let manager = hidManager {
            IOHIDManagerClose(manager, hidOpenOptions)
        }
        inputBuffer?.deallocate()
        inputBuffer = nil
        inputThread = nil
        inputRunLoop = nil
        hidDevice = nil
        hidManager = nil
        model = nil
        lastReport = nil
    }

    @discardableResult
    public func handshake() -> IOReturn {
        sendHIDReport(reportID: KompleteKontrolMK2Protocol.initReportID, bytesIncludingReportID: [KompleteKontrolMK2Protocol.initReportID, 0x00, 0x00])
    }

    @discardableResult
    public func sendGuide() -> IOReturn {
        sendHIDReport(reportID: KompleteKontrolMK2Protocol.lightGuideReportID, bytesIncludingReportID: [KompleteKontrolMK2Protocol.lightGuideReportID] + guide)
    }

    @discardableResult
    public func sendButtonLEDs() -> IOReturn {
        sendHIDReport(reportID: KompleteKontrolMK2Protocol.buttonLEDReportID, bytesIncludingReportID: [KompleteKontrolMK2Protocol.buttonLEDReportID] + buttonLEDs)
    }

    @discardableResult
    public func setKey(_ index: Int, color: KKRGB, flush: Bool = true) -> IOReturn? {
        guard let model, (0..<model.keyCount).contains(index) else { return nil }
        guide[index] = Self.paletteCode(for: color)
        return flush ? sendGuide() : nil
    }

    @discardableResult
    public func setAllKeys(color: KKRGB, flush: Bool = true) -> IOReturn? {
        guard let model else { return nil }
        let code = Self.paletteCode(for: color)
        for index in 0..<model.keyCount {
            guide[index] = code
        }
        return flush ? sendGuide() : nil
    }

    @discardableResult
    public func setButtonLED(_ led: KKMK2ButtonLED, color: KKRGB, flush: Bool = true) -> IOReturn? {
        let index = led.rawValue
        guard buttonLEDs.indices.contains(index) else { return nil }
        buttonLEDs[index] = Self.paletteCode(for: color)
        return flush ? sendButtonLEDs() : nil
    }

    @discardableResult
    public func setAllButtonLEDs(color: KKRGB, flush: Bool = true) -> IOReturn {
        let code = Self.paletteCode(for: color)
        for index in buttonLEDs.indices {
            buttonLEDs[index] = code
        }
        return flush ? sendButtonLEDs() : kIOReturnSuccess
    }

    @discardableResult
    public func fillDisplay(screen: Int, x: Int = 0, y: Int = 0, width: Int = KompleteKontrolMK2Protocol.displayWidth, height: Int = KompleteKontrolMK2Protocol.displayHeight, color565: UInt16, timeoutMs: UInt32 = 1_000) -> KKUSBResult {
        guard (0...1).contains(screen) else {
            return KKUSBResult(status: -1, message: "display screen out of range")
        }
        guard ensureDaemonAvailable() else {
            return KKUSBResult(status: -1, message: "Komplete Kontrol daemon unavailable")
        }
        guard let client = KompleteKontrolDaemonClient(socketPath: KompleteKontrolLibUSBServer.defaultDaemonSocketPath) else {
            return KKUSBResult(status: -1, message: "Komplete Kontrol daemon socket unavailable")
        }
        let line = [
            "mk2fill",
            KKHex.byte(UInt8(screen & 0xff)),
            String(format: "%04x", x & 0xffff),
            String(format: "%04x", y & 0xffff),
            String(format: "%04x", width & 0xffff),
            String(format: "%04x", height & 0xffff),
            String(format: "%04x", Int(color565)),
            String(format: "%04x", Int(timeoutMs)),
        ].joined(separator: " ") + "\n"
        guard let response = client.request(line, timeoutUsec: 3_000_000) else {
            return KKUSBResult(status: -1, message: "Komplete Kontrol daemon timed out")
        }
        if response == "ok" {
            return KKUSBResult(status: 0, message: response)
        }
        return KKUSBResult(status: -1, message: response)
    }

    @discardableResult
    public func configureAnalogControls(
        pitchWheel: KompleteKontrolMK2Protocol.AnalogAssignment = .pitchBend(),
        modWheel: KompleteKontrolMK2Protocol.AnalogAssignment = .cc(number: 1),
        strip: KompleteKontrolMK2Protocol.AnalogAssignment = .cc(number: 11)
    ) -> KKUSBResult {
        guard ensureDaemonAvailable() else {
            return KKUSBResult(status: -1, message: "Komplete Kontrol daemon unavailable")
        }
        guard let client = KompleteKontrolDaemonClient(socketPath: KompleteKontrolLibUSBServer.defaultDaemonSocketPath) else {
            return KKUSBResult(status: -1, message: "Komplete Kontrol daemon socket unavailable")
        }
        let payload = KompleteKontrolMK2Protocol.wheelStripMapPayload(pitchWheel: pitchWheel, modWheel: modWheel, strip: strip)
        let writes: [(UInt8, [UInt8])] = [
            (KompleteKontrolMK2Protocol.wheelStripMapReportID, payload),
            (KompleteKontrolMK2Protocol.mapCommitReportID, KompleteKontrolMK2Protocol.mapCommitPayload),
        ]
        for (reportID, bytes) in writes {
            let line = (["write", KKHex.byte(reportID)] + bytes.map(KKHex.byte)).joined(separator: " ") + "\n"
            guard let response = client.request(line, timeoutUsec: 3_000_000) else {
                return KKUSBResult(status: -1, message: "Komplete Kontrol daemon timed out")
            }
            guard response == "ok" else {
                return KKUSBResult(status: -1, message: response)
            }
        }
        return KKUSBResult(status: 0, message: "ok")
    }

    public static func rgb565(_ color: KKRGB) -> UInt16 {
        let r = UInt16(color.red >> 3)
        let g = UInt16(color.green >> 2)
        let b = UInt16(color.blue >> 3)
        return (r << 11) | (g << 5) | b
    }

    public static func paletteCode(for color: KKRGB, intensity: UInt8 = 0x03) -> UInt8 {
        guard color != .off else { return 0x00 }
        var bestIndex = 0
        var bestDistance = Int.max
        for (index, paletteColor) in mk2Palette.enumerated() {
            let dr = Int(color.red) - Int(paletteColor.red)
            let dg = Int(color.green) - Int(paletteColor.green)
            let db = Int(color.blue) - Int(paletteColor.blue)
            let distance = dr * dr + dg * dg + db * db
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return UInt8(((bestIndex + 1) << 2) | Int(intensity & 0x03))
    }

    private var hidOpenOptions: IOOptionBits {
        seizeHID ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice) : IOOptionBits(kIOHIDOptionsTypeNone)
    }

    private func ensureDaemonAvailable() -> Bool {
        if KompleteKontrolLibUSBServer.daemonSocketIsAvailable() {
            return true
        }
        return KompleteKontrolLibUSBServer.startDaemonWithAdministratorPrivileges(executablePath: nil, logger: log)
    }

    private func sendHIDReport(reportID: UInt8, bytesIncludingReportID: [UInt8]) -> IOReturn {
        guard let hidDevice else { return kIOReturnNotOpen }
        var bytes = bytesIncludingReportID
        let length = bytes.count
        return bytes.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceSetReport(hidDevice, kIOHIDReportTypeOutput, CFIndex(reportID), baseAddress, length)
        }
    }

    private func scheduleInputIfNeeded() {
        guard inputThread != nil, let runLoop = inputRunLoop else { return }
        scheduleInput(on: runLoop)
    }

    private func scheduleInput(on runLoop: CFRunLoop) {
        guard let hidDevice else {
            _ = mountIfAvailable(logOpen: false)
            if hidDevice == nil {
                return
            }
            return scheduleInput(on: runLoop)
        }
        if inputBuffer == nil {
            inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferLength)
        }
        guard let inputBuffer else { return }
        IOHIDDeviceScheduleWithRunLoop(hidDevice, runLoop, CFRunLoopMode.defaultMode.rawValue)
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceRegisterInputReportCallback(hidDevice, inputBuffer, inputBufferLength, kkMK2InputCallback, context)
    }

    fileprivate func handleInput(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        var bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
        if bytes.first != UInt8(reportID & 0xff) {
            bytes.insert(UInt8(reportID & 0xff), at: 0)
        }
        if bytes.first == UInt8(KompleteKontrolMK2Protocol.inputReportID) {
            let previous = lastReport
            let events = KKMK2InputReportDecoder.events(previous: previous, current: bytes)
            lastReport = bytes
            onInputReport?(KKMK2InputReport(bytes: bytes, previous: previous, events: events, receptionTimestamp: KKTiming.now()))
            return
        }
        let events = KKMK2InputReportDecoder.eventsForReport(previous: nil, current: bytes)
        guard !events.isEmpty else { return }
        onInputReport?(KKMK2InputReport(bytes: bytes, previous: nil, events: events, receptionTimestamp: KKTiming.now()))
    }

    private static func openHIDDevice(seize: Bool, logOpen: Bool, logger: (@Sendable (String) -> Void)?) -> (manager: IOHIDManager, device: IOHIDDevice, model: KompleteKontrolDeviceModel, maxInputReportSize: Int, maxOutputReportSize: Int)? {
        let options = seize ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice) : IOOptionBits(kIOHIDOptionsTypeNone)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, options)
        let matches = KompleteKontrolDeviceModel.allCases.map {
            [
                kIOHIDVendorIDKey: KompleteKontrolMK2Protocol.vendorID,
                kIOHIDProductIDKey: $0.productID,
            ] as CFDictionary
        } as CFArray
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches)
        let managerResult = IOHIDManagerOpen(manager, options)
        guard managerResult == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            if logOpen {
                logger?("MK2 IOHIDManagerOpen -> \(String(format: "0x%08x", managerResult))")
            }
            IOHIDManagerClose(manager, options)
            return nil
        }
        for device in devices {
            let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
            guard let model = KompleteKontrolDeviceModel.productID(productID) else { continue }
            let openResult = IOHIDDeviceOpen(device, options)
            if logOpen {
                logger?("MK2 IOHIDDeviceOpen(\(model.name), seize=\(seize)) -> \(String(format: "0x%08x", openResult))")
            }
            guard openResult == kIOReturnSuccess else { continue }
            func property(_ key: String) -> Int {
                (IOHIDDeviceGetProperty(device, key as CFString) as? Int) ?? 0
            }
            return (
                manager,
                device,
                model,
                property(kIOHIDMaxInputReportSizeKey),
                property(kIOHIDMaxOutputReportSizeKey)
            )
        }
        IOHIDManagerClose(manager, options)
        return nil
    }

    private static let mk2Palette: [KKRGB] = [
        KKRGB(red: 0xff, green: 0x00, blue: 0x00),
        KKRGB(red: 0xff, green: 0x3f, blue: 0x00),
        KKRGB(red: 0xff, green: 0x7f, blue: 0x00),
        KKRGB(red: 0xff, green: 0xcf, blue: 0x00),
        KKRGB(red: 0xff, green: 0xff, blue: 0x00),
        KKRGB(red: 0x7f, green: 0xff, blue: 0x00),
        KKRGB(red: 0x00, green: 0xff, blue: 0x00),
        KKRGB(red: 0x00, green: 0xff, blue: 0x7f),
        KKRGB(red: 0x00, green: 0xff, blue: 0xff),
        KKRGB(red: 0x00, green: 0x7f, blue: 0xff),
        KKRGB(red: 0x00, green: 0x00, blue: 0xff),
        KKRGB(red: 0x3f, green: 0x00, blue: 0xff),
        KKRGB(red: 0x7f, green: 0x00, blue: 0xff),
        KKRGB(red: 0xff, green: 0x00, blue: 0xff),
        KKRGB(red: 0xff, green: 0x00, blue: 0x7f),
        KKRGB(red: 0xff, green: 0x00, blue: 0x3f),
        KKRGB(red: 0xff, green: 0xff, blue: 0xff),
    ]
}

private let kkMK2InputCallback: IOHIDReportCallback = { context, _, _, _, reportID, report, length in
    guard let context else { return }
    let device = Unmanaged<KompleteKontrolSSeriesMK2>.fromOpaque(context).takeUnretainedValue()
    device.handleInput(reportID: reportID, report: report, length: length)
}
