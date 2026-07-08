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
        // matching the dialog-surface tone — so the yellow accent and the colorful
        // content carry the identity instead of competing with a tinted chrome. The
        // lit top edge sits well above the fill but below the dim text grey; the
        // bottom edge drops into true black shadow.
        public static let headerFill: UInt16 = 0x18e3   // (24, 28, 24) graphite panel
        public static let headerTopLine: UInt16 = 0x632c // (96, 100, 96) lit top edge
        public static let headerBottomLine: UInt16 = 0x0000 // true black shadow
        public static let text: UInt16 = 0xffff
        public static let dim: UInt16 = 0x8410
        public static let accent: UInt16 = 0xffe0
        public static let border: UInt16 = 0x4208
        public static let footerFill: UInt16 = 0x1083
        // Chrome progress gradient: deep blue running into a luminous cyan tip.
        // Deliberately not the yellow accent — progress is ambient state, not a call
        // to action, and the cool ramp reads calmer against the graphite bands.
        public static let progressFillStart: UInt16 = 0x1294 // (16, 81, 160)
        public static let progressFillEnd: UInt16 = 0x465f   // (64, 201, 248)
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
