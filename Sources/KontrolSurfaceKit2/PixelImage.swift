import CoreGraphics
import Foundation
import ImageIO

/// A decoded, display-ready RGB565 bitmap. Decoding (PNG, JPEG — anything ImageIO
/// reads) and scaling happen once at load time, so presenting the image later is a
/// plain pixel copy. Built for splash/about screens that appear instantly while the
/// rest of the app is still warming up.
public struct MK2PixelImage: Sendable, Equatable {
    public enum Scaling: Sendable, Equatable {
        /// Scale preserving aspect ratio until the image covers the target, cropping
        /// the overhang (centered).
        case fill
        /// Scale preserving aspect ratio until the image fits inside the target,
        /// leaving black borders (centered).
        case fit
    }

    public let width: Int
    public let height: Int
    public let pixels: [UInt16]

    public init(width: Int, height: Int, pixels: [UInt16]) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.pixels = pixels
    }

    public init?(
        contentsOf url: URL,
        width targetWidth: Int = MK2PixelFrame.width,
        height targetHeight: Int = MK2PixelFrame.height,
        scaling: Scaling = .fill
    ) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data, width: targetWidth, height: targetHeight, scaling: scaling)
    }

    public init?(
        data: Data,
        width targetWidth: Int = MK2PixelFrame.width,
        height targetHeight: Int = MK2PixelFrame.height,
        scaling: Scaling = .fill
    ) {
        guard targetWidth > 0, targetHeight > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              cgImage.width > 0, cgImage.height > 0,
              let context = CGContext(
                  data: nil,
                  width: targetWidth,
                  height: targetHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: targetWidth * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let sourceWidth = Double(cgImage.width)
        let sourceHeight = Double(cgImage.height)
        let scaleX = Double(targetWidth) / sourceWidth
        let scaleY = Double(targetHeight) / sourceHeight
        let scale = scaling == .fill ? max(scaleX, scaleY) : min(scaleX, scaleY)
        let drawWidth = sourceWidth * scale
        let drawHeight = sourceHeight * scale
        let drawRect = CGRect(
            x: (Double(targetWidth) - drawWidth) / 2,
            y: (Double(targetHeight) - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        context.interpolationQuality = .high
        context.draw(cgImage, in: drawRect)

        guard let raw = context.data else { return nil }
        var converted = [UInt16](repeating: 0, count: targetWidth * targetHeight)
        let bytes = raw.bindMemory(to: UInt8.self, capacity: targetWidth * targetHeight * 4)
        for index in 0..<(targetWidth * targetHeight) {
            let r = UInt16(bytes[index * 4])
            let g = UInt16(bytes[index * 4 + 1])
            let b = UInt16(bytes[index * 4 + 2])
            converted[index] = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        }
        self.init(width: targetWidth, height: targetHeight, pixels: converted)
    }
}

/// Draws an `MK2PixelImage`, by default centered — a full-screen decode lands exactly
/// on the display. `brightness` darkens the image at draw time so foreground labels
/// stay readable over busy artwork without preparing a second asset.
public struct MK2ImageElement: MK2ScreenElement {
    public var image: MK2PixelImage
    public var x: Int?
    public var y: Int?
    public var brightness: Double

    public init(_ image: MK2PixelImage, x: Int? = nil, y: Int? = nil, brightness: Double = 1) {
        self.image = image
        self.x = x
        self.y = y
        self.brightness = max(0, min(1, brightness))
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        guard image.width > 0, image.height > 0 else { return }
        let originX = x ?? (MK2PixelFrame.width - image.width) / 2
        let originY = y ?? (MK2PixelFrame.height - image.height) / 2

        for row in 0..<image.height {
            let frameY = originY + row
            guard frameY >= 0, frameY < MK2PixelFrame.height else { continue }
            for column in 0..<image.width {
                let frameX = originX + column
                guard frameX >= 0, frameX < MK2PixelFrame.width else { continue }
                let pixel = image.pixels[row * image.width + column]
                frame[frameX, frameY] = brightness >= 1
                    ? pixel
                    : MK2OrderedDither.scaled(pixel, by: brightness, x: frameX, y: frameY)
            }
        }
    }
}
