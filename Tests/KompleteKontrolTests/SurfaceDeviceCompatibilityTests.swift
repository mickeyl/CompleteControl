import KompleteKontrol
@testable import KontrolSurfaceKit2
import Testing

@Suite("Surface device compatibility")
struct SurfaceDeviceCompatibilityTests {
    @Test("MK3 compatibility mappings are one-to-one and intentionally incomplete")
    func mappingPolicy() {
        let mappings = KontrolSurfaceDeviceCompatibility.maschineMK3Mappings
        let physicalButtons = Set(mappings.map(\.physicalButton))
        let logicalLamps = mappings.compactMap(\.input.logicalLamp)
        let expectedLogicalLamps: Set<KKMK2ButtonLED> = [
            .jogLeft, .jogUp, .jogDown, .jogRight,
            .shift, .tempo, .keyMode, .fixedVel, .scene, .pattern, .variation, .s, .m,
            .instrument1, .instrument2, .instrument3, .instrument4,
            .instrument5, .instrument6, .instrument7, .instrument8,
            .clear, .play, .record, .stop, .setup, .pageRight, .mixer,
            .plugin, .track, .browser, .pageLeft, .auto,
            .function1, .function2, .function3, .function4,
            .function5, .function6, .function7, .function8,
        ]

        #expect(physicalButtons.count == mappings.count)
        #expect(Set(logicalLamps).count == logicalLamps.count)
        #expect(Set(logicalLamps) == expectedLogicalLamps)
        #expect(KontrolSurfaceDeviceCompatibility.mapping(for: .displayButton1)?.input == .button(.function1))
        #expect(KontrolSurfaceDeviceCompatibility.mapping(for: .settings)?.input == .button(.setup))
        #expect(KontrolSurfaceDeviceCompatibility.mapping(for: .erase)?.input == .button(.clear))
        #expect(KontrolSurfaceDeviceCompatibility.mapping(for: .arrowLeft)?.input == .button(.pageLeft))
        #expect(KontrolSurfaceDeviceCompatibility.mapping(for: .channel)?.input == .button(.track))
        #expect(KontrolSurfaceDeviceCompatibility.mapping(for: .keyboard)?.input == .button(.keyMode))
        #expect(KontrolSurfaceDeviceCompatibility.mapping(for: .variation)?.input == .button(.variation))
        #expect(KontrolSurfaceDeviceCompatibility.mapping(for: .groupA)?.input == .button(.instrument1))
        #expect(KontrolSurfaceDeviceCompatibility.mapping(for: .groupH)?.input == .button(.instrument8))

        #expect(KontrolSurfaceDeviceCompatibility.mapping(for: .restart) == nil)
        #expect(KontrolSurfaceDeviceCompatibility.mapping(for: .tap) == nil)
        #expect(KontrolSurfaceDeviceCompatibility.mapping(for: .noteRepeat) == nil)
        #expect(KontrolSurfaceDeviceCompatibility.mapping(for: .chords) == nil)
        #expect(KontrolSurfaceDeviceCompatibility.mapping(for: .duplicate) == nil)
    }

    @Test("MK3 Group A-H lower to hardware-independent instrument shortcuts")
    func instrumentShortcutInputLowering() {
        var adapter = KontrolSurfaceInputAdapter(family: .maschineMK3)
        let baseline = surfaceReport()
        #expect(adapter.events(for: baseline, timestampNanos: 0).isEmpty)

        var current = baseline
        current[2] = 0x81

        #expect(adapter.events(for: current, timestampNanos: 1) == [
            .button(led: .instrument1, pressed: true),
            .button(led: .instrument8, pressed: true),
        ])
    }

    @Test("host-control setup is emitted only for the keyboard family")
    func hostControlSetup() {
        let keyboard = KontrolSurfaceDeviceCompatibility.hostControlReports(for: .kompleteKontrolMK2)
        let maschine = KontrolSurfaceDeviceCompatibility.hostControlReports(for: .maschineMK3)

        #expect(keyboard.map(\.reportID) == [
            KompleteKontrolMK2Protocol.initReportID,
            KompleteKontrolMK2Protocol.wheelStripMapReportID,
            KompleteKontrolMK2Protocol.mapCommitReportID,
        ])
        #expect(maschine.isEmpty)
    }

    @Test("MK3 buttons, 4D encoder, and display encoders lower to existing Kit2 events")
    func inputLowering() {
        var adapter = KontrolSurfaceInputAdapter(family: .maschineMK3)
        let baseline = surfaceReport()
        #expect(adapter.events(for: baseline, timestampNanos: 0).isEmpty)

        var current = baseline
        current[1] = 0x08 | 0x40 | 0x80
        current[6] = 0x20
        current[9] = 0x01 | 0x80
        current[10] = 0x80
        current[11] = 1
        current[12] = 1

        #expect(adapter.events(for: current, timestampNanos: 12_000_000) == [
            .jog(direction: "right"),
            .button(led: .shift, pressed: true),
            .button(led: .function8, pressed: true),
            .button(led: .play, pressed: true),
            .button(led: .function1, pressed: true),
            .jogScroll(delta: 1, value: 1),
            .knob(index: 1, delta: 1, value: 1),
            .jogTouch(touched: true),
            .touchEncoder(index: 1, touched: true),
        ])
    }

    @Test("MK3 pad reports lower native strike, pressure, and release with daemon timestamps")
    func padInputLowering() {
        var adapter = KontrolSurfaceInputAdapter(family: .maschineMK3)

        #expect(adapter.padEvents(
            for: padReport(hardwareIndex: 12, encodedValue: 0x002c),
            timestampNanos: 1_000_000
        ) == [KontrolSurfacePadEvent(
            index: 0,
            phase: .touch,
            pressure: 44,
            maximumPressure: MaschineMK3Protocol.padMaximumPressure,
            maximumStrikeVelocity: MaschineMK3Protocol.padMaximumStrikeVelocity,
            timestampNanos: 1_000_000
        )])
        #expect(adapter.padEvents(
            for: padReport(hardwareIndex: 12, encodedValue: 0x2000),
            timestampNanos: 2_000_000
        ).first?.phase == .up)

        #expect(adapter.padEvents(
            for: padReport(hardwareIndex: 12, encodedValue: 0x16ce),
            timestampNanos: 3_000_000
        ) == [KontrolSurfacePadEvent(
            index: 0,
            phase: .down,
            pressure: 0,
            maximumPressure: MaschineMK3Protocol.padMaximumPressure,
            strikeVelocity: 0x6ce,
            maximumStrikeVelocity: MaschineMK3Protocol.padMaximumStrikeVelocity,
            timestampNanos: 3_000_000
        )])
        #expect(adapter.padEvents(
            for: padReport(hardwareIndex: 12, encodedValue: 0x4384),
            timestampNanos: 5_000_000
        ) == [KontrolSurfacePadEvent(
            index: 0,
            phase: .pressure,
            pressure: 900,
            maximumPressure: MaschineMK3Protocol.padMaximumPressure,
            maximumStrikeVelocity: MaschineMK3Protocol.padMaximumStrikeVelocity,
            timestampNanos: 5_000_000
        )])
        #expect(adapter.padEvents(
            for: padReport(hardwareIndex: 12, encodedValue: 0x3000),
            timestampNanos: 8_000_000
        ) == [KontrolSurfacePadEvent(
            index: 0,
            phase: .up,
            pressure: 0,
            maximumPressure: MaschineMK3Protocol.padMaximumPressure,
            maximumStrikeVelocity: MaschineMK3Protocol.padMaximumStrikeVelocity,
            timestampNanos: 8_000_000
        )])
        #expect(adapter.padEvents(
            for: padReport(hardwareIndex: 12, encodedValue: 0x4000),
            timestampNanos: 9_000_000
        ).isEmpty)
    }

    @Test("MK3 VARIATION lowers directly without involving Shift")
    func variationInput() {
        var adapter = KontrolSurfaceInputAdapter(family: .maschineMK3)
        let baseline = surfaceReport()
        _ = adapter.events(for: baseline, timestampNanos: 0)
        var pressed = baseline
        pressed[5] = 0x02

        #expect(adapter.events(for: pressed, timestampNanos: 1) == [
            .button(led: .variation, pressed: true),
        ])
        #expect(adapter.events(for: baseline, timestampNanos: 2) == [
            .button(led: .variation, pressed: false),
        ])
    }

    @Test("MK3 main encoder confirms on release like the keyboard 4D encoder")
    func mainEncoderConfirm() {
        var adapter = KontrolSurfaceInputAdapter(family: .maschineMK3)
        let baseline = surfaceReport()
        _ = adapter.events(for: baseline, timestampNanos: 0)
        var pressed = baseline
        pressed[1] = 0x01

        #expect(adapter.events(for: pressed, timestampNanos: 1).isEmpty)
        #expect(adapter.events(for: baseline, timestampNanos: 2) == [.jogCenter])
    }

    @Test("the first MK3 surface report does not consume the first encoder turn")
    func firstSurfaceGesture() {
        var adapter = KontrolSurfaceInputAdapter(family: .maschineMK3)
        var firstReport = surfaceReport()
        firstReport[11] = 1

        #expect(adapter.events(for: firstReport, timestampNanos: 1_000_000) == [
            .jogScroll(delta: 1, value: 1),
        ])
    }

    @Test("a daemon snapshot primes MK3 counters before the first live encoder step")
    func inputSnapshotPriming() {
        var adapter = KontrolSurfaceInputAdapter(family: .maschineMK3)
        var snapshot = surfaceReport()
        snapshot[11] = 14
        setWord(734, at: 12, in: &snapshot)
        setWord(500, at: 30, in: &snapshot)
        adapter.prime(with: snapshot)

        var firstLiveReport = snapshot
        firstLiveReport[11] = 15
        setWord(735, at: 12, in: &firstLiveReport)
        setWord(0, at: 30, in: &firstLiveReport)

        #expect(adapter.events(for: firstLiveReport, timestampNanos: 2_000_000) == [
            .jogScroll(delta: 1, value: 15),
            .knob(index: 1, delta: 1, value: 735),
            .strip(position: nil, time: 2),
        ])
    }

    @Test("two MK3 ribbon contacts hand over without a false release")
    func ribbonHandover() {
        var adapter = KontrolSurfaceInputAdapter(family: .maschineMK3)
        var report = surfaceReport()
        _ = adapter.events(for: report, timestampNanos: 0)

        setWord(300, at: 30, in: &report)
        #expect(adapter.events(for: report, timestampNanos: 10_000_000) == [
            .strip(position: 300, time: 10),
        ])

        setWord(700, at: 34, in: &report)
        #expect(adapter.events(for: report, timestampNanos: 11_000_000).isEmpty)

        setWord(0, at: 30, in: &report)
        #expect(adapter.events(for: report, timestampNanos: 12_000_000) == [
            .strip(position: 700, time: 12),
        ])

        setWord(0, at: 34, in: &report)
        #expect(adapter.events(for: report, timestampNanos: 13_000_000) == [
            .strip(position: nil, time: 13),
        ])
    }

    @Test("MK3 lamp output uses native report sizes and the compatibility map")
    func maschineLampOutput() throws {
        let white = KKRGB(red: 0xff, green: 0xff, blue: 0xff)
        let red = KKRGB(red: 0xff, green: 0, blue: 0)
        let green = KKRGB(red: 0, green: 0xff, blue: 0)
        let reports = KontrolSurfaceDeviceCompatibility.lampReports(
            for: .maschineMK3,
            lamps: [
                .function1: KontrolSurfaceLampValue(color: white, intensity: 3),
                .play: KontrolSurfaceLampValue(color: green, intensity: 3),
                .record: KontrolSurfaceLampValue(color: white, intensity: 2),
                .pageLeft: KontrolSurfaceLampValue(color: white, intensity: 1),
                .scene: KontrolSurfaceLampValue(color: white, intensity: 1),
                .variation: KontrolSurfaceLampValue(color: white, intensity: 1),
                .jogRight: KontrolSurfaceLampValue(color: green, intensity: 2),
                .strip1: KontrolSurfaceLampValue(color: white, intensity: 3),
                .strip25: KontrolSurfaceLampValue(color: red, intensity: 1),
                .metro: KontrolSurfaceLampValue(color: white, intensity: 3),
            ]
        )
        let buttons = try #require(reports.first { $0.reportID == MaschineMK3Protocol.buttonLEDReportID })
        let stripAndPads = try #require(reports.first { $0.reportID == MaschineMK3Protocol.stripLEDReportID })

        #expect(buttons.payload.count == MaschineMK3Protocol.buttonLEDPayloadSize)
        #expect(buttons.payload[MaschineMK3ButtonLED.displayButton1.rawValue] == 7)
        #expect(buttons.payload[MaschineMK3ButtonLED.play.rawValue] == 7)
        #expect(buttons.payload[MaschineMK3ButtonLED.record.rawValue] == 6)
        #expect(buttons.payload[MaschineMK3ButtonLED.arrowLeft.rawValue] == 4)
        #expect(buttons.payload[MaschineMK3ButtonLED.scene.rawValue] == 4)
        #expect(buttons.payload[MaschineMK3ButtonLED.variation.rawValue] == 4)
        #expect(buttons.payload[MaschineMK3ButtonLED.mainEncoderRight.rawValue] == 0x1e)
        #expect(buttons.payload[MaschineMK3ButtonLED.tap.rawValue] == 0)

        #expect(stripAndPads.payload.count == MaschineMK3Protocol.stripLEDPayloadSize)
        #expect(stripAndPads.payload[0] == 0xff)
        #expect(stripAndPads.payload[24] == 0x05)
        #expect(stripAndPads.payload[25...40].allSatisfy { $0 == 0 })
    }

    @Test("MK3 monochrome and hybrid Sampling brightness curves stay distinct")
    func maschineBrightnessCurves() {
        let white = KKRGB(red: 0xff, green: 0xff, blue: 0xff)
        let red = KKRGB(red: 0xff, green: 0, blue: 0)

        #expect(KontrolSurfaceDeviceCompatibility.maschineMK3ButtonByte(
            for: KontrolSurfaceLampValue(color: white, intensity: 1), lamp: .browser
        ) == 0x04)
        #expect(KontrolSurfaceDeviceCompatibility.maschineMK3ButtonByte(
            for: KontrolSurfaceLampValue(color: white, intensity: 2), lamp: .browser
        ) == 0x06)
        #expect(KontrolSurfaceDeviceCompatibility.maschineMK3ButtonByte(
            for: KontrolSurfaceLampValue(color: white, intensity: 3), lamp: .browser
        ) == 0x07)

        #expect(KontrolSurfaceDeviceCompatibility.maschineMK3ButtonByte(
            for: KontrolSurfaceLampValue(color: white, intensity: 1), lamp: .sampling
        ) == 0xfc)
        #expect(KontrolSurfaceDeviceCompatibility.maschineMK3ButtonByte(
            for: KontrolSurfaceLampValue(color: white, intensity: 2), lamp: .sampling
        ) == 0xfe)
        #expect(KontrolSurfaceDeviceCompatibility.maschineMK3ButtonByte(
            for: KontrolSurfaceLampValue(color: white, intensity: 3), lamp: .sampling
        ) == 0xff)
        #expect(KontrolSurfaceDeviceCompatibility.maschineMK3ButtonByte(
            for: KontrolSurfaceLampValue(color: red, intensity: 1), lamp: .sampling
        ) == 0x05)
        #expect(KontrolSurfaceDeviceCompatibility.maschineMK3ButtonByte(
            for: KontrolSurfaceLampValue(color: white, intensity: 1), lamp: .groupA
        ) == 0xfd)
    }

    @Test("MK3 performance pads lower in printed panel order with four visible levels")
    func maschinePerformancePadOutput() throws {
        let red = KKRGB(red: 0xff, green: 0, blue: 0)
        let cyan = KKRGB(red: 0, green: 0xff, blue: 0xff)
        let reports = KontrolSurfaceDeviceCompatibility.lampReports(
            for: .maschineMK3,
            lamps: [:],
            performancePads: [
                0: KontrolSurfaceLampValue(color: red, intensity: 0),
                1: KontrolSurfaceLampValue(color: red, intensity: 3),
                14: KontrolSurfaceLampValue(color: cyan, intensity: 1),
                15: KontrolSurfaceLampValue(color: .off, intensity: 3),
            ]
        )
        let pads = try #require(reports.first { $0.reportID == MaschineMK3Protocol.stripLEDReportID })

        #expect(pads.payload[MaschineMK3PadLED.pad1.rawValue] == 0x04)
        #expect(pads.payload[MaschineMK3PadLED.pad2.rawValue] == 0x07)
        #expect(pads.payload[MaschineMK3PadLED.pad15.rawValue] == 0x25)
        #expect(pads.payload[MaschineMK3PadLED.pad16.rawValue] == 0)
    }

    @Test("Performance pads are ignored by keyboard-family reports")
    func keyboardIgnoresPerformancePads() throws {
        let report = try #require(KontrolSurfaceDeviceCompatibility.lampReports(
            for: .kompleteKontrolMK2,
            lamps: [:],
            performancePads: [0: KontrolSurfaceLampValue(
                color: KKRGB(red: 0xff, green: 0, blue: 0),
                intensity: 3
            )]
        ).first)

        #expect(report.payload.allSatisfy { $0 == 0 })
    }

    @Test("keyboard lamp output remains byte-for-byte compatible")
    func keyboardLampOutput() throws {
        let color = KKRGB(red: 0xff, green: 0, blue: 0)
        let value = KontrolSurfaceLampValue(color: color, intensity: 2)
        let report = try #require(KontrolSurfaceDeviceCompatibility.lampReports(
            for: .kompleteKontrolMK2,
            lamps: [.function1: value, .play: value]
        ).first)

        #expect(report.reportID == KompleteKontrolMK2Protocol.buttonLEDReportID)
        #expect(report.payload.count == KompleteKontrolMK2Protocol.buttonLEDMapSize)
        #expect(report.payload[KKMK2ButtonLED.function1.rawValue] == KKMK2ButtonLED.function1.ledByte(for: color, intensity: 2))
        #expect(report.payload[KKMK2ButtonLED.play.rawValue] == KKMK2ButtonLED.play.ledByte(for: color, intensity: 2))
    }

    @Test("instrument shortcut lamps lower to MK3 Group A-H only")
    func instrumentShortcutLampOutput() throws {
        let red = KKRGB(red: 0xff, green: 0, blue: 0)
        let blue = KKRGB(red: 0, green: 0, blue: 0xff)
        let reports = KontrolSurfaceDeviceCompatibility.lampReports(
            for: .maschineMK3,
            lamps: [
                .instrument1: KontrolSurfaceLampValue(color: red, intensity: 1),
                .instrument8: KontrolSurfaceLampValue(color: blue, intensity: 3),
            ]
        )
        let buttons = try #require(reports.first {
            $0.reportID == MaschineMK3Protocol.buttonLEDReportID
        })

        #expect(buttons.payload[MaschineMK3ButtonLED.groupA.rawValue]
            == KontrolSurfaceDeviceCompatibility.maschineMK3ColorByte(
                for: KontrolSurfaceLampValue(color: red, intensity: 1)
            ))
        #expect(buttons.payload[MaschineMK3ButtonLED.groupH.rawValue]
            == KontrolSurfaceDeviceCompatibility.maschineMK3ColorByte(
                for: KontrolSurfaceLampValue(color: blue, intensity: 3)
            ))

        let mk2 = try #require(KontrolSurfaceDeviceCompatibility.lampReports(
            for: .kompleteKontrolMK2,
            lamps: [.instrument1: KontrolSurfaceLampValue(color: red, intensity: 3)]
        ).first)
        #expect(mk2.payload.allSatisfy { $0 == 0 })
    }

    @Test("literal calibration bytes pass through both output maps")
    func literalCalibrationLampOutput() throws {
        let mk3Reports = KontrolSurfaceDeviceCompatibility.lampReports(
            for: .maschineMK3,
            lamps: [
                .function1: KontrolSurfaceLampValue(rawByte: 0x05),
                .jogRight: KontrolSurfaceLampValue(rawByte: 0x4e),
                .strip1: KontrolSurfaceLampValue(rawByte: 0xfa),
            ]
        )
        let mk3Buttons = try #require(mk3Reports.first { $0.reportID == MaschineMK3Protocol.buttonLEDReportID })
        let mk3Secondary = try #require(mk3Reports.first { $0.reportID == MaschineMK3Protocol.stripLEDReportID })
        #expect(mk3Buttons.payload[MaschineMK3ButtonLED.displayButton1.rawValue] == 0x05)
        #expect(mk3Buttons.payload[MaschineMK3ButtonLED.mainEncoderRight.rawValue] == 0x4e)
        #expect(mk3Secondary.payload[0] == 0xfa)

        let mk2 = try #require(KontrolSurfaceDeviceCompatibility.lampReports(
            for: .kompleteKontrolMK2,
            lamps: [.function1: KontrolSurfaceLampValue(rawByte: 0xab)]
        ).first)
        #expect(mk2.payload[KKMK2ButtonLED.function1.rawValue] == 0xab)
    }

    @Test("MK3 diagnostic LED bytes override every physical colour class")
    func diagnosticLEDOverrides() throws {
        let reports = KontrolSurfaceDeviceCompatibility.lampReports(
            for: .maschineMK3,
            lamps: [
                .function1: KontrolSurfaceLampValue(rawByte: 0x07),
                .jogUp: KontrolSurfaceLampValue(rawByte: 0x11),
            ],
            performancePads: [0: KontrolSurfaceLampValue(
                color: KKRGB(red: 0xff, green: 0, blue: 0),
                intensity: 3
            )],
            diagnosticLEDBytes: [
                .maschineMK3Button(.displayButton1): 0x21,
                .maschineMK3Button(.groupA): 0x22,
                .maschineMK3Button(.mainEncoderUp): 0x23,
                .maschineMK3Pad(.pad1): 0x24,
            ]
        )
        let buttons = try #require(reports.first { $0.reportID == MaschineMK3Protocol.buttonLEDReportID })
        let pads = try #require(reports.first { $0.reportID == MaschineMK3Protocol.stripLEDReportID })

        #expect(buttons.payload[MaschineMK3ButtonLED.displayButton1.rawValue] == 0x21)
        #expect(buttons.payload[MaschineMK3ButtonLED.groupA.rawValue] == 0x22)
        #expect(buttons.payload[MaschineMK3ButtonLED.mainEncoderUp.rawValue] == 0x23)
        #expect(pads.payload[MaschineMK3PadLED.pad1.rawValue] == 0x24)
    }

    @Test("MK3-only VARIATION never writes past the MK2 LED map")
    func variationDoesNotWriteMK2LEDMap() throws {
        let report = try #require(KontrolSurfaceDeviceCompatibility.lampReports(
            for: .kompleteKontrolMK2,
            lamps: [.variation: KontrolSurfaceLampValue(
                color: KKRGB(red: 0xff, green: 0xff, blue: 0xff),
                intensity: 3
            )]
        ).first)

        #expect(report.payload.count == KompleteKontrolMK2Protocol.buttonLEDMapSize)
        #expect(report.payload.allSatisfy { $0 == 0 })
    }

    private func surfaceReport() -> [UInt8] {
        [MaschineMK3Protocol.surfaceReportID]
            + [UInt8](repeating: 0, count: MaschineMK3Protocol.surfaceReportSize - 1)
    }

    private func padReport(hardwareIndex: Int, encodedValue: Int) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: MaschineMK3Protocol.padReportSize)
        report[0] = MaschineMK3Protocol.padReportID
        report[1] = UInt8(hardwareIndex & 0x0f)
        report[2] = UInt8((encodedValue >> 8) & 0xff)
        report[3] = UInt8(encodedValue & 0xff)
        return report
    }

    private func setWord(_ value: Int, at offset: Int, in report: inout [UInt8]) {
        report[offset] = UInt8(value & 0xff)
        report[offset + 1] = UInt8((value >> 8) & 0x03)
    }
}
