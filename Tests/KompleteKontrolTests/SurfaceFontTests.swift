import Foundation
import Testing
@testable import KontrolSurfaceKit2

@Suite("SurfaceFont metrics & atlas")
struct SurfaceFontMetricsTests {
    @Test("Face metrics match the vendored bitmap cell sizes")
    func faceMetrics() {
        #expect(SurfaceFont.grid.advance == 8)
        #expect(SurfaceFont.grid.cellHeight == 16)
        #expect(SurfaceFont.grid.ascent == 12)
        #expect(SurfaceFont.label.advance == 6)
        #expect(SurfaceFont.label.cellHeight == 13)
        #expect(SurfaceFont.label.ascent == 10)
        #expect(SurfaceFont.readout.advance == 10)
        #expect(SurfaceFont.readout.cellHeight == 20)
    }

    @Test("Atlas blob is fully decoded for every face")
    func atlasDecoded() {
        for font in [SurfaceFont.grid, .gridBold, .label, .readout, .readoutBold] {
            #expect(font.bitmap.count == font.glyphCount * font.bytesPerRow * font.cellHeight)
        }
    }

    @Test("Role/weight resolution; label has no bold face so it falls back")
    func roleResolution() {
        #expect(SurfaceFont.face(.grid, .bold).advance == SurfaceFont.gridBold.advance)
        #expect(SurfaceFont.face(.readout, .bold).cellHeight == SurfaceFont.readoutBold.cellHeight)
        // Cozette ships a single label face — bold label must stay the regular cell.
        #expect(SurfaceFont.face(.label, .bold).cellHeight == SurfaceFont.label.cellHeight)
        #expect(SurfaceFont.face(.label, .bold).advance == 6)
    }

    @Test("Monospace measure counts scalars, including precomposed umlauts")
    func measure() {
        #expect(SurfaceFont.grid.measure("ABCD") == 4 * 8)
        #expect(SurfaceFont.grid.measure("ABCD", scale: 2) == 4 * 8 * 2)
        #expect(SurfaceFont.grid.measure("ÄÖÜ") == 3 * 8)   // precomposed, one cell each
        #expect(SurfaceFont.label.measure("ABCDE") == 5 * 6)
    }

    @Test("Space is blank, a letter has ink, out-of-range falls back to '?'")
    func glyphInk() {
        let font = SurfaceFont.grid
        let spaceInk = (0..<font.cellHeight).reduce(UInt16(0)) {
            $0 | font.rowBits(glyph: font.glyphIndex(for: " "), row: $1)
        }
        #expect(spaceInk == 0)

        let letterInk = (0..<font.cellHeight).reduce(UInt16(0)) {
            $0 | font.rowBits(glyph: font.glyphIndex(for: "A"), row: $1)
        }
        #expect(letterInk != 0)

        // Ink must stay within the advance-wide field (no stray high bits).
        for row in 0..<font.cellHeight {
            #expect(font.rowBits(glyph: font.glyphIndex(for: "A"), row: row) < (UInt16(1) << font.advance))
        }

        // A scalar outside 0x20…0xFF resolves to the '?' slot.
        let euro: Unicode.Scalar = "€"
        #expect(font.glyphIndex(for: euro) == font.glyphIndex(for: "?"))
    }
}

@Suite("Bitmap text rendering & clipping")
struct BitmapTextTests {
    private func inkExists(_ frame: MK2PixelFrame, _ rect: MK2PixelRect) -> Bool {
        for y in rect.y..<rect.maxY {
            for x in rect.x..<rect.maxX where frame[x, y] != 0 { return true }
        }
        return false
    }

    @Test("maxWidth truncates: nothing is drawn past the limit")
    func maxWidthClips() {
        var frame = MK2PixelFrame(fill: 0)
        frame.drawText("XXXXXXXX", font: .grid, x: 100, y: 100, color: 0xffff, maxWidth: 8)
        #expect(inkExists(frame, MK2PixelRect(x: 100, y: 100, width: 8, height: 16)))
        // One glyph cell fit; everything from x=108 on stays background.
        #expect(!inkExists(frame, MK2PixelRect(x: 108, y: 100, width: 200, height: 16)))
    }

    @Test("clip rect masks the left edge of a glyph")
    func clipRectMasksLeft() {
        var frame = MK2PixelFrame(fill: 0)
        let clip = MK2PixelRect(x: 104, y: 0, width: 480 - 104, height: 272)
        frame.drawText("A", font: .grid, x: 100, y: 100, color: 0xffff, clip: clip)
        #expect(!inkExists(frame, MK2PixelRect(x: 0, y: 0, width: 104, height: 272)))
    }

    @Test("Negative x and right overflow are clamped, no out-of-bounds write")
    func edgeClamping() {
        var frame = MK2PixelFrame(fill: 0)
        frame.drawText("A", font: .grid, x: -3, y: 100, color: 0xffff)  // partially off the left
        frame.drawText("MMMM", font: .grid, x: 476, y: 100, color: 0xffff) // runs off the right
        // Reaching here without a trap is the assertion; frame stays intact.
        #expect(frame.pixels.count == MK2PixelFrame.width * MK2PixelFrame.height)
    }

    @Test("Highlight background fills the covered cells")
    func highlightBackground() {
        var frame = MK2PixelFrame(fill: 0)
        frame.drawText("AB", font: .grid, x: 40, y: 40, color: 0x0000, background: 0xffff)
        // Between the two glyph cells there is inter-glyph gutter that only the
        // background covers — proves the fill happened independent of glyph ink.
        #expect(frame[40, 40] == 0xffff)
        #expect(inkExists(frame, MK2PixelRect(x: 40, y: 40, width: 16, height: 16)))
    }
}

@Suite("RGB565 & PNG snapshot")
struct PixelSnapshotTests {
    @Test("Host<->wire RGB565 round-trips through the frame subscript")
    func rgb565RoundTrip() {
        var frame = MK2PixelFrame(fill: 0)
        let red: UInt16 = 0xf800
        let green: UInt16 = 0x07e0
        let blue: UInt16 = 0x001f
        frame[10, 20] = red
        frame[11, 20] = green
        frame[12, 20] = blue
        #expect(frame[10, 20] == red)
        #expect(frame[11, 20] == green)
        #expect(frame[12, 20] == blue)
        // Storage is big-endian wire order under the host-order subscript.
        #expect(frame.pixels[20 * MK2PixelFrame.width + 10] == red.bigEndian)
    }

    @Test("Two-screen PNG has the signature and the expected IHDR dimensions")
    func twoScreenPNG() {
        let left = MK2PixelFrame(fill: 0xf800)
        let right = MK2PixelFrame(fill: 0x001f)
        let png = PixelSnapshot.pngData(frames: [left, right])
        let sig: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        #expect(Array(png.prefix(8)) == sig)

        // IHDR width/height are big-endian at fixed offsets after signature+len+"IHDR".
        func be32(_ d: Data, _ off: Int) -> Int {
            Int(d[off]) << 24 | Int(d[off + 1]) << 16 | Int(d[off + 2]) << 8 | Int(d[off + 3])
        }
        let bytes = Data(png)
        #expect(be32(bytes, 16) == 2 * MK2PixelFrame.width + 1)  // two screens + 1px gap
        #expect(be32(bytes, 20) == MK2PixelFrame.height)
    }
}
