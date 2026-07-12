import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// The regular-screen chrome combinations: header and footer slot variants
/// with live progress and typography knobs. INSTANCE cycles the combination;
/// the left screen visualizes the resulting layout rects, the right screen
/// carries the encoder values.
final class ChromeSlotsDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "chrome-slots",
        title: "Chrome Slots",
        category: .lookAndFeel,
        summary: "Header/footer chrome combinations",
        detail: "Six header and footer slot combinations of the regular screen. INSTANCE cycles them; E5-E8 drive progress placement and value plus caption and footnote sizes.",
        snapshotVariants: ["title-none", "title-hint", "title-encoders", "status-filters", "none-none", "none-encoders"]
    )

    private enum Combo: Int, CaseIterable {
        case titleOnly, titleHint, titleEncoders, statusFilters, bare, footerOnly

        var next: Combo { Self(rawValue: (rawValue + 1) % Self.allCases.count)! }

        var title: String {
            switch self {
                case .titleOnly: "TITLE + NONE"
                case .titleHint: "TITLE + HINT"
                case .titleEncoders: "TITLE + ENCODERS"
                case .statusFilters: "STATUS + FILTERS"
                case .bare: "NONE + NONE"
                case .footerOnly: "NONE + ENCODERS"
            }
        }

        var header: MK2ScreenHeader {
            switch self {
                case .titleOnly, .titleHint, .titleEncoders:
                    .title(title: "Scene Lab", subtitle: "Chrome Slots")
                case .statusFilters:
                    .status([
                        MK2StatusLineItem("SCENE", x: 8, color: Palette.blue),
                        MK2StatusLineItem("CHROME", x: 92, color: Palette.dim),
                        MK2StatusLineItem("STATUS HEADER", x: 196, color: Palette.text, font: .gridBold),
                    ])
                case .bare, .footerOnly:
                    .none
            }
        }

        var footer: MK2ScreenFooter {
            switch self {
                case .titleOnly, .bare: .none
                case .titleHint: .hint("4-D confirms, INSTANCE cycles the combination.")
                case .titleEncoders, .footerOnly: .encoderArea()
                case .statusFilters: .filters()
            }
        }

        var headerLabel: String {
            switch self {
                case .titleOnly, .titleHint, .titleEncoders: "TITLE"
                case .statusFilters: "STATUS"
                case .bare, .footerOnly: "NONE"
            }
        }

        var footerLabel: String {
            switch self {
                case .titleOnly, .bare: "NONE"
                case .titleHint: "HINT"
                case .titleEncoders, .footerOnly: "ENCODER"
                case .statusFilters: "FILTERS"
            }
        }
    }

    private var combo: Combo = .titleHint
    private var progressMode = 1
    private var progressPercent = 42
    private var captionSize = MK2HIG.Typography.captionPixelSize
    private var footnoteSize = MK2HIG.Typography.footnotePixelSize
    private var focusedEncoder: Int?

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        var scene = MK2DoubleScreenDSL(
            left: layoutScreen(context),
            right: controlScreen(context)
        ).scene()
        scene.lamps[.instance] = .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01)
        scene.bindings.onPress(.instance) { [weak self] in
            context.update { self?.combo = self?.combo.next ?? .titleHint }
        }
        return scene
    }

    func prepareSnapshot(variant: String) {
        let variants: [String: Combo] = [
            "title-none": .titleOnly, "title-hint": .titleHint,
            "title-encoders": .titleEncoders, "status-filters": .statusFilters,
            "none-none": .bare, "none-encoders": .footerOnly,
        ]
        combo = variants[variant] ?? .titleHint
    }

    private func progressBar() -> MK2ScreenProgressBar? {
        switch progressMode {
            case 1: MK2ScreenProgressBar(placement: .top, progress: Double(progressPercent) / 100.0)
            case 2: MK2ScreenProgressBar(placement: .bottom, progress: Double(progressPercent) / 100.0)
            default: nil
        }
    }

    private func progressLabel() -> String {
        switch progressMode {
            case 1: "TOP"
            case 2: "BTM"
            default: "OFF"
        }
    }

    private func layout() -> MK2RegularScreenLayout {
        MK2ScreenLayout.regular(
            header: combo.header,
            footer: combo.footer,
            progress: progressBar()?.placement,
            typography: MK2ScreenChromeTypography(captionPixelSize: captionSize, footnotePixelSize: footnoteSize)
        )
    }

    private func layoutScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        let combo = combo
        let layout = layout()
        let headerLine = "HEADER \(combo.headerLabel) \(layout.headerRect?.height ?? 0)  FOOTER \(combo.footerLabel) \(layout.footerRect?.height ?? 0)"
        let progressLine = progressMode == 0 ? "PROGRESS OFF" : "PROGRESS \(progressLabel()) \(progressPercent)%"
        let typoLine = "CAPTION \(captionSize)PX  FOOTNOTE \(footnoteSize)PX"
        let footerDisplays = (layout.footerRect?.height ?? 0) >= MK2ScreenLayout.encoderFooterHeight ? encoderDisplays() : []

        return MK2RegularScreenDSL(
            header: combo.header,
            footer: combo.footer,
            progress: progressBar(),
            typography: MK2ScreenChromeTypography(captionPixelSize: captionSize, footnotePixelSize: footnoteSize)
        ) {
            MK2AnyScreenElement { frame, context, _ in
                guard let layout = context.layout else { return }
                let content = layout.contentRect
                frame.stroke(content, Palette.border)
                let lines: [(String, SurfaceFont, UInt16)] = [
                    (combo.title, .gridBold, Palette.blue),
                    (headerLine, .grid, Palette.dim),
                    (progressLine, .grid, Palette.dim),
                    ("CONTENT \(content.x),\(content.y) \(content.width)*\(content.height)", .grid, Palette.text),
                    (typoLine, .grid, Palette.dim),
                ]
                var y = content.y + 6
                for (text, font, color) in lines {
                    guard y + font.cellHeight <= content.maxY else { break }
                    BitmapLabel(text, font: font, color: color)
                        .draw(into: &frame, x: content.x + 8, y: y, clip: content)
                    y += font.cellHeight + 4
                }
            }
            MK2EncoderFooterElement(footerDisplays)
        }.build(renderer: context.renderer)
    }

    private func controlScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        let combo = combo
        let layout = layout()
        let values = encoderValues(context)
        let summary: [(String, UInt16)] = [
            ("HEADER   \(combo.headerLabel) \(layout.headerRect?.height ?? 0)", Palette.text),
            ("FOOTER   \(combo.footerLabel) \(layout.footerRect?.height ?? 0)", Palette.text),
            ("PROGRESS \(progressLabel()) \(progressPercent)%", Palette.text),
            ("CONTENT  \(layout.contentRect.x),\(layout.contentRect.y) \(layout.contentRect.width)*\(layout.contentRect.height)", Palette.blue),
            ("INSTANCE CYCLES THE COMBINATION", Palette.dim),
            ("2xTAP AN ENCODER RESETS ITS VALUE", Palette.dim),
        ]

        var result = MK2FullScreenDSL(
            background: Palette.page,
            header: .status([
                MK2StatusLineItem("CHROME SLOTS", x: 8, color: Palette.blue),
                MK2StatusLineItem(combo.title, x: 170, color: Palette.text, font: .gridBold),
            ])
        ) {
            MK2AnyScreenElement { frame, _, _ in
                var y = 44
                for (text, color) in summary {
                    BitmapLabel(text, font: .grid, color: color).draw(into: &frame, x: 8, y: y)
                    y += SurfaceFont.grid.cellHeight + 6
                }
                for value in values {
                    value.drawDisplay(into: &frame)
                }
            }
        }.build(renderer: context.renderer)
        for value in values {
            value.apply(bindings: &result.bindings)
        }
        return result
    }

    private func encoderValues(_ context: LabContext) -> [MK2EncoderDiscreteValue] {
        let displays = encoderDisplays()
        return [
            MK2EncoderDiscreteValue(
                encoder: 5, value: progressMode, bounds: 0...2, defaultValue: 1, display: displays[0],
                onTouch: { [weak self] touched in context.update { self?.focus(5, touched) } },
                onChange: { [weak self] value in context.update { self?.progressMode = value.wrapped(to: 0...2) } }
            ),
            MK2EncoderDiscreteValue(
                encoder: 6, value: progressPercent, bounds: 0...100, step: 2, defaultValue: 42, display: displays[1],
                onTouch: { [weak self] touched in context.update { self?.focus(6, touched) } },
                onChange: { [weak self] value in context.update { self?.progressPercent = max(0, min(100, value)) } }
            ),
            MK2EncoderDiscreteValue(
                encoder: 7, value: captionSize, bounds: 10...24, defaultValue: MK2HIG.Typography.captionPixelSize, display: displays[2],
                onTouch: { [weak self] touched in context.update { self?.focus(7, touched) } },
                onChange: { [weak self] value in context.update { self?.captionSize = max(10, min(24, value)) } }
            ),
            MK2EncoderDiscreteValue(
                encoder: 8, value: footnoteSize, bounds: 10...24, defaultValue: MK2HIG.Typography.footnotePixelSize, display: displays[3],
                onTouch: { [weak self] touched in context.update { self?.focus(8, touched) } },
                onChange: { [weak self] value in context.update { self?.footnoteSize = max(10, min(24, value)) } }
            ),
        ]
    }

    private func focus(_ encoder: Int, _ touched: Bool) {
        if touched {
            focusedEncoder = encoder
        } else if focusedEncoder == encoder {
            focusedEncoder = nil
        }
    }

    private func encoderDisplays() -> [MK2EncoderDiscreteValueDisplay] {
        let entries: [(label: String, value: String, encoder: Int)] = [
            ("PROG", progressLabel(), 5),
            ("VALUE", "\(progressPercent)%", 6),
            ("CAPT", "\(captionSize)", 7),
            ("FOOT", "\(footnoteSize)", 8),
        ]
        return entries.enumerated().map { index, entry in
            MK2EncoderDiscreteValueDisplay(
                label: entry.label,
                value: entry.value,
                rect: MK2ScreenLayout.encoderSlotRect(index),
                isFocused: focusedEncoder == entry.encoder,
                valueFont: .readoutBold,
                cornerRadius: 7,
                colors: labEditCellColors(value: Palette.text)
            )
        }
    }
}
