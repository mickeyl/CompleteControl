import Foundation

struct DaemonDisplayBlitRegion: Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var pixels: [UInt8]
}

enum DaemonDisplayBlitCoalescer {
    static func coalesce(
        older: DaemonDisplayBlitRegion,
        newer: DaemonDisplayBlitRegion,
        shadow: [UInt8]?,
        screenWidth: Int,
        screenHeight: Int
    ) -> DaemonDisplayBlitRegion {
        let olderMaxX = older.x + older.width
        let olderMaxY = older.y + older.height
        let newerMaxX = newer.x + newer.width
        let newerMaxY = newer.y + newer.height

        if newer.x <= older.x, newer.y <= older.y,
           newerMaxX >= olderMaxX, newerMaxY >= olderMaxY {
            return newer
        }

        let x = min(older.x, newer.x)
        let y = min(older.y, newer.y)
        let maxX = max(olderMaxX, newerMaxX)
        let maxY = max(olderMaxY, newerMaxY)
        let width = maxX - x
        let height = maxY - y
        precondition(x >= 0 && y >= 0 && maxX <= screenWidth && maxY <= screenHeight)
        var pixels = [UInt8](repeating: 0, count: width * height * 2)

        if let shadow, shadow.count == screenWidth * screenHeight * 2 {
            pixels.withUnsafeMutableBufferPointer { destination in
                shadow.withUnsafeBufferPointer { source in
                    guard let destinationBase = destination.baseAddress,
                          let sourceBase = source.baseAddress else { return }
                    for row in 0..<height {
                        let sourceOffset = ((y + row) * screenWidth + x) * 2
                        destinationBase.advanced(by: row * width * 2)
                            .update(from: sourceBase.advanced(by: sourceOffset), count: width * 2)
                    }
                }
            }
        }

        overlay(older, unionX: x, unionY: y, unionWidth: width, into: &pixels)
        overlay(newer, unionX: x, unionY: y, unionWidth: width, into: &pixels)
        return DaemonDisplayBlitRegion(x: x, y: y, width: width, height: height, pixels: pixels)
    }

    private static func overlay(
        _ source: DaemonDisplayBlitRegion,
        unionX: Int,
        unionY: Int,
        unionWidth: Int,
        into destination: inout [UInt8]
    ) {
        let offsetX = source.x - unionX
        let offsetY = source.y - unionY
        let sourceRowBytes = source.width * 2
        destination.withUnsafeMutableBufferPointer { destinationBuffer in
            source.pixels.withUnsafeBufferPointer { sourceBuffer in
                guard let destinationBase = destinationBuffer.baseAddress,
                      let sourceBase = sourceBuffer.baseAddress else { return }
                for row in 0..<source.height {
                    let destinationOffset = ((offsetY + row) * unionWidth + offsetX) * 2
                    destinationBase.advanced(by: destinationOffset)
                        .update(from: sourceBase.advanced(by: row * sourceRowBytes), count: sourceRowBytes)
                }
            }
        }
    }
}
