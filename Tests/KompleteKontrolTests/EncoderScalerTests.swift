import Testing
@testable import KontrolSurfaceKit2

// Feel constants ported from the MK1 kit (ParameterPage.step): span/900 per count,
// 3x under 90 ms between reports, 5x under 35 ms.
@Suite("MK2 encoder scaler")
struct EncoderScalerTests {
    @Test("slow turns use the range-relative base step")
    func slowBaseStep() {
        var scaler = MK2EncoderScaler()
        let first = scaler.step(encoder: 1, delta: 3, span: 360, now: 1_000_000_000)
        #expect(abs(first - 3.0 * 360.0 / 900.0) < 0.0001)

        let second = scaler.step(encoder: 1, delta: -3, span: 360, now: 2_000_000_000)
        #expect(abs(second + 3.0 * 360.0 / 900.0) < 0.0001)
    }

    @Test("short report intervals accelerate 3x and 5x")
    func acceleration() {
        var scaler = MK2EncoderScaler()
        _ = scaler.step(encoder: 2, delta: 1, span: 900, now: 1_000_000_000)
        let medium = scaler.step(encoder: 2, delta: 1, span: 900, now: 1_050_000_000)
        #expect(abs(medium - 3.0) < 0.0001)
        let fast = scaler.step(encoder: 2, delta: 1, span: 900, now: 1_060_000_000)
        #expect(abs(fast - 5.0) < 0.0001)
    }

    @Test("encoders track velocity independently")
    func independentVelocity() {
        var scaler = MK2EncoderScaler()
        _ = scaler.step(encoder: 1, delta: 1, span: 900, now: 1_000_000_000)
        // encoder 3 has no history at this timestamp: base step despite encoder 1's pace
        let other = scaler.step(encoder: 3, delta: 1, span: 900, now: 1_010_000_000)
        #expect(abs(other - 1.0) < 0.0001)
    }

    @Test("sensitivity multiplies the step")
    func sensitivity() {
        var scaler = MK2EncoderScaler()
        let step = scaler.step(encoder: 4, delta: 2, span: 900, sensitivity: 0.5, now: 1_000_000_000)
        #expect(abs(step - 1.0) < 0.0001)
    }
}
