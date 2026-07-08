import Foundation
import Testing
@testable import KontrolSurfaceKit2

@Suite("Status line and value cell", .serialized)
struct StatusLineAndValueCellTests {
    @Test("Status line renders text at the requested y position")
    func statusLineRendersText() {
        var frame = MK2PixelFrame()

        MK2StatusLine(y: 8, items: [
            MK2StatusLineItem("EDIT", x: 8, color: 0xffff),
        ]).draw(into: &frame)

        #expect(hasNonBlackPixel(in: frame, rect: MK2PixelRect(x: 8, y: 8, width: 40, height: SurfaceFont.grid.cellHeight)))
    }

    @Test("Value cell uses focused and unfocused frame colours")
    func valueCellFocusColors() {
        let colors = MK2ValueCellColors(
            label: 0xffff,
            value: 0x07e0,
            border: 0x4208,
            fill: 0x001f,
            focusedValue: 0x0000,
            focusedFill: 0xc618,
            focusedBorder: 0xffff
        )
        let rect = MK2PixelRect(x: 20, y: 40, width: 80, height: 30)

        var unfocused = MK2PixelFrame()
        MK2ValueCell(label: "VOL", value: "40", rect: rect, colors: colors)
            .draw(into: &unfocused)

        var focused = MK2PixelFrame()
        MK2ValueCell(label: "VOL", value: "40", rect: rect, isFocused: true, colors: colors)
            .draw(into: &focused)

        func luminance(_ pixel: UInt16) -> Int {
            Int((pixel >> 11) & 0x1f) + Int((pixel >> 5) & 0x3f) + Int(pixel & 0x1f)
        }

        // Debossed well: the border ring runs from a dark shadow rim at the top to a
        // lit edge at the bottom, in both palettes.
        #expect(luminance(unfocused[rect.x + 40, rect.y]) < luminance(unfocused[rect.x + 40, rect.maxY - 1]))
        #expect(luminance(focused[rect.x + 40, rect.y]) < luminance(focused[rect.x + 40, rect.maxY - 1]))
        // The fill falls the same way and keeps the focused/unfocused inversion.
        #expect(luminance(unfocused[rect.x + 2, rect.y + 2]) <= luminance(unfocused[rect.x + 2, rect.maxY - 3]))
        #expect(luminance(focused[rect.x + 2, rect.y + 15]) > luminance(unfocused[rect.x + 2, rect.y + 15]))
    }

    @Test("Rounded value cell antialiases corner pixels")
    func valueCellRoundedCornersAntialias() {
        UserDefaults.standard.set(true, forKey: MK2RenderSettings.antialiasingEnabledDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: MK2RenderSettings.antialiasingEnabledDefaultsKey) }

        let colors = MK2ValueCellColors(
            label: 0xffff,
            value: 0x07e0,
            border: 0xffff,
            fill: 0x001f,
            focusedValue: 0x0000,
            focusedFill: 0xc618,
            focusedBorder: 0xffff
        )
        let rect = MK2PixelRect(x: 20, y: 40, width: 80, height: 30)
        var frame = MK2PixelFrame()

        MK2ValueCell(label: "VOL", value: "40", rect: rect, cornerRadius: 8, colors: colors)
            .draw(into: &frame)

        var hasBlendedCornerPixel = false
        for y in rect.y..<(rect.y + 8) {
            for x in rect.x..<(rect.x + 8) {
                let pixel = frame[x, y]
                if pixel != 0x0000, pixel != colors.border, pixel != colors.fill {
                    hasBlendedCornerPixel = true
                }
            }
        }

        #expect(hasBlendedCornerPixel)
    }

    @Test("Render settings can disable rounded corner antialiasing globally")
    func valueCellRoundedCornersRespectGlobalAntialiasingSwitch() {
        UserDefaults.standard.set(false, forKey: MK2RenderSettings.antialiasingEnabledDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: MK2RenderSettings.antialiasingEnabledDefaultsKey) }

        let colors = MK2ValueCellColors(
            label: 0xffff,
            value: 0x07e0,
            border: 0xffff,
            fill: 0x001f,
            focusedValue: 0x0000,
            focusedFill: 0xc618,
            focusedBorder: 0xffff
        )
        let rect = MK2PixelRect(x: 20, y: 40, width: 80, height: 30)
        var frame = MK2PixelFrame()

        MK2ValueCell(label: "VOL", value: "40", rect: rect, cornerRadius: 8, colors: colors)
            .draw(into: &frame)

        // Aliased corners are hard-edged: with radius 8 the top row insets five
        // pixels, so the outermost columns stay pure background with no coverage
        // fringe (antialiasing would leave partially blended pixels there).
        #expect((0..<4).allSatisfy { frame[rect.x + $0, rect.y] == 0x0000 })
        #expect((0..<4).allSatisfy { frame[rect.maxX - 1 - $0, rect.y] == 0x0000 })
    }
}

private func hasNonBlackPixel(in frame: MK2PixelFrame, rect: MK2PixelRect) -> Bool {
    for y in rect.y..<rect.maxY {
        for x in rect.x..<rect.maxX where frame[x, y] != 0x0000 {
            return true
        }
    }
    return false
}
