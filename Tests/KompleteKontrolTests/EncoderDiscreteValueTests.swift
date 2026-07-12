import Testing
@testable import KontrolSurfaceKit2

@Suite("Encoder discrete value")
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

    @Test("Automatic counts-per-step targets a constant sweep, clamped for tiny domains")
    func automaticCountsPerStep() {
        // Three-way mode: 200/2 = 100, clamped to the per-step maximum.
        #expect(MK2EncoderDiscreteValue.automaticCountsPerStep(for: 0...2) == MK2EncoderDiscreteValue.maximumCountsPerStep)
        // Mid-size domain: full sweep ≈ targetSweepCounts.
        #expect(MK2EncoderDiscreteValue.automaticCountsPerStep(for: 0...20) == 10)
        // Large domains stay near raw counts.
        #expect(MK2EncoderDiscreteValue.automaticCountsPerStep(for: 0...200) == 1)
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
