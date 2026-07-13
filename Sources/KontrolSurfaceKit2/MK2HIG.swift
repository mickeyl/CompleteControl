import Foundation

public enum MK2HIG {
    public enum Fonts {
        public static let textFamilyID = "plex-sans-condensed"
        public static let textFamilyName = "IBM Plex Sans Condensed"
        public static let textRegularResourceName = "IBMPlexSansCondensed-Regular.otf"
        public static let textMediumResourceName = "IBMPlexSansCondensed-Medium.otf"

        public static let iconFamilyID = "phosphor-regular"
        public static let iconFamilyName = "Phosphor Regular"
        public static let iconResourceName = "Phosphor.ttf"

        public static let monoFamilyID = "jetbrains-mono"
        public static let monoFamilyName = "JetBrains Mono"
        public static let monoRegularResourceName = "JetBrainsMono-Regular.ttf"
        public static let monoBoldResourceName = "JetBrainsMono-Bold.ttf"

        public static let bodyWeight: FreeTypeFontWeight = .regular
        public static let captionWeight: FreeTypeFontWeight = .medium
        public static let titleWeight: FreeTypeFontWeight = .medium
        public static let iconWeight: FreeTypeFontWeight = .regular
        public static let surfaceRegularWeight: FreeTypeFontWeight = .regular
        public static let surfaceBoldWeight: FreeTypeFontWeight = .bold
        public static let rasterMode: FreeTypeRasterMode = .grayscaleHinted
    }

    /// Curated Phosphor Regular glyphs for label-line icons
    /// (`MK2ValueCell.iconGlyph`, `MK2SelectionFilter.iconGlyph`). The names
    /// mirror the Phosphor catalog; pick by parameter semantics, one icon
    /// position per screen.
    ///
    /// This is a hand-picked subset, grown on demand: the full Phosphor
    /// Regular palette (≈1530 glyphs) lives in
    /// `Tools/MK2WidgetLabDemo/PhosphorIcons.regular.json`. When a screen
    /// needs a glyph that is not here yet, look up its codepoint there and add
    /// a `case` below — never scatter raw `\u{…}` escapes through the demos or
    /// renderers. (The Icon Browser demo renders the whole JSON palette, so it
    /// doubles as the picker.)
    public enum IconGlyph {
        public static let anchor = "\u{e514}"                    // anchor
        public static let arrowLineLeft = "\u{e062}"             // arrow-line-left
        public static let arrowLineRight = "\u{e064}"            // arrow-line-right
        public static let arrowsDownUp = "\u{e098}"              // arrows-down-up
        public static let arrowsOutLineHorizontal = "\u{e534}"   // arrows-out-line-horizontal
        public static let flag = "\u{e244}"                      // flag
        public static let funnel = "\u{e266}"                    // funnel
        public static let gauge = "\u{e628}"                     // gauge
        public static let layout = "\u{e6d6}"                    // layout
        public static let lightbulb = "\u{e2dc}"                 // lightbulb
        public static let lightning = "\u{e2de}"                 // lightning
        public static let listBullets = "\u{e2f2}"               // list-bullets
        public static let loop = "\u{e3f6}"                      // repeat
        public static let magnifyingGlass = "\u{e30c}"           // magnifying-glass
        public static let musicNote = "\u{e33c}"                 // music-note
        public static let palette = "\u{e6c8}"                   // palette
        public static let percent = "\u{e3b6}"                   // percent
        public static let pianoKeys = "\u{e9c8}"                 // piano-keys
        public static let resize = "\u{ed6e}"                    // resize
        public static let ruler = "\u{e6b8}"                     // ruler
        public static let speakerHigh = "\u{e44a}"               // speaker-high
        public static let squaresFour = "\u{e464}"               // squares-four
        public static let sticker = "\u{e5ac}"                   // sticker
        public static let sun = "\u{e472}"                       // sun
        public static let textAa = "\u{e6ee}"                    // text-aa
        public static let textT = "\u{e48a}"                     // text-t
        public static let warning = "\u{e4e0}"                   // warning
        public static let waveSine = "\u{ea9a}"                  // wave-sine
    }

    public enum Typography {
        public static let bodyPixelSize = 16
        public static let captionPixelSize = 15
        public static let footnotePixelSize = 13
        public static let titlePixelSize = 24
        public static let actionDialogIconPixelSize = 48
    }

    public enum SurfaceFontMetrics {
        public static let gridAdvance = 8
        public static let gridCellHeight = 16
        public static let gridAscent = 12
        public static let gridPixelSize = 13

        public static let labelAdvance = 6
        public static let labelCellHeight = 13
        public static let labelAscent = 10
        public static let labelPixelSize = 10

        public static let readoutAdvance = 10
        public static let readoutCellHeight = 20
        public static let readoutAscent = 14
        public static let readoutPixelSize = 16
    }

    public enum Chrome {
        public static let background: UInt16 = 0x0841
        // Raised-band bevel for header and footer. Deliberately neutral graphite —
        // matching the dialog-surface tone — so the light-blue accent and the colorful
        // content carry the identity instead of competing with a tinted chrome. The
        // lit top edge sits well above the fill but below the dim text grey; the
        // bottom edge drops into true black shadow.
        public static let headerFill: UInt16 = 0x18e3   // (24, 28, 24) graphite panel
        public static let headerTopLine: UInt16 = 0x632c // (96, 100, 96) lit top edge
        public static let headerBottomLine: UInt16 = 0x0000 // true black shadow
        public static let text: UInt16 = 0xffff
        public static let dim: UInt16 = 0x8410
        public static let accent: UInt16 = 0x7dbf // light blue (123, 182, 255)
        // Shift-layer treatment: labels that only apply while SHIFT is held render
        // in this amber, the classic shifted-function idiom — deliberately not the
        // accent (call to action) and not plain text (base layer). Judged on
        // PNG so far; tune on the OLED.
        public static let shiftAccent: UInt16 = 0xfc00   // (255, 129, 0) amber
        public static let border: UInt16 = 0x4208
        public static let footerFill: UInt16 = 0x1083
        // Chrome progress gradient: deep blue running into a luminous cyan tip.
        // Deliberately not the accent — progress is ambient state, not a call
        // to action, and the cool ramp reads calmer against the graphite bands.
        public static let progressFillStart: UInt16 = 0x1294 // (16, 81, 160)
        public static let progressFillEnd: UInt16 = 0x465f   // (64, 201, 248)
    }

    /// Waveform palette, mirroring the Paulinche app's sample waveform view
    /// (`Design.Waveform` / `Design.Accent` in PaulincheApp) so hardware and
    /// app render sample material in one identity: black canvas, blue trace,
    /// green start/stop beacons, white playhead. Values are the app's sRGB
    /// tokens quantized to RGB565; opacity-based tokens are pre-composited
    /// over the black canvas. Change them here and in the app together.
    public enum Waveform {
        public static let background: UInt16 = 0x0000
        /// The app frames the waveform with a hairline, not a border: secondary at 18 %.
        public static let border: UInt16 = 0x2945
        /// App center line: secondary at 35 %.
        public static let centerLine: UInt16 = 0x39c7
        /// `Design.Waveform.trace` blue (0.18, 0.68, 1.0).
        public static let trace: UInt16 = 0x357f
        /// Trace dimmed to ~45 % for columns outside the highlighted region.
        public static let traceOutsideRegion: UInt16 = 0x1a6e
        /// Trace at 12 % over black — the app's loop-region shading.
        public static let regionFill: UInt16 = 0x08a4
        /// `Design.Waveform.loopMarker` (0.72, 0.83, 0.95).
        public static let regionEdge: UInt16 = 0xb69d
        /// `Design.Accent.startOffset` beacon green (0.33, 0.85, 0.42).
        public static let marker: UInt16 = 0x56cd
        /// App playhead: white at 86 % over black.
        public static let playhead: UInt16 = 0xdedb
        /// Matches the app's `SampleWaveformView` corner radius.
        public static let cornerRadius = 6
    }

    public static func bodyTextStyle(color: UInt16) -> FreeTypeTextStyle {
        textStyle(
            weight: Fonts.bodyWeight,
            pixelSize: Typography.bodyPixelSize,
            color: color
        )
    }

    public static func captionTextStyle(color: UInt16) -> FreeTypeTextStyle {
        textStyle(
            weight: Fonts.captionWeight,
            pixelSize: Typography.captionPixelSize,
            color: color
        )
    }

    /// Body-weight text one step below the body size — footers, annotations, and
    /// other secondary lines that should read quietly.
    public static func footnoteTextStyle(color: UInt16) -> FreeTypeTextStyle {
        textStyle(
            weight: Fonts.bodyWeight,
            pixelSize: Typography.footnotePixelSize,
            color: color
        )
    }

    public static func titleTextStyle(color: UInt16) -> FreeTypeTextStyle {
        textStyle(
            weight: Fonts.titleWeight,
            pixelSize: Typography.titlePixelSize,
            color: color
        )
    }

    public static func textStyle(weight: FreeTypeFontWeight, pixelSize: Int, color: UInt16) -> FreeTypeTextStyle {
        FreeTypeTextStyle(
            familyID: Fonts.textFamilyID,
            weight: weight,
            pixelSize: pixelSize,
            color: color,
            rasterMode: Fonts.rasterMode
        )
    }

    public static func iconStyle(pixelSize: Int, color: UInt16) -> FreeTypeTextStyle {
        FreeTypeTextStyle(
            familyID: Fonts.iconFamilyID,
            weight: Fonts.iconWeight,
            pixelSize: pixelSize,
            color: color,
            rasterMode: Fonts.rasterMode
        )
    }

    public static func actionDialogIconStyle(color: UInt16) -> FreeTypeTextStyle {
        iconStyle(pixelSize: Typography.actionDialogIconPixelSize, color: color)
    }
}
