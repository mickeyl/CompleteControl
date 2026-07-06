import Foundation

public extension MK2PixelFrame {
    /// Draw `text` with a monospace `SurfaceFont`. `y` is the top of the glyph cell.
    /// When `background` is set the covered cells are filled first (highlight / inverted
    /// rows). Output is clipped to `clip` (∩ frame bounds) and, when given, to `maxWidth`
    /// measured from `x`. Rasterization now lowers to JetBrains Mono through the shared
    /// `FreeTypeTextRenderer`, stepping the pen by the face's fixed `advance` so column
    /// positions and characters-per-row match the retired bitmap atlas exactly.
    mutating func drawText(
        _ text: String,
        font: SurfaceFont = .grid,
        x: Int,
        y: Int,
        color: UInt16 = 0xffff,
        background: UInt16? = nil,
        scale: Int = 1,
        maxWidth: Int? = nil,
        clip: MK2PixelRect? = nil
    ) {
        let scale = max(1, scale)
        guard let renderer = FreeTypeTextRenderer.shared else { return }
        let style = FreeTypeTextStyle(
            familyID: font.familyID,
            weight: font.renderWeight,
            pixelSize: font.pixelSize * scale,
            color: color,
            rasterMode: .grayscaleHinted)
        try? renderer.drawMonospaced(
            text,
            into: &self,
            x: x,
            y: y,
            style: style,
            advance: font.advance * scale,
            ascent: font.ascent * scale,
            cellHeight: font.cellHeight * scale,
            background: background,
            maxWidth: maxWidth,
            clip: clip)
    }
}
