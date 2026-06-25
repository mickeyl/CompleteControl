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

/// One LCD (0…8) and its rows. `onEncoder` binds the rotary encoder above this
/// display (encoder index == display index, 1…8) to a delta handler.
public struct Cell: ScreenElement {
    let display: Int
    let elements: [any CellElement]
    var encoderHandler: ((Int) -> Void)?

    public init(_ display: Int, @CellBuilder _ content: () -> [any CellElement]) {
        self.display = display
        self.elements = content()
    }

    public func onEncoder(_ handler: @escaping (Int) -> Void) -> Cell {
        var copy = self
        copy.encoderHandler = handler
        return copy
    }

    public func render(into model: inout SurfaceModel) {
        var textRow = 1
        for element in elements {
            element.place(into: &model, display: display, textRow: &textRow)
        }
        if let encoderHandler, (1...8).contains(display) {
            model.handlers.encoder[display] = encoderHandler
        }
    }
}

/// A button LED, including animated states. The handler modifiers bind the
/// matching hardware button's gestures: `onTap`, `onHold`, and `onSecondary`
/// (a tap on this button while another is held — the held one is the modifier).
public struct Lamp: ScreenElement {
    let led: KKButtonLED
    let state: LampState
    var tapHandler: (() -> Void)?
    var holdHandler: (() -> Void)?
    var secondaryHandler: ((String) -> Void)?

    public init(_ led: KKButtonLED, _ state: LampState) {
        self.led = led
        self.state = state
    }

    public func onTap(_ handler: @escaping () -> Void) -> Lamp {
        var copy = self
        copy.tapHandler = handler
        return copy
    }

    public func onHold(_ handler: @escaping () -> Void) -> Lamp {
        var copy = self
        copy.holdHandler = handler
        return copy
    }

    public func onSecondary(_ handler: @escaping (String) -> Void) -> Lamp {
        var copy = self
        copy.secondaryHandler = handler
        return copy
    }

    public func render(into model: inout SurfaceModel) {
        model.setLamp(led, state)
        let name = led.inputName
        if let tapHandler { model.handlers.tap[name] = tapHandler }
        if let holdHandler { model.handlers.hold[name] = holdHandler }
        if let secondaryHandler { model.handlers.secondary[name] = secondaryHandler }
    }
}

/// Declares the RGB light guide. The closure returns the colour for each key
/// index (0…24), or `nil` for off — so scales, chords, and played-note feedback
/// are just functions of state (compose them inside the closure). Keys not set
/// by the presented screen are cleared.
public struct KeyColors: ScreenElement {
    let color: (Int) -> KKRGB?
    public init(_ color: @escaping (Int) -> KKRGB?) { self.color = color }
    public func render(into model: inout SurfaceModel) {
        for index in 0..<KompleteKontrolS25MK1Protocol.keyCount {
            if let color = color(index) { model.setKey(index, color) }
        }
    }
}

/// Binds the main 4-D wheel's turn to a delta handler.
public struct MainEncoder: ScreenElement {
    let handler: (Int) -> Void
    public init(_ handler: @escaping (Int) -> Void) { self.handler = handler }
    public func render(into model: inout SurfaceModel) { model.handlers.mainEncoder = handler }
}

extension KKButtonLED {
    /// The decoder's input button name for this LED (they differ for a few).
    var inputName: String {
        switch self {
            case .shift: "shift"
            case .scale: "scale"
            case .arp: "arp"
            case .loop: "loop"
            case .rwd: "rewind"
            case .ffw: "fast forward"
            case .play: "play"
            case .rec: "rec"
            case .stop: "stop"
            case .pageLeft: "page left"
            case .pageRight: "page right"
            case .browse: "browse"
            case .presetUp: "preset up"
            case .instance: "instance"
            case .presetDown: "preset down"
            case .back: "back"
            case .navigateUp: "navigate up"
            case .enter: "enter"
            case .navigateLeft: "navigate left"
            case .navigateDown: "navigate down"
            case .navigateRight: "navigate right"
            case .octaveDownWhite, .octaveDownRed: "octave down"
            case .octaveUpWhite, .octaveUpRed: "octave up"
        }
    }
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
