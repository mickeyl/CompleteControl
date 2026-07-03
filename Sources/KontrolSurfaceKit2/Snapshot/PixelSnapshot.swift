import Foundation

/// Encodes `MK2PixelFrame`s as RGB PNGs for visual snapshot inspection (tests and the
/// widget lab). Self-contained: RGB565 → RGB888 decode plus a minimal PNG writer that
/// emits a valid zlib stream using stored (uncompressed) deflate blocks, so there is no
/// dependency on a compression library. Not a hot path — this is off-device tooling.
public enum PixelSnapshot {
    /// PNG bytes for a single frame.
    public static func pngData(_ frame: MK2PixelFrame) -> Data {
        pngData(frames: [frame])
    }

    /// PNG bytes for several frames laid out left-to-right with a 1px separator — the
    /// natural form for the two 480×272 MK2 screens side by side.
    public static func pngData(frames: [MK2PixelFrame], gap: Int = 1, separator: UInt8 = 40) -> Data {
        guard !frames.isEmpty else { return Data() }
        let fw = MK2PixelFrame.width
        let fh = MK2PixelFrame.height
        let width = frames.count * fw + max(0, frames.count - 1) * gap
        let height = fh

        var rgb = [UInt8](repeating: separator, count: width * height * 3)
        for (i, frame) in frames.enumerated() {
            let ox = i * (fw + gap)
            for y in 0..<fh {
                for x in 0..<fw {
                    let px = frame[x, y]
                    let r5 = (px >> 11) & 0x1f
                    let g6 = (px >> 5) & 0x3f
                    let b5 = px & 0x1f
                    let di = (y * width + ox + x) * 3
                    rgb[di + 0] = UInt8((r5 << 3) | (r5 >> 2))
                    rgb[di + 1] = UInt8((g6 << 2) | (g6 >> 4))
                    rgb[di + 2] = UInt8((b5 << 3) | (b5 >> 2))
                }
            }
        }
        return encodePNG(rgb: rgb, width: width, height: height)
    }

    /// Write a snapshot next to a path, creating parent directories. Returns the path.
    @discardableResult
    public static func write(_ frames: [MK2PixelFrame], to path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pngData(frames: frames).write(to: url)
        return path
    }

    // MARK: - PNG encoding

    private static func encodePNG(rgb: [UInt8], width: Int, height: Int) -> Data {
        var filtered = [UInt8]()
        filtered.reserveCapacity(height * (1 + width * 3))
        for y in 0..<height {
            filtered.append(0) // filter type: none
            let start = y * width * 3
            filtered.append(contentsOf: rgb[start..<(start + width * 3)])
        }

        var png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        var ihdr = Data()
        ihdr.appendBE(UInt32(width))
        ihdr.appendBE(UInt32(height))
        ihdr.append(contentsOf: [8, 2, 0, 0, 0]) // 8-bit, colour type 2 (RGB)
        png.append(chunk("IHDR", ihdr))
        png.append(chunk("IDAT", zlibStored(filtered)))
        png.append(chunk("IEND", Data()))
        return png
    }

    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        data.appendBE(UInt32(payload.count))
        let typed = Data(type.utf8) + payload
        data.append(typed)
        data.appendBE(crc32(typed))
        return data
    }

    /// A zlib stream wrapping `data` in stored (BTYPE=00) deflate blocks — no compression.
    private static func zlibStored(_ data: [UInt8]) -> Data {
        var out = Data([0x78, 0x01]) // zlib header (CM=deflate, 32K window), check %31==0
        let maxBlock = 0xffff
        var offset = 0
        if data.isEmpty {
            out.append(contentsOf: [0x01, 0x00, 0x00, 0xff, 0xff])
        }
        while offset < data.count {
            let len = min(maxBlock, data.count - offset)
            let final: UInt8 = offset + len >= data.count ? 1 : 0
            out.append(final)
            out.append(UInt8(len & 0xff))
            out.append(UInt8((len >> 8) & 0xff))
            let nlen = ~UInt16(len)
            out.append(UInt8(nlen & 0xff))
            out.append(UInt8((nlen >> 8) & 0xff))
            out.append(contentsOf: data[offset..<(offset + len)])
            offset += len
        }
        out.appendBE(adler32(data))
        return out
    }

    private static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendBE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}
