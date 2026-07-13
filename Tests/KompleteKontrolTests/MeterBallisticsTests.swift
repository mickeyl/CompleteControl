import Foundation
import Testing
@testable import KontrolSurfaceKit2

@Suite("Meter ballistics")
struct MeterBallisticsTests {
    @Test("Pulse is an instant attack on level and peak")
    func pulseAttack() {
        var b = MK2MeterBallistics()
        b.pulse(0.9)
        #expect(b.level == 0.9)
        #expect(b.peak == 0.9)
        // A quieter pulse never pulls the louder level down.
        b.pulse(0.3)
        #expect(b.level == 0.9)
    }

    @Test("Release decays to the −20 dB floor over the release time, rate-independent")
    func releaseIsRateIndependent() {
        func levelAfterReleaseTime(tickMs: Int) -> Double {
            var b = MK2MeterBallistics(releaseMilliseconds: 360, peakHoldMilliseconds: 0, peakFallMilliseconds: 1500)
            b.pulse(1.0)
            var elapsed = 0
            while elapsed < 360 {
                b.step(tickMilliseconds: tickMs)
                elapsed += tickMs
            }
            return b.level
        }
        // Different tick rates land near the same 0.1 floor after the release time —
        // the decay derives from time, not from the frame count.
        #expect(abs(levelAfterReleaseTime(tickMs: 20) - 0.1) < 0.02)
        #expect(abs(levelAfterReleaseTime(tickMs: 10) - 0.1) < 0.02)
    }

    @Test("Peak holds through the hold window, then falls")
    func peakHoldThenFall() {
        var b = MK2MeterBallistics(releaseMilliseconds: 100, peakHoldMilliseconds: 200, peakFallMilliseconds: 1000)
        b.pulse(0.9)
        // Inside the hold window: peak stays put while the bar already decays.
        b.step(tickMilliseconds: 100)
        #expect(b.peak == 0.9)
        #expect(b.level < 0.9)
        // Past the hold window (>200 ms elapsed): the peak starts to fall.
        b.step(tickMilliseconds: 150)
        b.step(tickMilliseconds: 100)
        #expect(b.peak < 0.9)
    }

    @Test("Settles to zero and reports it, so the loop can stop")
    func settles() {
        var b = MK2MeterBallistics(releaseMilliseconds: 50, peakHoldMilliseconds: 0, peakFallMilliseconds: 50)
        b.pulse(1.0)
        #expect(!b.isSettled)
        var guardCounter = 0
        while b.step(tickMilliseconds: 20), guardCounter < 1_000 { guardCounter += 1 }
        #expect(b.isSettled)
        #expect(b.level == 0)
        #expect(b.peak == 0)
    }

    @Test("hold sets a static frame directly")
    func staticHold() {
        var b = MK2MeterBallistics()
        b.hold(level: 0.7, peak: 0.85)
        #expect(b.level == 0.7)
        #expect(b.peak == 0.85)
    }

    @Test("HIG defaults are the hardware-approved values")
    func higDefaults() {
        let b = MK2MeterBallistics()
        #expect(b.releaseMilliseconds == MK2HIG.Meter.Ballistics.releaseMilliseconds)
        #expect(b.peakHoldMilliseconds == MK2HIG.Meter.Ballistics.peakHoldMilliseconds)
        #expect(b.peakFallMilliseconds == MK2HIG.Meter.Ballistics.peakFallMilliseconds)
    }
}
