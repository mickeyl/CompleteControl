import Foundation
import KompleteKontrol

public struct MK2SelectionItem: Sendable, Equatable {
    public var title: String
    public var detail: String?
    public var badge: String?
    public var iconGlyph: String?

    public init(
        title: String,
        detail: String? = nil,
        badge: String? = nil,
        iconGlyph: String? = nil
    ) {
        self.title = title
        self.detail = detail
        self.badge = badge
        self.iconGlyph = iconGlyph
    }
}

public struct MK2SelectionFilter: Sendable, Equatable {
    public var label: String
    public var value: String
    public var encoder: Int
    public var isActive: Bool
    public var isFocused: Bool

    public init(label: String, value: String, encoder: Int, isActive: Bool = true, isFocused: Bool = false) {
        self.label = label
        self.value = value
        self.encoder = encoder
        self.isActive = isActive
        self.isFocused = isFocused
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
    public static let contentX = 8
    public static let contentY = 43
    public static let contentWidth = 464
    public static let contentHeight = 221
    public static let filteredContentHeight = 134
    public static let filterAreaY = 184
    public static let filterAreaHeight = 88

    public static func contentRect(hasFilters: Bool) -> MK2PixelRect {
        MK2PixelRect(
            x: contentX,
            y: contentY,
            width: contentWidth,
            height: hasFilters ? filteredContentHeight : contentHeight
        )
    }

    public static func gridColumnCount(for cellSize: MK2SelectionCellSize, contentWidth: Int = contentWidth) -> Int {
        max(1, contentWidth / cellSize.width)
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
        accent: UInt16 = 0xffe0,
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
    public var colors: MK2SelectionViewColors
    public var rowHeight: Int

    public init(
        title: String,
        subtitle: String? = nil,
        items: [MK2SelectionItem],
        selectedIndex: Int,
        filters: [MK2SelectionFilter] = [],
        rowHeight: Int = 30,
        colors: MK2SelectionViewColors = MK2SelectionViewColors()
    ) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.selectedIndex = selectedIndex
        self.filters = filters
        self.rowHeight = max(24, rowHeight)
        self.colors = colors
    }

    public func draw(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer? = nil) {
        frame.fill(MK2PixelFrame.bounds, colors.background)
        MK2SelectionDrawing.drawHeader(title: title, subtitle: subtitle, into: &frame, colors: colors)
        let content = MK2SelectionLayout.contentRect(hasFilters: !filters.isEmpty)
        guard !items.isEmpty else {
            MK2SelectionDrawing.drawEmpty("Keine Einträge", into: &frame, rect: content, colors: colors)
            MK2SelectionDrawing.drawFilters(filters, into: &frame, colors: colors)
            return
        }

        let visibleRows = max(1, content.height / rowHeight)
        let selected = selectedIndex.clamped(to: 0...(items.count - 1))
        let first = min(max(0, selected - visibleRows / 2), max(0, items.count - visibleRows))
        let last = min(items.count, first + visibleRows)

        for visible in first..<last {
            let y = content.y + (visible - first) * rowHeight
            drawRow(items[visible], index: visible, selected: visible == selected, y: y, into: &frame, renderer: renderer)
        }
        MK2SelectionDrawing.drawFilters(filters, into: &frame, colors: colors)
    }

    private func drawRow(
        _ item: MK2SelectionItem,
        index: Int,
        selected: Bool,
        y: Int,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?
    ) {
        let rect = MK2PixelRect(x: MK2SelectionLayout.contentX, y: y + 1, width: MK2SelectionLayout.contentWidth, height: rowHeight - 3)
        if selected {
            frame.fillRounded(rect, radius: 7, colors.selectionFill, antialiased: true)
        }
        if let iconGlyph = item.iconGlyph {
            MK2SelectionDrawing.drawIcon(iconGlyph, into: &frame, renderer: renderer, x: 20, y: y + 1, size: min(22, rowHeight - 6), color: selected ? colors.text : colors.dim)
        }
        let textX = item.iconGlyph == nil ? 20 : 58
        MK2SelectionDrawing.drawBody(item.title, into: &frame, renderer: renderer, x: textX, y: y + 3, color: selected ? colors.text : colors.dim, maxWidth: item.badge == nil ? 392 : 322)
        if let badge = item.badge {
            MK2SelectionDrawing.drawBody(badge, into: &frame, renderer: renderer, x: 386, y: y + 3, color: selected ? colors.text : colors.muted, maxWidth: 74)
        }
        if rowHeight >= 44, let detail = item.detail {
            MK2SelectionDrawing.drawBody(detail, into: &frame, renderer: renderer, x: textX, y: y + 24, color: selected ? colors.dim : colors.muted, maxWidth: 392)
        }
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
        frame.fill(MK2PixelFrame.bounds, colors.background)
        MK2SelectionDrawing.drawHeader(title: title, subtitle: subtitle, into: &frame, colors: colors)
        let content = MK2SelectionLayout.contentRect(hasFilters: !filters.isEmpty)
        guard !items.isEmpty else {
            MK2SelectionDrawing.drawEmpty("Keine Einträge", into: &frame, rect: content, colors: colors)
            MK2SelectionDrawing.drawFilters(filters, into: &frame, colors: colors)
            return
        }

        let columns = Self.columnCount(for: cellSize, contentWidth: content.width)
        let rows = visibleRowCount(in: content)
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
                y: content.y + row * cellSize.height + 3,
                width: cellSize.width - 6,
                height: cellSize.height - 6
            )
            drawCell(items[index], selected: index == selected, rect: rect, into: &frame, renderer: renderer)
        }
        MK2SelectionDrawing.drawFilters(filters, into: &frame, colors: colors)
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

    private func visibleRowCount(in content: MK2PixelRect) -> Int {
        if filters.isEmpty, case .iconOnly = cellContent {
            return max(1, (content.height + cellSize.height - 1) / cellSize.height)
        }
        return max(1, content.height / cellSize.height)
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
    static func drawHeader(title: String, subtitle: String?, into frame: inout MK2PixelFrame, colors: MK2SelectionViewColors) {
        BitmapLabel(title, font: .label, color: colors.accent)
            .draw(into: &frame, x: 8, y: 8, clip: MK2PixelRect(x: 8, y: 8, width: 220, height: 14))
        if let subtitle {
            BitmapLabel(subtitle, font: .label, color: colors.dim)
                .draw(into: &frame, x: 236, y: 8, clip: MK2PixelRect(x: 236, y: 8, width: 236, height: 14))
        }
    }

    static func drawEmpty(_ text: String, into frame: inout MK2PixelFrame, rect: MK2PixelRect, colors: MK2SelectionViewColors) {
        BitmapLabel(text, font: .grid, color: colors.dim)
            .draw(into: &frame, x: rect.x + 12, y: rect.y + 32, clip: rect)
    }

    static func drawFilters(_ filters: [MK2SelectionFilter], into frame: inout MK2PixelFrame, colors: MK2SelectionViewColors) {
        guard !filters.isEmpty else { return }
        let area = MK2PixelRect(x: 0, y: MK2SelectionLayout.filterAreaY, width: MK2PixelFrame.width, height: MK2SelectionLayout.filterAreaHeight)
        frame.fillRounded(area, radius: 8, colors.filterFill, antialiased: true)
        frame.fill(MK2PixelRect(x: 0, y: area.y, width: MK2PixelFrame.width, height: 1), colors.border)
        let slotWidth = MK2PixelFrame.width / 4
        let visibleFilters = Array(filters.prefix(4))
        for index in visibleFilters.indices {
            let filter = filters[index]
            let slot = filter.encoderSlot(fallback: index)
            let x = slot * slotWidth + 8
            let rect = MK2PixelRect(x: x, y: area.y + 34, width: slotWidth - 16, height: 34)
            MK2ValueCell(
                label: "E\(filter.encoder) \(filter.label)",
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
                    focusedBorder: colors.accent
                )
            ).draw(into: &frame)
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
        let style = FreeTypeTextStyle(
            familyID: FreeTypeFontCatalog.textFamilyID,
            weight: .regular,
            pixelSize: 16,
            color: color
        )
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
        let style = FreeTypeTextStyle(
            familyID: FreeTypeFontCatalog.iconProLightFamilyID,
            weight: .regular,
            pixelSize: size,
            color: color
        )
        guard let renderer,
              (try? renderer.drawText(glyph, into: &frame, x: x, y: y, style: style, maxWidth: size + 12)) != nil else {
            BitmapLabel("*", font: .gridBold, color: color)
                .draw(into: &frame, x: x, y: y + 3)
            return
        }
    }
}

private extension MK2SelectionFilter {
    func encoderSlot(fallback: Int) -> Int {
        guard (5...8).contains(encoder) else {
            return fallback.clamped(to: 0...3)
        }
        return encoder - 5
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
