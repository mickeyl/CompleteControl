import Foundation
import Testing
@testable import KontrolSurfaceKit2

@Suite("MK2PixelFrame blit")
struct PixelFrameBlitTests {
    @Test("Blit matches an element-wise reference across deterministic random rects")
    func blitMatchesElementWiseReference() {
        var state: UInt32 = 0x1234_5678
        func next() -> UInt32 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return state >> 8
        }
        for _ in 0..<100 {
            let width = 1 + Int(next() % UInt32(MK2PixelFrame.width))
            let height = 1 + Int(next() % UInt32(MK2PixelFrame.height))
            let x = Int(next()) % (MK2PixelFrame.width - width + 1)
            let y = Int(next()) % (MK2PixelFrame.height - height + 1)
            let rect = MK2PixelRect(x: x, y: y, width: width, height: height)
            let source = (0..<(width * height)).map { UInt16(truncatingIfNeeded: $0 &* 0x9e37 &+ 0x1234) }

            var frame = MK2PixelFrame(fill: 0x0841)
            let before = frame.pixels
            frame.blit(source, into: rect)

            var expected = before
            for row in 0..<height {
                for column in 0..<width {
                    expected[(y + row) * MK2PixelFrame.width + x + column] = source[row * width + column]
                }
            }
            #expect(frame.pixels == expected)
        }
    }

    @Test("Rejected rects leave content and storage identity untouched")
    func rejectedRectsLeaveStorageUntouched() {
        var frame = MK2PixelFrame(fill: 0x0841)
        let before = frame.pixels
        // Partially outside the frame ...
        frame.blit([0xffff], into: MK2PixelRect(x: 470, y: 0, width: 20, height: 1))
        // ... and a pixel count mismatch inside it.
        frame.blit([0xffff, 0xffff], into: MK2PixelRect(x: 0, y: 0, width: 4, height: 1))
        #expect(frame.pixels == before)
        let sharesStorage = frame.pixels.withUnsafeBufferPointer { $0.baseAddress }
            == before.withUnsafeBufferPointer { $0.baseAddress }
        #expect(sharesStorage)
    }
}
