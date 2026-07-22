import CoreGraphics
import Foundation
import ImageIO
import KontrolSimulatorCore

/// Writes decoded framebuffer snapshots to disk without AppKit, so the host stays free of
/// any WindowServer dependency.
enum FramebufferPNG {
    enum WriteError: Error, CustomStringConvertible {
        case imageCreationFailed
        case destinationFailed(String)

        var description: String {
            switch self {
                case .imageCreationFailed: return "could not create image from framebuffer"
                case let .destinationFailed(path): return "could not write PNG to \(path)"
            }
        }
    }

    static func write(_ snapshot: SimulatorFramebufferSnapshot, to path: String) throws {
        var rgba = [UInt8](repeating: 0, count: snapshot.width * snapshot.height * 4)
        for pixel in 0..<(snapshot.width * snapshot.height) {
            let value = UInt16(snapshot.pixelsBE[pixel * 2]) << 8 | UInt16(snapshot.pixelsBE[pixel * 2 + 1])
            let red = UInt8((value >> 11) & 0x1f)
            let green = UInt8((value >> 5) & 0x3f)
            let blue = UInt8(value & 0x1f)
            rgba[pixel * 4] = red << 3 | red >> 2
            rgba[pixel * 4 + 1] = green << 2 | green >> 4
            rgba[pixel * 4 + 2] = blue << 3 | blue >> 2
            rgba[pixel * 4 + 3] = 0xff
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                  width: snapshot.width,
                  height: snapshot.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: snapshot.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw WriteError.imageCreationFailed
        }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let destination = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
            throw WriteError.destinationFailed(path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw WriteError.destinationFailed(path)
        }
    }
}
