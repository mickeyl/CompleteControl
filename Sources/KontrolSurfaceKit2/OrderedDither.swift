import Foundation

/// Ordered (Bayer 4×4) dithering for RGB565 quantization. Dark gradients and
/// brightness-scaled imagery otherwise collapse onto the few remaining 5/6-bit
/// levels and the OLED shows every level as a visible band; adding the positional
/// threshold before truncation trades the bands for an imperceptible pattern.
public enum MK2OrderedDither {
    private static let thresholds: [Double] = [
        0, 8, 2, 10,
        12, 4, 14, 6,
        3, 11, 1, 9,
        15, 7, 13, 5,
    ].map { ($0 + 0.5) / 16.0 }

    public static func threshold(x: Int, y: Int) -> Double {
        thresholds[((y & 3) << 2) | (x & 3)]
    }

    /// Quantizes fractional RGB565 components (r/b in 0…31, g in 0…63) with the
    /// positional dither threshold applied before truncation.
    public static func rgb565(r: Double, g: Double, b: Double, x: Int, y: Int) -> UInt16 {
        let t = threshold(x: x, y: y)
        let rq = UInt16(min(31, max(0, Int(r + t))))
        let gq = UInt16(min(63, max(0, Int(g + t))))
        let bq = UInt16(min(31, max(0, Int(b + t))))
        return (rq << 11) | (gq << 5) | bq
    }

    /// Scales an RGB565 pixel by `factor` with dithered quantization.
    public static func scaled(_ pixel: UInt16, by factor: Double, x: Int, y: Int) -> UInt16 {
        rgb565(
            r: Double((pixel >> 11) & 0x1f) * factor,
            g: Double((pixel >> 5) & 0x3f) * factor,
            b: Double(pixel & 0x1f) * factor,
            x: x,
            y: y
        )
    }
}
