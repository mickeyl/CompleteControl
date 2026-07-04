import Foundation

public struct MK2StatusLineItem: Sendable {
    public var text: String
    public var x: Int
    public var color: UInt16
    public var font: SurfaceFont

    public init(
        _ text: String,
        x: Int,
        color: UInt16,
        font: SurfaceFont = .grid
    ) {
        self.text = text
        self.x = x
        self.color = color
        self.font = font
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
            BitmapLabel(item.text, font: item.font, color: item.color)
                .draw(into: &frame, x: item.x, y: y)
        }
    }
}
