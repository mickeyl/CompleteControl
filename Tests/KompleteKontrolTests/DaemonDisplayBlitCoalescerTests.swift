import Testing
@testable import KompleteKontrol

@Suite("Daemon display blit coalescing")
struct DaemonDisplayBlitCoalescerTests {
    @Test("a later narrow band preserves an older broad band")
    func preservesOlderRows() {
        let older = DaemonDisplayBlitRegion(
            x: 0, y: 0, width: 2, height: 3,
            pixels: pixelBytes([1, 1, 2, 2, 3, 3])
        )
        let newer = DaemonDisplayBlitRegion(
            x: 0, y: 1, width: 2, height: 1,
            pixels: pixelBytes([9, 9])
        )

        let combined = DaemonDisplayBlitCoalescer.coalesce(
            older: older,
            newer: newer,
            shadow: nil,
            screenWidth: 2,
            screenHeight: 3
        )

        #expect(combined == DaemonDisplayBlitRegion(
            x: 0, y: 0, width: 2, height: 3,
            pixels: pixelBytes([1, 1, 9, 9, 3, 3])
        ))
    }

    @Test("disjoint bands retain shadow pixels in their gap")
    func preservesGapFromShadow() {
        let older = DaemonDisplayBlitRegion(
            x: 0, y: 0, width: 2, height: 1,
            pixels: pixelBytes([1, 1])
        )
        let newer = DaemonDisplayBlitRegion(
            x: 0, y: 2, width: 2, height: 1,
            pixels: pixelBytes([9, 9])
        )

        let combined = DaemonDisplayBlitCoalescer.coalesce(
            older: older,
            newer: newer,
            shadow: pixelBytes([7, 7, 8, 8, 7, 7]),
            screenWidth: 2,
            screenHeight: 3
        )

        #expect(combined.pixels == pixelBytes([1, 1, 8, 8, 9, 9]))
    }

    @Test("a containing newer blit replaces the pending transfer")
    func containingNewerBlitWins() {
        let older = DaemonDisplayBlitRegion(
            x: 1, y: 1, width: 1, height: 1,
            pixels: pixelBytes([1])
        )
        let newer = DaemonDisplayBlitRegion(
            x: 0, y: 0, width: 2, height: 2,
            pixels: pixelBytes([9, 9, 9, 9])
        )

        #expect(DaemonDisplayBlitCoalescer.coalesce(
            older: older,
            newer: newer,
            shadow: nil,
            screenWidth: 2,
            screenHeight: 2
        ) == newer)
    }

    private func pixelBytes(_ values: [UInt16]) -> [UInt8] {
        values.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] }
    }
}
