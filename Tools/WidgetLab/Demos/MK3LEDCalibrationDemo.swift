import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// A literal-byte laboratory for MASCHINE MK3 colour LEDs. E1 controls the
/// low two brightness bits and E2 selects a source-derived hue code. Every
/// candidate receives the same byte so hardware classes can be compared by eye.
final class MK3LEDCalibrationDemo: LabDemo, @unchecked Sendable {
    private struct ColorChoice: Sendable {
        var label: String
        var hueCode: UInt8
        var preview: KKRGB
    }

    let descriptor = DemoDescriptor(
        id: "mk3-led-calibration",
        title: "MASCHINE MK3 RGB LED Calibration",
        category: .calibration,
        summary: "Cross-check RGB hue and brightness bytes",
        detail: "E1 selects brightness 0...3 and E2 selects 16 hue sectors, protocol white, or the alternate 0x4E reference. Browser is the monochrome comparison. Sampling is RGB with a monochrome white curve; Group A-H, the four 4-D halo dots, and all 16 pads use the linear RGB curve.",
        snapshotVariants: ["red", "white"],
        requiredFamily: .maschineMK3
    )

    /// openAV-Ctlra derives device hue codes 1...16 from a 0...255 HSV hue.
    /// White is the special wrapped hue 0xff. The final entry retains our
    /// source-derived 0x4e reference as an explicit hardware cross-check.
    private static let colors: [ColorChoice] = (0..<16).map { index in
        ColorChoice(
            label: String(format: "H%02d", index + 1),
            hueCode: UInt8(index + 1),
            preview: .hsv(Double(index) * 360.0 / 16.0, 1, 1)
        )
    } + [
        ColorChoice(label: "WHITE", hueCode: 0x3f, preview: KKRGB(red: 0xff, green: 0xff, blue: 0xff)),
        ColorChoice(label: "REF-4E", hueCode: 0x13, preview: KKRGB(red: 0xff, green: 0xff, blue: 0xff)),
    ]

    private static let candidateButtons: [MaschineMK3ButtonLED] = [
        .browser,
        .sampling,
        .groupA, .groupB, .groupC, .groupD, .groupE, .groupF, .groupG, .groupH,
        .mainEncoderUp, .mainEncoderLeft, .mainEncoderRight, .mainEncoderDown,
    ]

    private var brightness = 2
    private var colorIndex = 0
    private var focusedEncoder: Int?

    private var color: ColorChoice { Self.colors[colorIndex] }
    private var rawByte: UInt8 { (color.hueCode &<< 2) | UInt8(brightness) }

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        let values = encoderValues(context)
        var scene = MK2SurfaceScene2(
            left: calibrationScreen(context, values: values).screen.frame,
            right: targetScreen(context).screen.frame
        )
        scene.diagnosticLEDBytes = diagnosticLEDBytes()
        for value in values {
            value.apply(bindings: &scene.bindings)
        }
        return scene
    }

    func prepareSnapshot(variant: String) {
        brightness = variant == "white" ? 3 : 1
        colorIndex = variant == "white" ? 16 : 0
        focusedEncoder = nil
    }

    func replCommands() -> [ReplCommand] {
        [
            ReplCommand(name: "calbright", arg: "<0-3>", summary: "set MK3 RGB brightness bits", values: ["0", "1", "2", "3"]),
            ReplCommand(name: "calcolor", arg: "<0-17>", summary: "set MK3 RGB hue/reference", values: Self.colors.indices.map(String.init)),
        ]
    }

    func handleRepl(verb: String, rest: String, _ context: LabContext) -> Bool {
        switch verb {
            case "calbright":
                guard let value = Int(rest), (0...3).contains(value) else { return true }
                context.update { [weak self] in self?.brightness = value }
                return true
            case "calcolor":
                guard let value = Int(rest), Self.colors.indices.contains(value) else { return true }
                context.update { [weak self] in self?.colorIndex = value }
                return true
            default:
                return false
        }
    }

    func testState() -> String? {
        String(format: "bright=%d color=%@ raw=%02X", brightness, color.label, rawByte)
    }

    private func diagnosticLEDBytes() -> [KontrolSurfaceDiagnosticLED: UInt8] {
        var result = Dictionary(
            uniqueKeysWithValues: Self.candidateButtons.map {
                (KontrolSurfaceDiagnosticLED.maschineMK3Button($0), rawByte)
            }
        )
        for pad in MaschineMK3PadLED.allCases {
            result[.maschineMK3Pad(pad)] = rawByte
        }
        return result
    }

    private func calibrationScreen(
        _ context: LabContext,
        values: [MK2EncoderDiscreteValue]
    ) -> MK2ScreenBuildResult {
        let selected = color
        let selectedColorIndex = colorIndex
        let byte = rawByte
        let level = brightness
        return MK2RegularScreenDSL(
            header: .title(title: "MK3 RGB LED Calibration", subtitle: "One raw byte on every candidate"),
            footer: .encoderArea()
        ) {
            MK2AnyScreenElement { frame, elementContext, _ in
                guard let content = elementContext.layout?.contentRect else { return }
                let left = content.x + 8
                let top = content.y + 5

                BitmapLabel("WIRE VALUE", font: .gridBold, color: Palette.text)
                    .draw(into: &frame, x: left, y: top, clip: content)
                frame.fill(
                    MK2PixelRect(x: left, y: top + 27, width: 96, height: 48),
                    KompleteKontrolSSeriesMK2.rgb565(selected.preview)
                )
                frame.stroke(MK2PixelRect(x: left, y: top + 27, width: 96, height: 48), Palette.text, width: 2)
                BitmapLabel(String(format: "0x%02X", byte), font: .readoutBold, color: Palette.text)
                    .draw(into: &frame, x: left + 126, y: top + 27, clip: content)
                BitmapLabel("\(selected.label)  HUE=\(selected.hueCode)", font: .gridBold, color: Palette.accent)
                    .draw(into: &frame, x: left + 126, y: top + 58, clip: content)
                BitmapLabel("BRIGHTNESS BITS = \(level)", font: .grid, color: Palette.dim)
                    .draw(into: &frame, x: left + 126, y: top + 84, clip: content)

                for index in 0..<16 {
                    let preview = Self.colors[index].preview
                    let x = left + index * 27
                    frame.fill(MK2PixelRect(x: x, y: top + 115, width: 25, height: 18), KompleteKontrolSSeriesMK2.rgb565(preview))
                    if index == selectedColorIndex {
                        frame.stroke(MK2PixelRect(x: x - 1, y: top + 114, width: 27, height: 20), Palette.text, width: 2)
                    }
                }
                BitmapLabel("H01                                      H16", font: .label, color: Palette.dim)
                    .draw(into: &frame, x: left, y: top + 139, clip: content)
            }
            MK2EncoderDiscreteValuesElement(values)
        }.build(renderer: context.renderer)
    }

    private func targetScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(
            header: .title(title: "Compare LED Classes", subtitle: String(format: "Current raw byte 0x%02X", rawByte)),
            footer: .hint("E1 brightness - E2 colour/reference")
        ) {
            MK2AnyScreenElement { frame, elementContext, _ in
                guard let content = elementContext.layout?.contentRect else { return }
                let left = content.x + 8
                let top = content.y + 5

                BitmapLabel("ALL RECEIVE THE SAME BYTE", font: .gridBold, color: Palette.text)
                    .draw(into: &frame, x: left, y: top, clip: content)
                let rows: [(String, String, UInt16)] = [
                    ("BROWSER", "MONO: 1 < 0 < 2 < 3", Palette.text),
                    ("SAMPLING", "RGB; WHITE USES MONO", Palette.text),
                    ("GROUP A-H", "RGB: 0 < 1 < 2 < 3", Palette.accent),
                    ("4-D HALO DOTS", "RGB: 0 < 1 < 2 < 3", Palette.accent),
                    ("PADS 1-16", "RGB: 0 < 1 < 2 < 3", Palette.accent),
                ]
                for (index, row) in rows.enumerated() {
                    let y = top + 31 + index * 30
                    BitmapLabel(row.0, font: .gridBold, color: row.2)
                        .draw(into: &frame, x: left, y: y, clip: content)
                    BitmapLabel(row.1, font: .grid, color: Palette.dim)
                        .draw(into: &frame, x: left + 168, y: y, clip: content)
                }
                BitmapLabel("WHITE and REF-4E are separate E2 entries.", font: .grid, color: Palette.orange)
                    .draw(into: &frame, x: left, y: top + 187, clip: content)
            }
        }.build(renderer: context.renderer)
    }

    private func encoderValues(_ context: LabContext) -> [MK2EncoderDiscreteValue] {
        [
            MK2EncoderDiscreteValue(
                encoder: 1,
                value: brightness,
                bounds: 0...3,
                defaultValue: 2,
                display: encoderDisplay(
                    label: "BRIGHT",
                    icon: MK2HIG.IconGlyph.sun,
                    value: "\(brightness)",
                    encoder: 1
                ),
                onTouch: touch(1, context),
                onChange: { [weak self] value in
                    guard let demo = self else { return }
                    context.update { demo.brightness = max(0, min(3, value)) }
                }
            ),
            MK2EncoderDiscreteValue(
                encoder: 2,
                value: colorIndex,
                bounds: 0...(Self.colors.count - 1),
                wraps: true,
                defaultValue: 0,
                display: encoderDisplay(
                    label: "COLOUR",
                    icon: MK2HIG.IconGlyph.palette,
                    value: color.label,
                    encoder: 2
                ),
                onTouch: touch(2, context),
                onChange: { [weak self] value in
                    guard let demo = self else { return }
                    context.update { demo.colorIndex = value.wrapped(to: 0...(Self.colors.count - 1)) }
                }
            ),
        ]
    }

    private func touch(_ encoder: Int, _ context: LabContext) -> (@Sendable (Bool) -> Void) {
        { [weak self] touched in
            guard let demo = self else { return }
            context.update {
                if touched {
                    demo.focusedEncoder = encoder
                } else if demo.focusedEncoder == encoder {
                    demo.focusedEncoder = nil
                }
            }
        }
    }

    private func encoderDisplay(
        label: String,
        icon: String,
        value: String,
        encoder: Int
    ) -> MK2EncoderDiscreteValueDisplay {
        MK2EncoderDiscreteValueDisplay(
            label: label,
            iconGlyph: icon,
            value: value,
            rect: MK2ScreenLayout.encoderSlotRect(encoder - 1),
            isFocused: focusedEncoder == encoder,
            valueFont: .readoutBold,
            cornerRadius: 7,
            colors: labEditCellColors(value: Palette.text)
        )
    }
}
