import Foundation
import KompleteKontrol
import Testing
@testable import KontrolSurfaceKit2

@Suite("Touch overlay composite cache")
struct TouchOverlayCompositeCacheTests {
    private static let slotRect = MK2PixelRect(x: 8, y: 215, width: 464, height: 57)

    /// CoW buffer identity — the same notion of "unchanged" the reconciler uses.
    private static func sharesBuffer(_ a: [UInt16]?, _ b: [UInt16]?) -> Bool {
        switch (a, b) {
            case (nil, nil):
                true
            case let (a?, b?):
                a.withUnsafeBufferPointer { lhs in
                    b.withUnsafeBufferPointer { rhs in
                        lhs.baseAddress == rhs.baseAddress && lhs.count == rhs.count
                    }
                }
            default:
                false
        }
    }

    private static func scene(
        selection: MK2EncoderSelectionBehavior = .latched,
        encoders: [Int] = [5],
        value: String = "80 %"
    ) -> MK2SurfaceScene2 {
        let slots = encoders.enumerated().map { index, encoder in
            MK2ParameterPageSlot(
                label: "LEVEL \(index + 1)",
                value: value,
                encoderValue: MK2EncoderDiscreteValue(encoder: encoder, value: 80, bounds: 0...100) { _ in },
                selection: selection
            )
        }
        return MK2DoubleScreenDSL(
            left: MK2FullScreenDSL {}.build(),
            right: MK2FullScreenDSL {
                MK2ParameterPageElement(slots: slots, rect: slotRect, relativeToContent: false)
            }.build()
        ).scene()
    }

    private static func latched(surface: MK2Surface2, _ encoder: Int) async {
        await surface.handleForTesting([.touchEncoder(index: encoder, touched: true)])
        await surface.handleForTesting([.touchEncoder(index: encoder, touched: false)])
    }

    @Test("A latched overlay composites once and later ticks reuse the buffer")
    func latchedOverlayTicksReuseComposite() async {
        let scene = Self.scene(encoders: [5])
        let surface = MK2Surface2()
        await surface.present(scene)
        await Self.latched(surface: surface, 5)
        let overlay = scene.encoderTouchOverlays[5]!

        let displays = await surface.activeDisplaysForTesting()
        #expect(displays[1]?.pixels(in: overlay.rect) == overlay.pixels)
        for _ in 0..<30 {
            let tickDisplays = await surface.activeDisplaysForTesting()
            #expect(Self.sharesBuffer(displays[0]?.pixels, tickDisplays[0]?.pixels))
            #expect(Self.sharesBuffer(displays[1]?.pixels, tickDisplays[1]?.pixels))
        }

        var reconciler = PixelDisplayReconciler2()
        _ = reconciler.reconcile(frames: displays)
        #expect(reconciler.reconcile(frames: displays).isEmpty)
    }

    @Test("A scene change while latched recomposites")
    func sceneChangeWhileLatchedRecomposites() async {
        let surface = MK2Surface2()
        await surface.present(Self.scene(encoders: [5]))
        await Self.latched(surface: surface, 5)
        let before = await surface.activeDisplaysForTesting()

        let second = Self.scene(encoders: [5], value: "42 %")
        await surface.present(second)
        let after = await surface.activeDisplaysForTesting()

        #expect(!Self.sharesBuffer(before[1]?.pixels, after[1]?.pixels))
        let overlay = second.encoderTouchOverlays[5]!
        #expect(after[1]?.pixels(in: overlay.rect) == overlay.pixels)
    }

    @Test("Releasing a momentary overlay returns the base buffer without a copy")
    func momentaryReleaseReturnsBaseBuffer() async {
        let scene = Self.scene(selection: .momentary, encoders: [5])
        let surface = MK2Surface2()
        await surface.present(scene)
        let overlay = scene.encoderTouchOverlays[5]!
        let base = scene.displays[1]?.pixels

        await surface.handleForTesting([.touchEncoder(index: 5, touched: true)])
        let touched = await surface.activeDisplaysForTesting()
        #expect(touched[1]?.pixels(in: overlay.rect) == overlay.pixels)
        #expect(!Self.sharesBuffer(base, touched[1]?.pixels))

        await surface.handleForTesting([.touchEncoder(index: 5, touched: false)])
        let released = await surface.activeDisplaysForTesting()
        #expect(Self.sharesBuffer(base, released[1]?.pixels))
        #expect(released[1]?.pixels(in: overlay.rect) == scene.displays[1]?.pixels(in: overlay.rect))
    }

    @Test("Swapping overlay content over identical base buffers recomposites")
    func overlayContentSwapOverIdenticalBaseRecomposites() async {
        let scene = Self.scene(encoders: [5])
        let surface = MK2Surface2()
        await surface.present(scene)
        await Self.latched(surface: surface, 5)
        let original = scene.encoderTouchOverlays[5]!
        let before = await surface.activeDisplaysForTesting()
        #expect(before[1]?.pixels(in: original.rect) == original.pixels)

        var next = scene
        next.encoderTouchOverlays[5] = MK2EncoderTouchOverlay(
            screen: original.screen,
            rect: original.rect,
            pixels: [UInt16](repeating: 0x1234, count: original.pixels.count),
            behavior: .latched
        )
        await surface.present(next)
        let after = await surface.activeDisplaysForTesting()

        #expect(after[1]?.pixels(in: original.rect) == next.encoderTouchOverlays[5]!.pixels)
        #expect(after[1]?.pixels(in: original.rect) != original.pixels)
    }

    @Test("Shift hold suppresses overlays and release restores the cached composite")
    func shiftHoldReleaseRestoresCachedComposite() async {
        let right = MK2FullScreenDSL {
            MK2ParameterPageElement(
                slots: [
                    MK2ParameterPageSlot(
                        label: "LEVEL",
                        value: "80 %",
                        encoderValue: MK2EncoderDiscreteValue(encoder: 5, value: 80, bounds: 0...100) { _ in },
                        selection: .latched
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
        await Self.latched(surface: surface, 5)
        let overlay = scene.encoderTouchOverlays[5]!

        let composite = await surface.activeDisplaysForTesting()
        #expect(composite[1]?.pixels(in: overlay.rect) == overlay.pixels)

        await surface.handleForTesting([.button(led: .shift, pressed: true)])
        let shifted = await surface.activeDisplaysForTesting()
        #expect(shifted[1]?.pixels(in: overlay.rect) != overlay.pixels)

        await surface.handleForTesting([.button(led: .shift, pressed: false)])
        let restored = await surface.activeDisplaysForTesting()
        #expect(restored[1]?.pixels(in: overlay.rect) == overlay.pixels)
        #expect(Self.sharesBuffer(composite[1]?.pixels, restored[1]?.pixels))
    }

    @Test("Two simultaneously touched encoders composite both overlays")
    func simultaneousMomentaryOverlaysComposite() async {
        let scene = Self.scene(selection: .momentary, encoders: [5, 6])
        let surface = MK2Surface2()
        await surface.present(scene)
        await surface.handleForTesting([
            .touchEncoder(index: 5, touched: true),
            .touchEncoder(index: 6, touched: true),
        ])
        let displays = await surface.activeDisplaysForTesting()
        let first = scene.encoderTouchOverlays[5]!
        let second = scene.encoderTouchOverlays[6]!
        #expect(displays[1]?.pixels(in: first.rect) == first.pixels)
        #expect(displays[1]?.pixels(in: second.rect) == second.pixels)
    }
}
