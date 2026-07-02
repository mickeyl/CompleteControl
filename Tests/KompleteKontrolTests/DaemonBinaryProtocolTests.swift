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
