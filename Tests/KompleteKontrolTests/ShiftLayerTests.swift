import Foundation
import KompleteKontrol
import Testing
@testable import KontrolSurfaceKit2

@Suite("MK2 surface shift layer")
struct ShiftLayerTests {
    @Test("Shift layer bindings dispatch while held and fall back to base")
    func layerBindingsDispatchWhileHeld() async {
        let box = ShiftLayerBox()
        var base = MK2InputBindings2()
        base.onPress(.function5) { box.basePresses += 1 }
        base.encoder[2] = { delta, _, _ in box.baseEncoderDelta += delta }
        var layer = MK2InputBindings2()
        layer.onPress(.function5) { box.shiftPresses += 1 }

        let surface = MK2Surface2()
        await surface.present(MK2SurfaceScene2(
            bindings: base,
            shift: MK2SurfaceScene2.ShiftLayer(bindings: layer)
        ))

        await surface.handleForTesting([.button(led: .function5, pressed: true)])
        await surface.handleForTesting([.button(led: .function5, pressed: false)])
        #expect(box.basePresses == 1)
        #expect(box.shiftPresses == 0)

        await surface.handleForTesting([.button(led: .shift, pressed: true)])
        await surface.handleForTesting([.button(led: .function5, pressed: true)])
        await surface.handleForTesting([.button(led: .function5, pressed: false)])
        #expect(box.basePresses == 1)
        #expect(box.shiftPresses == 1)

        // The layer leaves encoder 2 unbound: the base handler keeps working under shift.
        await surface.handleForTesting([.knob(index: 2, delta: 3, value: 0)])
        #expect(box.baseEncoderDelta == 3)
        await surface.handleForTesting([.button(led: .shift, pressed: false)])
    }

    @Test("Shift layer encoder bindings replace base handlers while held")
    func layerEncoderBindingsReplaceBase() async {
        let box = ShiftLayerBox()
        var base = MK2InputBindings2()
        base.encoder[1] = { delta, _, _ in box.baseEncoderDelta += delta }
        base.jogScroll = { delta, _ in box.baseJogDelta += delta }
        var layer = MK2InputBindings2()
        layer.encoder[1] = { delta, _, _ in box.shiftEncoderDelta += delta }

        let surface = MK2Surface2()
        await surface.present(MK2SurfaceScene2(
            bindings: base,
            shift: MK2SurfaceScene2.ShiftLayer(bindings: layer)
        ))

        await surface.handleForTesting([.knob(index: 1, delta: 2, value: 0)])
        #expect(box.baseEncoderDelta == 2)
        #expect(box.shiftEncoderDelta == 0)

        await surface.handleForTesting([.button(led: .shift, pressed: true)])
        await surface.handleForTesting([.knob(index: 1, delta: 5, value: 0)])
        await surface.handleForTesting([.jogScroll(delta: 1, value: 0)])
        #expect(box.baseEncoderDelta == 2)
        #expect(box.shiftEncoderDelta == 5)
        #expect(box.baseJogDelta == 1)

        await surface.handleForTesting([.button(led: .shift, pressed: false)])
        await surface.handleForTesting([.knob(index: 1, delta: 1, value: 0)])
        #expect(box.baseEncoderDelta == 3)
        #expect(box.shiftEncoderDelta == 5)
    }

    @Test("Release pairs with the layer captured at press time")
    func releasePairsWithPressTimeLayer() async {
        let box = ShiftLayerBox()
        var base = MK2InputBindings2()
        base.onRelease(.function5) { box.baseReleases += 1 }
        var layer = MK2InputBindings2()
        layer.onRelease(.function5) { box.shiftReleases += 1 }

        let surface = MK2Surface2()
        await surface.present(MK2SurfaceScene2(
            bindings: base,
            shift: MK2SurfaceScene2.ShiftLayer(bindings: layer)
        ))

        // Press under shift, shift goes up first: the release must stay a layer release.
        await surface.handleForTesting([.button(led: .shift, pressed: true)])
        await surface.handleForTesting([.button(led: .function5, pressed: true)])
        await surface.handleForTesting([.button(led: .shift, pressed: false)])
        await surface.handleForTesting([.button(led: .function5, pressed: false)])
        #expect(box.shiftReleases == 1)
        #expect(box.baseReleases == 0)

        // Press unmodified, shift goes down before release: still a base release.
        await surface.handleForTesting([.button(led: .function5, pressed: true)])
        await surface.handleForTesting([.button(led: .shift, pressed: true)])
        await surface.handleForTesting([.button(led: .function5, pressed: false)])
        await surface.handleForTesting([.button(led: .shift, pressed: false)])
        #expect(box.shiftReleases == 1)
        #expect(box.baseReleases == 1)
    }

    @Test("ModifierRequirement bindings keep working alongside a shift layer")
    func modifierRequirementFallbackSurvivesLayer() async {
        let box = ShiftLayerBox()
        var base = MK2InputBindings2()
        base.onPress(.clear, modifiers: .unmodified) { box.basePresses += 1 }
        base.onPress(.clear, modifiers: .shift) { box.shiftPresses += 1 }

        let surface = MK2Surface2()
        await surface.present(MK2SurfaceScene2(
            bindings: base,
            shift: MK2SurfaceScene2.ShiftLayer(bindings: MK2InputBindings2())
        ))

        await surface.handleForTesting([.button(led: .clear, pressed: true)])
        await surface.handleForTesting([.button(led: .clear, pressed: false)])
        await surface.handleForTesting([.button(led: .shift, pressed: true)])
        await surface.handleForTesting([.button(led: .clear, pressed: true)])
        await surface.handleForTesting([.button(led: .clear, pressed: false)])
        await surface.handleForTesting([.button(led: .shift, pressed: false)])
        #expect(box.basePresses == 1)
        #expect(box.shiftPresses == 1)
    }

    @Test("Displays swap to layer frames while shift is held")
    func displaysSwapWhileHeld() async {
        let baseLeft = MK2PixelFrame(fill: 0x1111)
        let baseRight = MK2PixelFrame(fill: 0x2222)
        let shiftRight = MK2PixelFrame(fill: 0x3333)

        let surface = MK2Surface2()
        await surface.present(MK2SurfaceScene2(
            left: baseLeft,
            right: baseRight,
            shift: MK2SurfaceScene2.ShiftLayer(right: shiftRight)
        ))

        var displays = await surface.activeDisplaysForTesting()
        #expect(displays[0]?[0, 0] == 0x1111)
        #expect(displays[1]?[0, 0] == 0x2222)

        await surface.handleForTesting([.button(led: .shift, pressed: true)])
        displays = await surface.activeDisplaysForTesting()
        #expect(displays[0]?[0, 0] == 0x1111)
        #expect(displays[1]?[0, 0] == 0x3333)

        await surface.handleForTesting([.button(led: .shift, pressed: false)])
        displays = await surface.activeDisplaysForTesting()
        #expect(displays[1]?[0, 0] == 0x2222)
    }

    @Test("Scene presented while shift is held activates the new layer immediately")
    func presentWhileHeldUsesNewLayer() async {
        let surface = MK2Surface2()
        await surface.present(MK2SurfaceScene2(
            left: MK2PixelFrame(fill: 0x1111),
            shift: MK2SurfaceScene2.ShiftLayer(left: MK2PixelFrame(fill: 0x2222))
        ))
        await surface.handleForTesting([.button(led: .shift, pressed: true)])

        await surface.present(MK2SurfaceScene2(
            left: MK2PixelFrame(fill: 0x4444),
            shift: MK2SurfaceScene2.ShiftLayer(left: MK2PixelFrame(fill: 0x5555))
        ))
        let displays = await surface.activeDisplaysForTesting()
        #expect(displays[0]?[0, 0] == 0x5555)
        await surface.handleForTesting([.button(led: .shift, pressed: false)])
    }

    @Test("Automatic shift lamp advertises and confirms the layer")
    func automaticShiftLamp() async {
        let surface = MK2Surface2()

        await surface.present(MK2SurfaceScene2())
        var lamps = await surface.activeLampsForTesting()
        #expect(lamps[.shift] == nil)

        await surface.present(MK2SurfaceScene2(shift: MK2SurfaceScene2.ShiftLayer()))
        lamps = await surface.activeLampsForTesting()
        #expect(lamps[.shift] == .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01))

        await surface.handleForTesting([.button(led: .shift, pressed: true)])
        lamps = await surface.activeLampsForTesting()
        #expect(lamps[.shift] == .white)
        await surface.handleForTesting([.button(led: .shift, pressed: false)])

        // An explicit lamp anywhere disables the automatic one.
        await surface.present(MK2SurfaceScene2(
            lamps: [.shift: .amber],
            shift: MK2SurfaceScene2.ShiftLayer()
        ))
        lamps = await surface.activeLampsForTesting()
        #expect(lamps[.shift] == .amber)
    }

    @Test("Layer lamps and key colors merge over the base while held")
    func layerLampsAndKeyColorsMerge() async {
        let red = KKRGB(red: 0xff, green: 0x00, blue: 0x00)
        let green = KKRGB(red: 0x00, green: 0xff, blue: 0x00)
        let surface = MK2Surface2()
        await surface.present(MK2SurfaceScene2(
            lamps: [.play: .green, .stop: .red],
            keyColors: [10: red],
            shift: MK2SurfaceScene2.ShiftLayer(
                lamps: [.play: .amber],
                keyColors: [10: green, 11: green]
            )
        ))

        var lamps = await surface.activeLampsForTesting()
        var keys = await surface.activeKeyColorsForTesting()
        #expect(lamps[.play] == .green)
        #expect(keys[10] == red)
        #expect(keys[11] == nil)

        await surface.handleForTesting([.button(led: .shift, pressed: true)])
        lamps = await surface.activeLampsForTesting()
        keys = await surface.activeKeyColorsForTesting()
        #expect(lamps[.play] == .amber)
        #expect(lamps[.stop] == .red)
        #expect(keys[10] == green)
        #expect(keys[11] == green)
        await surface.handleForTesting([.button(led: .shift, pressed: false)])
    }
}

@Suite("MK2 screen DSL shift pass")
struct ShiftPassTests {
    @Test("Screens without shift content build in one pass")
    func noShiftContentSkipsSecondPass() {
        let result = MK2FullScreenDSL {
            MK2ContentText("PLAIN", x: 8, y: 8, relativeToContent: false)
        }.build()

        #expect(!result.wantsShiftPass)
        #expect(result.shiftScreen == nil)

        let scene = MK2DoubleScreenDSL(left: result, right: result).scene()
        #expect(scene.shift == nil)
    }

    @Test("MK2ShiftBranch splits drawing, lamps, and bindings by pass")
    func shiftBranchSplitsByPass() {
        let box = ShiftLayerBox()
        let result = MK2FullScreenDSL(background: 0x0000) {
            MK2ShiftBranch {
                MK2RenderBlock { frame, _ in
                    frame.fill(MK2PixelRect(x: 0, y: 0, width: 4, height: 4), 0xAAAA)
                }
                MK2LampElement(.function5, .amber)
                MK2ButtonBindingElement(.function5) { box.shiftPresses += 1 }
            } otherwise: {
                MK2RenderBlock { frame, _ in
                    frame.fill(MK2PixelRect(x: 0, y: 0, width: 4, height: 4), 0xBBBB)
                }
                MK2ButtonBindingElement(.function5) { box.basePresses += 1 }
            }
        }.build()

        #expect(result.wantsShiftPass)
        #expect(result.screen.frame[0, 0] == 0xBBBB)
        #expect(result.shiftScreen?.frame[0, 0] == 0xAAAA)
        #expect(result.lamps[.function5] == nil)
        #expect(result.shiftLamps[.function5] == .amber)
        #expect(result.bindings.buttonDown[.function5] != nil)
        #expect(result.shiftBindings.buttonDown[.function5] != nil)

        result.bindings.buttonDown[.function5]?()
        result.shiftBindings.buttonDown[.function5]?()
        #expect(box.basePresses == 1)
        #expect(box.shiftPresses == 1)
    }

    @Test("Elements outside a branch render into both passes")
    func unbranchedElementsRenderInBothPasses() {
        let result = MK2FullScreenDSL(background: 0x0000) {
            MK2RenderBlock { frame, _ in
                frame.fill(MK2PixelRect(x: 10, y: 10, width: 2, height: 2), 0xCCCC)
            }
            MK2ShiftBranch {
                MK2RenderBlock { frame, _ in
                    frame.fill(MK2PixelRect(x: 0, y: 0, width: 2, height: 2), 0xAAAA)
                }
            }
        }.build()

        #expect(result.screen.frame[10, 10] == 0xCCCC)
        #expect(result.shiftScreen?.frame[10, 10] == 0xCCCC)
        #expect(result.screen.frame[0, 0] == 0x0000)
        #expect(result.shiftScreen?.frame[0, 0] == 0xAAAA)
    }

    @Test("Regular screens rebuild their chrome in the shift pass")
    func regularScreenShiftPassKeepsChrome() {
        let result = MK2RegularScreenDSL(header: .title(title: "SHIFTY")) {
            MK2ShiftBranch {
                MK2ContentText("ALT", x: 8, y: 8)
            }
        }.build()

        #expect(result.shiftScreen != nil)
        guard let base = result.screen.frame.pixelsEqual(to: result.shiftScreen?.frame) else { return }
        #expect(!base)
    }

    @Test("Double screen DSL merges shift results into the scene layer")
    func doubleScreenMergesShiftLayer() async {
        let box = ShiftLayerBox()
        let plain = MK2FullScreenDSL {
            MK2ContentText("LEFT", x: 8, y: 8, relativeToContent: false)
        }.build()
        let shifty = MK2FullScreenDSL(background: 0x1111) {
            MK2ShiftBranch {
                MK2RenderBlock { frame, _ in
                    frame.fill(MK2PixelRect(x: 0, y: 0, width: 2, height: 2), 0x2222)
                }
                MK2ButtonBindingElement(.function6) { box.shiftPresses += 1 }
            } otherwise: {
                MK2ButtonBindingElement(.function6) { box.basePresses += 1 }
            }
        }.build()

        let scene = MK2DoubleScreenDSL(left: plain, right: shifty).scene()
        #expect(scene.shift != nil)
        #expect(scene.shift?.displays[0] == nil)
        #expect(scene.shift?.displays[1]?[0, 0] == 0x2222)

        let surface = MK2Surface2()
        await surface.present(scene)
        await surface.handleForTesting([.button(led: .function6, pressed: true)])
        await surface.handleForTesting([.button(led: .function6, pressed: false)])
        #expect(box.basePresses == 1)
        #expect(box.shiftPresses == 0)

        await surface.handleForTesting([.button(led: .shift, pressed: true)])
        await surface.handleForTesting([.button(led: .function6, pressed: true)])
        await surface.handleForTesting([.button(led: .function6, pressed: false)])
        #expect(box.basePresses == 1)
        #expect(box.shiftPresses == 1)

        let displays = await surface.activeDisplaysForTesting()
        #expect(displays[1]?[0, 0] == 0x2222)
        await surface.handleForTesting([.button(led: .shift, pressed: false)])
    }
}

@Suite("MK2 shift-aware elements")
struct ShiftAwareElementTests {
    @Test("Function key bar without shift slots stays single-pass")
    func functionKeyBarWithoutShiftSlotsStaysSinglePass() {
        let result = MK2FullScreenDSL {
            MK2FunctionKeyBarElement(
                slots: [MK2FunctionKeySlot("CUT")],
                side: .right,
                onPress: { _ in }
            )
        }.build()
        #expect(!result.wantsShiftPass)
        #expect(result.shiftScreen == nil)
    }

    @Test("Function key bar shift slots draw and bind the shift layer")
    func functionKeyBarShiftSlots() async {
        let box = ShiftLayerBox()
        let result = MK2FullScreenDSL {
            MK2FunctionKeyBarElement(
                slots: [MK2FunctionKeySlot("CUT"), MK2FunctionKeySlot("COPY")],
                shiftSlots: [MK2FunctionKeySlot("TRIM")],
                side: .right,
                onPress: { slot in box.basePresses += slot + 1 },
                onShiftPress: { slot in box.shiftPresses += slot + 1 }
            )
        }.build()

        #expect(result.wantsShiftPass)
        #expect(result.shiftScreen != nil)

        let scene = MK2DoubleScreenDSL(
            left: MK2FullScreenDSL {}.build(),
            right: result
        ).scene()
        let surface = MK2Surface2()
        await surface.present(scene)

        await surface.handleForTesting([.button(led: .function5, pressed: true)])
        await surface.handleForTesting([.button(led: .function5, pressed: false)])
        #expect(box.basePresses == 1)

        await surface.handleForTesting([.button(led: .shift, pressed: true)])
        await surface.handleForTesting([.button(led: .function5, pressed: true)])
        await surface.handleForTesting([.button(led: .function5, pressed: false)])
        #expect(box.shiftPresses == 1)
        #expect(box.basePresses == 1)

        // F6 has a base action (COPY) but an empty shift slot: the press must be
        // swallowed, not fall through to the base action.
        await surface.handleForTesting([.button(led: .function6, pressed: true)])
        await surface.handleForTesting([.button(led: .function6, pressed: false)])
        #expect(box.basePresses == 1)
        #expect(box.shiftPresses == 1)
        await surface.handleForTesting([.button(led: .shift, pressed: false)])
    }

    @Test("Parameter page shift slots swap cells and encoder bindings")
    func parameterPageShiftSlots() async {
        let box = ShiftLayerBox()
        let rect = MK2PixelRect(x: 8, y: 215, width: 464, height: 57)
        let result = MK2FullScreenDSL {
            MK2ParameterPageElement(
                slots: [
                    MK2ParameterPageSlot(
                        label: "TUNE",
                        value: "+0 ST",
                        encoderValue: MK2EncoderDiscreteValue(encoder: 1, value: 0, bounds: -12...12) { _ in
                            box.baseEncoderDelta += 1
                        }
                    ),
                    MK2ParameterPageSlot(
                        label: "VOLUME",
                        value: "80 %",
                        encoderValue: MK2EncoderDiscreteValue(encoder: 2, value: 80, bounds: 0...100) { _ in
                            box.baseJogDelta += 1
                        }
                    ),
                ],
                shiftSlots: [
                    MK2ParameterPageSlot(
                        label: "FINE",
                        value: "+0 CT",
                        encoderValue: MK2EncoderDiscreteValue(encoder: 1, value: 0, bounds: -100...100) { _ in
                            box.shiftEncoderDelta += 1
                        }
                    ),
                    MK2ParameterPageSlot(label: "VOLUME", value: "80 %"),
                ],
                rect: rect,
                relativeToContent: false
            )
        }.build()

        #expect(result.wantsShiftPass)
        #expect(result.shiftScreen != nil)
        #expect(result.screen.frame.pixels != result.shiftScreen?.frame.pixels)

        let scene = MK2DoubleScreenDSL(
            left: MK2FullScreenDSL {}.build(),
            right: result
        ).scene()
        let surface = MK2Surface2()
        await surface.present(scene)

        await surface.handleForTesting([.knob(index: 1, delta: 1, value: 0)])
        #expect(box.baseEncoderDelta == 1)

        await surface.handleForTesting([.button(led: .shift, pressed: true)])
        await surface.handleForTesting([.knob(index: 1, delta: 1, value: 0)])
        #expect(box.baseEncoderDelta == 1)
        #expect(box.shiftEncoderDelta == 1)

        // The VOLUME shift slot brings no encoder value: the base binding stays
        // active under shift.
        await surface.handleForTesting([.knob(index: 2, delta: 1, value: 0)])
        #expect(box.baseJogDelta == 1)
        await surface.handleForTesting([.button(led: .shift, pressed: false)])
    }
}

private extension MK2PixelFrame {
    func pixelsEqual(to other: MK2PixelFrame?) -> Bool? {
        guard let other else { return nil }
        return pixels == other.pixels
    }
}

private final class ShiftLayerBox: @unchecked Sendable {
    var basePresses = 0
    var shiftPresses = 0
    var baseReleases = 0
    var shiftReleases = 0
    var baseEncoderDelta = 0
    var shiftEncoderDelta = 0
    var baseJogDelta = 0
}
