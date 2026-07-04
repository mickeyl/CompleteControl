import Testing
@testable import KontrolSurfaceKit2

@Suite("Status line and value cell")
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

        #expect(unfocused[rect.x, rect.y] == colors.border)
        #expect(unfocused[rect.x + 2, rect.y + 2] == colors.fill)
        #expect(focused[rect.x, rect.y] == colors.focusedBorder)
        #expect(focused[rect.x + 2, rect.y + 2] == colors.focusedFill)
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
