import Testing
@testable import KompleteKontrol
@testable import KontrolSurfaceKit2

@Suite("Function key bar")
struct FunctionKeyBarTests {
    private func build(_ bar: MK2FunctionKeyBarElement) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(background: 0x0000) { bar }.build(renderer: nil)
    }

    @Test("slots draw on the encoder grid, top-flush")
    func slotsDrawOnEncoderGrid() {
        let result = build(MK2FunctionKeyBarElement(
            slots: [MK2FunctionKeySlot("AAA"), MK2FunctionKeySlot(""), MK2FunctionKeySlot("BBB"), MK2FunctionKeySlot("CCC")],
            side: .right
        ))
        let frame = result.screen.frame
        let barRect = MK2PixelRect(x: 0, y: 0, width: MK2PixelFrame.width, height: MK2FunctionKeyBarElement.barHeight)
        #expect(frame.countPixels(in: barRect, notMatching: 0x0000) > 0)
        // Slot 1 is empty: nothing but the band fill inside its cell.
        let emptySlot = MK2PixelRect(
            x: MK2ScreenLayout.encoderSlotXs[1],
            y: 0,
            width: MK2ScreenLayout.encoderSlotWidth,
            height: MK2FunctionKeyBarElement.barHeight - 1
        )
        #expect(frame.countPixels(in: emptySlot, notMatching: MK2HIG.Chrome.headerFill) == 0)
        let labeledSlot = MK2PixelRect(
            x: MK2ScreenLayout.encoderSlotXs[3],
            y: 0,
            width: MK2ScreenLayout.encoderSlotWidth,
            height: MK2FunctionKeyBarElement.barHeight - 1
        )
        #expect(frame.countPixels(in: labeledSlot, notMatching: MK2HIG.Chrome.headerFill) > 0)
    }

    @Test("only enabled labeled slots bind their physical button")
    func bindingsFollowEnableState() {
        let result = build(MK2FunctionKeyBarElement(
            slots: [
                MK2FunctionKeySlot("A"),
                MK2FunctionKeySlot(""),
                MK2FunctionKeySlot("C", isEnabled: false),
                MK2FunctionKeySlot("D"),
            ],
            side: .right,
            onPress: { _ in }
        ))
        #expect(result.bindings.buttonDown[.function5] != nil)
        #expect(result.bindings.buttonDown[.function6] == nil)
        #expect(result.bindings.buttonDown[.function7] == nil)
        #expect(result.bindings.buttonDown[.function8] != nil)
    }

    @Test("left side binds F1–F4")
    func leftSideBindsLowBank() {
        let result = build(MK2FunctionKeyBarElement(
            slots: [MK2FunctionKeySlot("A")],
            side: .left,
            onPress: { _ in }
        ))
        #expect(result.bindings.buttonDown[.function1] != nil)
        #expect(result.bindings.buttonDown[.function5] == nil)
    }
}

private extension MK2PixelFrame {
    func countPixels(in rect: MK2PixelRect, notMatching color: UInt16) -> Int {
        guard let clipped = rect.clipped(to: MK2PixelFrame.bounds) else { return 0 }
        var count = 0
        for y in clipped.y..<clipped.maxY {
            for x in clipped.x..<clipped.maxX where self[x, y] != color {
                count += 1
            }
        }
        return count
    }
}
