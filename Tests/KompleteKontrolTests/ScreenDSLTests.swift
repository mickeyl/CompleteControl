import Foundation
import KompleteKontrol
import Testing
@testable import KontrolSurfaceKit2

@Suite("MK2 screen DSL")
struct ScreenDSLTests {
    @Test("Regular screen DSL renders chrome, content, lamps and bindings")
    func regularScreenBuildsSceneContract() {
        let box = ScreenDSLBox()
        let renderer = try? FreeTypeTextRenderer()

        let result = MK2RegularScreenDSL(
            header: .title(title: "Browser", subtitle: "4D Select"),
            footer: .hint("Press 4D to open")
        ) {
            MK2ContentText("Piano Noir", x: 8, y: 10, role: .title)
            MK2LampElement(.browser, .white)
            MK2ButtonBindingElement(.browser) {
                box.count += 1
            }
        }.build(renderer: renderer)

        #expect(result.screen.kind == .regular)
        #expect(result.lamps[.browser] == .white)
        #expect(result.screen.frame.countPixels(in: MK2PixelRect(x: 0, y: 0, width: 480, height: 1), matching: MK2HIG.Chrome.headerTopLine) == 480)
        #expect(result.screen.frame.countPixels(in: MK2PixelRect(x: 16, y: 54, width: 140, height: 32), notMatching: MK2HIG.Chrome.background) > 10)

        result.bindings.buttonDown[.browser]?()
        #expect(box.count == 1)
    }

    @Test("Double screen DSL merges both sides into one scene")
    func doubleScreenMergesResults() {
        let left = MK2FullScreenDSL {
            MK2LampElement(.function1, .green)
        }.build()
        let right = MK2FullScreenDSL {
            MK2LampElement(.function2, .red)
            MK2KeyColorElement(12, KKRGB(red: 1, green: 2, blue: 3))
        }.build()

        let scene = MK2DoubleScreenDSL(left: left, right: right).scene()

        #expect(scene.displays[0] != nil)
        #expect(scene.displays[1] != nil)
        #expect(scene.lamps[.function1] == .green)
        #expect(scene.lamps[.function2] == .red)
        #expect(scene.keyColors[12] == KKRGB(red: 1, green: 2, blue: 3))
    }

    @Test("Shift is a first-class button modifier")
    func shiftModifiedButtonPressRoutesSeparately() async {
        let box = ScreenDSLBox()
        let surface = MK2Surface2()
        var bindings = MK2InputBindings2()
        bindings.onPress(.clear, modifiers: .unmodified) {
            box.rowClears += 1
        }
        bindings.onPress(.clear, modifiers: .shift) {
            box.patternClears += 1
        }
        await surface.present(MK2SurfaceScene2(bindings: bindings))

        await surface.handleForTesting([.button(led: .clear, pressed: true)])
        await surface.handleForTesting([.button(led: .clear, pressed: false)])
        #expect(box.rowClears == 1)
        #expect(box.patternClears == 0)

        await surface.handleForTesting([.button(led: .shift, pressed: true)])
        await surface.handleForTesting([.button(led: .clear, pressed: true)])
        await surface.handleForTesting([.button(led: .clear, pressed: false)])
        await surface.handleForTesting([.button(led: .shift, pressed: false)])
        #expect(box.rowClears == 1)
        #expect(box.patternClears == 1)
    }
}

private final class ScreenDSLBox: @unchecked Sendable {
    var count = 0
    var rowClears = 0
    var patternClears = 0
}

private extension MK2PixelFrame {
    func countPixels(in rect: MK2PixelRect, matching color: UInt16) -> Int {
        guard let clipped = rect.clipped(to: MK2PixelFrame.bounds) else { return 0 }
        var count = 0
        for y in clipped.y..<clipped.maxY {
            for x in clipped.x..<clipped.maxX where self[x, y] == color {
                count += 1
            }
        }
        return count
    }

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
