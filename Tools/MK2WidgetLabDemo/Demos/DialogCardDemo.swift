import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// The inline action-dialog card and its icon-size sweep: judging the global
/// dialog look (Phosphor icon, title, body, action row) against candidate
/// contents and sizes. INSTANCE cycles the candidate, PAGE browses icons,
/// PRESET steps through the size sweep.
final class DialogCardDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "dialog-card",
        title: "Dialog Card",
        category: .lookAndFeel,
        summary: "Action dialog look and icon sizes",
        detail: "The dialog card with candidate contents and the icon-size sweep. INSTANCE cycles the candidate, PAGE browses icons, PRESET steps the size."
    )

    private struct Candidate: Sendable {
        let title: String
        let body: String
        let action: String
    }

    private static let candidates = [
        Candidate(title: "Load Instrument?", body: "Replace the current sound and keep pattern data.", action: "LOAD"),
        Candidate(title: "Clear Pattern?", body: "This removes all notes in the selected pattern.", action: "CLEAR"),
        Candidate(title: "Save Snapshot", body: "Write the current display pair as a PNG reference.", action: "SAVE"),
        Candidate(title: "Leave Browser?", body: "Return to the tracker without changing selection.", action: "LEAVE"),
    ]

    private static let sizes = [20, 24, 28, 32, 36, 42, 48, 56, 64, 72, 88]
    private static let dialogIconSize = MK2HIG.Typography.actionDialogIconPixelSize

    private let iconSource: String
    private let icons: [PhosphorIcon]
    private var iconIndex: Int
    private var candidateIndex = 0
    private var sizeIndex = 7

    init() {
        let catalog = (try? PhosphorIconCatalog.load()) ?? (source: "Phosphor catalog unavailable", icons: [])
        iconSource = catalog.source
        icons = catalog.icons
        iconIndex = catalog.icons.firstIndex { $0.name == "info" } ?? 0
    }

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        var scene = MK2SurfaceScene2(
            left: cardFrame(context.renderer),
            right: sweepFrame(context.renderer),
            lamps: [
                .instance: .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01),
                .pageLeft: .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01),
                .pageRight: .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01),
            ]
        )
        scene.bindings.onPress(.instance) { [weak self] in
            context.update {
                guard let self else { return }
                self.candidateIndex = (self.candidateIndex + 1) % Self.candidates.count
            }
        }
        scene.bindings.onPress(.pageLeft) { [weak self] in
            context.update { self?.moveIcon(-1) }
        }
        scene.bindings.onPress(.pageRight) { [weak self] in
            context.update { self?.moveIcon(1) }
        }
        MK2ButtonRangeSelection(
            value: sizeIndex,
            bounds: 0...(Self.sizes.count - 1),
            previousButton: .presetDown,
            nextButton: .presetUp,
            availableLamp: .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01)
        ) { [weak self] index in
            context.update { self?.sizeIndex = max(0, min(Self.sizes.count - 1, index)) }
        }
        .apply(lamps: &scene.lamps, bindings: &scene.bindings)
        return scene
    }

    private var selectedIcon: PhosphorIcon? {
        icons.indices.contains(iconIndex) ? icons[iconIndex] : nil
    }

    private var currentSize: Int {
        Self.sizes[max(0, min(Self.sizes.count - 1, sizeIndex))]
    }

    private func moveIcon(_ delta: Int) {
        guard !icons.isEmpty else { return }
        iconIndex = (iconIndex + delta).wrapped(to: 0...(icons.count - 1))
    }

    private func cardFrame(_ renderer: FreeTypeTextRenderer?) -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        let candidate = Self.candidates[candidateIndex]
        drawHeader(into: &frame, title: "DIALOG CARD", subtitle: "Phosphor Regular, icon 48 px")
        // Icon-on-top variant of the same Kit dialog card as the type-specimen demo.
        MK2DialogCard(
            rect: MK2PixelRect(x: 46, y: 56, width: 388, height: 172),
            iconGlyph: selectedIcon?.glyph,
            iconColor: Palette.accent,
            iconSize: Self.dialogIconSize,
            iconPlacement: .top,
            title: candidate.title,
            body: candidate.body,
            footnote: "[\(candidate.action)]        CANCEL",
            colors: MK2DialogCardColors(
                surface: Palette.dialogSurface,
                border: Palette.border,
                title: Palette.text,
                body: Palette.dim,
                footnote: Palette.text
            )
        ).draw(into: &frame, renderer: renderer)
        drawFreeTypeBody("PAGE browses icons. PRESET steps the size. INSTANCE cycles content.", into: &frame, renderer: renderer, x: 18, y: 246, size: MK2HIG.Typography.bodyPixelSize, color: Palette.empty, maxWidth: 432)
        return frame
    }

    private func sweepFrame(_ renderer: FreeTypeTextRenderer?) -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        drawHeader(into: &frame, title: "SIZE SWEEP", subtitle: "global action style")
        guard let icon = selectedIcon else {
            drawFreeTypeBody(iconSource, into: &frame, renderer: renderer, x: 18, y: 58, size: MK2HIG.Typography.bodyPixelSize, color: Palette.orange, maxWidth: 432)
            return frame
        }
        drawFreeTypeTitle("Current Icon", into: &frame, renderer: renderer, x: 18, y: 58, size: MK2HIG.Typography.titlePixelSize, color: Palette.text, maxWidth: 432)
        drawFreeTypeBody(icon.name, into: &frame, renderer: renderer, x: 18, y: 94, size: MK2HIG.Typography.bodyPixelSize, color: Palette.dim, maxWidth: 300)
        drawFreeTypeBody(String(format: "Phosphor  U+%04X  action 48 px", icon.codepoint), into: &frame, renderer: renderer, x: 18, y: 122, size: MK2HIG.Typography.bodyPixelSize, color: Palette.dim, maxWidth: 420)
        var x = 18
        for size in [24, 32, 42, 56, 72] {
            let item = MK2PixelRect(x: x - 3, y: 158, width: 58, height: 74)
            if size == currentSize { frame.stroke(item, Palette.accent) }
            drawFreeTypeIconCentered(icon.glyph, into: &frame, renderer: renderer, centerX: x + 25, y: 164, size: size, color: Palette.text)
            drawFreeTypeBody("\(size)", into: &frame, renderer: renderer, x: x + 9, y: 216, size: 14, color: size == currentSize ? Palette.text : Palette.empty, maxWidth: 46)
            x += 84
        }
        drawFreeTypeBody(iconSource, into: &frame, renderer: renderer, x: 18, y: 248, size: MK2HIG.Typography.bodyPixelSize, color: Palette.empty, maxWidth: 432)
        return frame
    }

    private func drawHeader(into frame: inout MK2PixelFrame, title: String, subtitle: String) {
        frame.fill(MK2PixelRect(x: 0, y: 0, width: MK2PixelFrame.width, height: 38), 0x0000)
        BitmapLabel(title, font: .gridBold, color: Palette.accent).draw(into: &frame, x: 8, y: 8)
        BitmapLabel(subtitle.uppercased(), font: .label, color: Palette.dim).draw(into: &frame, x: 8, y: 25)
    }
}
