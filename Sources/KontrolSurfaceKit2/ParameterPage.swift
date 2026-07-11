import Foundation

public struct MK2ParameterPageSlot: Sendable {
    public var label: String
    public var value: String
    public var isFocused: Bool
    public var encoderValue: MK2EncoderDiscreteValue?
    public var colors: MK2ValueCellColors?
    /// Touch selection of the bound encoder; the runtime shows the focused
    /// appearance without an app round trip. `isFocused` stays the
    /// app-declared persistent selection on top of this.
    public var selection: MK2EncoderSelectionBehavior
    /// The encoder whose touch drives the selection when the slot carries no
    /// `encoderValue` — for slots whose encoder is bound separately (raw
    /// `MK2EncoderBindingElement`, velocity-scaled app-side values).
    public var selectionEncoder: Int?

    public init(
        label: String,
        value: String,
        isFocused: Bool = false,
        encoderValue: MK2EncoderDiscreteValue? = nil,
        colors: MK2ValueCellColors? = nil,
        selection: MK2EncoderSelectionBehavior = .momentary,
        selectionEncoder: Int? = nil
    ) {
        self.label = label
        self.value = value
        self.isFocused = isFocused
        self.encoderValue = encoderValue
        self.colors = colors
        self.selection = selection
        self.selectionEncoder = selectionEncoder
    }
}

public struct MK2ParameterPageElement: MK2ScreenElement {
    public var slots: [MK2ParameterPageSlot]
    /// Alternate slots shown while SHIFT is held. Slot indices keep their
    /// encoder correspondence; a shift slot without an `encoderValue` leaves
    /// the base encoder binding active (turning the encoder under shift then
    /// still edits the base parameter), so shift cells that change meaning
    /// must bring their own encoder value.
    public var shiftSlots: [MK2ParameterPageSlot]?
    public var rect: MK2PixelRect?
    public var columns: Int
    public var pageIndex: Int?
    public var pageCount: Int?
    public var colors: MK2ValueCellColors
    public var relativeToContent: Bool

    public init(
        slots: [MK2ParameterPageSlot],
        shiftSlots: [MK2ParameterPageSlot]? = nil,
        rect: MK2PixelRect? = nil,
        columns: Int = 4,
        pageIndex: Int? = nil,
        pageCount: Int? = nil,
        colors: MK2ValueCellColors = MK2ParameterPageElement.defaultColors,
        relativeToContent: Bool = true
    ) {
        self.slots = Array(slots.prefix(8))
        self.shiftSlots = shiftSlots.map { Array($0.prefix(8)) }
        self.rect = rect
        self.columns = min(4, max(1, columns))
        self.pageIndex = pageIndex
        self.pageCount = pageCount
        self.colors = colors
        self.relativeToContent = relativeToContent
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        if shiftSlots != nil {
            result.wantsShiftPass = true
        }
        let activeSlots = context.isShiftPass ? (shiftSlots ?? slots) : slots
        for slot in activeSlots {
            slot.encoderValue?.apply(bindings: &result.bindings)
        }

        let contentRect = context.layout?.contentRect ?? MK2PixelFrame.bounds
        let area = resolvedRect(contentRect: contentRect)
        guard !activeSlots.isEmpty, !area.isEmpty else { return }

        drawSlots(activeSlots, in: area, into: &frame, isShiftPass: context.isShiftPass, result: &result)
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
                height: max(0, contentRect.height - 12)
            )
        }
        guard relativeToContent else { return base }
        return MK2PixelRect(x: contentRect.x + base.x, y: contentRect.y + base.y, width: base.width, height: base.height)
    }

    private func drawSlots(
        _ slots: [MK2ParameterPageSlot],
        in area: MK2PixelRect,
        into frame: inout MK2PixelFrame,
        isShiftPass: Bool,
        result: inout MK2ScreenBuildResult
    ) {
        // Matches the canonical slot geometry: inter-cell gaps equal the screen margin,
        // so a four-column page over the full content width lands exactly on
        // `MK2ScreenLayout.encoderSlotXs`/`encoderSlotWidth`.
        let columnGap = MK2ScreenLayout.margin
        let rowGap = 18
        let rows = max(1, Int((Double(slots.count) / Double(columns)).rounded(.up)))
        let indicatorReserve = hasPageIndicator ? 12 : 0
        let availableHeight = max(0, area.height - indicatorReserve)
        let cellWidth = max(1, (area.width - columnGap * (columns - 1)) / columns)
        // A slot never grows past label + gap + the canonical cell height, and the
        // grid anchors to the area's bottom (clamped to the canonical slot bottom):
        // the cells map to the physical encoders below the display, so trailing
        // whitespace under them would break that association.
        let maxRowHeight = SurfaceFont.label.cellHeight + 4 + MK2ScreenLayout.encoderSlotHeight
        let rowHeight = min(maxRowHeight, max(1, (availableHeight - rowGap * (rows - 1)) / rows))
        let gridHeight = rows * rowHeight + rowGap * (rows - 1)
        let anchorBottom = min(area.maxY - indicatorReserve, MK2ScreenLayout.encoderSlotBottom)
        let startY = anchorBottom - gridHeight

        for (index, slot) in slots.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = area.x + column * (cellWidth + columnGap)
            let y = startY + row * (rowHeight + rowGap)
            let valueY = y + SurfaceFont.label.cellHeight + 4
            let valueHeight = min(MK2ScreenLayout.encoderSlotHeight, max(24, rowHeight - SurfaceFont.label.cellHeight - 4))
            let valueRect = MK2PixelRect(x: x, y: valueY, width: cellWidth, height: valueHeight)
            let cell = MK2ValueCell(
                label: slot.label.uppercased(),
                value: slot.value,
                rect: valueRect,
                isFocused: slot.isFocused,
                valueFont: .readoutBold,
                labelFont: .label,
                cornerRadius: 6,
                colors: slot.colors ?? colors
            )
            // Touch selection: capture the focused appearance as a prepared
            // overlay before the real cell paints over it. An already-focused
            // slot needs none — touched and focused look identical. The shift
            // pass never captures: its overlays would be dropped anyway and
            // touch highlights are suppressed while the layer is held.
            if !isShiftPass, !slot.isFocused, slot.selection != .none,
               let encoder = slot.encoderValue?.encoder ?? slot.selectionEncoder {
                var focusedCell = cell
                focusedCell.isFocused = true
                focusedCell.draw(into: &frame)
                result.touchOverlays[encoder] = MK2EncoderTouchOverlay(
                    rect: valueRect,
                    pixels: frame.pixels(in: valueRect),
                    behavior: slot.selection
                )
            }
            cell.draw(into: &frame)
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
