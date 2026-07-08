import Foundation
import KontrolSurfaceKit2

/// The generated Paulinche splash artwork: a deep-blue vertical gradient with two
/// phase-shifted sine waves, rendered as one panorama that spans both displays.
/// `bezelGapColumns` inserts virtual columns for the physical gap between the two
/// screens, so the waves appear to flow through the bezel instead of jumping.
public enum MK2PaulincheSplashArtwork {
    /// Calibrated on the S61 MK2 bench (Scene Lab SPLASH, E7): the waves flow
    /// visually through the physical bezel at 53 hidden columns.
    public static let defaultBezelGapColumns = 53

    public static func panorama(bezelGapColumns: Int = defaultBezelGapColumns) -> MK2PixelImage {
        let width = MK2PixelFrame.width * 2 + max(0, bezelGapColumns)
        let height = MK2PixelFrame.height
        var pixels = [UInt16](repeating: 0, count: width * height)

        // The gradient quantizes with ordered dithering — flat per-row fills band
        // visibly on the OLED once a brightness scrim compresses the dark levels.
        for y in 0..<height {
            let t = Double(y) / Double(height - 1)
            let r = 3.0 * (1 - t)
            let g = 10.0 * (1 - t)
            let b = 20.0 * (1 - t) + 2
            for x in 0..<width {
                pixels[y * width + x] = MK2OrderedDither.rgb565(r: r, g: g, b: b, x: x, y: y)
            }
        }

        func plot(x: Int, y: Int, height waveHeight: Int, color: UInt16) {
            for row in y..<(y + waveHeight) where row >= 0 && row < height {
                pixels[row * width + x] = color
            }
        }

        // The same spatial frequency the widget lab established: two full periods
        // per display width, continuous across the whole panorama.
        for x in 0..<width {
            let phase = Double(x) / Double(MK2PixelFrame.width) * .pi * 4
            let y1 = 136 + Int((sin(phase) * 78).rounded())
            let y2 = 136 + Int((sin(phase + 1.2) * 52).rounded())
            plot(x: x, y: y1 - 1, height: 3, color: MK2PaulincheRendererSupport.Palette.green)
            plot(x: x, y: y2, height: 2, color: MK2PaulincheRendererSupport.Palette.solo)
        }

        return MK2PixelImage(width: width, height: height, pixels: pixels)
    }
}
