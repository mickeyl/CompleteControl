import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// A literal-byte laboratory for MASCHINE MK3 palette LEDs. E1 controls the
/// low two brightness bits and E2 selects a source-derived hue code. VARIATION
/// switches between one byte on every candidate, all 16 raw hues on Pads 1-16,
/// and their bench-calibrated nine-family semantic collapse.
final class MK3LEDCalibrationDemo: LabDemo, @unchecked Sendable {
    private struct ColorChoice: Sendable {
        var label: String
        var hueCode: UInt8
        var preview: KKRGB
    }

    private enum Mode: String, Sendable {
        case sameByte = "SAME"
        case hueAtlas = "ATLAS"
        case safePalette = "SAFE"

        var next: Mode {
            switch self {
                case .sameByte: .hueAtlas
                case .hueAtlas: .safePalette
                case .safePalette: .sameByte
            }
        }

        init?(replValue: String) {
            switch replValue.lowercased() {
                case "same": self = .sameByte
                case "atlas": self = .hueAtlas
                case "safe": self = .safePalette
                default: return nil
            }
        }
    }

    let descriptor = DemoDescriptor(
        id: "mk3-led-calibration",
        title: "MASCHINE MK3 LED Palette Calibration",
        category: .calibration,
        summary: "Cross-check hue palette and brightness bytes",
        detail: "VARIATION cycles one raw byte on every LED class, H01-H16 simultaneously on Pads 1-16, and the calibrated nine-family SAFE collapse. E1 selects brightness 0...3; E2 selects the focused hue, protocol white, or alternate 0x4E reference.",
        snapshotVariants: ["red", "white", "atlas", "safe"],
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

    /// Physical pad-number order, independent from the bottom-up wire offsets.
    private static let padLEDs: [MaschineMK3PadLED] = [
        .pad1, .pad2, .pad3, .pad4,
        .pad5, .pad6, .pad7, .pad8,
        .pad9, .pad10, .pad11, .pad12,
        .pad13, .pad14, .pad15, .pad16,
    ]

    private var mode = Mode.sameByte
    private var brightness = 2
    private var colorIndex = 0
    private var focusedEncoder: Int?

    private var color: ColorChoice { Self.colors[colorIndex] }
    private var outputHueCode: UInt8 {
        guard mode == .safePalette else { return color.hueCode }
        return MaschineMK3Protocol.calibratedColorHueCode(forPaletteIndex: UInt8(colorIndex + 1)) ?? color.hueCode
    }
    private var outputColor: ColorChoice {
        guard mode == .safePalette, (1...16).contains(Int(outputHueCode)) else { return color }
        return Self.colors[Int(outputHueCode) - 1]
    }
    private var rawByte: UInt8 { wireByte(for: outputHueCode) }
    private var selectableColorCount: Int { mode == .sameByte ? Self.colors.count : 16 }

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        let values = encoderValues(context)
        var scene = MK2SurfaceScene2(
            left: calibrationScreen(context, values: values).screen.frame,
            right: targetScreen(context).screen.frame
        )
        scene.diagnosticLEDBytes = diagnosticLEDBytes()
        scene.lamps[.instance] = .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01)
        scene.bindings.onPress(.instance) { [weak self] in
            context.update { [weak self] in
                guard let self else { return }
                self.mode = self.mode.next
                self.colorIndex = min(self.colorIndex, self.selectableColorCount - 1)
            }
        }
        for value in values {
            value.apply(bindings: &scene.bindings)
        }
        return scene
    }

    func prepareSnapshot(variant: String) {
        switch variant {
            case "white":
                mode = .sameByte
                brightness = 3
                colorIndex = 16
            case "atlas":
                mode = .hueAtlas
                brightness = 2
                colorIndex = 0
            case "safe":
                mode = .safePalette
                brightness = 2
                colorIndex = 0
            default:
                mode = .sameByte
                brightness = 1
                colorIndex = 0
        }
        focusedEncoder = nil
    }

    func replCommands() -> [ReplCommand] {
        [
            ReplCommand(name: "calbright", arg: "<0-3>", summary: "set MK3 RGB brightness bits", values: ["0", "1", "2", "3"]),
            ReplCommand(name: "calcolor", arg: "<0-17>", summary: "set MK3 RGB hue/reference", values: Self.colors.indices.map(String.init)),
            ReplCommand(name: "calmode", arg: "<same|atlas|safe>", summary: "select raw, atlas, or calibrated hue view", values: ["same", "atlas", "safe"]),
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
                context.update { [weak self] in
                    guard let self else { return }
                    self.colorIndex = min(value, self.selectableColorCount - 1)
                }
                return true
            case "calmode":
                guard let nextMode = Mode(replValue: rest) else { return true }
                context.update { [weak self] in
                    guard let self else { return }
                    self.mode = nextMode
                    self.colorIndex = min(self.colorIndex, self.selectableColorCount - 1)
                }
                return true
            default:
                return false
        }
    }

    func testState() -> String? {
        String(
            format: "mode=%@ bright=%d source=%@ output=H%02d raw=%02X",
            mode.rawValue.lowercased(), brightness, color.label, outputHueCode, rawByte
        )
    }

    private func diagnosticLEDBytes() -> [KontrolSurfaceDiagnosticLED: UInt8] {
        switch mode {
            case .sameByte:
                var result = Dictionary(
                    uniqueKeysWithValues: Self.candidateButtons.map {
                        (KontrolSurfaceDiagnosticLED.maschineMK3Button($0), rawByte)
                    }
                )
                for pad in Self.padLEDs {
                    result[.maschineMK3Pad(pad)] = rawByte
                }
                return result

            case .hueAtlas:
                return Dictionary(uniqueKeysWithValues: Self.padLEDs.enumerated().map { index, pad in
                    (.maschineMK3Pad(pad), wireByte(for: UInt8(index + 1)))
                })

            case .safePalette:
                return Dictionary(uniqueKeysWithValues: Self.padLEDs.enumerated().compactMap { index, pad in
                    guard let hueCode = MaschineMK3Protocol.calibratedColorHueCode(
                        forPaletteIndex: UInt8(index + 1)
                    ) else { return nil }
                    return (.maschineMK3Pad(pad), wireByte(for: hueCode))
                })
        }
    }

    private func wireByte(for hueCode: UInt8) -> UInt8 {
        (hueCode &<< 2) | UInt8(brightness)
    }

    private func atlasHueCode(forPadNumber padNumber: Int, calibrated: Bool) -> UInt8 {
        let sourceHueCode = UInt8(padNumber)
        guard calibrated else { return sourceHueCode }
        return MaschineMK3Protocol.calibratedColorHueCode(forPaletteIndex: sourceHueCode) ?? sourceHueCode
    }

    private func atlasByte(forPadNumber padNumber: Int, calibrated: Bool) -> UInt8 {
        wireByte(for: atlasHueCode(forPadNumber: padNumber, calibrated: calibrated))
    }

    private func atlasColor(forPadNumber padNumber: Int, calibrated: Bool) -> ColorChoice {
        let hueCode = atlasHueCode(forPadNumber: padNumber, calibrated: calibrated)
        return Self.colors[Int(hueCode) - 1]
    }

    private func atlasPadNumbersTopDown() -> [[Int]] {
        [
            [13, 14, 15, 16],
            [9, 10, 11, 12],
            [5, 6, 7, 8],
            [1, 2, 3, 4],
        ]
    }

    private func modeHeaderSubtitle() -> String {
        switch mode {
            case .sameByte: "One raw byte on every candidate"
            case .hueAtlas: "H01-H16 on physical Pads 1-16"
            case .safePalette: "16 -> 9 hue families"
        }
    }

    private func modeWireLabel(selectedColorIndex: Int) -> String {
        switch mode {
            case .sameByte: "WIRE VALUE"
            case .hueAtlas: "FOCUS PAD \(selectedColorIndex + 1)"
            case .safePalette: "SOURCE PAD \(selectedColorIndex + 1)"
        }
    }

    private func modeFooterHint() -> String {
        switch mode {
            case .sameByte: "E1 brightness - E2 colour/reference - VARIATION atlas"
            case .hueAtlas: "E1 brightness - E2 focus - VARIATION safe palette"
            case .safePalette: "E1 brightness - E2 source - VARIATION same-byte view"
        }
    }

    private func targetScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        switch mode {
            case .sameByte: comparisonScreen(context)
            case .hueAtlas: hueAtlasScreen(context, calibrated: false)
            case .safePalette: hueAtlasScreen(context, calibrated: true)
        }
    }

    private func comparisonScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(
            header: .title(title: "Compare LED Classes", subtitle: String(format: "Current raw byte 0x%02X", rawByte)),
            footer: .hint(modeFooterHint())
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

    private func hueAtlasScreen(_ context: LabContext, calibrated: Bool) -> MK2ScreenBuildResult {
        let focusedPadNumber = colorIndex + 1
        let rows = atlasPadNumbersTopDown()
        return MK2RegularScreenDSL(
            header: .title(
                title: calibrated ? "Safe Semantic Palette" : "16-Hue Pad Atlas",
                subtitle: calibrated ? "16 source hues -> 9 families" : "Brightness bits \(brightness)"
            ),
            footer: .hint(modeFooterHint())
        ) {
            MK2AnyScreenElement { frame, elementContext, _ in
                guard let content = elementContext.layout?.contentRect else { return }
                let left = content.x + 8
                let top = content.y + 4

                BitmapLabel(
                    calibrated ? "CALIBRATED COLLAPSE - SAME BRIGHTNESS" : "PHYSICAL PAD LAYOUT - SAME BRIGHTNESS",
                    font: .gridBold,
                    color: Palette.text
                )
                    .draw(into: &frame, x: left, y: top, clip: content)

                for (rowIndex, padNumbers) in rows.enumerated() {
                    for (columnIndex, padNumber) in padNumbers.enumerated() {
                        let hueCode = self.atlasHueCode(forPadNumber: padNumber, calibrated: calibrated)
                        let choice = self.atlasColor(forPadNumber: padNumber, calibrated: calibrated)
                        let x = left + columnIndex * 112
                        let y = top + 27 + rowIndex * 39
                        let cell = MK2PixelRect(x: x, y: y, width: 104, height: 33)
                        let swatch = MK2PixelRect(x: x + 3, y: y + 3, width: 26, height: 27)
                        frame.stroke(
                            cell,
                            padNumber == focusedPadNumber ? Palette.text : Palette.border,
                            width: padNumber == focusedPadNumber ? 2 : 1
                        )
                        frame.fill(swatch, KompleteKontrolSSeriesMK2.rgb565(choice.preview))
                        BitmapLabel(String(format: "P%02d H%02d", padNumber, hueCode), font: .gridBold, color: Palette.text)
                            .draw(into: &frame, x: x + 35, y: y + 2, clip: cell)
                        BitmapLabel(
                            String(format: "0x%02X", self.atlasByte(forPadNumber: padNumber, calibrated: calibrated)),
                            font: .label,
                            color: Palette.dim
                        )
                            .draw(into: &frame, x: x + 35, y: y + 19, clip: cell)
                    }
                }

                BitmapLabel(
                    calibrated ? "Pad number is source hue; Hxx is safe output." : "Top row is Pads 13-16; bottom row is Pads 1-4.",
                    font: .label,
                    color: Palette.orange
                )
                    .draw(into: &frame, x: left, y: top + 188, clip: content)
            }
        }.build(renderer: context.renderer)
    }

    private func calibrationScreen(
        _ context: LabContext,
        values: [MK2EncoderDiscreteValue]
    ) -> MK2ScreenBuildResult {
        let selectedSource = color
        let selectedOutput = outputColor
        let selectedColorIndex = colorIndex
        let byte = rawByte
        let level = brightness
        let selectionLine = mode == .safePalette
            ? "\(selectedSource.label) -> H\(String(format: "%02d", outputHueCode))"
            : "\(selectedSource.label)  HUE=\(selectedSource.hueCode)"
        return MK2RegularScreenDSL(
            header: .title(title: "MK3 LED Calibration", subtitle: modeHeaderSubtitle()),
            footer: .encoderArea()
        ) {
            MK2AnyScreenElement { frame, elementContext, _ in
                guard let content = elementContext.layout?.contentRect else { return }
                let left = content.x + 8
                let top = content.y + 5

                BitmapLabel(self.modeWireLabel(selectedColorIndex: selectedColorIndex), font: .gridBold, color: Palette.text)
                    .draw(into: &frame, x: left, y: top, clip: content)
                frame.fill(
                    MK2PixelRect(x: left, y: top + 27, width: 96, height: 48),
                    KompleteKontrolSSeriesMK2.rgb565(selectedOutput.preview)
                )
                frame.stroke(MK2PixelRect(x: left, y: top + 27, width: 96, height: 48), Palette.text, width: 2)
                BitmapLabel(String(format: "0x%02X", byte), font: .readoutBold, color: Palette.text)
                    .draw(into: &frame, x: left + 126, y: top + 27, clip: content)
                BitmapLabel(
                    selectionLine,
                    font: .gridBold,
                    color: Palette.accent
                )
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
                bounds: 0...(selectableColorCount - 1),
                wraps: true,
                defaultValue: 0,
                display: encoderDisplay(
                    label: mode == .sameByte ? "COLOUR" : (mode == .hueAtlas ? "FOCUS" : "SOURCE"),
                    icon: MK2HIG.IconGlyph.palette,
                    value: color.label,
                    encoder: 2
                ),
                onTouch: touch(2, context),
                onChange: { [weak self] value in
                    guard let demo = self else { return }
                    context.update { demo.colorIndex = value.wrapped(to: 0...(demo.selectableColorCount - 1)) }
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
