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
        let low = MK2EncoderDiscreteValue(encoder: 4, value: 0, bounds: 0...3, wraps: true, onChange: { _ in })
        let high = MK2EncoderDiscreteValue(encoder: 4, value: 3, bounds: 0...3, wraps: true, onChange: { _ in })

        #expect(low.value(after: -1) == 3)
        #expect(high.value(after: 1) == 0)
        #expect(low.value(after: 5) == 1)
    }

    @Test("Apply installs touch and encoder callbacks")
    func installsBindings() {
        let box = EncoderBox()
        var bindings = MK2InputBindings2()

        MK2EncoderDiscreteValue(
            encoder: 6,
            value: 10,
            bounds: 0...64,
            onTouch: { box.touch($0) },
            onChange: { box.change($0) }
        ).apply(bindings: &bindings)

        bindings.encoderTouch[6]?(true)
        bindings.encoder[6]?(2, 0, 0)

        #expect(box.touches == [true])
        #expect(box.values == [12])
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

        #expect(frame[rect.x, rect.y] == colors.focusedBorder)
        #expect(frame[rect.x + 2, rect.y + 2] == colors.focusedFill)
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
