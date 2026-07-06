import Foundation
import KompleteKontrol

public struct MK2ScreenContext: Sendable {
    public let layout: MK2RegularScreenLayout?
    public let renderer: FreeTypeTextRenderer?
    public let chromeColors: MK2ScreenChromeColors

    public init(
        layout: MK2RegularScreenLayout? = nil,
        renderer: FreeTypeTextRenderer? = nil,
        chromeColors: MK2ScreenChromeColors = MK2ScreenChromeColors()
    ) {
        self.layout = layout
        self.renderer = renderer
        self.chromeColors = chromeColors
    }
}

public struct MK2ScreenBuildResult: Sendable {
    public var screen: MK2Screen
    public var lamps: [KKMK2ButtonLED: MK2LampState2]
    public var keyColors: [Int: KKRGB]
    public var bindings: MK2InputBindings2

    public init(
        screen: MK2Screen,
        lamps: [KKMK2ButtonLED: MK2LampState2] = [:],
        keyColors: [Int: KKRGB] = [:],
        bindings: MK2InputBindings2 = MK2InputBindings2()
    ) {
        self.screen = screen
        self.lamps = lamps
        self.keyColors = keyColors
        self.bindings = bindings
    }

    public mutating func merge(_ other: MK2ScreenBuildResult) {
        lamps.merge(other.lamps) { _, next in next }
        keyColors.merge(other.keyColors) { _, next in next }
        bindings.merge(other.bindings)
    }
}

public protocol MK2ScreenElement: Sendable {
    func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult)
}

@resultBuilder
public enum MK2ScreenBuilder {
    public static func buildBlock(_ components: [any MK2ScreenElement]...) -> [any MK2ScreenElement] {
        components.flatMap { $0 }
    }

    public static func buildOptional(_ component: [any MK2ScreenElement]?) -> [any MK2ScreenElement] {
        component ?? []
    }

    public static func buildEither(first component: [any MK2ScreenElement]) -> [any MK2ScreenElement] {
        component
    }

    public static func buildEither(second component: [any MK2ScreenElement]) -> [any MK2ScreenElement] {
        component
    }

    public static func buildArray(_ components: [[any MK2ScreenElement]]) -> [any MK2ScreenElement] {
        components.flatMap { $0 }
    }

    public static func buildExpression(_ expression: any MK2ScreenElement) -> [any MK2ScreenElement] {
        [expression]
    }

    public static func buildExpression(_ expression: [any MK2ScreenElement]) -> [any MK2ScreenElement] {
        expression
    }
}

public struct MK2AnyScreenElement: MK2ScreenElement {
    private let applyBlock: @Sendable (inout MK2PixelFrame, MK2ScreenContext, inout MK2ScreenBuildResult) -> Void

    public init(_ applyBlock: @escaping @Sendable (inout MK2PixelFrame, MK2ScreenContext, inout MK2ScreenBuildResult) -> Void) {
        self.applyBlock = applyBlock
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        applyBlock(&frame, context, &result)
    }
}

public struct MK2RegularScreenDSL: Sendable {
    public var header: MK2ScreenHeader
    public var footer: MK2ScreenFooter
    public var colors: MK2ScreenChromeColors
    public var elements: [any MK2ScreenElement]

    public init(
        header: MK2ScreenHeader = .none,
        footer: MK2ScreenFooter = .none,
        colors: MK2ScreenChromeColors = MK2ScreenChromeColors(),
        @MK2ScreenBuilder content: () -> [any MK2ScreenElement]
    ) {
        self.header = header
        self.footer = footer
        self.colors = colors
        self.elements = content()
    }

    public func build(renderer: FreeTypeTextRenderer? = nil) -> MK2ScreenBuildResult {
        let chrome = MK2RegularScreenChrome(header: header, footer: footer, colors: colors)
        var frame = MK2PixelFrame()
        chrome.draw(into: &frame, renderer: renderer)
        var result = MK2ScreenBuildResult(screen: .regular(frame))
        let context = MK2ScreenContext(layout: chrome.layout, renderer: renderer, chromeColors: colors)
        for element in elements {
            element.apply(to: &frame, context: context, result: &result)
        }
        result.screen = .regular(frame)
        return result
    }
}

public struct MK2FullScreenDSL: Sendable {
    public var background: UInt16
    public var elements: [any MK2ScreenElement]

    public init(
        background: UInt16 = MK2HIG.Chrome.background,
        @MK2ScreenBuilder content: () -> [any MK2ScreenElement]
    ) {
        self.background = background
        self.elements = content()
    }

    public func build(renderer: FreeTypeTextRenderer? = nil) -> MK2ScreenBuildResult {
        var frame = MK2PixelFrame(fill: background)
        var result = MK2ScreenBuildResult(screen: .fullScreen(frame))
        let context = MK2ScreenContext(renderer: renderer)
        for element in elements {
            element.apply(to: &frame, context: context, result: &result)
        }
        result.screen = .fullScreen(frame)
        return result
    }
}

public struct MK2DoubleScreenDSL: Sendable {
    public var left: MK2ScreenBuildResult
    public var right: MK2ScreenBuildResult
    public var lamps: [KKMK2ButtonLED: MK2LampState2]
    public var keyColors: [Int: KKRGB]
    public var bindings: MK2InputBindings2

    public init(
        left: MK2ScreenBuildResult,
        right: MK2ScreenBuildResult,
        lamps: [KKMK2ButtonLED: MK2LampState2] = [:],
        keyColors: [Int: KKRGB] = [:],
        bindings: MK2InputBindings2 = MK2InputBindings2()
    ) {
        self.left = left
        self.right = right
        self.lamps = lamps
        self.keyColors = keyColors
        self.bindings = bindings
    }

    public func scene() -> MK2SurfaceScene2 {
        var mergedLamps = lamps
        mergedLamps.merge(left.lamps) { _, next in next }
        mergedLamps.merge(right.lamps) { _, next in next }

        var mergedKeyColors = keyColors
        mergedKeyColors.merge(left.keyColors) { _, next in next }
        mergedKeyColors.merge(right.keyColors) { _, next in next }

        var mergedBindings = bindings
        mergedBindings.merge(left.bindings)
        mergedBindings.merge(right.bindings)

        return MK2SurfaceScene2(
            left: left.screen.frame,
            right: right.screen.frame,
            lamps: mergedLamps,
            keyColors: mergedKeyColors,
            bindings: mergedBindings
        )
    }
}

public extension MK2SurfaceScene2 {
    init(_ doubleScreen: MK2DoubleScreenDSL) {
        self = doubleScreen.scene()
    }
}

public struct MK2RenderBlock: MK2ScreenElement {
    private let block: @Sendable (inout MK2PixelFrame, MK2ScreenContext) -> Void

    public init(_ block: @escaping @Sendable (inout MK2PixelFrame, MK2ScreenContext) -> Void) {
        self.block = block
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        block(&frame, context)
    }
}

public struct MK2ContentText: MK2ScreenElement {
    public enum Role: Sendable {
        case body
        case title
        case caption
        case custom(weight: FreeTypeFontWeight, pixelSize: Int)
    }

    public var text: String
    public var x: Int
    public var y: Int
    public var maxWidth: Int?
    public var role: Role
    public var color: UInt16
    public var relativeToContent: Bool

    public init(
        _ text: String,
        x: Int = 0,
        y: Int = 0,
        maxWidth: Int? = nil,
        role: Role = .body,
        color: UInt16 = MK2HIG.Chrome.text,
        relativeToContent: Bool = true
    ) {
        self.text = text
        self.x = x
        self.y = y
        self.maxWidth = maxWidth
        self.role = role
        self.color = color
        self.relativeToContent = relativeToContent
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        let origin = relativeToContent ? context.layout?.contentRect.origin ?? .zero : .zero
        let drawX = origin.x + x
        let drawY = origin.y + y
        let availableWidth = maxWidth ?? max(0, MK2PixelFrame.width - drawX - MK2ScreenLayout.contentInset)
        let style = textStyle()

        guard let renderer = context.renderer,
              (try? renderer.drawText(text, into: &frame, x: drawX, y: drawY, style: style, maxWidth: availableWidth)) != nil else {
            let font: SurfaceFont
            switch role {
                case .title:
                    font = .gridBold
                case .caption, .body, .custom:
                    font = .grid
            }
            BitmapLabel(text, font: font, color: color)
                .draw(into: &frame, x: drawX, y: drawY + 3, clip: MK2PixelRect(x: drawX, y: drawY, width: availableWidth, height: 26))
            return
        }
    }

    private func textStyle() -> FreeTypeTextStyle {
        switch role {
            case .body:
                MK2HIG.bodyTextStyle(color: color)
            case .title:
                MK2HIG.titleTextStyle(color: color)
            case .caption:
                MK2HIG.captionTextStyle(color: color)
            case let .custom(weight, pixelSize):
                MK2HIG.textStyle(weight: weight, pixelSize: pixelSize, color: color)
        }
    }
}

public struct MK2LampElement: MK2ScreenElement {
    public var led: KKMK2ButtonLED
    public var state: MK2LampState2

    public init(_ led: KKMK2ButtonLED, _ state: MK2LampState2) {
        self.led = led
        self.state = state
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        result.lamps[led] = state
    }
}

public struct MK2KeyColorElement: MK2ScreenElement {
    public var key: Int
    public var color: KKRGB

    public init(_ key: Int, _ color: KKRGB) {
        self.key = key
        self.color = color
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        result.keyColors[key] = color
    }
}

public struct MK2ButtonBindingElement: MK2ScreenElement {
    public var led: KKMK2ButtonLED
    public var event: ButtonEvent
    public var modifiers: MK2InputBindings2.ModifierRequirement
    private let handler: @Sendable () -> Void

    public enum ButtonEvent: Sendable {
        case press
        case release
        case hold
    }

    public init(
        _ led: KKMK2ButtonLED,
        event: ButtonEvent = .press,
        modifiers: MK2InputBindings2.ModifierRequirement = .any,
        handler: @escaping @Sendable () -> Void
    ) {
        self.led = led
        self.event = event
        self.modifiers = modifiers
        self.handler = handler
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        switch event {
            case .press:
                result.bindings.onPress(led, modifiers: modifiers, handler)
            case .release:
                result.bindings.onRelease(led, modifiers: modifiers, handler)
            case .hold:
                result.bindings.onHold(led, modifiers: modifiers, handler)
        }
    }
}

public struct MK2EncoderBindingElement: MK2ScreenElement {
    public var encoder: Int
    private let onChange: @Sendable (_ delta: Int, _ value: Int, _ timestampNanos: UInt64) -> Void
    private let onTouch: (@Sendable (_ touched: Bool) -> Void)?

    public init(
        _ encoder: Int,
        onTouch: (@Sendable (_ touched: Bool) -> Void)? = nil,
        onChange: @escaping @Sendable (_ delta: Int, _ value: Int, _ timestampNanos: UInt64) -> Void
    ) {
        self.encoder = encoder
        self.onTouch = onTouch
        self.onChange = onChange
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        result.bindings.encoder[encoder] = onChange
        if let onTouch {
            result.bindings.encoderTouch[encoder] = onTouch
        }
    }
}

private extension MK2PixelRect {
    var origin: MK2Point {
        MK2Point(x: x, y: y)
    }
}

private struct MK2Point: Sendable {
    var x: Int
    var y: Int

    static let zero = MK2Point(x: 0, y: 0)
}
