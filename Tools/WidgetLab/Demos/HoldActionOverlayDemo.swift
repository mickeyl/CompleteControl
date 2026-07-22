import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// HIG reference for both held popup semantics: a persistent setting popup and
/// an immediate command popup that preserves the active scene.
final class HoldActionOverlayDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "hold-action-overlay",
        title: "Hold Popups",
        category: .catalogue,
        summary: "Persistent setting and immediate command",
        detail: "Hold KEY MODE on KOMPLETE or KEYBOARD on MASCHINE for the persistent octave setting popup. Hold PATTERN for the immediate F1-F8 command popup.",
        snapshotVariants: ["octave-5"]
    )

    private var octave = 2
    private var outcome = "Default C2 matches the current MK3 pad range"

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        let settingTrigger = settingTrigger(for: context.deviceFamily)
        let settingTriggerLabel = settingTriggerLabel(for: context.deviceFamily)
        let left = explainerScreen(settingTriggerLabel: settingTriggerLabel, context: context)
        let right = stateScreen(context)
        let overlay = MK2HoldActionOverlayElement(
            trigger: settingTrigger,
            triggerLabel: settingTriggerLabel,
            title: "Root Octave",
            helpText: "Press F1-F8 to choose the common note-input octave. New notes use the new range immediately; release \(settingTriggerLabel) to return.",
            actions: (0...7).map(Self.octaveAction),
            selectedIndex: octave,
            onSelect: { [weak self] index in
                context.update { [weak self] in
                    self?.octave = index
                    self?.outcome = "Selected Oct \(index) from F\(index + 1)"
                }
            }
        ).build(renderer: context.renderer)
        let commandBar = referenceCommandBar(
            left: left,
            right: right,
            context: context
        )

        return MK2DoubleScreenDSL(
            left: left,
            right: right,
            heldButtonLayers: [commandBar, overlay]
        ).scene()
    }

    /// Copyable integration pattern: render both base screens first, then
    /// pre-compose their current frames into the held command layer.
    private func referenceCommandBar(
        left: MK2ScreenBuildResult,
        right: MK2ScreenBuildResult,
        context: LabContext
    ) -> MK2SurfaceScene2.HeldButtonLayer {
        MK2HoldCommandBarElement(
            trigger: .pattern,
            title: "Arrangement Commands",
            actions: [
                MK2HoldAction("NEW", detail: "Blank pattern"),
                MK2HoldAction("DUP", detail: "Independent copy"),
                MK2HoldAction("REUSE", detail: "Linked data"),
                MK2HoldAction("CLEAR", detail: "Erase all events", isDestructive: true),
                MK2HoldAction("MOVE-", detail: "Earlier position", isEnabled: false),
                MK2HoldAction("MOVE+", detail: "Later position"),
                MK2HoldAction(""), // Reserve F7 without shifting DEL POS to F7.
                MK2HoldAction("DEL POS", detail: "Keep pattern data", isDestructive: true),
            ],
            onSelect: { [weak self] index in
                context.update { [weak self] in
                    self?.outcome = "Selected arrangement command F\(index + 1)"
                }
            }
        ).build(
            baseLeft: left.screen.frame,
            baseRight: right.screen.frame,
            renderer: context.renderer
        )
    }

    func prepareSnapshot(variant: String) {
        switch variant {
            case "octave-5":
                octave = 5
                outcome = "Selected Oct 5 from F6"
            default:
                octave = 2
                outcome = "Default C2 matches the current MK3 pad range"
        }
    }

    func testState() -> String? {
        "octave=\(octave) range=C\(octave)-D#\(octave + 1)"
    }

    private func explainerScreen(
        settingTriggerLabel: String,
        context: LabContext
    ) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(
            header: .title(title: "Held Popups", subtitle: "SETTING / COMMAND"),
            footer: .hint("Hold \(settingTriggerLabel) for setting · PATTERN for command")
        ) {
            MK2ContentText("Choose by effect", x: 8, y: 4, role: .title)
            MK2ContentText(
                "\(settingTriggerLabel) changes a persistent octave setting. PATTERN performs one immediate arrangement command.",
                x: 8,
                y: 46,
                maxWidth: 432,
                color: Palette.dim,
                maxLines: 4,
                lineSpacing: 2
            )
            MK2ContentText(
                "Both popups own F1-F8 only while their trigger is held; release returns to the base scene.",
                x: 8,
                y: 146,
                maxWidth: 432,
                color: Palette.text,
                maxLines: 3,
                lineSpacing: 2
            )
        }.build(renderer: context.renderer)
    }

    private func stateScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(
            background: Palette.page,
            header: .status([
                MK2StatusLineItem("ROOT OCT", x: 8, color: Palette.blue),
                MK2StatusLineItem("\(octave)", x: 128, color: Palette.text, font: .gridBold),
                MK2StatusLineItem("C\(octave)-D#\(octave + 1)", x: 306, color: Palette.dim),
            ])
        ) {
            MK2ContentText("Current shared input range", x: 8, y: 50, role: .caption, color: Palette.dim, relativeToContent: false)
            MK2ContentText("C\(octave)", x: 8, y: 82, role: .custom(weight: MK2HIG.Fonts.titleWeight, pixelSize: 46), color: Palette.text, relativeToContent: false)
            MK2ContentText("Pads C\(octave)-D#\(octave + 1)", x: 8, y: 148, maxWidth: 432, color: Palette.blue, relativeToContent: false)
            MK2ContentText(outcome, x: 8, y: 194, maxWidth: 432, role: .footnote, color: Palette.dim, relativeToContent: false, maxLines: 2, lineSpacing: 2)
        }.build(renderer: context.renderer)
    }

    private static func octaveAction(_ octave: Int) -> MK2HoldAction {
        MK2HoldAction(
            "OCT \(octave)",
            value: "C\(octave)",
            detail: "Chromatic pads C\(octave)-D#\(octave + 1)"
        )
    }

    private func settingTrigger(for family: KontrolDeviceFamily) -> KKMK2ButtonLED {
        family == .maschineMK3 ? .keyboard : .keyMode
    }

    private func settingTriggerLabel(for family: KontrolDeviceFamily) -> String {
        family == .maschineMK3 ? "KEYBOARD" : "KEY MODE"
    }
}
