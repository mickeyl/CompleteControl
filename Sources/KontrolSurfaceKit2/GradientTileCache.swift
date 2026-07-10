import Foundation

/// Pre-rendered tiles for `MK2PixelFrame.fillRoundedVerticalGradient`.
///
/// The gradient ramp, the corner coverage and the dither pattern depend only
/// on the rect's size, radius, colors and its 4×4 Bayer phase — not on what
/// the frame already contains or what gets drawn on top. Rendering a tile runs
/// per-pixel Double math plus 4× supersampling in the corners; doing that on
/// every frame render made the instrument editor's eight encoder cells cost
/// ~19 ms per render in debug builds. With the cache the math runs once per
/// distinct appearance and every further draw is a row-span memcpy plus a few
/// blended corner pixels.
enum MK2GradientTileCache {
    struct Key: Hashable {
        var width: Int
        var height: Int
        var radius: Int
        var top: UInt16
        var bottom: UInt16
        var phaseX: Int
        var phaseY: Int
        var smooth: Bool
    }

    struct Tile {
        /// Row-major pixels in wire byte order, ready for span copies.
        var pixels: [UInt16]
        /// Per-pixel alpha: 255 opaque, 0 outside the rounded rect, else an
        /// antialiased corner pixel that must blend over the destination.
        var coverage: [UInt8]
        /// Per-row inset outside of which pixels need the per-pixel coverage
        /// path; the span between the insets is fully opaque and memcpy-able.
        var rowInsets: [Int]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var tiles: [Key: Tile] = [:]
    private static let capacity = 128

    static func tile(for key: Key) -> Tile {
        lock.lock()
        if let tile = tiles[key] {
            lock.unlock()
            return tile
        }
        lock.unlock()

        let tile = render(key)

        lock.lock()
        if tiles.count >= capacity {
            tiles.removeAll(keepingCapacity: true)
        }
        tiles[key] = tile
        lock.unlock()
        return tile
    }

    /// Mirrors the previous in-place gradient loop bit for bit (same lerp, same
    /// dither phase, same supersampled corner coverage), just into a tile.
    private static func render(_ key: Key) -> Tile {
        let width = key.width
        let height = key.height
        let radius = key.radius
        var pixels = [UInt16](repeating: 0, count: width * height)
        var coverage = [UInt8](repeating: 0, count: width * height)
        var rowInsets = [Int](repeating: 0, count: height)

        let topR = Double((key.top >> 11) & 0x1f)
        let topG = Double((key.top >> 5) & 0x3f)
        let topB = Double(key.top & 0x1f)
        let bottomR = Double((key.bottom >> 11) & 0x1f)
        let bottomG = Double((key.bottom >> 5) & 0x3f)
        let bottomB = Double(key.bottom & 0x1f)
        let span = Double(max(1, height - 1))

        for localY in 0..<height {
            let t = Double(localY) / span
            let r = topR + (bottomR - topR) * t
            let g = topG + (bottomG - topG) * t
            let b = topB + (bottomB - topB) * t
            let ditherY = localY + key.phaseY
            let inCornerBand = localY < radius || localY >= height - radius
            let rowBase = localY * width

            if key.smooth, inCornerBand {
                rowInsets[localY] = min(radius, width)
                for localX in 0..<width {
                    let inCorner = localX < radius || localX >= width - radius
                    let pixelCoverage = inCorner
                        ? roundedRectCoverage(x: localX, y: localY, width: width, height: height, radius: radius, sampleCount: 4)
                        : 1
                    guard pixelCoverage > 0 else { continue }
                    pixels[rowBase + localX] = MK2OrderedDither.rgb565(r: r, g: g, b: b, x: localX + key.phaseX, y: ditherY).bigEndian
                    coverage[rowBase + localX] = pixelCoverage >= 1 ? 255 : UInt8((pixelCoverage * 255).rounded())
                }
            } else {
                let inset = radius > 0 ? roundedCornerInset(y: localY, height: height, radius: radius) : 0
                rowInsets[localY] = inset
                for localX in inset..<(width - inset) {
                    pixels[rowBase + localX] = MK2OrderedDither.rgb565(r: r, g: g, b: b, x: localX + key.phaseX, y: ditherY).bigEndian
                    coverage[rowBase + localX] = 255
                }
            }
        }

        return Tile(pixels: pixels, coverage: coverage, rowInsets: rowInsets)
    }

    // Exact copies of MK2PixelFrame's private corner helpers, so a cached tile
    // reproduces the in-place gradient pixel for pixel.

    private static func roundedCornerInset(y: Int, height: Int, radius: Int) -> Int {
        let dy: Int
        if y < radius {
            dy = radius - y - 1
        } else if y >= height - radius {
            dy = y - (height - radius)
        } else {
            return 0
        }
        return max(0, radius - Int(Double(radius * radius - dy * dy).squareRoot()))
    }

    private static func roundedRectCoverage(x: Int, y: Int, width: Int, height: Int, radius: Int, sampleCount: Int) -> Double {
        let samples = max(1, sampleCount)
        var inside = 0
        let total = samples * samples
        for sy in 0..<samples {
            for sx in 0..<samples {
                let sampleX = Double(x) + (Double(sx) + 0.5) / Double(samples)
                let sampleY = Double(y) + (Double(sy) + 0.5) / Double(samples)
                if isInsideRoundedRect(x: sampleX, y: sampleY, width: Double(width), height: Double(height), radius: Double(radius)) {
                    inside += 1
                }
            }
        }
        return Double(inside) / Double(total)
    }

    private static func isInsideRoundedRect(x: Double, y: Double, width: Double, height: Double, radius: Double) -> Bool {
        let nearestX = min(max(x, radius), width - radius)
        let nearestY = min(max(y, radius), height - radius)
        let dx = x - nearestX
        let dy = y - nearestY
        return dx * dx + dy * dy <= radius * radius
    }
}
