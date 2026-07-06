import Foundation
import Testing
import KompleteKontrol
@testable import KontrolSurfaceKit2

@Suite("Selection list and grid", .serialized)
struct SelectionViewTests {
    @Test("Navigation clamps or wraps selected indices")
    func navigationMovesAndClampsSelection() {
        var clamped = MK2SelectionNavigation(selectedIndex: 1)

        #expect(clamped.move(by: 2, itemCount: 3) == true)
        #expect(clamped.selectedIndex == 2)
        #expect(clamped.move(by: 1, itemCount: 3) == false)
        #expect(clamped.selectedIndex == 2)
        clamped.clamp(itemCount: 0)
        #expect(clamped.selectedIndex == 0)

        var wrapped = MK2SelectionNavigation(selectedIndex: 0)
        #expect(wrapped.move(by: -1, itemCount: 3, wraps: true) == true)
        #expect(wrapped.selectedIndex == 2)
    }

    @Test("Navigation keeps one focused filter encoder")
    func navigationTracksFocusedFilterEncoder() {
        var navigation = MK2SelectionNavigation()

        navigation.touchFilter(encoder: 6, touched: true)
        #expect(navigation.focusedFilterEncoder == 6)
        navigation.touchFilter(encoder: 7, touched: false)
        #expect(navigation.focusedFilterEncoder == 6)
        navigation.touchFilter(encoder: 6, touched: false)
        #expect(navigation.focusedFilterEncoder == nil)
        navigation.setFilterFocus(encoder: 5, enabled: false)
        #expect(navigation.focusedFilterEncoder == nil)
    }

    @Test("Navigation maps 4-D directions to list and grid movement")
    func navigationMapsJogDirections() {
        let cell = MK2SelectionCellSize(width: 154, height: 58)

        #expect(MK2SelectionLayout.jogDelta(for: "left", layout: .grid(cellSize: cell)) == -1)
        #expect(MK2SelectionLayout.jogDelta(for: "right", layout: .grid(cellSize: cell)) == 1)
        #expect(MK2SelectionLayout.jogDelta(for: "up", layout: .grid(cellSize: cell)) == -3)
        #expect(MK2SelectionLayout.jogDelta(for: "down", layout: .grid(cellSize: cell)) == 3)
        #expect(MK2SelectionLayout.jogDelta(for: "press", layout: .grid(cellSize: cell)) == nil)

        var navigation = MK2SelectionNavigation(selectedIndex: 4)
        let movedLeft = navigation.move(jogDirection: "left", itemCount: 10, layout: .grid(cellSize: cell))
        #expect(movedLeft)
        #expect(navigation.selectedIndex == 3)
        let movedDown = navigation.move(jogDirection: "down", itemCount: 10, layout: .grid(cellSize: cell))
        #expect(movedDown)
        #expect(navigation.selectedIndex == 6)
        let movedUp = navigation.move(jogDirection: "up", itemCount: 10, layout: .grid(cellSize: cell))
        #expect(movedUp)
        #expect(navigation.selectedIndex == 3)
    }

    @Test("Navigation exposes 4-D movement availability as jog lamps")
    func navigationMapsJogLamps() {
        let cell = MK2SelectionCellSize(width: 154, height: 58)
        let available = MK2LampState2.on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01)

        let atStart = MK2SelectionNavigation(selectedIndex: 0).jogLamps(
            itemCount: 10,
            layout: .grid(cellSize: cell),
            availableLamp: available
        )
        #expect(atStart[.jogLeft] == MK2LampState2.off)
        #expect(atStart[.jogUp] == MK2LampState2.off)
        #expect(atStart[.jogRight] == available)
        #expect(atStart[.jogDown] == available)

        let atEnd = MK2SelectionNavigation(selectedIndex: 9).jogLamps(
            itemCount: 10,
            layout: .grid(cellSize: cell),
            availableLamp: available
        )
        #expect(atEnd[.jogLeft] == available)
        #expect(atEnd[.jogUp] == available)
        #expect(atEnd[.jogRight] == MK2LampState2.off)
        #expect(atEnd[.jogDown] == MK2LampState2.off)
    }

    @Test("Layout exposes shared content metrics")
    func layoutExposesSharedContentMetrics() {
        let regular = MK2ScreenLayout.regular()
        let filteredScreen = MK2ScreenLayout.regular(footer: .filters())
        let full = MK2SelectionLayout.contentRect(hasFilters: false)
        let filtered = MK2SelectionLayout.contentRect(hasFilters: true)
        let iconCell = MK2SelectionCellSize(width: 58, height: 58)

        #expect(regular.headerRect == MK2PixelRect(x: 0, y: 0, width: 480, height: 38))
        #expect(regular.contentRect == full)
        #expect(filteredScreen.contentRect == filtered)
        #expect(filteredScreen.footerRect == MK2PixelRect(x: 0, y: 184, width: 480, height: 88))
        #expect(full == MK2PixelRect(x: 8, y: 43, width: 464, height: 221))
        #expect(filtered == MK2PixelRect(x: 8, y: 43, width: 464, height: 134))
        #expect(MK2SelectionLayout.gridColumnCount(for: iconCell) == 8)
        #expect(MK2SelectionLayout.gridRowStep(for: iconCell) == 8)
        #expect(MK2SelectionGrid.columnCount(for: iconCell) == MK2SelectionLayout.gridColumnCount(for: iconCell))
    }

    @Test("Regular screen chrome draws title and footer regions")
    func regularScreenChromeDrawsTitleAndFooterRegions() {
        var frame = MK2PixelFrame()
        let renderer = try? FreeTypeTextRenderer()

        MK2RegularScreenChrome(
            header: .title(title: "TITLE", subtitle: "SUB", subtitleAlignment: .trailing),
            footer: .filters()
        ).draw(into: &frame, renderer: renderer)

        #expect(frame.countNonBackgroundPixels(in: MK2PixelRect(x: 8, y: 8, width: 80, height: 14)) > 10)
        #expect(frame.countNonBackgroundPixels(in: MK2PixelRect(x: 420, y: 8, width: 52, height: 14)) > 10)
        #expect(frame.countPixels(in: MK2PixelRect(x: 0, y: 0, width: 480, height: 1), matching: MK2HIG.Chrome.headerTopLine) == 480)
        #expect(frame.countPixels(in: MK2PixelRect(x: 0, y: 1, width: 480, height: 36), matching: MK2HIG.Chrome.headerFill) > 15_000)
        #expect(frame.countPixels(in: MK2PixelRect(x: 0, y: 37, width: 480, height: 1), matching: MK2HIG.Chrome.headerBottomLine) == 480)
        #expect(frame.countPixels(in: MK2PixelRect(x: 0, y: 185, width: 480, height: 80), matching: MK2HIG.Chrome.footerFill) > 10_000)
    }

    @Test("Regular screen hint footer uses body typography")
    func regularScreenHintFooterUsesBodyTypography() {
        var frame = MK2PixelFrame()
        let renderer = try? FreeTypeTextRenderer()

        MK2RegularScreenChrome(
            footer: .hint("4D confirms the selected action")
        ).draw(into: &frame, renderer: renderer)

        #expect(frame.countNonBackgroundPixels(in: MK2PixelRect(x: 18, y: 251, width: 300, height: 18)) > 40)
    }

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
        let rowRect = MK2PixelRect(x: 8, y: 74, width: 464, height: 29)
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

    @Test("Tall list selection highlight covers the detail descender area")
    func tallListSelectionCoversDetailDescenders() {
        let colors = MK2SelectionViewColors(
            background: 0x0000,
            text: 0x07e0,
            dim: 0x8410,
            muted: 0x39e7,
            selectionFill: 0x001f
        )
        var frame = MK2PixelFrame()

        MK2SelectionList(
            title: "TEST",
            items: [
                MK2SelectionItem(
                    title: "Kick Resin",
                    detail: "Round transient, short tail",
                    badge: "Drums",
                    iconGlyph: "\u{f001}"
                ),
            ],
            selectedIndex: 0,
            filters: [
                MK2SelectionFilter(label: "TYPE", value: "All", encoder: 5),
            ],
            rowHeight: 44,
            colors: colors
        ).draw(into: &frame)

        #expect(
            frame.countPixels(
                in: MK2PixelRect(x: 32, y: 86, width: 416, height: 1),
                matching: colors.selectionFill
            ) > 300
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

    @Test("Grid can render compact icon-only cells")
    func gridRendersIconOnlyCells() {
        let colors = MK2SelectionViewColors(
            background: 0x0000,
            dim: 0x39e7,
            muted: 0x7bef,
            selectionFill: 0x2126
        )
        var frame = MK2PixelFrame()
        let items = (0..<40).map { index in
            let item = sampleItems[index % sampleItems.count]
            return MK2SelectionItem(
                title: "\(item.title) \(index)",
                detail: item.detail,
                badge: item.badge,
                iconGlyph: item.iconGlyph
            )
        }

        MK2SelectionGrid(
            title: "ICONS",
            items: items,
            selectedIndex: 31,
            cellSize: MK2SelectionCellSize(width: 58, height: 58),
            colors: colors,
            cellContent: .iconOnly(iconSize: 30)
        ).draw(into: &frame)

        #expect(frame.countPixels(in: MK2PixelRect(x: 417, y: 220, width: 52, height: 52), matching: colors.selectionFill) > 200)
        #expect(frame.countPixels(in: MK2PixelRect(x: 430, y: 270, width: 26, height: 1), matching: colors.selectionFill) > 0)
        #expect(frame.countPixels(in: MK2PixelRect(x: 417, y: 256, width: 52, height: 14), matching: colors.muted) == 0)
    }

    @Test("Selection list and grid can be captured as a two-screen snapshot")
    func selectionSnapshotSmoke() {
        var list = MK2PixelFrame()
        MK2SelectionList(
            title: "LIST",
            items: sampleItems,
            selectedIndex: 1,
            filters: [
                MK2SelectionFilter(label: "TYPE", value: "Bass", encoder: 5, isActive: true, isFocused: true),
            ],
            rowHeight: 44
        ).draw(into: &list)

        var grid = MK2PixelFrame()
        MK2SelectionGrid(
            title: "GRID",
            items: sampleItems + sampleItems,
            selectedIndex: 4,
            cellSize: MK2SelectionCellSize(width: 154, height: 58),
            filters: [
                MK2SelectionFilter(label: "BANK", value: "User", encoder: 7, isActive: true, isFocused: true),
            ]
        ).draw(into: &grid)

        let png = PixelSnapshot.pngData(frames: [list, grid])
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        #expect(Self.be32(png, 16) == 2 * MK2PixelFrame.width + 1)
        #expect(Self.be32(png, 20) == MK2PixelFrame.height)
        #expect(list.countPixels(in: MK2PixelRect(x: 8, y: 218, width: 104, height: 34), matching: 0xffe0) > 200)
        #expect(grid.countPixels(in: MK2PixelRect(x: 248, y: 218, width: 104, height: 34), matching: 0xffe0) > 200)
    }

    private static func be32(_ data: Data, _ offset: Int) -> Int {
        Int(data[offset]) << 24
            | Int(data[offset + 1]) << 16
            | Int(data[offset + 2]) << 8
            | Int(data[offset + 3])
    }
}

private extension MK2PixelFrame {
    func countNonBackgroundPixels(in rect: MK2PixelRect, background: UInt16 = 0x0841) -> Int {
        guard let clipped = rect.clipped(to: MK2PixelFrame.bounds) else { return 0 }
        var count = 0
        for y in clipped.y..<clipped.maxY {
            for x in clipped.x..<clipped.maxX where self[x, y] != background {
                count += 1
            }
        }
        return count
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
