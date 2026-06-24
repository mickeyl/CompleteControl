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

    private static let plusGlyph: UInt16 = 0x5a00
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
        for row in 0..<Self.rowCount {
            for column in 0..<Self.characterCount {
                setGlyph(glyph, display: display, row: row, column: column)
            }
        }
    }

    public mutating func setText(_ text: String, display: Int, row: Int, alignment: KKDisplayAlignment = .left) {
        guard Self.validDisplay(display), Self.validRow(row) else { return }
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
        guard Self.validDisplay(display), Self.validRow(row) else { return }
        let clamped = max(0.0, min(1.0, value))
        if row == 0 {
            let lit = Int((clamped * 9.0).rounded())
            writeByte(display: display, row: 0, byte: 0, value: 0x04 | (lit > 0 ? 0x03 : 0x00))
            for column in 1..<8 {
                writeByte(display: display, row: 0, byte: column * 2, value: lit > column ? 0x03 : 0x00)
            }
            writeByte(display: display, row: 0, byte: 15, value: lit > 8 ? 0x03 : 0x00)
        } else {
            let lit = Int((clamped * Double(Self.characterCount)).rounded())
            for column in 0..<Self.characterCount {
                setGlyph(column < lit ? Self.plusGlyph : Self.emptyGlyph, display: display, row: row, column: column)
            }
        }
    }

    public mutating func setBox(_ display: Int) {
        guard Self.validDisplay(display) else { return }
        setText("+------+", display: display, row: 0, alignment: .left)
        setText("| SID  |", display: display, row: 1, alignment: .left)
        setText("+------+", display: display, row: 2, alignment: .left)
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
        ProcessInfo.processInfo.environment["LOGLEVEL"]?.uppercased() == "TRACE"
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
              (0..<KKDisplayFrame.rowCount).contains(row) else { return nil }
        displayFrame.setText(text, display: display, row: row, alignment: alignment)
        return flush ? sendDisplays() : nil
    }

    @discardableResult
    public func setDisplayBar(_ value: Double, display: Int, row: Int = 0, flush: Bool = true) -> [KKUSBResult]? {
        guard (0..<KKDisplayFrame.displayCount).contains(display),
              (0..<KKDisplayFrame.rowCount).contains(row) else { return nil }
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
        let events = KKInputReportDecoder.events(reportID: reportID, previous: previous, current: current)
        if monitorMode == .changed && events.isEmpty && changedIndices.isEmpty {
            return
        }
        onInputReport?(KKInputReport(reportID: reportID, bytes: current, previous: previous, events: events, receptionTimestamp: receptionTimestamp))
    }

    private func handleInput(reportID: UInt32, bytes current: [UInt8]) {
        guard monitorMode != .off else { return }
        let receptionTimestamp = KKTiming.now()
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
        let events = KKInputReportDecoder.events(reportID: reportID, previous: previous, current: current)
        if monitorMode == .changed && events.isEmpty && changedIndices.isEmpty {
            return
        }
        onInputReport?(KKInputReport(reportID: reportID, bytes: current, previous: previous, events: events, receptionTimestamp: receptionTimestamp))
    }

    private func runDaemonInputLoop() {
        while inputUsesDaemon {
            guard let session = startHelperSession() else {
                log?("Komplete Kontrol libusb daemon unavailable for input.")
                usleep(500_000)
                continue
            }
            guard let response = session.request("read 10\n", timeoutUsec: 100_000) else {
                closeHelperSession(sendQuit: false)
                usleep(250_000)
                continue
            }
            if handleDaemonReconnectResponse(response, source: "input") {
                usleep(80_000)
                continue
            }
            handleDaemonSurfaceResponse(response)

            guard let midiResponse = session.request("midiread 2\n", timeoutUsec: 50_000) else {
                closeHelperSession(sendQuit: false)
                usleep(50_000)
                continue
            }
            if handleDaemonReconnectResponse(midiResponse, source: "MIDI") {
                usleep(80_000)
                continue
            }
            handleDaemonMIDIResponse(midiResponse)
        }
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
        let bytes = response
            .dropFirst(3)
            .split(separator: " ")
            .compactMap { KKHex.parse(String($0)).map { UInt8($0 & 0xff) } }
        guard !bytes.isEmpty else { return }
        handleInput(reportID: KompleteKontrolS25MK1Protocol.inputReportID, bytes: bytes)
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
        let receptionTimestamp = KKTiming.now()
        let bytes = response
            .dropFirst(5)
            .split(separator: " ")
            .compactMap { KKHex.parse(String($0)).map { UInt8($0 & 0xff) } }
        for event in Self.parseUSBMIDIEvents(bytes, receptionTimestamp: receptionTimestamp) {
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
    private static let daemonStartLock = NSLock()

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

    public static func runDaemon(socketPath: String = defaultDaemonSocketPath) -> Never {
        signal(SIGPIPE, SIG_IGN)
        unlink(socketPath)
        daemonLog("starting foreground daemon socket=\(socketPath)")

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
        var clientID = 0
        while true {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else {
                usleep(50_000)
                continue
            }
            clientID += 1
            daemonLog("client \(clientID) connected")
            let acceptedID = clientID
            let thread = Thread {
                handleDaemonClient(clientFD, clientID: acceptedID, hardware: hardware)
                daemonLog("client \(acceptedID) disconnected")
                hardware.disconnect(clientID: acceptedID)
                close(clientFD)
            }
            thread.name = "KompleteKontrolDaemonClient-\(acceptedID)"
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    public static func daemonSocketIsAvailable(socketPath: String = defaultDaemonSocketPath) -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        guard let session = KompleteKontrolDaemonClient(socketPath: socketPath) else { return false }
        return sessionHasCurrentProtocol(session)
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

        // First, try to use launchctl if the daemon is already installed as a launchd service
        if tryStartDaemonViaLaunchctl(socketPath: socketPath, forceRestart: forceRestart, logger: logger) {
            return true
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
                "/usr/bin/pkill -f --", shellQuote("--kk-libusb-daemon " + socketPath), "2>/dev/null || true", ";",
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
        let plistPath = "/Library/LaunchDaemons/\(daemonLabel).plist"
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
            process.arguments = ["start", "system/\(daemonLabel)"]
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

    private final class DaemonHardware: @unchecked Sendable {
        private struct RegisteredClient {
            var pid: Int32
            var name: String
        }

        private let lock = NSLock()
        private let transientClaim = ProcessInfo.processInfo.environment["KK_DAEMON_TRANSIENT_CLAIM"] == "1"
        private var libusbSession: KontrolUSBLibUSBSessionRef?
        private var registeredClients: [Int: RegisteredClient] = [:]
        private var activeClientID: Int?

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

            lock.lock()
            defer { lock.unlock() }

            if command == "register" {
                return register(tokens: tokens, clientID: clientID)
            }
            if command == "unregister" {
                return unregister(clientID: clientID)
            }

            if transientClaim {
                return KompleteKontrolLibUSBServer.handleDaemonCommand(line, session: nil, transientClaim: true)
            }

            guard let session = ensureSession() else {
                return "err no session"
            }

            let response = KompleteKontrolLibUSBServer.handleDaemonCommand(line, session: session)
            if shouldDropSession(after: response) {
                KontrolUSBLibUSBSessionClose(session)
                libusbSession = nil
            }
            return response
        }

        func disconnect(clientID: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard registeredClients.removeValue(forKey: clientID) != nil else { return }
            daemonLog("client \(clientID) registration removed on disconnect")
            if activeClientID == clientID {
                activeClientID = registeredClients.keys.sorted().last
                if let activeClientID, let active = registeredClients[activeClientID] {
                    showConnectedClient(active)
                } else {
                    showNoClient()
                }
            }
        }

        func runStartupAnimationThenIdle() {
            lock.lock()
            defer { lock.unlock() }
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
            registeredClients[clientID] = client
            activeClientID = clientID
            daemonLog("client \(clientID) registered name=\(name) pid=\(pidValue)")
            showConnectedClient(client)
            return "ok registered"
        }

        private func unregister(clientID: Int) -> String {
            guard let client = registeredClients.removeValue(forKey: clientID) else {
                return "ok unregistered"
            }
            daemonLog("client \(clientID) unregistered name=\(client.name) pid=\(client.pid)")
            if activeClientID == clientID {
                activeClientID = registeredClients.keys.sorted().last
                if let activeClientID, let active = registeredClients[activeClientID] {
                    showConnectedClient(active)
                } else {
                    showNoClient()
                }
            }
            return "ok unregistered"
        }

        private func ensureSession() -> KontrolUSBLibUSBSessionRef? {
            if let libusbSession {
                return libusbSession
            }
            var session: KontrolUSBLibUSBSessionRef?
            let result = KontrolUSBLibUSBSessionOpen(&session)
            let message = KKUSBResult(result).message.replacingOccurrences(of: "\n", with: " ")
            daemonLog("hardware session open status=\(result.status) ep=0x\(String(format: "%02x", result.endpointAddress)) \(message)")
            guard result.status == 0, let session else {
                return nil
            }
            libusbSession = session
            return session
        }

        private func shouldDropSession(after response: String) -> Bool {
            response.hasPrefix("err -4 ") || response.hasPrefix("err -5 ") || response.hasPrefix("err -6 ")
        }

        private func runStartupAnimation() {
            guard let session = ensureSession() else { return }
            writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.initReportID, payload: [0x00, 0x00])

            var allButtons = [UInt8](repeating: 0x7f, count: KKButtonLED.protocolNames.count)
            writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.buttonLEDReportID, payload: allButtons)
            var flashGuide = (0..<KompleteKontrolS25MK1Protocol.keyCount).flatMap { index -> [UInt8] in
                let color = KKRGB.hsv(Double(index) / Double(KompleteKontrolS25MK1Protocol.keyCount) * 360.0, 1.0, 0.8)
                return [color.red, color.green, color.blue]
            }
            writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.lightGuideReportID, payload: flashGuide)
            usleep(120_000)

            allButtons = [UInt8](repeating: 0, count: KKButtonLED.protocolNames.count)
            writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.buttonLEDReportID, payload: allButtons)

            let keyCount = KompleteKontrolS25MK1Protocol.keyCount
            for index in 0..<keyCount {
                writeStartupSweep(session: session, center: index)
                usleep(18_000)
            }
            for index in stride(from: keyCount - 1, through: 0, by: -1) {
                writeStartupSweep(session: session, center: index)
                usleep(18_000)
            }

            flashGuide = [UInt8](repeating: 0, count: 3 * keyCount)
            writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.lightGuideReportID, payload: flashGuide)
        }

        private func writeStartupSweep(session: KontrolUSBLibUSBSessionRef, center: Int) {
            let keyCount = KompleteKontrolS25MK1Protocol.keyCount
            var guide = [UInt8](repeating: 0, count: 3 * keyCount)
            for offset in -2...2 {
                let index = center + offset
                guard (0..<keyCount).contains(index) else { continue }
                let strength = UInt8(max(0, 0x7f - abs(offset) * 0x25))
                guide[index * 3 + 0] = strength
                guide[index * 3 + 1] = UInt8(Int(strength) * 3 / 4)
                guide[index * 3 + 2] = 0
            }
            writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.lightGuideReportID, payload: guide)
        }

        private func showConnectedClient(_ client: RegisteredClient) {
            guard let session = ensureSession() else { return }
            let name = String(client.name.prefix(8)).uppercased()
            let pid = "PID \(client.pid)"
            var frame = KKDisplayFrame()
            frame.setText("CLIENT", display: 0, row: 0, alignment: .center)
            frame.setText(name, display: 0, row: 1, alignment: .center)
            frame.setText(String(pid.prefix(8)), display: 0, row: 2, alignment: .center)
            frame.setText("CONNECTED", display: 1, row: 1, alignment: .center)
            writeDarkSurface(session: session, displayFrame: frame)
        }

        private func showNoClient() {
            guard let session = ensureSession() else { return }
            var frame = KKDisplayFrame()
            frame.setText("KK", display: 0, row: 0, alignment: .center)
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
            _ = payload.withUnsafeMutableBufferPointer { buffer in
                KontrolUSBLibUSBSessionWrite(session, reportID, buffer.baseAddress, UInt32(buffer.count))
            }
        }
    }

    private static func handleDaemonClient(_ fd: Int32, clientID: Int, hardware: DaemonHardware) {
        let transientClaim = ProcessInfo.processInfo.environment["KK_DAEMON_TRANSIENT_CLAIM"] == "1"
        if transientClaim {
            daemonLog("client \(clientID) transient claim mode enabled")
        }

        var buffer: [UInt8] = []
        var scratch = [UInt8](repeating: 0, count: 512)

        while true {
            let scratchCount = scratch.count
            let count = scratch.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!, scratchCount)
            }
            if count <= 0 {
                return
            }
            buffer.append(contentsOf: scratch.prefix(count))

            while let newline = buffer.firstIndex(of: 0x0a) {
                let lineBytes = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let line = String(bytes: lineBytes, encoding: .utf8) else {
                    writeDaemonResponse("err utf8", to: fd)
                    continue
                }
                let commandStart = KKTiming.now()
                daemonTraceLog("client \(clientID) recv \(line)")
                let response = hardware.handle(line, clientID: clientID)
                daemonTraceLog("client \(clientID) done \(line) elapsed=\(KKTiming.msSince(commandStart))")
                logDaemonCommand(line, response: response, clientID: clientID)
                writeDaemonResponse(response, to: fd)
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
            daemonTraceLog("client \(clientID) read -> \(response)")
            return
        }
        if command.hasPrefix("midiread ") && response.hasPrefix("midi ") {
            daemonTraceLog("client \(clientID) midiread -> \(response)")
            return
        }
        if command.hasPrefix("write ") {
            daemonTraceLog("client \(clientID) \(command) -> \(response)")
        } else {
            daemonLog("client \(clientID) \(command) -> \(response)")
        }
    }

    private static func daemonLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        fputs("[kk-daemon] \(timestamp) \(message)\n", stderr)
        fflush(stderr)
    }

    private static func daemonTraceLog(_ message: String) {
        guard KKTiming.traceEnabled else { return }
        daemonLog(message)
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

    private func trace(_ message: String) {
        guard KKTiming.traceEnabled else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        fputs("[kk-client] \(timestamp) \(message)\n", stderr)
        fflush(stderr)
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
                return String(bytes: lineBytes, encoding: .utf8)
            }

            var scratch = [UInt8](repeating: 0, count: 512)
            let scratchCount = scratch.count
            let count = scratch.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!, scratchCount)
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
