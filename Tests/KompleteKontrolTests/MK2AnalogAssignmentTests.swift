import Testing
@testable import KompleteKontrol

@Suite("MK2 analog assignment map")
struct MK2AnalogAssignmentTests {
    // The exact payload verified live on the S61 MK2 (2026-07-02): wheels at factory
    // behaviour, strip unipolar on CC11. Any change here must be re-benched on hardware.
    @Test("default map matches the hardware-verified bytes")
    func defaultMap() {
        let expected: [UInt8] =
            [0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x3f, 0x00, 0x00, 0x01, 0x00]
            + [0x03, 0x01, 0x00, 0x20, 0x00, 0x00, 0x7f, 0x00, 0x00, 0x00, 0x00, 0x00]
            + [0x03, 0x0b, 0x00, 0x20, 0x00, 0x00, 0x7f, 0x00, 0x00, 0x00, 0x00, 0x00]
            + [UInt8](repeating: 0x00, count: 8)
        #expect(KompleteKontrolMK2Protocol.defaultWheelStripMapPayload == expected)
        #expect(expected.count == 44)
    }

    @Test("bipolar strip sets decay and center LED zero point in the trailer")
    func bipolarStrip() {
        let payload = KompleteKontrolMK2Protocol.wheelStripMapPayload(strip: .pitchBend(channel: 1, decay: 4))
        #expect(payload.count == 44)
        #expect(Array(payload[24..<36]) == [0x06, 0x00, 0x01, 0x00, 0x00, 0x00, 0xff, 0x3f, 0x00, 0x00, 0x01, 0x00])
        #expect(Array(payload[36...]) == [0x04, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00])
    }

    @Test("unipolar strip respects CC number, channel and range")
    func unipolarStrip() {
        let payload = KompleteKontrolMK2Protocol.wheelStripMapPayload(strip: .cc(number: 74, channel: 2, min: 10, max: 100))
        #expect(Array(payload[24..<36]) == [0x03, 74, 0x02, 0x20, 10, 0x00, 100, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(Array(payload[36...]) == [UInt8](repeating: 0x00, count: 8))
    }
}

// Byte-6 semantics from the 2026-07-02 calibration session: 0x04 = cap touched,
// pushes are 0x08/0x10/0x20/0x40/0x80 OR'd with the touch bit.
@Suite("MK2 4-D input decode")
struct MK2FourDDecodeTests {
    private func report(byte6: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = 0x01
        bytes[6] = byte6
        return bytes
    }

    @Test("touch edge surfaces as jogTouch")
    func touchEdges() {
        #expect(KKMK2InputReportDecoder.events(previous: report(byte6: 0x00), current: report(byte6: 0x04)) == [.jogTouch(touched: true)])
        #expect(KKMK2InputReportDecoder.events(previous: report(byte6: 0x04), current: report(byte6: 0x00)) == [.jogTouch(touched: false)])
    }

    @Test("pushes decode as directions while touched")
    func pushes() {
        #expect(KKMK2InputReportDecoder.events(previous: report(byte6: 0x04), current: report(byte6: 0x24)) == [.jog(direction: "up")])
        #expect(KKMK2InputReportDecoder.events(previous: report(byte6: 0x04), current: report(byte6: 0x0c)) == [.jog(direction: "press")])
        #expect(KKMK2InputReportDecoder.events(previous: report(byte6: 0x84), current: report(byte6: 0x04)) == [])
    }
}
