import Foundation
import KompleteKontrol

public struct MK2ModalDialogAction: Sendable, Equatable {
    public var title: String
    public var detail: String?

    public init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
}

public struct MK2ModalDialogColors: Sendable, Equatable {
    public var background: UInt16
    public var text: UInt16
    public var dim: UInt16
    public var accent: UInt16
    public var destructive: UInt16
    public var warning: UInt16
    public var question: UInt16
    public var selectionFill: UInt16
    public var border: UInt16

    public init(
        background: UInt16 = 0x0000,
        text: UInt16 = MK2HIG.Chrome.text,
        dim: UInt16 = MK2HIG.Chrome.dim,
        accent: UInt16 = MK2HIG.Chrome.accent,
        destructive: UInt16 = MK2HIG.Chrome.destructive,
        warning: UInt16 = MK2HIG.Palette.warn,
        question: UInt16 = 0x9a7f,
        selectionFill: UInt16 = MK2HIG.Selection.fill,
        border: UInt16 = MK2HIG.Chrome.border
    ) {
        self.background = background
        self.text = text
        self.dim = dim
        self.accent = accent
        self.destructive = destructive
        self.warning = warning
        self.question = question
        self.selectionFill = selectionFill
        self.border = border
    }

    public func accent(for severity: MK2ModalDialogSeverity) -> UInt16 {
        switch severity {
            case .info: accent
            case .warning: warning
            case .error: destructive
            case .question: question
        }
    }
}

public enum MK2ModalDialogSeverity: Sendable, Equatable, CaseIterable {
    case info
    case warning
    case error
    case question

    public var iconGlyph: String {
        switch self {
            case .info: "\u{e2ce}"      // info
            case .warning: "\u{e4e0}"   // warning
            case .error: "\u{e4f8}"     // x-circle
            case .question: "\u{e3e8}"  // question
        }
    }

    public var fallbackText: String {
        switch self {
            case .info: "i"
            case .warning: "!"
            case .error: "x"
            case .question: "?"
        }
    }
}

/// A modal surface dialog that owns both displays and the relevant hardware bindings.
///
/// The dialog is intentionally strict: 4-D wheel up/down and rotation move selection,
/// 4-D press confirms, and every other hardware button press dismisses the dialog.
public struct MK2ModalDialog: Sendable {
    private static let bodyLineAdvance = 24

    public var severity: MK2ModalDialogSeverity
    public var iconGlyph: String?
    public var title: String
    public var message: [String]
    public var actions: [MK2ModalDialogAction]
    public var selectedIndex: Int
    public var colors: MK2ModalDialogColors

    private let onSelectionChange: @Sendable (_ index: Int) -> Void
    private let onConfirm: @Sendable (_ index: Int) -> Void
    private let onDismiss: @Sendable () -> Void

    public init(
        severity: MK2ModalDialogSeverity = .info,
        iconGlyph: String? = nil,
        title: String,
        message: [String],
        actions: [MK2ModalDialogAction],
        selectedIndex: Int = 0,
        colors: MK2ModalDialogColors = MK2ModalDialogColors(),
        onSelectionChange: @escaping @Sendable (_ index: Int) -> Void,
        onConfirm: @escaping @Sendable (_ index: Int) -> Void,
        onDismiss: @escaping @Sendable () -> Void
    ) {
        self.severity = severity
        self.iconGlyph = iconGlyph
        self.title = title
        self.message = message
        self.actions = actions
        self.selectedIndex = selectedIndex
        self.colors = colors
        self.onSelectionChange = onSelectionChange
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
    }

    public func scene() -> MK2SurfaceScene2 {
        var bindings = MK2InputBindings2()
        bindNavigation(into: &bindings)
        bindDismissButtons(into: &bindings)
        return doubleScreen().scene(
            lamps: [:],
            bindings: bindings
        )
    }

    public func doubleScreen() -> MK2DoubleScreen {
        let renderer = try? FreeTypeTextRenderer()
        return MK2DoubleScreen(
            left: .fullScreen(leftFrame(renderer: renderer)),
            right: .fullScreen(rightFrame(renderer: renderer))
        )
    }

    private func bindNavigation(into bindings: inout MK2InputBindings2) {
        bindings.jog = { direction in
            switch direction {
                case .up:
                    select(delta: -1)
                case .down:
                    select(delta: 1)
                case .left, .right:
                    break
            }
        }
        bindings.jogCenter = {
            confirm()
        }
        bindings.jogScroll = { delta, _ in
            select(delta: delta)
        }
    }

    private func bindDismissButtons(into bindings: inout MK2InputBindings2) {
        for led in KKMK2ButtonLED.allCases where led.rawValue < KKMK2ButtonLED.strip1.rawValue {
            bindings.onPress(led, onDismiss)
        }
    }

    private func select(delta: Int) {
        guard !actions.isEmpty, delta != 0 else { return }
        let next = max(0, min(actions.count - 1, selectedIndex + delta))
        guard next != selectedIndex else { return }
        onSelectionChange(next)
    }

    private func confirm() {
        guard actions.indices.contains(selectedIndex) else { return }
        onConfirm(selectedIndex)
    }

    private func leftFrame(renderer: FreeTypeTextRenderer?) -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: colors.background)
        let tone = colors.accent(for: severity)
        let iconRect = MK2PixelRect(x: 16, y: 18, width: 96, height: 96)
        frame.drawRoundedPanel(iconRect, fill: colors.background, border: tone, radius: 8)
        drawIcon(renderer: renderer, glyph: iconGlyph ?? severity.iconGlyph, fallback: severity.fallbackText, into: &frame, rect: iconRect, color: tone)
        drawTitle(title, renderer: renderer, into: &frame, x: 136, y: iconRect.y, color: tone, maxWidth: 328)

        var y = 76
        var remainingLines = 6
        for paragraph in message where remainingLines > 0 {
            let drawn = drawWrappedBody(
                paragraph,
                renderer: renderer,
                into: &frame,
                x: 136,
                y: y,
                color: colors.text,
                maxWidth: 328,
                maxLines: remainingLines
            )
            y += drawn * Self.bodyLineAdvance
            remainingLines -= drawn
        }

        drawBody("4-D: Select and confirm, any other button cancels.", renderer: renderer, into: &frame, x: 24, y: 242, color: colors.dim, maxWidth: 432)
        return frame
    }

    private func rightFrame(renderer: FreeTypeTextRenderer?) -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: colors.background)
        let tone = colors.accent(for: severity)
        drawTitle("ACTIONS", renderer: renderer, into: &frame, x: 24, y: 12, color: tone, maxWidth: 432)

        for (index, action) in actions.enumerated() {
            let rect = MK2PixelRect(x: 24, y: 62 + index * 74, width: 432, height: 62)
            let selected = index == selectedIndex
            if selected {
                frame.drawSelectionHighlight(rect, radius: 7, fill: colors.selectionFill, accent: tone)
            }
            drawTitle(action.title, renderer: renderer, into: &frame, x: 44, y: rect.y + 8, color: selected ? colors.text : colors.dim, maxWidth: 392)
            if let detail = action.detail {
                drawBody(detail, renderer: renderer, into: &frame, x: 44, y: rect.y + 37, color: colors.dim, maxWidth: 392)
            }
        }

        return frame
    }

    private func drawTitle(
        _ text: String,
        renderer: FreeTypeTextRenderer?,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        color: UInt16,
        maxWidth: Int
    ) {
        let style = MK2HIG.titleTextStyle(color: color)
        guard let renderer, (try? renderer.drawText(text, into: &frame, x: x, y: y, style: style, maxWidth: maxWidth)) != nil else {
            BitmapLabel(text, font: .gridBold, color: color)
                .draw(into: &frame, x: x, y: y + 4, clip: MK2PixelRect(x: x, y: y, width: maxWidth, height: 24))
            return
        }
    }

    private func bodyStyle(color: UInt16) -> FreeTypeTextStyle {
        MK2HIG.bodyTextStyle(color: color)
    }

    private func drawBody(
        _ text: String,
        renderer: FreeTypeTextRenderer?,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        color: UInt16,
        maxWidth: Int
    ) {
        let style = bodyStyle(color: color)
        guard let renderer, (try? renderer.drawText(text, into: &frame, x: x, y: y, style: style, maxWidth: maxWidth)) != nil else {
            BitmapLabel(text, font: .grid, color: color)
                .draw(into: &frame, x: x, y: y + 3, clip: MK2PixelRect(x: x, y: y, width: maxWidth, height: 18))
            return
        }
    }

    @discardableResult
    private func drawWrappedBody(
        _ text: String,
        renderer: FreeTypeTextRenderer?,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        color: UInt16,
        maxWidth: Int,
        maxLines: Int
    ) -> Int {
        let style = bodyStyle(color: color)
        if let renderer, let layout = try? renderer.wrappedLayout(text, style: style, maxWidth: maxWidth) {
            let count = min(maxLines, layout.lines.count)
            for index in 0..<count {
                try? renderer.drawText(
                    layout.lines[index],
                    into: &frame,
                    x: x,
                    y: y + index * Self.bodyLineAdvance,
                    style: style,
                    maxWidth: maxWidth
                )
            }
            return count
        }

        let lines = wrappedBitmapLines(text, font: .grid, maxWidth: maxWidth)
        let count = min(maxLines, lines.count)
        for index in 0..<count {
            BitmapLabel(lines[index], font: .grid, color: color)
                .draw(
                    into: &frame,
                    x: x,
                    y: y + index * Self.bodyLineAdvance + 3,
                    clip: MK2PixelRect(x: x, y: y + index * Self.bodyLineAdvance, width: maxWidth, height: 18)
                )
        }
        return count
    }

    private func wrappedBitmapLines(_ text: String, font: SurfaceFont, maxWidth: Int) -> [String] {
        let words = text
            .split(whereSeparator: { $0.unicodeScalars.allSatisfy(\.properties.isWhitespace) })
            .map(String.init)
        guard !words.isEmpty else { return text.isEmpty ? [] : [""] }

        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if font.measure(candidate) <= maxWidth {
                current = candidate
            } else {
                if !current.isEmpty { lines.append(current) }
                current = word
            }
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return lines
    }

    private func drawIcon(
        renderer: FreeTypeTextRenderer?,
        glyph: String,
        fallback: String,
        into frame: inout MK2PixelFrame,
        rect: MK2PixelRect,
        color: UInt16
    ) {
        let style = MK2HIG.actionDialogIconStyle(color: color)
        if let renderer, let width = try? renderer.measure(glyph, style: style) {
            let x = rect.x + (rect.width - width) / 2
            let y = rect.y + 22
            if (try? renderer.drawText(glyph, into: &frame, x: x, y: y, style: style, maxWidth: rect.width)) != nil {
                return
            }
        }

        BitmapLabel(fallback, font: .readoutBold, color: color)
            .draw(into: &frame, x: rect.x + 36, y: rect.y + 32)
    }
}
