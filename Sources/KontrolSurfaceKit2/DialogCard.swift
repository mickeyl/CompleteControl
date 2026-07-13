import Foundation

public struct MK2DialogCardColors: Sendable, Equatable {
    public var surface: UInt16
    public var border: UInt16
    public var title: UInt16
    public var body: UInt16
    public var footnote: UInt16

    public init(
        surface: UInt16 = MK2HIG.Chrome.headerFill,
        border: UInt16 = MK2HIG.Chrome.accent,
        title: UInt16 = MK2HIG.Chrome.accent,
        body: UInt16 = MK2HIG.Chrome.text,
        footnote: UInt16 = MK2HIG.Chrome.dim
    ) {
        self.surface = surface
        self.border = border
        self.title = title
        self.body = body
        self.footnote = footnote
    }
}

/// A single-screen dialog card: a rounded panel (accent/severity ring over a
/// graphite surface) carrying a Phosphor icon, a title, a body of up to two
/// lines and an optional footnote. This is the inline, one-OLED sibling of
/// `MK2ModalDialog` — it does not take over both screens or own bindings, so
/// it fits inside any scene as informational or confirmation content.
public struct MK2DialogCard: Sendable {
    /// Where the icon sits relative to the text block.
    public enum IconPlacement: Sendable, Equatable {
        /// Icon leading, text column to its right — the compact inline form.
        case leading
        /// Icon centered above a left-aligned text block — the action-dialog form.
        case top
    }

    public var rect: MK2PixelRect
    public var iconGlyph: String?
    public var iconFallback: String
    public var iconColor: UInt16
    public var iconSize: Int
    public var iconPlacement: IconPlacement
    public var title: String
    public var body: String
    public var footnote: String?
    public var titlePixelSize: Int
    public var bodyPixelSize: Int
    public var cornerRadius: Int
    public var colors: MK2DialogCardColors

    public init(
        rect: MK2PixelRect,
        iconGlyph: String? = nil,
        iconFallback: String = "!",
        iconColor: UInt16 = MK2HIG.Chrome.accent,
        iconSize: Int = MK2HIG.Typography.actionDialogIconPixelSize,
        iconPlacement: IconPlacement = .leading,
        title: String,
        body: String,
        footnote: String? = nil,
        titlePixelSize: Int = MK2HIG.Typography.titlePixelSize,
        bodyPixelSize: Int = MK2HIG.Typography.bodyPixelSize,
        cornerRadius: Int = 8,
        colors: MK2DialogCardColors = MK2DialogCardColors()
    ) {
        self.rect = rect
        self.iconGlyph = iconGlyph
        self.iconFallback = iconFallback
        self.iconColor = iconColor
        self.iconSize = max(12, iconSize)
        self.iconPlacement = iconPlacement
        self.title = title
        self.body = body
        self.footnote = footnote
        self.titlePixelSize = titlePixelSize
        self.bodyPixelSize = bodyPixelSize
        self.cornerRadius = max(0, cornerRadius)
        self.colors = colors
    }

    /// Severity-driven convenience: the ring/title tint and the default icon
    /// come from `MK2ModalDialogSeverity`, so an inline card and a full modal
    /// read as the same family.
    public init(
        rect: MK2PixelRect,
        severity: MK2ModalDialogSeverity,
        title: String,
        body: String,
        footnote: String? = nil,
        iconGlyph: String? = nil,
        iconPlacement: IconPlacement = .leading,
        titlePixelSize: Int = MK2HIG.Typography.titlePixelSize,
        bodyPixelSize: Int = MK2HIG.Typography.bodyPixelSize,
        colors: MK2ModalDialogColors = MK2ModalDialogColors()
    ) {
        let tone = colors.accent(for: severity)
        self.init(
            rect: rect,
            iconGlyph: iconGlyph ?? severity.iconGlyph,
            iconFallback: severity.fallbackText,
            iconColor: tone,
            iconPlacement: iconPlacement,
            title: title,
            body: body,
            footnote: footnote,
            titlePixelSize: titlePixelSize,
            bodyPixelSize: bodyPixelSize,
            colors: MK2DialogCardColors(
                surface: colors.background == 0 ? MK2HIG.Chrome.headerFill : colors.background,
                border: tone,
                title: tone,
                body: colors.text,
                footnote: colors.dim
            )
        )
    }

    public func draw(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer?) {
        // Ring over surface, both rounded and dithered like the value cells.
        frame.fillRounded(rect, radius: cornerRadius, colors.border, antialiased: true)
        frame.fillRounded(
            MK2PixelRect(x: rect.x + 1, y: rect.y + 1, width: rect.width - 2, height: rect.height - 2),
            radius: max(0, cornerRadius - 1),
            colors.surface,
            antialiased: true
        )

        switch iconPlacement {
            case .leading:
                drawLeading(into: &frame, renderer: renderer)
            case .top:
                drawTop(into: &frame, renderer: renderer)
        }
    }

    private func drawLeading(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer?) {
        let padding = 20
        drawIcon(into: &frame, renderer: renderer, x: rect.x + padding, y: rect.y + 22)
        let textX = rect.x + padding + iconSize + 24
        let maxWidth = max(0, rect.maxX - textX - padding)
        var y = rect.y + 16
        drawText(title, into: &frame, renderer: renderer, x: textX, y: y, pixelSize: titlePixelSize, weight: MK2HIG.Fonts.titleWeight, color: colors.title, maxWidth: maxWidth)
        y = rect.y + 56
        let bodyLines = drawWrapped(body, into: &frame, renderer: renderer, x: textX, y: y, pixelSize: bodyPixelSize, color: colors.body, maxWidth: maxWidth, maxLines: 2)
        if let footnote {
            let footY = y + bodyLines * lineAdvance(bodyPixelSize) + 2
            drawText(footnote, into: &frame, renderer: renderer, x: textX, y: footY, pixelSize: max(12, bodyPixelSize - 1), weight: MK2HIG.Fonts.bodyWeight, color: colors.footnote, maxWidth: maxWidth)
        }
    }

    private func drawTop(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer?) {
        let padding = 28
        drawIconCentered(into: &frame, renderer: renderer, centerX: rect.x + rect.width / 2, y: rect.y + 20)
        let textX = rect.x + padding
        let maxWidth = max(0, rect.width - padding * 2)
        var y = rect.y + 20 + iconSize + 14
        drawText(title, into: &frame, renderer: renderer, x: textX, y: y, pixelSize: titlePixelSize, weight: MK2HIG.Fonts.titleWeight, color: colors.title, maxWidth: maxWidth)
        y += lineAdvance(titlePixelSize) + 4
        let bodyLines = drawWrapped(body, into: &frame, renderer: renderer, x: textX, y: y, pixelSize: bodyPixelSize, color: colors.body, maxWidth: maxWidth, maxLines: 2)
        if let footnote {
            let footY = y + bodyLines * lineAdvance(bodyPixelSize) + 6
            drawText(footnote, into: &frame, renderer: renderer, x: textX, y: footY, pixelSize: bodyPixelSize, weight: MK2HIG.Fonts.bodyWeight, color: colors.body, maxWidth: maxWidth)
        }
    }

    // MARK: - Drawing primitives (same FreeType-with-bitmap-fallback pattern as MK2ModalDialog)

    private func lineAdvance(_ pixelSize: Int) -> Int { max(18, pixelSize + 4) }

    private func drawIcon(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer?, x: Int, y: Int) {
        let style = MK2HIG.iconStyle(pixelSize: iconSize, color: iconColor)
        if let iconGlyph, let renderer,
           (try? renderer.drawText(iconGlyph, into: &frame, x: x, y: y, style: style, maxWidth: iconSize + 20)) != nil {
            return
        }
        BitmapLabel(iconFallback, font: .readoutBold, color: iconColor).draw(into: &frame, x: x + iconSize / 3, y: y + iconSize / 3)
    }

    private func drawIconCentered(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer?, centerX: Int, y: Int) {
        let style = MK2HIG.iconStyle(pixelSize: iconSize, color: iconColor)
        if let iconGlyph, let renderer,
           let width = try? renderer.measure(iconGlyph, style: style),
           (try? renderer.drawText(iconGlyph, into: &frame, x: centerX - width / 2, y: y, style: style, maxWidth: iconSize + 20)) != nil {
            return
        }
        BitmapLabel(iconFallback, font: .readoutBold, color: iconColor).draw(into: &frame, x: centerX - 8, y: y + iconSize / 3)
    }

    private func drawText(_ text: String, into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer?, x: Int, y: Int, pixelSize: Int, weight: FreeTypeFontWeight, color: UInt16, maxWidth: Int) {
        let style = MK2HIG.textStyle(weight: weight, pixelSize: pixelSize, color: color)
        guard let renderer, (try? renderer.drawText(text, into: &frame, x: x, y: y, style: style, maxWidth: maxWidth)) != nil else {
            let font: SurfaceFont = weight == MK2HIG.Fonts.titleWeight ? .gridBold : .grid
            BitmapLabel(text, font: font, color: color)
                .draw(into: &frame, x: x, y: y + 3, clip: MK2PixelRect(x: x, y: y, width: maxWidth, height: max(18, pixelSize + 4)))
            return
        }
    }

    private func drawWrapped(_ text: String, into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer?, x: Int, y: Int, pixelSize: Int, color: UInt16, maxWidth: Int, maxLines: Int) -> Int {
        let style = MK2HIG.textStyle(weight: MK2HIG.Fonts.bodyWeight, pixelSize: pixelSize, color: color)
        if let renderer, let layout = try? renderer.wrappedLayout(text, style: style, maxWidth: maxWidth) {
            let count = min(maxLines, max(1, layout.lines.count))
            for index in 0..<count {
                let line = layout.lines.indices.contains(index) ? layout.lines[index] : ""
                try? renderer.drawText(line, into: &frame, x: x, y: y + index * lineAdvance(pixelSize), style: style, maxWidth: maxWidth)
            }
            return count
        }
        drawText(text, into: &frame, renderer: renderer, x: x, y: y, pixelSize: pixelSize, weight: MK2HIG.Fonts.bodyWeight, color: color, maxWidth: maxWidth)
        return 1
    }
}

/// Screen-DSL wrapper for `MK2DialogCard`.
public struct MK2DialogCardElement: MK2ScreenElement {
    public var card: MK2DialogCard
    public var relativeToContent: Bool

    public init(_ card: MK2DialogCard, relativeToContent: Bool = true) {
        self.card = card
        self.relativeToContent = relativeToContent
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        var card = card
        if relativeToContent, let contentRect = context.layout?.contentRect {
            card.rect = MK2PixelRect(x: contentRect.x + card.rect.x, y: contentRect.y + card.rect.y, width: card.rect.width, height: card.rect.height)
        }
        card.draw(into: &frame, renderer: context.renderer)
    }
}
