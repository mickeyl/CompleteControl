import Foundation

/// Diffs MK2 pixel framebuffers and emits USB-friendly blits.
///
/// The reconciler uses tile scanning to detect changes, but emits a full frame for
/// each changed screen. The daemon display queue is "latest wins"; full-frame
/// payloads are therefore the only correct baseline until display acknowledgements
/// become presentation-complete rather than queue-accepted.
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
            // Whole-array equality instead of a hand-rolled per-pixel scan: an unchanged
            // scene keeps the same CoW buffer, making this an O(1) identity check, and the
            // stdlib comparison runs optimized even in debug builds — the manual tile loop
            // cost tens of ms per tick and stalled the surface actor. Tile-granular spans
            // return with the scatter-transfer format.
            if force || lastSent[screen] != frame.pixels {
                blits.append(MK2PixelBlit(screen: screen, rect: MK2PixelFrame.bounds, pixels: frame.pixels))
                lastSent[screen] = frame.pixels
            }
        }
        return blits
    }
}
