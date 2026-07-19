import KompleteKontrol
import Testing

@Suite("MASCHINE MK3 protocol")
struct MaschineMK3ProtocolTests {
    @Test("device profile exposes the safe first-class capability boundary")
    func deviceProfile() throws {
        let profile = try #require(KontrolDeviceProfile.productID(MaschineMK3Protocol.productID))

        #expect(profile.family == .maschineMK3)
        #expect(profile.name == "MASCHINE MK3")
        #expect(profile.capabilities.screenCount == 2)
        #expect(profile.capabilities.keyCount == 0)
        #expect(profile.capabilities.padCount == 16)
        #expect(!profile.capabilities.hasLightGuide)
        #expect(profile.capabilities.hasTouchStrip)
        #expect(!profile.capabilities.claimsUSBMIDI)
    }

    @Test("verified HID report lengths are classified")
    func reportLengths() {
        let surface = MaschineMK3InputReportDecoder.observe(
            previous: nil,
            current: [MaschineMK3Protocol.surfaceReportID]
                + [UInt8](repeating: 0, count: MaschineMK3Protocol.surfaceReportSize - 1)
        )
        let pads = MaschineMK3InputReportDecoder.observe(
            previous: nil,
            current: [MaschineMK3Protocol.padReportID]
                + [UInt8](repeating: 0, count: MaschineMK3Protocol.padReportSize - 1)
        )

        #expect(surface.kind == .surface)
        #expect(surface.hasValidLength)
        #expect(surface.changedIndices.isEmpty)
        #expect(pads.kind == .pads)
        #expect(pads.hasValidLength)
        #expect(pads.changedIndices.isEmpty)
    }

    @Test("successive reports expose only changed byte indices")
    func reportDiff() {
        let previous = [MaschineMK3Protocol.surfaceReportID]
            + [UInt8](repeating: 0, count: MaschineMK3Protocol.surfaceReportSize - 1)
        var current = previous
        current[7] = 0x12
        current[41] = 0xff

        let observation = MaschineMK3InputReportDecoder.observe(previous: previous, current: current)

        #expect(observation.changedIndices == [7, 41])
    }

    @Test("malformed and unknown reports remain observable")
    func malformedReports() {
        let shortSurface = MaschineMK3InputReportDecoder.observe(
            previous: nil,
            current: [MaschineMK3Protocol.surfaceReportID, 0]
        )
        let unknown = MaschineMK3InputReportDecoder.observe(previous: nil, current: [0x7f])
        let empty = MaschineMK3InputReportDecoder.observe(previous: nil, current: [])

        #expect(!shortSurface.hasValidLength)
        #expect(unknown.kind == .unknown)
        #expect(unknown.expectedLength == nil)
        #expect(empty.reportID == nil)
        #expect(empty.actualLength == 0)
    }

    @Test("pad payload is exposed as 21 neutral three-byte record slots")
    func padRecordSlots() {
        var report = [UInt8](repeating: 0, count: MaschineMK3Protocol.padReportSize)
        report[0] = MaschineMK3Protocol.padReportID
        report[1] = 0x0c
        report[2] = 0x40
        report[3] = 0x85
        report[61] = 0x0f
        report[62] = 0x20
        report[63] = 0x00

        let records = MaschineMK3InputReportDecoder.padRecords(in: report)

        #expect(records == [
            MaschineMK3PadRecord(slotIndex: 0, byte0: 0x0c, byte1: 0x40, byte2: 0x85),
            MaschineMK3PadRecord(slotIndex: 20, byte0: 0x0f, byte1: 0x20, byte2: 0x00),
        ])
        #expect(MaschineMK3InputReportDecoder.padRecords(in: [0x02, 0x01]).isEmpty)
    }

    @Test("source-derived pad samples preserve hardware index and 12-bit pressure")
    func padSamples() {
        var report = [UInt8](repeating: 0, count: MaschineMK3Protocol.padReportSize)
        report[0] = MaschineMK3Protocol.padReportID
        report[1] = 0x00
        report[2] = 0x40
        report[3] = 0x85
        report[4] = 0x0c
        report[5] = 0x4f
        report[6] = 0xfd
        report[7] = 0x10
        report[8] = 0x40
        report[9] = 0x01

        #expect(MaschineMK3InputReportDecoder.padSamples(in: report) == [
            MaschineMK3PadSample(slotIndex: 0, hardwareIndex: 0, pressure: 0x085, encodedValue: 0x4085),
            MaschineMK3PadSample(slotIndex: 1, hardwareIndex: 12, pressure: 0xffd, encodedValue: 0x4ffd),
        ])
    }

    @Test("bench pad words distinguish touch, 12-bit strike, pressure, and releases")
    func padInputs() {
        var report = [UInt8](repeating: 0, count: MaschineMK3Protocol.padReportSize)
        report[0] = MaschineMK3Protocol.padReportID
        report[1...12] = [
            0x0b, 0x00, 0x2c,
            0x0c, 0x16, 0xce,
            0x0c, 0x42, 0x77,
            0x0c, 0x30, 0x00,
        ]

        #expect(MaschineMK3InputReportDecoder.padInputs(in: report) == [
            MaschineMK3PadInput(slotIndex: 0, hardwareIndex: 11, value: .touch(0x02c), encodedValue: 0x002c),
            MaschineMK3PadInput(slotIndex: 1, hardwareIndex: 12, value: .strikeVelocity(0x6ce), encodedValue: 0x16ce),
            MaschineMK3PadInput(slotIndex: 2, hardwareIndex: 12, value: .pressure(0x277), encodedValue: 0x4277),
            MaschineMK3PadInput(slotIndex: 3, hardwareIndex: 12, value: .release, encodedValue: 0x3000),
        ])
    }

    @Test("bench sentinel is excluded while the real index-13 stream remains available")
    func padSentinel() {
        var report = [UInt8](repeating: 0, count: MaschineMK3Protocol.padReportSize)
        report[0] = MaschineMK3Protocol.padReportID
        report[1] = 0x0d
        report[2] = 0x43
        report[3] = 0x21
        report[10] = 0x0d
        report[11] = 0x40
        report[12] = 0x00

        let records = MaschineMK3InputReportDecoder.padRecords(in: report)

        #expect(records.count == 2)
        #expect(!records[0].isKnownNeutralSentinel)
        #expect(records[1].isKnownNeutralSentinel)
        #expect(MaschineMK3InputReportDecoder.padSamples(in: report) == [
            MaschineMK3PadSample(slotIndex: 0, hardwareIndex: 13, pressure: 0x321, encodedValue: 0x4321),
        ])
    }

    @Test("pad tracker preserves native strike velocity, pressure, and release")
    func padStateTracker() {
        var tracker = MaschineMK3PadStateTracker()
        let strike = MaschineMK3PadInput(slotIndex: 0, hardwareIndex: 13, value: .strikeVelocity(0x151), encodedValue: 0x1151)
        let pressure = MaschineMK3PadInput(slotIndex: 0, hardwareIndex: 13, value: .pressure(900), encodedValue: 0x4384)
        let release = MaschineMK3PadInput(slotIndex: 0, hardwareIndex: 13, value: .release, encodedValue: 0x3000)
        let zero = MaschineMK3PadInput(slotIndex: 0, hardwareIndex: 13, value: .pressure(0), encodedValue: 0x4000)

        #expect(tracker.events(for: [strike]) == [
            MaschineMK3PadEvent(hardwareIndex: 13, phase: .down, pressure: 0, strikeVelocity: 0x151, encodedValue: 0x1151),
        ])
        #expect(strike.physicalPadNumber == 2)
        #expect(tracker.events(for: [pressure]) == [
            MaschineMK3PadEvent(hardwareIndex: 13, phase: .pressure, pressure: 900, encodedValue: 0x4384),
        ])
        #expect(tracker.events(for: [release]) == [
            MaschineMK3PadEvent(hardwareIndex: 13, phase: .up, pressure: 0, encodedValue: 0x3000),
        ])
        #expect(tracker.events(for: [zero]).isEmpty)
    }

    @Test("pad tracker recovers pressure-only hits without duplicating an explicit strike")
    func pressureOnlyPadState() {
        var tracker = MaschineMK3PadStateTracker()
        let pressureOnly = MaschineMK3PadInput(
            slotIndex: 0,
            hardwareIndex: 15,
            value: .pressure(25),
            encodedValue: 0x4019
        )
        let pressureZero = MaschineMK3PadInput(
            slotIndex: 0,
            hardwareIndex: 15,
            value: .pressure(0),
            encodedValue: 0x4000
        )

        #expect(tracker.events(for: [pressureOnly]) == [
            MaschineMK3PadEvent(hardwareIndex: 15, phase: .down, pressure: 25, encodedValue: 0x4019),
        ])
        #expect(tracker.events(for: [pressureZero]) == [
            MaschineMK3PadEvent(hardwareIndex: 15, phase: .up, pressure: 0, encodedValue: 0x4000),
        ])

        let leadingPressure = MaschineMK3PadInput(
            slotIndex: 0,
            hardwareIndex: 13,
            value: .pressure(104),
            encodedValue: 0x4068
        )
        let strike = MaschineMK3PadInput(
            slotIndex: 1,
            hardwareIndex: 13,
            value: .strikeVelocity(199),
            encodedValue: 0x10c7
        )
        #expect(tracker.events(for: [leadingPressure, strike]) == [
            MaschineMK3PadEvent(hardwareIndex: 13, phase: .down, pressure: 0, strikeVelocity: 199, encodedValue: 0x10c7),
        ])
    }

    @Test("pad tracker suppresses spurious touchRelease alongside active pressure (firmware 1.4.6 Pad 14 quirk)")
    func spuriousTouchReleaseSuppressed() {
        var tracker = MaschineMK3PadStateTracker()

        // Report 1: TOUCH + spurious TOUCH_REL for hw idx 1 (Pad 14).
        // Without suppression, the TOUCH_REL would immediately release the pad.
        let touch = MaschineMK3PadInput(slotIndex: 0, hardwareIndex: 1, value: .touch(88), encodedValue: 0x0058)
        let spuriousRelease1 = MaschineMK3PadInput(slotIndex: 4, hardwareIndex: 1, value: .touchRelease, encodedValue: 0x2000)
        let report1 = tracker.events(for: [touch, spuriousRelease1])
        #expect(report1 == [
            MaschineMK3PadEvent(hardwareIndex: 1, phase: .touch, pressure: 88, encodedValue: 0x0058),
        ])

        // Report 2: PRESSURE(>0) + spurious TOUCH_REL.
        // Without suppression, PRESSURE would re-trigger .down and TOUCH_REL would .up.
        let pressure = MaschineMK3PadInput(slotIndex: 0, hardwareIndex: 1, value: .pressure(484), encodedValue: 0x41e4)
        let spuriousRelease2 = MaschineMK3PadInput(slotIndex: 4, hardwareIndex: 1, value: .touchRelease, encodedValue: 0x2000)
        let report2 = tracker.events(for: [pressure, spuriousRelease2])
        #expect(report2 == [
            MaschineMK3PadEvent(hardwareIndex: 1, phase: .pressure, pressure: 484, encodedValue: 0x41e4),
        ])

        // Report 3: Another PRESSURE change + spurious TOUCH_REL — still held, no retrigger.
        let pressure2 = MaschineMK3PadInput(slotIndex: 0, hardwareIndex: 1, value: .pressure(690), encodedValue: 0x42b2)
        let spuriousRelease3 = MaschineMK3PadInput(slotIndex: 4, hardwareIndex: 1, value: .touchRelease, encodedValue: 0x2000)
        let report3 = tracker.events(for: [pressure2, spuriousRelease3])
        #expect(report3 == [
            MaschineMK3PadEvent(hardwareIndex: 1, phase: .pressure, pressure: 690, encodedValue: 0x42b2),
        ])

        // Final report: PRESSURE(0) — the pad is actually released now.
        let pressureZero = MaschineMK3PadInput(slotIndex: 0, hardwareIndex: 1, value: .pressure(0), encodedValue: 0x4000)
        let realRelease = MaschineMK3PadInput(slotIndex: 4, hardwareIndex: 1, value: .touchRelease, encodedValue: 0x2000)
        let report4 = tracker.events(for: [pressureZero, realRelease])
        // PRESSURE(0) produces .up; the TOUCH_REL is suppressed because
        // padsWithActivePressure is empty for this pad, but the PRESSURE(0)
        // already emitted .up so the TOUCH_REL guard (heldPads) fails.
        #expect(report4 == [
            MaschineMK3PadEvent(hardwareIndex: 1, phase: .up, pressure: 0, encodedValue: 0x4000),
        ])
    }

    @Test("pad tracker still honours a standalone touchRelease without active pressure")
    func standaloneTouchReleaseHonoured() {
        var tracker = MaschineMK3PadStateTracker()

        let touch = MaschineMK3PadInput(slotIndex: 0, hardwareIndex: 5, value: .touch(50), encodedValue: 0x0032)
        #expect(tracker.events(for: [touch]) == [
            MaschineMK3PadEvent(hardwareIndex: 5, phase: .touch, pressure: 50, encodedValue: 0x0032),
        ])

        // A touchRelease in a report with no active pressure for this pad must
        // still produce an .up event.
        let release = MaschineMK3PadInput(slotIndex: 0, hardwareIndex: 5, value: .touchRelease, encodedValue: 0x2000)
        #expect(tracker.events(for: [release]) == [
            MaschineMK3PadEvent(hardwareIndex: 5, phase: .up, pressure: 0, encodedValue: 0x2000),
        ])
    }

    @Test("button bitfields decode to semantic press and touch events")
    func surfaceButtonsAndTouches() {
        var previous = [UInt8](repeating: 0, count: MaschineMK3Protocol.surfaceReportSize)
        previous[0] = MaschineMK3Protocol.surfaceReportID
        var current = previous
        current[1] = 0x80
        current[2] = 0x04
        current[6] = 0x20
        current[9] = 0x80
        current[10] = 0x80

        #expect(MaschineMK3InputReportDecoder.surfaceEvents(previous: previous, current: current) == [
            .button(button: .displayButton8, pressed: true),
            .button(button: .groupC, pressed: true),
            .button(button: .play, pressed: true),
            .encoderTouch(index: 0, touched: true),
            .encoderTouch(index: 1, touched: true),
        ])
    }

    @Test("main and display encoders decode across their source-documented wraps")
    func surfaceEncoders() {
        var previous = [UInt8](repeating: 0, count: MaschineMK3Protocol.surfaceReportSize)
        previous[0] = MaschineMK3Protocol.surfaceReportID
        previous[11] = 0x0f
        previous[12] = 0xe7
        previous[13] = 0x03
        var current = previous
        current[11] = 0
        current[12] = 0
        current[13] = 0

        #expect(MaschineMK3InputReportDecoder.surfaceEvents(previous: previous, current: current) == [
            .encoder(index: 0, delta: 1, value: 0),
            .encoder(index: 1, delta: 1, value: 0),
        ])
    }

    @Test("touch strip and audio controls decode while ambiguous bits stay raw")
    func surfaceAnalogValues() {
        var previous = [UInt8](repeating: 0, count: MaschineMK3Protocol.surfaceReportSize)
        previous[0] = MaschineMK3Protocol.surfaceReportID
        var current = previous
        current[3] = 0x40
        current[30] = 0x00
        current[31] = 0x02
        current[36] = 0x34
        current[37] = 0x12

        #expect(MaschineMK3InputReportDecoder.surfaceEvents(previous: previous, current: current) == [
            .touchStrip(finger: 1, position: 512),
            .analog(control: .microphoneGain, value: 0x1234),
            .rawChanged(indices: [3]),
        ])
    }

    @Test("LED enums cover the complete verified output payload maps")
    func ledMaps() {
        #expect(MaschineMK3ButtonLED.allCases.count == MaschineMK3Protocol.buttonLEDPayloadSize)
        #expect(MaschineMK3ButtonLED.play.rawValue == 41)
        #expect(MaschineMK3ButtonLED.record.rawValue == 42)
        #expect(MaschineMK3ButtonLED.mainEncoderDown.rawValue == 61)
        #expect(MaschineMK3PadLED.allCases.count == 16)
        #expect(MaschineMK3PadLED.pad13.rawValue == 25)
        #expect(MaschineMK3PadLED.pad4.rawValue == 40)
    }

    @Test("NO CLIENT echo maps documented controls to verified pad LED slots")
    func ledEchoMappings() {
        #expect(MaschineMK3Button.allCases.filter { $0.led == nil } == [.mainEncoderPress])
        #expect(MaschineMK3Button.play.led == .play)
        #expect(MaschineMK3Button.displayButton8.led == .displayButton8)
        #expect(MaschineMK3Protocol.monochromeDimLEDValue == 0x04)
        #expect(MaschineMK3Protocol.monochromeSubtleDimLEDValue == 0x05)
        #expect(MaschineMK3Protocol.monochromeBrightLEDValue == 0x06)
        #expect(MaschineMK3ButtonLED.play.pressedEchoValue == MaschineMK3Protocol.monochromePressedLEDValue)
        #expect(MaschineMK3ButtonLED.groupA.pressedEchoValue == MaschineMK3Protocol.whiteColorLEDValue)
        #expect(MaschineMK3ButtonLED.sampling.usesColorEncoding)
        #expect(MaschineMK3ButtonLED.sampling.usesMonochromeWhiteCurve)
        #expect(!MaschineMK3ButtonLED.browser.usesColorEncoding)
        #expect(MaschineMK3ButtonLED.mainEncoderRight.usesColorEncoding)

        #expect(MaschineMK3PadLED(hardwareIndex: 0) == .pad13)
        #expect(MaschineMK3PadLED(hardwareIndex: 2) == .pad15)
        #expect(MaschineMK3PadLED(hardwareIndex: 13) == .pad2)
        #expect(MaschineMK3PadLED(hardwareIndex: 15) == .pad4)
        #expect(MaschineMK3PadLED(hardwareIndex: 2)?.rawValue == 27)
        #expect(MaschineMK3PadLED(hardwareIndex: 13)?.rawValue == 38)
        #expect(MaschineMK3PadLED(hardwareIndex: -1) == nil)
        #expect(MaschineMK3PadLED(hardwareIndex: 16) == nil)

        #expect(MaschineMK3Protocol.stripLEDIndex(for: 0) == nil)
        #expect(MaschineMK3Protocol.stripLEDIndex(for: 1) == 0)
        #expect(MaschineMK3Protocol.stripLEDIndex(for: 512) == 12)
        #expect(MaschineMK3Protocol.stripLEDIndex(for: 1023) == 24)
    }

    @Test("clear output payloads match the verified HID descriptors")
    func clearedOutputPayloads() {
        #expect(MaschineMK3Protocol.clearedButtonLEDPayload().count == 62)
        #expect(MaschineMK3Protocol.clearedButtonLEDPayload().allSatisfy { $0 == 0 })
        #expect(MaschineMK3Protocol.clearedStripLEDPayload().count == 41)
        #expect(MaschineMK3Protocol.clearedStripLEDPayload().allSatisfy { $0 == 0 })
    }
}
