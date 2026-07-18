import CoreGraphics
import Foundation
import ImageIO

private final class MK2IdleArtworkBundleMarker {}

enum MK2IdleArtwork {
    static let bundledFrame: [UInt16]? = {
        guard let url = bundledArtworkURL(),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return frame(data: data)
    }()

    static func frameBeforeFirstEvent(_ artwork: [UInt16]?, eventCount: Int) -> [UInt16]? {
        eventCount == 0 ? artwork : nil
    }

    static func frame(
        data: Data,
        width targetWidth: Int = KompleteKontrolMK2Protocol.displayWidth,
        height targetHeight: Int = KompleteKontrolMK2Protocol.displayHeight
    ) -> [UInt16]? {
        guard targetWidth > 0,
              targetHeight > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0,
              image.height > 0,
              let context = CGContext(
                  data: nil,
                  width: targetWidth,
                  height: targetHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: targetWidth * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        let sourceWidth = Double(image.width)
        let sourceHeight = Double(image.height)
        let scale = max(Double(targetWidth) / sourceWidth, Double(targetHeight) / sourceHeight)
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
        context.draw(image, in: drawRect)

        guard let raw = context.data else { return nil }
        let pixelCount = targetWidth * targetHeight
        let bytes = raw.bindMemory(to: UInt8.self, capacity: pixelCount * 4)
        var pixels = [UInt16](repeating: 0, count: pixelCount)
        for index in 0..<pixelCount {
            pixels[index] = ditheredRGB565(
                red: bytes[index * 4],
                green: bytes[index * 4 + 1],
                blue: bytes[index * 4 + 2],
                x: index % targetWidth,
                y: index / targetWidth
            )
        }
        return pixels
    }

    static func ditheredRGB565(red: UInt8, green: UInt8, blue: UInt8, x: Int, y: Int) -> UInt16 {
        KKRGB565OrderedDither.rgb565(
            r: Double(red) * 31.0 / 255.0,
            g: Double(green) * 63.0 / 255.0,
            b: Double(blue) * 31.0 / 255.0,
            x: x,
            y: y
        )
    }

    private static func bundledArtworkURL() -> URL? {
        let bundleName = "CompleteControl_KompleteKontrol"
        let environment = ProcessInfo.processInfo.environment
        var candidates = ["PACKAGE_RESOURCE_BUNDLE_PATH", "PACKAGE_RESOURCE_BUNDLE_URL"]
            .compactMap { environment[$0] }
            .map { URL(fileURLWithPath: $0) }
        candidates.append(contentsOf: [
            Bundle.main.resourceURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle.main.bundleURL,
            Bundle(for: MK2IdleArtworkBundleMarker.self).resourceURL,
            Bundle(for: MK2IdleArtworkBundleMarker.self).executableURL?.deletingLastPathComponent(),
            Bundle(for: MK2IdleArtworkBundleMarker.self).bundleURL,
        ].compactMap(\.self))

        for candidate in candidates {
            let bundleURL = candidate.lastPathComponent == bundleName + ".bundle"
                ? candidate
                : candidate.appendingPathComponent(bundleName + ".bundle")
            if let bundle = Bundle(url: bundleURL),
               let url = bundle.url(forResource: "buddies", withExtension: "png") {
                return url
            }
        }
        return nil
    }
}
