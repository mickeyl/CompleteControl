import Foundation
import Darwin
import IOKit
import IOKit.hid
import IOKit.pwr_mgt
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

    public static var availableGlyphCount: Int {
        font16Segment.count
    }

    public static func glyph(at index: Int) -> UInt16? {
        guard font16Segment.indices.contains(index) else { return nil }
        return font16Segment[index]
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

    public mutating func setRawGlyph(_ glyph: UInt16, display: Int, row: Int, column: Int) {
        guard Self.validDisplay(display), Self.validTextRow(row), (0..<Self.characterCount).contains(column) else { return }
        setGlyph(glyph, display: display, row: row, column: column)
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

    public mutating func setRowData(_ data: [UInt8], row: Int) {
        guard Self.validRow(row) else { return }
        var rowData = Array(data.prefix(Self.bytesPerReportRow))
        if rowData.count < Self.bytesPerReportRow {
            rowData += Array(repeating: 0, count: Self.bytesPerReportRow - rowData.count)
        }
        rows[row] = rowData
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
            let delta = wrappedDelta(from: Int(previous[6] & 0x0f), to: Int(current[6] & 0x0f), modulo: 16)
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

    static func initialEventBaseline(reportID: UInt32, current: [UInt8]) -> [UInt8]? {
        guard reportID == KompleteKontrolS25MK1Protocol.inputReportID,
              current.count >= 23 else { return nil }
        var baseline = current
        for buttonByte in 1...3 where buttonByte < baseline.count {
            baseline[buttonByte] = 0
        }
        return baseline
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

    public static func clipped(_ text: String, limit: Int = 512) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + " ...[+\(text.count - limit) chars]"
    }
}

private enum KKBuildInfo {
    static func gitRevisionSummary() -> (count: String, hash: String) {
        (KKGeneratedBuildInfo.revisionCount, KKGeneratedBuildInfo.revisionHash)
    }
}

enum DaemonUSBReadinessAction: Equatable {
    case pumpOnly
    case pumpAndReconnect
}

enum DaemonReactorScheduler {
    static func usbReadinessAction(flags: UInt16) -> DaemonUSBReadinessAction {
        // Normal libusb readiness is the input hot path. Health/reconnect work only belongs on error edges.
        let hasError = (flags & UInt16(EV_ERROR)) != 0 || (flags & UInt16(EV_EOF)) != 0
        return hasError ? .pumpAndReconnect : .pumpOnly
    }
}

struct DaemonIdleDiagnosticFlushDecision: Equatable {
    var writeDisplay: Bool
    var writeLightGuide: Bool
}

struct DaemonIdleDiagnosticFlushGate {
    var lastDisplayFlushAt: UInt64 = 0
    var minimumDisplayFlushIntervalNs: UInt64 = 50_000_000

    mutating func decide(
        now: UInt64,
        needsDisplay: Bool,
        needsLightGuide: Bool
    ) -> DaemonIdleDiagnosticFlushDecision {
        let displayDue = needsDisplay
            && (lastDisplayFlushAt == 0 || now &- lastDisplayFlushAt >= minimumDisplayFlushIntervalNs)
        if displayDue {
            lastDisplayFlushAt = now
        }
        return DaemonIdleDiagnosticFlushDecision(
            writeDisplay: displayDue,
            writeLightGuide: needsLightGuide
        )
    }

    mutating func reset() {
        lastDisplayFlushAt = 0
    }
}

enum DaemonClientCommandPump {
    static func processCompleteLines(
        buffer: inout [UInt8],
        clientID: Int,
        handle: (String, Int) -> String,
        writeResponse: (String) -> Void,
        pumpUSB: () -> Void
    ) {
        while let newline = buffer.firstIndex(of: 0x0a) {
            let lineBytes = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let line = String(bytes: lineBytes, encoding: .utf8) else {
                writeResponse("err utf8")
                continue
            }
            let response = handle(line, clientID)
            writeResponse(response)
            pumpUSB()
        }
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
    private static let queue = DispatchQueue(label: "media.vanille.kompletekontrol.log", qos: .background)
    private static let maxPending = 2_048
    private static let maxMessageLength = 2_048
    private static var pending = 0
    private static var dropped = 0
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func write(group: String, level: KKStderrLogLevel, _ message: String) {
        lock.lock()
        guard pending < maxPending else {
            dropped += 1
            lock.unlock()
            return
        }
        pending += 1
        lock.unlock()

        queue.async {
            let droppedBefore: Int
            lock.lock()
            droppedBefore = dropped
            dropped = 0
            lock.unlock()

            var cleanMessage = message.replacingOccurrences(of: "\n", with: "\\n")
            if cleanMessage.count > maxMessageLength {
                cleanMessage = String(cleanMessage.prefix(maxMessageLength)) + " ...[truncated]"
            }
            if droppedBefore > 0 {
                cleanMessage = "droppedLogs=\(droppedBefore) " + cleanMessage
            }

            let timestamp = formatter.string(from: Date())
            let line = "timestamp=\(timestamp) group=\(group) level=\(level.rawValue) message=\(cleanMessage)\n"
            fputs(line, stderr)
            fflush(stderr)
            if let path = ProcessInfo.processInfo.environment["KK_DAEMON_LOG_FILE"],
               let file = fopen(path, "a") {
                fputs(line, file)
                fclose(file)
            }

            lock.lock()
            pending -= 1
            lock.unlock()
        }
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
    private var daemonSurfaceReceiveSequence: UInt64 = 0
    private var daemonMIDIReceiveSequence: UInt64 = 0
    private var inputRunLoop: CFRunLoop?
    private var inputThread: Thread?
    private var inputUsesDaemon = false
    private var autoMountTask: Task<Void, Never>?
    private var helperSession: KKDaemonOutputSession?
    private let helperSessionLock = NSLock()
    private var surfaceReplayPending = true
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
    public func setDisplayGlyph(_ glyph: UInt16, display: Int, row: Int, column: Int, flush: Bool = true) -> [KKUSBResult]? {
        guard (0..<KKDisplayFrame.displayCount).contains(display),
              (1..<KKDisplayFrame.rowCount).contains(row),
              (0..<KKDisplayFrame.characterCount).contains(column) else { return nil }
        displayFrame.setRawGlyph(glyph, display: display, row: row, column: column)
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
        displayFrame.setRowData(data, row: row)
        return sendInterruptOutput(
            reportID: KompleteKontrolS25MK1Protocol.displayReportID,
            payload: displayRowPayload(row, data: data)
        )
    }

    public func sendDisplayRowAsync(_ row: Int, data: [UInt8]) {
        guard (0..<KKDisplayFrame.rowCount).contains(row) else { return }
        displayFrame.setRowData(data, row: row)
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

    private func traceInput(_ message: String) {
        guard KKTiming.traceEnabled else { return }
        log?("kk-input \(message)")
    }

    private func traceMIDI(_ message: String) {
        guard KKTiming.traceEnabled else { return }
        log?("kk-midi \(message)")
    }

    private static func formatChangedIndices(_ indices: [Int]) -> String {
        if indices.isEmpty { return "[]" }
        return "[" + indices.map(String.init).joined(separator: ",") + "]"
    }

    private static func formatInputEvents(_ events: [KKInputEvent]) -> String {
        if events.isEmpty { return "[]" }
        return "[" + events.map { String(describing: $0) }.joined(separator: " | ") + "]"
    }

    fileprivate static func formatMIDIEvents(_ events: [KKMIDIEvent]) -> String {
        if events.isEmpty { return "[]" }
        return "[" + events.map(\.description).joined(separator: " | ") + "]"
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
        let eventBaseline = previous ?? KKInputReportDecoder.initialEventBaseline(reportID: reportID, current: current)
        let events = KKInputReportDecoder.events(reportID: reportID, previous: eventBaseline, current: current)
        if monitorMode == .changed && events.isEmpty && changedIndices.isEmpty {
            return
        }
        traceInput(
            "direct-hid report=0x\(KKHex.byte(UInt8(reportID & 0xff))) ts=0x\(String(receptionTimestamp, radix: 16)) bytes=\(KKHex.bytes(current)) changed=\(Self.formatChangedIndices(changedIndices)) events=\(Self.formatInputEvents(events))"
        )
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
        let eventBaseline = previous ?? KKInputReportDecoder.initialEventBaseline(reportID: reportID, current: current)
        let events = KKInputReportDecoder.events(reportID: reportID, previous: eventBaseline, current: current)
        if monitorMode == .changed && events.isEmpty && changedIndices.isEmpty {
            return
        }
        traceInput(
            "daemon-surface parsed report=0x\(KKHex.byte(UInt8(reportID & 0xff))) ts=0x\(String(receptionTimestamp, radix: 16)) bytes=\(KKHex.bytes(current)) changed=\(Self.formatChangedIndices(changedIndices)) events=\(Self.formatInputEvents(events))"
        )
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
                    } else if line.hasPrefix("device ") {
                        self.handleDaemonDeviceResponse(line)
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
        daemonSurfaceReceiveSequence &+= 1
        traceInput(
            "daemon-surface recv seq=\(daemonSurfaceReceiveSequence) ts=0x\(String(payload.timestamp, radix: 16)) raw=\(KKHex.bytes(payload.bytes))"
        )
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
        daemonMIDIReceiveSequence &+= 1
        let events = Self.parseUSBMIDIEvents(payload.bytes, receptionTimestamp: receptionTimestamp)
        traceMIDI(
            "daemon-midi recv seq=\(daemonMIDIReceiveSequence) ts=0x\(String(receptionTimestamp, radix: 16)) raw=\(KKHex.bytes(payload.bytes)) events=\(Self.formatMIDIEvents(events))"
        )
        for event in events {
            onMIDIEvent?(event)
        }
    }

    private func handleDaemonDeviceResponse(_ response: String) {
        guard response.hasPrefix("device reconnected") else { return }
        log?("Komplete Kontrol daemon device reconnected; replaying surface state.")
        helperSessionLock.lock()
        surfaceReplayPending = true
        let session = helperSession
        helperSessionLock.unlock()
        if let session {
            replaySurfaceState(on: session)
        }
    }

    fileprivate static func parseUSBMIDIEvents(_ bytes: [UInt8], receptionTimestamp: UInt64 = 0) -> [KKMIDIEvent] {
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
        response.hasPrefix("err -1 ")
            || response.hasPrefix("err -4 ")
            || response.hasPrefix("err -5 ")
            || response.hasPrefix("err -6 ")
            || response.hasPrefix("err -9 ")
            || response.hasPrefix("err -10 ")
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
        let response = session.request("register \(pid) \(KKHex.utf8(name))\n", timeoutUsec: 750_000)
        if response == "ok registered" {
            clientRegisteredWithSession = true
            log?("Komplete Kontrol daemon registered client \(name) pid=\(pid).")
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

    private enum DaemonControlEvent: UInt8 {
        case systemSleep = 0x73
        case systemWake = 0x77
    }

    private enum IOPowerMessage {
        // Swift cannot import these IOMessage.h macros directly.
        static let canSystemSleep: UInt32 = 0xe0000270
        static let systemWillSleep: UInt32 = 0xe0000280
        static let systemWillNotSleep: UInt32 = 0xe0000290
        static let systemWillPowerOn: UInt32 = 0xe0000320
        static let systemHasPoweredOn: UInt32 = 0xe0000300
    }

    private struct LibUSBKqueueRegistration: Hashable {
        var fd: Int32
        var filter: Int16
    }

    private final class DaemonPowerObserver: @unchecked Sendable {
        private let hardware: DaemonHardware
        private let controlWriteFD: Int32
        private let queue = DispatchQueue(label: "media.vanille.kompletekontrol.power")
        private var notifyPort: IONotificationPortRef?
        private var notifier: io_object_t = 0
        private var rootPort: io_connect_t = 0

        init(hardware: DaemonHardware, controlWriteFD: Int32) {
            self.hardware = hardware
            self.controlWriteFD = controlWriteFD
        }

        func start() {
            var localNotifyPort: IONotificationPortRef?
            var localNotifier: io_object_t = 0
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let root = IORegisterForSystemPower(refcon, &localNotifyPort, Self.callback, &localNotifier)
            guard root != 0, let localNotifyPort else {
                daemonLog("power notifications unavailable", group: "power", level: .error)
                return
            }
            rootPort = root
            notifyPort = localNotifyPort
            notifier = localNotifier
            IONotificationPortSetDispatchQueue(localNotifyPort, queue)
            daemonLog("power notifications registered", group: "power")
        }

        deinit {
            if notifier != 0 {
                var localNotifier = notifier
                IODeregisterForSystemPower(&localNotifier)
            }
            if let notifyPort {
                IONotificationPortDestroy(notifyPort)
            }
            if rootPort != 0 {
                IOServiceClose(rootPort)
            }
        }

        private static let callback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            let observer = Unmanaged<DaemonPowerObserver>.fromOpaque(refcon).takeUnretainedValue()
            observer.handlePowerMessage(messageType, argument: messageArgument)
        }

        private func handlePowerMessage(_ messageType: UInt32, argument: UnsafeMutableRawPointer?) {
            let notificationID = argument.map { Int(bitPattern: $0) } ?? 0
            switch messageType {
                case IOPowerMessage.canSystemSleep:
                    daemonDebugLog("system can sleep", group: "power")
                    allowPowerChange(notificationID)
                case IOPowerMessage.systemWillSleep:
                    daemonLog("system will sleep; closing hardware session", group: "power")
                    hardware.prepareForSystemSleep()
                    writeControlEvent(.systemSleep)
                    allowPowerChange(notificationID)
                case IOPowerMessage.systemWillNotSleep:
                    daemonDebugLog("system sleep cancelled", group: "power")
                case IOPowerMessage.systemWillPowerOn:
                    daemonDebugLog("system will power on", group: "power")
                case IOPowerMessage.systemHasPoweredOn:
                    daemonLog("system has powered on; scheduling hardware reconnect", group: "power")
                    hardware.noteSystemWake()
                    writeControlEvent(.systemWake)
                default:
                    daemonTraceLog("power message type=0x\(String(messageType, radix: 16))", group: "power")
            }
        }

        private func allowPowerChange(_ notificationID: Int) {
            guard rootPort != 0 else { return }
            IOAllowPowerChange(rootPort, notificationID)
        }

        private func writeControlEvent(_ event: DaemonControlEvent) {
            var byte = event.rawValue
            withUnsafeBytes(of: &byte) { raw in
                _ = Darwin.write(controlWriteFD, raw.baseAddress, 1)
            }
        }
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

        var controlPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&controlPipe) == 0 else {
            daemonLog("control pipe failed errno=\(errno)")
            exit(5)
        }
        _ = fcntl(controlPipe[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(controlPipe[1], F_SETFL, O_NONBLOCK)
        _ = fcntl(controlPipe[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(controlPipe[1], F_SETFD, FD_CLOEXEC)

        // Register server socket
        var serverKev = kevent(ident: UInt(serverFD), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)
        kevent(kq, &serverKev, 1, nil, 0, nil)
        daemonDebugLog("register server fd=\(serverFD) filter=\(EVFILT_READ)", group: "reactor")

        var controlKev = kevent(ident: UInt(controlPipe[0]), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)
        kevent(kq, &controlKev, 1, nil, 0, nil)
        daemonDebugLog("register control fd=\(controlPipe[0]) filter=\(EVFILT_READ)", group: "reactor")

        let powerObserver = DaemonPowerObserver(hardware: hardware, controlWriteFD: controlPipe[1])
        powerObserver.start()

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
        let reconnectTimerIdent = UInt.max - 42
        var reconnectTimerArmed = false

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

        func cancelReconnectTimer() {
            guard reconnectTimerArmed else { return }
            var kev = kevent(ident: reconnectTimerIdent, filter: Int16(EVFILT_TIMER), flags: UInt16(EV_DELETE), fflags: 0, data: 0, udata: nil)
            kevent(kq, &kev, 1, nil, 0, nil)
            reconnectTimerArmed = false
            daemonTraceLog("reconnect timer cancelled", group: "reactor")
        }

        func armReconnectTimer(afterNs delayNs: UInt64) {
            let clampedDelay = max(100_000_000, min(delayNs, UInt64(Int.max)))
            cancelReconnectTimer()
            var kev = kevent(
                ident: reconnectTimerIdent,
                filter: Int16(EVFILT_TIMER),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                fflags: UInt32(NOTE_NSECONDS),
                data: Int(clampedDelay),
                udata: nil
            )
            let status = kevent(kq, &kev, 1, nil, 0, nil)
            if status == 0 {
                reconnectTimerArmed = true
                daemonDebugLog("reconnect timer armed delayNs=\(clampedDelay)", group: "reactor")
            } else {
                daemonLog("reconnect timer arm failed errno=\(errno)", group: "reactor", level: .error)
            }
        }

        func scheduleReconnectIfNeeded() {
            guard let delay = hardware.reconnectDelayNs() else {
                cancelReconnectTimer()
                return
            }
            if !reconnectTimerArmed {
                armReconnectTimer(afterNs: delay)
            }
        }

        func runReconnect(reason: String, forceOpen: Bool) {
            daemonDebugLog("reconnect attempt reason=\(reason) force=\(forceOpen ? 1 : 0)", group: "reactor")
            let connected = hardware.maintainConnection(forceOpen: forceOpen)
            syncLibUSBRegistrations()
            if connected {
                cancelReconnectTimer()
            } else {
                scheduleReconnectIfNeeded()
            }
        }

        func drainControlEvents() -> [DaemonControlEvent] {
            var result: [DaemonControlEvent] = []
            var buffer = [UInt8](repeating: 0, count: 32)
            let bufferCount = buffer.count
            while true {
                let count = buffer.withUnsafeMutableBytes { raw in
                    Darwin.read(controlPipe[0], raw.baseAddress, bufferCount)
                }
                if count > 0 {
                    for byte in buffer.prefix(count) {
                        if let event = DaemonControlEvent(rawValue: byte) {
                            result.append(event)
                        }
                    }
                    continue
                }
                if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                    daemonLog("control pipe read failed errno=\(errno)", group: "reactor", level: .error)
                }
                break
            }
            return result
        }

        scheduleReconnectIfNeeded()

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
                daemonTraceLog("event ident=\(event.ident) filter=\(event.filter) flags=\(event.flags) fflags=\(event.fflags) data=\(event.data)", group: "reactor")

                if event.filter == Int16(EVFILT_TIMER), event.ident == reconnectTimerIdent {
                    reconnectTimerArmed = false
                    runReconnect(reason: "timer", forceOpen: true)
                    continue
                }

                guard event.ident <= UInt(Int32.max) else {
                    daemonLog("unexpected kqueue ident=\(event.ident) filter=\(event.filter)", group: "reactor", level: .error)
                    continue
                }
                let fd = Int32(event.ident)

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
                } else if fd == controlPipe[0] {
                    for controlEvent in drainControlEvents() {
                        switch controlEvent {
                            case .systemSleep:
                                daemonDebugLog("reactor received system sleep", group: "reactor")
                                syncLibUSBRegistrations()
                            case .systemWake:
                                daemonDebugLog("reactor received system wake", group: "reactor")
                                syncLibUSBRegistrations()
                                armReconnectTimer(afterNs: 750_000_000)
                        }
                    }
                } else if hardware.isLibusbFd(fd) {
                    let action = DaemonReactorScheduler.usbReadinessAction(flags: event.flags)
                    daemonDebugLog("libusb fd ready fd=\(fd) filter=\(event.filter) action=\(action)", group: "reactor")
                    hardware.handleUsbEvents(timeoutMs: 0)
                    if action == .pumpAndReconnect {
                        runReconnect(reason: "libusb-fd-error", forceOpen: true)
                    } else {
                        syncLibUSBRegistrations()
                    }
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
            scheduleReconnectIfNeeded()
            _ = powerObserver
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

        DaemonClientCommandPump.processCompleteLines(
            buffer: &buffer,
            clientID: clientID,
            handle: { line, clientID in
                daemonTraceLog("client \(clientID) recv \(KKTiming.clipped(line))")
                return hardware.handle(line, clientID: clientID)
            },
            writeResponse: { response in
                writeDaemonResponse(response, to: fd)
            },
            pumpUSB: {
                hardware.handleUsbEvents(timeoutMs: 0)
            }
        )
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
            "ccd .*--kk-libusb-daemon",
            "ccd .*--libusb-daemon",
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
            case device
        }

        private let lock = NSLock()
        private let sessionIOLock = NSLock()
        private let maxQueuedPushes = 64
        private let transientClaim = ProcessInfo.processInfo.environment["KK_DAEMON_TRANSIENT_CLAIM"] == "1"
        private let daemonSurfaceEnabled = ProcessInfo.processInfo.environment["KK_DAEMON_DISABLE_SURFACE"] != "1"
        private var libusbSession: KontrolUSBLibUSBSessionRef?
        private var asyncTransfersStarted = false
        private let initialOpenRetryDelayNs: UInt64 = 1_000_000_000
        private let maxOpenRetryDelayNs: UInt64 = 10_000_000_000
        private var nextSessionOpenAttemptAt: UInt64 = 0
        private var sessionOpenRetryDelayNs: UInt64 = 1_000_000_000
        private var systemSleeping = false
        private var registeredClients: [Int: RegisteredClient] = [:]
        private var activeClientID: Int?
        private var clientFDs: [Int: Int32] = [:]
        private var trackedLibusbFds: Set<Int32> = []
        private var queuedInputMessages: [String] = []
        private var queuedMIDIMessages: [String] = []
        private var inputPushSequence: UInt64 = 0
        private var midiPushSequence: UInt64 = 0
        private let idleRevisionSummary = KKBuildInfo.gitRevisionSummary()
        private var idleSurfacePreviousReport: [UInt8]?
        private var idleSurfaceSummary = "PRESS ANY SURFACE"
        private var idleMIDISummary = "OR MIDI KEY FOR TEST"
        private var idleHasReceivedInput = false
        private var idleLightGuide = [UInt8](repeating: 0, count: 3 * KompleteKontrolS25MK1Protocol.keyCount)
        private var idleDiagnosticNeedsFlush = false
        private var idleDiagnosticNeedsLightGuideFlush = false
        private var idleDiagnosticFlushGate = DaemonIdleDiagnosticFlushGate()

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

            let response = handleDaemonCommand(line, ifCurrentSession: session)
            guard dropSession(session, after: response) else {
                return response
            }

            guard let reconnectedSession = ensureSession(forceOpen: true) else {
                return response
            }
            let retryResponse = handleDaemonCommand(line, ifCurrentSession: reconnectedSession)
            _ = dropSession(reconnectedSession, after: retryResponse)
            return retryResponse
        }

        private func handleDaemonCommand(_ line: String, ifCurrentSession session: KontrolUSBLibUSBSessionRef) -> String {
            sessionIOLock.lock()
            lock.lock()
            let isCurrent = libusbSession == session
            lock.unlock()
            guard isCurrent else {
                sessionIOLock.unlock()
                return "err no session"
            }
            let response = KompleteKontrolLibUSBServer.handleDaemonCommand(line, session: session)
            sessionIOLock.unlock()
            return response
        }

        func disconnect(clientID: Int) {
            let nextClient: RegisteredClient?
            let shouldShowConnectedClient: Bool
            let shouldShowNoClient: Bool
            lock.lock()
            guard registeredClients.removeValue(forKey: clientID) != nil else {
                lock.unlock()
                return
            }
            if activeClientID == clientID {
                activeClientID = registeredClients.keys.sorted().last
                nextClient = activeClientID.flatMap { registeredClients[$0] }
                shouldShowConnectedClient = nextClient != nil
            } else {
                nextClient = nil
                shouldShowConnectedClient = false
            }
            shouldShowNoClient = registeredClients.isEmpty && clientFDs.isEmpty
            lock.unlock()

            daemonLog("client \(clientID) registration removed on disconnect")
            if shouldShowConnectedClient, let nextClient {
                showConnectedClient(nextClient)
            } else if shouldShowNoClient {
                showNoClient()
            }
        }

        func runStartupAnimationThenIdle() {
            runStartupAnimation()
            if shouldDaemonShowIdleSurface() {
                showNoClient()
            }
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
            let shouldShowConnectedClient: Bool
            let shouldShowNoClient: Bool
            lock.lock()
            guard let client = registeredClients.removeValue(forKey: clientID) else {
                lock.unlock()
                return "ok unregistered"
            }
            if activeClientID == clientID {
                activeClientID = registeredClients.keys.sorted().last
                nextClient = activeClientID.flatMap { registeredClients[$0] }
                shouldShowConnectedClient = nextClient != nil
            } else {
                nextClient = nil
                shouldShowConnectedClient = false
            }
            shouldShowNoClient = registeredClients.isEmpty && clientFDs.isEmpty
            lock.unlock()

            daemonLog("client \(clientID) unregistered name=\(client.name) pid=\(client.pid)")
            if shouldShowConnectedClient, let nextClient {
                showConnectedClient(nextClient)
            } else if shouldShowNoClient {
                showNoClient()
            }
            return "ok unregistered"
        }

        private func ensureSession(forceOpen: Bool = false) -> KontrolUSBLibUSBSessionRef? {
            lock.lock()
            if let libusbSession {
                lock.unlock()
                return libusbSession
            }
            if systemSleeping {
                lock.unlock()
                daemonTraceLog("hardware session open skipped: system sleeping", group: "usb")
                return nil
            }
            let now = KKTiming.now()
            if !forceOpen, nextSessionOpenAttemptAt > now {
                let remaining = nextSessionOpenAttemptAt - now
                lock.unlock()
                daemonTraceLog("hardware session open skipped: backoff remainingNs=\(remaining)", group: "usb")
                return nil
            }
            lock.unlock()

            sessionIOLock.lock()
            lock.lock()
            if let libusbSession {
                lock.unlock()
                sessionIOLock.unlock()
                return libusbSession
            }
            if systemSleeping {
                lock.unlock()
                sessionIOLock.unlock()
                daemonTraceLog("hardware session open skipped: system sleeping", group: "usb")
                return nil
            }
            lock.unlock()

            var session: KontrolUSBLibUSBSessionRef?
            let result = KontrolUSBLibUSBSessionOpen(&session)
            let message = KKUSBResult(result).message.replacingOccurrences(of: "\n", with: " ")
            daemonLog("hardware session open status=\(result.status) ep=0x\(String(format: "%02x", result.endpointAddress)) \(message)")
            guard result.status == 0, let session else {
                sessionIOLock.unlock()
                recordSessionOpenFailure()
                return nil
            }

            lock.lock()
            if let existingSession = libusbSession {
                lock.unlock()
                KontrolUSBLibUSBSessionClose(session)
                sessionIOLock.unlock()
                return existingSession
            }
            libusbSession = session
            nextSessionOpenAttemptAt = 0
            sessionOpenRetryDelayNs = initialOpenRetryDelayNs
            lock.unlock()
            sessionIOLock.unlock()

            startAsyncTransfersIfNeeded(session)
            return session
        }

        private func recordSessionOpenFailure() {
            let now = KKTiming.now()
            lock.lock()
            nextSessionOpenAttemptAt = now + sessionOpenRetryDelayNs
            sessionOpenRetryDelayNs = min(maxOpenRetryDelayNs, sessionOpenRetryDelayNs * 2)
            let retryAt = nextSessionOpenAttemptAt
            let nextDelay = sessionOpenRetryDelayNs
            lock.unlock()
            daemonDebugLog("hardware session open backoff retryAt=0x\(String(retryAt, radix: 16)) nextDelayNs=\(nextDelay)", group: "usb")
        }

        private func shouldDropSession(after response: String) -> Bool {
            response.hasPrefix("err -1 ")
                || response.hasPrefix("err -4 ")
                || response.hasPrefix("err -5 ")
                || response.hasPrefix("err -6 ")
                || response.hasPrefix("err -9 ")
                || response.hasPrefix("err -10 ")
        }

        @discardableResult
        private func dropSession(_ session: KontrolUSBLibUSBSessionRef, after response: String) -> Bool {
            guard shouldDropSession(after: response) else { return false }
            sessionIOLock.lock()
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
            sessionIOLock.unlock()
            return shouldClose
        }

        func maintainConnection(forceOpen: Bool = false) -> Bool {
            guard !transientClaim else { return true }

            lock.lock()
            let session = libusbSession
            let sleeping = systemSleeping
            lock.unlock()
            guard !sleeping else { return true }

            if let session {
                sessionIOLock.lock()
                lock.lock()
                let isCurrent = libusbSession == session
                lock.unlock()
                guard isCurrent else {
                    sessionIOLock.unlock()
                    return false
                }
                let health = KontrolUSBLibUSBSessionHealth(session)
                sessionIOLock.unlock()
                let message = KKUSBResult(health).message.replacingOccurrences(of: "\n", with: " ")
                if health.status != 0 {
                    daemonLog("hardware session health failed status=\(health.status) \(message); reconnecting", group: "usb", level: .error)
                    if dropSession(session, after: "err \(health.status) \(message)") {
                        return restoreHardwareAfterReconnect(forceOpen: true)
                    }
                    return false
                }
                return true
            }

            return restoreHardwareAfterReconnect(forceOpen: forceOpen)
        }

        private func restoreHardwareAfterReconnect(forceOpen: Bool = false) -> Bool {
            guard let session = ensureSession(forceOpen: forceOpen) else { return false }
            daemonLog("hardware session reconnected", group: "usb")
            writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.initReportID, payload: [0x00, 0x00])
            notifyDeviceReconnected()
            if shouldDaemonShowIdleSurface() {
                showNoClient()
            }
            return true
        }

        private func notifyDeviceReconnected() {
            pushToClients("device reconnected @\(String(KKTiming.now(), radix: 16))", kind: .device)
        }

        func prepareForSystemSleep() {
            sessionIOLock.lock()
            lock.lock()
            systemSleeping = true
            nextSessionOpenAttemptAt = 0
            sessionOpenRetryDelayNs = initialOpenRetryDelayNs
            let session = libusbSession
            libusbSession = nil
            asyncTransfersStarted = false
            trackedLibusbFds.removeAll()
            lock.unlock()

            if let session {
                daemonLog("hardware session closed for system sleep", group: "usb")
                KontrolUSBLibUSBSessionClose(session)
            }
            sessionIOLock.unlock()
        }

        func noteSystemWake() {
            lock.lock()
            systemSleeping = false
            nextSessionOpenAttemptAt = 0
            sessionOpenRetryDelayNs = initialOpenRetryDelayNs
            lock.unlock()
        }

        func reconnectDelayNs(now: UInt64 = KKTiming.now()) -> UInt64? {
            lock.lock()
            defer { lock.unlock() }
            guard !transientClaim, libusbSession == nil, !systemSleeping else { return nil }
            guard nextSessionOpenAttemptAt > now else { return 0 }
            return nextSessionOpenAttemptAt - now
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
            guard daemonSurfaceEnabled else { return }
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
            guard shouldDaemonShowIdleSurface() else { return }
            guard let session = ensureSession() else { return }
            resetIdleDiagnosticState()
            let emptyButtons = [UInt8](repeating: 0, count: KKButtonLED.protocolNames.count)
            writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.buttonLEDReportID, payload: emptyButtons)
            writeIdleDiagnosticSurface(
                surfaceSummary: "PRESS ANY SURFACE",
                midiSummary: "OR MIDI KEY FOR TEST",
                hasInput: false,
                lightGuide: [UInt8](repeating: 0, count: 3 * KompleteKontrolS25MK1Protocol.keyCount),
                writeLightGuide: true
            )
        }

        private func shouldDaemonShowIdleSurface() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return daemonSurfaceEnabled && registeredClients.isEmpty && clientFDs.isEmpty
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

        private func resetIdleDiagnosticState() {
            lock.lock()
            idleSurfacePreviousReport = nil
            idleSurfaceSummary = "PRESS ANY SURFACE"
            idleMIDISummary = "OR MIDI KEY FOR TEST"
            idleHasReceivedInput = false
            idleLightGuide = [UInt8](repeating: 0, count: 3 * KompleteKontrolS25MK1Protocol.keyCount)
            idleDiagnosticNeedsFlush = false
            idleDiagnosticNeedsLightGuideFlush = false
            idleDiagnosticFlushGate.reset()
            lock.unlock()
        }

        private func acknowledgeIdleSurfaceInput(_ bytes: [UInt8]) {
            guard shouldDaemonShowIdleSurface() else { return }
            let report = normalizedIdleSurfaceReport(bytes)

            lock.lock()
            let previous = idleSurfacePreviousReport
            let baseline = previous ?? KKInputReportDecoder.initialEventBaseline(
                reportID: KompleteKontrolS25MK1Protocol.inputReportID,
                current: report
            ) ?? report
            let events = KKInputReportDecoder.events(
                reportID: KompleteKontrolS25MK1Protocol.inputReportID,
                previous: baseline,
                current: report
            )
            idleSurfacePreviousReport = report
            if events.isEmpty, previous != nil, previous == report {
                lock.unlock()
                return
            }
            idleHasReceivedInput = true
            idleSurfaceSummary = events.first.map(idleSurfaceSummary(for:)) ?? idleRawSurfaceSummary(bytes)
            if idleMIDISummary == "OR MIDI KEY FOR TEST" {
                idleMIDISummary = "--"
            }
            idleDiagnosticNeedsFlush = true
            lock.unlock()
        }

        private func acknowledgeIdleMIDIInput(_ bytes: [UInt8], timestamp: UInt64) {
            guard shouldDaemonShowIdleSurface() else { return }
            let events = KompleteKontrolS25MK1.parseUSBMIDIEvents(bytes, receptionTimestamp: timestamp)
            guard !events.isEmpty || !bytes.isEmpty else { return }

            lock.lock()
            idleHasReceivedInput = true
            idleMIDISummary = events.first.map(idleMIDISummary(for:)) ?? idleRawMIDISummary(bytes)
            if idleSurfaceSummary == "PRESS ANY SURFACE" {
                idleSurfaceSummary = "--"
            }
            for event in events {
                updateIdleLightGuide(for: event)
            }
            idleDiagnosticNeedsFlush = true
            idleDiagnosticNeedsLightGuideFlush = true
            lock.unlock()
        }

        private func normalizedIdleSurfaceReport(_ bytes: [UInt8]) -> [UInt8] {
            guard bytes.first == UInt8(KompleteKontrolS25MK1Protocol.inputReportID) else {
                return bytes
            }
            return Array(bytes.dropFirst())
        }

        private func idleSurfaceSummary(for event: KKInputEvent) -> String {
            switch event {
                case let .button(name, pressed):
                    return "BTN \(shortIdleName(name)) \(pressed ? "DOWN" : "UP")"
                case let .touchEncoder(index, touched):
                    return "TOUCH E\(index) \(touched ? "ON" : "OFF")"
                case let .mainEncoderState(value):
                    return String(format: "MAIN STATE %02X", value)
                case let .mainEncoder(delta):
                    return "MAIN \(signedIdleDelta(delta))"
                case let .rotaryEncoder(index, delta, value):
                    return "ENC \(index) \(signedIdleDelta(delta)) VAL \(value)"
                case let .touchStrip(name, value):
                    return "\(shortIdleName(name)) STRIP \(value)"
            }
        }

        private func idleMIDISummary(for event: KKMIDIEvent) -> String {
            switch event.kind {
                case .noteOn:
                    return "ON \(idleNoteName(event.note)) V\(event.velocity)"
                case .noteOff:
                    return "OFF \(idleNoteName(event.note))"
                case .controlChange:
                    return "CC \(event.control) \(event.controlValue)"
                case .pitchBend:
                    return "BEND \(event.pitchBendCentered)"
            }
        }

        private func idleRawSurfaceSummary(_ bytes: [UInt8]) -> String {
            "RAW " + bytes.prefix(6).map(KKHex.byte).joined(separator: " ")
        }

        private func idleRawMIDISummary(_ bytes: [UInt8]) -> String {
            "RAW " + bytes.prefix(6).map(KKHex.byte).joined(separator: " ")
        }

        private func shortIdleName(_ name: String) -> String {
            name.uppercased().replacingOccurrences(of: " ", with: "")
        }

        private func signedIdleDelta(_ value: Int) -> String {
            value >= 0 ? "+\(value)" : "\(value)"
        }

        private func idleNoteName(_ note: UInt8) -> String {
            let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
            let value = Int(note)
            let octave = value / 12 - 1
            return "\(names[value % 12])\(octave)"
        }

        private func updateIdleLightGuide(for event: KKMIDIEvent) {
            guard event.kind == .noteOn || event.kind == .noteOff else { return }
            let keyIndex = Int(event.note) - 48
            guard (0..<KompleteKontrolS25MK1Protocol.keyCount).contains(keyIndex) else { return }
            let base = keyIndex * 3
            if event.kind == .noteOn {
                let intensity = UInt8(max(16, min(0x7f, Int(event.velocity))))
                idleLightGuide[base] = 0
                idleLightGuide[base + 1] = intensity
                idleLightGuide[base + 2] = 0x7f
            } else {
                idleLightGuide[base] = 0
                idleLightGuide[base + 1] = 0
                idleLightGuide[base + 2] = 0
            }
        }

        private func writeIdleDiagnosticSurface(
            surfaceSummary: String,
            midiSummary: String,
            hasInput: Bool,
            lightGuide: [UInt8],
            writeLightGuide: Bool
        ) {
            guard shouldDaemonShowIdleSurface() else { return }
            guard let session = ensureSession() else { return }

            var frame = KKDisplayFrame()
            frame.setText("NO", display: 0, row: 1, alignment: .center)
            frame.setText("CLIENT", display: 0, row: 2, alignment: .center)
            if hasInput {
                setIdleWideText("SURF \(surfaceSummary)", row: 1, into: &frame)
                setIdleWideText("MIDI \(midiSummary)", row: 2, into: &frame)
            } else {
                setIdleWideText("PRESS ANY SURFACE", row: 1, into: &frame)
                setIdleWideText("OR MIDI KEY FOR TEST", row: 2, into: &frame)
            }
            frame.setText("REV \(idleRevisionSummary.count)", display: KKDisplayFrame.displayCount - 1, row: 1, alignment: .left)
            frame.setText(idleRevisionSummary.hash, display: KKDisplayFrame.displayCount - 1, row: 2, alignment: .left)

            if writeLightGuide {
                writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.lightGuideReportID, payload: lightGuide)
            }
            for row in 0..<KKDisplayFrame.rowCount {
                let payload = KompleteKontrolLibUSBServer.displayRowPayload(row, data: frame.rowData(row))
                writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.displayReportID, payload: payload)
            }
        }

        private func flushIdleDiagnosticIfNeeded() {
            guard shouldDaemonShowIdleSurface() else { return }
            let now = KKTiming.now()
            let surfaceSummary: String
            let midiSummary: String
            let hasInput: Bool
            let guide: [UInt8]
            let decision: DaemonIdleDiagnosticFlushDecision

            lock.lock()
            guard idleDiagnosticNeedsFlush || idleDiagnosticNeedsLightGuideFlush else {
                lock.unlock()
                return
            }
            decision = idleDiagnosticFlushGate.decide(
                now: now,
                needsDisplay: idleDiagnosticNeedsFlush,
                needsLightGuide: idleDiagnosticNeedsLightGuideFlush
            )
            surfaceSummary = idleSurfaceSummary
            midiSummary = idleMIDISummary
            hasInput = idleHasReceivedInput
            guide = idleLightGuide
            if decision.writeDisplay {
                idleDiagnosticNeedsFlush = false
            }
            if decision.writeLightGuide {
                idleDiagnosticNeedsLightGuideFlush = false
            }
            lock.unlock()

            if decision.writeDisplay {
                writeIdleDiagnosticSurface(
                    surfaceSummary: surfaceSummary,
                    midiSummary: midiSummary,
                    hasInput: hasInput,
                    lightGuide: guide,
                    writeLightGuide: decision.writeLightGuide
                )
            } else if decision.writeLightGuide {
                writeIdleDiagnosticLightGuide(guide)
            }
        }

        private func writeIdleDiagnosticLightGuide(_ lightGuide: [UInt8]) {
            guard shouldDaemonShowIdleSurface() else { return }
            guard let session = ensureSession() else { return }
            writeReport(session: session, reportID: KompleteKontrolS25MK1Protocol.lightGuideReportID, payload: lightGuide)
        }

        private func setIdleWideText(_ text: String, row: Int, into frame: inout KKDisplayFrame) {
            let displayRange = 1..<(KKDisplayFrame.displayCount - 1)
            let capacity = displayRange.count * KKDisplayFrame.characterCount
            let scalars = Array(text.uppercased().unicodeScalars.prefix(capacity))
            for display in displayRange {
                let start = (display - 1) * KKDisplayFrame.characterCount
                let end = min(start + KKDisplayFrame.characterCount, scalars.count)
                let chunk = start < end ? String(String.UnicodeScalarView(scalars[start..<end])) : ""
                frame.setText(chunk, display: display, row: row, alignment: .left)
            }
        }

        private func writeReport(session: KontrolUSBLibUSBSessionRef, reportID: UInt8, payload: [UInt8]) {
            var payload = payload
            daemonTraceLog("write report begin report=0x\(KKHex.byte(reportID)) bytes=\(payload.count) head=\(KKTiming.short(payload))", group: "usb-out")
            let start = KKTiming.now()
            sessionIOLock.lock()
            lock.lock()
            let isCurrent = libusbSession == session
            lock.unlock()
            guard isCurrent else {
                sessionIOLock.unlock()
                daemonTraceLog("write report skipped report=0x\(KKHex.byte(reportID)) stale session", group: "usb-out")
                return
            }
            let result = payload.withUnsafeMutableBufferPointer { buffer in
                KontrolUSBLibUSBSessionWrite(session, reportID, buffer.baseAddress, UInt32(buffer.count))
            }
            sessionIOLock.unlock()
            daemonTraceLog("write report end report=0x\(KKHex.byte(reportID)) status=\(result.status) elapsed=\(KKTiming.msSince(start))", group: "usb-out")
        }

        func addClient(fd: Int32, clientID: Int) {
            lock.lock()
            clientFDs[clientID] = fd
            lock.unlock()
        }

        func removeClient(clientID: Int) {
            let shouldShowNoClient: Bool
            lock.lock()
            clientFDs.removeValue(forKey: clientID)
            shouldShowNoClient = registeredClients.isEmpty && clientFDs.isEmpty
            lock.unlock()
            if shouldShowNoClient {
                showNoClient()
            }
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
            sessionIOLock.lock()
            lock.lock()
            let isCurrent = libusbSession == session
            lock.unlock()
            guard isCurrent else {
                sessionIOLock.unlock()
                return
            }
            let inputStatus = KontrolUSBLibUSBSessionStartAsyncInput(session, KompleteKontrolLibUSBServer.asyncInputCallback, selfPtr)
            let midiStatus = KontrolUSBLibUSBSessionStartAsyncMIDI(session, KompleteKontrolLibUSBServer.asyncMidiCallback, selfPtr)
            sessionIOLock.unlock()

            lock.lock()
            asyncTransfersStarted = inputStatus == 0 || midiStatus == 0
            lock.unlock()
            daemonLog("async transfers started input=\(inputStatus) midi=\(midiStatus)", group: "usb")
        }

        func handleUsbEvents(timeoutMs: Int) {
            sessionIOLock.lock()
            lock.lock()
            let session = libusbSession
            lock.unlock()
            guard let session else {
                sessionIOLock.unlock()
                daemonDebugLog("handle_events skipped: no session", group: "usb")
                return
            }
            daemonTraceLog("handle_events begin timeoutMs=\(timeoutMs)", group: "usb")
            KontrolUSBLibUSBHandleEventsTimeout(session, Int32(timeoutMs))
            sessionIOLock.unlock()
            daemonTraceLog("handle_events end timeoutMs=\(timeoutMs)", group: "usb")
            flushIdleDiagnosticIfNeeded()
        }

        func currentLibusbPollFds() -> [KontrolUSBPollFd] {
            sessionIOLock.lock()
            lock.lock()
            let session = libusbSession
            lock.unlock()
            guard let session else {
                sessionIOLock.unlock()
                daemonTraceLog("pollfds skipped: no session", group: "usb")
                return []
            }
            var pollFds = [KontrolUSBPollFd](repeating: KontrolUSBPollFd(), count: 8)
            let count = pollFds.withUnsafeMutableBufferPointer { buf in
                KontrolUSBLibUSBSessionGetPollFds(session, buf.baseAddress, Int32(buf.count))
            }
            sessionIOLock.unlock()
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
            let bytes = (0..<Int(length)).map { data[$0] }
            let hex = bytes.map(KKHex.byte).joined(separator: " ")
            let sequence = nextInputPushSequence()
            daemonDebugLog(
                "push surface seq=\(sequence) ts=0x\(String(timestamp, radix: 16)) len=\(length) raw=\(hex)",
                group: "surface",
                level: .info
            )
            daemonDebugLog("async input len=\(length) head=\((0..<min(Int(length), 12)).map { KKHex.byte(data[$0]) }.joined(separator: " "))", group: "surface", level: .info)
            acknowledgeIdleSurfaceInput(bytes)
            pushToClients("in @\(String(timestamp, radix: 16)) \(hex)", kind: .input)
        }

        fileprivate func pushMidiToClients(_ data: UnsafePointer<UInt8>, length: UInt32) {
            let timestamp = KKTiming.now()
            let bytes = (0..<Int(length)).map { data[$0] }
            let hex = bytes.map(KKHex.byte).joined(separator: " ")
            let sequence = nextMIDIPushSequence()
            daemonDebugLog(
                "push midi seq=\(sequence) ts=0x\(String(timestamp, radix: 16)) len=\(length) raw=\(hex) parsed=\(KompleteKontrolS25MK1.formatMIDIEvents(KompleteKontrolS25MK1.parseUSBMIDIEvents(bytes, receptionTimestamp: timestamp)) )",
                group: "midi",
                level: .info
            )
            daemonDebugLog("async midi len=\(length) head=\((0..<min(Int(length), 12)).map { KKHex.byte(data[$0]) }.joined(separator: " "))", group: "midi", level: .info)
            acknowledgeIdleMIDIInput(bytes, timestamp: timestamp)
            pushToClients("midi @\(String(timestamp, radix: 16)) \(hex)", kind: .midi)
        }

        private func nextInputPushSequence() -> UInt64 {
            lock.lock()
            inputPushSequence &+= 1
            let sequence = inputPushSequence
            lock.unlock()
            return sequence
        }

        private func nextMIDIPushSequence() -> UInt64 {
            lock.lock()
            midiPushSequence &+= 1
            let sequence = midiPushSequence
            lock.unlock()
            return sequence
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
                case .device:
                    break
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
            currentExecutableDirectory.map { $0 + "/ccd" },
            fileManager.currentDirectoryPath + "/.build/debug/ccd",
            "/usr/local/bin/ccd",
            currentExecutable?.hasSuffix("/ccd") == true ? currentExecutable : nil,
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

    public static func bytes(_ values: [UInt8]) -> String {
        values.map(byte).joined(separator: " ")
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
                if let line, (line.hasPrefix("in ") || line.hasPrefix("midi ") || line.hasPrefix("device ")) {
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
