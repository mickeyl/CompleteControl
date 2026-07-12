import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// The standardized header and ruler forms side by side (decision
/// 2026-07-12): the sanctioned set, each labeled with its origin — the
/// reference sheet for judging the forms on the OLEDs.
final class FormsDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "forms",
        title: "Header & Ruler Forms",
        category: .lookAndFeel,
        summary: "The sanctioned header and separator set",
        detail: "Left: the four header forms (chrome bands, full-screen status and title slots). Right: the separator forms R1-R4; vertical rulers stay a pattern-grid detail."
    )

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        MK2DoubleScreenDSL(
            left: headersScreen(context),
            right: rulersScreen(context)
        ).scene()
    }

    private func headersScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        let renderer = context.renderer
        let titleBand = MK2RegularScreenDSL(header: .title(title: "Title + Subtitle", subtitle: "TRAILING")) {}
            .build(renderer: renderer).screen.frame
        let statusBand = MK2RegularScreenDSL(header: .status([
            MK2StatusLineItem("STATUS", x: 8, color: Palette.blue),
            MK2StatusLineItem("ITEMS", x: 92, color: Palette.dim),
            MK2StatusLineItem("FIXED X POSITIONS", x: 196, color: Palette.text, font: .gridBold),
        ])) {}.build(renderer: renderer).screen.frame

        return MK2FullScreenDSL(
            background: Palette.page,
            header: .status([
                MK2StatusLineItem("HEADER FORMS", x: 8, color: Palette.blue),
                MK2StatusLineItem("H1-H4 · ORIGIN IN LABEL", x: 170, color: Palette.dim),
            ])
        ) {
            MK2AnyScreenElement { frame, _, _ in
                var y = 38
                func caption(_ text: String) {
                    BitmapLabel(text, font: .label, color: Palette.dim).draw(into: &frame, x: 8, y: y)
                    y += SurfaceFont.label.cellHeight + 2
                }

                caption("H1 CHROME BAND .TITLE — REGULAR SCREEN (BROWSER/METER)")
                frame.blit(titleBand.pixels(in: MK2PixelRect(x: 0, y: 0, width: 480, height: 30)), into: MK2PixelRect(x: 0, y: y, width: 480, height: 30))
                y += 36

                caption("H2 CHROME BAND .STATUS — REGULAR SCREEN")
                frame.blit(statusBand.pixels(in: MK2PixelRect(x: 0, y: 0, width: 480, height: 30)), into: MK2PixelRect(x: 0, y: y, width: 480, height: 30))
                y += 36

                caption("H3 FULLSCREEN HEADER .STATUS — FIXED-PITCH, header: SLOT")
                MK2StatusLine(y: y + 4, items: [
                    MK2StatusLineItem("PAT 00", x: 8, color: Palette.blue),
                    MK2StatusLineItem("ROW 1F", x: 120, color: Palette.text, font: .gridBold),
                    MK2StatusLineItem("PLAY", x: 230, color: Palette.green),
                ]).draw(into: &frame)
                frame.hline(y: y + 24, x: 0, width: MK2PixelFrame.width, color: MK2HIG.Chrome.border)
                y += 32

                caption("H4 FULLSCREEN HEADER .TITLE — PROPORTIONAL, header: SLOT")
                if let renderer {
                    try? renderer.drawText(
                        "PULSE LEAD", into: &frame, x: 8, y: y + 2,
                        style: MK2HIG.textStyle(weight: MK2HIG.Fonts.titleWeight, pixelSize: 15, color: Palette.blue),
                        maxWidth: 330
                    )
                    try? renderer.drawText(
                        "EDIT 04 SAMPLE", into: &frame, x: 344, y: y + 4,
                        style: MK2HIG.textStyle(weight: MK2HIG.Fonts.bodyWeight, pixelSize: MK2HIG.Typography.captionPixelSize, color: Palette.dim),
                        maxWidth: 128
                    )
                }
            }
        }.build(renderer: renderer)
    }

    private func rulersScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(
            background: Palette.page,
            header: .status([
                MK2StatusLineItem("RULER FORMS", x: 8, color: Palette.blue),
                MK2StatusLineItem("R1-R4 · VERTICAL: PATTERN GRID", x: 170, color: Palette.dim),
            ])
        ) {
            MK2AnyScreenElement { frame, _, _ in
                var y = 38
                func caption(_ text: String) {
                    BitmapLabel(text, font: .label, color: Palette.dim).draw(into: &frame, x: 8, y: y)
                    y += SurfaceFont.label.cellHeight + 2
                }

                caption("R1 SEPARATOR .LINE (BORDER)")
                frame.hline(y: y + 3, x: 0, width: MK2PixelFrame.width, color: MK2HIG.Chrome.border)
                y += 14

                caption("R2 SEPARATOR .ACCENT — EMPHASIZED SEPARATION")
                frame.hline(y: y + 3, x: 0, width: MK2PixelFrame.width, color: MK2HIG.Chrome.accent)
                y += 14

                caption("R3 SEPARATOR .BANDEDGE — BEVEL OVER SHADOW, 2PX")
                frame.hline(y: y + 3, x: 0, width: MK2PixelFrame.width, color: MK2HIG.Chrome.headerTopLine)
                frame.hline(y: y + 4, x: 0, width: MK2PixelFrame.width, color: MK2HIG.Chrome.headerBottomLine)
                y += 16

                caption("R4 SEPARATOR .DOTTED — LIGHTEST TOUCH")
                frame.dottedHLine(y: y + 3, color: MK2HIG.Chrome.dim)
                y += 14

                caption("V1 DOTTED VERTICAL — CHANNEL RULERS (PATTERN GRID ONLY)")
                for column in 0..<4 {
                    frame.dottedVLine(x: 40 + column * 120, y: y + 4, height: 52, color: Palette.border)
                }
                BitmapLabel("CHANNEL 1", font: .label, color: Palette.dim).draw(into: &frame, x: 48, y: y + 8)
                BitmapLabel("CHANNEL 2", font: .label, color: Palette.dim).draw(into: &frame, x: 168, y: y + 8)
            }
        }.build(renderer: context.renderer)
    }
}
