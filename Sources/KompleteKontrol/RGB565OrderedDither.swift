package enum KKRGB565OrderedDither {
    private static let thresholds: [Double] = [
        0, 8, 2, 10,
        12, 4, 14, 6,
        3, 11, 1, 9,
        15, 7, 13, 5,
    ].map { ($0 + 0.5) / 16.0 }

    package static func threshold(x: Int, y: Int) -> Double {
        thresholds[((y & 3) << 2) | (x & 3)]
    }

    package static func rgb565(r: Double, g: Double, b: Double, x: Int, y: Int) -> UInt16 {
        let threshold = threshold(x: x, y: y)
        let red = UInt16(min(31, max(0, Int(r + threshold))))
        let green = UInt16(min(63, max(0, Int(g + threshold))))
        let blue = UInt16(min(31, max(0, Int(b + threshold))))
        return (red << 11) | (green << 5) | blue
    }

    package static func lerp(_ from: UInt16, _ to: UInt16, t: Double, x: Int, y: Int) -> UInt16 {
        let t = min(1, max(0, t))
        func mix(_ first: UInt16, _ second: UInt16) -> Double {
            Double(first) + (Double(second) - Double(first)) * t
        }
        return rgb565(
            r: mix((from >> 11) & 0x1f, (to >> 11) & 0x1f),
            g: mix((from >> 5) & 0x3f, (to >> 5) & 0x3f),
            b: mix(from & 0x1f, to & 0x1f),
            x: x,
            y: y
        )
    }

    package static func scaled(_ pixel: UInt16, by factor: Double, x: Int, y: Int) -> UInt16 {
        rgb565(
            r: Double((pixel >> 11) & 0x1f) * factor,
            g: Double((pixel >> 5) & 0x3f) * factor,
            b: Double(pixel & 0x1f) * factor,
            x: x,
            y: y
        )
    }
}
