import Foundation

public struct MK2StatusLineItem: Sendable {
    public var text: String
    public var x: Int
    public var color: UInt16
    public var font: SurfaceFont
    /// Clips the item to this width — for trailing free-text items
    /// (subtitles, instrument names) that must not run into a neighbour.
    public var maxWidth: Int?

    public init(
        _ text: String,
        x: Int,
        color: UInt16,
        font: SurfaceFont = .grid,
        maxWidth: Int? = nil
    ) {
        self.text = text
        self.x = x
        self.color = color
        self.font = font
        self.maxWidth = maxWidth
    }
}

/// Compact, fixed-position header/status text for MK2 display pages.
public struct MK2StatusLine: Sendable {
    public var y: Int
    public var items: [MK2StatusLineItem]

    public init(y: Int, items: [MK2StatusLineItem]) {
        self.y = y
        self.items = items
    }

    public func draw(into frame: inout MK2PixelFrame) {
        for item in items {
            let label = BitmapLabel(item.text, font: item.font, color: item.color)
            if let maxWidth = item.maxWidth {
                label.draw(into: &frame, x: item.x, y: y, clip: MK2PixelRect(x: item.x, y: y, width: maxWidth, height: item.font.cellHeight))
            } else {
                label.draw(into: &frame, x: item.x, y: y)
            }
        }
    }
}
