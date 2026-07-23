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
    case encoderArea(height: Int = MK2ScreenLayout.encoderFooterHeight)
    case filters(height: Int = MK2ScreenLayout.encoderFooterHeight)

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
    // Horizontal whitespace is uniform: edge margins and inter-cell gaps all equal
    // `margin`, which the slot width fills exactly (8 + 4×110 + 3×8 + 8 = 480).
    public static let encoderSlotXs = [8, 126, 244, 362]
    public static let encoderSlotWidth = 110
    /// History: 38 until 2026-07-23 — the chrome-diet round (prompted by the
    /// MASCHINE MK3 factory-UI comparison) slimmed the well; the freed rows go
    /// to content, and the figure-band centering keeps values optically
    /// centered at any height. Bench-approved on the OLEDs.
    public static let encoderSlotHeight = 33
    public static let encoderSlotBottomInset = 2
    public static var encoderSlotBottom: Int { bounds.height - encoderSlotBottomInset }

    /// Height of the encoder/filter footer band: exactly the bottom-flush value
    /// cell with its label line plus a tight 6 px of air under the band's bevel —
    /// anything taller floats as dead space above the encoder row.
    public static var encoderFooterHeight: Int {
        encoderSlotHeight + encoderSlotBottomInset + SurfaceFont.label.cellHeight + MK2ValueCell.labelGap + 6
    }

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
    /// IBM Plex and fixed-pitch JetBrains Mono expose different top-of-em
    /// whitespace. Keep their hardware-calibrated origins independent.
    static let titleHeaderTextOpticalOffset = -3
    static let statusHeaderTextOpticalOffset = 0
    static let footerTextOpticalOffset = -3

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
        switch header {
            case .none:
                return
            case let .title(title, subtitle, subtitleAlignment):
                let lineY = Self.titleHeaderTextY(for: typography)
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
                MK2StatusLine(y: Self.statusHeaderTextY(for: typography), items: items).draw(into: &frame)
        }
    }

    private func drawHeaderBackdrop(into frame: inout MK2PixelFrame) {
        guard let headerRect = layout.headerRect else { return }
        drawChromeBand(headerRect, into: &frame, debossed: true)
    }

    public func drawFooter(into frame: inout MK2PixelFrame, renderer: FreeTypeTextRenderer? = nil) {
        guard let footerRect = layout.footerRect else { return }
        switch footer {
            case .none:
                return
            case let .hint(text):
                drawChromeBand(footerRect, into: &frame)
                let textY = Self.footerTextY(in: footerRect, typography: typography)
                drawFootnote(text, into: &frame, renderer: renderer, x: 18, y: textY, color: colors.dim, maxWidth: 444)
            case .encoderArea, .filters:
                drawChromeBand(footerRect, into: &frame)
        }
    }

    static func titleHeaderTextY(for typography: MK2ScreenChromeTypography) -> Int {
        (typography.captionPixelSize + 2) / 2 + titleHeaderTextOpticalOffset
    }

    static func statusHeaderTextY(for typography: MK2ScreenChromeTypography) -> Int {
        (typography.captionPixelSize + 2) / 2 + statusHeaderTextOpticalOffset
    }

    static func footerTextY(in rect: MK2PixelRect, typography: MK2ScreenChromeTypography) -> Int {
        rect.y + max(1, (rect.height - typography.footnotePixelSize) / 2 + footerTextOpticalOffset)
    }

    // Shared band painter. The footer keeps the raised look (lit top bevel,
    // bottom shadow). The header inverts the curve since 2026-07-23 (bench
    // decision from the MASCHINE factory-UI round): a debossed band whose lit
    // edge faces the content, so header and footer frame the content plane
    // with light from both sides and the chrome recedes at both screen edges.
    // The gradient derives from the single fill color so custom chrome
    // palettes keep working, and renders through the dithered gradient tile
    // cache — per-row 565 quantization banded visibly on bands taller than
    // the header.
    private func drawChromeBand(_ rect: MK2PixelRect, into frame: inout MK2PixelFrame, debossed: Bool = false) {
        frame.fillRoundedVerticalGradient(
            rect,
            radius: 0,
            top: colors.headerFill.scaled565(by: debossed ? 0.6 : 1.4),
            bottom: colors.headerFill.scaled565(by: debossed ? 1.4 : 0.6)
        )
        frame.fill(
            MK2PixelRect(x: rect.x, y: rect.y, width: rect.width, height: 1),
            debossed ? colors.headerRule : colors.headerTopLine
        )
        frame.fill(
            MK2PixelRect(x: rect.x, y: rect.maxY - 1, width: rect.width, height: 1),
            debossed ? colors.headerTopLine : colors.headerRule
        )
    }

    private func drawProgressBar(into frame: inout MK2PixelFrame) {
        guard let progress, let rect = layout.progressRect else { return }
        frame.fill(rect, progress.track)
        let clamped = max(0, min(1, progress.progress))
        let fillWidth = min(rect.width, Int((Double(rect.width) * clamped).rounded()))
        guard fillWidth > 0 else { return }
        // The fill runs a start→end gradient across its current width, so the bright
        // tip always marks the progress edge; dithered so the ramp stays band-free.
        let span = Double(max(1, fillWidth - 1))
        for offset in 0..<fillWidth {
            let t = Double(offset) / span
            for row in 0..<rect.height {
                frame[rect.x + offset, rect.y + row] = MK2OrderedDither.lerp(
                    progress.fillStart,
                    progress.fillEnd,
                    t: t,
                    x: rect.x + offset,
                    y: rect.y + row
                )
            }
        }
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
