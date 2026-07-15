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

    @Test("Encoder touch, turn and release surface as separate reports")
    func encoderTouchTurnReleaseSequence() {
        let (daemon, sim) = makePair()
        defer { Darwin.close(daemon); Darwin.close(sim) }
        let session = SimulatorDeviceSession(fd: daemon)
        var last = MK2InputReportBuilder().bytes
        _ = session.startAsyncInput { data, length in
            last = Array(UnsafeBufferPointer(start: data, count: Int(length)))
        }

        let baseline = last
        send(.encoderTouch(index: 4, touched: true), to: sim)
        session.handleEvents(timeoutMs: 0)
        #expect(KKMK2InputReportDecoder.eventsForReport(previous: baseline, current: last) == [.touchEncoder(index: 4, touched: true)])

        let touched = last
        send(.encoder(index: 4, delta: 2), to: sim)
        session.handleEvents(timeoutMs: 0)
        #expect(KKMK2InputReportDecoder.eventsForReport(previous: touched, current: last) == [.knob(index: 4, delta: 2, value: 2)])

        let turned = last
        send(.encoderTouch(index: 4, touched: false), to: sim)
        session.handleEvents(timeoutMs: 0)
        #expect(KKMK2InputReportDecoder.eventsForReport(previous: turned, current: last) == [.touchEncoder(index: 4, touched: false)])
    }

    @Test("4-D touch, rotation and release surface as separate reports")
    func fourDTouchTurnReleaseSequence() {
        let (daemon, sim) = makePair()
        defer { Darwin.close(daemon); Darwin.close(sim) }
        let session = SimulatorDeviceSession(fd: daemon)
        var last = MK2InputReportBuilder().bytes
        _ = session.startAsyncInput { data, length in
            last = Array(UnsafeBufferPointer(start: data, count: Int(length)))
        }

        let baseline = last
        send(.fourDTouch(touched: true), to: sim)
        session.handleEvents(timeoutMs: 0)
        #expect(KKMK2InputReportDecoder.eventsForReport(previous: baseline, current: last) == [.jogTouch(touched: true)])

        let touched = last
        send(.fourDWheel(delta: 1), to: sim)
        session.handleEvents(timeoutMs: 0)
        #expect(KKMK2InputReportDecoder.eventsForReport(previous: touched, current: last) == [.jogScroll(delta: 1, value: 1)])

        let turned = last
        send(.fourDTouch(touched: false), to: sim)
        session.handleEvents(timeoutMs: 0)
        #expect(KKMK2InputReportDecoder.eventsForReport(previous: turned, current: last) == [.jogTouch(touched: false)])
    }

    @Test("Key frames surface as USB MIDI note events")
    func keyFramesBecomeMIDI() {
        let (daemon, sim) = makePair()
        defer { Darwin.close(daemon); Darwin.close(sim) }
        let session = SimulatorDeviceSession(fd: daemon)
        var received: [[UInt8]] = []
        _ = session.startAsyncMIDI { data, length in
            received.append(Array(UnsafeBufferPointer(start: data, count: Int(length))))
        }

        send(.note(60, velocity: 100, on: true), to: sim)
        session.handleEvents(timeoutMs: 0)
        send(.note(60, velocity: 0, on: false), to: sim)
        session.handleEvents(timeoutMs: 0)

        #expect(received == [[0x09, 0x90, 60, 100], [0x08, 0x80, 60, 0]])
    }

    @Test("Wheel MIDI frames keep their USB MIDI code index")
    func wheelMIDIFrames() {
        let (daemon, sim) = makePair()
        defer { Darwin.close(daemon); Darwin.close(sim) }
        let session = SimulatorDeviceSession(fd: daemon)
        var received: [[UInt8]] = []
        _ = session.startAsyncMIDI { data, length in
            received.append(Array(UnsafeBufferPointer(start: data, count: Int(length))))
        }

        send(.midi(status: 0xb0, data1: 1, data2: 127), to: sim)
        session.handleEvents(timeoutMs: 0)
        send(.midi(status: 0xe0, data1: 0, data2: 64), to: sim)
        session.handleEvents(timeoutMs: 0)

        #expect(received == [[0x0b, 0xb0, 1, 127], [0x0e, 0xe0, 0, 64]])
    }

    @Test("Channel pressure MIDI frames keep their USB MIDI code index")
    func channelPressureMIDIFrames() {
        let (daemon, sim) = makePair()
        defer { Darwin.close(daemon); Darwin.close(sim) }
        let session = SimulatorDeviceSession(fd: daemon)
        var received: [[UInt8]] = []
        _ = session.startAsyncMIDI { data, length in
            received.append(Array(UnsafeBufferPointer(start: data, count: Int(length))))
        }

        send(.midi(status: 0xd0, data1: 0x45, data2: 0x00), to: sim)
        session.handleEvents(timeoutMs: 0)

        #expect(received == [[0x0d, 0xd0, 0x45, 0x00]])
    }

    @Test("Ribbon frames surface as raw strip reports")
    func ribbonFramesBecomeStripReports() {
        let (daemon, sim) = makePair()
        defer { Darwin.close(daemon); Darwin.close(sim) }
        let session = SimulatorDeviceSession(fd: daemon)
        var received: [[UInt8]] = []
        _ = session.startAsyncInput { data, length in
            received.append(Array(UnsafeBufferPointer(start: data, count: Int(length))))
        }

        send(.strip(position: 512, time: 123), to: sim)
        session.handleEvents(timeoutMs: 0)
        send(.strip(position: nil, time: 133), to: sim)
        session.handleEvents(timeoutMs: 0)

        #expect(received.count == 2)
        #expect(KKMK2InputReportDecoder.eventsForReport(previous: nil, current: received[0]) == [.strip(position: 512, time: 123)])
        #expect(KKMK2InputReportDecoder.eventsForReport(previous: nil, current: received[1]) == [.strip(position: nil, time: 133)])
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

    @Test("Adaptive display mode forwards a raw packet the strict decoder can apply")
    func adaptiveOutputPath() throws {
        let (daemon, sim) = makePair()
        defer { Darwin.close(daemon); Darwin.close(sim) }
        let selection = MK2DisplayEncodingSelection.resolve(environment: [
            MK2DisplayEncodingSelection.environmentKey: "adaptive",
        ])
        let session = SimulatorDeviceSession(fd: daemon, displayEncodingSelection: selection)
        let pixels: [UInt8] = [0xf8, 0x00, 0xf8, 0x00, 0xf8, 0x00, 0xf8, 0x00]
        _ = session.writeMK2DisplayBytes(
            screen: 0, x: 10, y: 20, width: 4, height: 1, pixels: pixels, timeoutMs: 100
        )

        var buffer = [UInt8](repeating: 0, count: 256)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(sim, $0.baseAddress, 256) }
        let (frames, _) = SimWireCodec.decode(Array(buffer[0..<max(0, n)]))
        let frame = try #require(frames.first)
        #expect(frame.type == .displayPacket)
        let decoded = try MK2DisplayPacketDecoder().decodeAndApply(frame.payload)
        #expect(decoded.screen == 0)
        #expect(decoded.x == 10)
        #expect(decoded.y == 20)
        #expect(decoded.pixelsBE == pixels)
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
