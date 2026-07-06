import Foundation

public struct MK2ParameterPageSlot: Sendable {
    public var label: String
    public var value: String
    public var isFocused: Bool
    public var encoderValue: MK2EncoderDiscreteValue?
    public var colors: MK2ValueCellColors?

    public init(
        label: String,
        value: String,
        isFocused: Bool = false,
        encoderValue: MK2EncoderDiscreteValue? = nil,
        colors: MK2ValueCellColors? = nil
    ) {
        self.label = label
        self.value = value
        self.isFocused = isFocused
        self.encoderValue = encoderValue
        self.colors = colors
    }
}

public struct MK2ParameterPageElement: MK2ScreenElement {
    public var slots: [MK2ParameterPageSlot]
    public var rect: MK2PixelRect?
    public var columns: Int
    public var pageIndex: Int?
    public var pageCount: Int?
    public var colors: MK2ValueCellColors
    public var relativeToContent: Bool

    public init(
        slots: [MK2ParameterPageSlot],
        rect: MK2PixelRect? = nil,
        columns: Int = 4,
        pageIndex: Int? = nil,
        pageCount: Int? = nil,
        colors: MK2ValueCellColors = MK2ParameterPageElement.defaultColors,
        relativeToContent: Bool = true
    ) {
        self.slots = Array(slots.prefix(8))
        self.rect = rect
        self.columns = min(4, max(1, columns))
        self.pageIndex = pageIndex
        self.pageCount = pageCount
        self.colors = colors
        self.relativeToContent = relativeToContent
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        for slot in slots {
            slot.encoderValue?.apply(bindings: &result.bindings)
        }

        let contentRect = context.layout?.contentRect ?? MK2PixelFrame.bounds
        let area = resolvedRect(contentRect: contentRect)
        guard !slots.isEmpty, !area.isEmpty else { return }

        drawSlots(in: area, into: &frame)
        drawPageIndicatorIfNeeded(in: area, into: &frame)
    }

    public static let defaultColors = MK2ValueCellColors(
        label: MK2HIG.Chrome.dim,
        value: MK2HIG.Chrome.text,
        border: MK2HIG.Chrome.border,
        fill: MK2HIG.Chrome.background,
        focusedValue: 0x0000,
        focusedFill: MK2HIG.Chrome.accent,
        focusedBorder: MK2HIG.Chrome.accent
    )

    private func resolvedRect(contentRect: MK2PixelRect) -> MK2PixelRect {
        let base: MK2PixelRect
        if let rect {
            base = rect
        } else {
            base = MK2PixelRect(
                x: MK2ScreenLayout.contentInset,
                y: 12,
                width: MK2PixelFrame.width - MK2ScreenLayout.contentInset * 2,
                height: max(0, contentRect.height - 20)
            )
        }
        guard relativeToContent else { return base }
        return MK2PixelRect(x: contentRect.x + base.x, y: contentRect.y + base.y, width: base.width, height: base.height)
    }

    private func drawSlots(in area: MK2PixelRect, into frame: inout MK2PixelFrame) {
        let columnGap = 12
        let rowGap = 18
        let rows = max(1, Int((Double(slots.count) / Double(columns)).rounded(.up)))
        let indicatorReserve = hasPageIndicator ? 12 : 0
        let availableHeight = max(0, area.height - indicatorReserve)
        let cellWidth = max(1, (area.width - columnGap * (columns - 1)) / columns)
        let rowHeight = min(70, max(1, (availableHeight - rowGap * (rows - 1)) / rows))

        for (index, slot) in slots.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = area.x + column * (cellWidth + columnGap)
            let y = area.y + row * (rowHeight + rowGap)
            let valueY = y + SurfaceFont.label.cellHeight + 4
            let valueHeight = min(38, max(24, rowHeight - SurfaceFont.label.cellHeight - 4))
            let valueRect = MK2PixelRect(x: x, y: valueY, width: cellWidth, height: valueHeight)
            MK2ValueCell(
                label: slot.label.uppercased(),
                value: slot.value,
                rect: valueRect,
                isFocused: slot.isFocused,
                valueFont: .readoutBold,
                labelFont: .label,
                cornerRadius: 6,
                colors: slot.colors ?? colors
            ).draw(into: &frame)
        }
    }

    private var hasPageIndicator: Bool {
        guard let pageCount else { return false }
        return pageCount > 1
    }

    private func drawPageIndicatorIfNeeded(in area: MK2PixelRect, into frame: inout MK2PixelFrame) {
        guard let pageCount, pageCount > 1 else { return }
        let dotSize = 5
        let spacing = 5
        let totalWidth = pageCount * dotSize + max(0, pageCount - 1) * spacing
        let current = (pageIndex ?? 0).clamped(to: 0...(pageCount - 1))
        let y = area.maxY - dotSize
        let x = area.maxX - totalWidth
        for index in 0..<pageCount {
            frame.fillRounded(
                MK2PixelRect(x: x + index * (dotSize + spacing), y: y, width: dotSize, height: dotSize),
                radius: dotSize / 2,
                index == current ? MK2HIG.Chrome.accent : MK2HIG.Chrome.border,
                antialiased: true
            )
        }
    }
}

private extension Int {
    func clamped(to bounds: ClosedRange<Int>) -> Int {
        Swift.min(bounds.upperBound, Swift.max(bounds.lowerBound, self))
    }
}
