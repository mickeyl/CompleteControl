import Foundation

public struct MK2ValueCellColors: Sendable, Equatable {
    public var label: UInt16
    public var value: UInt16
    public var border: UInt16
    public var fill: UInt16
    public var focusedValue: UInt16
    public var focusedFill: UInt16
    public var focusedBorder: UInt16
    /// Tint of the label-line icon; nil derives a lightened label color so
    /// the icon always reads distinct from the label text.
    public var icon: UInt16?

    public init(
        label: UInt16,
        value: UInt16,
        border: UInt16,
        fill: UInt16 = 0x0000,
        focusedValue: UInt16 = 0x0000,
        focusedFill: UInt16 = 0xffff,
        focusedBorder: UInt16 = 0xffff,
        icon: UInt16? = nil
    ) {
        self.label = label
        self.value = value
        self.border = border
        self.fill = fill
        self.focusedValue = focusedValue
        self.focusedFill = focusedFill
        self.focusedBorder = focusedBorder
        self.icon = icon
    }
}

/// A labelled fixed-size value field intended for encoder-bound controls.
///
/// The label names the *parameter or unit*, never the encoder — the physical
/// encoder sits directly above the cell, so its identity is given by
/// position. An optional Phosphor icon on the label line carries the
/// parameter semantics visually; it renders in its own tint
/// (`MK2ValueCellColors.icon`), never in the label color.
public struct MK2ValueCell: Sendable {
    /// Vertical gap between the label line and the value well below it.
    public static let labelGap = 3
    /// Horizontal gap between the label-line icon and the label text.
    public static let iconGap = 4

    public enum IconPosition: Sendable, Equatable {
        /// Icon at the cell's leading edge, the label shifts inward.
        case leading
        /// Icon right-aligned to the cell's trailing edge.
        case trailing
    }

    public var label: String
    public var iconGlyph: String?
    public var iconPosition: IconPosition
    public var value: String
    public var rect: MK2PixelRect
    public var isFocused: Bool
    public var valueFont: SurfaceFont
    public var labelFont: SurfaceFont
    public var cornerRadius: Int
    public var colors: MK2ValueCellColors

    public init(
        label: String,
        iconGlyph: String? = nil,
        iconPosition: IconPosition = .leading,
        value: String,
        rect: MK2PixelRect,
        isFocused: Bool = false,
        valueFont: SurfaceFont = .readoutBold,
        labelFont: SurfaceFont = .label,
        cornerRadius: Int = 0,
        colors: MK2ValueCellColors
    ) {
        self.label = label
        self.iconGlyph = iconGlyph
        self.iconPosition = iconPosition
        self.value = value
        self.rect = rect
        self.isFocused = isFocused
        self.valueFont = valueFont
        self.labelFont = labelFont
        self.cornerRadius = max(0, cornerRadius)
        self.colors = colors
    }

    public func draw(into frame: inout MK2PixelFrame) {
        draw(into: &frame, renderer: nil)
    }

    public func draw(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer?) {
        let labelY = max(0, rect.y - labelFont.cellHeight - Self.labelGap)
        let iconInset = drawIconIfNeeded(into: &frame, renderer: renderer, labelY: labelY)
        BitmapLabel(label, font: labelFont, color: colors.label)
            .draw(into: &frame, x: rect.x + iconInset, y: labelY)

        // The value well is debossed into the panel: the border ring runs from a dark
        // shadow rim at the top into a lit edge at the bottom, and the fill falls
        // the same way — pressed in, lit from above. The `MK2HIG.Well` depth makes
        // the recess read as physically bound to the encoder beneath the display.
        // Both gradients quantize dithered so the ramps stay band-free on the OLED.
        let fill = isFocused ? colors.focusedFill : colors.fill
        let border = isFocused ? colors.focusedBorder : colors.border
        frame.fillRoundedVerticalGradient(
            rect,
            radius: cornerRadius,
            top: border.scaled565(by: MK2HIG.Well.rimShadow),
            bottom: border.scaled565(by: MK2HIG.Well.rimLight),
            antialiased: true
        )
        if rect.width > 2, rect.height > 2 {
            frame.fillRoundedVerticalGradient(
                MK2PixelRect(x: rect.x + 1, y: rect.y + 1, width: rect.width - 2, height: rect.height - 2),
                radius: max(0, cornerRadius - 1),
                top: fill.scaled565(by: MK2HIG.Well.fillTopDrop),
                bottom: fill.scaled565(by: MK2HIG.Well.fillBottomLift),
                antialiased: true
            )
        }

        let glyph = BitmapLabel(value, font: valueFont, color: isFocused ? colors.focusedValue : colors.value)
        glyph.draw(
            into: &frame,
            x: rect.x + 6,
            y: rect.y + max(0, (rect.height - glyph.height) / 2),
            clip: MK2PixelRect(x: rect.x + 4, y: rect.y, width: max(0, rect.width - 8), height: rect.height)
        )
    }

    /// Renders the label-line icon and returns the label's horizontal inset
    /// (icon advance + gap for a leading icon, 0 otherwise). Without a
    /// renderer the icon is skipped and the label stays at the cell edge.
    private func drawIconIfNeeded(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer?, labelY: Int) -> Int {
        guard let iconGlyph, !iconGlyph.isEmpty, let renderer else { return 0 }
        let pixelSize = labelFont.cellHeight + 3
        let style = MK2HIG.iconStyle(pixelSize: pixelSize, color: colors.icon ?? colors.label.scaled565(by: 1.6))
        guard let width = try? renderer.measure(iconGlyph, style: style), width > 0 else { return 0 }
        let x = iconPosition == .leading ? rect.x : rect.maxX - width
        let y = labelY - 2
        guard (try? renderer.drawText(iconGlyph, into: &frame, x: x, y: y, style: style, maxWidth: width + pixelSize)) != nil else { return 0 }
        return iconPosition == .leading ? width + Self.iconGap : 0
    }
}
