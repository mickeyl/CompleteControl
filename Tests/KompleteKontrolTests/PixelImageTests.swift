import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import KontrolSurfaceKit2

@Suite("MK2 pixel image")
struct PixelImageTests {
    @Test("PNG round-trip reproduces RGB565 pixels exactly")
    func pngRoundTripIsExact() throws {
        var frame = MK2PixelFrame(fill: 0x0841)
        frame.fill(MK2PixelRect(x: 10, y: 20, width: 100, height: 50), 0xf800)
        frame.fill(MK2PixelRect(x: 200, y: 100, width: 80, height: 80), 0x07e0)
        frame.fill(MK2PixelRect(x: 400, y: 240, width: 60, height: 20), 0x001f)

        let image = try #require(MK2PixelImage(data: PixelSnapshot.pngData(frame)))
        #expect(image.width == 480)
        #expect(image.height == 272)
        var mismatches = 0
        for y in 0..<272 {
            for x in 0..<480 where image.pixels[y * 480 + x] != frame[x, y] {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    @Test("Fit scaling letterboxes, fill scaling covers")
    func scalingModes() throws {
        let frame = MK2PixelFrame(fill: 0xffff)
        let data = PixelSnapshot.pngData(frame)

        // 480x272 source into a 480x136 fit target: scaled to 240x136, centered,
        // black bars left and right.
        let fit = try #require(MK2PixelImage(data: data, width: 480, height: 136, scaling: .fit))
        #expect(fit.pixels[136 * 480 / 2 + 240] != 0x0000)
        #expect(fit.pixels[136 * 480 / 2 + 10] == 0x0000)
        #expect(fit.pixels[136 * 480 / 2 + 470] == 0x0000)

        // The same source with fill covers the full target.
        let fill = try #require(MK2PixelImage(data: data, width: 480, height: 136, scaling: .fill))
        #expect(fill.pixels[136 * 480 / 2 + 10] != 0x0000)
        #expect(fill.pixels[136 * 480 / 2 + 470] != 0x0000)
    }

    @Test("JPEG decodes to approximately the source color")
    func jpegDecodes() throws {
        let width = 64, height = 64
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            rgba[index * 4] = 200      // r
            rgba[index * 4 + 1] = 40   // g
            rgba[index * 4 + 2] = 120  // b
            rgba[index * 4 + 3] = 255
        }
        let context = try #require(CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let cgImage = try #require(context.makeImage())
        let jpegData = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(jpegData, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))

        let image = try #require(MK2PixelImage(data: jpegData as Data, width: 64, height: 64))
        let center = image.pixels[32 * 64 + 32]
        let r = Int((center >> 11) & 0x1f) << 3
        let g = Int((center >> 5) & 0x3f) << 2
        let b = Int(center & 0x1f) << 3
        #expect(abs(r - 200) < 24)
        #expect(abs(g - 40) < 24)
        #expect(abs(b - 120) < 24)
    }

    @Test("Image element centers, clips, and dims")
    func imageElementDrawsCenteredAndDimmed() throws {
        let image = MK2PixelImage(width: 100, height: 50, pixels: [UInt16](repeating: 0xffff, count: 100 * 50))
        let result = MK2FullScreenDSL(background: 0x0000) {
            MK2ImageElement(image, brightness: 0.5)
        }.build()

        let frame = result.screen.frame
        // Centered: 100x50 lands at (190, 111).
        #expect(frame[240, 136] == 0x7bef)
        #expect(frame[189, 136] == 0x0000)
        #expect(frame[290, 136] == 0x0000)
        #expect(frame[240, 110] == 0x0000)
    }

    @Test("Content text centers within its box")
    func contentTextCenters() throws {
        let renderer = try FreeTypeTextRenderer()
        let result = MK2FullScreenDSL(background: 0x0000) {
            MK2ContentText("PAULINCHE", x: 0, y: 100, maxWidth: 480, role: .title, alignment: .center)
        }.build(renderer: renderer)

        let frame = result.screen.frame
        var minX = MK2PixelFrame.width, maxX = 0
        for y in 100..<140 {
            for x in 0..<MK2PixelFrame.width where frame[x, y] != 0x0000 {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        #expect(maxX > minX)
        let center = (minX + maxX) / 2
        #expect(abs(center - 240) < 12)
    }
}
