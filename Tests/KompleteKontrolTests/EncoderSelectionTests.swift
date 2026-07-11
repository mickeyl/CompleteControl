import Foundation
import KompleteKontrol
import Testing
@testable import KontrolSurfaceKit2

@Suite("Encoder touch selection")
struct EncoderSelectionTests {
    private static let slotRect = MK2PixelRect(x: 8, y: 215, width: 464, height: 57)

    private static func parameterPage(
        selection: MK2EncoderSelectionBehavior = .momentary,
        isFocused: Bool = false,
        encoder: Int = 5
    ) -> MK2ScreenBuildResult {
        MK2FullScreenDSL {
            MK2ParameterPageElement(
                slots: [
                    MK2ParameterPageSlot(
                        label: "LEVEL",
                        value: "80 %",
                        isFocused: isFocused,
                        encoderValue: MK2EncoderDiscreteValue(encoder: encoder, value: 80, bounds: 0...100) { _ in },
                        selection: selection
                    ),
                ],
                rect: slotRect,
                relativeToContent: false
            )
        }.build()
    }

    @Test("Encoder-bound slots capture a touch overlay by default")
    func slotCapturesOverlay() {
        let result = Self.parameterPage()

        let overlay = result.touchOverlays[5]
        #expect(overlay != nil)
        #expect(overlay?.behavior == .momentary)
        #expect(overlay?.rect.isEmpty == false)
        #expect(overlay?.pixels.count == (overlay?.rect.width ?? 0) * (overlay?.rect.height ?? 0))
        // The overlay is the focused appearance, so it must differ from the
        // unfocused pixels the base frame shows in the same rect.
        if let overlay {
            #expect(overlay.pixels != result.screen.frame.pixels(in: overlay.rect))
        }
    }

    @Test("Focused and opted-out slots capture no overlay")
    func focusedAndOptedOutSlotsCaptureNothing() {
        #expect(Self.parameterPage(isFocused: true).touchOverlays.isEmpty)
        #expect(Self.parameterPage(selection: .none).touchOverlays.isEmpty)
    }

    @Test("Slots with separately bound encoders declare their selection encoder")
    func selectionEncoderWithoutEncoderValue() {
        let result = MK2FullScreenDSL {
            MK2ParameterPageElement(
                slots: [
                    MK2ParameterPageSlot(label: "START", value: "420", selectionEncoder: 7),
                    MK2ParameterPageSlot(label: "", value: ""),
                ],
                rect: Self.slotRect,
                relativeToContent: false
            )
        }.build()

        #expect(result.touchOverlays.count == 1)
        #expect(result.touchOverlays[7] != nil)
    }

    @Test("Scene assembly assigns the display index to each overlay")
    func sceneAssignsScreenIndex() {
        let scene = MK2DoubleScreenDSL(
            left: Self.parameterPage(encoder: 1),
            right: Self.parameterPage(encoder: 5)
        ).scene()

        #expect(scene.encoderTouchOverlays[1]?.screen == 0)
        #expect(scene.encoderTouchOverlays[5]?.screen == 1)
    }

    @Test("Momentary selection highlights while touched and restores on release")
    func momentaryHighlight() async {
        let scene = MK2DoubleScreenDSL(
            left: MK2FullScreenDSL {}.build(),
            right: Self.parameterPage()
        ).scene()
        let surface = MK2Surface2()
        await surface.present(scene)
        let overlay = scene.encoderTouchOverlays[5]!
        let basePixels = scene.displays[1]!.pixels(in: overlay.rect)

        await surface.handleForTesting([.touchEncoder(index: 5, touched: true)])
        var displays = await surface.activeDisplaysForTesting()
        #expect(displays[1]?.pixels(in: overlay.rect) == overlay.pixels)

        await surface.handleForTesting([.touchEncoder(index: 5, touched: false)])
        displays = await surface.activeDisplaysForTesting()
        #expect(displays[1]?.pixels(in: overlay.rect) == basePixels)
    }

    @Test("Latched selection survives release and moves to the next latched touch")
    func latchedSelection() async {
        let scene = MK2DoubleScreenDSL(
            left: Self.parameterPage(selection: .latched, encoder: 1),
            right: Self.parameterPage(selection: .latched, encoder: 5)
        ).scene()
        let surface = MK2Surface2()
        await surface.present(scene)
        let first = scene.encoderTouchOverlays[1]!
        let second = scene.encoderTouchOverlays[5]!
        let firstBase = scene.displays[0]!.pixels(in: first.rect)

        await surface.handleForTesting([.touchEncoder(index: 1, touched: true)])
        await surface.handleForTesting([.touchEncoder(index: 1, touched: false)])
        var displays = await surface.activeDisplaysForTesting()
        #expect(displays[0]?.pixels(in: first.rect) == first.pixels)

        await surface.handleForTesting([.touchEncoder(index: 5, touched: true)])
        await surface.handleForTesting([.touchEncoder(index: 5, touched: false)])
        displays = await surface.activeDisplaysForTesting()
        #expect(displays[0]?.pixels(in: first.rect) == firstBase)
        #expect(displays[1]?.pixels(in: second.rect) == second.pixels)
    }

    @Test("Touch overlays are suppressed while the shift layer is held")
    func shiftSuppressesOverlays() async {
        let right = MK2FullScreenDSL {
            MK2ParameterPageElement(
                slots: [
                    MK2ParameterPageSlot(
                        label: "LEVEL",
                        value: "80 %",
                        encoderValue: MK2EncoderDiscreteValue(encoder: 5, value: 80, bounds: 0...100) { _ in }
                    ),
                ],
                shiftSlots: [
                    MK2ParameterPageSlot(label: "FINE", value: "+0 CT"),
                ],
                rect: Self.slotRect,
                relativeToContent: false
            )
        }.build()
        let scene = MK2DoubleScreenDSL(
            left: MK2FullScreenDSL {}.build(),
            right: right
        ).scene()
        #expect(scene.shift != nil)
        let surface = MK2Surface2()
        await surface.present(scene)
        let overlay = scene.encoderTouchOverlays[5]!

        await surface.handleForTesting([.button(led: .shift, pressed: true)])
        await surface.handleForTesting([.touchEncoder(index: 5, touched: true)])
        let displays = await surface.activeDisplaysForTesting()
        #expect(displays[1]?.pixels(in: overlay.rect) != overlay.pixels)
        await surface.handleForTesting([.button(led: .shift, pressed: false)])
    }
}
