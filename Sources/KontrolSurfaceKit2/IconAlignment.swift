import Foundation

/// Metric-driven vertical icon placement (2026-07-23). Phosphor ink sits on
/// the baseline and fills its em asymmetrically, so centering the layout box
/// hung every icon visibly high — and each call site compensated with its own
/// hand-tuned nudge (+0, -1, -2 across the kit). The fonts already carry the
/// truth: the icon's measured ink centers on the cap band of the text beside
/// it, so a font or size change re-centers every use without retuning.
public enum MK2IconAlignment {
    /// Optical anchor of a proportional text line: the center of its cap band
    /// (baseline - cap height … baseline), probed via "H". `textTop` is the
    /// `drawText` layout `y` of the line.
    public static func capBandCenter(
        textTop: Int,
        style: FreeTypeTextStyle,
        renderer: FreeTypeTextRenderer?
    ) -> Int? {
        guard let renderer,
              let metrics = try? renderer.metrics(style: style),
              let cap = try? renderer.inkExtent("H", style: style),
              cap.height > 0 else { return nil }
        return textTop + metrics.ascender + cap.top + cap.height / 2
    }

    /// Cap-band anchor of a `BitmapLabel`/`drawMonospaced` line, whose
    /// baseline is `labelTop + font.ascent` by contract.
    public static func capBandCenter(
        labelTop: Int,
        font: SurfaceFont,
        renderer: FreeTypeTextRenderer?
    ) -> Int? {
        guard let renderer,
              let cap = try? renderer.inkExtent("H", style: font.measurementStyle),
              cap.height > 0 else { return nil }
        return labelTop + font.ascent + cap.top + cap.height / 2
    }

    /// The `drawText` `y` that puts the glyph's measured ink center on
    /// `center` — for icons beside a text line pass a cap-band center, for
    /// icons alone in a panel pass the panel's mid-height.
    public static func iconTop(
        glyph: String,
        style: FreeTypeTextStyle,
        centeredOn center: Int,
        renderer: FreeTypeTextRenderer?
    ) -> Int? {
        guard let renderer,
              let metrics = try? renderer.metrics(style: style),
              let ink = try? renderer.inkExtent(glyph, style: style),
              ink.height > 0 else { return nil }
        return center - metrics.ascender - ink.top - ink.height / 2
    }
}

extension SurfaceFont {
    /// The mono face as a FreeType style for metric probes. Color is fixed:
    /// the run cache keys on family/weight/size/raster only, and extents do
    /// not depend on tint.
    var measurementStyle: FreeTypeTextStyle {
        FreeTypeTextStyle(
            familyID: familyID,
            weight: renderWeight,
            pixelSize: pixelSize,
            color: 0xffff,
            rasterMode: MK2HIG.Fonts.rasterMode
        )
    }
}
