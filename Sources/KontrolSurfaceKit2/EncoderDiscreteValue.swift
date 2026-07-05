import Foundation

/// Standard value-cell presentation for an encoder-bound discrete value.
public struct MK2EncoderDiscreteValueDisplay: Sendable {
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
        MK2ValueCell(
            label: label,
            value: value,
            rect: rect,
            isFocused: isFocused,
            valueFont: valueFont,
            labelFont: labelFont,
            cornerRadius: cornerRadius,
            colors: colors
        ).draw(into: &frame)
    }
}

/// A discrete encoder-bound integer value with optional wrap-around.
public struct MK2EncoderDiscreteValue: Sendable {
    public var encoder: Int
    public var value: Int
    public var bounds: ClosedRange<Int>
    public var step: Int
    public var wraps: Bool
    public var display: MK2EncoderDiscreteValueDisplay?

    private let onTouch: @Sendable (_ touched: Bool) -> Void
    private let onChange: @Sendable (_ value: Int) -> Void

    public init(
        encoder: Int,
        value: Int,
        bounds: ClosedRange<Int>,
        step: Int = 1,
        wraps: Bool = false,
        display: MK2EncoderDiscreteValueDisplay? = nil,
        onTouch: @escaping @Sendable (_ touched: Bool) -> Void = { _ in },
        onChange: @escaping @Sendable (_ value: Int) -> Void
    ) {
        self.encoder = encoder
        self.value = value
        self.bounds = bounds
        self.step = max(1, step)
        self.wraps = wraps
        self.display = display
        self.onTouch = onTouch
        self.onChange = onChange
    }

    public func value(after delta: Int) -> Int {
        guard delta != 0 else { return value }
        let raw = value + delta * step
        if wraps {
            return raw.wrapped(to: bounds)
        }
        return min(bounds.upperBound, max(bounds.lowerBound, raw))
    }

    public func apply(bindings: inout MK2InputBindings2) {
        bindings.encoderTouch[encoder] = { touched in
            onTouch(touched)
        }
        bindings.encoder[encoder] = { delta, _, _ in
            let next = value(after: delta)
            if next != value {
                onChange(next)
            }
        }
    }

    public func drawDisplay(into frame: inout MK2PixelFrame) {
        display?.draw(into: &frame)
    }
}

private extension Int {
    func wrapped(to bounds: ClosedRange<Int>) -> Int {
        let count = bounds.upperBound - bounds.lowerBound + 1
        guard count > 0 else { return bounds.lowerBound }
        let raw = (self - bounds.lowerBound) % count
        let offset = raw >= 0 ? raw : raw + count
        return bounds.lowerBound + offset
    }
}
