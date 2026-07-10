import Foundation

/// Process-wide mirror of the last pixels sent to each MK2 display. Recording
/// happens at the device seam (both the libusb and the simulator session), so
/// every output path — client blits, daemon idle surfaces, fills — is captured
/// regardless of which layer produced it, and the mirror survives session
/// reconnects.
///
/// Snapshots are lock-bounded memory copies that never touch USB or the display
/// queues, which is what makes the daemon's out-of-band `displaySnapshot` query
/// safe to issue while a client owns the surface.
final class MK2DisplayShadow: @unchecked Sendable {
    static let shared = MK2DisplayShadow()

    static let screenCount = 2
    static let width = KompleteKontrolMK2Protocol.displayWidth
    static let height = KompleteKontrolMK2Protocol.displayHeight

    private let lock = NSLock()
    private var frames: [[UInt8]]
    private var hasFrame: [Bool]

    init() {
        frames = Array(
            repeating: [UInt8](repeating: 0, count: Self.width * Self.height * 2),
            count: Self.screenCount
        )
        hasFrame = Array(repeating: false, count: Self.screenCount)
    }

    /// Wire-order (RGB565 big-endian) rect, exactly as sent to the device.
    func recordBytes(screen: UInt8, x: UInt16, y: UInt16, width: UInt16, height: UInt16, pixelsBE: [UInt8]) {
        let screenIndex = Int(screen)
        let x = Int(x), y = Int(y), w = Int(width), h = Int(height)
        guard screenIndex < Self.screenCount,
              w > 0, h > 0,
              x + w <= Self.width,
              y + h <= Self.height,
              pixelsBE.count == w * h * 2 else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        frames[screenIndex].withUnsafeMutableBufferPointer { frame in
            pixelsBE.withUnsafeBufferPointer { source in
                for row in 0..<h {
                    let destination = frame.baseAddress! + ((y + row) * Self.width + x) * 2
                    destination.update(from: source.baseAddress! + row * w * 2, count: w * 2)
                }
            }
        }
        hasFrame[screenIndex] = true
    }

    /// Host-order RGB565 rect (mirrors `writeMK2DisplayPixels`).
    func recordPixels(screen: UInt8, x: UInt16, y: UInt16, width: UInt16, height: UInt16, pixels: [UInt16]) {
        var be = [UInt8]()
        be.reserveCapacity(pixels.count * 2)
        for pixel in pixels {
            be.append(UInt8(pixel >> 8))
            be.append(UInt8(pixel & 0xff))
        }
        recordBytes(screen: screen, x: x, y: y, width: width, height: height, pixelsBE: be)
    }

    func recordFill(screen: UInt8, x: UInt16, y: UInt16, width: UInt16, height: UInt16, rgb565: UInt16) {
        let count = Int(width) * Int(height)
        guard count > 0 else { return }
        var be = [UInt8](repeating: 0, count: count * 2)
        let hi = UInt8(rgb565 >> 8), lo = UInt8(rgb565 & 0xff)
        for index in 0..<count {
            be[index * 2] = hi
            be[index * 2 + 1] = lo
        }
        recordBytes(screen: screen, x: x, y: y, width: width, height: height, pixelsBE: be)
    }

    /// Full-frame wire-order pixels, or nil while nothing has been sent to that
    /// screen in this daemon's lifetime.
    func snapshot(screen: UInt8) -> [UInt8]? {
        let screenIndex = Int(screen)
        guard screenIndex < Self.screenCount else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard hasFrame[screenIndex] else { return nil }
        return frames[screenIndex]
    }
}
