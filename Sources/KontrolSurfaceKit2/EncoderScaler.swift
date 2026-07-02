import Foundation

/// Velocity-sensitive scaling for the high-resolution rotaries, ported from the MK1
/// kit's tuned feel: the base increment is range-relative — a slow full sweep takes
/// about 900 encoder counts regardless of the target range — and short inter-report
/// intervals accelerate it (3× under 90 ms, 5× under 35 ms). The raw count delta
/// scales linearly on top, which already reflects how far the encoder moved, so slow
/// turns stay precise while fast turns cover the range quickly.
public struct MK2EncoderScaler: Sendable {
    private var lastTurnNanos = [UInt64](repeating: 0, count: 16)

    public init() {}

    public mutating func step(
        encoder: Int,
        delta: Int,
        span: Double,
        sensitivity: Double = 1,
        now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Double {
        guard lastTurnNanos.indices.contains(encoder) else { return 0 }
        let previous = lastTurnNanos[encoder]
        let elapsed = previous == 0 ? 1.0 : Double(now &- previous) / 1_000_000_000.0
        lastTurnNanos[encoder] = now

        let perCount = max(span, .ulpOfOne) / 900.0
        let acceleration: Double = if elapsed < 0.035 {
            5
        } else if elapsed < 0.090 {
            3
        } else {
            1
        }
        return Double(delta) * perCount * acceleration * sensitivity
    }
}
