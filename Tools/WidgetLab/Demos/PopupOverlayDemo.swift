import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// Catalogue reference for passive two-screen popups over a preserved scene.
final class PopupOverlayDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "popup-overlay",
        title: "Popup Overlay",
        category: .catalogue,
        summary: "Passive prompt over a half-dimmed scene",
        detail: "The reusable popup targets the left display, right display, or both while dimming only its target to 50%. F1 cycles the display mode; F2 toggles the captured state.",
        snapshotVariants: ["left", "right", "both"]
    )

    private var captured = false
    private var displayMode = MK2PopupOverlayDisplayMode.both

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        var scene = MK2DoubleScreenDSL(
            left: baseScreen(title: "Instrument", value: "ROOT C-4", context: context),
            right: baseScreen(title: "Tuning", value: "FINE 0ct", context: context)
        ).scene()
        scene.lamps[.function1] = .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01)
        scene.lamps[.function2] = .on(KKRGB(red: 0x38, green: 0xa8, blue: 0xff), intensity: 0x01)
        scene.bindings.onPress(.function1) { [weak self] in
            context.update { [weak self] in
                self?.cycleDisplayMode()
            }
        }
        scene.bindings.onPress(.function2) { [weak self] in
            context.update { [weak self] in
                self?.captured.toggle()
            }
        }

        MK2PopupOverlayElement(
            left: displayMode == .right ? nil : MK2PopupOverlayContent(
                title: "MIDI Input",
                body: "Play a key to set the tuning root."
            ),
            right: displayMode == .left ? nil : MK2PopupOverlayContent(
                title: captured ? "Input Captured" : "Waiting for Input",
                body: captured ? "Captured: C-4" : "Play or move the requested MIDI control.",
                footnote: "F1 display / F2 state"
            )
        ).apply(to: &scene, renderer: context.renderer)
        return scene
    }

    func prepareSnapshot(variant: String) {
        displayMode = MK2PopupOverlayDisplayMode(rawValue: variant) ?? .both
        captured = false
    }

    func testState() -> String? {
        "popup=\(captured ? "captured" : "waiting") displays=\(displayMode.rawValue) dim=50%"
    }

    private func cycleDisplayMode() {
        switch displayMode {
        case .left: displayMode = .right
        case .right: displayMode = .both
        case .both: displayMode = .left
        }
    }

    private func baseScreen(
        title: String,
        value: String,
        context: LabContext
    ) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(
            background: Palette.page,
            header: .status([
                MK2StatusLineItem(title.uppercased(), x: 8, color: Palette.blue),
                MK2StatusLineItem("BASE SCENE", x: 280, color: Palette.dim),
            ])
        ) {
            MK2ContentText(value, x: 12, y: 70, role: .title, color: Palette.text, relativeToContent: false)
            MK2ContentText(
                "Bright content around the card makes the exact 50% background dimming easy to judge.",
                x: 12,
                y: 126,
                maxWidth: 440,
                color: Palette.text,
                relativeToContent: false,
                maxLines: 4,
                lineSpacing: 2
            )
        }.build(renderer: context.renderer)
    }
}
