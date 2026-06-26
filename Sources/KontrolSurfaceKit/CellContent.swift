import Foundation
import KompleteKontrol

/// Intended content of one LCD row — the lowering target for the declarative
/// DSL. Deprecated imperative setters also write this state as a legacy escape
/// hatch.
public enum CellContent: Sendable {
    case empty
    case bar(Double)
    case text(String, KKDisplayAlignment, TextOverflow)
    case glyphs([UInt16])
    case spinner(speed: Double, length: Int, reverse: Bool, column: Int?)
}
