import Foundation

/// A fixed-metric bitmap font face backed by the generated bitmap atlas. Faces are
/// value types decoded once from their base64 blob into a flat `[UInt8]` the text hot
/// path indexes directly — no per-glyph heap churn on lookup.
public struct SurfaceFont: Sendable {
    /// Semantic role; maps to a concrete bitmap face.
    public enum Role: Sendable {
        case grid       // 8×16 — pattern rows, dense columns
        case label      // 6×12 — chrome, secondary text
        case readout    // 10×20 — large transport/position readouts
    }

    public enum Weight: Sendable {
        case regular
        case bold
    }

    public let advance: Int
    public let cellHeight: Int
    public let ascent: Int
    let bytesPerRow: Int
    let firstCodepoint: Int
    let glyphCount: Int
    let bitmap: [UInt8]

    private init(_ face: TamzenAtlas.Face) {
        advance = face.advance
        cellHeight = face.cellHeight
        ascent = face.ascent
        bytesPerRow = face.bytesPerRow
        firstCodepoint = face.firstCodepoint
        glyphCount = face.glyphCount
        bitmap = [UInt8](Data(base64Encoded: face.bitmapBase64) ?? Data())
    }

    public static let grid = SurfaceFont(TamzenAtlas.grid)
    public static let gridBold = SurfaceFont(TamzenAtlas.gridBold)
    public static let label = SurfaceFont(TamzenAtlas.label)
    public static let readout = SurfaceFont(TamzenAtlas.readout)
    public static let readoutBold = SurfaceFont(TamzenAtlas.readoutBold)

    /// Resolve a role/weight to a concrete face. The label role currently ships as a
    /// single Cozette face, so bold label falls back to regular label.
    public static func face(_ role: Role, _ weight: Weight = .regular) -> SurfaceFont {
        switch (role, weight) {
            case (.grid, .regular): grid
            case (.grid, .bold): gridBold
            case (.label, _): label
            case (.readout, .regular): readout
            case (.readout, .bold): readoutBold
        }
    }

    /// Pixel width of `text` laid out at `scale`. Monospace: one advance per scalar,
    /// counted over the same unit the renderer iterates so measure matches layout.
    public func measure(_ text: String, scale: Int = 1) -> Int {
        text.unicodeScalars.count * advance * max(1, scale)
    }

    /// Glyph slot for a scalar, falling back to '?' outside the baked codepoint window.
    func glyphIndex(for scalar: Unicode.Scalar) -> Int {
        let cp = Int(scalar.value)
        if cp >= firstCodepoint, cp < firstCodepoint + glyphCount {
            return cp - firstCodepoint
        }
        return fallbackIndex
    }

    private var fallbackIndex: Int { Int(UInt8(ascii: "?")) - firstCodepoint }

    /// Set-bit mask of one glyph row; bit `advance-1` is the leftmost pixel.
    func rowBits(glyph: Int, row: Int) -> UInt16 {
        let base = glyph * bytesPerRow * cellHeight + row * bytesPerRow
        var bits: UInt16 = 0
        for b in 0..<bytesPerRow {
            bits = (bits << 8) | UInt16(bitmap[base + b])
        }
        return bits
    }
}
