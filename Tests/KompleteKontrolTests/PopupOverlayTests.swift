import Testing
@testable import KontrolSurfaceKit2

@Suite("Popup overlay", .serialized)
struct PopupOverlayTests {
    @Test("Popup dims both backgrounds by half and preserves scene behavior")
    func dimsBackgroundAndPreservesBindings() {
        let box = PopupOverlayBox()
        var bindings = MK2InputBindings2()
        bindings.onPress(.function1) { box.presses += 1 }
        let base = MK2SurfaceScene2(
            left: MK2PixelFrame(fill: 0xFFFF),
            right: MK2PixelFrame(fill: 0xFFFF),
            bindings: bindings
        )
        let popup = MK2PopupOverlayElement(
            left: MK2PopupOverlayContent(title: "MIDI Input", body: "Play a key."),
            right: MK2PopupOverlayContent(title: "Waiting", body: "Move a control.")
        )

        let scene = popup.applying(to: base)

        #expect(scene.displays[0]?[0, 0] == 0x7BEF)
        #expect(scene.displays[1]?[0, 0] == 0x7BEF)
        #expect(scene.displays[0]?[MK2PopupOverlayElement.defaultRect.x, 100] == MK2HIG.Chrome.accent)
        #expect(scene.displays[1]?[MK2PopupOverlayElement.defaultRect.x, 100] == MK2HIG.Chrome.accent)
        scene.bindings.buttonDown[.function1]?()
        #expect(box.presses == 1)
    }

    @Test("Popup may preserve full background brightness")
    func canSkipBackgroundDimming() {
        let base = MK2SurfaceScene2(left: MK2PixelFrame(fill: 0xFFFF))
        let popup = MK2PopupOverlayElement(
            left: MK2PopupOverlayContent(title: "Left", body: "Body"),
            right: MK2PopupOverlayContent(title: "Right", body: "Body"),
            dimsBackground: false
        )

        let scene = popup.applying(to: base)

        #expect(scene.displays[0]?[0, 0] == 0xFFFF)
        #expect(scene.displays[1] == nil)
    }

    @Test("Popup can target only the left, only the right, or both displays", arguments: [
        (MK2PopupOverlayDisplayMode.left, true, false),
        (MK2PopupOverlayDisplayMode.right, false, true),
        (MK2PopupOverlayDisplayMode.both, true, true),
    ])
    func supportsDisplayModes(
        mode: MK2PopupOverlayDisplayMode,
        changesLeft: Bool,
        changesRight: Bool
    ) {
        let content = MK2PopupOverlayContent(title: "Popup", body: "Body")
        let popup = MK2PopupOverlayElement(
            left: mode == .right ? nil : content,
            right: mode == .left ? nil : content
        )
        let base = MK2SurfaceScene2(
            left: MK2PixelFrame(fill: 0xFFFF),
            right: MK2PixelFrame(fill: 0xFFFF)
        )

        let scene = popup.applying(to: base)

        #expect(popup.displayMode == mode)
        #expect(scene.displays[0]?[0, 0] == (changesLeft ? 0x7BEF : 0xFFFF))
        #expect(scene.displays[1]?[0, 0] == (changesRight ? 0x7BEF : 0xFFFF))
    }
}

private final class PopupOverlayBox: @unchecked Sendable {
    var presses = 0
}
