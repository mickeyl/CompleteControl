import Foundation

public extension MK2PixelFrame {
    /// Draw `text` with a bitmap font. `y` is the top of the glyph cell. When
    /// `background` is set the covered cells are filled first (highlight / inverted
    /// rows). Output is clipped to `clip` (∩ frame bounds) and, when given, to
    /// `maxWidth` measured from `x`. Set bits merge into horizontal runs so each run
    /// is a single `fill` (bulk `memset_pattern4`), keeping speed at `-Onone`.
    mutating func drawText(
        _ text: String,
        font: SurfaceFont,
        x: Int,
        y: Int,
        color: UInt16 = 0xffff,
        background: UInt16? = nil,
        scale: Int = 1,
        maxWidth: Int? = nil,
        clip: MK2PixelRect? = nil
    ) {
        let scale = max(1, scale)
        let advance = font.advance * scale
        let scalars = Array(text.unicodeScalars)
        let widthLimit = maxWidth.map { min(x + $0, Self.width) } ?? Self.width

        var region = MK2PixelRect(x: x, y: y, width: widthLimit - x, height: font.cellHeight * scale)
        if let clip {
            guard let clipped = region.clipped(to: clip) else { return }
            region = clipped
        }
        guard let bounds = region.clipped(to: Self.bounds) else { return }

        if let background {
            let bg = MK2PixelRect(x: x, y: y, width: scalars.count * advance, height: font.cellHeight * scale)
            if let filled = bg.clipped(to: bounds) { fill(filled, background) }
        }

        var cursor = x
        for scalar in scalars {
            if cursor >= bounds.maxX { break }
            let glyph = font.glyphIndex(for: scalar)
            for row in 0..<font.cellHeight {
                let bits = font.rowBits(glyph: glyph, row: row)
                guard bits != 0 else { continue }
                var column = 0
                while column < font.advance {
                    guard (bits & (UInt16(1) << (font.advance - 1 - column))) != 0 else {
                        column += 1
                        continue
                    }
                    var runEnd = column
                    while runEnd + 1 < font.advance,
                          (bits & (UInt16(1) << (font.advance - 1 - (runEnd + 1)))) != 0 {
                        runEnd += 1
                    }
                    let runRect = MK2PixelRect(
                        x: cursor + column * scale,
                        y: y + row * scale,
                        width: (runEnd - column + 1) * scale,
                        height: scale)
                    if let clipped = runRect.clipped(to: bounds) { fill(clipped, color) }
                    column = runEnd + 1
                }
            }
            cursor += advance
        }
    }
}
