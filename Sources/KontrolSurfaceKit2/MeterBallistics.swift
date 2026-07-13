import Foundation

/// Rate-independent VU-meter ballistics — the transformation half of the meter.
/// Instant attack, exponential release, and a peak marker that holds then falls
/// slower, all parametrized in *time* units (ms) so the decay factor derives
/// from the caller's actual tick interval rather than a magic per-frame
/// constant. The Kit owns this transformation; the *time driver* (timer/loop)
/// stays with the client, which calls `step(tickMilliseconds:)` each tick and
/// re-renders — the same boundary as any stateless screen element.
///
/// HIG-approved defaults live in `MK2HIG.Meter.Ballistics` (release 360, hold
/// 300, fall 1500 ms, signed off on hardware 2026-07-13).
///
/// One value per channel: the client holds an array, `pulse`es a momentary
/// value in, `step`s them all per tick, and feeds `level`/`peak` into
/// `MK2MeterChannel`.
public struct MK2MeterBallistics: Sendable, Equatable {
    /// Fall time of the bar to −20 dB (a tenth of full scale), in milliseconds.
    public var releaseMilliseconds: Int
    /// How long the peak marker holds at its captured value before it falls.
    public var peakHoldMilliseconds: Int
    /// Fall time of the peak marker to −20 dB once the hold expires.
    public var peakFallMilliseconds: Int

    public private(set) var level: Double
    public private(set) var peak: Double
    private var holdRemainingMilliseconds: Int

    public init(
        releaseMilliseconds: Int = MK2HIG.Meter.Ballistics.releaseMilliseconds,
        peakHoldMilliseconds: Int = MK2HIG.Meter.Ballistics.peakHoldMilliseconds,
        peakFallMilliseconds: Int = MK2HIG.Meter.Ballistics.peakFallMilliseconds
    ) {
        self.releaseMilliseconds = max(1, releaseMilliseconds)
        self.peakHoldMilliseconds = max(0, peakHoldMilliseconds)
        self.peakFallMilliseconds = max(1, peakFallMilliseconds)
        level = 0
        peak = 0
        holdRemainingMilliseconds = 0
    }

    /// True once the bar, the peak and the hold have all come to rest — the
    /// client's loop can stop stepping until the next pulse.
    public var isSettled: Bool {
        level < MK2HIG.Meter.Ballistics.silenceThreshold
            && peak < MK2HIG.Meter.Ballistics.silenceThreshold
            && holdRemainingMilliseconds == 0
    }

    /// Instant attack: raise the level and peak to `value` (clamped 0…1) and
    /// restart the peak hold. A value below the current level still refreshes
    /// the hold but leaves the louder level untouched.
    public mutating func pulse(_ value: Double) {
        let clamped = max(0, min(1, value))
        level = max(level, clamped)
        peak = max(peak, clamped)
        holdRemainingMilliseconds = peakHoldMilliseconds
    }

    /// Force the state directly — for a static/fixture frame with no animation.
    public mutating func hold(level: Double, peak: Double) {
        self.level = max(0, min(1, level))
        self.peak = max(0, min(1, peak))
        holdRemainingMilliseconds = 0
    }

    /// Advance one time step of `tickMilliseconds`; returns whether anything is
    /// still moving (i.e. the loop should keep going).
    @discardableResult
    public mutating func step(tickMilliseconds: Int) -> Bool {
        let dt = max(1, tickMilliseconds)
        let floor = MK2HIG.Meter.Ballistics.decayFloor
        let silence = MK2HIG.Meter.Ballistics.silenceThreshold

        level *= pow(floor, Double(dt) / Double(releaseMilliseconds))
        if level < silence { level = 0 }

        if holdRemainingMilliseconds > 0 {
            holdRemainingMilliseconds = max(0, holdRemainingMilliseconds - dt)
            peak = max(peak, level)
        } else {
            peak = max(level, peak * pow(floor, Double(dt) / Double(peakFallMilliseconds)))
        }
        if peak < silence { peak = 0 }

        return !isSettled
    }
}
