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

/// Accumulates raw encoder counts into whole value steps, so small domains
/// keep a usable throw: state must survive scene re-presents (bindings are
/// rebuilt on every projection), hence a process-wide store keyed by encoder.
/// The remainder is transient sub-step rotation; direction flips decay it
/// naturally through signed accumulation.
final class MK2EncoderDetents: @unchecked Sendable {
    static let shared = MK2EncoderDetents()
    private let lock = NSLock()
    private var remainders: [Int: Int] = [:]

    func steps(encoder: Int, delta: Int, countsPerStep: Int) -> Int {
        guard countsPerStep > 1 else { return delta }
        lock.lock()
        defer { lock.unlock() }
        let accumulated = (remainders[encoder] ?? 0) + delta
        let steps = accumulated / countsPerStep
        remainders[encoder] = accumulated % countsPerStep
        return steps
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        remainders.removeAll()
    }
}

/// A discrete encoder-bound integer value with optional wrap-around.
///
/// Wrap-around is honored only for domains of at least
/// `wrapMinimumValueCount` values. With only a handful — an on/off toggle, a
/// three-way mode — a wrapping value can hardly be controlled: one detent
/// past the end flips it around again instead of parking it, so tiny
/// domains always clamp regardless of `wraps`.
///
/// The rotaries are smooth high-resolution encoders (a slow full sweep is
/// ~900 counts, see `MK2EncoderScaler`): mapping one count to one value step
/// makes small domains uncontrollable — a three-way mode would sweep in two
/// counts. Values therefore derive counts-per-step from the domain size
/// (targeting `targetSweepCounts` for a full sweep, clamped to
/// `maximumCountsPerStep`), overridable via `countsPerStep`.
public struct MK2EncoderDiscreteValue: Sendable {
    public static let wrapMinimumValueCount = 8
    /// Rotation for a full domain sweep the automatic derivation aims for.
    /// Tuned on hardware; discrete selections want a much shorter throw than
    /// the ~900-count continuous sweep.
    public static let targetSweepCounts = 200
    /// Upper bound of the automatic derivation, so tiny domains stay
    /// reachable without excessive cranking.
    public static let maximumCountsPerStep = 90

    public static func automaticCountsPerStep(for bounds: ClosedRange<Int>) -> Int {
        let transitions = max(1, bounds.count - 1)
        return min(maximumCountsPerStep, max(1, targetSweepCounts / transitions))
    }

    public var encoder: Int
    public var value: Int
    public var bounds: ClosedRange<Int>
    public var step: Int
    public var wraps: Bool
    /// Double-touching the encoder resets to this value — the pro-audio
    /// "back to default" gesture. `nil` leaves double-touch unbound.
    public var defaultValue: Int?
    /// Raw encoder counts per value step; `nil` derives it from the domain
    /// size via `automaticCountsPerStep(for:)`.
    public var countsPerStep: Int?
    public var display: MK2EncoderDiscreteValueDisplay?

    private let onTouch: @Sendable (_ touched: Bool) -> Void
    private let onChange: @Sendable (_ value: Int) -> Void

    public init(
        encoder: Int,
        value: Int,
        bounds: ClosedRange<Int>,
        step: Int = 1,
        wraps: Bool = false,
        defaultValue: Int? = nil,
        countsPerStep: Int? = nil,
        display: MK2EncoderDiscreteValueDisplay? = nil,
        onTouch: @escaping @Sendable (_ touched: Bool) -> Void = { _ in },
        onChange: @escaping @Sendable (_ value: Int) -> Void
    ) {
        self.encoder = encoder
        self.value = value
        self.bounds = bounds
        self.step = max(1, step)
        self.wraps = wraps
        self.defaultValue = defaultValue.map { min(bounds.upperBound, max(bounds.lowerBound, $0)) }
        self.countsPerStep = countsPerStep.map { max(1, $0) }
        self.display = display
        self.onTouch = onTouch
        self.onChange = onChange
    }

    public var resolvedCountsPerStep: Int {
        countsPerStep ?? Self.automaticCountsPerStep(for: bounds)
    }

    public func value(after delta: Int) -> Int {
        guard delta != 0 else { return value }
        let raw = value + delta * step
        if wraps, bounds.count >= Self.wrapMinimumValueCount {
            return raw.wrapped(to: bounds)
        }
        return min(bounds.upperBound, max(bounds.lowerBound, raw))
    }

    public func apply(bindings: inout MK2InputBindings2) {
        bindings.encoderTouch[encoder] = { touched in
            onTouch(touched)
        }
        bindings.encoder[encoder] = { [countsPerStep = resolvedCountsPerStep] delta, _, _ in
            let steps = MK2EncoderDetents.shared.steps(encoder: encoder, delta: delta, countsPerStep: countsPerStep)
            guard steps != 0 else { return }
            let next = value(after: steps)
            if next != value {
                onChange(next)
            }
        }
        if let defaultValue {
            bindings.encoderDoubleTouch[encoder] = {
                guard defaultValue != value else { return }
                onChange(defaultValue)
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
