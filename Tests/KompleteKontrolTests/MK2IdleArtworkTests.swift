import Foundation
import KontrolSurfaceKit2
import Testing
@testable import KompleteKontrol

@Suite("MK2 idle artwork")
struct MK2IdleArtworkTests {
    @Test("Bundled buddies artwork decodes as a full-bleed display frame")
    func bundledArtworkDecodes() throws {
        let frame = try #require(MK2IdleArtwork.bundledFrame)
        let width = KompleteKontrolMK2Protocol.displayWidth
        let height = KompleteKontrolMK2Protocol.displayHeight

        #expect(frame.count == width * height)
        #expect(frame[height / 2 * width] == 0x0000)
        #expect(frame[height / 2 * width + width / 2] != 0x0000)
        #expect(Set(frame).count > 1_000)

        if let directory = ProcessInfo.processInfo.environment["MK2_IDLE_ARTWORK_SNAPSHOT_DIR"] {
            var snapshot = MK2PixelFrame()
            for y in 0..<height {
                for x in 0..<width {
                    snapshot[x, y] = frame[y * width + x]
                }
            }
            try PixelSnapshot.write([snapshot], to: directory + "/mk2-idle-buddies.png")
        }
    }

    @Test("First event hands the right display back to the event log")
    func firstEventRevealsLog() {
        let artwork: [UInt16] = [0x1234]

        #expect(MK2IdleArtwork.frameBeforeFirstEvent(artwork, eventCount: 0) == artwork)
        #expect(MK2IdleArtwork.frameBeforeFirstEvent(artwork, eventCount: 1) == nil)
    }

    @Test("Artwork conversion uses the shared positional RGB565 dither")
    func artworkUsesOrderedDither() {
        let pixels = (0..<4).flatMap { y in
            (0..<4).map { x in
                let pixel = MK2IdleArtwork.ditheredRGB565(red: 127, green: 127, blue: 127, x: x, y: y)
                #expect(pixel == MK2OrderedDither.rgb565(
                    r: 127.0 * 31.0 / 255.0,
                    g: 127.0 * 63.0 / 255.0,
                    b: 127.0 * 31.0 / 255.0,
                    x: x,
                    y: y
                ))
                return pixel
            }
        }

        #expect(Set(pixels).count > 1)
        #expect(MK2IdleArtwork.ditheredRGB565(red: 0, green: 0, blue: 0, x: 3, y: 3) == 0x0000)
        #expect(MK2IdleArtwork.ditheredRGB565(red: 255, green: 255, blue: 255, x: 3, y: 3) == 0xffff)
    }
}
