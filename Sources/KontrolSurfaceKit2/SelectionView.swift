import Foundation

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
        let content = MK2SelectionDrawing.contentRect(hasFilters: !filters.isEmpty)
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
        let rect = MK2PixelRect(x: 8, y: y + 1, width: 464, height: rowHeight - 3)
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
    public var title: String
    public var subtitle: String?
    public var items: [MK2SelectionItem]
    public var selectedIndex: Int
    public var cellSize: MK2SelectionCellSize
    public var filters: [MK2SelectionFilter]
    public var colors: MK2SelectionViewColors

    public init(
        title: String,
        subtitle: String? = nil,
        items: [MK2SelectionItem],
        selectedIndex: Int,
        cellSize: MK2SelectionCellSize,
        filters: [MK2SelectionFilter] = [],
        colors: MK2SelectionViewColors = MK2SelectionViewColors()
    ) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.selectedIndex = selectedIndex
        self.cellSize = cellSize
        self.filters = filters
        self.colors = colors
    }

    public func draw(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer? = nil) {
        frame.fill(MK2PixelFrame.bounds, colors.background)
        MK2SelectionDrawing.drawHeader(title: title, subtitle: subtitle, into: &frame, colors: colors)
        let content = MK2SelectionDrawing.contentRect(hasFilters: !filters.isEmpty)
        guard !items.isEmpty else {
            MK2SelectionDrawing.drawEmpty("Keine Einträge", into: &frame, rect: content, colors: colors)
            MK2SelectionDrawing.drawFilters(filters, into: &frame, colors: colors)
            return
        }

        let columns = max(1, content.width / cellSize.width)
        let rows = max(1, content.height / cellSize.height)
        let selected = selectedIndex.clamped(to: 0...(items.count - 1))
        let selectedRow = selected / columns
        let firstRow = min(max(0, selectedRow - rows / 2), max(0, ((items.count - 1) / columns) - rows + 1))
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
    static func contentRect(hasFilters: Bool) -> MK2PixelRect {
        if hasFilters {
            return MK2PixelRect(x: 8, y: 45, width: 464, height: 132)
        }
        return MK2PixelRect(x: 8, y: 45, width: 464, height: 219)
    }

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
        let area = MK2PixelRect(x: 0, y: 184, width: MK2PixelFrame.width, height: 88)
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
}
