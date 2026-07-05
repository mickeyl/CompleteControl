import Foundation
import Testing
@testable import KontrolSurfaceKit2

@Suite("FreeType text rendering")
struct FreeTypeTextRendererTests {
    @Test("Production catalog exposes the locked text and icon families")
    func catalogShape() {
        let catalog = FreeTypeFontCatalog.production
        #expect(catalog.families.map(\.id) == [
            FreeTypeFontCatalog.textFamilyID,
            FreeTypeFontCatalog.iconProLightFamilyID,
        ])
        #expect(catalog.family(id: FreeTypeFontCatalog.textFamilyID)?.source(for: .regular).resourceName == "IBMPlexSansCondensed-Regular.otf")
        #expect(catalog.family(id: FreeTypeFontCatalog.textFamilyID)?.source(for: .medium).resourceName == "IBMPlexSansCondensed-Medium.otf")
        #expect(catalog.family(id: FreeTypeFontCatalog.iconProLightFamilyID)?.source(for: .regular).resourceName == "FontAwesome7Pro-Light-300.otf")
    }

    @Test("Renderer draws grayscale antialiased text into RGB565 frame")
    func drawAntialiasedText() throws {
        let renderer = try FreeTypeTextRenderer()
        var frame = MK2PixelFrame(fill: 0)
        let style = FreeTypeTextStyle(familyID: FreeTypeFontCatalog.textFamilyID, weight: .regular, pixelSize: 36, color: 0xffff)
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
                familyID: FreeTypeFontCatalog.textFamilyID,
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

    @Test("Font Awesome Pro Light icon font renders known glyphs")
    func drawFontAwesomeIcons() throws {
        let renderer = try FreeTypeTextRenderer()
        var frame = MK2PixelFrame(fill: 0)
        let style = FreeTypeTextStyle(familyID: FreeTypeFontCatalog.iconProLightFamilyID, weight: .regular, pixelSize: 48, color: 0xffff)
        try renderer.drawText("\u{f2bb}", into: &frame, x: 40, y: 40, style: style)

        var ink = 0
        for y in 0..<MK2PixelFrame.height {
            for x in 0..<MK2PixelFrame.width where frame[x, y] != 0 {
                ink += 1
            }
        }
        #expect(ink > 0)
    }

    @Test("Wrapped layout breaks body copy at word boundaries")
    func wrappedLayoutBreaksAtWords() throws {
        let renderer = try FreeTypeTextRenderer()
        let style = FreeTypeTextStyle(familyID: FreeTypeFontCatalog.textFamilyID, weight: .regular, pixelSize: 16, color: 0xffff)
        let maxWidth = try renderer.measure("Wollen Sie das aktuelle Pattern", style: style) - 1

        let layout = try renderer.wrappedLayout(
            "Wollen Sie das aktuelle Pattern wirklich löschen?",
            style: style,
            maxWidth: maxWidth
        )

        #expect(layout.lines == [
            "Wollen Sie das aktuelle",
            "Pattern wirklich löschen?",
        ])
        #expect(layout.lineHeight > 0)
    }

    @Test("Wrapped drawing advances onto later lines")
    func drawWrappedTextDrawsMultipleLines() throws {
        let renderer = try FreeTypeTextRenderer()
        var frame = MK2PixelFrame(fill: 0)
        let style = FreeTypeTextStyle(familyID: FreeTypeFontCatalog.textFamilyID, weight: .regular, pixelSize: 16, color: 0xffff)
        let maxWidth = try renderer.measure("Wollen Sie das aktuelle Pattern", style: style) - 1

        let drawn = try renderer.drawWrappedText(
            "Wollen Sie das aktuelle Pattern wirklich löschen?",
            into: &frame,
            x: 20,
            y: 40,
            style: style,
            maxWidth: maxWidth,
            lineSpacing: 5
        )

        #expect(drawn == 2)
        #expect(frame.countNonBackgroundPixels(in: MK2PixelRect(x: 20, y: 60, width: maxWidth, height: 28)) > 0)
    }
}

private extension MK2PixelFrame {
    func countNonBackgroundPixels(in rect: MK2PixelRect) -> Int {
        guard let clipped = rect.clipped(to: MK2PixelFrame.bounds) else { return 0 }
        var count = 0
        for y in clipped.y..<clipped.maxY {
            for x in clipped.x..<clipped.maxX where self[x, y] != 0x0000 {
                count += 1
            }
        }
        return count
    }
}
