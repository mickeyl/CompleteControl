import Foundation
import KompleteKontrol

/// Intended content of a single LCD row.
enum CellContent {
    case empty
    case bar(Double)
    case text(String, KKDisplayAlignment, TextOverflow)
    case glyphs([UInt16])
    case spinner(speed: Double, length: Int, reverse: Bool, column: Int?)
}

/// Per-cell marquee animation state, advanced by the surface clock.
private struct MarqueeState {
    var offset: Double = 0
    var elapsed: Double = 0
}

/// Holds the intended state of all nine displays, advances marquee animations,
/// and emits the minimal set of row reports needed to reach that state.
///
/// The hardware writes one report per row across all displays at once, so the
/// reconciler diffs at row granularity: an unchanged row produces no USB traffic.
struct DisplayReconciler {
    static let displays = KKDisplayFrame.displayCount
    static let rows = KKDisplayFrame.rowCount
    static let width = KKDisplayFrame.characterCount

    private var content: [[CellContent]]
    private var marquee: [[MarqueeState]]
    private var lastText: [[String]]
    private var lastSent: [[UInt8]?]

    init() {
        content = Array(repeating: Array(repeating: .empty, count: Self.rows), count: Self.displays)
        marquee = Array(repeating: Array(repeating: MarqueeState(), count: Self.rows), count: Self.displays)
        lastText = Array(repeating: Array(repeating: "", count: Self.rows), count: Self.displays)
        lastSent = Array(repeating: nil, count: Self.rows)
    }

    mutating func set(display: Int, row: Int, _ newContent: CellContent) {
        guard content.indices.contains(display), (0..<Self.rows).contains(row) else { return }
        if case let .text(text, _, _) = newContent {
            if lastText[display][row] != text {
                marquee[display][row] = MarqueeState()
                lastText[display][row] = text
            }
        } else {
            lastText[display][row] = ""
        }
        content[display][row] = newContent
    }

    mutating func clearAll() {
        for display in content.indices {
            for row in 0..<Self.rows {
                content[display][row] = .empty
                marquee[display][row] = MarqueeState()
                lastText[display][row] = ""
            }
        }
    }

    mutating func advance(dt: Double) {
        for display in content.indices {
            for row in 0..<Self.rows {
                switch content[display][row] {
                    case let .text(text, _, .marquee(speed, _, _, startDelay)) where text.count > Self.width:
                        marquee[display][row].elapsed += dt
                        if marquee[display][row].elapsed >= startDelay {
                            marquee[display][row].offset += speed * dt
                        }
                    case let .spinner(speed, _, _, _):
                        marquee[display][row].offset += speed * dt
                    default:
                        break
                }
            }
        }
    }

    /// Renders the intended state and returns only the rows whose bytes changed.
    mutating func render() -> [(row: Int, data: [UInt8])] {
        var frame = KKDisplayFrame()
        for display in content.indices {
            for row in 0..<Self.rows {
                renderCell(content[display][row], display: display, row: row, marquee: marquee[display][row], into: &frame)
            }
        }
        var changed: [(row: Int, data: [UInt8])] = []
        for row in 0..<Self.rows {
            let data = frame.rowData(row)
            if lastSent[row] != data {
                lastSent[row] = data
                changed.append((row, data))
            }
        }
        return changed
    }

    private func renderCell(_ cell: CellContent, display: Int, row: Int, marquee: MarqueeState, into frame: inout KKDisplayFrame) {
        switch cell {
            case .empty:
                break
            case let .bar(value):
                guard row == 0 else { break }
                frame.setBar(value, display: display, row: 0)
            case let .glyphs(glyphs):
                guard row >= 1 else { break }
                for (column, glyph) in glyphs.prefix(Self.width).enumerated() {
                    frame.setRawGlyph(glyph, display: display, row: row, column: column)
                }
            case let .text(text, alignment, overflow):
                guard row >= 1 else { break }
                if text.count <= Self.width {
                    frame.setText(text, display: display, row: row, alignment: alignment)
                } else {
                    frame.setText(window(text, overflow: overflow, marquee: marquee), display: display, row: row, alignment: .left)
                }
            case let .spinner(_, length, reverse, column):
                guard row >= 1 else { break }
                let mask = Self.perimeterMask(phase: Int(marquee.offset.rounded(.down)), length: length, reverse: reverse)
                if let column, (0..<Self.width).contains(column) {
                    frame.setRawGlyph(mask, display: display, row: row, column: column)
                } else {
                    for column in 0..<Self.width {
                        frame.setRawGlyph(mask, display: display, row: row, column: column)
                    }
                }
        }
    }

    /// The eight outer segments form the cell's rectangle, and bits 0…7 happen to
    /// walk that rectangle clockwise, so a single bit stepped through 0…7 runs a
    /// segment around the perimeter. `length` lights several adjacent segments.
    private static func perimeterMask(phase: Int, length: Int, reverse: Bool) -> UInt16 {
        var mask: UInt16 = 0
        for offset in 0..<max(1, length) {
            let raw = reverse ? -(phase + offset) : (phase + offset)
            let bit = ((raw % 8) + 8) % 8
            mask |= UInt16(1) << bit
        }
        return mask
    }

    private func window(_ text: String, overflow: TextOverflow, marquee: MarqueeState) -> String {
        let cap = Self.width
        let chars = Array(text)
        switch overflow {
            case .clip, .fit:
                return String(chars.prefix(cap))
            case .ellipsis:
                return String(chars.prefix(cap - 1)) + "."
            case let .marquee(_, gap, style, _):
                switch style {
                    case .wrap:
                        let cycle = chars.count + max(1, gap)
                        let start = Int(marquee.offset.rounded(.down)) % cycle
                        var visible = ""
                        for column in 0..<cap {
                            let index = (start + column) % cycle
                            visible.append(index < chars.count ? chars[index] : " ")
                        }
                        return visible
                    case .pingPong:
                        let span = chars.count - cap
                        let period = max(1, span * 2)
                        let phase = Int(marquee.offset.rounded(.down)) % period
                        let position = min(max(0, phase <= span ? phase : period - phase), span)
                        return String(chars[position..<position + cap])
                }
        }
    }
}
