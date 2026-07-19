import Foundation
import Testing
import KompleteKontrol
@testable import KontrolSurfaceKit2

/// The focused filter cell fills with the accent through the value cell's
/// dithered gradient, so exact-color counting is meaningless (it only ever
/// worked for yellow, which saturates under the gradient's clamp). Count
/// bright pixels instead.
private func countBrightPixels(_ frame: MK2PixelFrame, in rect: MK2PixelRect) -> Int {
    frame.pixels(in: rect).filter { pixel in
        let r = Int((pixel >> 11) & 0x1f)
        let g = Int((pixel >> 5) & 0x3f)
        let b = Int(pixel & 0x1f)
        return r + g + b > 55
    }.count
}

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

        #expect(MK2SelectionLayout.jogDelta(for: .left, layout: .grid(cellSize: cell)) == -1)
        #expect(MK2SelectionLayout.jogDelta(for: .right, layout: .grid(cellSize: cell)) == 1)
        #expect(MK2SelectionLayout.jogDelta(for: .up, layout: .grid(cellSize: cell)) == -3)
        #expect(MK2SelectionLayout.jogDelta(for: .down, layout: .grid(cellSize: cell)) == 3)

        var navigation = MK2SelectionNavigation(selectedIndex: 4)
        let movedLeft = navigation.move(jogDirection: .left, itemCount: 10, layout: .grid(cellSize: cell))
        #expect(movedLeft)
        #expect(navigation.selectedIndex == 3)
        let movedDown = navigation.move(jogDirection: .down, itemCount: 10, layout: .grid(cellSize: cell))
        #expect(movedDown)
        #expect(navigation.selectedIndex == 6)
        let movedUp = navigation.move(jogDirection: .up, itemCount: 10, layout: .grid(cellSize: cell))
        #expect(movedUp)
        #expect(navigation.selectedIndex == 3)

        // A linear list moves one row per up/down and one page per left/right —
        // up/down must never page-jump.
        #expect(MK2SelectionLayout.jogDelta(for: .up, layout: .list(step: 7)) == -1)
        #expect(MK2SelectionLayout.jogDelta(for: .down, layout: .list(step: 7)) == 1)
        #expect(MK2SelectionLayout.jogDelta(for: .left, layout: .list(step: 7)) == -7)
        #expect(MK2SelectionLayout.jogDelta(for: .right, layout: .list(step: 7)) == 7)

        var list = MK2SelectionNavigation(selectedIndex: 10)
        _ = list.move(jogDirection: .down, itemCount: 30, layout: .list(step: 7))
        #expect(list.selectedIndex == 11)
        _ = list.move(jogDirection: .right, itemCount: 30, layout: .list(step: 7))
        #expect(list.selectedIndex == 18)
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
        let regular = MK2ScreenLayout.regular(header: .status([]))
        let filteredScreen = MK2ScreenLayout.regular(header: .status([]), footer: .filters())
        let full = MK2SelectionLayout.contentRect(hasFilters: false)
        let filtered = MK2SelectionLayout.contentRect(hasFilters: true)
        let iconCell = MK2SelectionCellSize(width: 58, height: 58)

        #expect(regular.headerRect == MK2PixelRect(x: 0, y: 0, width: 480, height: 32))
        #expect(regular.contentRect == full)
        #expect(filteredScreen.contentRect == filtered)
        #expect(filteredScreen.footerRect == MK2PixelRect(x: 0, y: 210, width: 480, height: 62))
        #expect(full == MK2PixelRect(x: 8, y: 37, width: 464, height: 227))
        #expect(filtered == MK2PixelRect(x: 8, y: 37, width: 464, height: 166))
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

        #expect(frame.countNonBackgroundPixels(in: MK2PixelRect(x: 8, y: 6, width: 80, height: 14)) > 10)
        #expect(frame.countNonBackgroundPixels(in: MK2PixelRect(x: 420, y: 6, width: 52, height: 14)) > 10)
        #expect(frame.countPixels(in: MK2PixelRect(x: 0, y: 0, width: 480, height: 1), matching: MK2HIG.Chrome.headerTopLine) == 480)
        #expect(frame.countNonBackgroundPixels(in: MK2PixelRect(x: 0, y: 1, width: 480, height: 30)) > 13_000)
        #expect(frame[300, 2] != frame[300, 29])
        #expect(frame.countPixels(in: MK2PixelRect(x: 0, y: 31, width: 480, height: 1), matching: MK2HIG.Chrome.headerBottomLine) == 480)
        #expect(frame.countNonBackgroundPixels(in: MK2PixelRect(x: 0, y: 211, width: 480, height: 60)) > 25_000)
        #expect(frame.countPixels(in: MK2PixelRect(x: 0, y: 210, width: 480, height: 1), matching: MK2HIG.Chrome.headerTopLine) == 480)
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
        #expect(frame.countNonBackgroundPixels(in: MK2PixelRect(x: 0, y: 211, width: 480, height: 60)) > 25_000)
        #expect(countBrightPixels(frame, in: MK2PixelRect(x: 8, y: 236, width: 104, height: 34)) > 200)
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

        #expect(frame.countPixels(in: MK2PixelRect(x: 128, y: 236, width: 104, height: 34), matching: colors.accent) > 200)
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
        let rowRect = MK2PixelRect(x: 8, y: 68, width: 464, height: 29)
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
                    iconGlyph: "\u{e340}"
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
                in: MK2PixelRect(x: 32, y: 80, width: 416, height: 1),
                matching: colors.selectionFill
            ) > 300
        )
    }

    @Test("Fitted rows never clip and center the remainder")
    func fittedRowsFloorAndCenter() {
        // 166 px content, 54 px cells → three whole rows (not two, not a clipped
        // fourth), remainder split top/bottom.
        let content = MK2PixelRect(x: 8, y: 37, width: 464, height: 166)
        let fit = MK2SelectionLayout.fittedRows(cellHeight: 54, in: content)
        #expect(fit.rows == 3)
        // The three rows fit inside the content with no clipping…
        #expect(fit.originY + fit.rows * 54 <= content.maxY)
        // …and the block is centered: equal-ish margins top and bottom.
        let topMargin = fit.originY - content.y
        let bottomMargin = content.maxY - (fit.originY + fit.rows * 54)
        #expect(abs(topMargin - bottomMargin) <= 1)

        // Exact fit leaves no margin and never rounds up into a clipped row.
        let exact = MK2SelectionLayout.fittedRows(cellHeight: 50, in: MK2PixelRect(x: 0, y: 0, width: 100, height: 150))
        #expect(exact.rows == 3)
        #expect(exact.originY == 0)
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

        let cellSize = MK2SelectionCellSize(width: 58, height: 58)
        MK2SelectionGrid(
            title: "ICONS",
            items: items,
            selectedIndex: 31,
            cellSize: cellSize,
            colors: colors,
            cellContent: .iconOnly(iconSize: 30)
        ).draw(into: &frame)

        // Derive the selected cell from the tiling invariant instead of hard
        // pixels, so layout-constant changes don't silently break the test.
        let content = MK2SelectionLayout.contentRect(hasFilters: false)
        let (rows, originY) = MK2SelectionLayout.fittedRows(cellHeight: cellSize.height, in: content)
        let cols = MK2SelectionGrid.columnCount(for: cellSize, contentWidth: content.width)
        let totalRows = (items.count - 1) / cols + 1
        let selectedRow = 31 / cols
        let firstRow = min(max(0, totalRows - rows), (selectedRow / rows) * rows)
        let cellX = content.x + (31 % cols) * cellSize.width + 3
        let cellY = originY + (selectedRow - firstRow) * cellSize.height + 3

        // The selected cell carries the rounded selection fill…
        #expect(frame.countPixels(in: MK2PixelRect(x: cellX, y: cellY, width: 52, height: 52), matching: colors.selectionFill) > 200)
        // …the block is centered, so nothing is drawn in the bottom margin (no
        // clipped last row)…
        let blockBottom = originY + rows * cellSize.height
        #expect(frame.countPixels(in: MK2PixelRect(x: content.x, y: blockBottom, width: content.width, height: max(1, content.maxY - blockBottom)), matching: colors.selectionFill) == 0)
        // …and icon-only cells draw no muted badge text.
        #expect(frame.countPixels(in: MK2PixelRect(x: cellX, y: cellY + 36, width: 52, height: 14), matching: colors.muted) == 0)
    }

    @Test("Optional columns render a tabular list with headers and alignment")
    func listColumnsRenderTable() throws {
        let renderer = try FreeTypeTextRenderer()
        let columns = [
            MK2SelectionColumn(header: "POS", x: 0, width: 36, alignment: .trailing, fixedPitch: true),
            MK2SelectionColumn(header: "Title", x: 60, width: 210),
            MK2SelectionColumn(header: "ROWS", x: 300, width: 44, alignment: .trailing, fixedPitch: true),
        ]
        let items = [
            MK2SelectionItem(title: "Intro", columns: ["00", "Intro", "32"]),
            MK2SelectionItem(title: "Verse", columns: ["01", "Verse", "64"]),
        ]
        var frame = MK2PixelFrame()
        MK2SelectionList(title: "ORDER", items: items, selectedIndex: 0, columns: columns)
            .draw(into: &frame, renderer: renderer)

        let contentY = MK2SelectionLayout.contentY
        // The header band renders above the rows: caption pixels in the
        // trailing ROWS header region.
        #expect(countBrightPixels(frame, in: MK2PixelRect(x: 20 + 300, y: contentY, width: 44, height: 18)) > 0)
        // Trailing-aligned fixed-pitch value: pixels hug the column's right
        // edge, the leading half stays empty.
        let rowY = contentY + 18
        let posColumn = MK2PixelRect(x: 20, y: rowY, width: 36, height: 30)
        let posLeading = MK2PixelRect(x: 20, y: rowY, width: 16, height: 30)
        #expect(countBrightPixels(frame, in: posColumn) > 0)
        #expect(countBrightPixels(frame, in: posLeading) == 0)
        // The proportional title column renders too.
        #expect(countBrightPixels(frame, in: MK2PixelRect(x: 20 + 60, y: rowY, width: 210, height: 30)) > 0)
    }

    @Test("Lists without columns keep the plain row layout")
    func plainListsIgnoreColumnValues() throws {
        let renderer = try FreeTypeTextRenderer()
        let items = [MK2SelectionItem(title: "Piano Noir", columns: ["00", "ignored"])]

        var plain = MK2PixelFrame()
        MK2SelectionList(title: "BROWSE", items: [MK2SelectionItem(title: "Piano Noir")], selectedIndex: 0)
            .draw(into: &plain, renderer: renderer)
        var withValues = MK2PixelFrame()
        MK2SelectionList(title: "BROWSE", items: items, selectedIndex: 0)
            .draw(into: &withValues, renderer: renderer)

        #expect(plain.pixels(in: MK2PixelFrame.bounds) == withValues.pixels(in: MK2PixelFrame.bounds))
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
        #expect(countBrightPixels(list, in: MK2PixelRect(x: 8, y: 236, width: 104, height: 34)) > 200)
        #expect(countBrightPixels(grid, in: MK2PixelRect(x: 248, y: 236, width: 104, height: 34)) > 200)
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
    MK2SelectionItem(title: "Kick", detail: "Warm drum", badge: "DRM", iconGlyph: "\u{e340}"),
    MK2SelectionItem(title: "Bass", detail: "Mono low", badge: "BAS", iconGlyph: "\u{e340}"),
    MK2SelectionItem(title: "Pad", detail: "Wide layer", badge: "PAD", iconGlyph: "\u{e340}"),
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
