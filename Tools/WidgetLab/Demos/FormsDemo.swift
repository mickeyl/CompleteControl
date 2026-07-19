import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// The sanctioned chrome forms — headers, function bars, separators and the
/// tag pill — each rendered *where it belongs* rather than stacked as a
/// sample sheet: a header is a real header at the top, a function bar sits
/// top-flush, separators run as real rules in the content. INSTANCE cycles
/// the pages.
final class FormsDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "forms",
        title: "Chrome Forms",
        category: .lookAndFeel,
        summary: "Headers, function bars, separators, tag",
        detail: "Matched header/bar pairs first, so a chrome header on the left and its matching function bar on the right read as one strip; then the individual header, separator and tag forms. INSTANCE cycles the pages.",
        snapshotVariants: ["matched-flat", "chrome-headers", "fullscreen-headers", "separators"]
    )

    private enum Page: Int, CaseIterable {
        case matchedRaised, matchedFlat, chromeHeaders, fullscreenHeaders, separators
        var next: Page { Self(rawValue: (rawValue + 1) % Self.allCases.count)! }
    }

    private var page: Page = .matchedRaised
    private var functionSlotAvailability = [true, false, true, false]

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        var scene = MK2DoubleScreenDSL(
            left: leftScreen(context),
            right: rightScreen(context)
        ).scene()
        scene.lamps[.instance] = .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01)
        scene.bindings.onPress(.instance) { [weak self] in
            context.update { [weak self] in
                self?.page = self?.page.next ?? .chromeHeaders
            }
        }
        if page == .matchedRaised || page == .matchedFlat {
            for (index, button) in [KKMK2ButtonLED.function5, .function6, .function7, .function8].enumerated() {
                scene.bindings.onPress(button) { [weak self] in
                    context.update { [weak self] in
                        guard let self else { return }
                        self.functionSlotAvailability[index].toggle()
                    }
                }
            }
        }
        return scene
    }

    func prepareSnapshot(variant: String) {
        switch variant {
            case "matched-flat": page = .matchedFlat
            case "chrome-headers": page = .chromeHeaders
            case "fullscreen-headers": page = .fullscreenHeaders
            case "separators": page = .separators
            default: page = .matchedRaised
        }
    }

    private var pageIndex: String { "\(page.rawValue + 1)/\(Page.allCases.count)" }

    // MARK: - Left screen

    private func leftScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        switch page {
            case .matchedRaised: matchedHeaderRaised(context)
            case .matchedFlat: matchedHeaderFlat(context)
            case .chromeHeaders: chromeTitleHeader(context)
            case .fullscreenHeaders: fullscreenStatusHeader(context)
            case .separators: separators(context)
        }
    }

    private func rightScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        switch page {
            case .matchedRaised: functionBar(context, style: .chromeBand, side: .right, title: "Right · chrome-band bar", note: "Raised chips at chrome-header height — the top edge should run unbroken from the header on the left.")
            case .matchedFlat: functionBar(context, style: .plain, side: .right, title: "Right · plain bar", note: "Flat strip — pairs with the flat status header on the left.")
            case .chromeHeaders: chromeStatusHeader(context)
            case .fullscreenHeaders: fullscreenTitleHeader(context)
            case .separators: tags(context)
        }
    }

    // MARK: - Matched pairs (pages 1-2): header left, matching bar right

    private func matchedHeaderRaised(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(
            header: .status([
                MK2StatusLineItem("BROWSE", x: 8, color: Palette.blue),
                MK2StatusLineItem("FACTORY", x: 100, color: Palette.dim),
                MK2StatusLineItem("48 MB", x: 384, color: Palette.dim),
            ]),
            footer: .hint("Matched raised · page \(pageIndex)")
        ) {
            MK2ContentText("Left · chrome-band header", x: 8, y: 4, role: .title)
            MK2ContentText("A raised chrome header. Its top edge should line up with the chrome-band function bar on the right — same height, same bevel, one continuous strip across the pair.", x: 8, y: 44, maxWidth: 432, color: Palette.dim, maxLines: 4, lineSpacing: 2)
        }.build(renderer: context.renderer)
    }

    private func matchedHeaderFlat(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(
            background: Palette.page,
            header: .status([
                MK2StatusLineItem("PAT 00", x: 8, color: Palette.blue),
                MK2StatusLineItem("ROW 1F", x: 120, color: Palette.text, font: .gridBold),
                MK2StatusLineItem("PLAY", x: 230, color: Palette.green),
            ])
        ) {
            MK2ContentText("Left · flat status header (rule, no band). Pairs with the plain flat function bar on the right — judge whether the two flat top zones sit at a matching height.", x: 8, y: 44, maxWidth: 432, color: Palette.dim, maxLines: 4, lineSpacing: 2)
            MK2ContentText("Matched flat · page \(pageIndex)", x: 8, y: 250, maxWidth: 432, color: Palette.empty)
        }.build(renderer: context.renderer)
    }

    // MARK: - Chrome headers (page 1)

    private func chromeTitleHeader(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(
            header: .title(title: "Chrome Band · .title", subtitle: "REGULAR"),
            footer: .hint("INSTANCE cycles the forms · page \(pageIndex)")
        ) {
            MK2ContentText("Header .title", x: 8, y: 4, role: .title)
            MK2ContentText("A raised chrome band with a leading proportional title and a trailing subtitle — the browser, meter and instrument header.", x: 8, y: 44, maxWidth: 432, color: Palette.dim, maxLines: 3, lineSpacing: 2)
        }.build(renderer: context.renderer)
    }

    private func chromeStatusHeader(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(
            header: .status([
                MK2StatusLineItem("STATUS", x: 8, color: Palette.blue),
                MK2StatusLineItem("ITEMS", x: 92, color: Palette.dim),
                MK2StatusLineItem("FIXED X", x: 196, color: Palette.text, font: .gridBold),
            ]),
            footer: .hint("INSTANCE cycles the forms · page \(pageIndex)")
        ) {
            MK2ContentText("Header .status", x: 8, y: 4, role: .title)
            MK2ContentText("The same raised band with fixed-pitch status items at fixed x positions — the dense readout header.", x: 8, y: 44, maxWidth: 432, color: Palette.dim, maxLines: 3, lineSpacing: 2)
        }.build(renderer: context.renderer)
    }

    // MARK: - Full-screen headers (page 2)

    private func fullscreenStatusHeader(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(
            background: Palette.page,
            header: .status([
                MK2StatusLineItem("PAT 00", x: 8, color: Palette.blue),
                MK2StatusLineItem("ROW 1F", x: 120, color: Palette.text, font: .gridBold),
                MK2StatusLineItem("PLAY", x: 230, color: Palette.green),
            ])
        ) {
            MK2ContentText("The header above is the form: full-screen .status — fixed-pitch items with a border rule, no chrome band. The tracker/pattern top.", x: 8, y: 44, maxWidth: 432, color: Palette.dim, maxLines: 3, lineSpacing: 2)
            MK2ContentText("INSTANCE cycles the forms · page \(pageIndex)", x: 8, y: 250, maxWidth: 432, color: Palette.empty)
        }.build(renderer: context.renderer)
    }

    private func fullscreenTitleHeader(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(
            background: Palette.page,
            header: .title("Pulse Lead", caption: "EDIT 04 SAMPLE", color: Palette.blue)
        ) {
            MK2ContentText("The header above is the form: full-screen .title — a proportional leading title with a trailing caption. The instrument editor top.", x: 8, y: 44, maxWidth: 432, color: Palette.dim, maxLines: 3, lineSpacing: 2)
            MK2ContentText("INSTANCE cycles the forms · page \(pageIndex)", x: 8, y: 250, maxWidth: 432, color: Palette.empty)
        }.build(renderer: context.renderer)
    }

    // MARK: - Function bars (page 3)

    private func functionBar(_ context: LabContext, style: MK2FunctionKeyBarElement.Style, side: MK2FunctionKeyBarElement.Side = .left, title: String, note: String) -> MK2ScreenBuildResult {
        let contentTop = (style == .plain ? MK2FunctionKeyBarElement.plainHeight : MK2FunctionKeyBarElement.chromeBandHeight) + 12
        return MK2FullScreenDSL(background: Palette.page) {
            MK2FunctionKeyBarElement(
                slots: [
                    MK2FunctionKeySlot("COPY", iconGlyph: MK2HIG.IconGlyph.copy, isEnabled: functionSlotAvailability[0]),
                    MK2FunctionKeySlot("PASTE", iconGlyph: MK2HIG.IconGlyph.clipboard, isEnabled: functionSlotAvailability[1]),
                    MK2FunctionKeySlot("CLEAR", iconGlyph: MK2HIG.IconGlyph.eraser, isEnabled: functionSlotAvailability[2]),
                    MK2FunctionKeySlot("TRIM", iconGlyph: MK2HIG.IconGlyph.crop, isEnabled: functionSlotAvailability[3]),
                ],
                side: side,
                style: style
            )
            MK2AnyScreenElement { frame, elementContext, _ in
                BitmapLabel(title.uppercased(), font: .gridBold, color: Palette.blue).draw(into: &frame, x: 8, y: contentTop)
                _ = drawFreeTypeBody(note, into: &frame, renderer: elementContext.renderer, x: 8, y: contentTop + 22, size: MK2HIG.Typography.bodyPixelSize, color: Palette.dim, maxWidth: 432, maxLines: 3)
                BitmapLabel("F5-F8 TOGGLE AVAILABILITY · PAGE \(self.pageIndex)", font: .label, color: Palette.empty).draw(into: &frame, x: 8, y: 250)
            }
        }.build(renderer: context.renderer)
    }

    // MARK: - Separators (page 4, left) and tags (page 4, right)

    private func separators(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(
            background: Palette.page,
            header: .status([
                MK2StatusLineItem("SEPARATORS", x: 8, color: Palette.blue),
                MK2StatusLineItem("R1-R4", x: 130, color: Palette.dim),
            ])
        ) {
            MK2AnyScreenElement { frame, _, _ in
                var y = 40
                func caption(_ text: String) {
                    BitmapLabel(text, font: .label, color: Palette.dim).draw(into: &frame, x: 8, y: y)
                    y += SurfaceFont.label.cellHeight + 2
                }
                caption("R1 .LINE (BORDER)")
                frame.hline(y: y + 3, x: 0, width: MK2PixelFrame.width, color: MK2HIG.Chrome.border)
                y += 18
                caption("R2 .ACCENT — EMPHASIZED")
                frame.hline(y: y + 3, x: 0, width: MK2PixelFrame.width, color: MK2HIG.Chrome.accent)
                y += 18
                caption("R3 .BANDEDGE — BEVEL OVER SHADOW")
                frame.hline(y: y + 3, x: 0, width: MK2PixelFrame.width, color: MK2HIG.Chrome.headerTopLine)
                frame.hline(y: y + 4, x: 0, width: MK2PixelFrame.width, color: MK2HIG.Chrome.headerBottomLine)
                y += 20
                caption("R4 .DOTTED — LIGHTEST TOUCH")
                frame.dottedHLine(y: y + 3, color: MK2HIG.Chrome.dim)
                y += 18
                caption("V1 DOTTED VERTICAL — CHANNEL RULERS (PATTERN GRID)")
                for column in 0..<4 {
                    frame.dottedVLine(x: 40 + column * 120, y: y + 4, height: 44, color: Palette.border)
                }
                BitmapLabel("CHANNEL 1", font: .label, color: Palette.dim).draw(into: &frame, x: 48, y: y + 8)
                BitmapLabel("CHANNEL 2", font: .label, color: Palette.dim).draw(into: &frame, x: 168, y: y + 8)
            }
        }.build(renderer: context.renderer)
    }

    private func tags(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(
            background: Palette.page,
            header: .status([
                MK2StatusLineItem("TAG PILL", x: 8, color: Palette.blue),
                MK2StatusLineItem("T1", x: 110, color: Palette.dim),
            ])
        ) {
            MK2ContentText("Subtle gradient, antialiased ends, self-sizing to the text with an optional minimum width.", x: 8, y: 44, maxWidth: 432, color: Palette.dim, maxLines: 2, lineSpacing: 2)
            MK2TagElement("SAMPLE", x: 8, y: 96, minWidth: 96)
            MK2TagElement("WAVETABLE", x: 116, y: 96)
            MK2TagElement("MUTED", x: 232, y: 96, colors: MK2TagColors(text: Palette.mute))
            MK2TagElement("OK", x: 314, y: 96, colors: MK2TagColors(text: Palette.green))
            MK2ContentText("INSTANCE cycles the forms · page \(pageIndex)", x: 8, y: 150, maxWidth: 432, color: Palette.empty)
        }.build(renderer: context.renderer)
    }
}
