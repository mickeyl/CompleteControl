import Foundation

/// Diffs MK2 pixel framebuffers and emits USB-friendly blits.
///
/// Changed screens are diffed at full-width row-band granularity (memcmp per row, so
/// the scan costs microseconds even in unoptimized builds) and only the band between
/// the first and last dirty row is blitted — a meter update costs a ~40-row band, not
/// a 24 ms full frame. Full-width bands are also what the panel ingests fastest (the
/// narrow-window penalty, see the porting plan benchmark). The daemon display queue is
/// newest-wins per screen; band replacement is only possible when blits are produced
/// faster than the worker drains them, which band-sized payloads avoid by construction.
/// Multi-span scatter frames return with the jnlive transfer format.
public struct PixelDisplayReconciler2: Sendable {
    public var tileWidth: Int
    public var tileHeight: Int

    private var lastSent: [[UInt16]?] = Array(repeating: nil, count: 2)

    public init(tileWidth: Int = 120, tileHeight: Int = 34) {
        self.tileWidth = max(1, tileWidth)
        self.tileHeight = max(1, tileHeight)
    }

    public mutating func reset() {
        lastSent = Array(repeating: nil, count: 2)
    }

    public mutating func reconcile(frames: [MK2PixelFrame?], force: Bool = false) -> [MK2PixelBlit] {
        var blits: [MK2PixelBlit] = []
        for screen in 0..<min(2, frames.count) {
            guard let frame = frames[screen] else { continue }
            guard !force, let previous = lastSent[screen] else {
                blits.append(MK2PixelBlit(screen: screen, rect: MK2PixelFrame.bounds, pixels: frame.pixels))
                lastSent[screen] = frame.pixels
                continue
            }
            // Unchanged scenes keep their CoW buffer — O(1) identity check; never an
            // element-wise Array == (that cost milliseconds per tick in debug builds).
            if previous.span.isIdentical(to: frame.pixels.span) {
                continue
            }
            guard let band = Self.dirtyRowBand(previous: previous, current: frame.pixels) else {
                lastSent[screen] = frame.pixels
                continue
            }
            let width = MK2PixelFrame.width
            let pixels = Array(frame.pixels[(band.lowerBound * width)..<((band.upperBound + 1) * width)])
            let rect = MK2PixelRect(x: 0, y: band.lowerBound, width: width, height: band.count)
            blits.append(MK2PixelBlit(screen: screen, rect: rect, pixels: pixels))
            lastSent[screen] = frame.pixels
        }
        return blits
    }

    private static func dirtyRowBand(previous: [UInt16], current: [UInt16]) -> ClosedRange<Int>? {
        guard previous.count == current.count else { return 0...(MK2PixelFrame.height - 1) }
        let width = MK2PixelFrame.width
        let height = MK2PixelFrame.height
        let rowBytes = width * MemoryLayout<UInt16>.size
        return previous.withUnsafeBufferPointer { prev in
            current.withUnsafeBufferPointer { cur in
                guard let prevBase = prev.baseAddress, let curBase = cur.baseAddress else { return nil }
                var first = -1
                for row in 0..<height where memcmp(prevBase + row * width, curBase + row * width, rowBytes) != 0 {
                    first = row
                    break
                }
                guard first >= 0 else { return nil }
                var last = first
                for row in stride(from: height - 1, through: first, by: -1) where memcmp(prevBase + row * width, curBase + row * width, rowBytes) != 0 {
                    last = row
                    break
                }
                return first...last
            }
        }
    }
}
