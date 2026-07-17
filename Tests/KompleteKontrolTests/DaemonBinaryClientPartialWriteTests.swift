import Darwin
import Foundation
import Testing
@testable import KompleteKontrol

/// Reproduces the client-side mechanism behind the live "MK2 display frozen" incidents.
///
/// A display-channel send that times out mid-write does not roll back the bytes it already
/// wrote to the kernel socket buffer — it just abandons the frame and reports failure. The
/// header those bytes started with declared an honest, correct payload length, so the
/// daemon's parser does exactly the right thing at first: it waits for the rest of that
/// frame's payload to arrive. But the client believes that frame failed and never sends its
/// remainder — it only ever sends *new* frames on the same connection from then on. Those
/// keep getting appended to the buffer as if they were more of the stuck frame's payload,
/// until enough bytes accumulate to reach the original (correct) declared length. At that
/// point the parser consumes exactly that many bytes as "the frame's payload" — which is
/// actually a splice of leftover real payload plus whatever headers/payloads happened to
/// follow — and whatever is left over no longer starts at a real frame boundary. The next
/// header read is misaligned and gets rejected, permanently, until the client reconnects.
@Suite("Daemon binary client partial-write corruption")
struct DaemonBinaryClientPartialWriteTests {
    @Test("a send that times out mid-write eventually desyncs frame boundaries for later sends")
    func partialWriteCorruptsFraming() throws {
        let base = "/tmp/kk-repro-\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0..<UInt32.max))"
        let displayPath = base + ".display"
        defer { unlink(displayPath) }

        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(listenFD >= 0)
        defer { close(listenFD) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        #expect(KompleteKontrolLibUSBServer.fillSunPath(&addr, socketPath: displayPath))
        let bindStatus = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(listenFD, sockaddrPointer, KompleteKontrolLibUSBServer.sockaddrLength(for: displayPath))
            }
        }
        #expect(bindStatus == 0)
        #expect(listen(listenFD, 1) == 0)

        guard let client = KompleteKontrolDaemonBinaryClient(channel: .display, socketPath: base) else {
            Issue.record("failed to connect the test client")
            return
        }

        let acceptedFD = accept(listenFD, nil, nil)
        #expect(acceptedFD >= 0)
        defer { close(acceptedFD) }
        _ = fcntl(acceptedFD, F_SETFL, O_NONBLOCK)

        func drainAvailable() -> [UInt8] {
            var result: [UInt8] = []
            while true {
                var descriptor = pollfd(fd: acceptedFD, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 200) > 0 else { break }
                var scratch = [UInt8](repeating: 0, count: 64 * 1024)
                let count = scratch.withUnsafeMutableBytes { raw in
                    Darwin.read(acceptedFD, raw.baseAddress, raw.count)
                }
                guard count > 0 else { break }
                result.append(contentsOf: scratch.prefix(count))
            }
            return result
        }

        // Large enough to exceed the kernel socket buffer (nothing reads the accepted end,
        // so a single write() call fills it) and time out inside sendDisplayBlit's default
        // 50ms budget — exactly the "daemon momentarily busy, client bursts a repaint"
        // scenario a reconnect storm produces.
        let firstPayloadByteCount = 20_000
        let firstFrameTotalByteCount = KKDaemonBinaryFrame.headerByteCount + 14 + firstPayloadByteCount
        let firstSendSucceeded = client.sendDisplayBlit(
            screen: 0, x: 0, y: 0, width: 480, height: 272,
            timeoutMs: 1_000,
            pixelsRGB565BE: [UInt8](repeating: 0xab, count: firstPayloadByteCount)
        )
        #expect(firstSendSucceeded == false, "nothing drains the socket, so this must time out")

        // Simulate the daemon catching up — draining what actually made it onto the wire —
        // and then the client sending further, ordinary, fully-valid frames on the same
        // connection (the real MK2Surface2.reconcileDisplays retry path, repeated a few
        // times as later ticks each contribute their own blits). Every one of these is a
        // completely well-formed frame in isolation; the corruption is purely a consequence
        // of where they land relative to the first frame's still-unmet declared length.
        var received: [UInt8] = []
        var iterations = 0
        while received.count <= firstFrameTotalByteCount, iterations < 10 {
            received.append(contentsOf: drainAvailable())
            _ = client.sendDisplayBlit(
                screen: 1, x: 0, y: 0, width: 64, height: 32,
                timeoutMs: 1_000,
                pixelsRGB565BE: [UInt8](repeating: 0x11, count: 64 * 32 * 2)
            )
            iterations += 1
        }
        received.append(contentsOf: drainAvailable())
        #expect(
            received.count > firstFrameTotalByteCount,
            "expected enough follow-up frames to cross the abandoned frame's declared length, got \(received.count) of \(firstFrameTotalByteCount)"
        )

        var rejection: KKDaemonBinaryDecodeRejection?
        let decoded = KKDaemonBinaryCodec.decodeFrames(from: &received) { rejection = $0 }

        // The point of this test: every frame sent after the abandoned one was, on its own,
        // perfectly valid — yet decoding the stream fails, because the parser is still
        // completing the first frame's declared (correct) length using bytes that actually
        // belong to later, unrelated frames. This is the daemon-side "malformed header"
        // rejection observed live, reproduced end to end through the real client transport.
        #expect(decoded == nil, "expected the accumulated stream to desync, decoded \(String(describing: decoded))")
        guard case .malformedHeader = rejection else {
            Issue.record("expected a malformedHeader rejection, got \(String(describing: rejection))")
            return
        }
    }
}
