import Foundation
import KompleteKontrol

public struct MK2PixelRect: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func clipped(to bounds: MK2PixelRect) -> MK2PixelRect? {
        let nx = max(x, bounds.x)
        let ny = max(y, bounds.y)
        let mx = min(maxX, bounds.maxX)
        let my = min(maxY, bounds.maxY)
        guard mx > nx, my > ny else { return nil }
        return MK2PixelRect(x: nx, y: ny, width: mx - nx, height: my - ny)
    }
}

public struct MK2PixelBlit: Sendable, Equatable {
    public var screen: Int
    public var rect: MK2PixelRect
    public var pixels: [UInt16]

    public init(screen: Int, rect: MK2PixelRect, pixels: [UInt16]) {
        self.screen = screen
        self.rect = rect
        self.pixels = pixels
    }
}

/// A drawing surface whose pixel storage is kept in wire byte order (big-endian
/// RGB565): colours are swapped once per draw call instead of once per pixel per
/// blit, so shipping a frame to the daemon is a plain memcpy. The hot paths use
/// bulk libc operations (memset_pattern4/memcmp/memcpy) deliberately — they keep
/// their speed in unoptimized builds, where per-element Swift loops do not.
/// Deliberately copyable: the reconciler's O(1) unchanged-frame detection relies
/// on CoW buffer identity across copies.
public struct MK2PixelFrame: Sendable, Equatable {
    public static let width = KompleteKontrolMK2Protocol.displayWidth
    public static let height = KompleteKontrolMK2Protocol.displayHeight
    public static let bounds = MK2PixelRect(x: 0, y: 0, width: width, height: height)

    /// Storage in wire byte order — feed it to a blit verbatim (`pixels.span` for a
    /// borrowed zero-copy view); use the subscript for host-order pixel values.
    public private(set) var pixels: [UInt16]

    public init(fill color: UInt16 = 0x0000) {
        pixels = Array(repeating: color.bigEndian, count: Self.width * Self.height)
    }

    public subscript(x: Int, y: Int) -> UInt16 {
        get { UInt16(bigEndian: pixels[y * Self.width + x]) }
        set {
            guard (0..<Self.width).contains(x), (0..<Self.height).contains(y) else { return }
            pixels[y * Self.width + x] = newValue.bigEndian
        }
    }

    public mutating func fill(_ rect: MK2PixelRect, _ color: UInt16) {
        guard let clipped = rect.clipped(to: Self.bounds) else { return }
        var pattern = patternPair(color.bigEndian)
        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for y in clipped.y..<clipped.maxY {
                memset_pattern4(base + y * Self.width + clipped.x, &pattern, clipped.width * 2)
            }
        }
    }

    /// Halves each RGB565 channel in a clipped rectangle. The integer mask
    /// keeps channel bits from bleeding into one another and makes dimming a
    /// full display body inexpensive enough for momentary overlays.
    mutating func dimHalf(_ rect: MK2PixelRect) {
        guard let clipped = rect.clipped(to: Self.bounds) else { return }
        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for y in clipped.y..<clipped.maxY {
                let row = y * Self.width
                for x in clipped.x..<clipped.maxX {
                    let index = row + x
                    let color = UInt16(bigEndian: base[index])
                    base[index] = ((color >> 1) & 0x7BEF).bigEndian
                }
            }
        }
    }

    public mutating func fillRounded(_ rect: MK2PixelRect, radius: Int, _ color: UInt16, antialiased: Bool = false) {
        let radius = max(0, min(radius, rect.width / 2, rect.height / 2))
        guard radius > 0 else {
            fill(rect, color)
            return
        }
        guard antialiased, MK2RenderSettings.antialiasingEnabled else {
            fillRoundedAliased(rect, radius: radius, color)
            return
        }

        let sampleCount = 4
        fill(MK2PixelRect(x: rect.x + radius, y: rect.y, width: rect.width - radius * 2, height: rect.height), color)
        fill(MK2PixelRect(x: rect.x, y: rect.y + radius, width: rect.width, height: rect.height - radius * 2), color)
        fillRoundedCorner(rect: rect, radius: radius, cornerX: 0, cornerY: 0, color: color, sampleCount: sampleCount)
        fillRoundedCorner(rect: rect, radius: radius, cornerX: rect.width - radius, cornerY: 0, color: color, sampleCount: sampleCount)
        fillRoundedCorner(rect: rect, radius: radius, cornerX: 0, cornerY: rect.height - radius, color: color, sampleCount: sampleCount)
        fillRoundedCorner(rect: rect, radius: radius, cornerX: rect.width - radius, cornerY: rect.height - radius, color: color, sampleCount: sampleCount)
    }

    private mutating func fillRoundedCorner(
        rect: MK2PixelRect,
        radius: Int,
        cornerX: Int,
        cornerY: Int,
        color: UInt16,
        sampleCount: Int
    ) {
        for localY in cornerY..<(cornerY + radius) {
            let y = rect.y + localY
            guard (0..<Self.height).contains(y) else { continue }
            for localX in cornerX..<(cornerX + radius) {
                let x = rect.x + localX
                guard (0..<Self.width).contains(x) else { continue }
                let coverage = roundedRectCoverage(
                    x: localX,
                    y: localY,
                    width: rect.width,
                    height: rect.height,
                    radius: radius,
                    sampleCount: sampleCount
                )
                if coverage >= 1 {
                    self[x, y] = color
                } else if coverage > 0 {
                    self[x, y] = Self.blendRGB565(color, over: self[x, y], alpha: coverage)
                }
            }
        }
    }

    /// Fills a (rounded) rect with a dithered vertical gradient — the building block
    /// for embossed/debossed panel wells. Radius 0 degrades to plain gradient rows.
    ///
    /// The per-pixel gradient/dither/coverage math lives in a cached tile keyed by
    /// size, radius, colors and Bayer phase (`MK2GradientTileCache`); drawing is a
    /// per-row span copy plus a few blended corner pixels. Rendering the gradient
    /// in place cost the instrument editor ~19 ms per encoder tick in debug builds.
    public mutating func fillRoundedVerticalGradient(
        _ rect: MK2PixelRect,
        radius: Int,
        top: UInt16,
        bottom: UInt16,
        antialiased: Bool = false
    ) {
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = max(0, min(radius, rect.width / 2, rect.height / 2))
        let smooth = antialiased && MK2RenderSettings.antialiasingEnabled && radius > 0
        let tile = MK2GradientTileCache.tile(for: MK2GradientTileCache.Key(
            width: rect.width,
            height: rect.height,
            radius: radius,
            top: top,
            bottom: bottom,
            phaseX: rect.x & 3,
            phaseY: rect.y & 3,
            smooth: smooth
        ))
        blit(tile, at: rect)
    }

    private mutating func blit(_ tile: MK2GradientTileCache.Tile, at rect: MK2PixelRect) {
        pixels.withUnsafeMutableBufferPointer { destination in
            guard let destinationBase = destination.baseAddress else { return }
            tile.pixels.withUnsafeBufferPointer { source in
                guard let sourceBase = source.baseAddress else { return }
                for localY in 0..<rect.height {
                    let y = rect.y + localY
                    guard (0..<Self.height).contains(y) else { continue }
                    let inset = tile.rowInsets[localY]
                    let rowBase = localY * rect.width

                    // Fully opaque middle span: straight copy in wire byte order.
                    let spanStart = max(inset, -rect.x)
                    let spanEnd = min(rect.width - inset, Self.width - rect.x)
                    if spanEnd > spanStart {
                        memcpy(
                            destinationBase + y * Self.width + rect.x + spanStart,
                            sourceBase + rowBase + spanStart,
                            (spanEnd - spanStart) * 2
                        )
                    }

                    // Corner columns: coverage-driven, blended over the destination.
                    guard inset > 0 else { continue }
                    Self.blitCornerColumns(
                        tile,
                        rowBase: rowBase,
                        columns: 0..<min(inset, rect.width),
                        rect: rect,
                        y: y,
                        destinationBase: destinationBase,
                        sourceBase: sourceBase
                    )
                    Self.blitCornerColumns(
                        tile,
                        rowBase: rowBase,
                        columns: max(0, rect.width - inset)..<rect.width,
                        rect: rect,
                        y: y,
                        destinationBase: destinationBase,
                        sourceBase: sourceBase
                    )
                }
            }
        }
    }

    private static func blitCornerColumns(
        _ tile: MK2GradientTileCache.Tile,
        rowBase: Int,
        columns: Range<Int>,
        rect: MK2PixelRect,
        y: Int,
        destinationBase: UnsafeMutablePointer<UInt16>,
        sourceBase: UnsafePointer<UInt16>
    ) {
        for localX in columns {
            let x = rect.x + localX
            guard (0..<Self.width).contains(x) else { continue }
            let coverage = tile.coverage[rowBase + localX]
            guard coverage > 0 else { continue }
            let destinationIndex = y * Self.width + x
            if coverage == 255 {
                destinationBase[destinationIndex] = sourceBase[rowBase + localX]
            } else {
                let color = UInt16(bigEndian: sourceBase[rowBase + localX])
                let background = UInt16(bigEndian: destinationBase[destinationIndex])
                destinationBase[destinationIndex] = blendRGB565(color, over: background, alpha: Double(coverage) / 255).bigEndian
            }
        }
    }

    private mutating func fillRoundedAliased(_ rect: MK2PixelRect, radius: Int, _ color: UInt16) {
        for localY in 0..<rect.height {
            let inset = roundedCornerInset(y: localY, height: rect.height, radius: radius)
            fill(
                MK2PixelRect(
                    x: rect.x + inset,
                    y: rect.y + localY,
                    width: max(0, rect.width - inset * 2),
                    height: 1
                ),
                color
            )
        }
    }

    private func roundedCornerInset(y: Int, height: Int, radius: Int) -> Int {
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

    private func roundedRectCoverage(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        radius: Int,
        sampleCount: Int
    ) -> Double {
        let samples = max(1, sampleCount)
        var inside = 0
        let total = samples * samples
        for sy in 0..<samples {
            for sx in 0..<samples {
                let sampleX = Double(x) + (Double(sx) + 0.5) / Double(samples)
                let sampleY = Double(y) + (Double(sy) + 0.5) / Double(samples)
                if isInsideRoundedRect(
                    x: sampleX,
                    y: sampleY,
                    width: Double(width),
                    height: Double(height),
                    radius: Double(radius)
                ) {
                    inside += 1
                }
            }
        }
        return Double(inside) / Double(total)
    }

    private func isInsideRoundedRect(x: Double, y: Double, width: Double, height: Double, radius: Double) -> Bool {
        let nearestX = min(max(x, radius), width - radius)
        let nearestY = min(max(y, radius), height - radius)
        let dx = x - nearestX
        let dy = y - nearestY
        return dx * dx + dy * dy <= radius * radius
    }

    static func blendRGB565(_ foreground: UInt16, over background: UInt16, alpha: Double) -> UInt16 {
        let alpha = max(0, min(1, alpha))
        let inverse = 1 - alpha
        let fr = Double((foreground >> 11) & 0x1f)
        let fg = Double((foreground >> 5) & 0x3f)
        let fb = Double(foreground & 0x1f)
        let br = Double((background >> 11) & 0x1f)
        let bg = Double((background >> 5) & 0x3f)
        let bb = Double(background & 0x1f)
        let r = UInt16(max(0, min(31, Int((fr * alpha + br * inverse).rounded()))))
        let g = UInt16(max(0, min(63, Int((fg * alpha + bg * inverse).rounded()))))
        let b = UInt16(max(0, min(31, Int((fb * alpha + bb * inverse).rounded()))))
        return (r << 11) | (g << 5) | b
    }

    // A 4-byte pattern of the same stored pixel twice: any 2-byte-aligned offset into
    // the repeated pattern still yields that pixel, so memset_pattern4 works at odd x.
    private func patternPair(_ stored: UInt16) -> UInt32 {
        UInt32(stored) | (UInt32(stored) << 16)
    }

    public mutating func stroke(_ rect: MK2PixelRect, _ color: UInt16, width: Int = 1) {
        guard width > 0 else { return }
        fill(MK2PixelRect(x: rect.x, y: rect.y, width: rect.width, height: width), color)
        fill(MK2PixelRect(x: rect.x, y: rect.maxY - width, width: rect.width, height: width), color)
        fill(MK2PixelRect(x: rect.x, y: rect.y, width: width, height: rect.height), color)
        fill(MK2PixelRect(x: rect.maxX - width, y: rect.y, width: width, height: rect.height), color)
    }

    public mutating func horizontalBar(_ rect: MK2PixelRect, value: Double, fill: UInt16, track: UInt16) {
        let clamped = max(0, min(1, value))
        self.fill(rect, track)
        let fillWidth = Int((Double(max(0, rect.width)) * clamped).rounded())
        self.fill(MK2PixelRect(x: rect.x, y: rect.y, width: fillWidth, height: rect.height), fill)
    }

    /// Bipolar bar: grows from the horizontal center, `value` in -1…+1; the center
    /// tick stays visible at value 0.
    public mutating func centeredBar(_ rect: MK2PixelRect, value: Double, fill: UInt16, track: UInt16) {
        let clamped = max(-1, min(1, value))
        self.fill(rect, track)
        let center = rect.x + rect.width / 2
        let extent = Int((Double(rect.width / 2) * abs(clamped)).rounded())
        if clamped >= 0 {
            self.fill(MK2PixelRect(x: center, y: rect.y, width: max(1, extent), height: rect.height), fill)
        } else {
            self.fill(MK2PixelRect(x: center - extent, y: rect.y, width: max(1, extent), height: rect.height), fill)
        }
    }

    public mutating func drawText(
        _ text: String,
        x: Int,
        y: Int,
        scale: Int = 3,
        color: UInt16 = 0xffff,
        maxWidth: Int? = nil
    ) {
        let scale = max(1, scale)
        var pattern = patternPair(color.bigEndian)
        var cursor = x
        let limit = maxWidth.map { x + $0 } ?? Self.width
        let chars = Array(text.uppercased())
        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for char in chars {
                if cursor >= limit { break }
                if char == " " {
                    cursor += 4 * scale
                    continue
                }
                let rows = MK2PixelFont.rows(for: char)
                for row in 0..<rows.count {
                    let bits = rows[row]
                    // Adjacent set bits merge into one horizontal run per glyph row.
                    var column = 0
                    while column < 5 {
                        guard (bits & (1 << (4 - column))) != 0 else {
                            column += 1
                            continue
                        }
                        var runEnd = column
                        while runEnd + 1 < 5, (bits & (1 << (4 - (runEnd + 1)))) != 0 {
                            runEnd += 1
                        }
                        let runX = cursor + column * scale
                        let runWidth = (runEnd - column + 1) * scale
                        let clippedX = max(0, runX)
                        let clippedWidth = min(runX + runWidth, min(limit, Self.width)) - clippedX
                        if clippedWidth > 0 {
                            for subRow in 0..<scale {
                                let py = y + row * scale + subRow
                                guard py >= 0, py < Self.height else { continue }
                                memset_pattern4(base + py * Self.width + clippedX, &pattern, clippedWidth * 2)
                            }
                        }
                        column = runEnd + 1
                    }
                }
                cursor += 6 * scale
            }
        }
    }

    /// Writes back a pixel block previously captured with `pixels(in:)`.
    /// The rect must lie fully inside the frame and match the pixel count.
    public mutating func blit(_ sourcePixels: [UInt16], into rect: MK2PixelRect) {
        guard rect.clipped(to: Self.bounds) == rect,
              sourcePixels.count == rect.width * rect.height else { return }
        for row in 0..<rect.height {
            let destination = (rect.y + row) * Self.width + rect.x
            let source = row * rect.width
            pixels.replaceSubrange(destination..<(destination + rect.width), with: sourcePixels[source..<(source + rect.width)])
        }
    }

    public func pixels(in rect: MK2PixelRect) -> [UInt16] {
        guard let clipped = rect.clipped(to: Self.bounds) else { return [] }
        // Full-width rects are contiguous storage: a single memcpy.
        if clipped.x == 0, clipped.width == Self.width {
            return Array(pixels[(clipped.y * Self.width)..<(clipped.maxY * Self.width)])
        }
        var result: [UInt16] = []
        result.reserveCapacity(clipped.width * clipped.height)
        for y in clipped.y..<clipped.maxY {
            let start = y * Self.width + clipped.x
            result.append(contentsOf: pixels[start..<(start + clipped.width)])
        }
        return result
    }
}

enum MK2PixelFont {
    // Glyph rows live inline (7 bytes, no heap allocation or reference counting on
    // lookup) — one of the macOS 26 facilities this hot path exists for.
    static func rows(for char: Character) -> InlineArray<7, UInt8> {
        table[char] ?? table["?"]!
    }

    private static let table: [Character: InlineArray<7, UInt8>] = [
        "0": [0b11111, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b11111],
        "1": [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
        "2": [0b11110, 0b00001, 0b00001, 0b11110, 0b10000, 0b10000, 0b11111],
        "3": [0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110],
        "4": [0b10010, 0b10010, 0b10010, 0b11111, 0b00010, 0b00010, 0b00010],
        "5": [0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b00001, 0b11110],
        "6": [0b01111, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110],
        "7": [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000],
        "8": [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110],
        "9": [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b11110],
        "A": [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
        "B": [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110],
        "C": [0b01111, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b01111],
        "D": [0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110],
        "E": [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111],
        "F": [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000],
        "G": [0b01111, 0b10000, 0b10000, 0b10011, 0b10001, 0b10001, 0b01111],
        "H": [0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
        "I": [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111],
        "J": [0b00111, 0b00010, 0b00010, 0b00010, 0b10010, 0b10010, 0b01100],
        "K": [0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001],
        "L": [0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111],
        "M": [0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001],
        "N": [0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001],
        "O": [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
        "P": [0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000],
        "Q": [0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101],
        "R": [0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001],
        "S": [0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110],
        "T": [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100],
        "U": [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
        "V": [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100],
        "W": [0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010],
        "X": [0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001],
        "Y": [0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100],
        "Z": [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111],
        "-": [0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000],
        "+": [0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000],
        "/": [0b00001, 0b00010, 0b00010, 0b00100, 0b01000, 0b01000, 0b10000],
        ":": [0b00000, 0b00100, 0b00100, 0b00000, 0b00100, 0b00100, 0b00000],
        ".": [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b01100],
        "?": [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b00000, 0b00100],
    ]
}
