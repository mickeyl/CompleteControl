import Foundation
import Testing
@testable import KontrolSurfaceKit2

@Suite("Tag pill", .serialized)
struct TagTests {
    @Test("Tag renders a lit-from-above pill with antialiased round ends")
    func tagGradientAndAntialiasing() throws {
        UserDefaults.standard.set(true, forKey: MK2RenderSettings.antialiasingEnabledDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: MK2RenderSettings.antialiasingEnabledDefaultsKey) }

        let renderer = try FreeTypeTextRenderer()
        let rect = MK2PixelRect(x: 40, y: 60, width: 96, height: 24)
        var frame = MK2PixelFrame()
        MK2Tag("SAMPLE", rect: rect).draw(into: &frame, renderer: renderer)

        func luminance(_ pixel: UInt16) -> Int {
            Int((pixel >> 11) & 0x1f) + Int((pixel >> 5) & 0x3f) + Int(pixel & 0x1f)
        }
        func rowLuminance(_ y: Int) -> Int {
            (rect.x + 30..<rect.x + 60).reduce(0) { $0 + luminance(frame[$1, y]) }
        }

        // Subtle raised gradient: the fill row near the top outshines the one
        // near the bottom (averaged across a row segment, dithering-safe).
        #expect(rowLuminance(rect.y + 3) > rowLuminance(rect.maxY - 4))

        // Fully rounded pill ends: with radius = height/2 the outer corner
        // pixels stay pure background.
        #expect(frame[rect.x, rect.y] == 0x0000)
        #expect(frame[rect.maxX - 1, rect.maxY - 1] == 0x0000)

        // The label lands inside the pill.
        var hasTextPixel = false
        for y in rect.y..<rect.maxY {
            for x in rect.x..<rect.maxX where frame[x, y] == MK2HIG.Chrome.accent {
                hasTextPixel = true
            }
        }
        #expect(hasTextPixel)
    }

    @Test("Tag element sizes the pill to its text but honors minWidth")
    func tagElementSelfSizing() throws {
        let renderer = try FreeTypeTextRenderer()
        let short = MK2Tag.naturalWidth(for: "OK", renderer: renderer)
        let long = MK2Tag.naturalWidth(for: "WAVETABLE", renderer: renderer)
        #expect(long > short)
        #expect(short >= 24)
    }
}
