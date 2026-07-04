import Testing
import KompleteKontrol
@testable import KontrolSurfaceKit2

@Suite("Button range selection")
struct ButtonRangeSelectionTests {
    @Test("Lower edge turns previous button off and leaves next available")
    func lowerEdge() {
        let box = SelectionBox()
        var lamps: [KKMK2ButtonLED: MK2LampState2] = [:]
        var bindings = MK2InputBindings2()

        MK2ButtonRangeSelection(
            value: 0,
            bounds: 0...3,
            previousButton: .presetUp,
            nextButton: .presetDown,
            availableLamp: .white,
            onSelect: { box.append($0) }
        ).apply(lamps: &lamps, bindings: &bindings)

        #expect(lamps[.presetUp] == .off)
        #expect(lamps[.presetDown] == .white)
        #expect(bindings.buttonDown[.presetUp] == nil)

        bindings.buttonDown[.presetDown]?()
        #expect(box.values == [1])
    }

    @Test("Upper edge leaves previous available and turns next button off")
    func upperEdge() {
        let box = SelectionBox()
        var lamps: [KKMK2ButtonLED: MK2LampState2] = [:]
        var bindings = MK2InputBindings2()

        MK2ButtonRangeSelection(
            value: 3,
            bounds: 0...3,
            previousButton: .presetUp,
            nextButton: .presetDown,
            availableLamp: .white,
            onSelect: { box.append($0) }
        ).apply(lamps: &lamps, bindings: &bindings)

        #expect(lamps[.presetUp] == .white)
        #expect(lamps[.presetDown] == .off)
        #expect(bindings.buttonDown[.presetDown] == nil)

        bindings.buttonDown[.presetUp]?()
        #expect(box.values == [2])
    }

    @Test("Middle value exposes both directions")
    func middleValue() {
        let box = SelectionBox()
        var lamps: [KKMK2ButtonLED: MK2LampState2] = [:]
        var bindings = MK2InputBindings2()

        MK2ButtonRangeSelection(
            value: 2,
            bounds: 0...4,
            previousButton: .presetUp,
            nextButton: .presetDown,
            availableLamp: .white,
            onSelect: { box.append($0) }
        ).apply(lamps: &lamps, bindings: &bindings)

        #expect(lamps[.presetUp] == .white)
        #expect(lamps[.presetDown] == .white)

        bindings.buttonDown[.presetUp]?()
        bindings.buttonDown[.presetDown]?()
        #expect(box.values == [1, 3])
    }
}

private final class SelectionBox: @unchecked Sendable {
    private var storage: [Int] = []

    var values: [Int] {
        storage
    }

    func append(_ value: Int) {
        storage.append(value)
    }
}
