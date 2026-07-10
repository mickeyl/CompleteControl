import Testing
@testable import KompleteKontrol

@Suite("MK2 display shadow")
struct MK2DisplayShadowTests {
    @Test("snapshot is nil until the first write")
    func snapshotNilUntilFirstWrite() {
        let shadow = MK2DisplayShadow()
        #expect(shadow.snapshot(screen: 0) == nil)
        #expect(shadow.snapshot(screen: 1) == nil)
        #expect(shadow.snapshot(screen: 2) == nil)
    }

    @Test("rect blits composite into the full frame")
    func rectBlitsComposite() {
        let shadow = MK2DisplayShadow()
        shadow.recordFill(screen: 0, x: 0, y: 0, width: 480, height: 272, rgb565: 0x1234)
        shadow.recordBytes(screen: 0, x: 2, y: 1, width: 1, height: 2, pixelsBE: [0xab, 0xcd, 0xef, 0x01])

        let frame = try! #require(shadow.snapshot(screen: 0))
        #expect(frame.count == 480 * 272 * 2)

        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = (y * 480 + x) * 2
            return Array(frame[offset..<(offset + 2)])
        }
        #expect(pixel(0, 0) == [0x12, 0x34])
        #expect(pixel(2, 1) == [0xab, 0xcd])
        #expect(pixel(2, 2) == [0xef, 0x01])
        #expect(pixel(3, 1) == [0x12, 0x34])
    }

    @Test("host-order pixels are stored in wire order")
    func hostOrderPixelsStoredBigEndian() {
        let shadow = MK2DisplayShadow()
        shadow.recordPixels(screen: 1, x: 0, y: 0, width: 2, height: 1, pixels: [0xf800, 0x07e0])

        let frame = try! #require(shadow.snapshot(screen: 1))
        #expect(Array(frame[0..<4]) == [0xf8, 0x00, 0x07, 0xe0])
        #expect(shadow.snapshot(screen: 0) == nil)
    }

    @Test("out-of-bounds and mismatched rects are ignored")
    func invalidRectsIgnored() {
        let shadow = MK2DisplayShadow()
        shadow.recordBytes(screen: 0, x: 479, y: 0, width: 2, height: 1, pixelsBE: [0, 0, 0, 0])
        shadow.recordBytes(screen: 0, x: 0, y: 0, width: 1, height: 1, pixelsBE: [0, 0, 0, 0])
        shadow.recordBytes(screen: 2, x: 0, y: 0, width: 1, height: 1, pixelsBE: [0, 0])
        #expect(shadow.snapshot(screen: 0) == nil)
    }

    @Test("snapshot response payload round-trips")
    func snapshotPayloadRoundTrips() {
        let pixels: [UInt8] = [0xaa, 0xbb, 0xcc, 0xdd]
        let payload = KKDaemonBinaryCodec.displaySnapshotResponsePayload(
            screen: 1, width: 2, height: 1, pixelsRGB565BE: pixels)

        let parsed = try! #require(KKDaemonBinaryCodec.parseDisplaySnapshotResponsePayload(payload))
        #expect(parsed.screen == 1)
        #expect(parsed.width == 2)
        #expect(parsed.height == 1)
        #expect(parsed.pixelsRGB565BE == pixels)
        #expect(KKDaemonBinaryCodec.parseDisplaySnapshotResponsePayload([1, 0, 2, 0, 1, 0, 0xaa]) == nil)
    }
}
