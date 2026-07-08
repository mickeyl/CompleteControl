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

    /// The band height derives from the caption style the header text is set in,
    /// so tuning `MK2ScreenChromeTypography.captionPixelSize` resizes the header.
    /// A leading subtitle adds a second text line.
    public func height(for typography: MK2ScreenChromeTypography = MK2ScreenChromeTypography()) -> Int {
        switch self {
            case .none:
                return 0
            case let .title(_, subtitle, alignment):
                let base = typography.captionPixelSize * 2 + 2
                guard subtitle != nil, alignment == .leading else { return base }
                return base + typography.captionPixelSize + 2
            case .status:
                return typography.captionPixelSize * 2 + 2
        }
    }
}

public enum MK2ScreenFooter: Sendable, Equatable {
    case none
    case hint(String)
    case encoderArea(height: Int = 88)
    case filters(height: Int = 88)

    /// The hint band derives from the footnote style its text is set in; the encoder
    /// and filter areas keep their explicit widget-sized heights.
    public func height(for typography: MK2ScreenChromeTypography = MK2ScreenChromeTypography()) -> Int {
        switch self {
            case .none:
                0
            case .hint:
                typography.footnotePixelSize + 12
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

    public static let height = 2

    public var placement: Placement
    public var progress: Double
    public var fillStart: UInt16
    public var fillEnd: UInt16
    public var track: UInt16

    public init(
        placement: Placement = .top,
        progress: Double,
        fillStart: UInt16 = MK2HIG.Chrome.progressFillStart,
        fillEnd: UInt16 = MK2HIG.Chrome.progressFillEnd,
        track: UInt16 = MK2HIG.Chrome.footerFill
    ) {
        self.placement = placement
        self.progress = progress
        self.fillStart = fillStart
        self.fillEnd = fillEnd
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
    public static let contentInset = 8
    public static let footerSpacing = 7

    // The canonical on-screen slots for value cells bound to the four physical
    // encoders beneath each display. They sit bottom-flush (a 2 px breathing inset
    // to the glass edge) so the mapping to the hardware row below reads immediately —
    // trailing whitespace under an encoder cell breaks that association.
    public static let encoderSlotXs = [8, 126, 244, 362]
    public static let encoderSlotWidth = 102
    public static let encoderSlotHeight = 38
    public static let encoderSlotBottomInset = 2
    public static var encoderSlotBottom: Int { bounds.height - encoderSlotBottomInset }

    public static func encoderSlotRect(_ slot: Int) -> MK2PixelRect {
        MK2PixelRect(
            x: encoderSlotXs[min(encoderSlotXs.count - 1, max(0, slot))],
            y: encoderSlotBottom - encoderSlotHeight,
            width: encoderSlotWidth,
            height: encoderSlotHeight
        )
    }

    public static func regular(
        header: MK2ScreenHeader = .none,
        footer: MK2ScreenFooter = .none,
        progress: MK2ScreenProgressBar.Placement? = nil,
        typography: MK2ScreenChromeTypography = MK2ScreenChromeTypography()
    ) -> MK2RegularScreenLayout {
        let headerHeight = header.height(for: typography)
        let headerRect = headerHeight > 0
            ? MK2PixelRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
            : nil
        let footerHeight = footer.height(for: typography)
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

public struct MK2ScreenChromeTypography: Sendable, Equatable {
    public var captionPixelSize: Int
    public var footnotePixelSize: Int

    public init(
        captionPixelSize: Int = MK2HIG.Typography.captionPixelSize,
        footnotePixelSize: Int = MK2HIG.Typography.footnotePixelSize
    ) {
        self.captionPixelSize = max(1, captionPixelSize)
        self.footnotePixelSize = max(1, footnotePixelSize)
    }
}

public struct MK2RegularScreenChrome: Sendable {
    public static let captionPixelSize = MK2HIG.Typography.captionPixelSize
    public static let bodyPixelSize = MK2HIG.Typography.bodyPixelSize

    public var header: MK2ScreenHeader
    public var footer: MK2ScreenFooter
    public var progress: MK2ScreenProgressBar?
    public var typography: MK2ScreenChromeTypography
    public var colors: MK2ScreenChromeColors

    public init(
        header: MK2ScreenHeader = .none,
        footer: MK2ScreenFooter = .none,
        progress: MK2ScreenProgressBar? = nil,
        typography: MK2ScreenChromeTypography = MK2ScreenChromeTypography(),
        colors: MK2ScreenChromeColors = MK2ScreenChromeColors()
    ) {
        self.header = header
        self.footer = footer
        self.progress = progress
        self.typography = typography
        self.colors = colors
    }

    public var layout: MK2RegularScreenLayout {
        MK2ScreenLayout.regular(header: header, footer: footer, progress: progress?.placement, typography: typography)
    }

    public func draw(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer? = nil) {
        frame.fill(MK2ScreenLayout.bounds, colors.background)
        drawHeader(into: &frame, renderer: renderer)
        drawFooter(into: &frame, renderer: renderer)
        drawProgressBar(into: &frame)
    }

    public func drawHeader(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer? = nil) {
        // Visually centered in the single-line band: the geometric center minus 2 px,
        // because the em box carries more dead space below the caps than above.
        let lineY = (typography.captionPixelSize + 2) / 2 - 2
        switch header {
            case .none:
                return
            case let .title(title, subtitle, subtitleAlignment):
                drawHeaderBackdrop(into: &frame)
                drawCaption(title, into: &frame, renderer: renderer, x: 8, y: lineY, color: colors.accent, maxWidth: 220)
                guard let subtitle else { return }
                switch subtitleAlignment {
                    case .leading:
                        drawCaption(subtitle, into: &frame, renderer: renderer, x: 8, y: lineY + typography.captionPixelSize + 2, color: colors.dim, maxWidth: 456)
                    case .trailing:
                        drawTrailingCaption(subtitle, into: &frame, renderer: renderer, y: lineY, color: colors.dim, maxWidth: 236)
                }
            case let .status(items):
                drawHeaderBackdrop(into: &frame)
                MK2StatusLine(y: lineY, items: items).draw(into: &frame)
        }
    }

    private func drawHeaderBackdrop(into frame: inout MK2PixelFrame) {
        guard let headerRect = layout.headerRect else { return }
        drawChromeBand(headerRect, into: &frame)
    }

    public func drawFooter(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer? = nil) {
        guard let footerRect = layout.footerRect else { return }
        switch footer {
            case .none:
                return
            case let .hint(text):
                drawChromeBand(footerRect, into: &frame)
                let textY = footerRect.y + max(1, (footerRect.height - typography.footnotePixelSize) / 2 - 2)
                drawFootnote(text, into: &frame, renderer: renderer, x: 18, y: textY, color: colors.dim, maxWidth: 444)
            case .encoderArea, .filters:
                drawChromeBand(footerRect, into: &frame)
        }
    }

    // Shared raised-band look for header and footer: a bright bevel on the top edge,
    // a subtle vertical fill gradient (lit from above, falling into the bottom
    // shadow), and a shadow line on the bottom edge. The gradient is derived from
    // the single fill color so custom chrome palettes keep working.
    private func drawChromeBand(_ rect: MK2PixelRect, into frame: inout MK2PixelFrame) {
        let fillTop = Self.scale565(colors.headerFill, by: 1.4)
        let fillBottom = Self.scale565(colors.headerFill, by: 0.6)
        let span = Double(max(1, rect.height - 1))
        for row in 0..<rect.height {
            let color = Self.lerp565(fillTop, fillBottom, Double(row) / span)
            frame.fill(MK2PixelRect(x: rect.x, y: rect.y + row, width: rect.width, height: 1), color)
        }
        frame.fill(MK2PixelRect(x: rect.x, y: rect.y, width: rect.width, height: 1), colors.headerTopLine)
        frame.fill(MK2PixelRect(x: rect.x, y: rect.maxY - 1, width: rect.width, height: 1), colors.headerRule)
    }

    private func drawProgressBar(into frame: inout MK2PixelFrame) {
        guard let progress, let rect = layout.progressRect else { return }
        frame.fill(rect, progress.track)
        let clamped = max(0, min(1, progress.progress))
        let fillWidth = min(rect.width, Int((Double(rect.width) * clamped).rounded()))
        guard fillWidth > 0 else { return }
        // The fill runs a start→end gradient across its current width, so the bright
        // tip always marks the progress edge.
        let span = Double(max(1, fillWidth - 1))
        for offset in 0..<fillWidth {
            let color = Self.lerp565(progress.fillStart, progress.fillEnd, Double(offset) / span)
            frame.fill(MK2PixelRect(x: rect.x + offset, y: rect.y, width: 1, height: rect.height), color)
        }
    }

    private static func lerp565(_ from: UInt16, _ to: UInt16, _ t: Double) -> UInt16 {
        let t = max(0, min(1, t))
        func mix(_ a: UInt16, _ b: UInt16) -> UInt16 {
            UInt16((Double(a) + (Double(b) - Double(a)) * t).rounded())
        }
        let r = mix((from >> 11) & 0x1f, (to >> 11) & 0x1f)
        let g = mix((from >> 5) & 0x3f, (to >> 5) & 0x3f)
        let b = mix(from & 0x1f, to & 0x1f)
        return (r << 11) | (g << 5) | b
    }

    private static func scale565(_ color: UInt16, by factor: Double) -> UInt16 {
        func scaled(_ value: UInt16, max maxValue: Double) -> UInt16 {
            UInt16(Swift.min(maxValue, (Double(value) * factor).rounded()))
        }
        let r = scaled((color >> 11) & 0x1f, max: 31)
        let g = scaled((color >> 5) & 0x3f, max: 63)
        let b = scaled(color & 0x1f, max: 31)
        return (r << 11) | (g << 5) | b
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
            pixelSize: typography.captionPixelSize,
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
        let style = MK2HIG.textStyle(
            weight: MK2HIG.Fonts.captionWeight,
            pixelSize: typography.captionPixelSize,
            color: color
        )
        guard let renderer else { return }
        let width = min(maxWidth, (try? renderer.measure(text, style: style)) ?? maxWidth)
        try? renderer.drawText(text, into: &frame, x: 472 - width, y: y, style: style, maxWidth: maxWidth)
    }

    private func drawFootnote(
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
            pixelSize: typography.footnotePixelSize,
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
