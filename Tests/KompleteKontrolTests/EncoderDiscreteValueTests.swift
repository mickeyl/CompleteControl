import Testing
@testable import KontrolSurfaceKit2

// Serialized: the detent/acceleration tests exercise the process-wide
// MK2EncoderDetents.shared store (two of them on the same encoder index) —
// parallel execution races their reset() calls against each other.
@Suite("Encoder discrete value", .serialized)
struct EncoderDiscreteValueTests {
    @Test("Non-wrapping values clamp at both bounds")
    func clampsWithoutWrapAround() {
        let low = MK2EncoderDiscreteValue(encoder: 4, value: 0, bounds: 0...3, wraps: false, onChange: { _ in })
        let high = MK2EncoderDiscreteValue(encoder: 4, value: 3, bounds: 0...3, wraps: false, onChange: { _ in })

        #expect(low.value(after: -1) == 0)
        #expect(high.value(after: 1) == 3)
        #expect(MK2EncoderDiscreteValue(encoder: 4, value: 1, bounds: 0...3, wraps: false, onChange: { _ in }).value(after: 2) == 3)
    }

    @Test("Wrapping values cycle through the range")
    func wrapsAroundRange() {
        let low = MK2EncoderDiscreteValue(encoder: 4, value: 0, bounds: 0...9, wraps: true, onChange: { _ in })
        let high = MK2EncoderDiscreteValue(encoder: 4, value: 9, bounds: 0...9, wraps: true, onChange: { _ in })

        #expect(low.value(after: -1) == 9)
        #expect(high.value(after: 1) == 0)
        #expect(low.value(after: 11) == 1)
    }

    @Test("Tiny domains clamp even when wrapping is requested")
    func tinyDomainsNeverWrap() {
        // An on/off toggle or a three-way mode must park at its ends — one
        // detent past the end would otherwise flip the value around again.
        let toggle = MK2EncoderDiscreteValue(encoder: 4, value: 1, bounds: 0...1, wraps: true, onChange: { _ in })
        let mode = MK2EncoderDiscreteValue(encoder: 4, value: 0, bounds: 0...2, wraps: true, onChange: { _ in })

        #expect(toggle.value(after: 1) == 1)
        #expect(toggle.value(after: -3) == 0)
        #expect(mode.value(after: -1) == 0)
        #expect(mode.value(after: 7) == 2)
    }

    @Test("Apply installs touch and encoder callbacks")
    func installsBindings() {
        let box = EncoderBox()
        var bindings = MK2InputBindings2()

        MK2EncoderDiscreteValue(
            encoder: 6,
            value: 10,
            bounds: 0...64,
            countsPerStep: 1,
            onTouch: { box.touch($0) },
            onChange: { box.change($0) }
        ).apply(bindings: &bindings)

        bindings.encoderTouch[6]?(true)
        bindings.encoder[6]?(2, 0, 0)

        #expect(box.touches == [true])
        #expect(box.values == [12])
        // No default value declared: double-touch stays unbound.
        #expect(bindings.encoderDoubleTouch[6] == nil)
    }

    @Test("Double-touch resets to the default value")
    func doubleTouchResetsToDefault() {
        let box = EncoderBox()
        var bindings = MK2InputBindings2()

        MK2EncoderDiscreteValue(
            encoder: 6,
            value: 10,
            bounds: 0...64,
            defaultValue: 32,
            onChange: { box.change($0) }
        ).apply(bindings: &bindings)

        bindings.encoderDoubleTouch[6]?()
        #expect(box.values == [32])
    }

    @Test("Double-touch on an already-default value stays silent")
    func doubleTouchAtDefaultIsSilent() {
        let box = EncoderBox()
        var bindings = MK2InputBindings2()

        MK2EncoderDiscreteValue(
            encoder: 6,
            value: 32,
            bounds: 0...64,
            defaultValue: 32,
            onChange: { box.change($0) }
        ).apply(bindings: &bindings)

        bindings.encoderDoubleTouch[6]?()
        #expect(box.values.isEmpty)
    }

    @Test("Out-of-bounds default values clamp into the domain")
    func defaultValueClamps() {
        let value = MK2EncoderDiscreteValue(
            encoder: 6,
            value: 10,
            bounds: 0...64,
            defaultValue: 100,
            onChange: { _ in }
        )
        #expect(value.defaultValue == 64)
    }

    @Test("Automatic counts-per-step targets a constant sweep, clamped on both ends")
    func automaticCountsPerStep() {
        // Three-way mode: clamped to the per-step maximum.
        #expect(MK2EncoderDiscreteValue.automaticCountsPerStep(for: 0...2) == MK2EncoderDiscreteValue.maximumCountsPerStep)
        // Mid-size domain: full sweep ≈ targetSweepCounts.
        #expect(MK2EncoderDiscreteValue.automaticCountsPerStep(for: 0...15) == 32)
        // Large domains keep the slow-turn targeting floor — sweeping them
        // is the acceleration's job.
        #expect(MK2EncoderDiscreteValue.automaticCountsPerStep(for: 0...8191) == MK2EncoderDiscreteValue.minimumCountsPerStep)
    }

    @Test("Acceleration ceiling scales with the domain, never below 1")
    func sweepAccelerationScaling() {
        // Small domains sweep unscaled.
        #expect(MK2EncoderDiscreteValue.sweepAcceleration(for: 0...2, countsPerStep: 60) == 1)
        #expect(MK2EncoderDiscreteValue.sweepAcceleration(for: 0...31, countsPerStep: 6) == 1)
        // Huge domains get exactly the ceiling a fast sweep needs.
        let huge = MK2EncoderDiscreteValue.sweepAcceleration(for: 0...8191, countsPerStep: 4)
        #expect(huge > 50 && huge < 60)
    }

    @Test("Sub-step rotation accumulates across reports before a value change")
    func detentAccumulation() {
        MK2EncoderDetents.shared.reset()
        let box = EncoderBox()
        var bindings = MK2InputBindings2()

        MK2EncoderDiscreteValue(
            encoder: 3,
            value: 1,
            bounds: 0...2,
            countsPerStep: 10,
            onChange: { box.change($0) }
        ).apply(bindings: &bindings)

        bindings.encoder[3]?(6, 0, 0)
        #expect(box.values.isEmpty)
        bindings.encoder[3]?(4, 0, 0)
        #expect(box.values == [2])

        // Direction flip decays the remainder through signed accumulation.
        bindings.encoder[3]?(-6, 0, 0)
        #expect(box.values == [2])
        bindings.encoder[3]?(-4, 0, 0)
        #expect(box.values == [2, 0])
        MK2EncoderDetents.shared.reset()
    }

    @Test("Fast turns deliver multiple steps from one report")
    func fastTurnsSkipSteps() {
        MK2EncoderDetents.shared.reset()
        let box = EncoderBox()
        var bindings = MK2InputBindings2()

        MK2EncoderDiscreteValue(
            encoder: 3,
            value: 0,
            bounds: 0...10,
            countsPerStep: 5,
            onChange: { box.change($0) }
        ).apply(bindings: &bindings)

        bindings.encoder[3]?(23, 0, 0)
        #expect(box.values == [4])
        MK2EncoderDetents.shared.reset()
    }

    @Test("Slow turns stay single-step precise, fast turns sweep large domains")
    func rateBasedAcceleration() {
        MK2EncoderDetents.shared.reset()
        let box = EncoderBox()
        var bindings = MK2InputBindings2()

        MK2EncoderDiscreteValue(
            encoder: 2,
            value: 4096,
            bounds: 0...8191,
            onChange: { box.change($0) }
        ).apply(bindings: &bindings)

        // The binding captures value 4096 (production re-presents after each
        // change), so every emission is relative to it.
        let second: UInt64 = 1_000_000_000
        // A slow nudge — two reports of 12 counts, a second apart — moves
        // exactly one value, even on an 8192-value domain (24 counts/step).
        bindings.encoder[2]?(12, 0, second)
        #expect(box.values.isEmpty)
        bindings.encoder[2]?(12, 0, 2 * second)
        #expect(box.values == [4097])

        // A fast flick — 30 counts within 10 ms (3000 counts/s) — hits the
        // domain-scaled ceiling and covers hundreds of values in one report.
        bindings.encoder[2]?(30, 0, 2 * second + 10_000_000)
        let sweep = box.values.last! - 4096
        #expect(sweep > 300)

        // Reports whose *rate* is slow stay unscaled even when they follow
        // quickly: the factor tracks rotation speed, not report cadence.
        MK2EncoderDetents.shared.reset()
        let emissions = box.values.count
        bindings.encoder[2]?(1, 0, 2 * second + 60_000_000)
        bindings.encoder[2]?(1, 0, 2 * second + 110_000_000)
        #expect(box.values.count == emissions)

        MK2EncoderDetents.shared.reset()
    }

    @Test("Display projection draws the standard value cell")
    func displayDrawsValueCell() {
        let colors = MK2ValueCellColors(
            label: 0xffff,
            value: 0x07e0,
            border: 0x4208,
            fill: 0x001f,
            focusedValue: 0x0000,
            focusedFill: 0xc618,
            focusedBorder: 0xffff
        )
        let rect = MK2PixelRect(x: 20, y: 40, width: 80, height: 30)
        var frame = MK2PixelFrame()

        MK2EncoderDiscreteValue(
            encoder: 5,
            value: 19,
            bounds: 12...22,
            display: MK2EncoderDiscreteValueDisplay(
                label: "BODY",
                value: "19",
                rect: rect,
                isFocused: true,
                colors: colors
            ),
            onChange: { _ in }
        ).drawDisplay(into: &frame)

        func luminance(_ pixel: UInt16) -> Int {
            Int((pixel >> 11) & 0x1f) + Int((pixel >> 5) & 0x3f) + Int(pixel & 0x1f)
        }
        // The debossed well draws: shadow rim on top, lit rim below, bright focused fill.
        #expect(frame[rect.x, rect.y] != 0x0000)
        #expect(luminance(frame[rect.x + 40, rect.y]) < luminance(frame[rect.x + 40, rect.maxY - 1]))
        #expect(luminance(frame[rect.x + 2, rect.y + 15]) > 60)
    }

    @Test("Missing display projection is a no-op")
    func missingDisplayDoesNotDraw() {
        var frame = MK2PixelFrame()

        MK2EncoderDiscreteValue(
            encoder: 5,
            value: 19,
            bounds: 12...22,
            onChange: { _ in }
        ).drawDisplay(into: &frame)

        #expect(frame[20, 40] == 0x0000)
    }
}

private final class EncoderBox: @unchecked Sendable {
    private var touchStorage: [Bool] = []
    private var valueStorage: [Int] = []

    var touches: [Bool] { touchStorage }
    var values: [Int] { valueStorage }

    func touch(_ touched: Bool) {
        touchStorage.append(touched)
    }

    func change(_ value: Int) {
        valueStorage.append(value)
    }
}
