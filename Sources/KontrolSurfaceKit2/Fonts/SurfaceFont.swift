import Foundation

/// A fixed-metric monospace font face. Each face names a JetBrains Mono weight plus the
/// pixel size, cell advance, cell height, and ascent that reproduce the retired bitmap
/// atlas metrics exactly — so every widget laid out against `advance`/`cellHeight`/
/// `ascent`/`measure` keeps identical column and row geometry while the glyphs are now
/// rasterized through FreeType. Faces stay value types the layout code copies freely.
public struct SurfaceFont: Sendable {
    /// Semantic role; maps to a concrete monospace face.
    public enum Role: Sendable {
        case grid       // 8×16 — pattern rows, dense columns
        case label      // 6×13 — chrome, secondary text
        case readout    // 10×20 — large transport/position readouts
    }

    public enum Weight: Sendable {
        case regular
        case bold
    }

    public let advance: Int
    public let cellHeight: Int
    public let ascent: Int
    let familyID: String
    let renderWeight: FreeTypeFontWeight
    let pixelSize: Int

    private init(advance: Int, cellHeight: Int, ascent: Int, renderWeight: FreeTypeFontWeight, pixelSize: Int) {
        self.advance = advance
        self.cellHeight = cellHeight
        self.ascent = ascent
        self.familyID = FreeTypeFontCatalog.monoFamilyID
        self.renderWeight = renderWeight
        self.pixelSize = pixelSize
    }

    // JetBrains Mono has a 0.6·em advance, so 13/10/16 px reproduce the 8/6/10 px atlas
    // advances; cell height and ascent are carried over verbatim so nothing moves. "Bold"
    // maps to the Bold (700) cut: the 400→500 step is too subtle to survive hinting at
    // 13 px, whereas 400→700 stays legibly heavier for grid/readout emphasis.
    public static let grid = SurfaceFont(advance: 8, cellHeight: 16, ascent: 12, renderWeight: .regular, pixelSize: 13)
    public static let gridBold = SurfaceFont(advance: 8, cellHeight: 16, ascent: 12, renderWeight: .bold, pixelSize: 13)
    public static let label = SurfaceFont(advance: 6, cellHeight: 13, ascent: 10, renderWeight: .regular, pixelSize: 10)
    public static let readout = SurfaceFont(advance: 10, cellHeight: 20, ascent: 14, renderWeight: .regular, pixelSize: 16)
    public static let readoutBold = SurfaceFont(advance: 10, cellHeight: 20, ascent: 14, renderWeight: .bold, pixelSize: 16)

    /// Resolve a role/weight to a concrete face.
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
}
