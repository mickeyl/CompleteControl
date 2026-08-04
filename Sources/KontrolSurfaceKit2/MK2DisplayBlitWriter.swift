import Foundation
import KompleteKontrol

/// Owns the display channel's blocking blit round trips on a dedicated serial
/// queue, so a slow ack can never stall `MK2Surface2`'s input actor — the
/// client-side counterpart of the daemon invariant "display frames must not
/// gate feel-critical output".
///
/// The writer holds at most one in-flight batch. The actor's tick simply skips
/// display reconciliation while a batch is in flight and retries on the next
/// tick, which is latest-wins at frame granularity: the reconciler never
/// advances past pixels the writer has not accepted, so no diff is ever lost.
///
/// Bench evidence for why this exists (2026-08-04 dual-surface stress): a
/// single >50 ms blit ack tipped the actor-blocking design into a
/// timeout → full-frame-resend → longer-ack feedback loop that never
/// converged and grew the host app past 1.4 GB.
final class MK2DisplayBlitWriter: @unchecked Sendable {
    enum Outcome: Sendable, Equatable {
        case completed
        /// The daemon answered with a non-zero status.
        case rejected(String)
        /// No ack within the budget; `desynced` mirrors the connection state —
        /// a partially framed stream can only be recovered by reconnecting.
        case timedOut(desynced: Bool)
        case inactive
    }

    /// Sends one blit and returns the outcome. Production wraps
    /// `KompleteKontrolDaemonBinaryClient.sendDisplayBlit`; tests substitute a
    /// deterministic transport.
    typealias Transport = @Sendable (_ blit: MK2PixelBlit, _ deviceTimeoutMs: UInt32, _ ackTimeoutUsec: useconds_t) -> Outcome

    private let queue = DispatchQueue(label: "media.vanille.kontrolsurfacekit2.display-writer", qos: .userInitiated)
    private let lock = NSLock()
    private var transport: Transport?
    private var busy = false

    /// Base ack budget plus a size-proportional allowance: the daemon acks on
    /// enqueue, but a full-frame payload (~261 KB per screen) first has to
    /// cross the Unix socket and the daemon's reactor loop. A flat 50 ms was
    /// measured to time out under load exactly for those large payloads.
    static func ackTimeoutUsec(forPixelBytes bytes: Int) -> useconds_t {
        let base: useconds_t = 50_000
        let sizeAllowance = useconds_t(min(bytes / 5, 950_000))
        return base + sizeAllowance
    }

    func activate(_ client: KompleteKontrolDaemonBinaryClient) {
        activate(transport: { blit, deviceTimeoutMs, ackTimeoutUsec in
            let data = blit.pixels.withUnsafeBytes { Array($0) }
            let accepted = client.sendDisplayBlit(
                screen: UInt8(blit.screen & 0xff),
                x: UInt16(blit.rect.x & 0xffff),
                y: UInt16(blit.rect.y & 0xffff),
                width: UInt16(blit.rect.width & 0xffff),
                height: UInt16(blit.rect.height & 0xffff),
                timeoutMs: deviceTimeoutMs,
                pixelsRGB565BE: data,
                timeoutUsec: ackTimeoutUsec
            )
            return accepted ? .completed : .timedOut(desynced: client.isDesynced)
        })
    }

    func activate(transport: @escaping Transport) {
        lock.lock()
        self.transport = transport
        lock.unlock()
    }

    /// Detaches the transport. An in-flight batch finishes its current socket
    /// write but its outcome is discarded by the caller's generation guard.
    func deactivate() {
        lock.lock()
        transport = nil
        lock.unlock()
    }

    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return busy
    }

    /// Enqueues one batch. Returns false without side effects when a batch is
    /// already in flight or no transport is attached — the caller must then
    /// keep its pixels unsent (reset its reconciler advance) and retry later.
    /// The batch stops at the first non-completed blit, mirroring the previous
    /// inline behavior: writing further frames into a possibly desynced stream
    /// only deepens the corruption.
    @discardableResult
    func submit(
        _ blits: [MK2PixelBlit],
        deviceTimeoutMs: UInt32,
        completion: @escaping @Sendable (Outcome) -> Void
    ) -> Bool {
        lock.lock()
        guard !busy, let transport else {
            lock.unlock()
            return false
        }
        busy = true
        lock.unlock()
        queue.async { [weak self] in
            var outcome = Outcome.completed
            for blit in blits {
                let bytes = blit.pixels.count * MemoryLayout<UInt16>.size
                outcome = transport(blit, deviceTimeoutMs, Self.ackTimeoutUsec(forPixelBytes: bytes))
                if outcome != .completed {
                    break
                }
            }
            if let self {
                self.lock.lock()
                self.busy = false
                self.lock.unlock()
            }
            completion(outcome)
        }
        return true
    }

    /// Blocks until the current batch (if any) has drained. Reserved for the
    /// measurement/bench paths, which need barrier semantics on the display
    /// channel and deliberately accept an actor stall in exchange.
    func waitUntilIdle() {
        queue.sync {}
    }
}
