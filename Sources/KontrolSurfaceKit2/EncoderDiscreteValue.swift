import Foundation

/// Standard value-cell presentation for an encoder-bound discrete value.
public struct MK2EncoderDiscreteValueDisplay: Sendable {
    public var label: String
    public var iconGlyph: String?
    public var iconPosition: MK2ValueCell.IconPosition
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
        iconPosition: MK2ValueCell.IconPosition = .leading,
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
        MK2ValueCell(
            label: label,
            iconGlyph: iconGlyph,
            iconPosition: iconPosition,
            value: value,
            rect: rect,
            isFocused: isFocused,
            valueFont: valueFont,
            labelFont: labelFont,
            cornerRadius: cornerRadius,
            colors: colors
        ).draw(into: &frame, renderer: renderer)
    }
}

/// Accumulates raw encoder counts into whole value steps, so small domains
/// keep a usable throw: state must survive scene re-presents (bindings are
/// rebuilt on every projection), hence a process-wide store keyed by encoder.
/// The remainder is transient sub-step rotation; direction flips decay it
/// naturally through signed accumulation.
///
/// Fast turns accelerate the incoming counts by rotation *rate* (counts per
/// second from the daemon-side timestamps), never by report cadence — during
/// any continuous turn reports arrive a few milliseconds apart, so a
/// cadence rule degenerates into a permanent multiplier and destroys the
/// throw scaling. The factor ramps from 1 below `slowCountsPerSecond` to the
/// value's domain-scaled ceiling at `fastCountsPerSecond`: slow rotation is
/// always unscaled (precision), and only domains too large to sweep raw get
/// a ceiling above 1. Without a timestamp (0) counts stay unscaled.
final class MK2EncoderDetents: @unchecked Sendable {
    static let shared = MK2EncoderDetents()
    /// Rotation rate up to which counts stay unscaled — a deliberate slow
    /// turn must always move by single steps, on every domain size.
    static let slowCountsPerSecond = 150.0
    /// Rotation rate at which the domain-scaled ceiling is reached.
    static let fastCountsPerSecond = 1200.0

    private let lock = NSLock()
    private var remainders: [Int: Int] = [:]
    private var lastTurnNanos: [Int: UInt64] = [:]

    func steps(
        encoder: Int,
        delta: Int,
        countsPerStep: Int,
        maximumAcceleration: Double = 1,
        timestampNanos: UInt64 = 0
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let factor = accelerationLocked(
            encoder: encoder,
            delta: delta,
            maximum: maximumAcceleration,
            timestampNanos: timestampNanos
        )
        let accelerated = Int((Double(delta) * factor).rounded())
        guard countsPerStep > 1 else { return accelerated }
        let accumulated = (remainders[encoder] ?? 0) + accelerated
        let steps = accumulated / countsPerStep
        remainders[encoder] = accumulated % countsPerStep
        return steps
    }

    private func accelerationLocked(
        encoder: Int,
        delta: Int,
        maximum: Double,
        timestampNanos: UInt64
    ) -> Double {
        guard timestampNanos != 0 else { return 1 }
        let previous = lastTurnNanos[encoder] ?? 0
        lastTurnNanos[encoder] = timestampNanos
        guard maximum > 1, previous != 0, timestampNanos > previous else { return 1 }
        let elapsed = max(0.001, Double(timestampNanos &- previous) / 1_000_000_000.0)
        let rate = Double(abs(delta)) / elapsed
        guard rate > Self.slowCountsPerSecond else { return 1 }
        guard rate < Self.fastCountsPerSecond else { return maximum }
        let position = (rate - Self.slowCountsPerSecond) / (Self.fastCountsPerSecond - Self.slowCountsPerSecond)
        return 1 + (maximum - 1) * position
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        remainders.removeAll()
        lastTurnNanos.removeAll()
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
    /// Rotation for a slow full domain sweep the automatic derivation aims
    /// for. Only governs the mid-size range between the two clamps; large
    /// domains ride the precision floor and are swept by acceleration.
    public static let targetSweepCounts = 480
    /// Upper bound of the automatic derivation, so tiny domains stay
    /// reachable without excessive cranking. Bench-tuned 2026-07-12 in three
    /// rounds: 90 clearly heavy, 60 slightly sluggish, split the difference.
    public static let maximumCountsPerStep = 42
    /// Lower bound of the automatic derivation: the slow-turn targeting
    /// floor. Bench-tuned 2026-07-12: at 4 counts mid-size domains were too
    /// nervous to land on a specific value; a deliberate nudge now takes a
    /// clear rotation on every domain, and sweeping is the acceleration's
    /// job alone.
    public static let minimumCountsPerStep = 24
    /// Accelerated counts a fast full-domain sweep should take; sets the
    /// per-value acceleration ceiling via `sweepAcceleration(for:countsPerStep:)`.
    public static let fastSweepCounts = 600

    public static func automaticCountsPerStep(for bounds: ClosedRange<Int>) -> Int {
        let transitions = max(1, bounds.count - 1)
        return min(maximumCountsPerStep, max(minimumCountsPerStep, targetSweepCounts / transitions))
    }

    /// How far fast rotation may scale the counts: exactly enough that a
    /// fast sweep crosses the domain in ~`fastSweepCounts`, and never above
    /// 1 for domains that sweep comfortably unscaled.
    public static func sweepAcceleration(for bounds: ClosedRange<Int>, countsPerStep: Int) -> Double {
        let transitions = max(1, bounds.count - 1)
        return max(1, Double(transitions * countsPerStep) / Double(fastSweepCounts))
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
        bindings.encoder[encoder] = { [countsPerStep = resolvedCountsPerStep, bounds] delta, _, timestampNanos in
            let steps = MK2EncoderDetents.shared.steps(
                encoder: encoder,
                delta: delta,
                countsPerStep: countsPerStep,
                maximumAcceleration: Self.sweepAcceleration(for: bounds, countsPerStep: countsPerStep),
                timestampNanos: timestampNanos
            )
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

    public func drawDisplay(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer? = nil) {
        display?.draw(into: &frame, renderer: renderer)
    }
}
