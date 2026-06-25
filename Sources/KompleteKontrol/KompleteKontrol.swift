import Foundation
import Darwin
import IOKit
import IOKit.hid
import KontrolUSB

public enum KompleteKontrolS25MK1Protocol {
    public static let vendorID = 0x17cc
    public static let productID = 0x1340
    public static let keyCount = 25
    public static let lightGuideReportID: UInt8 = 0x82
    public static let buttonLEDReportID: UInt8 = 0x80
    public static let displayReportID: UInt8 = 0xe0
    public static let initReportID: UInt8 = 0xa0
    public static let inputReportID: UInt32 = 0x01
}

public struct KKRGB: Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let off = KKRGB(red: 0, green: 0, blue: 0)

    public static func hsv(_ h: Double, _ s: Double, _ v: Double) -> KKRGB {
        let c = v * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let r: Double
        let g: Double
        let b: Double
        switch h {
            case ..<60:   (r, g, b) = (c, x, 0)
            case ..<120:  (r, g, b) = (x, c, 0)
            case ..<180:  (r, g, b) = (0, c, x)
            case ..<240:  (r, g, b) = (0, x, c)
            case ..<300:  (r, g, b) = (x, 0, c)
            default:      (r, g, b) = (c, 0, x)
        }
        return KKRGB(
            red: UInt8(((r + m) * 255).rounded()),
            green: UInt8(((g + m) * 255).rounded()),
            blue: UInt8(((b + m) * 255).rounded())
        )
    }
}

public enum KKDisplayAlignment: Sendable {
    case left
    case center
    case right
}

public struct KKDisplayFrame: Equatable, Sendable {
    public static let displayCount = 9
    public static let rowCount = 3
    public static let characterCount = 8
    public static let bytesPerDisplayRow = characterCount * 2
    public static let bytesPerReportRow = 240

    private static let emptyGlyph: UInt16 = 0x0000

    // CP437-compatible 16-segment glyph table from shaduzlabs/cabl
    // src/gfx/fonts/data/FONT_16-seg.h, MIT license.
    private static let font16Segment: [UInt16] = [
        0x0000, 0x0578, 0x0578, 0x830f, 0x0503, 0x5a87, 0x0c7c, 0x1878,
        0x1887, 0x4860, 0x0a81, 0x4c66, 0x5d03, 0x4a62, 0x5a7e, 0xff00,
        0x21c0, 0x840c, 0x2466, 0x420c, 0x189f, 0xc333, 0xf878, 0x2466,
        0xe000, 0x0700, 0x2900, 0x9400, 0x0060, 0x2466, 0xe030, 0x0703,
        0x0000, 0x0004, 0x0204, 0x5ac0, 0x5abb, 0x7e99, 0x8b79, 0x0004,
        0x8400, 0x2100, 0xff00, 0x5a00, 0x2000, 0x1800, 0x0000, 0x2400,
        0x24ff, 0x040c, 0x1877, 0x183f, 0x188c, 0x18bb, 0x18fb, 0x000f,
        0x18ff, 0x18bf, 0x0021, 0x2001, 0x8103, 0x1830, 0x2403, 0x5007,
        0x487f, 0x18cf, 0x523f, 0x00f3, 0x423f, 0x18f3, 0x18c3, 0x10fb,
        0x18cc, 0x4200, 0x203c, 0x8cc0, 0x00f0, 0x05cc, 0x81cc, 0x00ff,
        0x18c7, 0x80ff, 0x98c7, 0x18bb, 0x4203, 0x00fc, 0x24c0, 0xa0cc,
        0xa500, 0x5884, 0x2433, 0x00e1, 0x8100, 0x001e, 0x0180, 0x0030,
        0x0100, 0xc860, 0x48e0, 0x0860, 0x4a60, 0x2860, 0x5a02, 0x4aa1,
        0x48c0, 0x4000, 0x4220, 0xc600, 0x4200, 0x5848, 0x4840, 0x4860,
        0x0ac1, 0x4a81, 0x0840, 0x9010, 0x08e0, 0x4060, 0x2040, 0xa048,
        0x6600, 0x2500, 0x2820, 0x4a12, 0x4200, 0x5221, 0x0580, 0x540c,
        0x4850,
    ]

    public private(set) var rows: [[UInt8]]

    public init() {
        rows = Array(
            repeating: Array(repeating: 0, count: Self.bytesPerReportRow),
            count: Self.rowCount
        )
    }

    public static func glyph(for scalar: Unicode.Scalar) -> UInt16 {
        let value = Int(scalar.value)
        guard value >= 0, value < font16Segment.count else { return emptyGlyph }
        return font16Segment[value]
    }

    public mutating func clear() {
        for row in rows.indices {
            rows[row] = Array(repeating: 0, count: Self.bytesPerReportRow)
        }
    }

    public mutating func fillDisplay(_ display: Int, glyph: UInt16 = 0xffff) {
        guard Self.validDisplay(display) else { return }
        for row in 1..<Self.rowCount {
            for column in 0..<Self.characterCount {
                setGlyph(glyph, display: display, row: row, column: column)
            }
        }
    }

    public mutating func setText(_ text: String, display: Int, row: Int, alignment: KKDisplayAlignment = .left) {
        guard Self.validDisplay(display), Self.validTextRow(row) else { return }
        let scalars = Array(text.unicodeScalars.prefix(Self.characterCount))
        let leftPadding: Int
        switch alignment {
            case .left:
                leftPadding = 0
            case .center:
                leftPadding = max(0, (Self.characterCount - scalars.count) / 2)
            case .right:
                leftPadding = max(0, Self.characterCount - scalars.count)
        }
        for column in 0..<Self.characterCount {
            setGlyph(Self.emptyGlyph, display: display, row: row, column: column)
        }
        for (offset, scalar) in scalars.enumerated() where leftPadding + offset < Self.characterCount {
            setGlyph(Self.glyph(for: scalar), display: display, row: row, column: leftPadding + offset)
        }
    }

    public mutating func setBar(_ value: Double, display: Int, row: Int = 0) {
        guard Self.validDisplay(display), row == 0 else { return }
        let clamped = max(0.0, min(1.0, value))
        let lit = Int((clamped * 9.0).rounded())
        writeByte(display: display, row: 0, byte: 0, value: 0x04 | (lit > 0 ? 0x03 : 0x00))
        for column in 1..<8 {
            writeByte(display: display, row: 0, byte: column * 2, value: lit > column ? 0x03 : 0x00)
        }
        writeByte(display: display, row: 0, byte: 15, value: lit > 8 ? 0x03 : 0x00)
    }

    public mutating func setBox(_ display: Int) {
        guard Self.validDisplay(display) else { return }
        setBar(1.0, display: display, row: 0)
        setText("+------+", display: display, row: 1, alignment: .left)
        setText("| SID  |", display: display, row: 2, alignment: .left)
    }

    public func rowData(_ row: Int) -> [UInt8] {
        guard Self.validRow(row) else { return Array(repeating: 0, count: Self.bytesPerReportRow) }
        return rows[row]
    }

    private mutating func setGlyph(_ glyph: UInt16, display: Int, row: Int, column: Int) {
        guard Self.validDisplay(display), Self.validRow(row), (0..<Self.characterCount).contains(column) else { return }
        let base = (display * Self.bytesPerDisplayRow) + (column * 2)
        rows[row][base] = UInt8(glyph & 0xff)
        rows[row][base + 1] = UInt8((glyph >> 8) & 0xff)
    }

    private mutating func writeByte(display: Int, row: Int, byte: Int, value: UInt8) {
        guard Self.validDisplay(display), Self.validRow(row), (0..<Self.bytesPerDisplayRow).contains(byte) else { return }
        rows[row][display * Self.bytesPerDisplayRow + byte] = value
    }

    private static func validDisplay(_ display: Int) -> Bool {
        (0..<displayCount).contains(display)
    }

    private static func validRow(_ row: Int) -> Bool {
        (0..<rowCount).contains(row)
    }

    private static func validTextRow(_ row: Int) -> Bool {
        (1..<rowCount).contains(row)
    }
}

public enum KKButtonLED: Int, CaseIterable, Sendable {
    case shift = 0
    case scale
    case arp
    case loop
    case rwd
    case ffw
    case play
    case rec
    case stop
    case pageLeft
    case pageRight
    case browse
    case presetUp
    case instance
    case presetDown
    case back
    case navigateUp
    case enter
    case navigateLeft
    case navigateDown
    case navigateRight
    case octaveDownWhite
    case octaveDownRed
    case octaveUpWhite
    case octaveUpRed

    public var protocolName: String {
        switch self {
            case .shift: "shift"
            case .scale: "scale"
            case .arp: "arp"
            case .loop: "loop"
            case .rwd: "rwd"
            case .ffw: "ffw"
            case .play: "play"
            case .rec: "rec"
            case .stop: "stop"
            case .pageLeft: "pageleft"
            case .pageRight: "pageright"
            case .browse: "browse"
            case .presetUp: "presetup"
            case .instance: "instance"
            case .presetDown: "presetdown"
            case .back: "back"
            case .navigateUp: "navigateup"
            case .enter: "enter"
            case .navigateLeft: "navigateleft"
            case .navigateDown: "navigatedown"
            case .navigateRight: "navigateright"
            case .octaveDownWhite: "octavedownwhite"
            case .octaveDownRed: "octavedownred"
            case .octaveUpWhite: "octaveupwhite"
            case .octaveUpRed: "octaveupred"
        }
    }

    public var isFirmwareOwnedStatusLED: Bool {
        switch self {
            case .octaveDownWhite, .octaveDownRed, .octaveUpWhite, .octaveUpRed: true
            default: false
        }
    }

    public static let protocolNames = KKButtonLED.allCases.map(\.protocolName)

    public static func normalize(_ name: String) -> String {
        let lower = name.lowercased()
        if let alias = aliases[lower] {
            return alias
        }
        let base = lower
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        return aliases[base] ?? base
    }

    public static func indices(for token: String, parseNumber: (String) -> Int?) -> [Int] {
        if let index = parseNumber(token), (0..<protocolNames.count).contains(index) {
            return [index]
        }
        let name = normalize(token)
        if name == "octavedown" {
            return [KKButtonLED.octaveDownWhite.rawValue, KKButtonLED.octaveDownRed.rawValue]
        }
        if name == "octaveup" {
            return [KKButtonLED.octaveUpWhite.rawValue, KKButtonLED.octaveUpRed.rawValue]
        }
        return KKButtonLED.allCases.first { $0.protocolName == name }.map { [$0.rawValue] } ?? []
    }

    private static let aliases = [
        "page-left": "pageleft",
        "page-right": "pageright",
        "preset-up": "presetup",
        "preset-down": "presetdown",
        "navup": "navigateup",
        "nav-up": "navigateup",
        "navleft": "navigateleft",
        "nav-left": "navigateleft",
        "navdown": "navigatedown",
        "nav-down": "navigatedown",
        "navright": "navigateright",
        "nav-right": "navigateright",
        "odownwhite": "octavedownwhite",
        "odownred": "octavedownred",
        "oupwhite": "octaveupwhite",
        "oupred": "octaveupred",
    ]
}

public enum KKInputEvent: Equatable, Sendable, CustomStringConvertible {
    case button(name: String, pressed: Bool)
    case touchEncoder(index: Int, touched: Bool)
    case mainEncoderState(UInt8)
    case mainEncoder(delta: Int)
    case rotaryEncoder(index: Int, delta: Int, value: Int)
    case touchStrip(name: String, value: Int)

    public var description: String {
        switch self {
            case let .button(name, pressed):
                "button \(name) \(pressed ? "down" : "up")"
            case let .touchEncoder(index, touched):
                "touch encoder \(index) \(touched ? "on" : "off")"
            case let .mainEncoderState(value):
                String(format: "main encoder state 0x%02x", value)
            case let .mainEncoder(delta):
                "main encoder \(delta > 0 ? "+" : "-") d=\(abs(delta))"
            case let .rotaryEncoder(index, delta, value):
                "rotary encoder \(index) \(delta > 0 ? "+" : "-") d=\(abs(delta)) value=\(value)"
            case let .touchStrip(name, value):
                "touch strip \(name) value=\(value)"
        }
    }
}

public struct KKInputReport: Sendable {
    public var reportID: UInt32
    public var bytes: [UInt8]
    public var previous: [UInt8]?
    public var events: [KKInputEvent]
    public var receptionTimestamp: UInt64

    public init(reportID: UInt32, bytes: [UInt8], previous: [UInt8]?, events: [KKInputEvent], receptionTimestamp: UInt64 = 0) {
        self.reportID = reportID
        self.bytes = bytes
        self.previous = previous
        self.events = events
        self.receptionTimestamp = receptionTimestamp
    }
}

public enum KKInputReportDecoder {
    public static let buttonNames = [
        "main encoder",
        "preset up",
        "enter",
        "preset down",
        "browse",
        "instance",
        "octave down",
        "octave up",
        "stop",
        "rec",
        "play",
        "navigate right",
        "navigate down",
        "navigate left",
        "back",
        "navigate up",
        "shift",
        "scale",
        "arp",
        "loop",
        "page right",
        "page left",
        "rewind",
        "fast forward",
    ]

    public static func hexDump(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    public static func summary(reportID: UInt32, bytes: [UInt8]) -> String {
        guard reportID == KompleteKontrolS25MK1Protocol.inputReportID, bytes.count >= 23 else { return "" }

        func byte(_ offset: Int) -> String {
            String(format: "%02x", bytes[offset])
        }
        func word(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }

        let buttons = (1...3).map { "b\($0):\(byte($0))" }.joined(separator: " ")
        let touchMask = bytes[4]
        let main = "main[b5:\(byte(5)) b6:\(byte(6))]"
        let knobs = (0..<8).map { index -> String in
            let touched = (touchMask & UInt8(1 << index)) != 0
            let mark = touched ? "*" : ""
            return String(format: "k%d%@:%04x", index, mark, word(7 + index * 2))
        }.joined(separator: " ")
        let pitchTail = (23..<min(31, bytes.count)).map { byte($0) }.joined(separator: " ")
        let modTail = (31..<bytes.count).map { byte($0) }.joined(separator: " ")

        return " | r01 btn[\(buttons)] touch8=0x\(byte(4)) \(main) \(knobs) pitch[\(pitchTail)] mod[\(modTail)]"
    }

    public static func events(reportID: UInt32, previous: [UInt8]?, current: [UInt8]) -> [KKInputEvent] {
        guard reportID == KompleteKontrolS25MK1Protocol.inputReportID,
              let previous,
              previous.count == current.count,
              current.count >= 23 else { return [] }
        var events: [KKInputEvent] = []

        for position in 0..<buttonNames.count {
            let wasPressed = reportButtonState(previous, position)
            let isPressed = reportButtonState(current, position)
            if wasPressed != isPressed {
                events.append(.button(name: buttonNames[position], pressed: isPressed))
            }
        }

        let previousTouch = previous[4]
        let currentTouch = current[4]
        for index in 0..<8 {
            let mask = UInt8(1 << index)
            let wasTouched = (previousTouch & mask) != 0
            let isTouched = (currentTouch & mask) != 0
            if wasTouched != isTouched {
                events.append(.touchEncoder(index: index + 1, touched: isTouched))
            }
        }

        if previous.count > 5, current.count > 5, previous[5] != current[5] {
            events.append(.mainEncoderState(current[5]))
        }
        if previous.count > 6, current.count > 6, previous[6] != current[6] {
            let delta = wrappedDelta(from: Int(previous[6]), to: Int(current[6]), modulo: 256)
            if delta != 0 {
                events.append(.mainEncoder(delta: delta))
            }
        }

        for index in 0..<8 {
            let offset = 7 + index * 2
            guard let oldValue = reportWord(previous, offset),
                  let newValue = reportWord(current, offset),
                  oldValue != newValue else { continue }
            let delta = wrappedDelta(from: oldValue, to: newValue)
            if delta != 0 {
                events.append(.rotaryEncoder(index: index + 1, delta: delta, value: newValue))
            }
        }

        if rangeChanged(23..<min(31, current.count), previous: previous, current: current) {
            events.append(.touchStrip(name: "pitch", value: stripValue(current, range: 23..<min(31, current.count))))
        }
        if rangeChanged(31..<current.count, previous: previous, current: current) {
            events.append(.touchStrip(name: "mod", value: stripValue(current, range: 31..<current.count)))
        }

        return events
    }

    private static func rangeChanged(_ range: Range<Int>, previous: [UInt8], current: [UInt8]) -> Bool {
        guard !range.isEmpty else { return false }
        for index in range where previous[index] != current[index] {
            return true
        }
        return false
    }

    private static func stripValue(_ bytes: [UInt8], range: Range<Int>) -> Int {
        guard !range.isEmpty else { return 0 }
        var value = 0
        var shift = 0
        for index in range.prefix(2) {
            value |= Int(bytes[index]) << shift
            shift += 8
        }
        return value
    }

    public static func reportWord(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset + 1 < bytes.count else { return nil }
        return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }

    public static func reportButtonState(_ bytes: [UInt8], _ position: Int) -> Bool {
        let offset = 1 + (position / 8)
        guard offset < bytes.count else { return false }
        return (bytes[offset] & UInt8(1 << (position % 8))) != 0
    }

    public static func wrappedDelta(from old: Int, to new: Int, modulo: Int = 1024) -> Int {
        var delta = new - old
        let half = modulo / 2
        if delta > half {
            delta -= modulo
        } else if delta < -half {
            delta += modulo
        }
        return delta
    }
}

public struct KKUSBResult: Sendable, CustomStringConvertible {
    public var status: Int32
    public var opened: Bool
    public var pipeRef: UInt8
    public var endpointAddress: UInt8
    public var numEndpoints: UInt8
    public var message: String

    public var succeeded: Bool { status == 0 }

    public var description: String {
        let hex = String(format: "0x%08x", UInt32(bitPattern: status))
        return "\(hex) opened=\(opened ? 1 : 0) pipe=\(pipeRef) ep=0x\(String(format: "%02x", endpointAddress)) endpoints=\(numEndpoints) \(message)"
    }

    public init(status: Int32, opened: Bool = false, pipeRef: UInt8 = 0, endpointAddress: UInt8 = 0, numEndpoints: UInt8 = 0, message: String = "") {
        self.status = status
        self.opened = opened
        self.pipeRef = pipeRef
        self.endpointAddress = endpointAddress
        self.numEndpoints = numEndpoints
        self.message = message
    }

    public init(_ result: KontrolUSBResult) {
        var copy = result
        let message = withUnsafeBytes(of: &copy.message) { raw in
            let cString = raw.bindMemory(to: CChar.self).baseAddress!
            return String(cString: cString)
        }
        self.init(
            status: result.status,
            opened: result.opened != 0,
            pipeRef: result.pipeRef,
            endpointAddress: result.endpointAddress,
            numEndpoints: result.numEndpoints,
            message: message
        )
    }
}

public enum KKOutputMode: Sendable {
    case directLibUSB
    case privilegedHelper(executablePath: String? = nil)
}

public enum KKInputMonitorMode: Int, Sendable {
    case off
    case changed
    case all
}

public struct KKMIDIEvent: Sendable, Equatable {
    public enum Kind: Sendable {
        case noteOn
        case noteOff
        case controlChange
        case pitchBend
    }

    public let kind: Kind
    public let channel: UInt8
    public let data1: UInt8
    public let data2: UInt8
    public let receptionTimestamp: UInt64

    public init(kind: Kind, channel: UInt8, note: UInt8, velocity: UInt8, receptionTimestamp: UInt64 = 0) {
        self.kind = kind
        self.channel = channel
        self.data1 = note
        self.data2 = velocity
        self.receptionTimestamp = receptionTimestamp
    }

    public init(control: UInt8, value: UInt8, channel: UInt8, receptionTimestamp: UInt64 = 0) {
        self.kind = .controlChange
        self.channel = channel
        self.data1 = control
        self.data2 = value
        self.receptionTimestamp = receptionTimestamp
    }

    public init(pitchBendLSB: UInt8, msb: UInt8, channel: UInt8, receptionTimestamp: UInt64 = 0) {
        self.kind = .pitchBend
        self.channel = channel
        self.data1 = pitchBendLSB
        self.data2 = msb
        self.receptionTimestamp = receptionTimestamp
    }

    public var note: UInt8 { data1 }
    public var velocity: UInt8 { data2 }
    public var control: UInt8 { data1 }
    public var controlValue: UInt8 { data2 }
    public var pitchBendValue: Int { Int(data1) | (Int(data2) << 7) }
    public var pitchBendCentered: Int { pitchBendValue - 8192 }

    public var description: String {
        switch kind {
            case .noteOn:
                "note on ch \(channel + 1) note \(note) velocity \(velocity)"
            case .noteOff:
                "note off ch \(channel + 1) note \(note) velocity \(velocity)"
            case .controlChange:
                "cc ch \(channel + 1) \(control)=\(controlValue)"
            case .pitchBend:
                "pitch bend ch \(channel + 1) \(pitchBendCentered)"
        }
    }
}

public enum KKTiming {
    public static var traceEnabled: Bool {
        #if KK_DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["LOGLEVEL"]?.uppercased() == "TRACE"
            || env["KK_DAEMON_DEBUG"] == "1"
            || env["KK_USB_DEBUG"] == "1"
        #else
        return false
        #endif
    }

    public static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    public static func msSince(_ start: UInt64) -> String {
        String(format: "%.3fms", Double(now() - start) / 1_000_000.0)
    }

    public static func short(_ payload: [UInt8]) -> String {
        payload.prefix(8).map(KKHex.byte).joined(separator: " ")
    }
}

private enum KKStderrLogLevel: String {
    case error = "ERROR"
    case info = "INFO"
    case debug = "DEBUG"
    case trace = "TRACE"
}

private enum KKStderrLog {
    private static let lock = NSLock()
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func write(group: String, level: KKStderrLogLevel, _ message: String) {
        let cleanMessage = message.replacingOccurrences(of: "\n", with: "\\n")
        lock.lock()
        let timestamp = formatter.string(from: Date())
        fputs("timestamp=\(timestamp) group=\(group) level=\(level.rawValue) message=\(cleanMessage)\n", stderr)
        fflush(stderr)
        lock.unlock()
    }
}

public final class KompleteKontrolS25MK1: @unchecked Sendable {
    public var onInputReport: (@Sendable (KKInputReport) -> Void)?
    public var onMIDIEvent: (@Sendable (KKMIDIEvent) -> Void)?
    public var onMountChanged: (@Sendable (Bool) -> Void)?
    public var log: (@Sendable (String) -> Void)?
    public var monitorMode: KKInputMonitorMode = .changed

    public private(set) var maxInputReportSize = 0
    public private(set) var maxOutputReportSize = 0
    public private(set) var guide = [UInt8](repeating: 0, count: 3 * KompleteKontrolS25MK1Protocol.keyCount)
    public private(set) var buttonLEDs = [UInt8](repeating: 0, count: KKButtonLED.protocolNames.count)
    public private(set) var displayFrame = KKDisplayFrame()

    private let outputMode: KKOutputMode
    private var hidManager: IOHIDManager?
    private var hidDevice: IOHIDDevice?
    private var inputBuffer: UnsafeMutablePointer<UInt8>?
    private var inputBufferLength = 0
    private var lastReports: [UInt32: [UInt8]] = [:]
    private var daemonSurfaceIncludesReportID: Bool?
    private var inputRunLoop: CFRunLoop?
    private var inputThread: Thread?
    private var inputUsesDaemon = false
    private var autoMountTask: Task<Void, Never>?
    private var helperSession: KKDaemonOutputSession?
    private let helperSessionLock = NSLock()
    private var surfaceReplayPending = true
    private var clientRegistrationAnnouncementShown = false
    private var clientRegisteredWithSession = false
    private var sessionConnectionAnnounced = false
    private let outputQueueCondition = NSCondition()
    private var outputWorkerThread: Thread?
    private var outputWorkerShouldStop = false
    private var outputWritePending = false
    private var pendingOutputs: [Int: (reportID: UInt8, payload: [UInt8])] = [:]
    private var pendingOutputOrder: [Int] = []

    public init(outputMode: KKOutputMode = .privilegedHelper()) {
        self.outputMode = outputMode
    }

    deinit {
        close()
    }

    public var isOpen: Bool {
        hidDevice != nil
    }

    public var usesPrivilegedDaemonTransport: Bool {
        if case .privilegedHelper = outputMode, geteuid() != 0 {
            return true
        }
        return false
    }

    public func open(logOpen: Bool = true) throws {
        guard mountIfAvailable(logOpen: logOpen) else {
            throw KKDriverError.openFailed
        }
    }

    public func openWithRetry(logOpen: Bool = true, attempts: Int = 20) throws {
        for attempt in 0..<attempts {
            if mountIfAvailable(logOpen: logOpen && attempt == 0) {
                return
            }
            usleep(100_000)
        }
        throw KKDriverError.openFailed
    }

    @discardableResult
    public func mountIfAvailable(logOpen: Bool = false) -> Bool {
        guard hidDevice == nil else { return true }
        guard let opened = Self.openHIDDevice(logOpen: logOpen, logger: log) else { return false }
        install(opened)
        scheduleInputIfMonitoring()
        log?("Komplete Kontrol mounted.")
        onMountChanged?(true)
        return true
    }

    public func startAutoMount(logOpen: Bool = false, intervalMs: UInt64 = 1_000) {
        guard autoMountTask == nil else { return }
        autoMountTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if !self.isOpen {
                    _ = self.mountIfAvailable(logOpen: logOpen)
                }
                try? await Task.sleep(nanoseconds: intervalMs * 1_000_000)
            }
        }
    }

    public func startInputMonitoring() {
        guard inputThread == nil else { return }
        if usesPrivilegedDaemonTransport {
            inputUsesDaemon = true
            let thread = Thread { [weak self] in
                Thread.current.qualityOfService = .userInteractive
                self?.runDaemonInputLoop()
            }
            thread.qualityOfService = .userInteractive
            thread.stackSize = 1 << 20
            inputThread = thread
            thread.start()
            return
        }
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
        autoMountTask?.cancel()
        autoMountTask = nil
        stopOutputWorker()
        inputUsesDaemon = false
        daemonSurfaceIncludesReportID = nil
        closeHelperSession(sendQuit: true)
        if let runLoop = inputRunLoop {
            CFRunLoopStop(runLoop)
        }
        if let device = hidDevice {
            IOHIDDeviceClose(device, Self.openOptions)
        }
        if let manager = hidManager {
            IOHIDManagerClose(manager, Self.openOptions)
        }
        inputBuffer?.deallocate()
        inputBuffer = nil
        inputThread = nil
        inputRunLoop = nil
        hidDevice = nil
        hidManager = nil
    }

    @discardableResult
    public func handshake() -> KKUSBResult {
        sendInterruptOutput(reportID: KompleteKontrolS25MK1Protocol.initReportID, payload: [0x00, 0x00])
    }

    public func handshakeAsync() {
        enqueueInterruptOutput(reportID: KompleteKontrolS25MK1Protocol.initReportID, payload: [0x00, 0x00])
    }

    public func performOutputBatch(_ updates: () -> Void) {
        updates()
    }

    @discardableResult
    public func sendGuide() -> KKUSBResult {
        sendInterruptOutput(reportID: KompleteKontrolS25MK1Protocol.lightGuideReportID, payload: guide)
    }

    public func sendGuideAsync() {
        enqueueInterruptOutput(reportID: KompleteKontrolS25MK1Protocol.lightGuideReportID, payload: guide)
    }

    @discardableResult
    public func sendButtonLEDs() -> KKUSBResult {
        sendInterruptOutput(reportID: KompleteKontrolS25MK1Protocol.buttonLEDReportID, payload: buttonLEDs)
    }

    public func sendButtonLEDsAsync() {
        enqueueInterruptOutput(reportID: KompleteKontrolS25MK1Protocol.buttonLEDReportID, payload: buttonLEDs)
    }

    @discardableResult
    public func setKey(_ index: Int, color: KKRGB, flush: Bool = true) -> KKUSBResult? {
        guard (0..<KompleteKontrolS25MK1Protocol.keyCount).contains(index) else { return nil }
        guide[3 * index] = color.red
        guide[3 * index + 1] = color.green
        guide[3 * index + 2] = color.blue
        return flush ? sendGuide() : nil
    }

    @discardableResult
    public func setAllKeys(color: KKRGB, flush: Bool = true) -> KKUSBResult? {
        guide = (0..<KompleteKontrolS25MK1Protocol.keyCount).flatMap { _ in [color.red, color.green, color.blue] }
        return flush ? sendGuide() : nil
    }

    @discardableResult
    public func setButtonLED(index: Int, value: UInt8, flush: Bool = true) -> KKUSBResult? {
        guard (0..<buttonLEDs.count).contains(index) else { return nil }
        buttonLEDs[index] = value
        return flush ? sendButtonLEDs() : nil
    }

    @discardableResult
    public func setButtonLED(name: String, value: UInt8, flush: Bool = true, parseNumber: (String) -> Int? = KKHex.parse) -> KKUSBResult? {
        let indices = KKButtonLED.indices(for: name, parseNumber: parseNumber)
        guard !indices.isEmpty else { return nil }
        for index in indices {
            buttonLEDs[index] = value
        }
        return flush ? sendButtonLEDs() : nil
    }

    @discardableResult
    public func setAllButtonLEDs(value: UInt8, flush: Bool = true) -> KKUSBResult? {
        buttonLEDs = Array(repeating: value, count: buttonLEDs.count)
        return flush ? sendButtonLEDs() : nil
    }

    @discardableResult
    public func clearButtonLEDs() -> KKUSBResult? {
        setAllButtonLEDs(value: 0)
    }

    @discardableResult
    public func clearKeys() -> KKUSBResult {
        guide = Array(repeating: 0, count: guide.count)
        return sendGuide()
    }

    @discardableResult
    public func displayAllSegmentsOn() -> [KKUSBResult] {
        displayFrame.clear()
        for display in 0..<KKDisplayFrame.displayCount {
            displayFrame.fillDisplay(display)
        }
        return sendDisplays()
    }

    @discardableResult
    public func clearDisplays(flush: Bool = true) -> [KKUSBResult] {
        displayFrame.clear()
        return flush ? sendDisplays() : []
    }

    public func clearDisplaysAsync() {
        displayFrame.clear()
        sendDisplaysAsync()
    }

    @discardableResult
    public func setDisplayText(
        _ text: String,
        display: Int,
        row: Int,
        alignment: KKDisplayAlignment = .left,
        flush: Bool = true
    ) -> [KKUSBResult]? {
        guard (0..<KKDisplayFrame.displayCount).contains(display),
              (1..<KKDisplayFrame.rowCount).contains(row) else { return nil }
        displayFrame.setText(text, display: display, row: row, alignment: alignment)
        return flush ? sendDisplays() : nil
    }

    @discardableResult
    public func setDisplayBar(_ value: Double, display: Int, row: Int = 0, flush: Bool = true) -> [KKUSBResult]? {
        guard (0..<KKDisplayFrame.displayCount).contains(display),
              row == 0 else { return nil }
        displayFrame.setBar(value, display: display, row: row)
        return flush ? sendDisplays() : nil
    }

    @discardableResult
    public func setDisplayBox(display: Int, flush: Bool = true) -> [KKUSBResult]? {
        guard (0..<KKDisplayFrame.displayCount).contains(display) else { return nil }
        displayFrame.setBox(display)
        return flush ? sendDisplays() : nil
    }

    @discardableResult
    public func sendDisplays() -> [KKUSBResult] {
        (0..<KKDisplayFrame.rowCount).map { row in
            sendDisplayRow(row, data: displayFrame.rowData(row))
        }
    }

    public func sendDisplaysAsync() {
        for row in 0..<KKDisplayFrame.rowCount {
            sendDisplayRowAsync(row, data: displayFrame.rowData(row))
        }
    }

    @discardableResult
    public func sendDisplayRow(_ row: Int, data: [UInt8]) -> KKUSBResult {
        guard (0..<KKDisplayFrame.rowCount).contains(row) else {
            return KKUSBResult(status: -1, message: "display row out of range")
        }
        return sendInterruptOutput(
            reportID: KompleteKontrolS25MK1Protocol.displayReportID,
            payload: displayRowPayload(row, data: data)
        )
    }

    public func sendDisplayRowAsync(_ row: Int, data: [UInt8]) {
        guard (0..<KKDisplayFrame.rowCount).contains(row) else { return }
        enqueueInterruptOutput(
            reportID: KompleteKontrolS25MK1Protocol.displayReportID,
            payload: displayRowPayload(row, data: data)
        )
    }

    private func displayRowPayload(_ row: Int, data: [UInt8]) -> [UInt8] {
        var rowData = Array(data.prefix(KKDisplayFrame.bytesPerReportRow))
        if rowData.count < KKDisplayFrame.bytesPerReportRow {
            rowData += Array(repeating: 0, count: KKDisplayFrame.bytesPerReportRow - rowData.count)
        }
        let header: [UInt8] = [0x00, 0x00, UInt8(row), 0x00, 0x48, 0x00, 0x01, 0x00]
        return header + rowData
    }

    @discardableResult
    public func runIntroAnimation(steps: UInt32 = 8, intervalMs: UInt32 = 250) -> [KKUSBResult] {
        var results: [KKUSBResult] = []
        results.append(handshake())
        results.append(sendInterruptOutput(reportID: KompleteKontrolS25MK1Protocol.buttonLEDReportID, payload: Array(repeating: 0x7f, count: buttonLEDs.count)))

        let count = steps == 0 ? 8 : steps
        let delay = useconds_t((intervalMs == 0 ? 250 : intervalMs) * 1000)
        for phase in 0..<count {
            var keys = [UInt8](repeating: 0, count: 3 * KompleteKontrolS25MK1Protocol.keyCount)
            for index in 0..<KompleteKontrolS25MK1Protocol.keyCount {
                let lane = (index + Int(phase)) % 6
                keys[index * 3 + 0] = (lane == 0 || lane == 1) ? 0x7f : 0x00
                keys[index * 3 + 1] = (lane == 2 || lane == 3) ? 0x7f : 0x00
                keys[index * 3 + 2] = (lane == 4 || lane == 5) ? 0x7f : 0x00
            }
            results.append(sendInterruptOutput(reportID: KompleteKontrolS25MK1Protocol.lightGuideReportID, payload: keys))
            usleep(delay)
        }

        guide = Array(repeating: 0, count: guide.count)
        buttonLEDs = Array(repeating: 0, count: buttonLEDs.count)
        results.append(sendGuide())
        results.append(sendButtonLEDs())
        return results
    }

    @discardableResult
    public func sendHIDOutputDiagnostic(reportID: UInt8, payload: [UInt8]) -> IOReturn {
        guard let hidDevice else { return kIOReturnNotOpen }
        var payload = payload
        return IOHIDDeviceSetReport(hidDevice, kIOHIDReportTypeOutput, CFIndex(reportID), &payload, payload.count)
    }

    @discardableResult
    public func sendFeatureReport(reportID: UInt8, payload: [UInt8]) -> IOReturn {
        guard let hidDevice else { return kIOReturnNotOpen }
        var payload = payload
        return IOHIDDeviceSetReport(hidDevice, kIOHIDReportTypeFeature, CFIndex(reportID), &payload, payload.count)
    }

    public func daemonRequest(_ line: String, timeoutUsec: useconds_t = 250_000) -> String? {
        guard let session = startHelperSession() else { return nil }
        let requestLine = line.hasSuffix("\n") ? line : line + "\n"
        return requestWithReconnect(session: session, line: requestLine, timeoutUsec: timeoutUsec)
    }

    @discardableResult
    public func sendInterruptOutput(reportID: UInt8, payload: [UInt8]) -> KKUSBResult {
        let result: KKUSBResult
        if case .directLibUSB = outputMode {
            result = Self.writeLibUSB(reportID: reportID, payload: payload)
        } else if geteuid() == 0 {
            result = Self.writeLibUSB(reportID: reportID, payload: payload)
        } else {
            result = writeThroughPrivilegedHelper(reportID: reportID, payload: payload)
        }

        return result
    }

    public func enqueueInterruptOutput(reportID: UInt8, payload: [UInt8]) {
        let payload = payload
        let key = outputQueueKey(reportID: reportID, payload: payload)
        outputQueueCondition.lock()
        if pendingOutputs[key] == nil {
            pendingOutputOrder.append(key)
        }
        pendingOutputs[key] = (reportID: reportID, payload: payload)
        startOutputWorkerLocked()
        outputQueueCondition.signal()
        outputQueueCondition.unlock()
        traceOutput("enqueue key=\(key) report=0x\(KKHex.byte(reportID)) bytes=\(payload.count) head=\(KKTiming.short(payload))")
    }

    private func outputQueueKey(reportID: UInt8, payload: [UInt8]) -> Int {
        if reportID == KompleteKontrolS25MK1Protocol.displayReportID, payload.count > 2 {
            return (Int(reportID) << 16) | Int(payload[2])
        }
        return (Int(reportID) << 16) | 0xffff
    }

    private func startOutputWorkerLocked() {
        guard outputWorkerThread == nil else { return }
        outputWorkerShouldStop = false
        let thread = Thread { [weak self] in
            Thread.current.qualityOfService = .userInitiated
            self?.runOutputWorker()
        }
        thread.name = "KompleteKontrolOutput"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 1 << 20
        outputWorkerThread = thread
        thread.start()
    }

    private func stopOutputWorker() {
        outputQueueCondition.lock()
        outputWorkerShouldStop = true
        pendingOutputs.removeAll(keepingCapacity: false)
        pendingOutputOrder.removeAll(keepingCapacity: false)
        outputQueueCondition.broadcast()
        while let thread = outputWorkerThread, thread !== Thread.current {
            outputQueueCondition.wait()
        }
        outputQueueCondition.unlock()
    }

    private func runOutputWorker() {
        while true {
            outputQueueCondition.lock()
            while pendingOutputOrder.isEmpty && !outputWorkerShouldStop {
                outputQueueCondition.wait()
            }
            if outputWorkerShouldStop {
                outputWorkerThread = nil
                outputQueueCondition.broadcast()
                outputQueueCondition.unlock()
                return
            }
            let order = pendingOutputOrder
            let outputs = order.compactMap { pendingOutputs.removeValue(forKey: $0) }
            pendingOutputOrder.removeAll(keepingCapacity: true)
            outputQueueCondition.unlock()

            for output in outputs {
                let start = KKTiming.now()
                traceOutput("worker begin report=0x\(KKHex.byte(output.reportID)) bytes=\(output.payload.count) head=\(KKTiming.short(output.payload))")
                setOutputWritePending(true)
                _ = sendInterruptOutput(reportID: output.reportID, payload: output.payload)
                setOutputWritePending(false)
                traceOutput("worker end report=0x\(KKHex.byte(output.reportID)) elapsed=\(KKTiming.msSince(start))")
            }
        }
    }

    private func setOutputWritePending(_ pending: Bool) {
        outputQueueCondition.lock()
        outputWritePending = pending
        outputQueueCondition.broadcast()
        outputQueueCondition.unlock()
    }

    private func outputShouldHaveDaemonPriority() -> Bool {
        outputQueueCondition.lock()
        let pending = outputWritePending || !pendingOutputOrder.isEmpty || !pendingOutputs.isEmpty
        outputQueueCondition.unlock()
        return pending
    }

    private func traceOutput(_ message: String) {
        guard KKTiming.traceEnabled else { return }
        log?("kk-output \(message)")
    }

    private func install(_ opened: OpenedHIDDevice, deallocateExistingBuffer: Bool = true) {
        hidManager = opened.manager
        hidDevice = opened.device
        maxInputReportSize = opened.maxInputReportSize
        maxOutputReportSize = opened.maxOutputReportSize
        inputBufferLength = max(opened.maxInputReportSize, 64)
        if deallocateExistingBuffer {
            inputBuffer?.deallocate()
        }
        inputBuffer = .allocate(capacity: inputBufferLength)
        inputBuffer?.initialize(repeating: 0, count: inputBufferLength)
    }

    private func scheduleInputIfMonitoring() {
        guard let runLoop = inputRunLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.scheduleInput(on: runLoop)
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func scheduleInput(on runLoop: CFRunLoop) {
        guard let hidDevice, let inputBuffer else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(hidDevice, inputBuffer, inputBufferLength, kkInputCallback, context)
        IOHIDDeviceScheduleWithRunLoop(hidDevice, runLoop, CFRunLoopMode.defaultMode.rawValue)
    }

    fileprivate func handleInput(reportID: UInt32, report: UnsafePointer<UInt8>, length: CFIndex) {
        guard monitorMode != .off else { return }
        let receptionTimestamp = KKTiming.now()
        let count = Int(length)
        let previous = lastReports[reportID]
        var changedIndices: [Int] = []
        if let previous, previous.count == count {
            for index in 0..<count where previous[index] != report[index] {
                changedIndices.append(index)
            }
            if changedIndices.isEmpty && monitorMode == .changed {
                return
            }
        }
        var current = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            current[index] = report[index]
        }
        lastReports[reportID] = current
        let eventBaseline = previous ?? Self.neutralInputReport(matching: current, reportID: reportID)
        let events = KKInputReportDecoder.events(reportID: reportID, previous: eventBaseline, current: current)
        if monitorMode == .changed && events.isEmpty && changedIndices.isEmpty {
            return
        }
        onInputReport?(KKInputReport(reportID: reportID, bytes: current, previous: previous, events: events, receptionTimestamp: receptionTimestamp))
    }

    private func handleInput(reportID: UInt32, bytes current: [UInt8], receptionTimestamp suppliedTimestamp: UInt64 = 0) {
        guard monitorMode != .off else { return }
        let receptionTimestamp = suppliedTimestamp > 0 ? suppliedTimestamp : KKTiming.now()
        let previous = lastReports[reportID]
        var changedIndices: [Int] = []
        if let previous, previous.count == current.count {
            for index in 0..<current.count where previous[index] != current[index] {
                changedIndices.append(index)
            }
            if changedIndices.isEmpty && monitorMode == .changed {
                return
            }
        }
        lastReports[reportID] = current
        let eventBaseline = previous ?? Self.neutralInputReport(matching: current, reportID: reportID)
        let events = KKInputReportDecoder.events(reportID: reportID, previous: eventBaseline, current: current)
        if monitorMode == .changed && events.isEmpty && changedIndices.isEmpty {
            return
        }
        onInputReport?(KKInputReport(reportID: reportID, bytes: current, previous: previous, events: events, receptionTimestamp: receptionTimestamp))
    }

    private static func parseDaemonPushPayload(_ payload: Substring) -> (timestamp: UInt64, bytes: [UInt8]) {
        var timestamp: UInt64 = 0
        var bytes: [UInt8] = []
        for tokenPart in payload.split(separator: " ") {
            let token = String(tokenPart)
            if token.hasPrefix("@") {
                timestamp = UInt64(String(token.dropFirst()), radix: 16) ?? timestamp
                continue
            }
            if let value = KKHex.parse(token) {
                bytes.append(UInt8(value & 0xff))
            }
        }
        return (timestamp, bytes)
    }

    private static func neutralInputReport(matching current: [UInt8], reportID: UInt32) -> [UInt8]? {
        guard reportID == KompleteKontrolS25MK1Protocol.inputReportID, !current.isEmpty else {
            return nil
        }
        var neutral = [UInt8](repeating: 0, count: current.count)
        neutral[0] = UInt8(reportID & 0xff)
        return neutral
    }

    private func runDaemonInputLoop() {
        var inputSession: KKDaemonOutputSession?
        while inputUsesDaemon {
            if inputSession == nil {
                inputSession = startDaemonInputSession()
                inputSession?.asyncPushHandler = { [weak self] line in
                    guard let self else { return }
                    if line.hasPrefix("in ") {
                        self.handleDaemonSurfaceResponse(line)
                    } else if line.hasPrefix("midi ") {
                        self.handleDaemonMIDIResponse(line)
                    }
                }
            }
            guard let session = inputSession else {
                log?("Komplete Kontrol libusb daemon unavailable for input.")
                usleep(500_000)
                continue
            }
            if !session.readPushes(timeoutUsec: 50_000) {
                inputSession = nil
                usleep(50_000)
            }
        }
    }

    private func startDaemonInputSession() -> KKDaemonOutputSession? {
        guard case let .privilegedHelper(executablePath) = outputMode else {
            return nil
        }
        if !KompleteKontrolLibUSBServer.daemonSocketIsAvailable() {
            log?("Komplete Kontrol libusb daemon not running; requesting administrator startup.")
            guard KompleteKontrolLibUSBServer.startDaemonWithAdministratorPrivileges(executablePath: executablePath, logger: log) else {
                log?("Komplete Kontrol libusb daemon startup failed.")
                return nil
            }
        }
        guard let session = KKDaemonOutputSession(socketPath: KompleteKontrolLibUSBServer.defaultDaemonSocketPath) else {
            return nil
        }
        guard KompleteKontrolLibUSBServer.sessionHasCurrentProtocol(session) else {
            return nil
        }
        return session
    }

    private func handleDaemonReconnectResponse(_ response: String, source: String) -> Bool {
        guard Self.daemonResponseRequiresReconnect(response) else { return false }
        log?("Komplete Kontrol daemon \(source) device dropped; reconnecting.")
        closeHelperSession(sendQuit: false)
        return true
    }

    private func handleDaemonSurfaceResponse(_ response: String) {
        if response == "timeout" {
            return
        }
        guard response.hasPrefix("in ") else {
            if response.hasPrefix("err ") {
                log?("Komplete Kontrol daemon input error: \(response)")
                usleep(50_000)
            }
            return
        }
        let payload = Self.parseDaemonPushPayload(response.dropFirst(3))
        guard !payload.bytes.isEmpty else { return }
        handleInput(
            reportID: KompleteKontrolS25MK1Protocol.inputReportID,
            bytes: normalizedDaemonSurfaceBytes(payload.bytes),
            receptionTimestamp: payload.timestamp
        )
    }

    private func normalizedDaemonSurfaceBytes(_ bytes: [UInt8]) -> [UInt8] {
        if daemonSurfaceIncludesReportID == nil {
            daemonSurfaceIncludesReportID = bytes.first == UInt8(KompleteKontrolS25MK1Protocol.inputReportID)
        }
        if daemonSurfaceIncludesReportID == true {
            return bytes
        }
        return [UInt8(KompleteKontrolS25MK1Protocol.inputReportID)] + bytes
    }

    private func handleDaemonMIDIResponse(_ response: String) {
        if response == "timeout" {
            return
        }
        guard response.hasPrefix("midi ") else {
            if response.hasPrefix("err ") {
                log?("Komplete Kontrol daemon MIDI error: \(response)")
                usleep(50_000)
            }
            return
        }
        let payload = Self.parseDaemonPushPayload(response.dropFirst(5))
        let receptionTimestamp = payload.timestamp > 0 ? payload.timestamp : KKTiming.now()
        for event in Self.parseUSBMIDIEvents(payload.bytes, receptionTimestamp: receptionTimestamp) {
            onMIDIEvent?(event)
        }
    }

    private static func parseUSBMIDIEvents(_ bytes: [UInt8], receptionTimestamp: UInt64 = 0) -> [KKMIDIEvent] {
        guard bytes.count >= 4 else { return [] }
        var events: [KKMIDIEvent] = []
        var offset = 0
        while offset + 3 < bytes.count {
            let status = bytes[offset + 1]
            let note = bytes[offset + 2]
            let velocity = bytes[offset + 3]
            let channel = status & 0x0f
            switch status & 0xf0 {
                case 0x90 where velocity > 0:
                    events.append(KKMIDIEvent(kind: .noteOn, channel: channel, note: note, velocity: velocity, receptionTimestamp: receptionTimestamp))
                case 0x90, 0x80:
                    events.append(KKMIDIEvent(kind: .noteOff, channel: channel, note: note, velocity: velocity, receptionTimestamp: receptionTimestamp))
                case 0xb0:
                    events.append(KKMIDIEvent(control: note, value: velocity, channel: channel, receptionTimestamp: receptionTimestamp))
                case 0xe0:
                    events.append(KKMIDIEvent(pitchBendLSB: note, msb: velocity, channel: channel, receptionTimestamp: receptionTimestamp))
                default:
                    break
            }
            offset += 4
        }
        return events
    }

    private func detachHIDDeviceForReconnect() {
        guard let oldDevice = hidDevice else { return }
        let oldManager = hidManager
        let oldBuffer = inputBuffer
        hidDevice = nil
        hidManager = nil
        inputBuffer = nil
        inputBufferLength = 0
        lastReports.removeAll(keepingCapacity: true)

        if let runLoop = inputRunLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                IOHIDDeviceUnscheduleFromRunLoop(oldDevice, runLoop, CFRunLoopMode.defaultMode.rawValue)
                IOHIDDeviceClose(oldDevice, Self.openOptions)
                if let oldManager {
                    IOHIDManagerClose(oldManager, Self.openOptions)
                }
                oldBuffer?.deallocate()
            }
            CFRunLoopWakeUp(runLoop)
        } else {
            IOHIDDeviceClose(oldDevice, Self.openOptions)
            if let oldManager {
                IOHIDManagerClose(oldManager, Self.openOptions)
            }
            oldBuffer?.deallocate()
        }
    }

    private func writeThroughPrivilegedHelper(reportID: UInt8, payload: [UInt8]) -> KKUSBResult {
        guard let session = startHelperSession() else {
            return KKUSBResult(status: -1, message: "privileged output helper unavailable")
        }
        let line = (["write", KKHex.byte(reportID)] + payload.map(KKHex.byte)).joined(separator: " ") + "\n"
        let start = KKTiming.now()
        traceOutput("helper request begin report=0x\(KKHex.byte(reportID)) bytes=\(payload.count)")
        guard let response = requestWithReconnect(session: session, line: line) else {
            closeHelperSession(sendQuit: false)
            traceOutput("helper request failed report=0x\(KKHex.byte(reportID)) elapsed=\(KKTiming.msSince(start))")
            return KKUSBResult(status: -1, message: "Komplete Kontrol libusb daemon did not respond")
        }
        traceOutput("helper request end report=0x\(KKHex.byte(reportID)) response=\(response) elapsed=\(KKTiming.msSince(start))")
        if response == "ok" {
            return KKUSBResult(status: 0, opened: true, endpointAddress: 0x02, message: "ok")
        }
        return KKUSBResult(status: -1, message: response)
    }

    private func requestWithReconnect(session: KKDaemonOutputSession, line: String, timeoutUsec: useconds_t = 250_000) -> String? {
        guard let response = session.request(line, timeoutUsec: timeoutUsec) else {
            return reconnectAndRequest(line, timeoutUsec: timeoutUsec)
        }
        guard Self.daemonResponseRequiresReconnect(response) else {
            return response
        }
        traceOutput("helper device dropped response=\(response); reconnecting")
        return reconnectAndRequest(line, timeoutUsec: timeoutUsec)
    }

    private func startHelperSession() -> KKDaemonOutputSession? {
        helperSessionLock.lock()
        defer { helperSessionLock.unlock() }
        if let helperSession {
            return helperSession
        }
        guard case let .privilegedHelper(executablePath) = outputMode else {
            return nil
        }

        if !KompleteKontrolLibUSBServer.daemonSocketIsAvailable() {
            log?("Komplete Kontrol libusb daemon not running; requesting administrator startup.")
            guard KompleteKontrolLibUSBServer.startDaemonWithAdministratorPrivileges(executablePath: executablePath, logger: log) else {
                log?("Komplete Kontrol libusb daemon startup failed.")
                return nil
            }
        }

        guard let session = KKDaemonOutputSession(socketPath: KompleteKontrolLibUSBServer.defaultDaemonSocketPath) else {
            log?("Komplete Kontrol libusb daemon unavailable. Install/start launchd daemon once.")
            return nil
        }

        if !KompleteKontrolLibUSBServer.sessionHasCurrentProtocol(session) {
            log?("Komplete Kontrol libusb daemon is outdated; requesting administrator restart.")
            _ = session.request("quit\n", timeoutUsec: 50_000)
            guard KompleteKontrolLibUSBServer.startDaemonWithAdministratorPrivileges(executablePath: executablePath, forceRestart: true, logger: log),
                  let restarted = KKDaemonOutputSession(socketPath: KompleteKontrolLibUSBServer.defaultDaemonSocketPath),
                  KompleteKontrolLibUSBServer.sessionHasCurrentProtocol(restarted) else {
                log?("Komplete Kontrol libusb daemon restart failed.")
                return nil
            }
            helperSession = restarted
            sessionConnectionAnnounced = true
            log?("Komplete Kontrol libusb daemon connected.")
            registerClient(on: restarted)
            replaySurfaceState(on: restarted)
            return restarted
        }

        helperSession = session
        if !sessionConnectionAnnounced {
            sessionConnectionAnnounced = true
            log?("Komplete Kontrol libusb daemon connected.")
        }
        registerClient(on: session)
        replaySurfaceState(on: session)
        return session
    }

    private func closeHelperSession(sendQuit: Bool) {
        helperSessionLock.lock()
        let session = helperSession
        helperSession = nil
        surfaceReplayPending = true
        clientRegisteredWithSession = false
        helperSessionLock.unlock()
        if sendQuit {
            unregisterClient(on: session)
        }
    }

    private func reconnectAndRequest(_ line: String, timeoutUsec: useconds_t = 250_000) -> String? {
        closeHelperSession(sendQuit: false)
        guard let session = startHelperSession() else { return nil }
        return session.request(line, timeoutUsec: timeoutUsec)
    }

    private static func daemonResponseRequiresReconnect(_ response: String) -> Bool {
        response.hasPrefix("err -4 ") || response.hasPrefix("err -5 ") || response.hasPrefix("err -6 ")
    }

    private func replaySurfaceState(on session: KKDaemonOutputSession) {
        guard surfaceReplayPending else { return }
        surfaceReplayPending = false
        _ = session.request((["write", KKHex.byte(KompleteKontrolS25MK1Protocol.initReportID), "00", "00"]).joined(separator: " ") + "\n")
        _ = session.request((["write", KKHex.byte(KompleteKontrolS25MK1Protocol.lightGuideReportID)] + guide.map(KKHex.byte)).joined(separator: " ") + "\n")
        _ = session.request((["write", KKHex.byte(KompleteKontrolS25MK1Protocol.buttonLEDReportID)] + buttonLEDs.map(KKHex.byte)).joined(separator: " ") + "\n")
        for row in 0..<KKDisplayFrame.rowCount {
            let payload = displayRowPayload(row, data: displayFrame.rowData(row))
            _ = session.request((["write", KKHex.byte(KompleteKontrolS25MK1Protocol.displayReportID)] + payload.map(KKHex.byte)).joined(separator: " ") + "\n")
        }
    }

    private func registerClient(on session: KKDaemonOutputSession) {
        guard !clientRegisteredWithSession else { return }
        let name = ProcessInfo.processInfo.processName
        let pid = getpid()
        let shouldPauseForInitialAnnouncement = !clientRegistrationAnnouncementShown
        clientRegistrationAnnouncementShown = true
        let response = session.request("register \(pid) \(KKHex.utf8(name))\n", timeoutUsec: 750_000)
        if response == "ok registered" {
            clientRegisteredWithSession = true
            if shouldPauseForInitialAnnouncement {
                log?("Komplete Kontrol daemon registered client \(name) pid=\(pid).")
                usleep(180_000)
            }
        } else if let response {
            log?("Komplete Kontrol daemon client registration returned: \(response)")
        } else {
            log?("Komplete Kontrol daemon client registration timed out.")
        }
    }

    private func unregisterClient(on session: KKDaemonOutputSession?) {
        guard let session else { return }
        let name = ProcessInfo.processInfo.processName
        _ = session.request("unregister \(getpid()) \(KKHex.utf8(name))\n", timeoutUsec: 500_000)
    }

    private static let openOptions = IOOptionBits(kIOHIDOptionsTypeSeizeDevice)

    private static func openHIDDevice(logOpen: Bool, logger: (@Sendable (String) -> Void)?) -> OpenedHIDDevice? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, openOptions)
        IOHIDManagerSetDeviceMatching(
            manager,
            [
                kIOHIDVendorIDKey: KompleteKontrolS25MK1Protocol.vendorID,
                kIOHIDProductIDKey: KompleteKontrolS25MK1Protocol.productID,
            ] as CFDictionary
        )
        let managerResult = IOHIDManagerOpen(manager, openOptions)
        guard managerResult == kIOReturnSuccess,
              let device = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first else {
            if logOpen {
                logger?("IOHIDManagerOpen -> \(String(format: "0x%08x", managerResult))")
            }
            IOHIDManagerClose(manager, openOptions)
            return nil
        }
        let openResult = IOHIDDeviceOpen(device, openOptions)
        if logOpen {
            logger?("IOHIDDeviceOpen(seize) -> \(String(format: "0x%08x", openResult))")
        }
        guard openResult == kIOReturnSuccess else {
            IOHIDManagerClose(manager, openOptions)
            return nil
        }
        func property(_ key: String) -> Int {
            (IOHIDDeviceGetProperty(device, key as CFString) as? Int) ?? 0
        }
        return OpenedHIDDevice(
            manager: manager,
            device: device,
            maxInputReportSize: property(kIOHIDMaxInputReportSizeKey),
            maxOutputReportSize: property(kIOHIDMaxOutputReportSizeKey)
        )
    }

    private static func writeLibUSB(reportID: UInt8, payload: [UInt8]) -> KKUSBResult {
        var payload = payload
        let result = payload.withUnsafeMutableBufferPointer { buffer in
            KontrolUSBLibUSBWriteReport(reportID, buffer.baseAddress, UInt32(buffer.count))
        }
        return KKUSBResult(result)
    }

    private static func hidDevicePresent() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(
            manager,
            [
                kIOHIDVendorIDKey: KompleteKontrolS25MK1Protocol.vendorID,
                kIOHIDProductIDKey: KompleteKontrolS25MK1Protocol.productID,
            ] as CFDictionary
        )
        guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess else { return false }
        defer { IOHIDManagerClose(manager, 0) }
        return !((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.isEmpty ?? true)
    }
}

public enum KKDriverError: Error {
    case openFailed
}

public enum KompleteKontrolLibUSBServer {
    public static let daemonLabel = "media.vanille.kompletekontrol-libusb"
    public static let defaultDaemonSocketPath = "/var/run/kompletekontrol-libusb.sock"
    public static let daemonLogPath = "/tmp/media.vanille.kompletekontrol-libusb.foreground.log"
    public static let protocolVersion = 3
    private static let daemonLockPath = "/var/run/kompletekontrol-libusb.lock"
    private static let daemonStartLock = NSLock()

    private struct LibUSBKqueueRegistration: Hashable {
        var fd: Int32
        var filter: Int16
    }

    public static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        let args = Array(arguments.dropFirst())
        if args.first == "--kk-libusb-daemon" || args.first == "--libusb-daemon" {
            let socketPath = args.dropFirst().first ?? defaultDaemonSocketPath
            runDaemon(socketPath: socketPath)
        }
        guard args.first == "--kk-libusb-server" || args.first == "--libusb-server" else {
            return false
        }
        guard args.count >= 3 else {
            exit(2)
        }
        run(requestPath: args[1], responsePath: args[2])
    }

    public static func run(requestPath: String, responsePath: String) -> Never {
        guard freopen(requestPath, "r", stdin) != nil else {
            exit(1)
        }
        guard freopen(responsePath, "w", stdout) != nil else {
            exit(1)
        }
        setbuf(stdout, nil)

        while let line = readLine() {
            let tokens = line.split(separator: " ").map(String.init)
            guard let command = tokens.first else { continue }
            if command == "quit" {
                print("ok quit")
                exit(0)
            }
            guard command == "write", tokens.count >= 2, let reportID = KKHex.parse(tokens[1]) else {
                print("err parse")
                continue
            }
            var payload = tokens.dropFirst(2).compactMap { KKHex.parse($0).map { UInt8($0 & 0xff) } }
            let result = payload.withUnsafeMutableBufferPointer { buffer in
                KontrolUSBLibUSBWriteReport(UInt8(reportID & 0xff), buffer.baseAddress, UInt32(buffer.count))
            }
            if result.status == 0 {
                print("ok")
            } else {
                let message = KKUSBResult(result).message.replacingOccurrences(of: "\n", with: " ")
                print("err \(result.status) \(message)")
            }
        }
        exit(0)
    }

    private static let asyncInputCallback: @convention(c) (UnsafePointer<UInt8>?, UInt32, UnsafeMutableRawPointer?) -> Void = { data, length, userData in
        guard let data, let userData else { return }
        let hardware = Unmanaged<DaemonHardware>.fromOpaque(userData).takeUnretainedValue()
        hardware.pushInputToClients(data, length: length)
    }

    private static let asyncMidiCallback: @convention(c) (UnsafePointer<UInt8>?, UInt32, UnsafeMutableRawPointer?) -> Void = { data, length, userData in
        guard let data, let userData else { return }
        let hardware = Unmanaged<DaemonHardware>.fromOpaque(userData).takeUnretainedValue()
        hardware.pushMidiToClients(data, length: length)
    }

    public static func runDaemon(socketPath: String = defaultDaemonSocketPath) -> Never {
        signal(SIGPIPE, SIG_IGN)
        daemonDebugLog("process start pid=\(getpid()) socket=\(socketPath)", group: "daemon")
        daemonDebugLog("process scan begin", group: "daemon")
        let otherPIDs = runningDaemonPIDs().filter { $0 != getpid() }
        daemonDebugLog("process scan complete otherPIDs=\(otherPIDs.map(String.init).joined(separator: ","))", group: "daemon")
        if !otherPIDs.isEmpty {
            daemonLog("refusing to start: other daemon process already running pid=\(otherPIDs.map(String.init).joined(separator: ","))", level: .error)
            exit(6)
        }
        daemonDebugLog("socket probe begin path=\(socketPath)", group: "daemon")
        if daemonSocketIsReachable(socketPath: socketPath) {
            daemonLog("refusing to start: daemon socket already responds at \(socketPath)", level: .error)
            exit(6)
        }
        daemonDebugLog("socket probe complete", group: "daemon")
        daemonDebugLog("lock acquire begin path=\(daemonLockPath)", group: "daemon")
        guard acquireDaemonLock() != nil else {
            daemonLog("refusing to start: another daemon holds \(daemonLockPath)", level: .error)
            exit(6)
        }
        daemonDebugLog("lock acquire complete", group: "daemon")
        unlink(socketPath)
        daemonLog("starting kqueue daemon socket=\(socketPath)")

        let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            daemonLog("socket() failed errno=\(errno)")
            exit(1)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard fillSunPath(&addr, socketPath: socketPath) else {
            daemonLog("socket path too long")
            exit(2)
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(serverFD, sockaddrPointer, sockaddrLength(for: socketPath))
            }
        }
        guard bindResult == 0 else {
            daemonLog("bind failed errno=\(errno)")
            exit(3)
        }
        chmod(socketPath, 0o666)
        guard listen(serverFD, 8) == 0 else {
            daemonLog("listen failed errno=\(errno)")
            exit(4)
        }
        daemonLog("listening")

        let hardware = DaemonHardware()
        hardware.runStartupAnimationThenIdle()
        hardware.startAsyncTransfers()

        let kq = kqueue()
        guard kq >= 0 else {
            daemonLog("kqueue() failed errno=\(errno)")
            exit(5)
        }

        // Register server socket
        var serverKev = kevent(ident: UInt(serverFD), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)
        kevent(kq, &serverKev, 1, nil, 0, nil)
        daemonDebugLog("register server fd=\(serverFD) filter=\(EVFILT_READ)", group: "reactor")

        // Register libusb poll fds
        let initialUsbRegistrations = kqueueRegistrations(for: hardware.currentLibusbPollFds())
        var trackedUsbRegistrations = initialUsbRegistrations
        hardware.updateTrackedLibusbFds(Set(initialUsbRegistrations.map(\.fd)))
        for registration in initialUsbRegistrations {
            var kev = kevent(ident: UInt(registration.fd), filter: registration.filter, flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)
            kevent(kq, &kev, 1, nil, 0, nil)
            daemonDebugLog("register libusb fd=\(registration.fd) filter=\(registration.filter)", group: "reactor")
        }
        daemonLog("tracking \(initialUsbRegistrations.count) libusb kqueue registrations")

        var clientBuffers: [Int32: [UInt8]] = [:]
        var clientIDs: [Int32: Int] = [:]
        var nextClientID = 0
        var events = Array<kevent>(repeating: kevent(ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: nil), count: 32)

        func syncLibUSBRegistrations() {
            let currentRegistrations = kqueueRegistrations(for: hardware.currentLibusbPollFds())
            let toAdd = currentRegistrations.subtracting(trackedUsbRegistrations)
            let toRemove = trackedUsbRegistrations.subtracting(currentRegistrations)
            for registration in toAdd {
                var kev = kevent(ident: UInt(registration.fd), filter: registration.filter, flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)
                kevent(kq, &kev, 1, nil, 0, nil)
                daemonDebugLog("register libusb fd=\(registration.fd) filter=\(registration.filter)", group: "reactor")
            }
            for registration in toRemove {
                var kev = kevent(ident: UInt(registration.fd), filter: registration.filter, flags: UInt16(EV_DELETE), fflags: 0, data: 0, udata: nil)
                kevent(kq, &kev, 1, nil, 0, nil)
                daemonDebugLog("unregister libusb fd=\(registration.fd) filter=\(registration.filter)", group: "reactor")
            }
            if currentRegistrations != trackedUsbRegistrations {
                daemonLog("tracking \(currentRegistrations.count) libusb kqueue registrations")
            }
            trackedUsbRegistrations = currentRegistrations
            hardware.updateTrackedLibusbFds(Set(currentRegistrations.map(\.fd)))
        }

        while true {
            let nReady = events.withUnsafeMutableBufferPointer { buf -> Int32 in
                kevent(kq, nil, 0, buf.baseAddress, Int32(buf.count), nil)
            }

            if nReady < 0 {
                if errno != EINTR {
                    daemonLog("kevent wait failed errno=\(errno)")
                }
                continue
            }
            daemonTraceLog("kevent ready count=\(nReady)", group: "reactor")

            for i in 0..<Int(nReady) {
                let event = events[i]
                let fd = Int32(event.ident)
                daemonTraceLog("event fd=\(fd) filter=\(event.filter) flags=\(event.flags) fflags=\(event.fflags) data=\(event.data)", group: "reactor")

                if fd == serverFD {
                    daemonTraceLog("server fd ready", group: "reactor")
                    let clientFD = accept(serverFD, nil, nil)
                    if clientFD >= 0 {
                        nextClientID += 1
                        _ = fcntl(clientFD, F_SETFL, O_NONBLOCK)
                        clientIDs[clientFD] = nextClientID
                        clientBuffers[clientFD] = []
                        hardware.addClient(fd: clientFD, clientID: nextClientID)
                        var kev = kevent(ident: UInt(clientFD), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)
                        kevent(kq, &kev, 1, nil, 0, nil)
                        daemonLog("client \(nextClientID) connected")
                    }
                } else if hardware.isLibusbFd(fd) {
                    daemonDebugLog("libusb fd ready fd=\(fd) filter=\(event.filter)", group: "reactor")
                    hardware.handleUsbEvents(timeoutMs: 0)
                    syncLibUSBRegistrations()
                } else if clientIDs[fd] != nil {
                    let cid = clientIDs[fd]!
                    daemonTraceLog("client fd ready client=\(cid) fd=\(fd)", group: "client")
                    let shouldClose = processClientCommands(fd, clientID: cid, hardware: hardware, buffer: &clientBuffers[fd, default: []])
                    syncLibUSBRegistrations()
                    if shouldClose {
                        hardware.removeClient(clientID: cid)
                        hardware.disconnect(clientID: cid)
                        var kev = kevent(ident: UInt(fd), filter: Int16(EVFILT_READ), flags: UInt16(EV_DELETE), fflags: 0, data: 0, udata: nil)
                        kevent(kq, &kev, 1, nil, 0, nil)
                        close(fd)
                        clientIDs.removeValue(forKey: fd)
                        clientBuffers.removeValue(forKey: fd)
                        daemonLog("client \(cid) disconnected")
                    }
                }
            }
        }
    }

    private static func kqueueRegistrations(for pollFds: [KontrolUSBPollFd]) -> Set<LibUSBKqueueRegistration> {
        var registrations = Set<LibUSBKqueueRegistration>()
        for pollFd in pollFds {
            var added = false
            if (pollFd.events & UInt16(POLLIN)) != 0 {
                registrations.insert(LibUSBKqueueRegistration(fd: pollFd.fd, filter: Int16(EVFILT_READ)))
                added = true
            }
            if (pollFd.events & UInt16(POLLOUT)) != 0 {
                registrations.insert(LibUSBKqueueRegistration(fd: pollFd.fd, filter: Int16(EVFILT_WRITE)))
                added = true
            }
            if !added {
                registrations.insert(LibUSBKqueueRegistration(fd: pollFd.fd, filter: Int16(EVFILT_READ)))
            }
        }
        return registrations
    }

    private static func processClientCommands(_ fd: Int32, clientID: Int, hardware: DaemonHardware, buffer: inout [UInt8]) -> Bool {
        var scratch = [UInt8](repeating: 0, count: 512)
        let scratchCount = scratch.count
        let count = scratch.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress!, scratchCount)
        }
        if count <= 0 {
            return true
        }
        buffer.append(contentsOf: scratch.prefix(count))

        while let newline = buffer.firstIndex(of: 0x0a) {
            let lineBytes = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let line = String(bytes: lineBytes, encoding: .utf8) else {
                writeDaemonResponse("err utf8", to: fd)
                continue
            }
            daemonTraceLog("client \(clientID) recv \(line)")
            let response = hardware.handle(line, clientID: clientID)
            writeDaemonResponse(response, to: fd)
        }
        return false
    }

    public static func daemonSocketIsAvailable(socketPath: String = defaultDaemonSocketPath) -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        guard let session = KompleteKontrolDaemonClient(socketPath: socketPath) else { return false }
        return sessionHasCurrentProtocol(session)
    }

    private static func daemonSocketIsReachable(socketPath: String = defaultDaemonSocketPath) -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        return KompleteKontrolDaemonClient(socketPath: socketPath) != nil
    }

    fileprivate static func sessionHasCurrentProtocol(_ session: KompleteKontrolDaemonClient) -> Bool {
        guard let response = session.request("version\n", timeoutUsec: 250_000) else {
            return false
        }
        return response == "ok kk-daemon \(protocolVersion)"
    }

    public static func startDaemonWithAdministratorPrivileges(
        executablePath requestedExecutablePath: String? = nil,
        socketPath: String = defaultDaemonSocketPath,
        forceRestart: Bool = false,
        logger: (@Sendable (String) -> Void)? = nil
    ) -> Bool {
        daemonStartLock.lock()
        defer { daemonStartLock.unlock() }

        if !forceRestart && daemonSocketIsAvailable(socketPath: socketPath) {
            return true
        }

        let plistPath = launchdPlistPath()
        let daemonIsInstalled = FileManager.default.fileExists(atPath: plistPath)
        if daemonIsInstalled {
            guard geteuid() == 0 else {
                logger?("Launchd service is installed but not running. Run 'sudo make install-daemon' to restart the system daemon.")
                return false
            }
            return tryStartDaemonViaLaunchctl(socketPath: socketPath, forceRestart: true, logger: logger)
        }

        // Fall back to osascript method for one-time setup
        logger?("Launchd service not found, falling back to osascript method.")
        logger?("Run 'sudo ./install-daemon.sh' in the KompleteKontrol-Swift directory for passwordless daemon startup.")

        guard let executablePath = daemonExecutablePath(requestedExecutablePath) else {
            logger?("No Komplete Kontrol daemon executable found.")
            return false
        }

        var commandParts: [String] = []
        if forceRestart {
            commandParts += [
                "/usr/bin/pkill -f", shellQuote("kk-libusb-daemon"), "2>/dev/null || true", ";",
            ]
        }
        commandParts += [
            "rm -f", shellQuote(socketPath), ";",
            shellQuote(executablePath), "--kk-libusb-daemon", shellQuote(socketPath),
            ">>", shellQuote(daemonLogPath), "2>&1", "&",
        ]
        let command = commandParts.joined(separator: " ")

        let script = "do shell script \(appleScriptString(command)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger?("Failed to request administrator daemon startup: \(error)")
            return false
        }

        guard process.terminationStatus == 0 else {
            logger?("Administrator daemon startup was cancelled or failed with status \(process.terminationStatus).")
            return false
        }

        for _ in 0..<60 {
            if daemonSocketIsAvailable(socketPath: socketPath) {
                return true
            }
            usleep(50_000)
        }
        logger?("Komplete Kontrol daemon did not create \(socketPath). See \(daemonLogPath).")
        return false
    }

    private static func tryStartDaemonViaLaunchctl(socketPath: String, forceRestart: Bool, logger: (@Sendable (String) -> Void)?) -> Bool {
        let plistPath = launchdPlistPath()
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: plistPath) else {
            return false
        }

        logger?("Found launchd service at \(plistPath)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")

        if forceRestart {
            process.arguments = ["kickstart", "-k", "system/\(daemonLabel)"]
            logger?("Restarting daemon via launchctl...")
        } else {
            process.arguments = ["bootstrap", "system", plistPath]
            logger?("Starting daemon via launchctl...")
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger?("Failed to run launchctl: \(error)")
            return false
        }

        // Wait for socket to appear
        for _ in 0..<60 {
            if daemonSocketIsAvailable(socketPath: socketPath) {
                logger?("Daemon started successfully via launchctl")
                return true
            }
            usleep(50_000)
        }

        logger?("Daemon did not start via launchctl, socket not found")
        return false
    }

    private static func launchdPlistPath() -> String {
        "/Library/LaunchDaemons/\(daemonLabel).plist"
    }

    private static func acquireDaemonLock() -> Int32? {
        let fd = Darwin.open(daemonLockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard fd >= 0 else {
            daemonLog("daemon lock open failed path=\(daemonLockPath) errno=\(errno)")
            return nil
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    private static func runningDaemonPIDs() -> [pid_t] {
        let patterns = [
            "KontrolProbe .*--kk-libusb-daemon",
            "KontrolProbe .*--libusb-daemon",
        ]
        var candidates = Set<pid_t>()
        for pattern in patterns {
            for pid in pgrep(pattern: pattern) {
                candidates.insert(pid)
            }
        }
        return candidates
            .compactMap { pid -> pid_t? in
                guard let command = commandLine(for: pid),
                      isDaemonProcessCommand(command) else {
                    return nil
                }
                return pid
            }
            .sorted()
    }

    private static func pgrep(pattern: String) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            daemonLog("daemon process scan failed pattern=\(pattern): \(error)")
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus == 1 {
            return []
        }
        guard process.terminationStatus == 0 else {
            daemonLog("daemon process scan failed pattern=\(pattern) status=\(process.terminationStatus)", level: .error)
            return []
        }
        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func commandLine(for pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            daemonLog("daemon process command scan failed pid=\(pid): \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        let command = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    private static func isDaemonProcessCommand(_ command: String) -> Bool {
        let executable = command
            .split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map(String.init) ?? ""
        let executableName = URL(fileURLWithPath: executable).lastPathComponent
        let ignoredWrappers: Set<String> = ["sudo", "sh", "zsh", "bash", "make", "awk", "env", "pgrep"]
        guard !ignoredWrappers.contains(executableName) else {
            return false
        }
        return command.contains("--kk-libusb-daemon") || command.contains("--libusb-daemon")
    }

    private final class DaemonHardware: @unchecked Sendable {
        private struct RegisteredClient {
            var pid: Int32
            var name: String
        }

        private enum PushKind {
            case input
            case midi
        }

        private let lock = NSLock()
        private let maxQueuedPushes = 64
        private let transientClaim = ProcessInfo.processInfo.environment["KK_DAEMON_TRANSIENT_CLAIM"] == "1"
        private var libusbSession: KontrolUSBLibUSBSessionRef?
        private var asyncTransfersStarted = false
        private var registeredClients: [Int: RegisteredClient] = [:]
        private var activeClientID: Int?
        private var clientFDs: [Int: Int32] = [:]
        private var trackedLibusbFds: Set<Int32> = []
        private var queuedInputMessages: [String] = []
        private var queuedMIDIMessages: [String] = []

        deinit {
            if let libusbSession {
                KontrolUSBLibUSBSessionClose(libusbSession)
            }
        }

        func handle(_ line: String, clientID: Int) -> String {
            let tokens = line.split(separator: " ").map(String.init)
            guard let command = tokens.first else { return "err parse" }
            guard command != "quit" else { return "ok quit" }
            if command == "version" {
                return "ok kk-daemon \(protocolVersion)"
            }

            if command == "register" {
                return register(tokens: tokens, clientID: clientID)
            }
            if command == "unregister" {
                return unregister(clientID: clientID)
            }

            if transientClaim {
                return KompleteKontrolLibUSBServer.handleDaemonCommand(line, session: nil, transientClaim: true)
            }

            if command == "read" {
                guard ensureSession() != nil else { return "timeout" }
                handleUsbEvents(timeoutMs: 0)
                return dequeueQueuedInputMessage() ?? "timeout"
            }
            if command == "midiread" {
                guard ensureSession() != nil else { return "timeout" }
                handleUsbEvents(timeoutMs: 0)
                return dequeueQueuedMIDIMessage() ?? "timeout"
            }

            guard let session = ensureSession() else {
                return "err no session"
            }

            let response = KompleteKontrolLibUSBServer.handleDaemonCommand(line, session: session)
            dropSession(session, after: response)
            return response
        }

        func disconnect(clientID: Int) {
            let nextClient: RegisteredClient?
            let shouldRefreshDisplay: Bool
            lock.lock()
            guard registeredClients.removeValue(forKey: clientID) != nil else {
                lock.unlock()
                return
            }
            if activeClientID == clientID {
                activeClientID = registeredClients.keys.sorted().last
                nextClient = activeClientID.flatMap { registeredClients[$0] }
                shouldRefreshDisplay = true
            } else {
                nextClient = nil
                shouldRefreshDisplay = false
            }
            lock.unlock()

            daemonLog("client \(clientID) registration removed on disconnect")
            if shouldRefreshDisplay {
                if let nextClient {
                    showConnectedClient(nextClient)
                } else {
                    showNoClient()
                }
            }
        }

        func runStartupAnimationThenIdle() {
            runStartupAnimation()
            showNoClient()
        }

        private func register(tokens: [String], clientID: Int) -> String {
            guard tokens.count >= 3,
                  let pidValue = Int32(tokens[1]),
                  let name = KKHex.decodeUTF8Hex(tokens[2]),
                  !name.isEmpty else {
                return "err register"
            }
            let client = RegisteredClient(pid: pidValue, name: name)
            lock.lock()
            registeredClients[clientID] = client
            activeClientID = clientID
            queuedInputMessages.removeAll()
            queuedMIDIMessages.removeAll()
            lock.unlock()

            daemonLog("client \(clientID) registered name=\(name) pid=\(pidValue)")
            showConnectedClient(client)
            return "ok registered"
        }

        private func unregister(clientID: Int) -> String {
            let nextClient: RegisteredClient?
            let shouldRefreshDisplay: Bool
            lock.lock()
            guard let client = registeredClients.removeValue(forKey: clientID) else {
                lock.unlock()
                return "ok unregistered"
            }
            if activeClientID == clientID {
                activeClientID = registeredClients.keys.sorted().last
                nextClient = activeClientID.flatMap { registeredClients[$0] }
                shouldRefreshDisplay = true
            } else {
                nextClient = nil
                shouldRefreshDisplay = false
            }
            lock.unlock()

            daemonLog("client \(clientID) unregistered name=\(client.name) pid=\(client.pid)")
            if shouldRefreshDisplay {
                if let nextClient {
                    showConnectedClient(nextClient)
                } else {
                    showNoClient()
                }
            }
            return "ok unregistered"
        }

        private func ensureSession() -> KontrolUSBLibUSBSessionRef? {
            lock.lock()
            if let libusbSession {
                lock.unlock()
                return libusbSession
            }
            lock.unlock()

            var session: KontrolUSBLibUSBSessionRef?
            let result = KontrolUSBLibUSBSessionOpen(&session)
            let message = KKUSBResult(result).message.replacingOccurrences(of: "\n", with: " ")
            daemonLog("hardware session open status=\(result.status) ep=0x\(String(format: "%02x", result.endpointAddress)) \(message)")
            guard result.status == 0, let session else {
                return nil
            }

            lock.lock()
            if let existingSession = libusbSession {
                lock.unlock()
                KontrolUSBLibUSBSessionClose(session)
                return existingSession
            }
            libusbSession = session
            lock.unlock()

            startAsyncTransfersIfNeeded(session)
            return session
        }

        private func shouldDropSession(after response: String) -> Bool {
            response.hasPrefix("err -4 ") || response.hasPrefix("err -5 ") || response.hasPrefix("err -6 ")
        }

        private func dropSession(_ session: KontrolUSBLibUSBSessionRef, after response: String) {
            guard shouldDropSession(after: response) else { return }
            lock.lock()
            let shouldClose = libusbSession == session
            if shouldClose {
                libusbSession = nil
                asyncTransfersStarted = false
            }
            lock.unlock()
            if shouldClose {
                KontrolUSBLibUSBSessionClose(session)
            }
        }

        private func runStartupAnimation() {
            guard let session = ensureSession() else { return }
            writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.initReportID, payload: [0x00, 0x00])

            var allButtons = [UInt8](repeating: 0x7f, count: KKButtonLED.protocolNames.count)
            writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.buttonLEDReportID, payload: allButtons)
            var flashGuide = startupRainbowGuide()
            writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.lightGuideReportID, payload: flashGuide)
            usleep(120_000)

            allButtons = [UInt8](repeating: 0, count: KKButtonLED.protocolNames.count)
            writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.buttonLEDReportID, payload: allButtons)

            flashGuide = [UInt8](repeating: 0, count: 3 * KompleteKontrolS25MK1Protocol.keyCount)
            writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.lightGuideReportID, payload: flashGuide)
        }

        private func startupRainbowGuide() -> [UInt8] {
            let keyCount = KompleteKontrolS25MK1Protocol.keyCount
            return (0..<keyCount).flatMap { index -> [UInt8] in
                let position = Double(index) / Double(max(1, keyCount - 1))
                let hue = (265.0 + position * 320.0).truncatingRemainder(dividingBy: 360.0)
                let color = KKRGB.hsv(hue, 0.78, 0.48)
                return [
                    UInt8(min(0x7f, Int(color.red))),
                    UInt8(min(0x7f, Int(color.green))),
                    UInt8(min(0x7f, Int(color.blue))),
                ]
            }
        }

        private func showConnectedClient(_ client: RegisteredClient) {
            guard let session = ensureSession() else { return }
            let name = String(client.name.prefix(8)).uppercased()
            let pid = "PID \(client.pid)"
            var frame = KKDisplayFrame()
            frame.setText(name, display: 0, row: 1, alignment: .center)
            frame.setText(String(pid.prefix(8)), display: 0, row: 2, alignment: .center)
            frame.setText("CONNECTED", display: 1, row: 1, alignment: .center)
            writeDarkSurface(session: session, displayFrame: frame)
        }

        private func showNoClient() {
            guard let session = ensureSession() else { return }
            var frame = KKDisplayFrame()
            frame.setText("NO", display: 0, row: 1, alignment: .center)
            frame.setText("CLIENT", display: 0, row: 2, alignment: .center)
            writeDarkSurface(session: session, displayFrame: frame)
        }

        private func writeDarkSurface(session: KontrolUSBLibUSBSessionRef, displayFrame: KKDisplayFrame) {
            let emptyGuide = [UInt8](repeating: 0, count: 3 * KompleteKontrolS25MK1Protocol.keyCount)
            writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.lightGuideReportID, payload: emptyGuide)
            let emptyButtons = [UInt8](repeating: 0, count: KKButtonLED.protocolNames.count)
            writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.buttonLEDReportID, payload: emptyButtons)
            for row in 0..<KKDisplayFrame.rowCount {
                let payload = KompleteKontrolLibUSBServer.displayRowPayload(row, data: displayFrame.rowData(row))
                writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.displayReportID, payload: payload)
            }
        }

        private func writeReport(session: KontrolUSBLibUSBSessionRef, reportID: UInt8, payload: [UInt8]) {
            var payload = payload
            daemonTraceLog("write report begin report=0x\(KKHex.byte(reportID)) bytes=\(payload.count) head=\(KKTiming.short(payload))", group: "usb-out")
            let start = KKTiming.now()
            let result = payload.withUnsafeMutableBufferPointer { buffer in
                KontrolUSBLibUSBSessionWrite(session, reportID, buffer.baseAddress, UInt32(buffer.count))
            }
            daemonTraceLog("write report end report=0x\(KKHex.byte(reportID)) status=\(result.status) elapsed=\(KKTiming.msSince(start))", group: "usb-out")
        }

        func addClient(fd: Int32, clientID: Int) {
            lock.lock()
            clientFDs[clientID] = fd
            lock.unlock()
        }

        func removeClient(clientID: Int) {
            lock.lock()
            clientFDs.removeValue(forKey: clientID)
            lock.unlock()
        }

        func startAsyncTransfers() {
            guard let session = ensureSession() else { return }
            startAsyncTransfersIfNeeded(session)
        }

        private func startAsyncTransfersIfNeeded(_ session: KontrolUSBLibUSBSessionRef) {
            lock.lock()
            guard !asyncTransfersStarted else {
                lock.unlock()
                return
            }
            asyncTransfersStarted = true
            lock.unlock()

            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            let inputStatus = KontrolUSBLibUSBSessionStartAsyncInput(session, KompleteKontrolLibUSBServer.asyncInputCallback, selfPtr)
            let midiStatus = KontrolUSBLibUSBSessionStartAsyncMIDI(session, KompleteKontrolLibUSBServer.asyncMidiCallback, selfPtr)

            lock.lock()
            asyncTransfersStarted = inputStatus == 0 || midiStatus == 0
            lock.unlock()
            daemonLog("async transfers started input=\(inputStatus) midi=\(midiStatus)", group: "usb")
        }

        func handleUsbEvents(timeoutMs: Int) {
            lock.lock()
            let session = libusbSession
            lock.unlock()
            guard let session else {
                daemonDebugLog("handle_events skipped: no session", group: "usb")
                return
            }
            daemonTraceLog("handle_events begin timeoutMs=\(timeoutMs)", group: "usb")
            KontrolUSBLibUSBHandleEventsTimeout(session, Int32(timeoutMs))
            daemonTraceLog("handle_events end timeoutMs=\(timeoutMs)", group: "usb")
        }

        func currentLibusbPollFds() -> [KontrolUSBPollFd] {
            lock.lock()
            let session = libusbSession
            lock.unlock()
            guard let session else {
                daemonTraceLog("pollfds skipped: no session", group: "usb")
                return []
            }
            var pollFds = [KontrolUSBPollFd](repeating: KontrolUSBPollFd(), count: 8)
            let count = pollFds.withUnsafeMutableBufferPointer { buf in
                KontrolUSBLibUSBSessionGetPollFds(session, buf.baseAddress, Int32(buf.count))
            }
            let result = Array(pollFds.prefix(Int(max(0, count))))
            let summary = result
                .map { "fd=\($0.fd)/events=0x\(String(format: "%04x", Int($0.events)))" }
                .joined(separator: ",")
            daemonTraceLog("pollfds count=\(result.count) \(summary)", group: "usb")
            return result
        }

        func isLibusbFd(_ fd: Int32) -> Bool {
            trackedLibusbFds.contains(fd)
        }

        func updateTrackedLibusbFds(_ fds: Set<Int32>) {
            trackedLibusbFds = fds
        }

        fileprivate func pushInputToClients(_ data: UnsafePointer<UInt8>, length: UInt32) {
            let timestamp = KKTiming.now()
            let hex = (0..<Int(length)).map { KKHex.byte(data[$0]) }.joined(separator: " ")
            daemonDebugLog("async input len=\(length) head=\((0..<min(Int(length), 12)).map { KKHex.byte(data[$0]) }.joined(separator: " "))", group: "surface", level: .info)
            pushToClients("in @\(String(timestamp, radix: 16)) \(hex)", kind: .input)
        }

        fileprivate func pushMidiToClients(_ data: UnsafePointer<UInt8>, length: UInt32) {
            let timestamp = KKTiming.now()
            let hex = (0..<Int(length)).map { KKHex.byte(data[$0]) }.joined(separator: " ")
            daemonDebugLog("async midi len=\(length) head=\((0..<min(Int(length), 12)).map { KKHex.byte(data[$0]) }.joined(separator: " "))", group: "midi", level: .info)
            pushToClients("midi @\(String(timestamp, radix: 16)) \(hex)", kind: .midi)
        }

        private func pushToClients(_ message: String, kind: PushKind) {
            lock.lock()
            switch kind {
                case .input:
                    queuedInputMessages.append(message)
                    trimQueuedMessages(&queuedInputMessages)
                case .midi:
                    queuedMIDIMessages.append(message)
                    trimQueuedMessages(&queuedMIDIMessages)
            }
            let fds = Array(clientFDs.values)
            lock.unlock()
            daemonTraceLog("push clients=\(fds.count) message=\(message)", group: "client")
            let bytes = Array((message + "\n").utf8)
            for fd in fds {
                bytes.withUnsafeBytes { raw in
                    _ = Darwin.write(fd, raw.baseAddress, bytes.count)
                }
            }
        }

        private func dequeueQueuedInputMessage() -> String? {
            lock.lock()
            defer { lock.unlock() }
            guard !queuedInputMessages.isEmpty else { return nil }
            return queuedInputMessages.removeFirst()
        }

        private func dequeueQueuedMIDIMessage() -> String? {
            lock.lock()
            defer { lock.unlock() }
            guard !queuedMIDIMessages.isEmpty else { return nil }
            return queuedMIDIMessages.removeFirst()
        }

        private func trimQueuedMessages(_ messages: inout [String]) {
            if messages.count > maxQueuedPushes {
                messages.removeFirst(messages.count - maxQueuedPushes)
            }
        }
    }

    private static func displayRowPayload(_ row: Int, data: [UInt8]) -> [UInt8] {
        var rowData = Array(data.prefix(KKDisplayFrame.bytesPerReportRow))
        if rowData.count < KKDisplayFrame.bytesPerReportRow {
            rowData += Array(repeating: 0, count: KKDisplayFrame.bytesPerReportRow - rowData.count)
        }
        return [0x00, 0x00, UInt8(row), 0x00, 0x48, 0x00, 0x01, 0x00] + rowData
    }

    private static func handleDaemonCommand(_ line: String, session: KontrolUSBLibUSBSessionRef?, transientClaim: Bool = false) -> String {
        let tokens = line.split(separator: " ").map(String.init)
        guard let command = tokens.first else { return "err parse" }
        guard command != "quit" else { return "ok quit" }
        if command == "version" {
            return "ok kk-daemon \(protocolVersion)"
        }

        if command == "status" {
            if transientClaim {
                return "ok transient-claim"
            }
            guard let session else { return "err no session" }
            let result = KontrolUSBLibUSBSessionStatus(session)
            let message = KKUSBResult(result).message.replacingOccurrences(of: "\n", with: " ")
            if result.status == 0 {
                return "ok \(message)"
            }
            return "err \(result.status) \(message)"
        }

        if command == "read" {
            guard let session else { return "timeout" }
            let timeoutMs = tokens.dropFirst().first.flatMap(KKHex.parse).map { UInt32(max(1, min($0, 1000))) } ?? 100
            var bytes = [UInt8](repeating: 0, count: 64)
            var transferred: UInt32 = 0
            let readStart = KKTiming.now()
            let result = bytes.withUnsafeMutableBufferPointer { buffer in
                KontrolUSBLibUSBSessionRead(session, buffer.baseAddress, UInt32(buffer.count), &transferred, timeoutMs)
            }
            if result.status != -7 {
                daemonTraceLog("libusb read status=\(result.status) transferred=\(transferred) timeoutMs=\(timeoutMs) elapsed=\(KKTiming.msSince(readStart))")
            }
            if result.status == -7 {
                return "timeout"
            }
            guard result.status == 0, transferred > 0 else {
                let message = KKUSBResult(result).message.replacingOccurrences(of: "\n", with: " ")
                return "err \(result.status) \(message)"
            }
            return (["in"] + bytes.prefix(Int(transferred)).map(KKHex.byte)).joined(separator: " ")
        }

        if command == "midiread" {
            guard let session else { return "timeout" }
            let timeoutMs = tokens.dropFirst().first.flatMap(KKHex.parse).map { UInt32(max(1, min($0, 1000))) } ?? 20
            var bytes = [UInt8](repeating: 0, count: 128)
            var transferred: UInt32 = 0
            let readStart = KKTiming.now()
            let result = bytes.withUnsafeMutableBufferPointer { buffer in
                KontrolUSBLibUSBSessionReadMIDI(session, buffer.baseAddress, UInt32(buffer.count), &transferred, timeoutMs)
            }
            if result.status != -7 {
                daemonTraceLog("libusb midi read status=\(result.status) transferred=\(transferred) timeoutMs=\(timeoutMs) elapsed=\(KKTiming.msSince(readStart))")
            }
            if result.status == -7 {
                return "timeout"
            }
            guard result.status == 0, transferred > 0 else {
                let message = KKUSBResult(result).message.replacingOccurrences(of: "\n", with: " ")
                return "err \(result.status) \(message)"
            }
            return (["midi"] + bytes.prefix(Int(transferred)).map(KKHex.byte)).joined(separator: " ")
        }

        guard command == "write", tokens.count >= 2, let reportID = KKHex.parse(tokens[1]) else {
            return "err parse"
        }
        var payload = tokens.dropFirst(2).compactMap { KKHex.parse($0).map { UInt8($0 & 0xff) } }
        daemonTraceLog("libusb write begin report=0x\(KKHex.byte(UInt8(reportID & 0xff))) bytes=\(payload.count) head=\(KKTiming.short(payload))")
        let writeStart = KKTiming.now()
        let result: KontrolUSBResult
        if transientClaim {
            result = payload.withUnsafeMutableBufferPointer { buffer in
                KontrolUSBLibUSBWriteReport(UInt8(reportID & 0xff), buffer.baseAddress, UInt32(buffer.count))
            }
        } else {
            guard let session else { return "err no session" }
            result = payload.withUnsafeMutableBufferPointer { buffer in
                KontrolUSBLibUSBSessionWrite(session, UInt8(reportID & 0xff), buffer.baseAddress, UInt32(buffer.count))
            }
        }
        daemonTraceLog("libusb write end report=0x\(KKHex.byte(UInt8(reportID & 0xff))) status=\(result.status) elapsed=\(KKTiming.msSince(writeStart))")
        if result.status == 0 {
            return "ok"
        }
        let message = KKUSBResult(result).message.replacingOccurrences(of: "\n", with: " ")
        return "err \(result.status) \(message)"
    }

    private static func writeDaemonResponse(_ response: String, to fd: Int32) {
        let bytes = Array((response + "\n").utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: written), bytes.count - written)
            }
            guard count > 0 else { return }
            written += count
        }
    }

    private static func logDaemonCommand(_ line: String, response: String, clientID: Int) {
        let command = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.hasPrefix("read ") && response == "timeout" {
            return
        }
        if command.hasPrefix("midiread ") && response == "timeout" {
            return
        }
        if command.hasPrefix("read ") && response.hasPrefix("in ") {
            daemonTraceLog("client \(clientID) read -> \(response)", group: "client")
            return
        }
        if command.hasPrefix("midiread ") && response.hasPrefix("midi ") {
            daemonTraceLog("client \(clientID) midiread -> \(response)", group: "client")
            return
        }
        if command.hasPrefix("write ") {
            daemonTraceLog("client \(clientID) \(command) -> \(response)", group: "client")
        } else {
            daemonLog("client \(clientID) \(command) -> \(response)", group: "client")
        }
    }

    private static func daemonLog(
        _ message: @autoclosure () -> String,
        group: String = "daemon",
        level: KKStderrLogLevel = .info
    ) {
        #if KK_DEBUG
        KKStderrLog.write(group: group, level: level, message())
        #else
        guard ProcessInfo.processInfo.environment["KK_DAEMON_LOG"] == "1" else { return }
        KKStderrLog.write(group: group, level: level, message())
        #endif
    }

    private static func daemonDebugLog(
        _ message: @autoclosure () -> String,
        group: String = "daemon",
        level: KKStderrLogLevel = .debug
    ) {
        #if KK_DEBUG
        guard KKTiming.traceEnabled else { return }
        KKStderrLog.write(group: group, level: level, message())
        #endif
    }

    private static func daemonTraceLog(_ message: @autoclosure () -> String, group: String = "daemon") {
        #if KK_DEBUG
        daemonDebugLog(message(), group: group, level: .trace)
        #endif
    }

    fileprivate static func fillSunPath(_ addr: inout sockaddr_un, socketPath: String) -> Bool {
        let path = Array(socketPath.utf8CString)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.count <= capacity else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for index in 0..<capacity {
                    destination[index] = 0
                }
                for index in 0..<path.count {
                    destination[index] = CChar(path[index])
                }
            }
        }
        return true
    }

    fileprivate static func sockaddrLength(for socketPath: String) -> socklen_t {
        socklen_t(MemoryLayout<sa_family_t>.size + Array(socketPath.utf8CString).count)
    }

    private static func daemonExecutablePath(_ requestedExecutablePath: String?) -> String? {
        let fileManager = FileManager.default
        let currentExecutable = CommandLine.arguments.first
        let currentExecutableDirectory = currentExecutable.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        }
        let candidates = [
            requestedExecutablePath,
            currentExecutableDirectory.map { $0 + "/KontrolProbe" },
            fileManager.currentDirectoryPath + "/.build/debug/KontrolProbe",
            currentExecutable?.hasSuffix("/KontrolProbe") == true ? currentExecutable : nil,
        ].compactMap { $0 }

        return candidates.compactMap { path -> String? in
            let absolutePath: String
            if path.hasPrefix("/") {
                absolutePath = path
            } else {
                absolutePath = URL(fileURLWithPath: fileManager.currentDirectoryPath)
                    .appendingPathComponent(path)
                    .standardizedFileURL
                    .path
            }
            return fileManager.isExecutableFile(atPath: absolutePath) ? absolutePath : nil
        }
        .first
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public enum KKHex {
    public static func parse(_ string: String) -> Int? {
        if string.hasPrefix("0x") {
            return Int(string.dropFirst(2), radix: 16)
        }
        if string.hasPrefix("#") {
            return Int(string.dropFirst())
        }
        return Int(string, radix: 16)
    }

    public static func byte(_ value: UInt8) -> String {
        String(format: "%02x", value)
    }

    public static func byte(_ value: Int) -> String {
        String(format: "%02x", value & 0xff)
    }

    public static func utf8(_ value: String) -> String {
        value.utf8.map { byte($0) }.joined()
    }

    public static func decodeUTF8Hex(_ value: String) -> String? {
        guard value.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

private struct OpenedHIDDevice {
    var manager: IOHIDManager
    var device: IOHIDDevice
    var maxInputReportSize: Int
    var maxOutputReportSize: Int
}

public final class KompleteKontrolDaemonClient: @unchecked Sendable {
    let fd: Int32
    var responseBuffer: [UInt8] = []
    private let lock = NSLock()
    public var asyncPushHandler: ((String) -> Void)?

    public init?(socketPath: String = KompleteKontrolLibUSBServer.defaultDaemonSocketPath) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard KompleteKontrolLibUSBServer.fillSunPath(&addr, socketPath: socketPath) else {
            close(fd)
            return nil
        }

        let status = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, KompleteKontrolLibUSBServer.sockaddrLength(for: socketPath))
            }
        }
        guard status == 0 else {
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    public func request(_ line: String, timeoutUsec: useconds_t = 250_000) -> String? {
        let start = KKTiming.now()
        let command = line.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        let lockedAt = KKTiming.now()
        defer { lock.unlock() }
        guard sendLine(line) else {
            trace("request send failed command=\(command) lockWait=\(String(format: "%.3fms", Double(lockedAt - start) / 1_000_000.0))")
            return nil
        }
        let response = readResponse(timeoutUsec: timeoutUsec)
        if !((command.hasPrefix("read ") || command.hasPrefix("midiread ")) && response == "timeout") {
            trace("request command=\(command) response=\(response ?? "nil") lockWait=\(String(format: "%.3fms", Double(lockedAt - start) / 1_000_000.0)) elapsed=\(KKTiming.msSince(start))")
        }
        return response
    }

    private func trace(_ message: @autoclosure () -> String) {
        #if KK_DEBUG
        guard KKTiming.traceEnabled else { return }
        KKStderrLog.write(group: "client", level: .trace, message())
        #endif
    }

    private func sendLine(_ line: String) -> Bool {
        let bytes = Array(line.utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: written), bytes.count - written)
            }
            if count <= 0 {
                return false
            }
            written += count
        }
        return true
    }

    private func readResponse(timeoutUsec: useconds_t = 250_000) -> String? {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutUsec) / 1_000_000.0)
        while Date() < deadline {
            if let newline = responseBuffer.firstIndex(of: 0x0a) {
                let lineBytes = responseBuffer.prefix(upTo: newline)
                responseBuffer.removeSubrange(...newline)
                let line = String(bytes: lineBytes, encoding: .utf8)
                // Dispatch async push messages to handler, keep reading for actual response
                if let line, (line.hasPrefix("in ") || line.hasPrefix("midi ")) {
                    asyncPushHandler?(line)
                    continue
                }
                return line
            }

            var scratch = [UInt8](repeating: 0, count: 512)
            let scratchCount = scratch.count
            let count = scratch.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!, scratchCount)
            }
            if count > 0 {
                responseBuffer.append(contentsOf: scratch.prefix(count))
            } else if count == 0 {
                return nil
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                guard waitForReadable(until: deadline) else { return nil }
            } else {
                return nil
            }
        }
        return nil
    }

    @discardableResult
    public func readPushes(timeoutUsec: useconds_t = 1_000_000) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutUsec) / 1_000_000.0)
        while Date() < deadline {
            if let newline = responseBuffer.firstIndex(of: 0x0a) {
                let lineBytes = responseBuffer.prefix(upTo: newline)
                responseBuffer.removeSubrange(...newline)
                if let line = String(bytes: lineBytes, encoding: .utf8) {
                    asyncPushHandler?(line)
                }
                continue
            }

            var scratch = [UInt8](repeating: 0, count: 512)
            let scratchCount = scratch.count
            let count = scratch.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!, scratchCount)
            }
            if count > 0 {
                responseBuffer.append(contentsOf: scratch.prefix(count))
            } else if count == 0 {
                return false
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                guard waitForReadable(until: deadline) else { return true }
            } else {
                return false
            }
        }
        return true
    }

    private func waitForReadable(until deadline: Date) -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        let timeoutMs = Int32(max(1, min(remaining * 1000.0, Double(Int32.max))))
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, timeoutMs)
        guard result > 0 else { return false }
        let readableEvents = Int16(POLLIN | POLLERR | POLLHUP)
        return (descriptor.revents & readableEvents) != 0
    }
}

private typealias KKDaemonOutputSession = KompleteKontrolDaemonClient

private final class KKAdminOutputSession {
    let directory: String
    let requestPath: String
    let responsePath: String
    let requestFD: Int32
    let responseFD: Int32
    var responseBuffer: [UInt8] = []

    init(directory: String, requestPath: String, responsePath: String, requestFD: Int32, responseFD: Int32) {
        self.directory = directory
        self.requestPath = requestPath
        self.responsePath = responsePath
        self.requestFD = requestFD
        self.responseFD = responseFD
    }

    deinit {
        _ = sendLine("quit\n")
        close(requestFD)
        close(responseFD)
        unlink(requestPath)
        unlink(responsePath)
        rmdir(directory)
    }

    func sendLine(_ line: String) -> Bool {
        let bytes = Array(line.utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { raw in
                Darwin.write(requestFD, raw.baseAddress!.advanced(by: written), bytes.count - written)
            }
            if count <= 0 {
                return false
            }
            written += count
        }
        return true
    }

    func readResponse(timeoutUsec: useconds_t = 5_000_000) -> String? {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutUsec) / 1_000_000.0)
        while Date() < deadline {
            if let newline = responseBuffer.firstIndex(of: 0x0a) {
                let lineBytes = responseBuffer.prefix(upTo: newline)
                responseBuffer.removeSubrange(...newline)
                return String(bytes: lineBytes, encoding: .utf8)
            }

            var scratch = [UInt8](repeating: 0, count: 512)
            let scratchCount = scratch.count
            let count = scratch.withUnsafeMutableBytes { raw in
                Darwin.read(responseFD, raw.baseAddress!, scratchCount)
            }
            if count > 0 {
                responseBuffer.append(contentsOf: scratch.prefix(count))
            } else if count == 0 {
                usleep(10_000)
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(10_000)
            } else {
                return nil
            }
        }
        return nil
    }
}

private let kkInputCallback: IOHIDReportCallback = { context, _, _, _, reportID, report, length in
    guard let context else { return }
    let device = Unmanaged<KompleteKontrolS25MK1>.fromOpaque(context).takeUnretainedValue()
    device.handleInput(reportID: reportID, report: report, length: length)
}

private enum KKFIFO {
    static func open(_ path: String, flags: Int32, timeoutUsec: useconds_t = 5_000_000) -> Int32 {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutUsec) / 1_000_000.0)
        while Date() < deadline {
            let fd = Darwin.open(path, flags)
            if fd >= 0 {
                return fd
            }
            if errno != ENXIO && errno != ENOENT {
                break
            }
            usleep(50_000)
        }
        return -1
    }
}

private enum KKShell {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private enum KKProcess {
    static func currentExecutablePath() -> String {
        let raw = CommandLine.arguments[0]
        if raw.hasPrefix("/") {
            return raw
        }
        return URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
            .path
    }
}
