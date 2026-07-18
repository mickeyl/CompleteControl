import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// A deliberate literal-byte laboratory for the two MASCHINE MK3 LED classes.
/// E1 pages eight monochrome button values on F1...F8. E2 chooses one colour
/// hue; the four 4-D ring segments then show that hue at brightness 0...3.
/// The screen is the permanent legend, so a hardware observation can name the
/// exact output byte without relying on a timed sweep.
final class MK3LEDCalibrationDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "mk3-led-calibration",
        title: "MASCHINE MK3 LED Calibration",
        category: .calibration,
        summary: "Literal brightness and hue reference",
        detail: "E1 pages raw monochrome bytes 00...1F over F1...F8. E2 selects bits 7...2; the four 4-D ring directions show brightness bits 1...0. The displays label every byte sent to the hardware.",
        snapshotVariants: ["mono-18", "white"]
    )

    private static let functionLEDs: [KKMK2ButtonLED] = [
        .function1, .function2, .function3, .function4,
        .function5, .function6, .function7, .function8,
    ]
    private static let ringLEDs: [(label: String, led: KKMK2ButtonLED)] = [
        ("UP", .jogUp),
        ("LEFT", .jogLeft),
        ("RIGHT", .jogRight),
        ("DOWN", .jogDown),
    ]

    private var monochromeBank = 0
    /// 0x4c...0x4f starts from the previously observed, clearly visible 0x4e.
    private var hue = 19
    private var focusedEncoder: Int?

    private var monochromeBase: Int { monochromeBank * 8 }
    private var ringBase: UInt8 { UInt8(hue << 2) }

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        var lamps: [KKMK2ButtonLED: MK2LampState2] = [:]
        for (index, led) in Self.functionLEDs.enumerated() {
            lamps[led] = .rawOutput(UInt8(monochromeBase + index))
        }
        for (index, entry) in Self.ringLEDs.enumerated() {
            lamps[entry.led] = .rawOutput(ringBase | UInt8(index))
        }

        var scene = MK2SurfaceScene2(
            left: monochromeScreen(context).screen.frame,
            right: hueScreen(context).screen.frame,
            lamps: lamps
        )
        for value in encoderValues(context) {
            value.apply(bindings: &scene.bindings)
        }
        return scene
    }

    func prepareSnapshot(variant: String) {
        switch variant {
            case "mono-18":
                monochromeBank = 3
                hue = 19
            case "white":
                monochromeBank = 0
                hue = 63
            default:
                monochromeBank = 0
                hue = 19
        }
        focusedEncoder = nil
    }

    func replCommands() -> [ReplCommand] {
        [
            ReplCommand(name: "calmono", arg: "<0-3>", summary: "set MK3 monochrome byte bank", values: ["0", "1", "2", "3"]),
            ReplCommand(name: "calhue", arg: "<0-63>", summary: "set MK3 4-D ring hue field", values: []),
        ]
    }

    func handleRepl(verb: String, rest: String, _ context: LabContext) -> Bool {
        switch verb {
            case "calmono":
                guard let value = Int(rest), (0...3).contains(value) else { return true }
                context.update { [weak self] in self?.monochromeBank = value }
                return true
            case "calhue":
                guard let value = Int(rest), (0...63).contains(value) else { return true }
                context.update { [weak self] in self?.hue = value }
                return true
            default:
                return false
        }
    }

    func testState() -> String? {
        "mono=\(monochromeBank) hue=\(hue)"
    }

    private func monochromeScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        let values = encoderValues(context)
        return MK2RegularScreenDSL(
            header: .title(title: "MK3 LED Calibration", subtitle: "Raw bytes, no lowering"),
            footer: .hint("E1 pages F1–F8 through 00...1F")
        ) {
            MK2ContentText("MONOCHROME BUTTONS", x: 8, y: 0, role: .title)
            MK2ContentText("F1–F8: literal bytes. Find the visible threshold.", x: 8, y: 40, maxWidth: 450, color: Palette.dim, maxLines: 1)
            MK2AnyScreenElement { [base = monochromeBase] frame, _, _ in
                for index in 0..<8 {
                    let x = 16 + (index % 2) * 224
                    let y = 106 + (index / 2) * 28
                    let text = String(format: "F%d   0x%02X", index + 1, base + index)
                    BitmapLabel(text, font: .gridBold, color: Palette.text).draw(into: &frame, x: x, y: y)
                }
            }
            MK2EncoderDiscreteValuesElement(values)
        }.build(renderer: context.renderer)
    }

    private func hueScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        let start = ringBase
        return MK2RegularScreenDSL(
            header: .title(title: "4-D Ring Palette", subtitle: String(format: "Hue %02X · raw %02X...%02X", hue, start, start | 0x03)),
            footer: .hint("E2 selects hue; ring uses brightness 0–3")
        ) {
            MK2ContentText("COLOUR SLOT BYTE", x: 8, y: 0, role: .title)
            MK2ContentText("E2 sets hue; 4-D shows brightness 0...3.", x: 8, y: 40, maxWidth: 450, color: Palette.dim, maxLines: 1)
            MK2AnyScreenElement { [start] frame, _, _ in
                for (index, entry) in Self.ringLEDs.enumerated() {
                    let y = 114 + index * 28
                    let value = start | UInt8(index)
                    let text = String(format: "4-D %@   B%d   0x%02X", entry.label, index, value)
                    BitmapLabel(text, font: .gridBold, color: Palette.text).draw(into: &frame, x: 24, y: y)
                }
            }
        }.build(renderer: context.renderer)
    }

    private func encoderValues(_ context: LabContext) -> [MK2EncoderDiscreteValue] {
        [
            MK2EncoderDiscreteValue(
                encoder: 1,
                value: monochromeBank,
                bounds: 0...3,
                defaultValue: 0,
                display: encoderDisplay(label: "MONO", icon: MK2HIG.IconGlyph.sun, value: String(format: "%02X–%02X", monochromeBase, monochromeBase + 7), encoder: 1),
                onTouch: touch(1, context),
                onChange: { [weak self] value in
                    context.update { self?.monochromeBank = max(0, min(3, value)) }
                }
            ),
            MK2EncoderDiscreteValue(
                encoder: 2,
                value: hue,
                bounds: 0...63,
                defaultValue: 19,
                display: encoderDisplay(label: "HUE", icon: MK2HIG.IconGlyph.palette, value: String(format: "%02X", hue), encoder: 2),
                onTouch: touch(2, context),
                onChange: { [weak self] value in
                    context.update { self?.hue = max(0, min(63, value)) }
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
            rect: MK2ScreenLayout.encoderSlotRect(encoder - 1),
            isFocused: focusedEncoder == encoder,
            valueFont: .readoutBold,
            cornerRadius: 7,
            colors: labEditCellColors(value: Palette.text)
        )
    }
}
