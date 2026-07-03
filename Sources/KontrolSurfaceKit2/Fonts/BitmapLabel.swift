import Foundation

/// A measured piece of bitmap text: font, colour, optional highlight background, and
/// integer scale. Widgets compose labels and ask for their `width`/`height` to lay
/// out; `draw(into:)` renders through the font-aware `drawText` primitive.
public struct BitmapLabel: Sendable {
    public var text: String
    public var font: SurfaceFont
    public var color: UInt16
    public var background: UInt16?
    public var scale: Int

    public init(
        _ text: String,
        font: SurfaceFont = .grid,
        color: UInt16 = 0xffff,
        background: UInt16? = nil,
        scale: Int = 1
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.background = background
        self.scale = max(1, scale)
    }

    public var width: Int { font.measure(text, scale: scale) }
    public var height: Int { font.cellHeight * scale }

    public func draw(into frame: inout MK2PixelFrame, x: Int, y: Int, clip: MK2PixelRect? = nil) {
        frame.drawText(
            text,
            font: font,
            x: x,
            y: y,
            color: color,
            background: background,
            scale: scale,
            clip: clip)
    }
}
