import Foundation
import KompleteKontrol

public struct MK2SelectionItem: Sendable, Equatable {
    public var title: String
    public var detail: String?
    public var badge: String?
    public var iconGlyph: String?
    /// Values for a tabular list, matched by index to the list's `columns`.
    /// Ignored by lists without columns.
    public var columns: [String]

    public init(
        title: String,
        detail: String? = nil,
        badge: String? = nil,
        iconGlyph: String? = nil,
        columns: [String] = []
    ) {
        self.title = title
        self.detail = detail
        self.badge = badge
        self.iconGlyph = iconGlyph
        self.columns = columns
    }
}

/// Column spec for tabular selection lists — order lists, arranger rows.
/// Optional by design: a list without columns keeps the title/detail/badge
/// row layout, so existing clients are untouched.
public struct MK2SelectionColumn: Sendable, Equatable {
    public enum Alignment: Sendable, Equatable {
        case leading
        case trailing
    }

    /// Header caption; drawn once above the rows when any column has one.
    public var header: String?
    /// Offset from the row's leading text edge.
    public var x: Int
    public var width: Int
    public var alignment: Alignment
    /// nil follows the row's selection state (text when selected, dim otherwise).
    public var color: UInt16?
    /// Fixed-pitch rendering for numeric/tracker columns.
    public var fixedPitch: Bool

    public init(
        header: String? = nil,
        x: Int,
        width: Int,
        alignment: Alignment = .leading,
        color: UInt16? = nil,
        fixedPitch: Bool = false
    ) {
        self.header = header
        self.x = x
        self.width = max(1, width)
        self.alignment = alignment
        self.color = color
        self.fixedPitch = fixedPitch
    }
}

public struct MK2SelectionFilter: Sendable, Equatable {
    public var label: String
    public var value: String
    public var encoder: Int
    public var isActive: Bool
    public var isFocused: Bool
    /// Optional leading label-line icon (see `MK2ValueCell.iconGlyph`). The
    /// filter cell sits above its physical encoder, so the label names the
    /// *filter*, never the encoder — the icon carries the filter's meaning.
    public var iconGlyph: String?

    public init(label: String, value: String, encoder: Int, isActive: Bool = true, isFocused: Bool = false, iconGlyph: String? = nil) {
        self.label = label
        self.value = value
        self.encoder = encoder
        self.isActive = isActive
        self.isFocused = isFocused
        self.iconGlyph = iconGlyph
    }
}

public struct MK2SelectionNavigation: Sendable, Equatable {
    public var selectedIndex: Int
    public var focusedFilterEncoder: Int?

    public init(selectedIndex: Int = 0, focusedFilterEncoder: Int? = nil) {
        self.selectedIndex = max(0, selectedIndex)
        self.focusedFilterEncoder = focusedFilterEncoder
    }

    public mutating func move(by delta: Int, itemCount: Int, wraps: Bool = false) -> Bool {
        guard delta != 0, itemCount > 0 else { return false }
        let previous = selectedIndex
        let bounds = 0...(itemCount - 1)
        if wraps {
            selectedIndex = (selectedIndex + delta).wrapped(to: bounds)
        } else {
            selectedIndex = (selectedIndex + delta).clamped(to: bounds)
        }
        return selectedIndex != previous
    }

    public func canMove(by delta: Int, itemCount: Int, wraps: Bool = false) -> Bool {
        guard delta != 0, itemCount > 0 else { return false }
        let bounds = 0...(itemCount - 1)
        let next: Int
        if wraps {
            next = (selectedIndex + delta).wrapped(to: bounds)
        } else {
            next = (selectedIndex + delta).clamped(to: bounds)
        }
        return next != selectedIndex
    }

    public mutating func select(_ index: Int, itemCount: Int) {
        guard itemCount > 0 else {
            selectedIndex = 0
            return
        }
        selectedIndex = index.clamped(to: 0...(itemCount - 1))
    }

    public mutating func clamp(itemCount: Int) {
        select(selectedIndex, itemCount: itemCount)
    }

    public func clampedSelectedIndex(itemCount: Int) -> Int? {
        guard itemCount > 0 else { return nil }
        return selectedIndex.clamped(to: 0...(itemCount - 1))
    }

    public mutating func setFilterFocus(encoder: Int?, enabled: Bool = true) {
        focusedFilterEncoder = enabled ? encoder : nil
    }

    public mutating func touchFilter(encoder: Int, touched: Bool, enabled: Bool = true) {
        guard enabled else {
            focusedFilterEncoder = nil
            return
        }
        if touched {
            focusedFilterEncoder = encoder
        } else if focusedFilterEncoder == encoder {
            focusedFilterEncoder = nil
        }
    }

    public mutating func move(jogDirection direction: String, itemCount: Int, layout: MK2SelectionJogLayout, wraps: Bool = false) -> Bool {
        guard let delta = MK2SelectionLayout.jogDelta(for: direction, layout: layout) else { return false }
        return move(by: delta, itemCount: itemCount, wraps: wraps)
    }

    public func canMove(jogDirection direction: String, itemCount: Int, layout: MK2SelectionJogLayout, wraps: Bool = false) -> Bool {
        guard let delta = MK2SelectionLayout.jogDelta(for: direction, layout: layout) else { return false }
        return canMove(by: delta, itemCount: itemCount, wraps: wraps)
    }

    public func jogLamps(
        itemCount: Int,
        layout: MK2SelectionJogLayout,
        availableLamp: MK2LampState2,
        unavailableLamp: MK2LampState2 = .off,
        wraps: Bool = false
    ) -> [KKMK2ButtonLED: MK2LampState2] {
        [
            .jogLeft: canMove(jogDirection: "left", itemCount: itemCount, layout: layout, wraps: wraps) ? availableLamp : unavailableLamp,
            .jogRight: canMove(jogDirection: "right", itemCount: itemCount, layout: layout, wraps: wraps) ? availableLamp : unavailableLamp,
            .jogUp: canMove(jogDirection: "up", itemCount: itemCount, layout: layout, wraps: wraps) ? availableLamp : unavailableLamp,
            .jogDown: canMove(jogDirection: "down", itemCount: itemCount, layout: layout, wraps: wraps) ? availableLamp : unavailableLamp,
        ]
    }

    public func applyJogLamps(
        to lamps: inout [KKMK2ButtonLED: MK2LampState2],
        itemCount: Int,
        layout: MK2SelectionJogLayout,
        availableLamp: MK2LampState2,
        unavailableLamp: MK2LampState2 = .off,
        wraps: Bool = false
    ) {
        for (led, state) in jogLamps(
            itemCount: itemCount,
            layout: layout,
            availableLamp: availableLamp,
            unavailableLamp: unavailableLamp,
            wraps: wraps
        ) {
            lamps[led] = state
        }
    }
}

public enum MK2SelectionJogLayout: Sendable, Equatable {
    case list(step: Int = 1)
    case grid(cellSize: MK2SelectionCellSize, contentWidth: Int = MK2SelectionLayout.contentWidth)
}

public enum MK2SelectionLayout {
    // Selection views draw their own title into the header band, so the geometry
    // must reserve it; only the header's presence matters here, not its content.
    private static let regularLayout = MK2ScreenLayout.regular(header: .status([]))
    private static let filteredLayout = MK2ScreenLayout.regular(header: .status([]), footer: .filters())

    public static let contentX = regularLayout.contentRect.x
    public static let contentY = regularLayout.contentRect.y
    public static let contentWidth = regularLayout.contentRect.width
    public static let contentHeight = regularLayout.contentRect.height
    public static let filteredContentHeight = filteredLayout.contentRect.height
    public static let filterAreaY = filteredLayout.footerRect?.y ?? (MK2ScreenLayout.bounds.height - MK2ScreenLayout.encoderFooterHeight)
    public static let filterAreaHeight = filteredLayout.footerRect?.height ?? MK2ScreenLayout.encoderFooterHeight

    public static func contentRect(hasFilters: Bool) -> MK2PixelRect {
        (hasFilters ? filteredLayout : regularLayout).contentRect
    }

    public static func gridColumnCount(for cellSize: MK2SelectionCellSize, contentWidth: Int = contentWidth) -> Int {
        max(1, contentWidth / cellSize.width)
    }

    /// The fixed-cell tiling invariant for grids: fit as many whole rows of
    /// `cellHeight` as the content allows (floor — a partial last row is never
    /// drawn clipped) and center the block, so the unavoidable remainder is a
    /// symmetric top/bottom margin instead of a dead strip. Any tiled element
    /// that lays out fixed-height cells should route through here rather than
    /// re-deriving `height / cell` (and never `ceil`, which clips).
    public static func fittedRows(cellHeight: Int, in content: MK2PixelRect) -> (rows: Int, originY: Int) {
        let stride = max(1, cellHeight)
        let rows = max(1, content.height / stride)
        let originY = content.y + max(0, (content.height - rows * stride) / 2)
        return (rows, originY)
    }

    public static func gridRowStep(for cellSize: MK2SelectionCellSize, contentWidth: Int = contentWidth) -> Int {
        gridColumnCount(for: cellSize, contentWidth: contentWidth)
    }

    public static func jogDelta(for direction: String, layout: MK2SelectionJogLayout) -> Int? {
        let normalized = direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
            case "left":
                return -1
            case "right":
                return 1
            case "up":
                switch layout {
                    case let .list(step):
                        return -max(1, step)
                    case let .grid(cellSize, contentWidth):
                        return -gridRowStep(for: cellSize, contentWidth: contentWidth)
                }
            case "down":
                switch layout {
                    case let .list(step):
                        return max(1, step)
                    case let .grid(cellSize, contentWidth):
                        return gridRowStep(for: cellSize, contentWidth: contentWidth)
                }
            default:
                return nil
        }
    }
}

public struct MK2SelectionViewColors: Sendable, Equatable {
    public var background: UInt16
    public var text: UInt16
    public var dim: UInt16
    public var muted: UInt16
    public var accent: UInt16
    public var selectionFill: UInt16
    public var border: UInt16
    public var filterFill: UInt16
    public var filterValue: UInt16

    public init(
        background: UInt16 = 0x0841,
        text: UInt16 = 0xffff,
        dim: UInt16 = 0x8410,
        muted: UInt16 = 0x4a69,
        accent: UInt16 = MK2HIG.Chrome.accent,
        selectionFill: UInt16 = 0x2126,
        border: UInt16 = 0x4208,
        filterFill: UInt16 = 0x1083,
        filterValue: UInt16 = 0xffff
    ) {
        self.background = background
        self.text = text
        self.dim = dim
        self.muted = muted
        self.accent = accent
        self.selectionFill = selectionFill
        self.border = border
        self.filterFill = filterFill
        self.filterValue = filterValue
    }
}

public struct MK2SelectionList: Sendable {
    public var title: String
    public var subtitle: String?
    public var items: [MK2SelectionItem]
    public var selectedIndex: Int
    public var filters: [MK2SelectionFilter]
    /// Tabular layout: when set, rows render the items' `columns` values at
    /// these positions instead of title/badge/detail. Optional — most
    /// clients keep the plain row layout.
    public var columns: [MK2SelectionColumn]
    public var colors: MK2SelectionViewColors
    public var rowHeight: Int
    /// Air between adjacent rows so neighboring cells don't touch; costs a
    /// visible row on tall lists. Pass 0 for the packed look.
    public var rowGap: Int

    public init(
        title: String,
        subtitle: String? = nil,
        items: [MK2SelectionItem],
        selectedIndex: Int,
        filters: [MK2SelectionFilter] = [],
        columns: [MK2SelectionColumn] = [],
        rowHeight: Int = 30,
        rowGap: Int = 6,
        colors: MK2SelectionViewColors = MK2SelectionViewColors()
    ) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.selectedIndex = selectedIndex
        self.filters = filters
        self.columns = columns
        self.rowHeight = max(24, rowHeight)
        self.rowGap = max(0, rowGap)
        self.colors = colors
    }

    public func draw(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer? = nil) {
        MK2SelectionDrawing.screenChrome(title: title, subtitle: subtitle, filters: filters, colors: colors)
            .draw(into: &frame, renderer: renderer)
        var content = MK2SelectionLayout.contentRect(hasFilters: !filters.isEmpty)
        if columns.contains(where: { $0.header != nil }) {
            drawColumnHeaders(into: &frame, renderer: renderer, contentY: content.y)
            content = MK2PixelRect(
                x: content.x,
                y: content.y + Self.columnHeaderHeight,
                width: content.width,
                height: max(0, content.height - Self.columnHeaderHeight)
            )
        }
        guard !items.isEmpty else {
            MK2SelectionDrawing.drawEmpty("No entries", into: &frame, rect: content, colors: colors)
            MK2SelectionDrawing.drawFilters(filters, into: &frame, colors: colors, renderer: renderer)
            return
        }

        // The trailing row needs no gap below it, so one gap's worth of height
        // comes for free when dividing by the row stride.
        let rowStride = rowHeight + rowGap
        let visibleRows = max(1, (content.height + rowGap) / rowStride)
        let selected = selectedIndex.clamped(to: 0...(items.count - 1))
        let first = min(max(0, selected - visibleRows / 2), max(0, items.count - visibleRows))
        let last = min(items.count, first + visibleRows)

        for visible in first..<last {
            let y = content.y + (visible - first) * rowStride
            drawRow(items[visible], index: visible, selected: visible == selected, y: y, into: &frame, renderer: renderer)
        }
        MK2SelectionDrawing.drawFilters(filters, into: &frame, colors: colors, renderer: renderer)
    }

    private func drawRow(
        _ item: MK2SelectionItem,
        index: Int,
        selected: Bool,
        y: Int,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?
    ) {
        let rect = MK2PixelRect(
            x: MK2SelectionLayout.contentX,
            y: y + 1,
            width: MK2SelectionLayout.contentWidth,
            height: max(1, rowHeight - 1)
        )
        if selected {
            frame.fillRounded(rect, radius: 7, colors.selectionFill, antialiased: true)
        }
        if let iconGlyph = item.iconGlyph {
            let iconSize = min(22, rowHeight - 6)
            MK2SelectionDrawing.drawIcon(
                iconGlyph,
                into: &frame,
                renderer: renderer,
                x: 20,
                y: y + max(0, (rowHeight - iconSize) / 2),
                size: iconSize,
                color: selected ? colors.text : colors.dim
            )
        }
        let textX = item.iconGlyph == nil ? 20 : 58
        guard columns.isEmpty else {
            drawColumns(of: item, selected: selected, textX: textX, y: y, into: &frame, renderer: renderer)
            return
        }
        MK2SelectionDrawing.drawBody(item.title, into: &frame, renderer: renderer, x: textX, y: y + 3, color: selected ? colors.text : colors.dim, maxWidth: item.badge == nil ? 392 : 322)
        if let badge = item.badge {
            MK2SelectionDrawing.drawBody(badge, into: &frame, renderer: renderer, x: 386, y: y + 3, color: selected ? colors.text : colors.muted, maxWidth: 74)
        }
        if rowHeight >= 44, let detail = item.detail {
            MK2SelectionDrawing.drawBody(detail, into: &frame, renderer: renderer, x: textX, y: y + 24, color: selected ? colors.dim : colors.muted, maxWidth: 392)
        }
    }

    private static let columnHeaderHeight = 18

    private func drawColumnHeaders(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer?, contentY: Int) {
        for column in columns {
            guard let header = column.header else { continue }
            let label = BitmapLabel(header.uppercased(), font: .label, color: colors.muted)
            let x = column.alignment == .leading
                ? 20 + column.x
                : 20 + column.x + max(0, column.width - label.width)
            label.draw(
                into: &frame,
                x: x,
                y: contentY + 2,
                clip: MK2PixelRect(x: 20 + column.x, y: contentY, width: column.width, height: Self.columnHeaderHeight)
            )
        }
    }

    private func drawColumns(
        of item: MK2SelectionItem,
        selected: Bool,
        textX: Int,
        y: Int,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?
    ) {
        for (index, column) in columns.enumerated() {
            guard item.columns.indices.contains(index) else { continue }
            let value = item.columns[index]
            guard !value.isEmpty else { continue }
            let color = column.color ?? (selected ? colors.text : colors.dim)
            let x = textX + column.x
            let drawX = column.alignment == .leading
                ? x
                : x + max(0, column.width - Self.textWidth(value, fixedPitch: column.fixedPitch, renderer: renderer))
            if column.fixedPitch {
                BitmapLabel(value, font: .grid, color: color)
                    .draw(into: &frame, x: drawX, y: y + 6, clip: MK2PixelRect(x: x, y: y, width: column.width, height: rowHeight))
            } else {
                MK2SelectionDrawing.drawBody(value, into: &frame, renderer: renderer, x: drawX, y: y + 3, color: color, maxWidth: column.width)
            }
        }
    }

    private static func textWidth(_ text: String, fixedPitch: Bool, renderer: FreeTypeTextRenderer?) -> Int {
        if fixedPitch {
            return BitmapLabel(text, font: .grid, color: 0).width
        }
        if let renderer, let width = try? renderer.measure(text, style: MK2HIG.bodyTextStyle(color: 0xffff)) {
            return width
        }
        return BitmapLabel(text, font: .grid, color: 0).width
    }
}

public struct MK2SelectionGrid: Sendable {
    public static let defaultContentWidth = MK2SelectionLayout.contentWidth

    public enum CellContent: Sendable, Equatable {
        case iconAndText
        case iconOnly(iconSize: Int = 30)
    }

    public var title: String
    public var subtitle: String?
    public var items: [MK2SelectionItem]
    public var selectedIndex: Int
    public var cellSize: MK2SelectionCellSize
    public var filters: [MK2SelectionFilter]
    public var colors: MK2SelectionViewColors
    public var cellContent: CellContent

    public init(
        title: String,
        subtitle: String? = nil,
        items: [MK2SelectionItem],
        selectedIndex: Int,
        cellSize: MK2SelectionCellSize,
        filters: [MK2SelectionFilter] = [],
        colors: MK2SelectionViewColors = MK2SelectionViewColors(),
        cellContent: CellContent = .iconAndText
    ) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.selectedIndex = selectedIndex
        self.cellSize = cellSize
        self.filters = filters
        self.colors = colors
        self.cellContent = cellContent
    }

    public static func columnCount(for cellSize: MK2SelectionCellSize, contentWidth: Int = defaultContentWidth) -> Int {
        MK2SelectionLayout.gridColumnCount(for: cellSize, contentWidth: contentWidth)
    }

    public func draw(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer? = nil) {
        MK2SelectionDrawing.screenChrome(title: title, subtitle: subtitle, filters: filters, colors: colors)
            .draw(into: &frame, renderer: renderer)
        let content = MK2SelectionLayout.contentRect(hasFilters: !filters.isEmpty)
        guard !items.isEmpty else {
            MK2SelectionDrawing.drawEmpty("No entries", into: &frame, rect: content, colors: colors)
            MK2SelectionDrawing.drawFilters(filters, into: &frame, colors: colors, renderer: renderer)
            return
        }

        let columns = Self.columnCount(for: cellSize, contentWidth: content.width)
        let (rows, originY) = MK2SelectionLayout.fittedRows(cellHeight: cellSize.height, in: content)
        let selected = selectedIndex.clamped(to: 0...(items.count - 1))
        let selectedRow = selected / columns
        let firstRow = firstVisibleRow(selectedRow: selectedRow, visibleRows: rows, itemCount: items.count, columns: columns)
        let first = firstRow * columns
        let last = min(items.count, first + rows * columns)

        for index in first..<last {
            let local = index - first
            let column = local % columns
            let row = local / columns
            let rect = MK2PixelRect(
                x: content.x + column * cellSize.width + 3,
                y: originY + row * cellSize.height + 3,
                width: cellSize.width - 6,
                height: cellSize.height - 6
            )
            drawCell(items[index], selected: index == selected, rect: rect, into: &frame, renderer: renderer)
        }
        MK2SelectionDrawing.drawFilters(filters, into: &frame, colors: colors, renderer: renderer)
    }

    private func drawCell(
        _ item: MK2SelectionItem,
        selected: Bool,
        rect: MK2PixelRect,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?
    ) {
        if selected {
            MK2SelectionDrawing.drawRoundedPanel(
                rect,
                fill: colors.selectionFill,
                border: colors.accent,
                radius: 7,
                into: &frame
            )
        }
        if case let .iconOnly(iconSize) = cellContent {
            let size = max(12, min(iconSize, min(rect.width, rect.height) - 12))
            let color = selected ? colors.text : colors.dim
            if let iconGlyph = item.iconGlyph {
                MK2SelectionDrawing.drawIcon(
                    iconGlyph,
                    into: &frame,
                    renderer: renderer,
                    x: rect.x + max(0, (rect.width - size) / 2),
                    y: rect.y + max(0, (rect.height - size) / 2) - 1,
                    size: size,
                    color: color
                )
            } else {
                MK2SelectionDrawing.drawBody(
                    item.title,
                    into: &frame,
                    renderer: renderer,
                    x: rect.x + 6,
                    y: rect.y + max(0, (rect.height - 18) / 2),
                    color: color,
                    maxWidth: max(0, rect.width - 12)
                )
            }
            return
        }
        if let iconGlyph = item.iconGlyph, rect.height >= 56 {
            MK2SelectionDrawing.drawIcon(iconGlyph, into: &frame, renderer: renderer, x: rect.x + 10, y: rect.y + 6, size: 22, color: selected ? colors.text : colors.dim)
            MK2SelectionDrawing.drawBody(item.title, into: &frame, renderer: renderer, x: rect.x + 42, y: rect.y + 8, color: selected ? colors.text : colors.dim, maxWidth: max(0, rect.width - 48))
        } else {
            MK2SelectionDrawing.drawBody(item.title, into: &frame, renderer: renderer, x: rect.x + 8, y: rect.y + 8, color: selected ? colors.text : colors.dim, maxWidth: max(0, rect.width - 16))
        }
        if let badge = item.badge, rect.height >= 44 {
            MK2SelectionDrawing.drawBody(badge, into: &frame, renderer: renderer, x: rect.x + 8, y: rect.maxY - 22, color: selected ? colors.dim : colors.muted, maxWidth: max(0, rect.width - 16))
        }
    }

    private func firstVisibleRow(selectedRow: Int, visibleRows: Int, itemCount: Int, columns: Int) -> Int {
        let totalRows = max(1, ((itemCount - 1) / columns) + 1)
        let maxFirstRow = max(0, totalRows - visibleRows)
        return min(maxFirstRow, (selectedRow / visibleRows) * visibleRows)
    }
}

public struct MK2SelectionCellSize: Sendable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = max(48, width)
        self.height = max(32, height)
    }
}

private enum MK2SelectionDrawing {
    static func screenChrome(title: String, subtitle: String?, filters: [MK2SelectionFilter], colors: MK2SelectionViewColors) -> MK2RegularScreenChrome {
        MK2RegularScreenChrome(
            header: .title(title: title, subtitle: subtitle, subtitleAlignment: .trailing),
            footer: filters.isEmpty ? .none : .filters(),
            colors: MK2ScreenChromeColors(
                background: colors.background,
                text: colors.text,
                dim: colors.dim,
                accent: colors.accent,
                border: colors.border
            )
        )
    }

    static func drawEmpty(_ text: String, into frame: inout MK2PixelFrame, rect: MK2PixelRect, colors: MK2SelectionViewColors) {
        BitmapLabel(text, font: .grid, color: colors.dim)
            .draw(into: &frame, x: rect.x + 12, y: rect.y + 32, clip: rect)
    }

    static func drawFilters(_ filters: [MK2SelectionFilter], into frame: inout MK2PixelFrame, colors: MK2SelectionViewColors, renderer: FreeTypeTextRenderer?) {
        guard !filters.isEmpty else { return }
        let slotWidth = MK2PixelFrame.width / 4
        let visibleFilters = Array(filters.prefix(4))
        for index in visibleFilters.indices {
            let filter = filters[index]
            let slot = filter.encoderSlot(fallback: index)
            let x = slot * slotWidth + 8
            // Bottom-flush like every encoder-bound value cell: the filter maps to a
            // physical encoder below the display. The label names the filter, not
            // the encoder (HIG: the cell already sits above its physical control).
            let rect = MK2PixelRect(x: x, y: MK2ScreenLayout.encoderSlotBottom - 34, width: slotWidth - 16, height: 34)
            MK2ValueCell(
                label: filter.label,
                iconGlyph: filter.iconGlyph,
                value: filter.value,
                rect: rect,
                isFocused: filter.isFocused,
                valueFont: .gridBold,
                cornerRadius: 7,
                colors: MK2ValueCellColors(
                    label: filter.isActive ? colors.accent : colors.dim,
                    value: colors.filterValue,
                    border: colors.border,
                    fill: colors.background,
                    focusedValue: colors.background,
                    focusedFill: colors.accent,
                    focusedBorder: colors.accent,
                    // Icon tint distinct from the label in both states (HIG).
                    icon: filter.isActive ? colors.filterValue : colors.accent
                )
            ).draw(into: &frame, renderer: renderer)
        }
    }

    static func drawRoundedPanel(
        _ rect: MK2PixelRect,
        fill: UInt16,
        border: UInt16,
        radius: Int,
        into frame: inout MK2PixelFrame
    ) {
        frame.fillRounded(rect, radius: radius, border, antialiased: true)
        let inset = 1
        let inner = MK2PixelRect(
            x: rect.x + inset,
            y: rect.y + inset,
            width: max(0, rect.width - inset * 2),
            height: max(0, rect.height - inset * 2)
        )
        frame.fillRounded(inner, radius: max(0, radius - inset), fill, antialiased: true)
    }

    static func drawBody(
        _ text: String,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?,
        x: Int,
        y: Int,
        color: UInt16,
        maxWidth: Int
    ) {
        let style = MK2HIG.bodyTextStyle(color: color)
        guard let renderer,
              (try? renderer.drawText(text, into: &frame, x: x, y: y, style: style, maxWidth: maxWidth)) != nil else {
            BitmapLabel(text, font: .grid, color: color)
                .draw(into: &frame, x: x, y: y + 3, clip: MK2PixelRect(x: x, y: y, width: maxWidth, height: 18))
            return
        }
    }

    static func drawIcon(
        _ glyph: String,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?,
        x: Int,
        y: Int,
        size: Int,
        color: UInt16
    ) {
        let style = MK2HIG.iconStyle(pixelSize: size, color: color)
        guard let renderer,
              (try? renderer.drawText(glyph, into: &frame, x: x, y: y, style: style, maxWidth: size + 12)) != nil else {
            BitmapLabel("*", font: .gridBold, color: color)
                .draw(into: &frame, x: x, y: y + 3)
            return
        }
    }
}

private extension MK2SelectionFilter {
    /// The visual slot under the physical encoder: E1–E4 drive left-screen
    /// slots, E5–E8 right-screen slots — the cell must sit above the encoder
    /// that turns it regardless of which display hosts the view.
    func encoderSlot(fallback: Int) -> Int {
        guard (1...8).contains(encoder) else {
            return fallback.clamped(to: 0...3)
        }
        return (encoder - 1) % 4
    }
}

private extension Int {
    func clamped(to bounds: ClosedRange<Int>) -> Int {
        Swift.min(bounds.upperBound, Swift.max(bounds.lowerBound, self))
    }

    func wrapped(to bounds: ClosedRange<Int>) -> Int {
        let count = bounds.upperBound - bounds.lowerBound + 1
        guard count > 0 else { return bounds.lowerBound }
        let raw = (self - bounds.lowerBound) % count
        let offset = raw >= 0 ? raw : raw + count
        return bounds.lowerBound + offset
    }
}
