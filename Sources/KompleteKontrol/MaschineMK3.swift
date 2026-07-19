import Foundation

public enum MaschineMK3Protocol {
    public static let vendorID: UInt16 = 0x17cc
    public static let productID: UInt16 = 0x1600

    public static let surfaceReportID: UInt8 = 0x01
    public static let surfaceReportSize = 42
    public static let padReportID: UInt8 = 0x02
    public static let padReportSize = 64

    public static let buttonLEDReportID: UInt8 = 0x80
    public static let buttonLEDPayloadSize = 62
    public static let stripLEDReportID: UInt8 = 0x81
    public static let stripLEDPayloadSize = 41
    public static let stripLEDCount = 25
    public static let padMaximumStrikeVelocity = 4095
    public static let padMaximumPressure = 4095

    /// Hardware-calibrated monochrome values. The low two bits are deliberately
    /// non-linear: `0x05` is almost dark, `0x04` is a useful soft state,
    /// `0x06` is bright, and `0x07` is maximum. Kit2 uses the three useful
    /// levels and retains `0x05` as a documented diagnostic reference.
    public static let monochromeDimLEDValue: UInt8 = 0x04
    public static let monochromeSubtleDimLEDValue: UInt8 = 0x05
    public static let monochromeBrightLEDValue: UInt8 = 0x06
    public static let monochromePressedLEDValue: UInt8 = 0x07
    /// Maximum white in the source-derived 16-hue palette. `0x4e` is another
    /// hardware-verified white reference at brightness level 2.
    public static let whiteColorLEDValue: UInt8 = 0xff
    public static let alternateWhiteColorLEDValue: UInt8 = 0x4e
    public static let padPressedReferenceThreshold = 128

    public static let displayWidth = 480
    public static let displayHeight = 272

    public static func clearedButtonLEDPayload() -> [UInt8] {
        [UInt8](repeating: 0, count: buttonLEDPayloadSize)
    }

    public static func clearedStripLEDPayload() -> [UInt8] {
        [UInt8](repeating: 0, count: stripLEDPayloadSize)
    }

    public static func stripLEDIndex(for position: Int) -> Int? {
        guard position > 0 else { return nil }
        return max(0, min(stripLEDCount - 1, ((position - 1) * stripLEDCount) / 1024))
    }
}

/// Physical controls carried as bits in the verified 42-byte report `0x01`.
/// Names and positions are cross-checked against cabl, ktemkin's protocol
/// notes, and openAV-Ctlra. Ambiguous pedal/microphone-presence bits are not
/// included and remain visible through `rawChanged` events.
public enum MaschineMK3Button: String, CaseIterable, Sendable {
    case mainEncoderPress = "main-encoder-press"
    case mainEncoderUp = "main-encoder-up"
    case mainEncoderRight = "main-encoder-right"
    case mainEncoderDown = "main-encoder-down"
    case mainEncoderLeft = "main-encoder-left"
    case shift
    case groupA = "group-a"
    case groupB = "group-b"
    case groupC = "group-c"
    case groupD = "group-d"
    case groupE = "group-e"
    case groupF = "group-f"
    case groupG = "group-g"
    case groupH = "group-h"
    case notes
    case volume
    case swing
    case tempo
    case noteRepeat = "note-repeat"
    case lock
    case padMode = "pad-mode"
    case keyboard
    case chords
    case step
    case fixedVelocity = "fixed-velocity"
    case scene
    case pattern
    case events
    case variation
    case duplicate
    case select
    case solo
    case mute
    case pitch
    case mod
    case perform
    case restart
    case erase
    case tap
    case follow
    case play
    case record
    case stop
    case macro
    case settings
    case arrowRight = "arrow-right"
    case sampling
    case mixer
    case plugin
    case channel
    case arranger
    case browser
    case arrowLeft = "arrow-left"
    case file
    case auto
    case displayButton1 = "display-button-1"
    case displayButton2 = "display-button-2"
    case displayButton3 = "display-button-3"
    case displayButton4 = "display-button-4"
    case displayButton5 = "display-button-5"
    case displayButton6 = "display-button-6"
    case displayButton7 = "display-button-7"
    case displayButton8 = "display-button-8"
}

/// Byte indices inside the 62-byte payload of output report `0x80`.
public enum MaschineMK3ButtonLED: Int, CaseIterable, Hashable, Sendable {
    case channel = 0, plugin, arranger, mixer, browser, sampling, arrowLeft, arrowRight
    case file = 8, settings, auto, macro
    case displayButton1 = 12, displayButton2, displayButton3, displayButton4
    case displayButton5 = 16, displayButton6, displayButton7, displayButton8
    case volume = 20, swing, noteRepeat, tempo, lock, pitch, mod, perform, notes
    case groupA = 29, groupB, groupC, groupD, groupE, groupF, groupG, groupH
    case restart = 37, erase, tap, follow, play, record, stop, shift, fixedVelocity
    case padMode = 46, keyboard, chords, step, scene, pattern, events, variation
    case duplicate = 54, select, solo, mute
    case mainEncoderUp = 58, mainEncoderLeft, mainEncoderRight, mainEncoderDown

    /// Hardware calibration distinguishes these RGB-style palette slots from
    /// the otherwise monochrome brightness slots in report `0x80`. Sampling is
    /// hybrid: colours use the RGB curve, while white uses the monochrome curve.
    public var usesColorEncoding: Bool {
        switch self {
            case .sampling,
                 .groupA, .groupB, .groupC, .groupD, .groupE, .groupF, .groupG, .groupH,
                 .mainEncoderUp, .mainEncoderLeft, .mainEncoderRight, .mainEncoderDown:
                true
            default:
                false
        }
    }

    public var usesMonochromeWhiteCurve: Bool { self == .sampling }

    public var pressedEchoValue: UInt8 {
        usesColorEncoding
            ? MaschineMK3Protocol.whiteColorLEDValue
            : MaschineMK3Protocol.monochromePressedLEDValue
    }
}

/// Byte indices inside the 41-byte payload of output report `0x81`.
public enum MaschineMK3PadLED: Int, CaseIterable, Hashable, Sendable {
    case pad13 = 25, pad14, pad15, pad16
    case pad9 = 29, pad10, pad11, pad12
    case pad5 = 33, pad6, pad7, pad8
    case pad1 = 37, pad2, pad3, pad4

    /// Bench-verified on bcdDevice 0x0146: the input hardware index maps directly
    /// to output payload offsets 25...40. The panel numbering runs bottom-up in
    /// four-pad rows, so hardware index 2 is physical Pad 15 while LED slot 27 is
    /// likewise physical Pad 15.
    public init?(hardwareIndex: Int) {
        guard 0..<16 ~= hardwareIndex else { return nil }
        guard let value = Self(rawValue: 25 + hardwareIndex) else { return nil }
        self = value
    }
}

public extension MaschineMK3Button {
    var led: MaschineMK3ButtonLED? {
        switch self {
            case .mainEncoderPress: nil
            case .mainEncoderUp: .mainEncoderUp
            case .mainEncoderRight: .mainEncoderRight
            case .mainEncoderDown: .mainEncoderDown
            case .mainEncoderLeft: .mainEncoderLeft
            case .shift: .shift
            case .groupA: .groupA
            case .groupB: .groupB
            case .groupC: .groupC
            case .groupD: .groupD
            case .groupE: .groupE
            case .groupF: .groupF
            case .groupG: .groupG
            case .groupH: .groupH
            case .notes: .notes
            case .volume: .volume
            case .swing: .swing
            case .tempo: .tempo
            case .noteRepeat: .noteRepeat
            case .lock: .lock
            case .padMode: .padMode
            case .keyboard: .keyboard
            case .chords: .chords
            case .step: .step
            case .fixedVelocity: .fixedVelocity
            case .scene: .scene
            case .pattern: .pattern
            case .events: .events
            case .variation: .variation
            case .duplicate: .duplicate
            case .select: .select
            case .solo: .solo
            case .mute: .mute
            case .pitch: .pitch
            case .mod: .mod
            case .perform: .perform
            case .restart: .restart
            case .erase: .erase
            case .tap: .tap
            case .follow: .follow
            case .play: .play
            case .record: .record
            case .stop: .stop
            case .macro: .macro
            case .settings: .settings
            case .arrowRight: .arrowRight
            case .sampling: .sampling
            case .mixer: .mixer
            case .plugin: .plugin
            case .channel: .channel
            case .arranger: .arranger
            case .browser: .browser
            case .arrowLeft: .arrowLeft
            case .file: .file
            case .auto: .auto
            case .displayButton1: .displayButton1
            case .displayButton2: .displayButton2
            case .displayButton3: .displayButton3
            case .displayButton4: .displayButton4
            case .displayButton5: .displayButton5
            case .displayButton6: .displayButton6
            case .displayButton7: .displayButton7
            case .displayButton8: .displayButton8
        }
    }
}

public enum MaschineMK3AnalogControl: String, CaseIterable, Sendable {
    case microphoneGain = "microphone-gain"
    case headphoneVolume = "headphone-volume"
    case masterVolume = "master-volume"
}

public enum MaschineMK3SurfaceEvent: Equatable, Sendable, CustomStringConvertible {
    case button(button: MaschineMK3Button, pressed: Bool)
    /// Encoder 0 is the main encoder; 1...8 are the encoders below the displays.
    case encoder(index: Int, delta: Int, value: Int)
    /// Encoder 0 is the main encoder; 1...8 are the encoders below the displays.
    case encoderTouch(index: Int, touched: Bool)
    /// Source-derived position field. A nil position is a zero/release sample.
    case touchStrip(finger: Int, position: Int?)
    case analog(control: MaschineMK3AnalogControl, value: Int)
    case rawChanged(indices: [Int])

    public var description: String {
        switch self {
            case let .button(button, pressed):
                "button \(button.rawValue) \(pressed ? "down" : "up")"
            case let .encoder(index, delta, value):
                "encoder \(index) \(delta > 0 ? "+" : "")\(delta) value=\(value)"
            case let .encoderTouch(index, touched):
                "touch encoder \(index) \(touched ? "on" : "off")"
            case let .touchStrip(finger, position):
                position.map { "strip \(finger) \($0)" } ?? "strip \(finger) release"
            case let .analog(control, value):
                "\(control.rawValue) \(value)"
            case let .rawChanged(indices):
                "raw changed \(indices.map(String.init).joined(separator: ","))"
        }
    }
}

public enum MaschineMK3InputReportKind: String, Sendable {
    case surface
    case pads
    case unknown
}

public struct MaschineMK3InputReportObservation: Sendable, Equatable {
    public var kind: MaschineMK3InputReportKind
    public var reportID: UInt8?
    public var actualLength: Int
    public var expectedLength: Int?
    public var changedIndices: [Int]

    public var hasValidLength: Bool {
        expectedLength == actualLength
    }

    public init(
        kind: MaschineMK3InputReportKind,
        reportID: UInt8?,
        actualLength: Int,
        expectedLength: Int?,
        changedIndices: [Int]
    ) {
        self.kind = kind
        self.reportID = reportID
        self.actualLength = actualLength
        self.expectedLength = expectedLength
        self.changedIndices = changedIndices
    }
}

/// One raw three-byte slot from the verified 63-byte pad-report payload.
public struct MaschineMK3PadRecord: Sendable, Equatable {
    public var slotIndex: Int
    public var byte0: UInt8
    public var byte1: UInt8
    public var byte2: UInt8

    public var bytes: [UInt8] { [byte0, byte1, byte2] }

    public var isSourceEncodedPadSample: Bool {
        byte0 < 16 && byte1 & 0xf0 == 0x40
    }

    /// Bench-observed semantic value. The older public notes document only
    /// `0x4xxx` pressure; a controlled trace on bcdDevice 0x0146 additionally
    /// establishes touch/strike words followed by matching release markers.
    public var inputValue: MaschineMK3PadInputValue? {
        guard byte0 < 16 else { return nil }
        let encoded = Int(byte1) << 8 | Int(byte2)
        switch encoded & 0xf000 {
            case 0x0000: return .touch(encoded & 0x0fff)
            case 0x1000: return .strikeVelocity(encoded & 0x0fff)
            case 0x2000: return .touchRelease
            case 0x3000: return .release
            case 0x4000: return .pressure(encoded & 0x0fff)
            default: return nil
        }
    }

    /// Bench-verified neutral record emitted by bcdDevice 0x0146 while other
    /// pads move. It is distinct from the real index-13 stream in slot 0.
    public var isKnownNeutralSentinel: Bool {
        slotIndex == 3 && bytes == [0x0d, 0x40, 0x00]
    }

    public init(slotIndex: Int, byte0: UInt8, byte1: UInt8, byte2: UInt8) {
        self.slotIndex = slotIndex
        self.byte0 = byte0
        self.byte1 = byte1
        self.byte2 = byte2
    }
}

public enum MaschineMK3PadInputValue: Sendable, Equatable {
    /// Contact below the hardware's strike threshold (`0x0xxx`).
    case touch(Int)
    /// Native 12-bit hit-strength value, observed as `0x1xxx`.
    case strikeVelocity(Int)
    /// Release after a touch-only contact (`0x2xxx`).
    case touchRelease
    /// Release after a triggered strike (`0x3xxx`).
    case release
    /// Native 12-bit held-pressure value, observed as `0x4000...0x4fff`.
    case pressure(Int)
}

public struct MaschineMK3PadInput: Sendable, Equatable {
    public var slotIndex: Int
    public var hardwareIndex: Int
    public var value: MaschineMK3PadInputValue
    public var encodedValue: Int

    public var physicalPadNumber: Int {
        (3 - hardwareIndex / 4) * 4 + hardwareIndex % 4 + 1
    }

    public init(
        slotIndex: Int,
        hardwareIndex: Int,
        value: MaschineMK3PadInputValue,
        encodedValue: Int
    ) {
        self.slotIndex = slotIndex
        self.hardwareIndex = hardwareIndex
        self.value = value
        self.encodedValue = encodedValue
    }
}

/// Interpretation of one MK3 pad record. `hardwareIndex` and `pressure` follow
/// cabl, ktemkin, and openAV-Ctlra; the physical 4x4 ordering was subsequently
/// verified with a controlled Pad 1...16 pass on bcdDevice 0x0146.
public struct MaschineMK3PadSample: Sendable, Equatable {
    public var slotIndex: Int
    public var hardwareIndex: Int
    public var pressure: Int
    public var encodedValue: Int

    public var normalizedPressure: Double {
        Double(pressure) / Double(MaschineMK3Protocol.padMaximumPressure)
    }

    /// Physical panel number verified by a controlled Pad 1...16 pass.
    public var physicalPadNumber: Int {
        (3 - hardwareIndex / 4) * 4 + hardwareIndex % 4 + 1
    }

    public init(slotIndex: Int, hardwareIndex: Int, pressure: Int, encodedValue: Int) {
        self.slotIndex = slotIndex
        self.hardwareIndex = hardwareIndex
        self.pressure = pressure
        self.encodedValue = encodedValue
    }
}

public enum MaschineMK3PadEventPhase: String, Sendable {
    case touch
    case down
    case pressure
    case up
}

public struct MaschineMK3PadEvent: Sendable, Equatable, CustomStringConvertible {
    public var hardwareIndex: Int
    public var phase: MaschineMK3PadEventPhase
    public var pressure: Int
    public var strikeVelocity: Int?
    public var encodedValue: Int

    public var physicalPadNumber: Int {
        (3 - hardwareIndex / 4) * 4 + hardwareIndex % 4 + 1
    }

    public var description: String {
        switch phase {
            case .touch:
                "pad \(physicalPadNumber) touch pressure=\(pressure)"
            case .down:
                if let strikeVelocity {
                    "pad \(physicalPadNumber) down velocity=\(strikeVelocity)"
                } else {
                    "pad \(physicalPadNumber) down pressure=\(pressure)"
                }
            case .pressure:
                "pad \(physicalPadNumber) pressure=\(pressure)"
            case .up:
                "pad \(physicalPadNumber) up"
        }
    }

    public init(
        hardwareIndex: Int,
        phase: MaschineMK3PadEventPhase,
        pressure: Int,
        strikeVelocity: Int? = nil,
        encodedValue: Int
    ) {
        self.hardwareIndex = hardwareIndex
        self.phase = phase
        self.pressure = pressure
        self.strikeVelocity = strikeVelocity
        self.encodedValue = encodedValue
    }
}

/// Stateful strike/pressure/release decoder for sparse MK3 pad reports. It also
/// accepts pressure-only streams so older firmware/captures cannot leave a pad
/// stuck when an explicit strike or release word is absent.
public struct MaschineMK3PadStateTracker: Sendable {
    public private(set) var pressures: [Int]
    public private(set) var heldPads: [Bool]

    public init() {
        pressures = [Int](repeating: 0, count: 16)
        heldPads = [Bool](repeating: false, count: 16)
    }

    public mutating func events(for inputs: [MaschineMK3PadInput]) -> [MaschineMK3PadEvent] {
        var events: [MaschineMK3PadEvent] = []
        let explicitContactPads = Set(inputs.compactMap { input -> Int? in
            switch input.value {
                case .touch, .strikeVelocity:
                    input.hardwareIndex
                case .touchRelease, .release, .pressure:
                    nil
            }
        })
        // bcdDevice 0x0146 (MK3 firmware 1.4.6) emits a spurious touchRelease
        // for Pad 14 (hw idx 1) in slot 4 alongside a non-zero pressure record
        // in slot 0 for the same pad — every report, for the entire hold. The
        // touchRelease resets heldPads, so the next report's pressure re-triggers
        // a .down, producing dozens of noteOn/noteOff pairs for a single hit.
        // When a report contains both an active contact signal (touch, strike,
        // or non-zero pressure) and a touchRelease for the same pad, the
        // contact signal is authoritative and the touchRelease is suppressed.
        let padsWithActiveContact = Set(inputs.compactMap { input -> Int? in
            switch input.value {
                case .touch, .strikeVelocity:
                    input.hardwareIndex
                case let .pressure(pressure) where pressure > 0:
                    input.hardwareIndex
                case .touchRelease, .release, .pressure:
                    nil
            }
        })
        for input in inputs {
            let index = input.hardwareIndex
            guard pressures.indices.contains(index) else { continue }
            switch input.value {
                case let .touch(pressure):
                    heldPads[index] = true
                    pressures[index] = pressure
                    events.append(MaschineMK3PadEvent(
                        hardwareIndex: index,
                        phase: .touch,
                        pressure: pressure,
                        encodedValue: input.encodedValue
                    ))

                case let .strikeVelocity(rawVelocity):
                    heldPads[index] = true
                    pressures[index] = 0
                    events.append(MaschineMK3PadEvent(
                        hardwareIndex: index,
                        phase: .down,
                        pressure: 0,
                        strikeVelocity: rawVelocity,
                        encodedValue: input.encodedValue
                    ))

                case let .pressure(pressure):
                    let previous = pressures[index]
                    guard previous != pressure else { continue }
                    pressures[index] = pressure
                    if pressure > 0, !heldPads[index] {
                        // Some reports contain an early pressure record and a
                        // native touch/strike record for the same contact. Let
                        // the explicit record supply attack velocity instead
                        // of publishing two downs for one physical hit.
                        guard !explicitContactPads.contains(index) else { continue }
                        heldPads[index] = true
                        events.append(MaschineMK3PadEvent(
                            hardwareIndex: index,
                            phase: .down,
                            pressure: pressure,
                            encodedValue: input.encodedValue
                        ))
                    } else if pressure == 0, heldPads[index] {
                        heldPads[index] = false
                        events.append(MaschineMK3PadEvent(
                            hardwareIndex: index,
                            phase: .up,
                            pressure: 0,
                            encodedValue: input.encodedValue
                        ))
                    } else if pressure > 0 {
                        events.append(MaschineMK3PadEvent(
                            hardwareIndex: index,
                            phase: .pressure,
                            pressure: pressure,
                            encodedValue: input.encodedValue
                        ))
                    }

                case .touchRelease:
                    // Suppress spurious touchRelease when the same report also
                    // carries an active contact signal for this pad (firmware
                    // 1.4.6 quirk on Pad 14). The pressure/touch stream is
                    // authoritative.
                    guard !padsWithActiveContact.contains(index) else { continue }
                    guard heldPads[index] else { continue }
                    heldPads[index] = false
                    pressures[index] = 0
                    events.append(MaschineMK3PadEvent(
                        hardwareIndex: index,
                        phase: .up,
                        pressure: 0,
                        encodedValue: input.encodedValue
                    ))

                case .release:
                    guard heldPads[index] else { continue }
                    heldPads[index] = false
                    pressures[index] = 0
                    events.append(MaschineMK3PadEvent(
                        hardwareIndex: index,
                        phase: .up,
                        pressure: 0,
                        encodedValue: input.encodedValue
                    ))
            }
        }
        return events
    }

    /// Compatibility entry point for pressure-only source fixtures.
    public mutating func events(for samples: [MaschineMK3PadSample]) -> [MaschineMK3PadEvent] {
        events(for: samples.map {
            MaschineMK3PadInput(
                slotIndex: $0.slotIndex,
                hardwareIndex: $0.hardwareIndex,
                value: .pressure($0.pressure),
                encodedValue: $0.encodedValue
            )
        })
    }
}

public enum MaschineMK3InputReportLayout {
    public struct ButtonBit: Sendable, Equatable {
        public var byte: Int
        public var mask: UInt8
        public var button: MaschineMK3Button

        public init(byte: Int, mask: UInt8, button: MaschineMK3Button) {
            self.byte = byte
            self.mask = mask
            self.button = button
        }
    }

    /// Shared by the production decoder and simulator builder. Keeping the bit map public
    /// to the module boundary prevents the simulator from maintaining a drifting copy.
    public static let buttonBits: [ButtonBit] = [
        ButtonBit(byte: 1, mask: 0x01, button: .mainEncoderPress),
        ButtonBit(byte: 1, mask: 0x04, button: .mainEncoderUp),
        ButtonBit(byte: 1, mask: 0x08, button: .mainEncoderRight),
        ButtonBit(byte: 1, mask: 0x10, button: .mainEncoderDown),
        ButtonBit(byte: 1, mask: 0x20, button: .mainEncoderLeft),
        ButtonBit(byte: 1, mask: 0x40, button: .shift),
        ButtonBit(byte: 1, mask: 0x80, button: .displayButton8),
        ButtonBit(byte: 2, mask: 0x01, button: .groupA),
        ButtonBit(byte: 2, mask: 0x02, button: .groupB),
        ButtonBit(byte: 2, mask: 0x04, button: .groupC),
        ButtonBit(byte: 2, mask: 0x08, button: .groupD),
        ButtonBit(byte: 2, mask: 0x10, button: .groupE),
        ButtonBit(byte: 2, mask: 0x20, button: .groupF),
        ButtonBit(byte: 2, mask: 0x40, button: .groupG),
        ButtonBit(byte: 2, mask: 0x80, button: .groupH),
        ButtonBit(byte: 3, mask: 0x01, button: .notes),
        ButtonBit(byte: 3, mask: 0x02, button: .volume),
        ButtonBit(byte: 3, mask: 0x04, button: .swing),
        ButtonBit(byte: 3, mask: 0x08, button: .tempo),
        ButtonBit(byte: 3, mask: 0x10, button: .noteRepeat),
        ButtonBit(byte: 3, mask: 0x20, button: .lock),
        ButtonBit(byte: 4, mask: 0x01, button: .padMode),
        ButtonBit(byte: 4, mask: 0x02, button: .keyboard),
        ButtonBit(byte: 4, mask: 0x04, button: .chords),
        ButtonBit(byte: 4, mask: 0x08, button: .step),
        ButtonBit(byte: 4, mask: 0x10, button: .fixedVelocity),
        ButtonBit(byte: 4, mask: 0x20, button: .scene),
        ButtonBit(byte: 4, mask: 0x40, button: .pattern),
        ButtonBit(byte: 4, mask: 0x80, button: .events),
        ButtonBit(byte: 5, mask: 0x02, button: .variation),
        ButtonBit(byte: 5, mask: 0x04, button: .duplicate),
        ButtonBit(byte: 5, mask: 0x08, button: .select),
        ButtonBit(byte: 5, mask: 0x10, button: .solo),
        ButtonBit(byte: 5, mask: 0x20, button: .mute),
        ButtonBit(byte: 5, mask: 0x40, button: .pitch),
        ButtonBit(byte: 5, mask: 0x80, button: .mod),
        ButtonBit(byte: 6, mask: 0x01, button: .perform),
        ButtonBit(byte: 6, mask: 0x02, button: .restart),
        ButtonBit(byte: 6, mask: 0x04, button: .erase),
        ButtonBit(byte: 6, mask: 0x08, button: .tap),
        ButtonBit(byte: 6, mask: 0x10, button: .follow),
        ButtonBit(byte: 6, mask: 0x20, button: .play),
        ButtonBit(byte: 6, mask: 0x40, button: .record),
        ButtonBit(byte: 6, mask: 0x80, button: .stop),
        ButtonBit(byte: 7, mask: 0x01, button: .macro),
        ButtonBit(byte: 7, mask: 0x02, button: .settings),
        ButtonBit(byte: 7, mask: 0x04, button: .arrowRight),
        ButtonBit(byte: 7, mask: 0x08, button: .sampling),
        ButtonBit(byte: 7, mask: 0x10, button: .mixer),
        ButtonBit(byte: 7, mask: 0x20, button: .plugin),
        ButtonBit(byte: 8, mask: 0x01, button: .channel),
        ButtonBit(byte: 8, mask: 0x02, button: .arranger),
        ButtonBit(byte: 8, mask: 0x04, button: .browser),
        ButtonBit(byte: 8, mask: 0x08, button: .arrowLeft),
        ButtonBit(byte: 8, mask: 0x10, button: .file),
        ButtonBit(byte: 8, mask: 0x20, button: .auto),
        ButtonBit(byte: 9, mask: 0x01, button: .displayButton1),
        ButtonBit(byte: 9, mask: 0x02, button: .displayButton2),
        ButtonBit(byte: 9, mask: 0x04, button: .displayButton3),
        ButtonBit(byte: 9, mask: 0x08, button: .displayButton4),
        ButtonBit(byte: 9, mask: 0x10, button: .displayButton5),
        ButtonBit(byte: 9, mask: 0x20, button: .displayButton6),
        ButtonBit(byte: 9, mask: 0x40, button: .displayButton7),
    ]
}

public enum MaschineMK3InputReportDecoder {

    public static func observe(previous: [UInt8]?, current: [UInt8]) -> MaschineMK3InputReportObservation {
        guard let reportID = current.first else {
            return MaschineMK3InputReportObservation(
                kind: .unknown,
                reportID: nil,
                actualLength: 0,
                expectedLength: nil,
                changedIndices: []
            )
        }

        let kind: MaschineMK3InputReportKind
        let expectedLength: Int?
        switch reportID {
            case MaschineMK3Protocol.surfaceReportID:
                kind = .surface
                expectedLength = MaschineMK3Protocol.surfaceReportSize
            case MaschineMK3Protocol.padReportID:
                kind = .pads
                expectedLength = MaschineMK3Protocol.padReportSize
            default:
                kind = .unknown
                expectedLength = nil
        }

        let changedIndices: [Int]
        if let previous,
           previous.first == reportID,
           previous.count == current.count {
            changedIndices = current.indices.filter { current[$0] != previous[$0] }
        } else {
            changedIndices = []
        }

        return MaschineMK3InputReportObservation(
            kind: kind,
            reportID: reportID,
            actualLength: current.count,
            expectedLength: expectedLength,
            changedIndices: changedIndices
        )
    }

    /// Returns non-zero raw slots from a complete report `0x02`. Bench captures
    /// establish the 21x3-byte packing, but not the meaning of each byte.
    public static func padRecords(in report: [UInt8]) -> [MaschineMK3PadRecord] {
        guard report.count == MaschineMK3Protocol.padReportSize,
              report.first == MaschineMK3Protocol.padReportID else { return [] }

        return stride(from: 1, to: report.count, by: 3).compactMap { offset in
            let record = MaschineMK3PadRecord(
                slotIndex: (offset - 1) / 3,
                byte0: report[offset],
                byte1: report[offset + 1],
                byte2: report[offset + 2]
            )
            return record.bytes.allSatisfy { $0 == 0 } ? nil : record
        }
    }

    /// Decodes the complete bench-observed pad lifecycle: touch or 12-bit
    /// strike, zero or more 12-bit pressure values, and a matching release.
    public static func padInputs(in report: [UInt8]) -> [MaschineMK3PadInput] {
        padRecords(in: report).compactMap { record in
            guard !record.isKnownNeutralSentinel,
                  let value = record.inputValue else { return nil }
            return MaschineMK3PadInput(
                slotIndex: record.slotIndex,
                hardwareIndex: Int(record.byte0),
                value: value,
                encodedValue: Int(record.byte1) << 8 | Int(record.byte2)
            )
        }
    }

    /// Decodes records whose source-documented `0x4xxx` marker and 0...15 pad
    /// index are both valid. Unknown/non-pad records remain available through
    /// `padRecords(in:)`.
    public static func padSamples(in report: [UInt8]) -> [MaschineMK3PadSample] {
        padRecords(in: report).compactMap { record in
            guard record.isSourceEncodedPadSample else { return nil }
            // bcdDevice 0x0146 emits this neutral sentinel in record slot 3
            // throughout unrelated pad activity. The real hardware-index 13
            // pressure stream simultaneously occupies slot 0 when Pad 2 moves.
            guard !record.isKnownNeutralSentinel else { return nil }
            return MaschineMK3PadSample(
                slotIndex: record.slotIndex,
                hardwareIndex: Int(record.byte0),
                pressure: Int(record.byte1 & 0x0f) << 8 | Int(record.byte2),
                encodedValue: Int(record.byte1) << 8 | Int(record.byte2)
            )
        }
    }

    public static func surfaceEvents(previous: [UInt8]?, current: [UInt8]) -> [MaschineMK3SurfaceEvent] {
        guard current.count == MaschineMK3Protocol.surfaceReportSize,
              current.first == MaschineMK3Protocol.surfaceReportID else { return [] }
        let previous = if let previous,
                          previous.count == current.count,
                          previous.first == current.first {
            previous
        } else {
            initialEventBaseline(current: current)
        }

        var events: [MaschineMK3SurfaceEvent] = []
        var explained = Set<Int>()

        for bit in MaschineMK3InputReportLayout.buttonBits {
            let wasPressed = previous[bit.byte] & bit.mask != 0
            let isPressed = current[bit.byte] & bit.mask != 0
            if wasPressed != isPressed {
                events.append(.button(button: bit.button, pressed: isPressed))
                explained.insert(bit.byte)
            }
        }

        let oldMain = Int(previous[11] & 0x0f)
        let newMain = Int(current[11] & 0x0f)
        if oldMain != newMain {
            let delta = wrappedDelta(from: oldMain, to: newMain, modulo: 16)
            if delta != 0 {
                events.append(.encoder(index: 0, delta: delta, value: newMain))
            }
            explained.insert(11)
        }

        for index in 0..<8 {
            let offset = 12 + index * 2
            let oldValue = word(previous, offset: offset, highMask: 0x03)
            let newValue = word(current, offset: offset, highMask: 0x03)
            if oldValue != newValue {
                let delta = wrappedDelta(from: oldValue, to: newValue, modulo: 1000)
                if delta != 0 {
                    events.append(.encoder(index: index + 1, delta: delta, value: newValue))
                }
                explained.insert(offset)
                explained.insert(offset + 1)
            }
        }

        if (previous[9] & 0x80) != (current[9] & 0x80) {
            events.append(.encoderTouch(index: 0, touched: current[9] & 0x80 != 0))
            explained.insert(9)
        }
        if previous[10] != current[10] {
            for index in 0..<8 {
                let mask = UInt8(0x80 >> index)
                let wasTouched = previous[10] & mask != 0
                let isTouched = current[10] & mask != 0
                if wasTouched != isTouched {
                    events.append(.encoderTouch(index: index + 1, touched: isTouched))
                }
            }
            explained.insert(10)
        }

        for finger in 0..<2 {
            let offset = 30 + finger * 4
            let oldPosition = word(previous, offset: offset, highMask: 0x03)
            let newPosition = word(current, offset: offset, highMask: 0x03)
            if oldPosition != newPosition {
                events.append(.touchStrip(finger: finger + 1, position: newPosition == 0 ? nil : newPosition))
                explained.insert(offset)
                explained.insert(offset + 1)
            }
        }

        let analogControls: [(offset: Int, control: MaschineMK3AnalogControl)] = [
            (36, .microphoneGain),
            (38, .headphoneVolume),
            (40, .masterVolume),
        ]
        for item in analogControls {
            let oldValue = word(previous, offset: item.offset)
            let newValue = word(current, offset: item.offset)
            if oldValue != newValue {
                events.append(.analog(control: item.control, value: newValue))
                explained.insert(item.offset)
                explained.insert(item.offset + 1)
            }
        }

        let unknownChanges = current.indices.filter {
            $0 != 0 && previous[$0] != current[$0] && !explained.contains($0)
        }
        if !unknownChanges.isEmpty {
            events.append(.rawChanged(indices: unknownChanges))
        }
        return events
    }

    /// Builds a safe comparison state for the first live report when the daemon
    /// could not supply an earlier snapshot. MK3 encoder and analogue fields are
    /// absolute state whose counters may already be non-zero; treating them as
    /// deltas from zero creates phantom edits. Known button bits remain edge-like
    /// so a first press is still delivered, and non-zero strip positions remain
    /// first contacts. Encoder touch state is retained because it arrives before
    /// rotation and therefore primes the following real counter change without
    /// inventing an unknowable first delta.
    private static func initialEventBaseline(current: [UInt8]) -> [UInt8] {
        var baseline = current
        for bit in MaschineMK3InputReportLayout.buttonBits {
            baseline[bit.byte] &= ~bit.mask
        }
        for offset in [30, 34] {
            baseline[offset] = 0
            baseline[offset + 1] &= ~0x03
        }
        return baseline
    }

    private static func word(_ bytes: [UInt8], offset: Int, highMask: UInt8 = 0xff) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1] & highMask) << 8
    }

    private static func wrappedDelta(from old: Int, to new: Int, modulo: Int) -> Int {
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
