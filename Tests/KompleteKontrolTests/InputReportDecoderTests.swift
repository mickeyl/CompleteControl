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

    private static func report(_ hex: String) -> [UInt8]? {
        let bytes = hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        return bytes.count == hex.split(separator: " ").count ? bytes : nil
    }
}
