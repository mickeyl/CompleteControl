import KompleteKontrol

/// Ordered (Bayer 4×4) dithering for RGB565 quantization. Dark gradients and
/// brightness-scaled imagery otherwise collapse onto the few remaining 5/6-bit
/// levels and the OLED shows every level as a visible band; adding the positional
/// threshold before truncation trades the bands for an imperceptible pattern.
public enum MK2OrderedDither {
    public static func threshold(x: Int, y: Int) -> Double {
        KKRGB565OrderedDither.threshold(x: x, y: y)
    }

    /// Quantizes fractional RGB565 components (r/b in 0…31, g in 0…63) with the
    /// positional dither threshold applied before truncation.
    public static func rgb565(r: Double, g: Double, b: Double, x: Int, y: Int) -> UInt16 {
        KKRGB565OrderedDither.rgb565(r: r, g: g, b: b, x: x, y: y)
    }

    /// Interpolates between two RGB565 colors at `t` with dithered quantization —
    /// the building block for band-free gradient ramps in any direction. Exact
    /// endpoints stay exact: integer channel values survive the threshold.
    public static func lerp(_ from: UInt16, _ to: UInt16, t: Double, x: Int, y: Int) -> UInt16 {
        KKRGB565OrderedDither.lerp(from, to, t: t, x: x, y: y)
    }

    /// Scales an RGB565 pixel by `factor` with dithered quantization.
    public static func scaled(_ pixel: UInt16, by factor: Double, x: Int, y: Int) -> UInt16 {
        KKRGB565OrderedDither.scaled(pixel, by: factor, x: x, y: y)
    }
}
