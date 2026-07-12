import Foundation

public struct MK2SelectionFilterEncoderBinding: Sendable {
    public var encoder: Int
    public var value: Int
    public var bounds: ClosedRange<Int>
    public var step: Int
    public var wraps: Bool
    /// Raw encoder counts per value step; `nil` derives it from the domain
    /// size (see `MK2EncoderDiscreteValue.automaticCountsPerStep(for:)`).
    public var countsPerStep: Int?

    private let onFocus: @Sendable (_ encoder: Int, _ touched: Bool) -> Void
    private let onChange: @Sendable (_ value: Int) -> Void

    public init(
        encoder: Int,
        value: Int,
        bounds: ClosedRange<Int>,
        step: Int = 1,
        wraps: Bool = true,
        countsPerStep: Int? = nil,
        onFocus: @escaping @Sendable (_ encoder: Int, _ touched: Bool) -> Void = { _, _ in },
        onChange: @escaping @Sendable (_ value: Int) -> Void
    ) {
        self.encoder = encoder
        self.value = value
        self.bounds = bounds
        self.step = max(1, step)
        self.wraps = wraps
        self.countsPerStep = countsPerStep
        self.onFocus = onFocus
        self.onChange = onChange
    }

    public func apply(bindings: inout MK2InputBindings2) {
        MK2EncoderDiscreteValue(
            encoder: encoder,
            value: value,
            bounds: bounds,
            step: step,
            wraps: wraps,
            countsPerStep: countsPerStep,
            onTouch: { touched in
                onFocus(encoder, touched)
            },
            onChange: onChange
        )
        .apply(bindings: &bindings)
    }
}

public struct MK2SelectionFilterEncoderElement: MK2ScreenElement {
    public var bindings: [MK2SelectionFilterEncoderBinding]

    public init(_ bindings: [MK2SelectionFilterEncoderBinding]) {
        self.bindings = bindings
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        for binding in bindings {
            binding.apply(bindings: &result.bindings)
        }
    }
}
