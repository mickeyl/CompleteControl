import Foundation
import KompleteKontrol

public enum MK2ScreenKind: Sendable, Equatable {
    case fullScreen
    case regular
}

public struct MK2Screen: Sendable {
    public var kind: MK2ScreenKind
    public var frame: MK2PixelFrame

    public init(kind: MK2ScreenKind, frame: MK2PixelFrame) {
        self.kind = kind
        self.frame = frame
    }

    public static func fullScreen(_ frame: MK2PixelFrame) -> MK2Screen {
        MK2Screen(kind: .fullScreen, frame: frame)
    }

    public static func regular(_ frame: MK2PixelFrame) -> MK2Screen {
        MK2Screen(kind: .regular, frame: frame)
    }
}

public struct MK2DoubleScreen: Sendable {
    public var left: MK2Screen
    public var right: MK2Screen

    public init(left: MK2Screen, right: MK2Screen) {
        self.left = left
        self.right = right
    }

    public func scene(
        lamps: [KKMK2ButtonLED: MK2LampState2] = [:],
        keyColors: [Int: KKRGB] = [:],
        bindings: MK2InputBindings2 = MK2InputBindings2()
    ) -> MK2SurfaceScene2 {
        MK2SurfaceScene2(
            left: left.frame,
            right: right.frame,
            lamps: lamps,
            keyColors: keyColors,
            bindings: bindings
        )
    }
}

public enum MK2ScreenSubtitleAlignment: Sendable, Equatable {
    case leading
    case trailing
}

public enum MK2ScreenHeader: Sendable {
    case none
    case title(title: String, subtitle: String? = nil, subtitleAlignment: MK2ScreenSubtitleAlignment = .trailing)
    case status([MK2StatusLineItem])

    public var height: Int {
        switch self {
            case .none:
                0
            case .title, .status:
                MK2ScreenLayout.headerHeight
        }
    }
}

public enum MK2ScreenFooter: Sendable, Equatable {
    case none
    case hint(String)
    case encoderArea(height: Int = 88)
    case filters(height: Int = 88)

    public var height: Int {
        switch self {
            case .none:
                0
            case .hint:
                28
            case let .encoderArea(height), let .filters(height):
                max(0, height)
        }
    }
}

public struct MK2ScreenProgressBar: Sendable, Equatable {
    public enum Placement: Sendable, Equatable {
        case top
        case bottom
    }

    public static let height = 4

    public var placement: Placement
    public var progress: Double
    public var fill: UInt16
    public var track: UInt16

    public init(
        placement: Placement = .top,
        progress: Double,
        fill: UInt16 = MK2HIG.Chrome.accent,
        track: UInt16 = MK2HIG.Chrome.footerFill
    ) {
        self.placement = placement
        self.progress = progress
        self.fill = fill
        self.track = track
    }
}

public struct MK2RegularScreenLayout: Sendable, Equatable {
    public var bounds: MK2PixelRect
    public var headerRect: MK2PixelRect?
    public var contentRect: MK2PixelRect
    public var footerRect: MK2PixelRect?
    public var progressRect: MK2PixelRect?
}

public enum MK2ScreenLayout {
    public static let bounds = MK2PixelFrame.bounds
    public static let margin = 8
    public static let headerHeight = 38
    public static let contentInset = 8
    public static let footerSpacing = 7

    public static func regular(
        header: MK2ScreenHeader = .none,
        footer: MK2ScreenFooter = .none,
        progress: MK2ScreenProgressBar.Placement? = nil
    ) -> MK2RegularScreenLayout {
        let headerHeight = header.height
        let headerRect = headerHeight > 0
            ? MK2PixelRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
            : nil
        let footerHeight = footer.height
        let footerRect = footerHeight > 0
            ? MK2PixelRect(x: 0, y: bounds.height - footerHeight, width: bounds.width, height: footerHeight)
            : nil

        let progressRect: MK2PixelRect? = switch progress {
            case .top:
                // Hugs the header's bottom rule; without a header it becomes the screen's top edge.
                MK2PixelRect(x: 0, y: headerRect?.maxY ?? 0, width: bounds.width, height: MK2ScreenProgressBar.height)
            case .bottom:
                // Hugs the footer's top border; without a footer it becomes the screen's bottom edge.
                MK2PixelRect(
                    x: 0,
                    y: footerRect.map { $0.y - MK2ScreenProgressBar.height } ?? (bounds.height - MK2ScreenProgressBar.height),
                    width: bounds.width,
                    height: MK2ScreenProgressBar.height
                )
            case nil:
                nil
        }

        let contentTop: Int = if let headerRect {
            headerRect.maxY + 5
        } else if let progressRect, progress == .top {
            progressRect.maxY + 5
        } else {
            contentInset
        }

        let contentBottom: Int = if let footerRect {
            footerRect.y - footerSpacing
        } else if let progressRect, progress == .bottom {
            progressRect.y - 5
        } else {
            bounds.height - contentInset
        }

        return MK2RegularScreenLayout(
            bounds: bounds,
            headerRect: headerRect,
            contentRect: MK2PixelRect(
                x: contentInset,
                y: contentTop,
                width: bounds.width - contentInset * 2,
                height: max(0, contentBottom - contentTop)
            ),
            footerRect: footerRect,
            progressRect: progressRect
        )
    }
}

public struct MK2ScreenChromeColors: Sendable, Equatable {
    public var background: UInt16
    public var headerFill: UInt16
    public var headerTopLine: UInt16
    public var text: UInt16
    public var dim: UInt16
    public var accent: UInt16
    public var border: UInt16
    public var headerRule: UInt16
    public var footerFill: UInt16

    public init(
        background: UInt16 = MK2HIG.Chrome.background,
        headerFill: UInt16 = MK2HIG.Chrome.headerFill,
        headerTopLine: UInt16 = MK2HIG.Chrome.headerTopLine,
        text: UInt16 = MK2HIG.Chrome.text,
        dim: UInt16 = MK2HIG.Chrome.dim,
        accent: UInt16 = MK2HIG.Chrome.accent,
        border: UInt16 = MK2HIG.Chrome.border,
        headerRule: UInt16 = MK2HIG.Chrome.headerBottomLine,
        footerFill: UInt16 = MK2HIG.Chrome.footerFill
    ) {
        self.background = background
        self.headerFill = headerFill
        self.headerTopLine = headerTopLine
        self.text = text
        self.dim = dim
        self.accent = accent
        self.border = border
        self.headerRule = headerRule
        self.footerFill = footerFill
    }
}

public struct MK2RegularScreenChrome: Sendable {
    public static let captionPixelSize = MK2HIG.Typography.captionPixelSize
    public static let bodyPixelSize = MK2HIG.Typography.bodyPixelSize

    public var header: MK2ScreenHeader
    public var footer: MK2ScreenFooter
    public var progress: MK2ScreenProgressBar?
    public var colors: MK2ScreenChromeColors

    public init(
        header: MK2ScreenHeader = .none,
        footer: MK2ScreenFooter = .none,
        progress: MK2ScreenProgressBar? = nil,
        colors: MK2ScreenChromeColors = MK2ScreenChromeColors()
    ) {
        self.header = header
        self.footer = footer
        self.progress = progress
        self.colors = colors
    }

    public var layout: MK2RegularScreenLayout {
        MK2ScreenLayout.regular(header: header, footer: footer, progress: progress?.placement)
    }

    public func draw(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer? = nil) {
        frame.fill(MK2ScreenLayout.bounds, colors.background)
        drawHeader(into: &frame, renderer: renderer)
        drawFooter(into: &frame, renderer: renderer)
        drawProgressBar(into: &frame)
    }

    public func drawHeader(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer? = nil) {
        switch header {
            case .none:
                return
            case let .title(title, subtitle, subtitleAlignment):
                drawHeaderBackdrop(into: &frame)
                drawCaption(title, into: &frame, renderer: renderer, x: 8, y: 8, color: colors.accent, maxWidth: 220)
                guard let subtitle else { return }
                switch subtitleAlignment {
                    case .leading:
                        drawCaption(subtitle, into: &frame, renderer: renderer, x: 8, y: 25, color: colors.dim, maxWidth: 456)
                    case .trailing:
                        drawTrailingCaption(subtitle, into: &frame, renderer: renderer, y: 8, color: colors.dim, maxWidth: 236)
                }
            case let .status(items):
                drawHeaderBackdrop(into: &frame)
                MK2StatusLine(y: 8, items: items).draw(into: &frame)
        }
    }

    private func drawHeaderBackdrop(into frame: inout MK2PixelFrame) {
        guard let headerRect = layout.headerRect else { return }
        frame.fill(headerRect, colors.headerFill)
        frame.fill(MK2PixelRect(x: 0, y: headerRect.y, width: headerRect.width, height: 1), colors.headerTopLine)
        frame.fill(MK2PixelRect(x: 0, y: headerRect.maxY - 1, width: headerRect.width, height: 1), colors.headerRule)
    }

    public func drawFooter(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer? = nil) {
        guard let footerRect = layout.footerRect else { return }
        switch footer {
            case .none:
                return
            case let .hint(text):
                drawBody(text, into: &frame, renderer: renderer, x: 18, y: footerRect.y + 7, color: colors.dim, maxWidth: 444)
            case .encoderArea, .filters:
                frame.fillRounded(footerRect, radius: 8, colors.footerFill, antialiased: true)
                frame.fill(MK2PixelRect(x: 0, y: footerRect.y, width: MK2PixelFrame.width, height: 1), colors.border)
        }
    }

    private func drawProgressBar(into frame: inout MK2PixelFrame) {
        guard let progress, let rect = layout.progressRect else { return }
        frame.fill(rect, progress.track)
        let clamped = max(0, min(1, progress.progress))
        let fillWidth = Int((Double(rect.width) * clamped).rounded())
        guard fillWidth > 0 else { return }
        frame.fill(MK2PixelRect(x: rect.x, y: rect.y, width: min(rect.width, fillWidth), height: rect.height), progress.fill)
    }

    private func drawCaption(
        _ text: String,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?,
        x: Int,
        y: Int,
        color: UInt16,
        maxWidth: Int
    ) {
        drawFreeType(
            text.uppercased(),
            into: &frame,
            renderer: renderer,
            x: x,
            y: y,
            weight: MK2HIG.Fonts.captionWeight,
            pixelSize: Self.captionPixelSize,
            color: color,
            maxWidth: maxWidth
        )
    }

    private func drawTrailingCaption(
        _ text: String,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?,
        y: Int,
        color: UInt16,
        maxWidth: Int
    ) {
        let text = text.uppercased()
        let style = MK2HIG.captionTextStyle(color: color)
        guard let renderer else { return }
        let width = min(maxWidth, (try? renderer.measure(text, style: style)) ?? maxWidth)
        try? renderer.drawText(text, into: &frame, x: 472 - width, y: y, style: style, maxWidth: maxWidth)
    }

    private func drawBody(
        _ text: String,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?,
        x: Int,
        y: Int,
        color: UInt16,
        maxWidth: Int
    ) {
        drawFreeType(
            text,
            into: &frame,
            renderer: renderer,
            x: x,
            y: y,
            weight: MK2HIG.Fonts.bodyWeight,
            pixelSize: Self.bodyPixelSize,
            color: color,
            maxWidth: maxWidth
        )
    }

    private func drawFreeType(
        _ text: String,
        into frame: inout MK2PixelFrame,
        renderer: FreeTypeTextRenderer?,
        x: Int,
        y: Int,
        weight: FreeTypeFontWeight,
        pixelSize: Int,
        color: UInt16,
        maxWidth: Int
    ) {
        let style = MK2HIG.textStyle(
            weight: weight,
            pixelSize: pixelSize,
            color: color
        )
        guard let renderer,
              (try? renderer.drawText(text, into: &frame, x: x, y: y, style: style, maxWidth: maxWidth)) != nil else {
            return
        }
    }
}
