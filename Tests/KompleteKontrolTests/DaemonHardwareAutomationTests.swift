import Foundation
import Testing
import Darwin
@testable import KompleteKontrol

/// Drives `DaemonHardware.handleAutomation(_:clientID:)` directly, in-process — no listening
/// automation socket needed — mirroring how `SimulatorDeviceSessionTests` drives
/// `SimulatorDeviceSession` over a bare socketpair. An event-channel socketpair end registered
/// via `addClient` stands in for a real connected client (Paulinche/KontrolSurfaceKit2), so these
/// tests prove the same thing production cares about: a text command reaches a client as the
/// exact frame real (or simulated) hardware input would produce.
@Suite("DaemonHardware automation-socket command handling")
struct DaemonHardwareAutomationTests {
    /// Registers a socketpair end as an `.event` client and returns (registeredEnd, readEnd).
    private func makeEventClient(
        _ hardware: KompleteKontrolLibUSBServer.DaemonHardware,
        clientID: Int = 1
    ) -> (registered: Int32, read: Int32) {
        var fds: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
        hardware.addClient(fd: fds[0], clientID: clientID, channel: .event)
        return (fds[0], fds[1])
    }

    private func readFrame(_ fd: Int32) throws -> KKDaemonBinaryFrame {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 4096) }
        var received = Array(buffer.prefix(max(0, n)))
        let frames = KKDaemonBinaryCodec.decodeFrames(from: &received)
        return try #require(frames?.first)
    }

    private func eventBytes(_ frame: KKDaemonBinaryFrame) throws -> [UInt8] {
        try #require(KKDaemonBinaryCodec.parseEventPayload(frame.payload)).bytes
    }

    @Test("button down/up round-trips as a decodable surface report")
    func buttonRoundTrip() throws {
        let hardware = KompleteKontrolLibUSBServer.DaemonHardware()
        let (registeredFD, readFD) = makeEventClient(hardware)
        defer { Darwin.close(registeredFD); Darwin.close(readFD) }

        #expect(hardware.handleAutomation("button play down", clientID: 99) == "ok")
        let downFrame = try readFrame(readFD)
        #expect(downFrame.channel == .event)
        #expect(downFrame.type == .input)
        let downBytes = try eventBytes(downFrame)
        let baseline = MK2InputReportBuilder().bytes
        #expect(KKMK2InputReportDecoder.eventsForReport(previous: baseline, current: downBytes) == [.button(led: .play, pressed: true)])

        #expect(hardware.handleAutomation("button play up", clientID: 99) == "ok")
        let upFrame = try readFrame(readFD)
        let upBytes = try eventBytes(upFrame)
        #expect(KKMK2InputReportDecoder.eventsForReport(previous: downBytes, current: upBytes) == [.button(led: .play, pressed: false)])
    }

    @Test("unknown button name is rejected")
    func unknownButtonRejected() {
        let hardware = KompleteKontrolLibUSBServer.DaemonHardware()
        #expect(hardware.handleAutomation("button doesnotexist down", clientID: 1).hasPrefix("err"))
    }

    @Test("note on/off round-trips as USB MIDI bytes")
    func noteRoundTrip() throws {
        let hardware = KompleteKontrolLibUSBServer.DaemonHardware()
        let (registeredFD, readFD) = makeEventClient(hardware)
        defer { Darwin.close(registeredFD); Darwin.close(readFD) }

        #expect(hardware.handleAutomation("note 60 100 on", clientID: 1) == "ok")
        let onFrame = try readFrame(readFD)
        #expect(onFrame.type == .midi)
        #expect(try eventBytes(onFrame) == [0x09, 0x90, 60, 100])

        #expect(hardware.handleAutomation("note 60 0 off", clientID: 1) == "ok")
        let offFrame = try readFrame(readFD)
        #expect(try eventBytes(offFrame) == [0x08, 0x80, 60, 0])
    }

    @Test("strip position round-trips as a decodable ribbon report")
    func stripRoundTrip() throws {
        let hardware = KompleteKontrolLibUSBServer.DaemonHardware()
        let (registeredFD, readFD) = makeEventClient(hardware)
        defer { Darwin.close(registeredFD); Darwin.close(readFD) }

        #expect(hardware.handleAutomation("strip 512 123", clientID: 1) == "ok")
        let frame = try readFrame(readFD)
        let bytes = try eventBytes(frame)
        #expect(KKMK2InputReportDecoder.eventsForReport(previous: nil, current: bytes) == [.strip(position: 512, time: 123)])
    }

    @Test("malformed commands return a parse error without crashing")
    func malformedCommandsAreRejected() {
        let hardware = KompleteKontrolLibUSBServer.DaemonHardware()
        #expect(hardware.handleAutomation("", clientID: 1) == "err parse")
        #expect(hardware.handleAutomation("button play", clientID: 1) == "err parse")
        #expect(hardware.handleAutomation("encoder 9 1", clientID: 1) == "err parse")
        #expect(hardware.handleAutomation("nonsense", clientID: 1).hasPrefix("err unknown command"))
    }
}
