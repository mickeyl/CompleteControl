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

    @Test("Leading label icon renders in its own tint and shifts the label inward")
    func valueCellLeadingIconShiftsLabel() throws {
        let renderer = try FreeTypeTextRenderer()
        let colors = MK2ValueCellColors(
            label: 0x8410,
            value: 0x07e0,
            border: 0x4208,
            icon: 0x07ff
        )
        let rect = MK2PixelRect(x: 20, y: 40, width: 100, height: 30)

        var plain = MK2PixelFrame()
        MK2ValueCell(label: "VOL", value: "40", rect: rect, colors: colors)
            .draw(into: &plain, renderer: renderer)

        var iconed = MK2PixelFrame()
        MK2ValueCell(label: "VOL", iconGlyph: MK2HIG.IconGlyph.speakerHigh, value: "40", rect: rect, colors: colors)
            .draw(into: &iconed, renderer: renderer)

        let labelLine = MK2PixelRect(x: rect.x, y: rect.y - SurfaceFont.label.cellHeight - MK2ValueCell.labelGap - 2, width: rect.width, height: SurfaceFont.label.cellHeight + 4)
        // The icon tint appears on the label line, and only with an icon set.
        func hasIconTint(_ frame: MK2PixelFrame) -> Bool {
            for y in labelLine.y..<labelLine.maxY {
                for x in labelLine.x..<labelLine.maxX where frame[x, y] == colors.icon {
                    return true
                }
            }
            return false
        }
        #expect(hasIconTint(iconed))
        #expect(!hasIconTint(plain))
        // The label moved inward: the plain cell has label pixels at the cell
        // edge where the iconed cell now shows the icon instead.
        #expect(plain[rect.x, labelLine.y + 4] != iconed[rect.x, labelLine.y + 4] || plain[rect.x + 1, labelLine.y + 4] != iconed[rect.x + 1, labelLine.y + 4])
    }

    @Test("Trailing icon right-aligns to the cell edge and keeps the label in place")
    func valueCellTrailingIconKeepsLabel() throws {
        let renderer = try FreeTypeTextRenderer()
        let colors = MK2ValueCellColors(label: 0x8410, value: 0x07e0, border: 0x4208, icon: 0x07ff)
        let rect = MK2PixelRect(x: 20, y: 40, width: 100, height: 30)

        var frame = MK2PixelFrame()
        MK2ValueCell(label: "VOL", iconGlyph: MK2HIG.IconGlyph.speakerHigh, iconPosition: .trailing, value: "40", rect: rect, colors: colors)
            .draw(into: &frame, renderer: renderer)

        let labelLineY = rect.y - SurfaceFont.label.cellHeight - MK2ValueCell.labelGap
        var iconTintX: Int?
        for y in (labelLineY - 2)..<rect.y {
            for x in rect.x..<rect.maxX where frame[x, y] == colors.icon {
                iconTintX = max(iconTintX ?? 0, x)
            }
        }
        let tintX = try #require(iconTintX)
        // Right-aligned: tinted pixels reach the trailing half of the cell.
        #expect(tintX > rect.x + rect.width / 2)
        // The label still starts at the cell edge.
        #expect(hasNonBlackPixel(in: frame, rect: MK2PixelRect(x: rect.x, y: labelLineY, width: 20, height: SurfaceFont.label.cellHeight)))
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
