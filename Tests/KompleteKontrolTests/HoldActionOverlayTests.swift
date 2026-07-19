import KompleteKontrol
import Testing
@testable import KontrolSurfaceKit2

@Suite("Held-button surface layers")
struct HeldButtonLayerTests {
    @Test("A custom trigger swaps both displays and dispatches its bindings while held")
    func customTriggerActivatesLayer() async {
        let box = HoldOverlayBox()
        var baseBindings = MK2InputBindings2()
        baseBindings.onPress(.function1) { box.basePresses += 1 }
        var overlayBindings = MK2InputBindings2()
        overlayBindings.onPress(.function1) { box.overlayPresses += 1 }

        let surface = MK2Surface2()
        await surface.present(MK2SurfaceScene2(
            left: MK2PixelFrame(fill: 0x1111),
            right: MK2PixelFrame(fill: 0x2222),
            bindings: baseBindings,
            heldButtonLayers: [MK2SurfaceScene2.HeldButtonLayer(
                trigger: .keyboard,
                left: MK2PixelFrame(fill: 0xAAAA),
                right: MK2PixelFrame(fill: 0xBBBB),
                bindings: overlayBindings
            )]
        ))

        var lamps = await surface.activeLampsForTesting()
        #expect(lamps[.keyboard] == .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01))

        await surface.handleForTesting([.button(led: .function1, pressed: true)])
        await surface.handleForTesting([.button(led: .function1, pressed: false)])
        #expect(box.basePresses == 1)

        await surface.handleForTesting([.button(led: .keyboard, pressed: true)])
        let displays = await surface.activeDisplaysForTesting()
        lamps = await surface.activeLampsForTesting()
        #expect(displays[0]?[0, 0] == 0xAAAA)
        #expect(displays[1]?[0, 0] == 0xBBBB)
        #expect(lamps[.keyboard] == .white)

        await surface.handleForTesting([.button(led: .function1, pressed: true)])
        await surface.handleForTesting([.button(led: .function1, pressed: false)])
        #expect(box.basePresses == 1)
        #expect(box.overlayPresses == 1)

        await surface.handleForTesting([.button(led: .keyboard, pressed: false)])
        let restored = await surface.activeDisplaysForTesting()
        #expect(restored[0]?[0, 0] == 0x1111)
        #expect(restored[1]?[0, 0] == 0x2222)
    }

    @Test("Release stays with the held layer captured at button down")
    func releaseOwnershipSurvivesTriggerRelease() async {
        let box = HoldOverlayBox()
        var base = MK2InputBindings2()
        base.onRelease(.function1) { box.baseReleases += 1 }
        var overlay = MK2InputBindings2()
        overlay.onRelease(.function1) { box.overlayReleases += 1 }

        let surface = MK2Surface2()
        await surface.present(MK2SurfaceScene2(
            bindings: base,
            heldButtonLayers: [MK2SurfaceScene2.HeldButtonLayer(
                trigger: .keyboard,
                bindings: overlay
            )]
        ))

        await surface.handleForTesting([.button(led: .keyboard, pressed: true)])
        await surface.handleForTesting([.button(led: .function1, pressed: true)])
        await surface.handleForTesting([.button(led: .keyboard, pressed: false)])
        await surface.handleForTesting([.button(led: .function1, pressed: false)])

        #expect(box.overlayReleases == 1)
        #expect(box.baseReleases == 0)
    }

    @Test("A specific held layer takes precedence over Shift and restores Shift on release")
    func customLayerNestsOverShift() async {
        let surface = MK2Surface2()
        await surface.present(MK2SurfaceScene2(
            left: MK2PixelFrame(fill: 0x1111),
            shift: MK2SurfaceScene2.ShiftLayer(left: MK2PixelFrame(fill: 0x2222)),
            heldButtonLayers: [MK2SurfaceScene2.HeldButtonLayer(
                trigger: .keyboard,
                left: MK2PixelFrame(fill: 0x3333)
            )]
        ))

        await surface.handleForTesting([.button(led: .shift, pressed: true)])
        var displays = await surface.activeDisplaysForTesting()
        #expect(displays[0]?[0, 0] == 0x2222)

        await surface.handleForTesting([.button(led: .keyboard, pressed: true)])
        displays = await surface.activeDisplaysForTesting()
        #expect(displays[0]?[0, 0] == 0x3333)

        await surface.handleForTesting([.button(led: .keyboard, pressed: false)])
        displays = await surface.activeDisplaysForTesting()
        #expect(displays[0]?[0, 0] == 0x2222)
        await surface.handleForTesting([.button(led: .shift, pressed: false)])
    }
}

@Suite("Hold action overlay DSL")
struct HoldActionOverlayElementTests {
    @Test("The picker owns F1-F8, highlights its selection, and renders two snapshots")
    func buildsCompletePickerLayer() {
        let box = HoldOverlayBox()
        let actions = (0...7).map { octave in
            MK2HoldAction(
                "OCT \(octave)",
                value: "C\(octave)",
                detail: "Pads C\(octave)-D#\(octave + 1)",
                isEnabled: octave != 6
            )
        }
        let layer = MK2HoldActionOverlayElement(
            trigger: .keyboard,
            title: "Root Octave",
            helpText: "Choose a common note-input octave.",
            actions: actions,
            selectedIndex: 2,
            onSelect: { box.selections.append($0) }
        ).build()

        #expect(layer.trigger == .keyboard)
        #expect(layer.displays.count == 2)
        #expect(layer.displays[0] != nil)
        #expect(layer.displays[1] != nil)
        #expect(layer.lamps[.function3] == .white)
        #expect(layer.lamps[.function1] == .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01))
        #expect(layer.lamps[.function7] == .off)

        layer.bindings.buttonDown[.function1]?()
        layer.bindings.buttonDown[.function7]?()
        layer.bindings.buttonDown[.function8]?()
        #expect(box.selections == [0, 7])

        let frames = layer.displays.compactMap { $0 }
        #expect(frames.count == 2)
        let png = PixelSnapshot.pngData(frames: frames)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(png.count > 1_000)
    }

    @Test("Double-screen DSL carries action overlays into the scene")
    func doubleScreenCarriesLayer() {
        let layer = MK2HoldActionOverlayElement(
            trigger: .keyboard,
            title: "Root",
            actions: [MK2HoldAction("OCT 2")],
            selectedIndex: 0,
            onSelect: { _ in }
        ).build()
        let plain = MK2FullScreenDSL {}.build()
        let scene = MK2DoubleScreenDSL(
            left: plain,
            right: plain,
            heldButtonLayers: [layer]
        ).scene()

        #expect(scene.heldButtonLayers.count == 1)
        #expect(scene.heldButtonLayers[0].trigger == .keyboard)
        #expect(scene.shift == nil)
    }
}

private final class HoldOverlayBox: @unchecked Sendable {
    var basePresses = 0
    var overlayPresses = 0
    var baseReleases = 0
    var overlayReleases = 0
    var selections: [Int] = []
}
