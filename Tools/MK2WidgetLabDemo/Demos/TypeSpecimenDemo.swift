import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// Typography reference: the fixed-pitch SurfaceFont faces against the
/// proportional FreeType styles, plus a live dialog mock whose body, title
/// and icon sizes ride on E5-E8. INSTANCE toggles between the specimen and
/// the combination view. Some fixture strings deliberately stay German —
/// they exist to exercise umlauts and eszett.
final class TypeSpecimenDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "type-specimen",
        title: "Type Specimen",
        category: .lookAndFeel,
        summary: "SurfaceFont and FreeType side by side",
        detail: "Fixed-pitch faces, proportional styles, ligatures and a live dialog mock. E5-E8 drive body, title, icon and icon size; INSTANCE toggles specimen and combinations.",
        snapshotVariants: ["typography"]
    )

    private struct Sample: Sendable {
        let label: String
        let title: String
        let body: String
        let detail: String
    }

    private struct IconSample: Sendable {
        let name: String
        let glyph: String
        let color: UInt16
    }

    private static let samples = [
        Sample(
            label: "Dialog",
            title: "Clear pattern?",
            body: "This removes every note in the selected pattern.",
            detail: "4-D confirms, any other hardware button cancels."
        ),
        Sample(
            label: "Browser",
            title: "Instrument Browser",
            body: "Kick Resin, Snare Alloy, Hat Needle, Bass Rubber",
            detail: "Longer list text stays calm and readable."
        ),
        Sample(
            label: "Settings",
            title: "MIDI Routing",
            body: "Channel 3 receives live input and writes steps into pattern 03.",
            detail: "Body regular, titles medium, icons Phosphor."
        ),
        Sample(
            label: "German",
            title: "Globale Einstellungen",
            body: "Größen, Dicken und Umlaute prüfen: ÄÖÜ äöü ß.",
            detail: "Numbers and units: 120 BPM, 16 steps, 80 %."
        ),
    ]

    private static let iconSamples = [
        IconSample(name: "Info", glyph: "\u{e2ce}", color: Palette.blue),
        IconSample(name: "Warn", glyph: "\u{e4e0}", color: Palette.accent),
        IconSample(name: "Error", glyph: "\u{e4f8}", color: Palette.orange),
        IconSample(name: "Question", glyph: "\u{e3e8}", color: Palette.question),
        IconSample(name: "Save", glyph: "\u{e248}", color: Palette.green),
        IconSample(name: "Sliders", glyph: "\u{e432}", color: Palette.solo),
        IconSample(name: "Trash", glyph: "\u{e4a6}", color: Palette.mute),
    ]

    private static let bodyBounds = 12...22
    private static let titleBounds = 18...32
    private static let iconSizeBounds = 32...72

    private enum View { case specimen, typography }

    private var view: View = .specimen
    private var sampleText = "Paulinche 0123 ÄÖÜ"
    private var sampleIndex = 0
    private var bodyPixelSize = MK2HIG.Typography.bodyPixelSize
    private var titlePixelSize = MK2HIG.Typography.titlePixelSize
    private var iconSampleIndex = 1
    private var iconPixelSize = MK2HIG.Typography.actionDialogIconPixelSize
    private var focusedEncoder: Int?

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        let renderer = context.renderer
        let left: MK2PixelFrame
        let right: MK2PixelFrame
        switch view {
            case .specimen:
                left = catalogFrame(renderer)
                right = focusFrame(renderer)
            case .typography:
                left = typographySpecimenFrame(renderer)
                right = typographyContextFrame(renderer)
        }
        var scene = MK2SurfaceScene2(
            left: left,
            right: right,
            lamps: [.instance: .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01)]
        )
        scene.bindings.onPress(.instance) { [weak self] in
            context.update {
                guard let self else { return }
                self.view = self.view == .specimen ? .typography : .specimen
            }
        }
        if view == .specimen {
            for binding in encoderValues(context) {
                binding.apply(bindings: &scene.bindings)
            }
        }
        return scene
    }

    func prepareSnapshot(variant: String) {
        view = variant == "typography" ? .typography : .specimen
    }

    func replCommands() -> [ReplCommand] {
        [
            ReplCommand(name: "text", arg: "<string>", summary: "specimen sample text", values: []),
            ReplCommand(name: "sample", arg: "<0-3>", summary: "dialog mock sample preset", values: ["0", "1", "2", "3"]),
            ReplCommand(name: "body", arg: "<12-22>", summary: "body pixel size", values: []),
            ReplCommand(name: "title", arg: "<18-32>", summary: "title pixel size", values: []),
        ]
    }

    func handleRepl(verb: String, rest: String, _ context: LabContext) -> Bool {
        switch verb {
            case "text":
                context.update { [weak self] in self?.sampleText = rest.isEmpty ? " " : rest }
            case "sample":
                guard let value = Int(rest) else { return false }
                context.update { [weak self] in
                    guard let self else { return }
                    self.sampleIndex = value.wrapped(to: 0...(Self.samples.count - 1))
                }
            case "body":
                guard let value = Int(rest) else { return false }
                context.update { [weak self] in
                    self?.bodyPixelSize = max(Self.bodyBounds.lowerBound, min(Self.bodyBounds.upperBound, value))
                }
            case "title":
                guard let value = Int(rest) else { return false }
                context.update { [weak self] in
                    self?.titlePixelSize = max(Self.titleBounds.lowerBound, min(Self.titleBounds.upperBound, value))
                }
            default:
                return false
        }
        return true
    }

    // MARK: - Specimen view

    private func catalogFrame(_ renderer: FreeTypeTextRenderer?) -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        BitmapLabel("TYPE SPECIMEN - FREETYPE + FIXED PITCH", font: .label, color: Palette.accent)
            .draw(into: &frame, x: 8, y: 8)

        drawFreeTypeTitle("Global dialog title", into: &frame, renderer: renderer, x: 8, y: 32, size: 24, color: Palette.text, maxWidth: 448)
        drawFreeTypeBody("Body regular 16 px: lists, dialogs, browsers, settings.", into: &frame, renderer: renderer, x: 8, y: 70, size: 16, color: Palette.dim, maxWidth: 448)
        drawFreeTypeBody("Tracker and grid stay fixed-pitch sharp.", into: &frame, renderer: renderer, x: 8, y: 94, size: 16, color: Palette.empty, maxWidth: 448)

        let icons = Array(Self.iconSamples.prefix(4))
        for (index, icon) in icons.enumerated() {
            let x = 28 + index * 110
            drawFreeTypeIcon(icon.glyph, into: &frame, renderer: renderer, x: x, y: 122, size: 40, color: icon.color)
            BitmapLabel(icon.name.uppercased(), font: .label, color: Palette.dim)
                .draw(into: &frame, x: x - 10, y: 174, clip: MK2PixelRect(x: x - 10, y: 174, width: 92, height: 14))
        }

        frame.hline(y: 198, x: 8, width: 456, color: Palette.border)

        let faces: [(String, SurfaceFont)] = [
            ("FIXED GRID", .grid), ("GRID BOLD", .gridBold), ("LABEL", .label),
        ]
        var y = 212
        for (name, font) in faces {
            BitmapLabel(name, font: .label, color: Palette.dim).draw(into: &frame, x: 8, y: y + 1)
            BitmapLabel(sampleText, font: font, color: Palette.text)
                .draw(into: &frame, x: 112, y: y, clip: MK2PixelRect(x: 112, y: y, width: 352, height: font.cellHeight))
            y += font.cellHeight + 8
        }
        return frame
    }

    private func focusFrame(_ renderer: FreeTypeTextRenderer?) -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        let sample = Self.samples[sampleIndex]
        let icon = Self.iconSamples[iconSampleIndex]

        BitmapLabel("MAIN SAMPLE  E5 BODY  E6 TITLE  E7 ICON  E8 SIZE", font: .label, color: Palette.dim)
            .draw(into: &frame, x: 8, y: 8)
        BitmapLabel("\(sample.label.uppercased())  \(icon.name.uppercased())", font: .label, color: Palette.accent)
            .draw(into: &frame, x: 8, y: 25, clip: MK2PixelRect(x: 8, y: 25, width: 456, height: 14))

        let dialog = MK2PixelRect(x: 8, y: 48, width: 456, height: 150)
        let dialogRadius = 8
        frame.fillRounded(dialog, radius: dialogRadius, icon.color, antialiased: true)
        frame.fillRounded(
            MK2PixelRect(x: dialog.x + 1, y: dialog.y + 1, width: dialog.width - 2, height: dialog.height - 2),
            radius: dialogRadius - 1,
            Palette.dialogSurface,
            antialiased: true
        )
        drawFreeTypeIcon(icon.glyph, into: &frame, renderer: renderer, x: 28, y: 70, size: iconPixelSize, color: icon.color)
        drawFreeTypeTitle(sample.title, into: &frame, renderer: renderer, x: 112, y: 64, size: titlePixelSize, color: icon.color, maxWidth: 336)
        let bodyLines = drawFreeTypeBody(sample.body, into: &frame, renderer: renderer, x: 112, y: 104, size: bodyPixelSize, color: Palette.text, maxWidth: 336, maxLines: 2)
        let detailSize = max(12, min(18, bodyPixelSize - 1))
        let detailY = 104 + bodyLines * freeTypeLineAdvance(size: bodyPixelSize) + 2
        drawFreeTypeBody(sample.detail, into: &frame, renderer: renderer, x: 112, y: detailY, size: detailSize, color: Palette.dim, maxWidth: 336, maxLines: 2)

        for binding in encoderValues(nil) {
            binding.drawDisplay(into: &frame, renderer: renderer)
        }
        return frame
    }

    // MARK: - Typography view

    private func typographySpecimenFrame(_ renderer: FreeTypeTextRenderer?) -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        drawHeader(into: &frame, title: "TYPOGRAPHY", subtitle: "INSTANCE: SPECIMEN")
        drawFreeTypeTitle("Browser Selection", into: &frame, renderer: renderer, x: 18, y: 56, size: MK2HIG.Typography.titlePixelSize, color: Palette.text, maxWidth: 432)
        drawFreeTypeBody("Body regular 16 px. Calm text for longer MK2 OLED surfaces.", into: &frame, renderer: renderer, x: 18, y: 91, size: MK2HIG.Typography.bodyPixelSize, color: Palette.dim, maxWidth: 432)
        drawFreeTypeTitle("Settings", into: &frame, renderer: renderer, x: 18, y: 126, size: MK2HIG.Typography.titlePixelSize, color: Palette.text, maxWidth: 432)
        let settingsLines = drawFreeTypeBody("Lists, dialogs, browser panes and preferences share one rhythm.", into: &frame, renderer: renderer, x: 18, y: 160, size: MK2HIG.Typography.bodyPixelSize, color: Palette.dim, maxWidth: 432, maxLines: 2)
        let ligatureY = 160 + settingsLines * freeTypeLineAdvance(size: MK2HIG.Typography.bodyPixelSize) + 8
        BitmapLabel("PROPORTIONAL LIGATURE TEST", font: .label, color: Palette.empty).draw(into: &frame, x: 18, y: ligatureY)
        drawFreeTypeTitle("office affine efficient", into: &frame, renderer: renderer, x: 18, y: ligatureY + 16, size: 20, color: Palette.text, maxWidth: 432)
        BitmapLabel("FIXED GRID 0123456789 ffi", font: .grid, color: Palette.accent).draw(into: &frame, x: 18, y: 252)
        return frame
    }

    private func typographyContextFrame(_ renderer: FreeTypeTextRenderer?) -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        drawHeader(into: &frame, title: "COMBINATIONS", subtitle: "title 24 medium + body 16 regular")
        drawRow(into: &frame, renderer: renderer, y: 54, title: "Piano Noir", body: "Felt grand with quiet release samples", focused: true)
        drawRow(into: &frame, renderer: renderer, y: 114, title: "Tape Strings", body: "Warm ensemble, filtered attack", focused: false)
        drawRow(into: &frame, renderer: renderer, y: 174, title: "System", body: "Display brightness, browser defaults", focused: false)
        drawFreeTypeBody("INSTANCE toggles specimen and combinations.", into: &frame, renderer: renderer, x: 18, y: 246, size: MK2HIG.Typography.bodyPixelSize, color: Palette.empty, maxWidth: 432)
        return frame
    }

    private func drawRow(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer?, y: Int, title: String, body: String, focused: Bool) {
        if focused {
            frame.fill(MK2PixelRect(x: 12, y: y - 6, width: 456, height: 54), Palette.selectionFill)
        }
        drawFreeTypeTitle(title, into: &frame, renderer: renderer, x: 22, y: y, size: MK2HIG.Typography.titlePixelSize, color: focused ? Palette.text : Palette.dim, maxWidth: 420)
        drawFreeTypeBody(body, into: &frame, renderer: renderer, x: 22, y: y + 31, size: MK2HIG.Typography.bodyPixelSize, color: focused ? Palette.dim : Palette.empty, maxWidth: 420)
    }

    private func drawHeader(into frame: inout MK2PixelFrame, title: String, subtitle: String) {
        frame.fill(MK2PixelRect(x: 0, y: 0, width: MK2PixelFrame.width, height: 38), 0x0000)
        BitmapLabel(title, font: .gridBold, color: Palette.accent).draw(into: &frame, x: 8, y: 8)
        BitmapLabel(subtitle.uppercased(), font: .label, color: Palette.dim).draw(into: &frame, x: 8, y: 25)
    }

    // MARK: - Encoders

    private func encoderValues(_ context: LabContext?) -> [MK2EncoderDiscreteValue] {
        let icon = Self.iconSamples[iconSampleIndex]
        func touch(_ encoder: Int) -> (@Sendable (Bool) -> Void) {
            { [weak self] touched in
                context?.update {
                    guard let self else { return }
                    if touched {
                        self.focusedEncoder = encoder
                    } else if self.focusedEncoder == encoder {
                        self.focusedEncoder = nil
                    }
                }
            }
        }
        return [
            MK2EncoderDiscreteValue(
                encoder: 5, value: bodyPixelSize, bounds: Self.bodyBounds,
                display: display(label: "BODY", icon: MK2HIG.IconGlyph.textAa, value: "\(bodyPixelSize)", encoder: 5, color: Palette.text),
                onTouch: touch(5),
                onChange: { [weak self] value in
                    context?.update { self?.bodyPixelSize = max(Self.bodyBounds.lowerBound, min(Self.bodyBounds.upperBound, value)) }
                }
            ),
            MK2EncoderDiscreteValue(
                encoder: 6, value: titlePixelSize, bounds: Self.titleBounds,
                display: display(label: "TITLE", icon: MK2HIG.IconGlyph.textT, value: "\(titlePixelSize)", encoder: 6, color: Palette.text),
                onTouch: touch(6),
                onChange: { [weak self] value in
                    context?.update { self?.titlePixelSize = max(Self.titleBounds.lowerBound, min(Self.titleBounds.upperBound, value)) }
                }
            ),
            MK2EncoderDiscreteValue(
                encoder: 7, value: iconSampleIndex, bounds: 0...(Self.iconSamples.count - 1),
                display: display(label: "ICON", icon: MK2HIG.IconGlyph.sticker, value: "\(iconSampleIndex + 1)", encoder: 7, color: icon.color),
                onTouch: touch(7),
                onChange: { [weak self] value in
                    context?.update {
                        self?.iconSampleIndex = value.wrapped(to: 0...(Self.iconSamples.count - 1))
                    }
                }
            ),
            MK2EncoderDiscreteValue(
                encoder: 8, value: iconPixelSize, bounds: Self.iconSizeBounds, step: 2,
                display: display(label: "SIZE", icon: MK2HIG.IconGlyph.resize, value: "\(iconPixelSize)", encoder: 8, color: icon.color),
                onTouch: touch(8),
                onChange: { [weak self] value in
                    context?.update { self?.iconPixelSize = max(Self.iconSizeBounds.lowerBound, min(Self.iconSizeBounds.upperBound, value)) }
                }
            ),
        ]
    }

    private func display(label: String, icon: String, value: String, encoder: Int, color: UInt16) -> MK2EncoderDiscreteValueDisplay {
        MK2EncoderDiscreteValueDisplay(
            label: label,
            iconGlyph: icon,
            value: value,
            rect: MK2ScreenLayout.encoderSlotRect(encoder - 5),
            isFocused: focusedEncoder == encoder,
            valueFont: .readoutBold,
            cornerRadius: 7,
            colors: labEditCellColors(value: color)
        )
    }
}
