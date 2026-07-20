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

    @Test("Held command lamps override matching realtime overlays")
    func heldCommandLampsOverrideRealtimeOverlay() async {
        let actions = [MK2HoldAction("NEW")]
        let layer = MK2HoldCommandBarElement(
            trigger: .scene,
            title: "Pattern Commands",
            actions: actions,
            onSelect: { _ in }
        ).build(baseLeft: nil, baseRight: nil)
        let surface = MK2Surface2()
        await surface.present(MK2SurfaceScene2(heldButtonLayers: [layer]))
        await surface.presentLampOverlay([.function1: .red, .function2: .green])

        var lamps = await surface.activeLampsForTesting()
        #expect(lamps[.function1] == .red)
        #expect(lamps[.function2] == .green)

        await surface.handleForTesting([.button(led: .scene, pressed: true)])
        lamps = await surface.activeLampsForTesting()
        #expect(lamps[.function1] == .on(
            KKRGB(red: 0xff, green: 0xff, blue: 0xff),
            intensity: 0x01
        ))
        #expect(lamps[.function2] == .off)
    }

    @Test("A layer introduced by a mode switch waits for the next button press")
    func newlyIntroducedLayerDoesNotOpenForExistingHold() async {
        let surface = MK2Surface2()
        await surface.present(MK2SurfaceScene2(left: MK2PixelFrame(fill: 0x1111)))

        await surface.handleForTesting([.button(led: .scene, pressed: true)])
        await surface.present(MK2SurfaceScene2(
            left: MK2PixelFrame(fill: 0x2222),
            heldButtonLayers: [MK2SurfaceScene2.HeldButtonLayer(
                trigger: .scene,
                left: MK2PixelFrame(fill: 0xAAAA)
            )]
        ))

        var displays = await surface.activeDisplaysForTesting()
        var lamps = await surface.activeLampsForTesting()
        #expect(displays[0]?[0, 0] == 0x2222)
        #expect(lamps[.scene] == .on(
            KKRGB(red: 0xff, green: 0xff, blue: 0xff),
            intensity: 0x01
        ))

        await surface.handleForTesting([.button(led: .scene, pressed: false)])
        await surface.handleForTesting([.button(led: .scene, pressed: true)])
        displays = await surface.activeDisplaysForTesting()
        lamps = await surface.activeLampsForTesting()
        #expect(displays[0]?[0, 0] == 0xAAAA)
        #expect(lamps[.scene] == .white)
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

    @Test("The command bar dims the preserved scene body and owns all function keys")
    func commandBarPrecomposesOverBaseFrames() {
        let box = HoldOverlayBox()
        var left = MK2PixelFrame(fill: 0x1111)
        var right = MK2PixelFrame(fill: 0x2222)
        left[42, 80] = 0xBCDE
        left[42, 100] = 0xCDEF
        left[42, 200] = 0xABCD
        right[84, 220] = 0xDCBA

        let layer = MK2HoldCommandBarElement(
            trigger: .scene,
            title: "Arrangement Commands",
            actions: [
                MK2HoldAction("NEW", detail: "Blank"),
                MK2HoldAction("DUP", detail: "Independent"),
                MK2HoldAction("REUSE", detail: "Linked"),
                MK2HoldAction("CLEAR", detail: "Erase events", isDestructive: true),
                MK2HoldAction("MOVE-", detail: "Earlier", isEnabled: false),
                MK2HoldAction("MOVE+", detail: "Later"),
                MK2HoldAction(""),
                MK2HoldAction("DEL POS", detail: "Keep pattern", isDestructive: true),
            ],
            onSelect: { box.selections.append($0) }
        ).build(baseLeft: left, baseRight: right)

        let renderedLeft = layer.displays[0]!
        let renderedRight = layer.displays[1]!
        #expect(layer.trigger == .scene)
        #expect(MK2HoldCommandBarElement.height == 90)
        #expect(renderedLeft[42, 80] != 0xBCDE)
        #expect(renderedLeft[42, 100] == (0xCDEF >> 1) & 0x7BEF)
        #expect(renderedLeft[42, 200] == (0xABCD >> 1) & 0x7BEF)
        #expect(renderedRight[84, 220] == (0xDCBA >> 1) & 0x7BEF)
        #expect(renderedLeft[0, 0] != 0x1111)
        #expect(layer.lamps[.function4] == .on(
            KKRGB(red: 0xff, green: 0x48, blue: 0x38),
            intensity: 0x01
        ))
        #expect(layer.lamps[.function5] == .off)
        #expect(layer.lamps[.function7] == .off)

        layer.bindings.buttonDown[.function1]?()
        layer.bindings.buttonDown[.function5]?()
        layer.bindings.buttonDown[.function7]?()
        layer.bindings.buttonDown[.function8]?()
        #expect(box.selections == [0, 7])

        let frames = layer.displays.compactMap { $0 }
        let png = PixelSnapshot.pngData(frames: frames)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(png.count > 1_000)
    }
}

private final class HoldOverlayBox: @unchecked Sendable {
    var basePresses = 0
    var overlayPresses = 0
    var baseReleases = 0
    var overlayReleases = 0
    var selections: [Int] = []
}
