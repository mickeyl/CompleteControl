import Foundation
import KompleteKontrol

public struct MK2ScreenContext: Sendable {
    public let layout: MK2RegularScreenLayout?
    public let renderer: FreeTypeTextRenderer?
    public let chromeColors: MK2ScreenChromeColors
    /// Which variant pass is rendering: empty for the base layer, `[.shift]`
    /// while building the shift layer of a screen that declared one.
    public let modifiers: Set<MK2Modifier>

    public init(
        layout: MK2RegularScreenLayout? = nil,
        renderer: FreeTypeTextRenderer? = nil,
        chromeColors: MK2ScreenChromeColors = MK2ScreenChromeColors(),
        modifiers: Set<MK2Modifier> = []
    ) {
        self.layout = layout
        self.renderer = renderer
        self.chromeColors = chromeColors
        self.modifiers = modifiers
    }

    public var isShiftPass: Bool { modifiers.contains(.shift) }
}

public struct MK2ScreenBuildResult: Sendable {
    public var screen: MK2Screen
    public var lamps: [KKMK2ButtonLED: MK2LampState2]
    public var keyColors: [Int: KKRGB]
    public var bindings: MK2InputBindings2
    /// Set during the base pass by elements that declare shift content; the DSL
    /// builders then run a second pass with `context.modifiers = [.shift]` and
    /// store its output in the `shift*` fields below.
    public var wantsShiftPass: Bool
    public var shiftScreen: MK2Screen?
    public var shiftLamps: [KKMK2ButtonLED: MK2LampState2]
    public var shiftKeyColors: [Int: KKRGB]
    public var shiftBindings: MK2InputBindings2
    /// Prepared touch highlights of encoder-bound slots, keyed by encoder.
    /// The `screen` field is assigned when two results merge into a scene.
    public var touchOverlays: [Int: MK2EncoderTouchOverlay]

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
        wantsShiftPass = false
        shiftLamps = [:]
        shiftKeyColors = [:]
        shiftBindings = MK2InputBindings2()
        touchOverlays = [:]
    }

    public mutating func merge(_ other: MK2ScreenBuildResult) {
        lamps.merge(other.lamps) { _, next in next }
        keyColors.merge(other.keyColors) { _, next in next }
        bindings.merge(other.bindings)
        wantsShiftPass = wantsShiftPass || other.wantsShiftPass
        if let shiftScreen = other.shiftScreen { self.shiftScreen = shiftScreen }
        shiftLamps.merge(other.shiftLamps) { _, next in next }
        shiftKeyColors.merge(other.shiftKeyColors) { _, next in next }
        shiftBindings.merge(other.shiftBindings)
        touchOverlays.merge(other.touchOverlays) { _, next in next }
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
    public var progress: MK2ScreenProgressBar?
    public var typography: MK2ScreenChromeTypography
    public var colors: MK2ScreenChromeColors
    public var elements: [any MK2ScreenElement]

    public init(
        header: MK2ScreenHeader = .none,
        footer: MK2ScreenFooter = .none,
        progress: MK2ScreenProgressBar? = nil,
        typography: MK2ScreenChromeTypography = MK2ScreenChromeTypography(),
        colors: MK2ScreenChromeColors = MK2ScreenChromeColors(),
        @MK2ScreenBuilder content: () -> [any MK2ScreenElement]
    ) {
        self.header = header
        self.footer = footer
        self.progress = progress
        self.typography = typography
        self.colors = colors
        self.elements = content()
    }

    public func build(renderer: FreeTypeTextRenderer? = nil) -> MK2ScreenBuildResult {
        var result = buildPass(renderer: renderer, modifiers: [])
        guard result.wantsShiftPass else { return result }
        let shiftResult = buildPass(renderer: renderer, modifiers: [.shift])
        result.shiftScreen = shiftResult.screen
        result.shiftLamps = shiftResult.lamps
        result.shiftKeyColors = shiftResult.keyColors
        result.shiftBindings = shiftResult.bindings
        return result
    }

    private func buildPass(renderer: FreeTypeTextRenderer?, modifiers: Set<MK2Modifier>) -> MK2ScreenBuildResult {
        let chrome = MK2RegularScreenChrome(header: header, footer: footer, progress: progress, typography: typography, colors: colors)
        var frame = MK2PixelFrame()
        chrome.draw(into: &frame, renderer: renderer)
        var result = MK2ScreenBuildResult(screen: .regular(frame))
        let context = MK2ScreenContext(layout: chrome.layout, renderer: renderer, chromeColors: colors, modifiers: modifiers)
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
        var result = buildPass(renderer: renderer, modifiers: [])
        guard result.wantsShiftPass else { return result }
        let shiftResult = buildPass(renderer: renderer, modifiers: [.shift])
        result.shiftScreen = shiftResult.screen
        result.shiftLamps = shiftResult.lamps
        result.shiftKeyColors = shiftResult.keyColors
        result.shiftBindings = shiftResult.bindings
        return result
    }

    private func buildPass(renderer: FreeTypeTextRenderer?, modifiers: Set<MK2Modifier>) -> MK2ScreenBuildResult {
        var frame = MK2PixelFrame(fill: background)
        var result = MK2ScreenBuildResult(screen: .fullScreen(frame))
        let context = MK2ScreenContext(renderer: renderer, modifiers: modifiers)
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

        var overlays: [Int: MK2EncoderTouchOverlay] = [:]
        for (screenIndex, result) in [left, right].enumerated() {
            for (encoder, overlay) in result.touchOverlays {
                var placed = overlay
                placed.screen = screenIndex
                overlays[encoder] = placed
            }
        }

        return MK2SurfaceScene2(
            left: left.screen.frame,
            right: right.screen.frame,
            lamps: mergedLamps,
            keyColors: mergedKeyColors,
            bindings: mergedBindings,
            shift: shiftLayer(),
            encoderTouchOverlays: overlays
        )
    }

    private func shiftLayer() -> MK2SurfaceScene2.ShiftLayer? {
        MK2SurfaceScene2.ShiftLayer(left: left, right: right)
    }
}

public extension MK2SurfaceScene2.ShiftLayer {
    /// Merges the shift output of two screen build results into one scene layer;
    /// nil when neither side declared shift content. `MK2DoubleScreenDSL` uses
    /// this, and clients that assemble `MK2SurfaceScene2` by hand should too.
    init?(left: MK2ScreenBuildResult, right: MK2ScreenBuildResult) {
        guard left.shiftScreen != nil || right.shiftScreen != nil else { return nil }
        var lamps = left.shiftLamps
        lamps.merge(right.shiftLamps) { _, next in next }
        var keyColors = left.shiftKeyColors
        keyColors.merge(right.shiftKeyColors) { _, next in next }
        var bindings = left.shiftBindings
        bindings.merge(right.shiftBindings)
        self.init(
            left: left.shiftScreen?.frame,
            right: right.shiftScreen?.frame,
            lamps: lamps,
            keyColors: keyColors,
            bindings: bindings
        )
    }
}

public extension MK2SurfaceScene2 {
    init(_ doubleScreen: MK2DoubleScreenDSL) {
        self = doubleScreen.scene()
    }
}

/// The generic shift-variance element: its `shifted` branch renders only into
/// the shift layer, the optional `otherwise` branch only into the base layer.
/// Elements outside a branch render identically in both layers, so wrapping
/// only what actually changes keeps the two passes aligned by construction.
public struct MK2ShiftBranch: MK2ScreenElement {
    public var shifted: [any MK2ScreenElement]
    public var base: [any MK2ScreenElement]

    public init(
        @MK2ScreenBuilder _ shifted: () -> [any MK2ScreenElement],
        @MK2ScreenBuilder otherwise base: () -> [any MK2ScreenElement] = { [] }
    ) {
        self.shifted = shifted()
        self.base = base()
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        result.wantsShiftPass = true
        for element in context.isShiftPass ? shifted : base {
            element.apply(to: &frame, context: context, result: &result)
        }
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
        case footnote
        case custom(weight: FreeTypeFontWeight, pixelSize: Int)
    }

    public enum Alignment: Sendable, Equatable {
        case leading
        case center
        case trailing
    }

    public var text: String
    public var x: Int
    public var y: Int
    public var maxWidth: Int?
    public var role: Role
    public var color: UInt16
    public var alignment: Alignment
    public var relativeToContent: Bool
    public var maxLines: Int?
    public var lineSpacing: Int

    public init(
        _ text: String,
        x: Int = 0,
        y: Int = 0,
        maxWidth: Int? = nil,
        role: Role = .body,
        color: UInt16 = MK2HIG.Chrome.text,
        alignment: Alignment = .leading,
        relativeToContent: Bool = true,
        maxLines: Int? = nil,
        lineSpacing: Int = 0
    ) {
        self.text = text
        self.x = x
        self.y = y
        self.maxWidth = maxWidth
        self.role = role
        self.color = color
        self.alignment = alignment
        self.relativeToContent = relativeToContent
        self.maxLines = maxLines
        self.lineSpacing = max(0, lineSpacing)
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        let origin = relativeToContent ? context.layout?.contentRect.origin ?? .zero : .zero
        let boxX = origin.x + x
        let drawY = origin.y + y
        let availableWidth = maxWidth ?? max(0, MK2PixelFrame.width - boxX - MK2ScreenLayout.contentInset)
        let style = textStyle()

        if let renderer = context.renderer {
            if let maxLines, maxLines > 1,
               (try? renderer.drawWrappedText(
                    text,
                    into: &frame,
                    x: boxX,
                    y: drawY,
                    style: style,
                    maxWidth: availableWidth,
                    maxLines: maxLines,
                    lineSpacing: lineSpacing
               )) != nil {
                return
            }

            let drawX = alignedX(boxX: boxX, availableWidth: availableWidth) {
                (try? renderer.measure(text, style: style)) ?? availableWidth
            }
            if (try? renderer.drawText(text, into: &frame, x: drawX, y: drawY, style: style, maxWidth: availableWidth)) != nil {
                return
            }
        }

        let font: SurfaceFont
        switch role {
            case .title:
                font = .gridBold
            case .caption, .body, .footnote, .custom:
                font = .grid
        }
        let lines = maxLines.map { wrappedBitmapLines(text, font: font, maxWidth: availableWidth, maxLines: max(1, $0)) } ?? [text]
        let lineAdvance = font.cellHeight + lineSpacing
        for (index, line) in lines.enumerated() {
            let y = drawY + 3 + index * lineAdvance
            let drawX = alignedX(boxX: boxX, availableWidth: availableWidth) { line.count * font.advance }
            BitmapLabel(line, font: font, color: color)
                .draw(into: &frame, x: drawX, y: y, clip: MK2PixelRect(x: boxX, y: y, width: availableWidth, height: font.cellHeight))
        }
    }

    private func alignedX(boxX: Int, availableWidth: Int, measure: () -> Int) -> Int {
        guard alignment != .leading else { return boxX }
        let textWidth = min(availableWidth, measure())
        return switch alignment {
            case .leading: boxX
            case .center: boxX + (availableWidth - textWidth) / 2
            case .trailing: boxX + availableWidth - textWidth
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
            case .footnote:
                MK2HIG.footnoteTextStyle(color: color)
            case let .custom(weight, pixelSize):
                MK2HIG.textStyle(weight: weight, pixelSize: pixelSize, color: color)
        }
    }
}

public struct MK2StatusLineElement: MK2ScreenElement {
    public var y: Int
    public var items: [MK2StatusLineItem]
    public var relativeToContent: Bool

    public init(y: Int = 0, items: [MK2StatusLineItem], relativeToContent: Bool = true) {
        self.y = y
        self.items = items
        self.relativeToContent = relativeToContent
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        let originY = relativeToContent ? context.layout?.contentRect.y ?? 0 : 0
        MK2StatusLine(y: originY + y, items: items).draw(into: &frame)
    }
}

public struct MK2ValueCellElement: MK2ScreenElement {
    public var cell: MK2ValueCell
    public var relativeToContent: Bool

    public init(_ cell: MK2ValueCell, relativeToContent: Bool = true) {
        self.cell = cell
        self.relativeToContent = relativeToContent
    }

    public init(
        label: String,
        value: String,
        rect: MK2PixelRect,
        isFocused: Bool = false,
        valueFont: SurfaceFont = .readoutBold,
        labelFont: SurfaceFont = .label,
        cornerRadius: Int = 0,
        colors: MK2ValueCellColors,
        relativeToContent: Bool = true
    ) {
        self.cell = MK2ValueCell(
            label: label,
            value: value,
            rect: rect,
            isFocused: isFocused,
            valueFont: valueFont,
            labelFont: labelFont,
            cornerRadius: cornerRadius,
            colors: colors
        )
        self.relativeToContent = relativeToContent
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        var cell = cell
        if relativeToContent, let contentRect = context.layout?.contentRect {
            cell.rect = MK2PixelRect(
                x: contentRect.x + cell.rect.x,
                y: contentRect.y + cell.rect.y,
                width: cell.rect.width,
                height: cell.rect.height
            )
        }
        cell.draw(into: &frame)
    }
}

public struct MK2EncoderFooterElement: MK2ScreenElement {
    public var displays: [MK2EncoderDiscreteValueDisplay]

    public init(_ displays: [MK2EncoderDiscreteValueDisplay]) {
        self.displays = displays
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        for display in displays {
            display.draw(into: &frame)
        }
    }
}

public struct MK2EncoderDiscreteValueElement: MK2ScreenElement {
    public var value: MK2EncoderDiscreteValue
    public var drawsDisplay: Bool

    public init(_ value: MK2EncoderDiscreteValue, drawsDisplay: Bool = true) {
        self.value = value
        self.drawsDisplay = drawsDisplay
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        value.apply(bindings: &result.bindings)
        if drawsDisplay {
            value.drawDisplay(into: &frame)
        }
    }
}

public struct MK2EncoderDiscreteValuesElement: MK2ScreenElement {
    public var values: [MK2EncoderDiscreteValue]
    public var drawsDisplays: Bool

    public init(_ values: [MK2EncoderDiscreteValue], drawsDisplays: Bool = true) {
        self.values = values
        self.drawsDisplays = drawsDisplays
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        for value in values {
            value.apply(bindings: &result.bindings)
            if drawsDisplays {
                value.drawDisplay(into: &frame)
            }
        }
    }
}

public struct MK2SelectionListElement: MK2ScreenElement {
    public var list: MK2SelectionList

    public init(_ list: MK2SelectionList) {
        self.list = list
    }

    public init(
        title: String,
        subtitle: String? = nil,
        items: [MK2SelectionItem],
        selectedIndex: Int,
        filters: [MK2SelectionFilter] = [],
        rowHeight: Int = 36,
        rowGap: Int = 6,
        colors: MK2SelectionViewColors = MK2SelectionViewColors()
    ) {
        self.list = MK2SelectionList(
            title: title,
            subtitle: subtitle,
            items: items,
            selectedIndex: selectedIndex,
            filters: filters,
            rowHeight: rowHeight,
            rowGap: rowGap,
            colors: colors
        )
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        list.draw(into: &frame, renderer: context.renderer)
    }
}

public struct MK2SelectionGridElement: MK2ScreenElement {
    public var grid: MK2SelectionGrid

    public init(_ grid: MK2SelectionGrid) {
        self.grid = grid
    }

    public init(
        title: String,
        subtitle: String? = nil,
        items: [MK2SelectionItem],
        selectedIndex: Int,
        cellSize: MK2SelectionCellSize,
        filters: [MK2SelectionFilter] = [],
        colors: MK2SelectionViewColors = MK2SelectionViewColors(),
        cellContent: MK2SelectionGrid.CellContent = .iconAndText
    ) {
        self.grid = MK2SelectionGrid(
            title: title,
            subtitle: subtitle,
            items: items,
            selectedIndex: selectedIndex,
            cellSize: cellSize,
            filters: filters,
            colors: colors,
            cellContent: cellContent
        )
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        grid.draw(into: &frame, renderer: context.renderer)
    }
}

public struct MK2SelectionInputElement: MK2ScreenElement {
    public var navigation: MK2SelectionNavigation
    public var itemCount: Int
    public var layout: MK2SelectionJogLayout
    public var availableLamp: MK2LampState2
    public var unavailableLamp: MK2LampState2
    public var wraps: Bool
    public var bindsMainEncoder: Bool
    private let onMove: @Sendable (_ delta: Int) -> Void
    private let onConfirm: (@Sendable () -> Void)?

    public init(
        navigation: MK2SelectionNavigation,
        itemCount: Int,
        layout: MK2SelectionJogLayout,
        availableLamp: MK2LampState2 = .white,
        unavailableLamp: MK2LampState2 = .off,
        wraps: Bool = false,
        bindsMainEncoder: Bool = true,
        onMove: @escaping @Sendable (_ delta: Int) -> Void,
        onConfirm: (@Sendable () -> Void)? = nil
    ) {
        self.navigation = navigation
        self.itemCount = itemCount
        self.layout = layout
        self.availableLamp = availableLamp
        self.unavailableLamp = unavailableLamp
        self.wraps = wraps
        self.bindsMainEncoder = bindsMainEncoder
        self.onMove = onMove
        self.onConfirm = onConfirm
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        navigation.applyJogLamps(
            to: &result.lamps,
            itemCount: itemCount,
            layout: layout,
            availableLamp: availableLamp,
            unavailableLamp: unavailableLamp,
            wraps: wraps
        )

        result.bindings.jog = { direction in
            guard let delta = MK2SelectionLayout.jogDelta(for: direction, layout: layout),
                  navigation.canMove(by: delta, itemCount: itemCount, wraps: wraps) else { return }
            onMove(delta)
        }

        if bindsMainEncoder {
            result.bindings.jogScroll = { delta, _ in
                guard itemCount > 0, delta != 0 else { return }
                onMove(delta)
            }
        }

        if let onConfirm {
            result.bindings.jogCenter = {
                guard navigation.clampedSelectedIndex(itemCount: itemCount) != nil else { return }
                onConfirm()
            }
        }
    }
}

public struct MK2EmptyStateElement: MK2ScreenElement {
    public var title: String
    public var detail: String?
    public var iconGlyph: String?
    public var iconColor: UInt16

    public init(
        title: String,
        detail: String? = nil,
        iconGlyph: String? = nil,
        iconColor: UInt16 = MK2HIG.Chrome.accent
    ) {
        self.title = title
        self.detail = detail
        self.iconGlyph = iconGlyph
        self.iconColor = iconColor
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        let contentRect = context.layout?.contentRect ?? MK2PixelFrame.bounds
        let centerY = contentRect.y + max(0, contentRect.height - 96) / 2
        var textX = contentRect.x + 8
        if let iconGlyph, let renderer = context.renderer {
            try? renderer.drawText(
                iconGlyph,
                into: &frame,
                x: contentRect.x + 8,
                y: centerY,
                style: MK2HIG.iconStyle(pixelSize: 40, color: iconColor),
                maxWidth: 48
            )
            textX += 64
        }
        if let renderer = context.renderer {
            _ = try? renderer.drawText(title, into: &frame, x: textX, y: centerY + 4, style: MK2HIG.titleTextStyle(color: MK2HIG.Chrome.text), maxWidth: contentRect.maxX - textX - 8)
            if let detail {
                _ = try? renderer.drawWrappedText(detail, into: &frame, x: textX, y: centerY + 42, style: MK2HIG.bodyTextStyle(color: MK2HIG.Chrome.dim), maxWidth: contentRect.maxX - textX - 8, maxLines: 2, lineSpacing: 2)
            }
        } else {
            BitmapLabel(title, font: .gridBold, color: MK2HIG.Chrome.text).draw(into: &frame, x: textX, y: centerY + 8)
            if let detail {
                BitmapLabel(detail, font: .grid, color: MK2HIG.Chrome.dim)
                    .draw(into: &frame, x: textX, y: centerY + 34, clip: MK2PixelRect(x: textX, y: centerY + 34, width: max(0, contentRect.maxX - textX - 8), height: SurfaceFont.grid.cellHeight))
            }
        }
    }
}

public struct MK2BrowserDetailElement: MK2ScreenElement {
    public var title: String
    public var detail: String
    public var metadata: String?
    public var iconGlyph: String?
    public var y: Int
    public var iconColor: UInt16
    public var accentColor: UInt16
    public var relativeToContent: Bool

    public init(
        title: String,
        detail: String,
        metadata: String? = nil,
        iconGlyph: String? = nil,
        y: Int = 84,
        iconColor: UInt16 = MK2HIG.Chrome.accent,
        accentColor: UInt16 = MK2HIG.Chrome.accent,
        relativeToContent: Bool = true
    ) {
        self.title = title
        self.detail = detail
        self.metadata = metadata
        self.iconGlyph = iconGlyph
        self.y = y
        self.iconColor = iconColor
        self.accentColor = accentColor
        self.relativeToContent = relativeToContent
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        let contentRect = context.layout?.contentRect ?? MK2PixelFrame.bounds
        let originX = relativeToContent ? contentRect.x : 0
        let originY = relativeToContent ? contentRect.y : 0
        var textX = originX + 8
        let topY = originY + y

        if let iconGlyph, let renderer = context.renderer {
            _ = try? renderer.drawText(
                iconGlyph,
                into: &frame,
                x: originX + 16,
                y: topY + 2,
                style: MK2HIG.iconStyle(pixelSize: 48, color: iconColor),
                maxWidth: 56
            )
            textX += 76
        }

        let textWidth = max(0, MK2PixelFrame.width - textX - 24)
        if let renderer = context.renderer {
            _ = try? renderer.drawText(title, into: &frame, x: textX, y: topY, style: MK2HIG.titleTextStyle(color: MK2HIG.Chrome.text), maxWidth: textWidth)
            _ = try? renderer.drawWrappedText(detail, into: &frame, x: textX, y: topY + 38, style: MK2HIG.bodyTextStyle(color: MK2HIG.Chrome.dim), maxWidth: textWidth, maxLines: 2, lineSpacing: 2)
            if let metadata {
                _ = try? renderer.drawText(metadata, into: &frame, x: textX, y: topY + 78, style: MK2HIG.bodyTextStyle(color: accentColor), maxWidth: textWidth)
            }
        } else {
            BitmapLabel(title, font: .gridBold, color: MK2HIG.Chrome.text)
                .draw(into: &frame, x: textX, y: topY + 4, clip: MK2PixelRect(x: textX, y: topY + 4, width: textWidth, height: SurfaceFont.gridBold.cellHeight))
            BitmapLabel(detail, font: .grid, color: MK2HIG.Chrome.dim)
                .draw(into: &frame, x: textX, y: topY + 34, clip: MK2PixelRect(x: textX, y: topY + 34, width: textWidth, height: SurfaceFont.grid.cellHeight))
            if let metadata {
                BitmapLabel(metadata, font: .grid, color: accentColor)
                    .draw(into: &frame, x: textX, y: topY + 66, clip: MK2PixelRect(x: textX, y: topY + 66, width: textWidth, height: SurfaceFont.grid.cellHeight))
            }
        }
    }
}

public struct MK2ProgressBarElement: MK2ScreenElement {
    public var rect: MK2PixelRect
    public var progress: Double
    public var fill: UInt16
    public var track: UInt16
    public var border: UInt16
    public var relativeToContent: Bool

    public init(
        rect: MK2PixelRect,
        progress: Double,
        fill: UInt16 = MK2HIG.Chrome.accent,
        track: UInt16 = MK2HIG.Chrome.footerFill,
        border: UInt16 = MK2HIG.Chrome.border,
        relativeToContent: Bool = true
    ) {
        self.rect = rect
        self.progress = progress
        self.fill = fill
        self.track = track
        self.border = border
        self.relativeToContent = relativeToContent
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        let contentRect = context.layout?.contentRect
        let drawRect = relativeToContent
            ? MK2PixelRect(x: (contentRect?.x ?? 0) + rect.x, y: (contentRect?.y ?? 0) + rect.y, width: rect.width, height: rect.height)
            : rect
        frame.fill(drawRect, track)
        frame.stroke(drawRect, border)
        let clamped = max(0, min(1, progress))
        let fillWidth = max(0, min(drawRect.width - 2, Int((Double(max(0, drawRect.width - 2)) * clamped).rounded())))
        if fillWidth > 0 {
            frame.fill(MK2PixelRect(x: drawRect.x + 1, y: drawRect.y + 1, width: fillWidth, height: max(0, drawRect.height - 2)), fill)
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

public struct MK2PageIndicatorElement: MK2ScreenElement {
    public var currentIndex: Int
    public var pageCount: Int
    public var x: Int
    public var y: Int
    public var dotSize: Int
    public var spacing: Int
    public var activeColor: UInt16
    public var inactiveColor: UInt16
    public var relativeToContent: Bool

    public init(
        currentIndex: Int,
        pageCount: Int,
        x: Int,
        y: Int,
        dotSize: Int = 5,
        spacing: Int = 5,
        activeColor: UInt16 = MK2HIG.Chrome.accent,
        inactiveColor: UInt16 = MK2HIG.Chrome.border,
        relativeToContent: Bool = true
    ) {
        self.currentIndex = currentIndex
        self.pageCount = max(0, pageCount)
        self.x = x
        self.y = y
        self.dotSize = max(1, dotSize)
        self.spacing = max(0, spacing)
        self.activeColor = activeColor
        self.inactiveColor = inactiveColor
        self.relativeToContent = relativeToContent
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        guard pageCount > 0 else { return }
        let contentRect = context.layout?.contentRect
        let originX = relativeToContent ? contentRect?.x ?? 0 : 0
        let originY = relativeToContent ? contentRect?.y ?? 0 : 0
        let current = currentIndex.clamped(to: 0...(pageCount - 1))
        for index in 0..<pageCount {
            let rect = MK2PixelRect(
                x: originX + x + index * (dotSize + spacing),
                y: originY + y,
                width: dotSize,
                height: dotSize
            )
            frame.fillRounded(rect, radius: dotSize / 2, index == current ? activeColor : inactiveColor, antialiased: true)
        }
    }
}

public struct MK2TabBarElement: MK2ScreenElement {
    public struct Item: Sendable, Equatable {
        public var title: String

        public init(_ title: String) {
            self.title = title
        }
    }

    public var items: [Item]
    public var selectedIndex: Int
    public var rect: MK2PixelRect
    public var selectedFill: UInt16
    public var border: UInt16
    public var text: UInt16
    public var dim: UInt16
    public var relativeToContent: Bool

    public init(
        items: [Item],
        selectedIndex: Int,
        rect: MK2PixelRect,
        selectedFill: UInt16 = MK2HIG.Chrome.footerFill,
        border: UInt16 = MK2HIG.Chrome.border,
        text: UInt16 = MK2HIG.Chrome.text,
        dim: UInt16 = MK2HIG.Chrome.dim,
        relativeToContent: Bool = true
    ) {
        self.items = items
        self.selectedIndex = selectedIndex
        self.rect = rect
        self.selectedFill = selectedFill
        self.border = border
        self.text = text
        self.dim = dim
        self.relativeToContent = relativeToContent
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        guard !items.isEmpty else { return }
        let contentRect = context.layout?.contentRect
        let drawRect = relativeToContent
            ? MK2PixelRect(x: (contentRect?.x ?? 0) + rect.x, y: (contentRect?.y ?? 0) + rect.y, width: rect.width, height: rect.height)
            : rect
        frame.stroke(drawRect, border)
        let selected = selectedIndex.clamped(to: 0...(items.count - 1))
        let tabWidth = max(1, drawRect.width / items.count)
        for (index, item) in items.enumerated() {
            let x = drawRect.x + index * tabWidth
            let width = index == items.count - 1 ? drawRect.maxX - x : tabWidth
            let tabRect = MK2PixelRect(x: x, y: drawRect.y, width: width, height: drawRect.height)
            if index == selected {
                frame.fill(tabRect.insetBy(dx: 1, dy: 1), selectedFill)
            }
            if index > 0 {
                frame.fill(MK2PixelRect(x: x, y: drawRect.y, width: 1, height: drawRect.height), border)
            }
            let label = item.title.uppercased()
            let labelWidth = min(max(0, width - 6), label.count * SurfaceFont.label.advance)
            let labelX = x + max(3, (width - labelWidth) / 2)
            BitmapLabel(label, font: .label, color: index == selected ? text : dim)
                .draw(
                    into: &frame,
                    x: labelX,
                    y: drawRect.y + max(0, (drawRect.height - SurfaceFont.label.cellHeight) / 2),
                    clip: MK2PixelRect(x: x + 3, y: drawRect.y, width: max(0, width - 6), height: drawRect.height)
                )
        }
    }
}

private extension Int {
    func clamped(to bounds: ClosedRange<Int>) -> Int {
        Swift.min(bounds.upperBound, Swift.max(bounds.lowerBound, self))
    }
}

private extension MK2PixelRect {
    var origin: MK2Point {
        MK2Point(x: x, y: y)
    }

    func insetBy(dx: Int, dy: Int) -> MK2PixelRect {
        MK2PixelRect(x: x + dx, y: y + dy, width: max(0, width - dx * 2), height: max(0, height - dy * 2))
    }
}

private func wrappedBitmapLines(_ text: String, font: SurfaceFont, maxWidth: Int, maxLines: Int) -> [String] {
    let maxCharacters = max(1, maxWidth / max(1, font.advance))
    var lines: [String] = []
    var current = ""

    for word in text.split(separator: " ").map(String.init) {
        let candidate = current.isEmpty ? word : current + " " + word
        if candidate.count <= maxCharacters {
            current = candidate
            continue
        }

        if !current.isEmpty {
            lines.append(current)
            current = ""
        }

        var remainder = word
        while remainder.count > maxCharacters {
            let index = remainder.index(remainder.startIndex, offsetBy: maxCharacters)
            lines.append(String(remainder[..<index]))
            remainder = String(remainder[index...])
            if lines.count >= maxLines {
                return Array(lines.prefix(maxLines))
            }
        }
        current = remainder
    }

    if !current.isEmpty {
        lines.append(current)
    }
    return Array(lines.prefix(maxLines))
}

private struct MK2Point: Sendable {
    var x: Int
    var y: Int

    static let zero = MK2Point(x: 0, y: 0)
}
