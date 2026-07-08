import Foundation

public struct MK2ValueCellColors: Sendable, Equatable {
    public var label: UInt16
    public var value: UInt16
    public var border: UInt16
    public var fill: UInt16
    public var focusedValue: UInt16
    public var focusedFill: UInt16
    public var focusedBorder: UInt16

    public init(
        label: UInt16,
        value: UInt16,
        border: UInt16,
        fill: UInt16 = 0x0000,
        focusedValue: UInt16 = 0x0000,
        focusedFill: UInt16 = 0xffff,
        focusedBorder: UInt16 = 0xffff
    ) {
        self.label = label
        self.value = value
        self.border = border
        self.fill = fill
        self.focusedValue = focusedValue
        self.focusedFill = focusedFill
        self.focusedBorder = focusedBorder
    }
}

/// A labelled fixed-size value field intended for encoder-bound controls.
public struct MK2ValueCell: Sendable {
    public var label: String
    public var value: String
    public var rect: MK2PixelRect
    public var isFocused: Bool
    public var valueFont: SurfaceFont
    public var labelFont: SurfaceFont
    public var cornerRadius: Int
    public var colors: MK2ValueCellColors

    public init(
        label: String,
        value: String,
        rect: MK2PixelRect,
        isFocused: Bool = false,
        valueFont: SurfaceFont = .readoutBold,
        labelFont: SurfaceFont = .label,
        cornerRadius: Int = 0,
        colors: MK2ValueCellColors
    ) {
        self.label = label
        self.value = value
        self.rect = rect
        self.isFocused = isFocused
        self.valueFont = valueFont
        self.labelFont = labelFont
        self.cornerRadius = max(0, cornerRadius)
        self.colors = colors
    }

    public func draw(into frame: inout MK2PixelFrame) {
        BitmapLabel(label, font: labelFont, color: colors.label)
            .draw(into: &frame, x: rect.x, y: max(0, rect.y - labelFont.cellHeight - 3))

        // The value well is debossed into the panel: the border ring runs from a dark
        // shadow rim at the top into a lit edge at the bottom, and the fill falls
        // slightly the same way — pressed in, lit from above. Both gradients quantize
        // dithered so the ramps stay band-free on the OLED.
        let fill = isFocused ? colors.focusedFill : colors.fill
        let border = isFocused ? colors.focusedBorder : colors.border
        frame.fillRoundedVerticalGradient(
            rect,
            radius: cornerRadius,
            top: Self.scaled(border, by: 0.45),
            bottom: Self.scaled(border, by: 1.8),
            antialiased: true
        )
        if rect.width > 2, rect.height > 2 {
            frame.fillRoundedVerticalGradient(
                MK2PixelRect(x: rect.x + 1, y: rect.y + 1, width: rect.width - 2, height: rect.height - 2),
                radius: max(0, cornerRadius - 1),
                top: Self.scaled(fill, by: 0.7),
                bottom: Self.scaled(fill, by: 1.2),
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

    private static func scaled(_ color: UInt16, by factor: Double) -> UInt16 {
        let r = UInt16(min(31, (Double((color >> 11) & 0x1f) * factor).rounded()))
        let g = UInt16(min(63, (Double((color >> 5) & 0x3f) * factor).rounded()))
        let b = UInt16(min(31, (Double(color & 0x1f) * factor).rounded()))
        return (r << 11) | (g << 5) | b
    }
}
