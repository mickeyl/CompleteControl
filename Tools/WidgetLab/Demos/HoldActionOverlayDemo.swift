import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// Demonstrates the momentary two-screen action layer intended for the
/// MASCHINE MK3 KEYBOARD + F1-F8 root-octave picker.
final class HoldActionOverlayDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "hold-action-overlay",
        title: "Hold Action Overlay",
        category: .catalogue,
        summary: "Held-button takeover with F1-F8 choices",
        detail: "Hold the MASCHINE KEYBOARD button to replace both displays. F1-F8 select a root octave immediately; releasing KEYBOARD restores the base scene.",
        snapshotVariants: ["octave-5"]
    )

    private var octave = 2
    private var outcome = "Default C2 matches the current MK3 pad range"

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        let overlay = MK2HoldActionOverlayElement(
            trigger: .keyboard,
            title: "Root Octave",
            helpText: "Press F1-F8 to choose the common note-input octave. New pad strikes use the new range immediately; release KEYBOARD to return.",
            actions: (0...7).map(Self.octaveAction),
            selectedIndex: octave,
            onSelect: { [weak self] index in
                context.update { [weak self] in
                    self?.octave = index
                    self?.outcome = "Selected Oct \(index) from F\(index + 1)"
                }
            }
        ).build(renderer: context.renderer)

        return MK2DoubleScreenDSL(
            left: explainerScreen(context),
            right: stateScreen(context),
            heldButtonLayers: [overlay]
        ).scene()
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

    private func explainerScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(
            header: .title(title: "Hold Overlay", subtitle: "KEYBOARD + F1-F8"),
            footer: .hint("MASCHINE MK3 · hold KEYBOARD to inspect")
        ) {
            MK2ContentText("Momentary action layer", x: 8, y: 4, role: .title)
            MK2ContentText(
                "The held button replaces both screens and owns the eight function keys without creating a persistent mode.",
                x: 8,
                y: 46,
                maxWidth: 432,
                color: Palette.dim,
                maxLines: 4,
                lineSpacing: 2
            )
            MK2ContentText(
                "KEYBOARD itself is advertised dim and lights brightly while the overlay is active.",
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
}
