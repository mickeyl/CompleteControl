import Foundation
import KompleteKontrol

// MARK: - Cell elements

/// Something that can be placed inside a ``Cell``. `Bar` targets row 0; every
/// other element fills the text rows (1 then 2) in declaration order.
public protocol CellElement: Sendable {
    func place(into model: inout SurfaceModel, display: Int, textRow: inout Int)
}

/// The row-0 progress bar (0…1).
public struct Bar: CellElement {
    let value: Double
    public init(_ value: Double) { self.value = value }
    public func place(into model: inout SurfaceModel, display: Int, textRow: inout Int) {
        model.set(display, 0, .bar(value))
    }
}

/// A text line; long strings scroll per `overflow` (marquee by default).
public struct Label: CellElement {
    let text: String
    let alignment: KKDisplayAlignment
    let overflow: TextOverflow
    public init(_ text: String, align: KKDisplayAlignment = .center, overflow: TextOverflow = .marquee) {
        self.text = text
        self.alignment = align
        self.overflow = overflow
    }
    public func place(into model: inout SurfaceModel, display: Int, textRow: inout Int) {
        guard textRow <= 2 else { return }
        model.set(display, textRow, .text(text, alignment, overflow))
        textRow += 1
    }
}

/// A formatted numeric value line.
public struct Value: CellElement {
    let text: String
    public init(_ value: Double, format: ValueFormat = .integer) { text = format.string(value) }
    public init(_ value: Int) { text = "\(value)" }
    public func place(into model: inout SurfaceModel, display: Int, textRow: inout Int) {
        guard textRow <= 2 else { return }
        model.set(display, textRow, .text(text, .center, .clip))
        textRow += 1
    }
}

/// Raw 16-segment glyph masks, one per column.
public struct Glyphs: CellElement {
    let masks: [UInt16]
    public init(_ masks: [UInt16]) { self.masks = masks }
    public func place(into model: inout SurfaceModel, display: Int, textRow: inout Int) {
        guard textRow <= 2 else { return }
        model.set(display, textRow, .glyphs(masks))
        textRow += 1
    }
}

/// An activity indicator running a segment around the cell rectangle.
public struct Spinner: CellElement {
    let column: Int?
    let speed: Double
    let length: Int
    let reverse: Bool
    public init(column: Int? = nil, speed: Double = 12, length: Int = 1, reverse: Bool = false) {
        self.column = column
        self.speed = speed
        self.length = length
        self.reverse = reverse
    }
    public func place(into model: inout SurfaceModel, display: Int, textRow: inout Int) {
        guard textRow <= 2 else { return }
        model.set(display, textRow, .spinner(speed: speed, length: length, reverse: reverse, column: column))
        textRow += 1
    }
}

@resultBuilder
public struct CellBuilder {
    public static func buildExpression(_ element: any CellElement) -> [any CellElement] { [element] }
    public static func buildBlock(_ parts: [any CellElement]...) -> [any CellElement] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [any CellElement]?) -> [any CellElement] { part ?? [] }
    public static func buildEither(first part: [any CellElement]) -> [any CellElement] { part }
    public static func buildEither(second part: [any CellElement]) -> [any CellElement] { part }
    public static func buildArray(_ parts: [[any CellElement]]) -> [any CellElement] { parts.flatMap { $0 } }
}

// MARK: - Screen elements

/// A top-level piece of a ``Screen``: a `Cell`, a `Lamp`, or the status-display
/// helpers. Each contributes to the lowered ``SurfaceModel``.
public protocol ScreenElement: Sendable {
    func render(into model: inout SurfaceModel)
}

/// One LCD (0…8) and its rows.
public struct Cell: ScreenElement {
    let display: Int
    let elements: [any CellElement]
    public init(_ display: Int, @CellBuilder _ content: () -> [any CellElement]) {
        self.display = display
        self.elements = content()
    }
    public func render(into model: inout SurfaceModel) {
        var textRow = 1
        for element in elements {
            element.place(into: &model, display: display, textRow: &textRow)
        }
    }
}

/// A button LED, including animated states.
public struct Lamp: ScreenElement {
    let led: KKButtonLED
    let state: LampState
    public init(_ led: KKButtonLED, _ state: LampState) {
        self.led = led
        self.state = state
    }
    public func render(into model: inout SurfaceModel) { model.setLamp(led, state) }
}

/// Global status line on the status display (0, row 1).
public struct Status: ScreenElement {
    let text: String
    public init(_ text: String) { self.text = text }
    public func render(into model: inout SurfaceModel) {
        model.set(0, 1, .text(text, .center, .marquee))
    }
}

/// Page indicator on the status display (0): `page/total` plus a position bar.
public struct PageIndicator: ScreenElement {
    let page: Int
    let total: Int
    public init(_ page: Int, of total: Int) {
        self.page = page
        self.total = total
    }
    public func render(into model: inout SurfaceModel) {
        model.set(0, 2, .text("\(page)/\(total)", .center, .clip))
        model.set(0, 0, .bar(total > 1 ? Double(page - 1) / Double(total - 1) : 0))
    }
}

@resultBuilder
public struct ScreenBuilder {
    public static func buildExpression(_ element: any ScreenElement) -> [any ScreenElement] { [element] }
    public static func buildBlock(_ parts: [any ScreenElement]...) -> [any ScreenElement] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [any ScreenElement]?) -> [any ScreenElement] { part ?? [] }
    public static func buildEither(first part: [any ScreenElement]) -> [any ScreenElement] { part }
    public static func buildEither(second part: [any ScreenElement]) -> [any ScreenElement] { part }
    public static func buildArray(_ parts: [[any ScreenElement]]) -> [any ScreenElement] { parts.flatMap { $0 } }
}
