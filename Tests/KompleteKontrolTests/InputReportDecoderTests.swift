import Testing
@testable import KompleteKontrol

@Suite("Input report decoder")
struct InputReportDecoderTests {
    @Test("Initial baseline calibrates absolute controls")
    func initialBaselineCalibratesAbsoluteControls() throws {
        let current = try #require(Self.report(
            "01 00 00 00 00 01 01 8b 01 c0 02 7c 00 78 01 ce 03 7a 00 1e 03 62 02 0d 00 23 b5 00 00 00 00 ba b0 00 00 00 00 30"
        ))

        let baseline = try #require(KKInputReportDecoder.initialEventBaseline(
            reportID: KompleteKontrolS25MK1Protocol.inputReportID,
            current: current
        ))
        let events = KKInputReportDecoder.events(
            reportID: KompleteKontrolS25MK1Protocol.inputReportID,
            previous: baseline,
            current: current
        )

        #expect(events.isEmpty)
    }

    @Test("Initial baseline preserves first button press")
    func initialBaselinePreservesFirstButtonPress() throws {
        var current = try #require(Self.report(
            "01 00 00 00 00 01 01 8b 01 c0 02 7c 00 78 01 ce 03 7a 00 1e 03 62 02 0d 00 23 b5 00 00 00 00 ba b0 00 00 00 00 30"
        ))
        current[2] = 0x01

        let baseline = try #require(KKInputReportDecoder.initialEventBaseline(
            reportID: KompleteKontrolS25MK1Protocol.inputReportID,
            current: current
        ))
        let events = KKInputReportDecoder.events(
            reportID: KompleteKontrolS25MK1Protocol.inputReportID,
            previous: baseline,
            current: current
        )

        #expect(events == [.button(name: "stop", pressed: true)])
    }

    @Test("Main encoder wraps as a four bit counter")
    func mainEncoderWrapsAsFourBitCounter() throws {
        var previous = try #require(Self.report(
            "01 00 00 00 00 01 0f 8b 01 c0 02 7c 00 78 01 ce 03 7a 00 1e 03 62 02 0d 00 23 b5 00 00 00 00 ba b0 00 00 00 00 30"
        ))
        var current = previous
        current[6] = 0x00

        var events = KKInputReportDecoder.events(
            reportID: KompleteKontrolS25MK1Protocol.inputReportID,
            previous: previous,
            current: current
        )
        #expect(events == [.mainEncoder(delta: 1)])

        previous = current
        current[6] = 0x0f
        events = KKInputReportDecoder.events(
            reportID: KompleteKontrolS25MK1Protocol.inputReportID,
            previous: previous,
            current: current
        )
        #expect(events == [.mainEncoder(delta: -1)])
    }

    @Test("MK2 encoder values start at byte 10")
    func mk2EncoderValuesStartAtByte10() throws {
        var previous = try #require(Self.report(
            "01 00 00 00 00 00 00 00 00 00 6c 01 5a 01 8d 03 c3 01 63 00 01 01 57 03 5d 02 00 00 00 00 06 24"
        ))
        var current = previous
        current[10] = 0x6f

        var events = KKMK2InputReportDecoder.events(previous: previous, current: current)
        #expect(events == [.knob(index: 1, delta: 3, value: 0x016f)])

        previous = current
        current[16] = 0xc6
        events = KKMK2InputReportDecoder.events(previous: previous, current: current)
        #expect(events == [.knob(index: 4, delta: 3, value: 0x01c6)])
    }

    @Test("MK2 encoder deltas are signed across wrap")
    func mk2EncoderDeltasAreSignedAcrossWrap() throws {
        var previous = try #require(Self.report(
            "01 00 00 00 00 00 00 01 00 00 73 02 3c 02 6d 00 80 02 bc 00 46 02 be 03 1b 00 00 00 00 00 03 18"
        ))
        var current = previous
        current[24] = 0x18

        var events = KKMK2InputReportDecoder.events(previous: previous, current: current)
        #expect(events == [.knob(index: 8, delta: -3, value: 0x0018)])

        previous = current
        previous[24] = 0x02
        current = previous
        current[24] = 0xe6
        current[25] = 0x03
        // 0x0002 -> 0x03e6 wraps through the bench-verified 0…999 counter range: -4.
        events = KKMK2InputReportDecoder.events(previous: previous, current: current)
        #expect(events == [.knob(index: 8, delta: -4, value: 0x03e6)])

        previous = current
        previous[24] = 0xaf
        previous[25] = 0x03
        current = previous
        current[24] = 0xb2
        events = KKMK2InputReportDecoder.events(previous: previous, current: current)
        #expect(events == [.knob(index: 8, delta: 3, value: 0x03b2)])
    }

    @Test("MK2 encoder touch mask is reversed")
    func mk2EncoderTouchMaskIsReversed() throws {
        let previous = try #require(Self.report(
            "01 00 00 00 00 00 00 00 00 00 6c 01 5a 01 8d 03 c3 01 63 00 01 01 57 03 5d 02 00 00 00 00 06 24"
        ))
        var current = previous
        current[7] = 0x80

        var events = KKMK2InputReportDecoder.events(previous: previous, current: current)
        #expect(events == [.touchEncoder(index: 1, touched: true)])

        current = previous
        current[7] = 0x40
        events = KKMK2InputReportDecoder.events(previous: previous, current: current)
        #expect(events == [.touchEncoder(index: 2, touched: true)])
    }

    @Test("MK2 revised button bit aliases")
    func mk2RevisedButtonBitAliases() throws {
        let previous = try #require(Self.report(
            "01 00 00 00 00 00 00 00 00 00 6c 01 5a 01 8d 03 c3 01 63 00 01 01 57 03 5d 02 00 00 00 00 06 24"
        ))

        var current = previous
        current[8] = 0x01
        var events = KKMK2InputReportDecoder.events(previous: previous, current: current)
        #expect(events == [.button(name: "octavedown", pressed: true)])

        current = previous
        current[8] = 0x02
        events = KKMK2InputReportDecoder.events(previous: previous, current: current)
        #expect(events == [.button(name: "octaveup", pressed: true)])

        current = previous
        current[8] = 0x04
        events = KKMK2InputReportDecoder.events(previous: previous, current: current)
        #expect(events == [.button(name: "fixedvel", pressed: true)])

        current = previous
        current[5] = 0x01
        events = KKMK2InputReportDecoder.events(previous: previous, current: current)
        #expect(events == [.button(name: "mixer", pressed: true)])

        current = previous
        current[5] = 0x04
        events = KKMK2InputReportDecoder.events(previous: previous, current: current)
        #expect(events == [.button(name: "browser", pressed: true)])
    }

    @Test("MK2 initial baseline preserves first function button press")
    func mk2InitialBaselinePreservesFirstFunctionButtonPress() throws {
        var current = try #require(Self.report(
            "01 00 00 00 00 00 00 00 00 00 6c 01 5a 01 8d 03 c3 01 63 00 01 01 57 03 5d 02 00 00 00 00 06 24"
        ))
        current[1] = 0x02

        let events = KKMK2InputReportDecoder.eventsForReport(previous: nil, current: current)

        #expect(events == [.button(name: "function6", pressed: true)])
    }

    @Test("MK2 pitch and mod HID mirrors do not remain raw")
    func mk2EncoderDeltaWrapsAtOneThousand() throws {
        var previous = try #require(Self.report(
            "01 00 00 00 00 00 00 00 00 00 e7 03 5a 01 8d 03 c3 01 63 00 01 01 57 03 5d 02 00 00 00 00 06 24"
        ))
        var current = previous
        current[10] = 0x02
        current[11] = 0x00

        let events = KKMK2InputReportDecoder.events(previous: previous, current: current)
        #expect(events == [.knob(index: 1, delta: 3, value: 2)])

        previous = current
        current[10] = 0xe7
        current[11] = 0x03
        #expect(KKMK2InputReportDecoder.events(previous: previous, current: current) == [.knob(index: 1, delta: -3, value: 999)])
    }

    @Test("MK2 jog scroll ignores activation edge")
    func mk2JogScrollIgnoresActivationEdge() throws {
        var previous = try #require(Self.report(
            "01 00 00 00 00 00 00 00 00 00 73 02 3c 02 6d 00 80 02 bc 00 55 01 c1 03 ef 02 00 00 00 00 04 18"
        ))

        var current = previous
        current[6] = 0x04
        current[30] = 0x03
        var events = KKMK2InputReportDecoder.events(previous: previous, current: current)
        #expect(events == [.jogTouch(touched: true)])

        previous = current
        current[30] = 0x04
        events = KKMK2InputReportDecoder.events(previous: previous, current: current)
        #expect(events == [.jogScroll(delta: 1, value: 4)])

        current[6] = 0x00
        previous = current
        current[6] = 0x04
        events = KKMK2InputReportDecoder.events(previous: previous, current: current)
        #expect(events == [.jogTouch(touched: true)])

        previous = current
        current[30] = 0x03
        events = KKMK2InputReportDecoder.events(previous: previous, current: current)
        #expect(events == [.jogScroll(delta: -1, value: 3)])
    }

    private static func report(_ hex: String) -> [UInt8]? {
        let bytes = hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        return bytes.count == hex.split(separator: " ").count ? bytes : nil
    }
}
