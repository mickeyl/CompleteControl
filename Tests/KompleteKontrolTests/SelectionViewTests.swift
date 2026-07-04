import Foundation
import Testing
@testable import KontrolSurfaceKit2

@Suite("Selection list and grid", .serialized)
struct SelectionViewTests {
    @Test("List draws selected row and filter area")
    func listDrawsSelectionAndFilters() {
        var frame = MK2PixelFrame()
        MK2SelectionList(
            title: "TEST",
            items: sampleItems,
            selectedIndex: 1,
            filters: [
                MK2SelectionFilter(label: "TYPE", value: "Bass", encoder: 5, isActive: true, isFocused: true),
            ],
            rowHeight: 30
        ).draw(into: &frame)

        #expect(frame.countPixels(in: MK2PixelRect(x: 8, y: 76, width: 464, height: 24), matching: 0x2126) > 200)
        #expect(frame.countPixels(in: MK2PixelRect(x: 0, y: 185, width: 480, height: 80), matching: 0x1083) > 10_000)
        #expect(frame.countPixels(in: MK2PixelRect(x: 8, y: 218, width: 104, height: 34), matching: 0xffe0) > 200)
    }

    @Test("Filter value cells stay in fixed encoder slots")
    func filterValueCellsStayInFixedEncoderSlots() {
        let colors = MK2SelectionViewColors(
            background: 0x0000,
            text: 0xffff,
            dim: 0x39e7,
            accent: 0xf800,
            filterFill: 0x0841
        )
        var frame = MK2PixelFrame()

        MK2SelectionList(
            title: "TEST",
            items: sampleItems,
            selectedIndex: 0,
            filters: [
                MK2SelectionFilter(label: "TYPE", value: "Bass", encoder: 5),
                MK2SelectionFilter(label: "TONE", value: "Dark", encoder: 6, isFocused: true),
                MK2SelectionFilter(label: "BANK", value: "User", encoder: 7),
            ],
            colors: colors
        ).draw(into: &frame)

        #expect(frame.countPixels(in: MK2PixelRect(x: 128, y: 218, width: 104, height: 34), matching: colors.accent) > 200)
        #expect(frame.countPixels(in: MK2PixelRect(x: 232, y: 218, width: 16, height: 34), matching: colors.accent) == 0)
    }

    @Test("List selection highlight antialiases rounded corners")
    func listSelectionAntialiasesRoundedCorners() {
        UserDefaults.standard.set(true, forKey: MK2RenderSettings.antialiasingEnabledDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: MK2RenderSettings.antialiasingEnabledDefaultsKey) }

        let colors = MK2SelectionViewColors(
            background: 0x0000,
            selectionFill: 0xffff
        )
        let rowRect = MK2PixelRect(x: 8, y: 76, width: 464, height: 27)
        var frame = MK2PixelFrame()

        MK2SelectionList(
            title: "TEST",
            items: sampleItems,
            selectedIndex: 1,
            rowHeight: 30,
            colors: colors
        ).draw(into: &frame)

        #expect(
            frame.hasPixel(
                in: MK2PixelRect(x: rowRect.x, y: rowRect.y, width: 7, height: 7),
                where: { $0 != colors.background && $0 != colors.selectionFill }
            )
        )
    }

    @Test("Grid derives visible cells from cell size")
    func gridDerivesLayoutFromCellSize() {
        var frame = MK2PixelFrame()
        MK2SelectionGrid(
            title: "GRID",
            items: sampleItems + sampleItems,
            selectedIndex: 5,
            cellSize: MK2SelectionCellSize(width: 120, height: 50)
        ).draw(into: &frame)

        #expect(frame.countPixels(in: MK2PixelRect(x: 251, y: 98, width: 114, height: 44), matching: 0x2126) > 200)
    }
}

private let sampleItems = [
    MK2SelectionItem(title: "Kick", detail: "Warm drum", badge: "DRM", iconGlyph: "\u{f001}"),
    MK2SelectionItem(title: "Bass", detail: "Mono low", badge: "BAS", iconGlyph: "\u{f001}"),
    MK2SelectionItem(title: "Pad", detail: "Wide layer", badge: "PAD", iconGlyph: "\u{f001}"),
]

private extension MK2PixelFrame {
    func countPixels(in rect: MK2PixelRect, matching color: UInt16) -> Int {
        guard let clipped = rect.clipped(to: MK2PixelFrame.bounds) else { return 0 }
        var count = 0
        for y in clipped.y..<clipped.maxY {
            for x in clipped.x..<clipped.maxX where self[x, y] == color {
                count += 1
            }
        }
        return count
    }

    func hasPixel(in rect: MK2PixelRect, where predicate: (UInt16) -> Bool) -> Bool {
        guard let clipped = rect.clipped(to: MK2PixelFrame.bounds) else { return false }
        for y in clipped.y..<clipped.maxY {
            for x in clipped.x..<clipped.maxX where predicate(self[x, y]) {
                return true
            }
        }
        return false
    }
}
