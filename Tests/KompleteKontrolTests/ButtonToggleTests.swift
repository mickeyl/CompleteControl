import Testing
import KompleteKontrol
@testable import KontrolSurfaceKit2

@Suite("Button toggle")
struct ButtonToggleTests {
    @Test("Off state shows off lamp and press toggles on")
    func offStateTogglesOn() {
        let box = ToggleBox()
        var lamps: [KKMK2ButtonLED: MK2LampState2] = [:]
        var bindings = MK2InputBindings2()

        MK2ButtonToggle(
            button: .m,
            isOn: false,
            onLamp: .red,
            offLamp: .white,
            onToggle: { box.append($0) }
        ).apply(lamps: &lamps, bindings: &bindings)

        #expect(lamps[.m] == .white)

        bindings.buttonDown[.m]?()
        #expect(box.values == [true])
    }

    @Test("On state shows on lamp and press toggles off")
    func onStateTogglesOff() {
        let box = ToggleBox()
        var lamps: [KKMK2ButtonLED: MK2LampState2] = [:]
        var bindings = MK2InputBindings2()

        MK2ButtonToggle(
            button: .s,
            isOn: true,
            onLamp: .blue,
            offLamp: .off,
            onToggle: { box.append($0) }
        ).apply(lamps: &lamps, bindings: &bindings)

        #expect(lamps[.s] == .blue)

        bindings.buttonDown[.s]?()
        #expect(box.values == [false])
    }

    @Test("Display binding draws from the same toggle state")
    func displayBindingDrawsToggleState() {
        let colors = MK2ButtonToggleDisplayColors(
            onFill: 0xf800,
            onBorder: 0xffff,
            offFill: 0x001f,
            offBorder: 0x07e0,
            offText: 0xffff
        )
        let display = MK2ButtonToggleDisplay(
            label: "",
            rect: MK2PixelRect(x: 4, y: 5, width: 8, height: 7),
            colors: colors
        )

        var onFrame = MK2PixelFrame()
        MK2ButtonToggle(button: .m, isOn: true, display: display).drawDisplay(into: &onFrame)

        var offFrame = MK2PixelFrame()
        MK2ButtonToggle(button: .m, isOn: false, display: display).drawDisplay(into: &offFrame)

        #expect(onFrame[5, 6] == colors.onFill)
        #expect(onFrame[4, 5] == colors.onBorder)
        #expect(offFrame[5, 6] == colors.offFill)
        #expect(offFrame[4, 5] == colors.offBorder)
    }
}

private final class ToggleBox: @unchecked Sendable {
    private var storage: [Bool] = []

    var values: [Bool] {
        storage
    }

    func append(_ value: Bool) {
        storage.append(value)
    }
}
