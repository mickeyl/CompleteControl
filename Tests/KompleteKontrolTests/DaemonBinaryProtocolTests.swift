import Testing
@testable import KompleteKontrol

@Suite("Daemon binary protocol")
struct DaemonBinaryProtocolTests {
    @Test("partial frame waits for more bytes")
    func partialFrameWaitsForMoreBytes() {
        let frame = KKDaemonBinaryFrame(channel: .control, type: .version, sequence: 7)
        var buffer = Array(frame.encoded().dropLast())

        let frames = KKDaemonBinaryCodec.decodeFrames(from: &buffer)

        #expect(frames == [])
        #expect(buffer.count == KKDaemonBinaryFrame.headerByteCount - 1)
    }

    @Test("frame with a payload length above the max is rejected instead of waiting forever")
    func oversizedPayloadIsRejected() {
        var buffer: [UInt8] = []
        buffer.appendUInt32LE(KKDaemonBinaryFrame.magic)
        buffer.append(KKDaemonBinaryFrame.version)
        buffer.append(KKDaemonBinaryChannel.control.rawValue)
        buffer.appendUInt16LE(KKDaemonBinaryMessageType.displayBlit.rawValue)
        buffer.appendUInt16LE(0) // flags
        buffer.appendUInt16LE(0) // reserved
        buffer.appendUInt32LE(42) // sequence
        buffer.appendUInt32LE(UInt32(KKDaemonBinaryCodec.maxPayloadByteCount + 1)) // bogus length, no payload follows

        var rejection: KKDaemonBinaryDecodeRejection?
        let frames = KKDaemonBinaryCodec.decodeFrames(from: &buffer) { rejection = $0 }

        #expect(frames == nil)
        guard case let .payloadTooLarge(_, _, sequence, payloadCount) = rejection else {
            Issue.record("expected a payloadTooLarge rejection, got \(String(describing: rejection))")
            return
        }
        #expect(sequence == 42)
        #expect(payloadCount == KKDaemonBinaryCodec.maxPayloadByteCount + 1)
    }

    @Test("multiple frames decode in order")
    func multipleFramesDecodeInOrder() {
        let first = KKDaemonBinaryFrame(channel: .event, type: .input, sequence: 1, payload: [1, 2, 3])
        let second = KKDaemonBinaryFrame(channel: .event, type: .midi, sequence: 2, payload: [4, 5])
        var buffer = first.encoded() + second.encoded()

        let frames = KKDaemonBinaryCodec.decodeFrames(from: &buffer)

        #expect(frames?.map(\.sequence) == [1, 2])
        #expect(frames?.map(\.type) == [.input, .midi])
        #expect(buffer.isEmpty)
    }

    @Test("display payload preserves RGB565 big endian bytes")
    func displayPayloadPreservesBytes() {
        let pixels: [UInt8] = [0x12, 0x34, 0xab, 0xcd]
        let payload = KKDaemonBinaryCodec.displayBlitPayload(
            screen: 1,
            x: 2,
            y: 3,
            width: 1,
            height: 2,
            timeoutMs: 25,
            pixelsRGB565BE: pixels
        )

        let parsed = KKDaemonBinaryCodec.parseDisplayBlitPayload(payload)

        #expect(parsed?.screen == 1)
        #expect(parsed?.x == 2)
        #expect(parsed?.y == 3)
        #expect(parsed?.width == 1)
        #expect(parsed?.height == 2)
        #expect(parsed?.timeoutMs == 25)
        #expect(parsed?.pixels == pixels)
    }

    @Test("Display barrier metrics round-trip and produce a checked delta")
    func displayBarrierMetrics() throws {
        let earlier = MK2DisplayTransportSnapshot(
            encoding: "adaptive",
            metrics: MK2DisplayTransportMetrics(
                writeCount: 10,
                byteCount: 20_000,
                transportNanoseconds: 8_000_000,
                failureCount: 1
            )
        )
        let later = MK2DisplayTransportSnapshot(
            encoding: "adaptive",
            metrics: MK2DisplayTransportMetrics(
                writeCount: 13,
                byteCount: 24_096,
                transportNanoseconds: 9_250_000,
                failureCount: 1
            )
        )

        #expect(MK2DisplayTransportSnapshot.parseBarrierMessage(later.barrierMessage) == later)
        let delta = try #require(later.metrics.subtracting(earlier.metrics))
        #expect(delta.writeCount == 3)
        #expect(delta.byteCount == 4_096)
        #expect(delta.transportNanoseconds == 1_250_000)
        #expect(delta.failureCount == 0)
        #expect(earlier.metrics.subtracting(later.metrics) == nil)
    }

    @Test("device info round-trips through its wire message, including a spaced name")
    func deviceInfoRoundTrips() {
        let info = KKDeviceInfo(
            productID: 0x1600,
            name: "MASCHINE MK3",
            family: .maschineMK3,
            keyCount: 0,
            padCount: 16,
            screenCount: 2,
            firmwareVersionRaw: 0x0146
        )

        #expect(info.firmwareVersionString == "1.4.6")
        #expect(KKDeviceInfo.parse(info.message) == info)
        #expect(KKDeviceInfo.parse("no session") == nil)
    }

    @Test("firmware version decodes bcdDevice as BCD major.minor.patch")
    func formatsBCDVersion() {
        #expect(KKDeviceInfo.formatBCDVersion(0x0146) == "1.4.6")
        #expect(KKDeviceInfo.formatBCDVersion(0x0100) == "1.0.0")
        #expect(KKDeviceInfo.formatBCDVersion(0x0000) == "0.0.0")
    }
}

@Suite("Daemon session policy")
struct DaemonSessionPolicyTests {
    @Test("new pid evicts every connection of other sessions")
    func newPIDEvictsOtherSessions() {
        // old session pid 100 holds control(1), event(2), display(3)
        let registered: [Int: Int32] = [1: 100, 2: 100, 3: 100]
        let victims = KKDaemonSessionPolicy.evictionVictims(registeredPIDs: registered, newClientID: 4, newPID: 200)
        #expect(victims == [1, 2, 3])
    }

    @Test("same pid joins its session without eviction")
    func samePIDJoinsWithoutEviction() {
        let registered: [Int: Int32] = [1: 100]
        let victims = KKDaemonSessionPolicy.evictionVictims(registeredPIDs: registered, newClientID: 2, newPID: 100)
        #expect(victims.isEmpty)
    }

    @Test("first registration has no victims")
    func firstRegistrationHasNoVictims() {
        let victims = KKDaemonSessionPolicy.evictionVictims(registeredPIDs: [:], newClientID: 1, newPID: 100)
        #expect(victims.isEmpty)
    }
}
