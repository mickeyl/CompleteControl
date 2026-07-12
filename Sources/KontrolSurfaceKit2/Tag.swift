import Foundation

public struct MK2TagColors: Sendable, Equatable {
    public var text: UInt16
    public var fill: UInt16
    public var border: UInt16

    public init(
        text: UInt16 = MK2HIG.Chrome.accent,
        fill: UInt16 = MK2HIG.Chrome.headerFill,
        border: UInt16 = MK2HIG.Chrome.border
    ) {
        self.text = text
        self.fill = fill
        self.border = border
    }
}

/// A compact pill-shaped tag/chip for categorical badges (SAMPLE/WAVETABLE,
/// states, kinds) placed next to titles — not for encoder-bound values,
/// that is `MK2ValueCell`. Fully rounded ends, and a raised look: border
/// ring and fill both run a subtle lit-from-above gradient, dithered and
/// antialiased like the value cells.
public struct MK2Tag: Sendable {
    public var text: String
    public var rect: MK2PixelRect
    public var pixelSize: Int
    public var colors: MK2TagColors

    public init(
        _ text: String,
        rect: MK2PixelRect,
        pixelSize: Int = 12,
        colors: MK2TagColors = MK2TagColors()
    ) {
        self.text = text
        self.rect = rect
        self.pixelSize = max(8, pixelSize)
        self.colors = colors
    }

    public func draw(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer?) {
        let radius = rect.height / 2
        frame.fillRoundedVerticalGradient(
            rect,
            radius: radius,
            top: Self.scaled(colors.border, by: 1.35),
            bottom: Self.scaled(colors.border, by: 0.75),
            antialiased: true
        )
        if rect.width > 2, rect.height > 2 {
            frame.fillRoundedVerticalGradient(
                MK2PixelRect(x: rect.x + 1, y: rect.y + 1, width: rect.width - 2, height: rect.height - 2),
                radius: max(0, radius - 1),
                top: Self.scaled(colors.fill, by: 1.18),
                bottom: Self.scaled(colors.fill, by: 0.82),
                antialiased: true
            )
        }

        let style = MK2HIG.textStyle(weight: .medium, pixelSize: pixelSize, color: colors.text)
        let textY = rect.y + max(0, (rect.height - pixelSize) / 2 - 1)
        let maxTextWidth = max(0, rect.width - 12)
        if let renderer,
           let width = try? renderer.measure(text, style: style) {
            let textX = rect.x + max(6, (rect.width - min(width, maxTextWidth)) / 2)
            if (try? renderer.drawText(text, into: &frame, x: textX, y: textY, style: style, maxWidth: maxTextWidth)) != nil {
                return
            }
        }
        let label = BitmapLabel(text, font: .label, color: colors.text)
        let textX = rect.x + max(6, (rect.width - label.width) / 2)
        label.draw(
            into: &frame,
            x: textX,
            y: rect.y + max(0, (rect.height - SurfaceFont.label.cellHeight) / 2),
            clip: MK2PixelRect(x: rect.x + 6, y: rect.y, width: maxTextWidth, height: rect.height)
        )
    }

    /// The pill's natural width for a text: glyph run plus the rounded lead
    /// on both ends.
    public static func naturalWidth(
        for text: String,
        pixelSize: Int = 12,
        height: Int = 24,
        renderer: FreeTypeTextRenderer?
    ) -> Int {
        let style = MK2HIG.textStyle(weight: .medium, pixelSize: pixelSize, color: 0xffff)
        let textWidth = (try? renderer?.measure(text, style: style))
            ?? BitmapLabel(text, font: .label, color: 0xffff).width
        return textWidth + height
    }

    private static func scaled(_ color: UInt16, by factor: Double) -> UInt16 {
        let r = UInt16(min(31, (Double((color >> 11) & 0x1f) * factor).rounded()))
        let g = UInt16(min(63, (Double((color >> 5) & 0x3f) * factor).rounded()))
        let b = UInt16(min(31, (Double(color & 0x1f) * factor).rounded()))
        return (r << 11) | (g << 5) | b
    }
}

/// Screen-DSL wrapper: sizes the pill to its text (never below `minWidth`)
/// and draws at the given position.
public struct MK2TagElement: MK2ScreenElement {
    public var text: String
    public var x: Int
    public var y: Int
    public var height: Int
    public var minWidth: Int
    public var pixelSize: Int
    public var colors: MK2TagColors
    public var relativeToContent: Bool

    public init(
        _ text: String,
        x: Int = 0,
        y: Int = 0,
        height: Int = 24,
        minWidth: Int = 0,
        pixelSize: Int = 12,
        colors: MK2TagColors = MK2TagColors(),
        relativeToContent: Bool = true
    ) {
        self.text = text
        self.x = x
        self.y = y
        self.height = max(12, height)
        self.minWidth = max(0, minWidth)
        self.pixelSize = pixelSize
        self.colors = colors
        self.relativeToContent = relativeToContent
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        let content = relativeToContent ? context.layout?.contentRect : nil
        let originX = content?.x ?? 0
        let originY = content?.y ?? 0
        let width = max(minWidth, MK2Tag.naturalWidth(for: text, pixelSize: pixelSize, height: height, renderer: context.renderer))
        MK2Tag(
            text,
            rect: MK2PixelRect(x: originX + x, y: originY + y, width: width, height: height),
            pixelSize: pixelSize,
            colors: colors
        ).draw(into: &frame, renderer: context.renderer)
    }
}
