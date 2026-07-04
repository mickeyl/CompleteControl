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
    public var colors: MK2ValueCellColors

    public init(
        label: String,
        value: String,
        rect: MK2PixelRect,
        isFocused: Bool = false,
        valueFont: SurfaceFont = .readoutBold,
        labelFont: SurfaceFont = .label,
        colors: MK2ValueCellColors
    ) {
        self.label = label
        self.value = value
        self.rect = rect
        self.isFocused = isFocused
        self.valueFont = valueFont
        self.labelFont = labelFont
        self.colors = colors
    }

    public func draw(into frame: inout MK2PixelFrame) {
        BitmapLabel(label, font: labelFont, color: colors.label)
            .draw(into: &frame, x: rect.x, y: max(0, rect.y - labelFont.cellHeight - 6))

        frame.fill(rect, isFocused ? colors.focusedFill : colors.fill)
        frame.stroke(rect, isFocused ? colors.focusedBorder : colors.border)

        let glyph = BitmapLabel(value, font: valueFont, color: isFocused ? colors.focusedValue : colors.value)
        glyph.draw(
            into: &frame,
            x: rect.x + 6,
            y: rect.y + max(0, (rect.height - glyph.height) / 2),
            clip: MK2PixelRect(x: rect.x + 4, y: rect.y, width: max(0, rect.width - 8), height: rect.height)
        )
    }
}
