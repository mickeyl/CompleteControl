import Foundation
import Testing
@testable import KontrolSurfaceKit2

@Suite("FreeType text rendering")
struct FreeTypeTextRendererTests {
    @Test("Exploratory catalog exposes the initial families and weights")
    func catalogShape() {
        let catalog = FreeTypeFontCatalog.exploratory
        #expect(catalog.families.map(\.id) == ["inter", "plex-sans", "plex-sans-condensed"])
        for family in catalog.families {
            #expect(family.source(for: .regular).resourceName.isEmpty == false)
            #expect(family.source(for: .bold).resourceName.isEmpty == false)
        }
    }

    @Test("Renderer draws grayscale antialiased text into RGB565 frame")
    func drawAntialiasedText() throws {
        let renderer = try FreeTypeTextRenderer()
        var frame = MK2PixelFrame(fill: 0)
        let style = FreeTypeTextStyle(familyID: "inter", weight: .regular, pixelSize: 36, color: 0xffff)
        try renderer.drawText("Ag", into: &frame, x: 20, y: 40, style: style)

        var ink = 0
        var partial = 0
        for y in 0..<MK2PixelFrame.height {
            for x in 0..<MK2PixelFrame.width {
                let pixel = frame[x, y]
                if pixel != 0 {
                    ink += 1
                    if pixel != 0xffff { partial += 1 }
                }
            }
        }
        #expect(ink > 0)
        #expect(partial > 0)
    }

    @Test("Every raster mode draws; antialiasing modes create partial coverage")
    func rasterModesDraw() throws {
        let renderer = try FreeTypeTextRenderer()
        for mode in FreeTypeRasterMode.allCases {
            var frame = MK2PixelFrame(fill: 0)
            let style = FreeTypeTextStyle(
                familyID: "inter",
                weight: .medium,
                pixelSize: 28,
                color: 0xffff,
                rasterMode: mode
            )
            try renderer.drawText("Hint", into: &frame, x: 24, y: 48, style: style)

            var ink = 0
            var partial = 0
            for y in 0..<MK2PixelFrame.height {
                for x in 0..<MK2PixelFrame.width {
                    let pixel = frame[x, y]
                    if pixel != 0 {
                        ink += 1
                        if pixel != 0xffff { partial += 1 }
                    }
                }
            }
            #expect(ink > 0)
            if mode == .monochromeHinted {
                #expect(partial == 0)
            } else {
                #expect(partial > 0)
            }
        }
    }
}
