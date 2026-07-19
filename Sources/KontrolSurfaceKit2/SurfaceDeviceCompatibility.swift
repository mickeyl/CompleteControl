import Foundation
import KompleteKontrol

struct KontrolSurfaceOutputReport: Equatable, Sendable {
    var reportID: UInt8
    var payload: [UInt8]
}

struct KontrolSurfaceLampValue: Equatable, Sendable {
    var color: KKRGB
    var intensity: UInt8
    var rawByte: UInt8?

    init(color: KKRGB, intensity: UInt8) {
        self.color = color
        self.intensity = intensity
        rawByte = nil
    }

    init(rawByte: UInt8) {
        color = .off
        intensity = 0
        self.rawByte = rawByte
    }
}

enum MaschineMK3CompatibilityInput: Equatable, Sendable {
    case button(KKMK2ButtonLED)
    case jog(direction: String, lamp: KKMK2ButtonLED)
    case jogCenterOnRelease

    var logicalLamp: KKMK2ButtonLED? {
        switch self {
            case let .button(lamp), let .jog(_, lamp):
                lamp
            case .jogCenterOnRelease:
                nil
        }
    }
}

struct MaschineMK3CompatibilityMapping: Equatable, Sendable {
    var physicalButton: MaschineMK3Button
    var input: MaschineMK3CompatibilityInput
}

/// The one-to-one compatibility vocabulary shared by MK3 input and lamp output.
/// Controls without an honest MK2 equivalent deliberately do not appear here.
enum KontrolSurfaceDeviceCompatibility {
    /// MK3 LED payload order is row-major from the bottom-right, while Kit2 pad
    /// indices follow the printed panel numbers. Keep this explicit so neither
    /// callers nor MIDI mappings need to know about the wire layout.
    static let maschineMK3PerformancePadLEDs: [MaschineMK3PadLED] = [
        .pad1, .pad2, .pad3, .pad4,
        .pad5, .pad6, .pad7, .pad8,
        .pad9, .pad10, .pad11, .pad12,
        .pad13, .pad14, .pad15, .pad16,
    ]

    static let maschineMK3Mappings: [MaschineMK3CompatibilityMapping] = [
        MaschineMK3CompatibilityMapping(physicalButton: .mainEncoderPress, input: .jogCenterOnRelease),
        MaschineMK3CompatibilityMapping(physicalButton: .mainEncoderUp, input: .jog(direction: "up", lamp: .jogUp)),
        MaschineMK3CompatibilityMapping(physicalButton: .mainEncoderRight, input: .jog(direction: "right", lamp: .jogRight)),
        MaschineMK3CompatibilityMapping(physicalButton: .mainEncoderDown, input: .jog(direction: "down", lamp: .jogDown)),
        MaschineMK3CompatibilityMapping(physicalButton: .mainEncoderLeft, input: .jog(direction: "left", lamp: .jogLeft)),
        MaschineMK3CompatibilityMapping(physicalButton: .shift, input: .button(.shift)),
        MaschineMK3CompatibilityMapping(physicalButton: .groupA, input: .button(.instrument1)),
        MaschineMK3CompatibilityMapping(physicalButton: .groupB, input: .button(.instrument2)),
        MaschineMK3CompatibilityMapping(physicalButton: .groupC, input: .button(.instrument3)),
        MaschineMK3CompatibilityMapping(physicalButton: .groupD, input: .button(.instrument4)),
        MaschineMK3CompatibilityMapping(physicalButton: .groupE, input: .button(.instrument5)),
        MaschineMK3CompatibilityMapping(physicalButton: .groupF, input: .button(.instrument6)),
        MaschineMK3CompatibilityMapping(physicalButton: .groupG, input: .button(.instrument7)),
        MaschineMK3CompatibilityMapping(physicalButton: .groupH, input: .button(.instrument8)),
        MaschineMK3CompatibilityMapping(physicalButton: .tempo, input: .button(.tempo)),
        MaschineMK3CompatibilityMapping(physicalButton: .padMode, input: .button(.keyMode)),
        MaschineMK3CompatibilityMapping(physicalButton: .fixedVelocity, input: .button(.fixedVel)),
        MaschineMK3CompatibilityMapping(physicalButton: .scene, input: .button(.scene)),
        MaschineMK3CompatibilityMapping(physicalButton: .pattern, input: .button(.pattern)),
        MaschineMK3CompatibilityMapping(physicalButton: .variation, input: .button(.variation)),
        MaschineMK3CompatibilityMapping(physicalButton: .solo, input: .button(.s)),
        MaschineMK3CompatibilityMapping(physicalButton: .mute, input: .button(.m)),
        MaschineMK3CompatibilityMapping(physicalButton: .erase, input: .button(.clear)),
        MaschineMK3CompatibilityMapping(physicalButton: .play, input: .button(.play)),
        MaschineMK3CompatibilityMapping(physicalButton: .record, input: .button(.record)),
        MaschineMK3CompatibilityMapping(physicalButton: .stop, input: .button(.stop)),
        MaschineMK3CompatibilityMapping(physicalButton: .settings, input: .button(.setup)),
        MaschineMK3CompatibilityMapping(physicalButton: .arrowRight, input: .button(.pageRight)),
        MaschineMK3CompatibilityMapping(physicalButton: .mixer, input: .button(.mixer)),
        MaschineMK3CompatibilityMapping(physicalButton: .plugin, input: .button(.plugin)),
        MaschineMK3CompatibilityMapping(physicalButton: .channel, input: .button(.track)),
        MaschineMK3CompatibilityMapping(physicalButton: .browser, input: .button(.browser)),
        MaschineMK3CompatibilityMapping(physicalButton: .arrowLeft, input: .button(.pageLeft)),
        MaschineMK3CompatibilityMapping(physicalButton: .auto, input: .button(.auto)),
        MaschineMK3CompatibilityMapping(physicalButton: .displayButton1, input: .button(.function1)),
        MaschineMK3CompatibilityMapping(physicalButton: .displayButton2, input: .button(.function2)),
        MaschineMK3CompatibilityMapping(physicalButton: .displayButton3, input: .button(.function3)),
        MaschineMK3CompatibilityMapping(physicalButton: .displayButton4, input: .button(.function4)),
        MaschineMK3CompatibilityMapping(physicalButton: .displayButton5, input: .button(.function5)),
        MaschineMK3CompatibilityMapping(physicalButton: .displayButton6, input: .button(.function6)),
        MaschineMK3CompatibilityMapping(physicalButton: .displayButton7, input: .button(.function7)),
        MaschineMK3CompatibilityMapping(physicalButton: .displayButton8, input: .button(.function8)),
    ]

    private static let maschineMK3MappingsByButton = Dictionary(
        uniqueKeysWithValues: maschineMK3Mappings.map { ($0.physicalButton, $0) }
    )

    static func mapping(for physicalButton: MaschineMK3Button) -> MaschineMK3CompatibilityMapping? {
        maschineMK3MappingsByButton[physicalButton]
    }

    static func hostControlReports(for family: KontrolDeviceFamily) -> [KontrolSurfaceOutputReport] {
        switch family {
            case .kompleteKontrolMK2:
                [
                    KontrolSurfaceOutputReport(
                        reportID: KompleteKontrolMK2Protocol.initReportID,
                        payload: KompleteKontrolMK2Protocol.initModeHostControl
                    ),
                    KontrolSurfaceOutputReport(
                        reportID: KompleteKontrolMK2Protocol.wheelStripMapReportID,
                        payload: KompleteKontrolMK2Protocol.wheelStripMapPayload(strip: .cc(number: 11))
                    ),
                    KontrolSurfaceOutputReport(
                        reportID: KompleteKontrolMK2Protocol.mapCommitReportID,
                        payload: KompleteKontrolMK2Protocol.mapCommitPayload
                    ),
                ]
            case .maschineMK3:
                // The MK3 surface interface already streams native reports after
                // it is claimed; the MK2 host-control setup reports are invalid.
                []
        }
    }

    static func lampReports(
        for family: KontrolDeviceFamily,
        lamps: [KKMK2ButtonLED: KontrolSurfaceLampValue],
        performancePads: [Int: KontrolSurfaceLampValue] = [:],
        diagnosticLEDBytes: [KontrolSurfaceDiagnosticLED: UInt8] = [:]
    ) -> [KontrolSurfaceOutputReport] {
        switch family {
            case .kompleteKontrolMK2:
                var payload = [UInt8](repeating: 0, count: KompleteKontrolMK2Protocol.buttonLEDMapSize)
                for (lamp, value) in lamps where payload.indices.contains(lamp.rawValue) {
                    payload[lamp.rawValue] = value.rawByte
                        ?? lamp.ledByte(for: value.color, intensity: value.intensity)
                }
                return [KontrolSurfaceOutputReport(
                    reportID: KompleteKontrolMK2Protocol.buttonLEDReportID,
                    payload: payload
                )]

            case .maschineMK3:
                var buttons = MaschineMK3Protocol.clearedButtonLEDPayload()
                var stripAndPads = MaschineMK3Protocol.clearedStripLEDPayload()

                for mapping in maschineMK3Mappings {
                    guard let logicalLamp = mapping.input.logicalLamp,
                          let value = lamps[logicalLamp],
                          let physicalLamp = mapping.physicalButton.led else { continue }
                    buttons[physicalLamp.rawValue] = maschineMK3ButtonByte(for: value, lamp: physicalLamp)
                }

                for logicalIndex in 0..<MaschineMK3Protocol.stripLEDCount {
                    guard let logicalLamp = KKMK2ButtonLED(
                        rawValue: KKMK2ButtonLED.strip1.rawValue + logicalIndex
                    ), let value = lamps[logicalLamp] else { continue }
                    stripAndPads[logicalIndex] = maschineMK3ColorByte(for: value)
                }

                for (panelIndex, value) in performancePads {
                    guard maschineMK3PerformancePadLEDs.indices.contains(panelIndex) else { continue }
                    let physicalLamp = maschineMK3PerformancePadLEDs[panelIndex]
                    stripAndPads[physicalLamp.rawValue] = maschineMK3PerformancePadByte(for: value)
                }

                // Diagnostic bytes deliberately win over semantic lowering so
                // a calibration scene can compare physical LED classes using
                // the exact same wire value.
                for (target, byte) in diagnosticLEDBytes {
                    switch target {
                        case let .maschineMK3Button(led):
                            buttons[led.rawValue] = byte
                        case let .maschineMK3Pad(led):
                            stripAndPads[led.rawValue] = byte
                    }
                }

                return [
                    KontrolSurfaceOutputReport(reportID: MaschineMK3Protocol.buttonLEDReportID, payload: buttons),
                    KontrolSurfaceOutputReport(reportID: MaschineMK3Protocol.stripLEDReportID, payload: stripAndPads),
                ]
        }
    }

    static func maschineMK3ButtonByte(
        for value: KontrolSurfaceLampValue,
        lamp: MaschineMK3ButtonLED
    ) -> UInt8 {
        if let rawByte = value.rawByte { return rawByte }
        guard value.color != .off, value.intensity > 0 else { return 0 }
        if lamp.usesColorEncoding {
            return maschineMK3ColorByte(
                for: value,
                monochromeWhiteCurve: lamp.usesMonochromeWhiteCurve
            )
        }
        return maschineMK3MonochromeByte(for: value.intensity)
    }

    static func maschineMK3MonochromeByte(for intensity: UInt8) -> UInt8 {
        switch min(intensity, 3) {
            case 0: 0
            case 1: MaschineMK3Protocol.monochromeDimLEDValue
            case 2: MaschineMK3Protocol.monochromeBrightLEDValue
            default: MaschineMK3Protocol.monochromePressedLEDValue
        }
    }

    /// MK3 RGB slots use the same 16 hue sectors as the MK2 palette but encode
    /// white as hue 0xff. Sampling alone routes white through the non-linear
    /// monochrome curve; its coloured palette entries remain linear like pads.
    static func maschineMK3ColorByte(
        for value: KontrolSurfaceLampValue,
        monochromeWhiteCurve: Bool = false
    ) -> UInt8 {
        if let rawByte = value.rawByte { return rawByte }
        guard value.color != .off, value.intensity > 0 else { return 0 }
        let intensity = min(value.intensity, 3)
        let mk2Code = KompleteKontrolSSeriesMK2.paletteCode(for: value.color, intensity: intensity)
        let paletteIndex = mk2Code >> 2
        let hue: UInt8 = paletteIndex == 17 ? 0xff : paletteIndex
        let brightnessBits = monochromeWhiteCurve && hue == 0xff
            ? maschineMK3MonochromeByte(for: intensity) & 0x03
            : intensity
        return (hue &<< 2) | brightnessBits
    }

    /// Performance pads expose four visible brightness levels numbered 0...3;
    /// byte zero remains the separate off state when no color is present.
    static func maschineMK3PerformancePadByte(for value: KontrolSurfaceLampValue) -> UInt8 {
        if let rawByte = value.rawByte { return rawByte }
        guard value.color != .off else { return 0 }
        let intensity = min(value.intensity, 3)
        let mk2Code = KompleteKontrolSSeriesMK2.paletteCode(for: value.color, intensity: intensity)
        let paletteIndex = mk2Code >> 2
        let hue: UInt8 = paletteIndex == 17 ? 0xff : paletteIndex
        return (hue &<< 2) | intensity
    }
}

struct KontrolSurfaceInputAdapter: Sendable {
    private(set) var family: KontrolDeviceFamily
    private var previousReports: [UInt8: [UInt8]] = [:]
    private var maschineTouchPositions: [Int?] = [nil, nil]
    private var maschinePadState = MaschineMK3PadStateTracker()

    init(family: KontrolDeviceFamily = .kompleteKontrolMK2) {
        self.family = family
    }

    mutating func select(family: KontrolDeviceFamily) {
        guard self.family.rawValue != family.rawValue else {
            reset()
            return
        }
        self.family = family
        reset()
    }

    mutating func reset() {
        previousReports.removeAll(keepingCapacity: true)
        maschineTouchPositions = [nil, nil]
        maschinePadState = MaschineMK3PadStateTracker()
    }

    /// Installs a daemon-provided state snapshot without emitting an input
    /// event. Live reports that follow it can therefore decode their very first
    /// encoder step against the real device counters.
    mutating func prime(with bytes: [UInt8]) {
        guard let reportID = bytes.first else { return }
        previousReports[reportID] = bytes
        guard family == .maschineMK3,
              reportID == MaschineMK3Protocol.surfaceReportID,
              bytes.count == MaschineMK3Protocol.surfaceReportSize else { return }
        maschineTouchPositions = [30, 34].map { offset in
            let position = Int(bytes[offset]) | Int(bytes[offset + 1] & 0x03) << 8
            return position == 0 ? nil : position
        }
    }

    mutating func events(for bytes: [UInt8], timestampNanos: UInt64) -> [KKMK2InputEvent] {
        guard let reportID = bytes.first else { return [] }
        switch family {
            case .kompleteKontrolMK2:
                let events = KKMK2InputReportDecoder.eventsForReport(
                    previous: previousReports[reportID],
                    current: bytes
                )
                if reportID == UInt8(KompleteKontrolMK2Protocol.inputReportID) {
                    previousReports[reportID] = bytes
                }
                return events

            case .maschineMK3:
                let previous: [UInt8]?
                if let cached = previousReports[reportID] {
                    previous = cached
                } else if reportID == MaschineMK3Protocol.surfaceReportID {
                    // The MK3 only interrupts on a changed surface state, so a
                    // newly registered client may receive the first physical
                    // encoder turn before it has ever seen an idle report.
                    // Seed the decoder with the neutral report rather than
                    // silently consuming that first real gesture as a baseline.
                    previous = initialMaschineMK3SurfaceBaseline(for: bytes)
                } else {
                    previous = nil
                }
                let nativeEvents = MaschineMK3InputReportDecoder.surfaceEvents(
                    previous: previous,
                    current: bytes
                )
                if reportID == MaschineMK3Protocol.surfaceReportID {
                    previousReports[reportID] = bytes
                }
                return lowerMaschineMK3(nativeEvents, timestampNanos: timestampNanos)
        }
    }

    mutating func padEvents(
        for bytes: [UInt8],
        timestampNanos: UInt64
    ) -> [KontrolSurfacePadEvent] {
        guard family == .maschineMK3,
              bytes.first == MaschineMK3Protocol.padReportID else { return [] }
        return maschinePadState.events(
            for: MaschineMK3InputReportDecoder.padInputs(in: bytes)
        ).map { event in
            let phase: KontrolSurfacePadEvent.Phase
            switch event.phase {
                case .touch: phase = .touch
                case .down: phase = .down
                case .pressure: phase = .pressure
                case .up: phase = .up
            }
            return KontrolSurfacePadEvent(
                index: event.physicalPadNumber - 1,
                phase: phase,
                pressure: event.pressure,
                maximumPressure: MaschineMK3Protocol.padMaximumPressure,
                strikeVelocity: event.strikeVelocity,
                maximumStrikeVelocity: MaschineMK3Protocol.padMaximumStrikeVelocity,
                timestampNanos: timestampNanos
            )
        }
    }

    private mutating func lowerMaschineMK3(
        _ nativeEvents: [MaschineMK3SurfaceEvent],
        timestampNanos: UInt64
    ) -> [KKMK2InputEvent] {
        var events: [KKMK2InputEvent] = []
        let oldPrimaryTouch = primaryMaschineTouch
        var touchChanged = false

        for nativeEvent in nativeEvents {
            switch nativeEvent {
                case let .button(button, pressed):
                    guard let mapping = KontrolSurfaceDeviceCompatibility.mapping(for: button) else { continue }
                    switch mapping.input {
                        case let .button(lamp):
                            events.append(.button(led: lamp, pressed: pressed))
                        case let .jog(direction, _):
                            if pressed {
                                events.append(.jog(direction: direction))
                            }
                        case .jogCenterOnRelease:
                            if !pressed {
                                events.append(.jogCenter)
                            }
                    }

                case let .encoder(index, delta, value):
                    if index == 0 {
                        events.append(.jogScroll(delta: delta, value: value))
                    } else if (1...8).contains(index) {
                        events.append(.knob(index: index, delta: delta, value: value))
                    }

                case let .encoderTouch(index, touched):
                    if index == 0 {
                        events.append(.jogTouch(touched: touched))
                    } else if (1...8).contains(index) {
                        events.append(.touchEncoder(index: index, touched: touched))
                    }

                case let .touchStrip(finger, position):
                    let index = finger - 1
                    guard maschineTouchPositions.indices.contains(index) else { continue }
                    maschineTouchPositions[index] = position
                    touchChanged = true

                case .analog, .rawChanged:
                    break
            }
        }

        if touchChanged, oldPrimaryTouch != primaryMaschineTouch {
            let timeMilliseconds = Int((timestampNanos / 1_000_000) & 0xffff)
            events.append(.strip(position: primaryMaschineTouch, time: timeMilliseconds))
        }
        return events
    }

    private var primaryMaschineTouch: Int? {
        maschineTouchPositions[0] ?? maschineTouchPositions[1]
    }

    private func initialMaschineMK3SurfaceBaseline(for bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count == MaschineMK3Protocol.surfaceReportSize,
              bytes.first == MaschineMK3Protocol.surfaceReportID else { return nil }
        return [MaschineMK3Protocol.surfaceReportID]
            + [UInt8](repeating: 0, count: MaschineMK3Protocol.surfaceReportSize - 1)
    }
}
