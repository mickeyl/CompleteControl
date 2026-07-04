import Foundation

/// A discrete encoder-bound integer value with optional wrap-around.
public struct MK2EncoderDiscreteValue: Sendable {
    public var encoder: Int
    public var value: Int
    public var bounds: ClosedRange<Int>
    public var step: Int
    public var wraps: Bool

    private let onTouch: @Sendable (_ touched: Bool) -> Void
    private let onChange: @Sendable (_ value: Int) -> Void

    public init(
        encoder: Int,
        value: Int,
        bounds: ClosedRange<Int>,
        step: Int = 1,
        wraps: Bool = false,
        onTouch: @escaping @Sendable (_ touched: Bool) -> Void = { _ in },
        onChange: @escaping @Sendable (_ value: Int) -> Void
    ) {
        self.encoder = encoder
        self.value = value
        self.bounds = bounds
        self.step = max(1, step)
        self.wraps = wraps
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
