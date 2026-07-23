import Foundation
import Testing
@testable import KontrolSurfaceKit2

@Suite("FreeType text rendering")
struct FreeTypeTextRendererTests {
    @Test("Production catalog exposes the locked text, icon, and mono families")
    func catalogShape() {
        let catalog = FreeTypeFontCatalog.production
        #expect(catalog.families.map(\.id) == [
            MK2HIG.Fonts.textFamilyID,
            MK2HIG.Fonts.iconFamilyID,
            MK2HIG.Fonts.monoFamilyID,
        ])
        #expect(catalog.family(id: MK2HIG.Fonts.textFamilyID)?.source(for: .regular).resourceName == MK2HIG.Fonts.textRegularResourceName)
        #expect(catalog.family(id: MK2HIG.Fonts.textFamilyID)?.source(for: .medium).resourceName == MK2HIG.Fonts.textMediumResourceName)
        #expect(catalog.family(id: MK2HIG.Fonts.iconFamilyID)?.source(for: .regular).resourceName == MK2HIG.Fonts.iconResourceName)
        #expect(catalog.family(id: MK2HIG.Fonts.monoFamilyID)?.source(for: .regular).resourceName == MK2HIG.Fonts.monoRegularResourceName)
        #expect(catalog.family(id: MK2HIG.Fonts.monoFamilyID)?.source(for: .bold).resourceName == MK2HIG.Fonts.monoBoldResourceName)
    }

    @Test("Renderer draws grayscale antialiased text into RGB565 frame")
    func drawAntialiasedText() throws {
        let renderer = try FreeTypeTextRenderer()
        var frame = MK2PixelFrame(fill: 0)
        let style = MK2HIG.textStyle(weight: MK2HIG.Fonts.bodyWeight, pixelSize: 36, color: 0xffff)
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

    @Test("Cached runs redraw with independent colour and position")
    func cachedRunsRedrawWithIndependentColorAndPosition() throws {
        let renderer = try FreeTypeTextRenderer()
        let white = MK2HIG.textStyle(weight: MK2HIG.Fonts.bodyWeight, pixelSize: 24, color: 0xffff)
        let green = MK2HIG.textStyle(weight: MK2HIG.Fonts.bodyWeight, pixelSize: 24, color: 0x07e0)
        var first = MK2PixelFrame(fill: 0)
        var second = MK2PixelFrame(fill: 0)

        try renderer.drawText("Cache", into: &first, x: 20, y: 40, style: white)
        try renderer.drawText("Cache", into: &second, x: 44, y: 64, style: green)

        #expect(first.countNonBackgroundPixels(in: MK2PixelFrame.bounds) > 0)
        #expect(second.countNonBackgroundPixels(in: MK2PixelFrame.bounds) > 0)
        #expect(second.countMatchingPixels(0x07e0, in: MK2PixelRect(x: 44, y: 64, width: 120, height: 40)) > 0)
        #expect(second.countNonBackgroundPixels(in: MK2PixelRect(x: 20, y: 40, width: 20, height: 20)) == 0)
    }

    @Test("Proportional text shapes ligatures through HarfBuzz")
    func proportionalTextShapesLigaturesThroughHarfBuzz() throws {
        let renderer = try FreeTypeTextRenderer()
        let style = MK2HIG.textStyle(weight: MK2HIG.Fonts.bodyWeight, pixelSize: 24, color: 0xffff)

        let glyphs = try renderer.debugShapedGlyphIDs("office", style: style)

        #expect(glyphs.count == 5) // o, f, fi, c, e
        #expect(glyphs.count < "office".unicodeScalars.count)
    }

    @Test("Every raster mode draws; antialiasing modes create partial coverage")
    func rasterModesDraw() throws {
        let renderer = try FreeTypeTextRenderer()
        for mode in FreeTypeRasterMode.allCases {
            var frame = MK2PixelFrame(fill: 0)
            let style = FreeTypeTextStyle(
                familyID: MK2HIG.Fonts.textFamilyID,
                weight: MK2HIG.Fonts.titleWeight,
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

    @Test("Phosphor icon font renders known glyphs")
    func drawPhosphorIcons() throws {
        let renderer = try FreeTypeTextRenderer()
        var frame = MK2PixelFrame(fill: 0)
        let style = MK2HIG.actionDialogIconStyle(color: 0xffff)
        try renderer.drawText("\u{e2ce}", into: &frame, x: 40, y: 40, style: style)

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
        let style = MK2HIG.bodyTextStyle(color: 0xffff)
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
        let style = MK2HIG.bodyTextStyle(color: 0xffff)
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

    @Test("Ink extent predicts the rendered pixel rows")
    func inkExtentMatchesRenderedInk() throws {
        let renderer = try FreeTypeTextRenderer()
        let style = MK2HIG.iconStyle(pixelSize: 22, color: 0xffff)
        let glyph = MK2HIG.IconGlyph.musicNote

        let metrics = try renderer.metrics(style: style)
        let ink = try renderer.inkExtent(glyph, style: style)
        #expect(ink.height > 0)

        let top = 100
        var frame = MK2PixelFrame()
        try renderer.drawText(glyph, into: &frame, x: 40, y: top, style: style, maxWidth: 60)

        var rows: [Int] = []
        for y in 0..<MK2PixelFrame.height where frame.countNonBackgroundPixels(in: MK2PixelRect(x: 0, y: y, width: MK2PixelFrame.width, height: 1)) > 0 {
            rows.append(y)
        }
        let predictedTop = top + metrics.ascender + ink.top
        #expect(rows.first == predictedTop)
        #expect(rows.count == ink.height)
    }

    @Test("Metric icon alignment centers icon ink on the cap band")
    func iconAlignmentCentersInkOnCapBand() throws {
        let renderer = try FreeTypeTextRenderer()
        let textStyle = MK2HIG.bodyTextStyle(color: 0xffff)
        let iconStyle = MK2HIG.iconStyle(pixelSize: 22, color: 0xffff)
        let glyph = MK2HIG.IconGlyph.musicNote
        let textTop = 80

        let center = try #require(MK2IconAlignment.capBandCenter(textTop: textTop, style: textStyle, renderer: renderer))
        let iconTop = try #require(MK2IconAlignment.iconTop(glyph: glyph, style: iconStyle, centeredOn: center, renderer: renderer))

        // The cap band center derives from real metrics: baseline − capHeight/2.
        let textMetrics = try renderer.metrics(style: textStyle)
        let cap = try renderer.inkExtent("H", style: textStyle)
        #expect(center == textTop + textMetrics.ascender + cap.top + cap.height / 2)

        // The placed icon's ink midpoint hits the anchor within rounding.
        let iconMetrics = try renderer.metrics(style: iconStyle)
        let ink = try renderer.inkExtent(glyph, style: iconStyle)
        let inkCenter = iconTop + iconMetrics.ascender + ink.top + ink.height / 2
        #expect(abs(inkCenter - center) <= 1)
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

    func countMatchingPixels(_ color: UInt16, in rect: MK2PixelRect) -> Int {
        guard let clipped = rect.clipped(to: MK2PixelFrame.bounds) else { return 0 }
        var count = 0
        for y in clipped.y..<clipped.maxY {
            for x in clipped.x..<clipped.maxX where self[x, y] == color {
                count += 1
            }
        }
        return count
    }
}
