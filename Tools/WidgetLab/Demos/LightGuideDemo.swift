import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// Diagnostics for the 0x81 light guide and the button LEDs, driven through
/// ordinary scene state: E5 picks a fill pattern, E6 the colour, E7 the key
/// span, E8 mirrors the colour onto the function-key LEDs. The 4-D wheel
/// moves a key cursor, 4-D press paints or clears that key on top of the
/// pattern; the left screen mirrors what the hardware guide should show.
final class LightGuideDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "light-guide",
        title: "Light Guide & LEDs",
        category: .diagnostics,
        summary: "Paint light-guide keys and button LEDs",
        detail: "Scene-driven light-guide painting with an on-screen mirror to compare against the hardware. E5 pattern, E6 colour, E7 key span, E8 mirrors the colour onto the F-key LEDs; 4-D moves the cursor, press paints.",
        snapshotVariants: ["rainbow", "solid", "instruments64"],
        requiredFamily: .kompleteKontrolMK2
    )

    private enum GuidePattern: Int, CaseIterable {
        case off, solid, octaves, rainbow, instruments64

        var title: String {
            switch self {
                case .off: "OFF"
                case .solid: "SOLID"
                case .octaves: "OCTAVES"
                case .rainbow: "RAINBOW"
                case .instruments64: "64 INST"
            }
        }
    }

    private static let colors: [(name: String, rgb: KKRGB)] = [
        ("WHITE", KKRGB(red: 0xff, green: 0xff, blue: 0xff)),
        ("RED", KKRGB(red: 0xff, green: 0x00, blue: 0x00)),
        ("ORANGE", KKRGB(red: 0xff, green: 0x7f, blue: 0x00)),
        ("GREEN", KKRGB(red: 0x00, green: 0xff, blue: 0x00)),
        ("CYAN", KKRGB(red: 0x00, green: 0xff, blue: 0xff)),
        ("BLUE", KKRGB(red: 0x00, green: 0x00, blue: 0xff)),
        ("MAGENTA", KKRGB(red: 0xff, green: 0x00, blue: 0xff)),
    ]
    private static let spans = [49, 61, 88]
    private static let instrumentHues: [KKRGB] = [
        KKRGB(red: 0xff, green: 0x00, blue: 0x00),
        KKRGB(red: 0x00, green: 0xff, blue: 0xff),
        KKRGB(red: 0xff, green: 0xff, blue: 0x00),
        KKRGB(red: 0x00, green: 0x00, blue: 0xff),
        KKRGB(red: 0x00, green: 0xff, blue: 0x00),
        KKRGB(red: 0xff, green: 0x00, blue: 0xff),
        KKRGB(red: 0xff, green: 0x7f, blue: 0x00),
        KKRGB(red: 0x00, green: 0x7f, blue: 0xff),
        KKRGB(red: 0x7f, green: 0xff, blue: 0x00),
        KKRGB(red: 0x7f, green: 0x00, blue: 0xff),
        KKRGB(red: 0xff, green: 0xcf, blue: 0x00),
        KKRGB(red: 0x3f, green: 0x00, blue: 0xff),
        KKRGB(red: 0x00, green: 0xff, blue: 0x7f),
        KKRGB(red: 0xff, green: 0x00, blue: 0x7f),
        KKRGB(red: 0xff, green: 0x3f, blue: 0x00),
        KKRGB(red: 0xff, green: 0x00, blue: 0x3f),
    ]
    private static let functionLEDs: [KKMK2ButtonLED] = [
        .function1, .function2, .function3, .function4,
        .function5, .function6, .function7, .function8,
    ]

    private var pattern: GuidePattern = .octaves
    private var colorIndex = 4
    private var spanIndex = 1
    private var mirrorLEDs = false
    private var cursor = 0
    private var painted: [Int: KKRGB] = [:]
    private var focusedEncoder: Int?

    private var span: Int { Self.spans[spanIndex] }
    private var color: KKRGB { Self.colors[colorIndex].rgb }

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        let keyColors = guideColors()
        let keyIntensities = guideIntensities()
        var lamps: [KKMK2ButtonLED: MK2LampState2] = [:]
        if mirrorLEDs {
            for led in Self.functionLEDs {
                lamps[led] = .on(color, intensity: 0x03)
            }
        }
        let canClear = pattern != .off || !painted.isEmpty
        lamps[.clear] = canClear
            ? .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01)
            : .off
        var scene = MK2SurfaceScene2(
            left: mirrorScreen(context).screen.frame,
            right: controlScreen(context).screen.frame,
            lamps: lamps,
            keyColors: keyColors,
            keyIntensities: keyIntensities
        )
        scene.bindings.jogScroll = { [weak self] delta, _ in
            context.update {
                guard let self else { return }
                self.cursor = max(0, min(self.span - 1, self.cursor + delta))
            }
        }
        scene.bindings.jogCenter = { [weak self] in
            context.update {
                guard let self else { return }
                if self.painted[self.cursor] != nil {
                    self.painted.removeValue(forKey: self.cursor)
                } else {
                    self.painted[self.cursor] = self.color
                }
            }
        }
        scene.bindings.onPress(.clear) { [weak self] in
            context.update { [weak self] in self?.clearAllKeys() }
        }
        for value in encoderValues(context) {
            value.apply(bindings: &scene.bindings)
        }
        return scene
    }

    func prepareSnapshot(variant: String) {
        switch variant {
            case "rainbow": pattern = .rainbow
            case "solid": pattern = .solid
            case "instruments64":
                pattern = .instruments64
                spanIndex = 2
            default: pattern = .octaves
        }
    }

    // MARK: - Guide state

    /// The lowest key of an S88 is an A, the smaller models start on a C —
    /// the octave pattern has to know where the real Cs sit.
    private var lowNoteClass: Int {
        span == 88 ? 9 : 0
    }

    private func guideColors() -> [Int: KKRGB] {
        var colors: [Int: KKRGB] = [:]
        switch pattern {
            case .off:
                break
            case .solid:
                for key in 0..<span {
                    colors[key] = color
                }
            case .octaves:
                for key in 0..<span where (key + lowNoteClass) % 12 == 0 {
                    colors[key] = color
                }
            case .rainbow:
                for key in 0..<span {
                    colors[key] = Self.rainbow(Double(key) / Double(max(1, span - 1)))
                }
            case .instruments64:
                for key in 0..<min(64, span) {
                    colors[key] = Self.instrumentHues[key % Self.instrumentHues.count]
                }
        }
        colors.merge(painted) { _, override in override }
        return colors
    }

    private func guideIntensities() -> [Int: UInt8] {
        var intensities: [Int: UInt8] = [:]
        if pattern == .instruments64 {
            for key in 0..<min(64, span) {
                intensities[key] = UInt8(3 - key / Self.instrumentHues.count)
            }
        }
        for key in painted.keys {
            intensities[key] = 3
        }
        return intensities
    }

    private func clearAllKeys() {
        pattern = .off
        painted.removeAll()
    }

    private static func rainbow(_ position: Double) -> KKRGB {
        let hue = max(0, min(1, position)) * 300.0 / 360.0
        let sector = hue * 6.0
        let fraction = sector - sector.rounded(.down)
        let ramp = UInt8((fraction * 255.0).rounded())
        let inverseRamp = UInt8(((1.0 - fraction) * 255.0).rounded())
        switch Int(sector) {
            case 0: return KKRGB(red: 0xff, green: ramp, blue: 0x00)
            case 1: return KKRGB(red: inverseRamp, green: 0xff, blue: 0x00)
            case 2: return KKRGB(red: 0x00, green: 0xff, blue: ramp)
            case 3: return KKRGB(red: 0x00, green: inverseRamp, blue: 0xff)
            default: return KKRGB(red: ramp, green: 0x00, blue: 0xff)
        }
    }

    private static func rgb565(_ color: KKRGB) -> UInt16 {
        (UInt16(color.red >> 3) << 11) | (UInt16(color.green >> 2) << 5) | UInt16(color.blue >> 3)
    }

    // MARK: - Screens

    private func mirrorScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        let keyColors = guideColors()
        let keyIntensities = guideIntensities()
        let span = span
        let cursor = cursor
        let paintedCount = painted.count
        return MK2RegularScreenDSL(
            header: .title(title: "Light Guide & LEDs", subtitle: "\(span) keys"),
            footer: .hint("4-D moves the cursor, press paints or clears the key.")
        ) {
            MK2ContentText("Guide Mirror", x: 8, y: 0, role: .title)
            MK2ContentText(
                "What the light guide should show right now. Compare screen and hardware key by key — a mismatch is a wiring or index bug.",
                x: 8,
                y: 40,
                maxWidth: 432,
                color: Palette.dim,
                maxLines: 2,
                lineSpacing: 2
            )
            MK2AnyScreenElement { frame, _, _ in
                Self.drawGuideMirror(into: &frame, keyColors: keyColors, keyIntensities: keyIntensities, span: span, cursor: cursor, rect: MK2PixelRect(x: 8, y: 148, width: 464, height: 56))
                BitmapLabel("KEY \(cursor)", font: .gridBold, color: Palette.text).draw(into: &frame, x: 8, y: 218)
                BitmapLabel("PAINTED \(paintedCount)", font: .grid, color: paintedCount > 0 ? Palette.accent : Palette.empty).draw(into: &frame, x: 120, y: 218)
            }
        }.build(renderer: context.renderer)
    }

    private static func drawGuideMirror(into frame: inout MK2PixelFrame, keyColors: [Int: KKRGB], keyIntensities: [Int: UInt8], span: Int, cursor: Int, rect: MK2PixelRect) {
        let blackNoteClasses: Set<Int> = [1, 3, 6, 8, 10]
        let lowNoteClass = span == 88 ? 9 : 0
        for key in 0..<span {
            let x0 = rect.x + key * rect.width / span
            let x1 = rect.x + (key + 1) * rect.width / span
            let width = max(1, x1 - x0 - 1)
            let isBlackKey = blackNoteClasses.contains((key + lowNoteClass) % 12)
            let keyRect = MK2PixelRect(x: x0, y: rect.y, width: width, height: isBlackKey ? rect.height * 3 / 5 : rect.height)
            let base: UInt16 = isBlackKey ? 0x2104 : 0x39e7
            frame.fill(keyRect, base)
            if let color = keyColors[key] {
                let light = MK2LightGuideColor(color: color, intensity: keyIntensities[key] ?? 3)
                let displayedColor = KompleteKontrolSSeriesMK2.paletteColor(forCode: light.paletteCode)
                frame.fill(MK2PixelRect(x: x0, y: keyRect.y + keyRect.height - 8, width: width, height: 8), rgb565(displayedColor))
            }
            if key == cursor {
                frame.fill(MK2PixelRect(x: x0, y: rect.y + rect.height + 4, width: width, height: 3), Palette.text)
            }
        }
    }

    private func controlScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        let values = encoderValues(context)
        let statusColor = mirrorLEDs ? Palette.accent : Palette.dim
        return MK2FullScreenDSL(background: Palette.page) {
            MK2FunctionKeyBarElement(
                slots: [
                    MK2FunctionKeySlot("CLEAR", isEnabled: pattern != .off || !painted.isEmpty),
                    MK2FunctionKeySlot(),
                    MK2FunctionKeySlot(),
                    MK2FunctionKeySlot(),
                ],
                side: .right,
                onPress: { [weak self] slot in
                    guard slot == 0 else { return }
                    context.update { [weak self] in self?.clearAllKeys() }
                }
            )
            MK2AnyScreenElement { [pattern, colorName = Self.colors[colorIndex].name, mirrorLEDs] frame, _, _ in
                MK2StatusLine(y: 30, items: [
                    MK2StatusLineItem("GUIDE", x: 8, color: Palette.blue),
                    MK2StatusLineItem(pattern.title, x: 120, color: Palette.text, font: .gridBold),
                    MK2StatusLineItem(colorName, x: 260, color: Palette.dim),
                ]).draw(into: &frame)
                frame.hline(y: 54, x: 0, width: 480, color: Palette.border)
                var y = 66
                for (text, color) in [
                    ("SCENE KEYCOLORS DRIVE THE 0x81 GUIDE", Palette.dim),
                    ("PAINTED KEYS OVERRIDE THE PATTERN", Palette.dim),
                    ("CLEAR TURNS OFF ALL GUIDE KEYS", Palette.dim),
                    ("LEDS \(mirrorLEDs ? "MIRROR THE COLOUR (F1-F8)" : "OFF")", statusColor),
                ] {
                    BitmapLabel(text, font: .grid, color: color).draw(into: &frame, x: 8, y: y)
                    y += SurfaceFont.grid.cellHeight + 6
                }
            }
            MK2EncoderDiscreteValuesElement(values)
        }.build(renderer: context.renderer)
    }

    private func encoderValues(_ context: LabContext) -> [MK2EncoderDiscreteValue] {
        [
            MK2EncoderDiscreteValue(
                encoder: 5,
                value: pattern.rawValue,
                bounds: 0...(GuidePattern.allCases.count - 1),
                defaultValue: GuidePattern.octaves.rawValue,
                display: encoderDisplay(label: "PATTERN", icon: MK2HIG.IconGlyph.squaresFour, value: pattern.title, encoder: 5),
                onTouch: touch(5, context),
                onChange: { [weak self] value in
                    context.update {
                        self?.pattern = GuidePattern(rawValue: max(0, min(GuidePattern.allCases.count - 1, value))) ?? .off
                    }
                }
            ),
            MK2EncoderDiscreteValue(
                encoder: 6,
                value: colorIndex,
                bounds: 0...(Self.colors.count - 1),
                wraps: true,
                display: encoderDisplay(label: "COLOUR", icon: MK2HIG.IconGlyph.palette, value: Self.colors[colorIndex].name, encoder: 6),
                onTouch: touch(6, context),
                onChange: { [weak self] value in
                    context.update {
                        self?.colorIndex = value.wrapped(to: 0...(Self.colors.count - 1))
                    }
                }
            ),
            MK2EncoderDiscreteValue(
                encoder: 7,
                value: spanIndex,
                bounds: 0...(Self.spans.count - 1),
                defaultValue: 1,
                display: encoderDisplay(label: "SPAN", icon: MK2HIG.IconGlyph.ruler, value: "\(span)", encoder: 7),
                onTouch: touch(7, context),
                onChange: { [weak self] value in
                    context.update {
                        guard let self else { return }
                        self.spanIndex = max(0, min(Self.spans.count - 1, value))
                        self.cursor = min(self.cursor, self.span - 1)
                    }
                }
            ),
            MK2EncoderDiscreteValue(
                encoder: 8,
                value: mirrorLEDs ? 1 : 0,
                bounds: 0...1,
                display: encoderDisplay(label: "LEDS", icon: MK2HIG.IconGlyph.lightbulb, value: mirrorLEDs ? "ON" : "OFF", encoder: 8),
                onTouch: touch(8, context),
                onChange: { [weak self] value in
                    context.update { self?.mirrorLEDs = value == 1 }
                }
            ),
        ]
    }

    private func touch(_ encoder: Int, _ context: LabContext) -> (@Sendable (Bool) -> Void) {
        { [weak self] touched in
            context.update {
                guard let self else { return }
                if touched {
                    self.focusedEncoder = encoder
                } else if self.focusedEncoder == encoder {
                    self.focusedEncoder = nil
                }
            }
        }
    }

    private func encoderDisplay(label: String, icon: String, value: String, encoder: Int) -> MK2EncoderDiscreteValueDisplay {
        MK2EncoderDiscreteValueDisplay(
            label: label,
            iconGlyph: icon,
            value: value,
            rect: MK2ScreenLayout.encoderSlotRect(encoder - 5),
            isFocused: focusedEncoder == encoder,
            valueFont: .readoutBold,
            cornerRadius: 7,
            colors: labEditCellColors(value: Palette.text)
        )
    }
}
