import Foundation

/// The sanctioned horizontal separator forms (decision 2026-07-12): a solid
/// 1 px rule in a configurable color (border for quiet structure, accent for
/// emphasis), a dotted rule for the lightest touch, and the chrome band edge
/// (bevel over shadow) where a separation should read raised like the
/// header/footer chrome. Vertical rulers are deliberately not an element —
/// they remain a pattern-grid implementation detail.
public struct MK2SeparatorElement: MK2ScreenElement {
    public enum Style: Sendable, Equatable {
        /// Solid 1 px rule.
        case line(UInt16)
        /// Dotted 1 px rule, one lit pixel every `pitch`.
        case dotted(UInt16, pitch: Int)
        /// The chrome band edge: bright bevel over shadow line (2 px).
        case bandEdge

        public static let line = Style.line(MK2HIG.Chrome.border)
        public static let accent = Style.line(MK2HIG.Chrome.accent)
        public static let dotted = Style.dotted(MK2HIG.Chrome.dim, pitch: 2)
    }

    public var y: Int
    public var style: Style
    public var x: Int?
    public var width: Int?
    public var relativeToContent: Bool

    public init(
        y: Int,
        style: Style = .line,
        x: Int? = nil,
        width: Int? = nil,
        relativeToContent: Bool = true
    ) {
        self.y = y
        self.style = style
        self.x = x
        self.width = width
        self.relativeToContent = relativeToContent
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        let contentRect = relativeToContent ? context.layout?.contentRect : nil
        let originX = (contentRect?.x ?? 0) + (x ?? 0)
        let originY = (contentRect?.y ?? 0) + y
        let drawWidth = width ?? (contentRect?.width ?? MK2PixelFrame.width) - (x ?? 0)
        guard drawWidth > 0 else { return }

        switch style {
            case let .line(color):
                frame.hline(y: originY, x: originX, width: drawWidth, color: color)
            case let .dotted(color, pitch):
                frame.dottedHLine(y: originY, x: originX, width: drawWidth, color: color, pitch: pitch)
            case .bandEdge:
                frame.hline(y: originY, x: originX, width: drawWidth, color: context.chromeColors.headerTopLine)
                frame.hline(y: originY + 1, x: originX, width: drawWidth, color: context.chromeColors.headerRule)
        }
    }
}

public extension MK2PixelFrame {
    /// 1 px horizontal rule.
    mutating func hline(y: Int, x: Int = 0, width: Int = MK2PixelFrame.width, color: UInt16) {
        fill(MK2PixelRect(x: x, y: y, width: width, height: 1), color)
    }

    /// Dotted 1 px horizontal rule: one lit pixel every `pitch`.
    mutating func dottedHLine(y: Int, x: Int = 0, width: Int = MK2PixelFrame.width, color: UInt16, pitch: Int = 2) {
        let step = max(1, pitch)
        var column = x
        while column < x + width {
            fill(MK2PixelRect(x: column, y: y, width: 1, height: 1), color)
            column += step
        }
    }

    /// Dotted 1 px vertical rule: one lit pixel every `pitch`.
    mutating func dottedVLine(x: Int, y: Int, height: Int, color: UInt16, pitch: Int = 2) {
        let step = max(1, pitch)
        var row = y
        while row < y + height {
            fill(MK2PixelRect(x: x, y: row, width: 1, height: 1), color)
            row += step
        }
    }
}
