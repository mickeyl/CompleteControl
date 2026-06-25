import Foundation
import KompleteKontrol

/// Intended content of one LCD row — the lowering target shared by the
/// imperative setters and the declarative DSL.
public enum CellContent: Sendable {
    case empty
    case bar(Double)
    case text(String, KKDisplayAlignment, TextOverflow)
    case glyphs([UInt16])
    case spinner(speed: Double, length: Int, reverse: Bool, column: Int?)
}
