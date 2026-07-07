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

    @Test("Reusable content elements draw through the screen DSL")
    func reusableContentElementsDraw() {
        let renderer = try? FreeTypeTextRenderer()
        let colors = MK2ValueCellColors(
            label: 0xffff,
            value: 0x07e0,
            border: 0x4208,
            fill: 0x1083,
            focusedValue: 0x0000,
            focusedFill: 0xc618,
            focusedBorder: 0xffff
        )

        let result = MK2RegularScreenDSL(
            header: .title(title: "Editor", subtitle: "Values"),
            footer: .encoderArea()
        ) {
            MK2StatusLineElement(items: [
                MK2StatusLineItem("EDIT", x: 8, color: 0xffff),
            ])
            MK2ContentText(
                "A long body line should wrap into a second visible row when the available width is tight.",
                x: 8,
                y: 24,
                maxWidth: 148,
                color: 0xffff,
                maxLines: 2,
                lineSpacing: 2
            )
            MK2ValueCellElement(label: "VOL", value: "40", rect: MK2PixelRect(x: 8, y: 112, width: 80, height: 30), colors: colors)
            MK2ProgressBarElement(rect: MK2PixelRect(x: 108, y: 118, width: 120, height: 14), progress: 0.5)
            MK2EncoderFooterElement([
                MK2EncoderDiscreteValueDisplay(label: "FX", value: "A09", rect: MK2PixelRect(x: 252, y: 218, width: 80, height: 34), colors: colors),
            ])
        }.build(renderer: renderer)

        #expect(result.screen.frame.countPixels(in: MK2PixelRect(x: 16, y: 90, width: 148, height: 44), notMatching: MK2HIG.Chrome.background) > 20)
        #expect(result.screen.frame[16, 164] == colors.border)
        #expect(result.screen.frame.countPixels(in: MK2PixelRect(x: 117, y: 165, width: 60, height: 12), matching: MK2HIG.Chrome.accent) > 10)
        #expect(result.screen.frame.countPixels(in: MK2PixelRect(x: 252, y: 196, width: 90, height: 56), notMatching: MK2HIG.Chrome.background) > 10)
    }

    @Test("Selection elements wrap existing list and grid widgets")
    func selectionElementsDrawExistingWidgets() {
        let items = [
            MK2SelectionItem(title: "Piano Noir", detail: "Felt", badge: "A"),
            MK2SelectionItem(title: "Tape Strings", detail: "Warm", badge: "B"),
        ]

        let list = MK2FullScreenDSL {
            MK2SelectionListElement(title: "Browser List", subtitle: "2 items", items: items, selectedIndex: 0, rowHeight: 44)
        }.build(renderer: try? FreeTypeTextRenderer())
        let grid = MK2FullScreenDSL {
            MK2SelectionGridElement(
                title: "Browser Grid",
                subtitle: "2 items",
                items: items,
                selectedIndex: 1,
                cellSize: MK2SelectionCellSize(width: 120, height: 58)
            )
        }.build(renderer: try? FreeTypeTextRenderer())

        #expect(list.screen.frame.countPixels(in: MK2PixelRect(x: 12, y: 48, width: 456, height: 70), notMatching: MK2HIG.Chrome.background) > 100)
        #expect(grid.screen.frame.countPixels(in: MK2PixelRect(x: 12, y: 48, width: 456, height: 80), notMatching: MK2HIG.Chrome.background) > 100)
    }

    @Test("Selection input owns jog lamps and movement bindings")
    func selectionInputOwnsNavigationBindings() {
        let box = ScreenDSLBox()
        let result = MK2FullScreenDSL {
            MK2SelectionInputElement(
                navigation: MK2SelectionNavigation(selectedIndex: 0),
                itemCount: 8,
                layout: .grid(cellSize: MK2SelectionCellSize(width: 110, height: 58)),
                onMove: { delta in
                    box.lastDelta = delta
                    box.count += 1
                },
                onConfirm: {
                    box.confirmed += 1
                }
            )
        }.build()

        #expect(result.lamps[.jogLeft] == .off)
        #expect(result.lamps[.jogRight] == .white)
        #expect(result.lamps[.jogUp] == .off)
        #expect(result.lamps[.jogDown] == .white)

        result.bindings.jog?("down")
        #expect(box.lastDelta == 4)
        result.bindings.jogScroll?(1, 0)
        #expect(box.lastDelta == 1)
        #expect(box.count == 2)
        result.bindings.jogCenter?()
        #expect(box.confirmed == 1)
    }

    @Test("Encoder discrete value element owns filter encoder bindings")
    func encoderDiscreteValueElementOwnsBindings() {
        let box = ScreenDSLBox()
        let result = MK2FullScreenDSL {
            MK2EncoderDiscreteValuesElement([
                MK2EncoderDiscreteValue(
                    encoder: 5,
                    value: 2,
                    bounds: 0...4,
                    wraps: true,
                    onTouch: { touched in
                        box.touched = touched
                    },
                    onChange: { value in
                        box.lastValue = value
                    }
                ),
                MK2EncoderDiscreteValue(
                    encoder: 6,
                    value: 1,
                    bounds: 0...4,
                    wraps: false,
                    onChange: { value in
                        box.secondValue = value
                    }
                ),
            ], drawsDisplays: false)
        }.build()

        result.bindings.encoderTouch[5]?(true)
        result.bindings.encoder[5]?(1, 0, 0)
        result.bindings.encoder[6]?(-1, 0, 0)

        #expect(box.touched)
        #expect(box.lastValue == 3)
        #expect(box.secondValue == 0)
    }

    @Test("Selection filter encoder element owns focus and value bindings")
    func selectionFilterEncoderElementOwnsBindings() {
        let box = ScreenDSLBox()
        let result = MK2FullScreenDSL {
            MK2SelectionFilterEncoderElement([
                MK2SelectionFilterEncoderBinding(
                    encoder: 5,
                    value: 1,
                    bounds: 0...3,
                    onFocus: { encoder, touched in
                        box.secondValue = touched ? encoder : -encoder
                    },
                    onChange: { value in
                        box.lastValue = value
                    }
                ),
            ])
        }.build()

        result.bindings.encoderTouch[5]?(true)
        result.bindings.encoder[5]?(1, 0, 0)
        result.bindings.encoderTouch[5]?(false)

        #expect(box.secondValue == -5)
        #expect(box.lastValue == 2)
    }

    @Test("Page indicator and tab bar draw compact navigation chrome")
    func pageIndicatorAndTabBarDraw() {
        let result = MK2RegularScreenDSL(header: .title(title: "Pages")) {
            MK2PageIndicatorElement(currentIndex: 1, pageCount: 3, x: 8, y: 16)
            MK2TabBarElement(
                items: [.init("Main"), .init("Filter"), .init("Mod")],
                selectedIndex: 1,
                rect: MK2PixelRect(x: 8, y: 40, width: 220, height: 26)
            )
        }.build()

        #expect(result.screen.frame.countPixels(in: MK2PixelRect(x: 16, y: 52, width: 40, height: 8), matching: MK2HIG.Chrome.accent) > 0)
        #expect(result.screen.frame.countPixels(in: MK2PixelRect(x: 16, y: 88, width: 220, height: 26), notMatching: MK2HIG.Chrome.background) > 40)
    }

    @Test("Parameter page draws value slots and owns encoder bindings")
    func parameterPageDrawsAndBindsEncoders() {
        let box = ScreenDSLBox()
        let result = MK2RegularScreenDSL(header: .title(title: "Params")) {
            MK2ParameterPageElement(
                slots: [
                    MK2ParameterPageSlot(
                        label: "Cutoff",
                        value: "64",
                        encoderValue: MK2EncoderDiscreteValue(
                            encoder: 1,
                            value: 3,
                            bounds: 0...7,
                            onTouch: { touched in
                                box.touched = touched
                            },
                            onChange: { value in
                                box.lastValue = value
                            }
                        )
                    ),
                    MK2ParameterPageSlot(label: "Reso", value: "22", isFocused: true),
                    MK2ParameterPageSlot(label: "Env", value: "+12"),
                    MK2ParameterPageSlot(label: "Drive", value: "Off"),
                ],
                rect: MK2PixelRect(x: 8, y: 16, width: 440, height: 96),
                pageIndex: 1,
                pageCount: 3
            )
        }.build()

        result.bindings.encoderTouch[1]?(true)
        result.bindings.encoder[1]?(2, 0, 0)

        #expect(box.touched)
        #expect(box.lastValue == 5)
        #expect(result.screen.frame.countPixels(in: MK2PixelRect(x: 8, y: 76, width: 440, height: 40), notMatching: MK2HIG.Chrome.background) > 80)
        #expect(result.screen.frame.countPixels(in: MK2PixelRect(x: 420, y: 148, width: 32, height: 10), matching: MK2HIG.Chrome.accent) > 0)
    }

    @Test("Meter element draws levels and peak markers")
    func meterElementDrawsLevelsAndPeaks() {
        let result = MK2FullScreenDSL {
            MK2MeterElement(
                channels: [
                    MK2MeterChannel(label: "L", level: 0.50, peak: 0.80),
                    MK2MeterChannel(label: "R", level: 0.95, peak: 1.0),
                ],
                rect: MK2PixelRect(x: 20, y: 40, width: 220, height: 34),
                relativeToContent: false
            )
            MK2MeterElement(
                channels: [
                    MK2MeterChannel(level: 0.30, peak: 0.45),
                    MK2MeterChannel(level: 0.74, peak: 0.90),
                ],
                rect: MK2PixelRect(x: 280, y: 40, width: 54, height: 100),
                orientation: .vertical,
                relativeToContent: false
            )
        }.build()

        #expect(result.screen.frame.countPixels(in: MK2PixelRect(x: 55, y: 42, width: 80, height: 12), matching: 0x464f) > 20)
        #expect(result.screen.frame.countPixels(in: MK2PixelRect(x: 55, y: 62, width: 180, height: 12), matching: 0xf8c3) > 20)
        #expect(result.screen.frame.countPixels(in: MK2PixelRect(x: 200, y: 42, width: 5, height: 12), matching: MK2HIG.Chrome.text) > 0)
        #expect(result.screen.frame.countPixels(in: MK2PixelRect(x: 310, y: 65, width: 24, height: 60), matching: MK2HIG.Chrome.accent) > 20)
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
    var lastDelta = 0
    var confirmed = 0
    var touched = false
    var lastValue = 0
    var secondValue = 0
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
