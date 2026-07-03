import Foundation
import Testing
import Darwin
@testable import KompleteKontrol

/// Drives a `SimulatorDeviceSession` over an in-process socketpair — no listening simulator,
/// no hardware — to prove the round trip: semantic frames in → decoded input reports out,
/// output ops → wire frames, socket EOF → device-loss.
@Suite("SimulatorDeviceSession over a socketpair")
struct SimulatorDeviceSessionTests {
    private func makePair() -> (daemon: Int32, sim: Int32) {
        var fds: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        // The daemon end drains until EAGAIN, exactly as the real open() configures it.
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
        return (fds[0], fds[1])
    }

    private func send(_ frame: SimFrame, to fd: Int32) {
        let bytes = SimWireCodec.encode(frame)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
    }

    @Test("A button frame surfaces to the input sink as a decodable report")
    func inputPath() {
        let (daemon, sim) = makePair()
        defer { Darwin.close(daemon); Darwin.close(sim) }
        let session = SimulatorDeviceSession(fd: daemon)

        var received: [[UInt8]] = []
        _ = session.startAsyncInput { data, length in
            received.append(Array(UnsafeBufferPointer(start: data, count: Int(length))))
        }

        send(.button(led: .function3, pressed: true), to: sim)
        session.handleEvents(timeoutMs: 0)

        #expect(received.count == 1)
        let baseline = MK2InputReportBuilder().bytes
        let events = KKMK2InputReportDecoder.eventsForReport(previous: baseline, current: received[0])
        #expect(events == [.button(led: .function3, pressed: true)])
    }

    @Test("Encoder frames accumulate into the running report state")
    func encoderAccumulates() {
        let (daemon, sim) = makePair()
        defer { Darwin.close(daemon); Darwin.close(sim) }
        let session = SimulatorDeviceSession(fd: daemon)
        var last: [UInt8] = []
        _ = session.startAsyncInput { data, length in
            last = Array(UnsafeBufferPointer(start: data, count: Int(length)))
        }

        send(.encoder(index: 2, delta: 3), to: sim)
        session.handleEvents(timeoutMs: 0)
        let afterFirst = last
        send(.encoder(index: 2, delta: 4), to: sim)
        session.handleEvents(timeoutMs: 0)

        // Second report differs from the first by a +4 knob delta (value 3 -> 7).
        let events = KKMK2InputReportDecoder.eventsForReport(previous: afterFirst, current: last)
        #expect(events == [.knob(index: 2, delta: 4, value: 7)])
    }

    @Test("A display blit is forwarded verbatim as a wire frame")
    func outputPath() {
        let (daemon, sim) = makePair()
        defer { Darwin.close(daemon); Darwin.close(sim) }
        let session = SimulatorDeviceSession(fd: daemon)

        let pixels: [UInt8] = [0xf8, 0x00, 0x00, 0x1f]
        _ = session.writeMK2DisplayBytes(screen: 1, x: 4, y: 5, width: 2, height: 1, pixels: pixels, timeoutMs: 100)

        var buffer = [UInt8](repeating: 0, count: 256)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(sim, $0.baseAddress, 256) }
        let (frames, _) = SimWireCodec.decode(Array(buffer[0..<max(0, n)]))
        #expect(frames.first?.type == .displayBlit)
        let payload = frames.first!.payload
        #expect(payload[0] == 1)                             // screen
        #expect(Int(payload[1]) << 8 | Int(payload[2]) == 4) // x
        #expect(Int(payload[3]) << 8 | Int(payload[4]) == 5) // y
        #expect(Array(payload.suffix(4)) == pixels)
    }

    @Test("Socket EOF marks the session device-lost (window closed = unplug)")
    func deviceLoss() {
        let (daemon, sim) = makePair()
        defer { Darwin.close(daemon) }
        let session = SimulatorDeviceSession(fd: daemon)
        #expect(!session.isDeviceLost)
        Darwin.close(sim) // simulator disconnects
        session.handleEvents(timeoutMs: 0)
        #expect(session.isDeviceLost)
    }
}
