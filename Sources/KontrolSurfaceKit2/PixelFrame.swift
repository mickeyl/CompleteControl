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

public struct MK2PixelFrame: Sendable, Equatable {
    public static let width = KompleteKontrolMK2Protocol.displayWidth
    public static let height = KompleteKontrolMK2Protocol.displayHeight
    public static let bounds = MK2PixelRect(x: 0, y: 0, width: width, height: height)

    public private(set) var pixels: [UInt16]

    public init(fill color: UInt16 = 0x0000) {
        pixels = Array(repeating: color, count: Self.width * Self.height)
    }

    public subscript(x: Int, y: Int) -> UInt16 {
        get { pixels[y * Self.width + x] }
        set {
            guard (0..<Self.width).contains(x), (0..<Self.height).contains(y) else { return }
            pixels[y * Self.width + x] = newValue
        }
    }

    public mutating func fill(_ rect: MK2PixelRect, _ color: UInt16) {
        guard let clipped = rect.clipped(to: Self.bounds) else { return }
        for y in clipped.y..<clipped.maxY {
            let start = y * Self.width + clipped.x
            pixels.replaceSubrange(start..<(start + clipped.width), with: repeatElement(color, count: clipped.width))
        }
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

    public mutating func drawText(
        _ text: String,
        x: Int,
        y: Int,
        scale: Int = 3,
        color: UInt16 = 0xffff,
        maxWidth: Int? = nil
    ) {
        let scale = max(1, scale)
        var cursor = x
        let limit = maxWidth.map { x + $0 } ?? Self.width
        for char in text.uppercased() {
            if cursor >= limit { break }
            if char == " " {
                cursor += 4 * scale
                continue
            }
            let rows = MK2PixelFont.rows(for: char)
            for row in 0..<rows.count {
                let bits = rows[row]
                for column in 0..<5 where (bits & (1 << (4 - column))) != 0 {
                    fill(
                        MK2PixelRect(
                            x: cursor + column * scale,
                            y: y + row * scale,
                            width: scale,
                            height: scale
                        ),
                        color
                    )
                }
            }
            cursor += 6 * scale
        }
    }

    public func pixels(in rect: MK2PixelRect) -> [UInt16] {
        guard let clipped = rect.clipped(to: Self.bounds) else { return [] }
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
    static func rows(for char: Character) -> [UInt8] {
        table[char] ?? table["?"]!
    }

    private static let table: [Character: [UInt8]] = [
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
