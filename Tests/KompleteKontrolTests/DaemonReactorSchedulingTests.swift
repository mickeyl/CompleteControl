import Darwin
import Foundation
import Testing
@testable import KompleteKontrol

@Suite("Daemon reactor scheduling")
struct DaemonReactorSchedulingTests {
    @Test("Normal libusb readiness only pumps events")
    func normalLibusbReadinessOnlyPumpsEvents() {
        #expect(DaemonReactorScheduler.usbReadinessAction(flags: 0) == .pumpOnly)
        #expect(DaemonReactorScheduler.usbReadinessAction(flags: UInt16(EV_ADD)) == .pumpOnly)
    }

    @Test("libusb readiness error flags request reconnect")
    func libusbReadinessErrorFlagsRequestReconnect() {
        #expect(DaemonReactorScheduler.usbReadinessAction(flags: UInt16(EV_ERROR)) == .pumpAndReconnect)
        #expect(DaemonReactorScheduler.usbReadinessAction(flags: UInt16(EV_EOF)) == .pumpAndReconnect)
        #expect(DaemonReactorScheduler.usbReadinessAction(flags: UInt16(EV_ERROR | EV_EOF)) == .pumpAndReconnect)
    }

    @Test("System wake invalidates the previous libusb session")
    func systemWakeInvalidatesPreviousLibusbSession() {
        #expect(DaemonReactorScheduler.shouldInvalidateSessionOnSystemWake())
    }

    @Test("Input push sessions register without sharing output helper state")
    func inputPushSessionsRegisterWithoutSharingOutputHelperState() {
        #expect(DaemonClientRegistrationPolicy.shouldRegister(role: .inputPush))
        #expect(!DaemonClientRegistrationPolicy.shouldTrackHelperRegistration(role: .inputPush))
        #expect(DaemonClientRegistrationPolicy.shouldRegister(role: .outputHelper))
        #expect(DaemonClientRegistrationPolicy.shouldTrackHelperRegistration(role: .outputHelper))
    }

    @Test("Client command bursts yield to libusb after each command")
    func clientCommandBurstsYieldToLibusbAfterEachCommand() {
        var buffer = Array("write-one\nwrite-two\npartial".utf8)
        var calls: [String] = []

        DaemonClientCommandPump.processCompleteLines(
            buffer: &buffer,
            clientID: 7,
            handle: { line, clientID in
                calls.append("handle:\(clientID):\(line)")
                return "ok \(line)"
            },
            writeResponse: { response in
                calls.append("response:\(response)")
            },
            pumpUSB: {
                calls.append("pump")
            }
        )

        #expect(calls == [
            "handle:7:write-one",
            "response:ok write-one",
            "pump",
            "handle:7:write-two",
            "response:ok write-two",
            "pump",
        ])
        #expect(String(bytes: buffer, encoding: .utf8) == "partial")
    }

    @Test("Binary blit waits for complete payload")
    func binaryBlitWaitsForCompletePayload() {
        var buffer = Array("mk2blitbin 00 0000 0000 0002 0001 03e8 00000004\n".utf8)
        buffer.append(contentsOf: [0x12, 0x34])
        var calls: [String] = []

        DaemonClientCommandPump.processCompleteLines(
            buffer: &buffer,
            clientID: 3,
            handle: { line, _ in
                calls.append("line:\(line)")
                return "ok"
            },
            handleBinary: { line, payload, _ in
                calls.append("binary:\(line):\(payload.count)")
                return "ok"
            },
            writeResponse: { response in
                calls.append("response:\(response)")
            },
            pumpUSB: {
                calls.append("pump")
            }
        )

        #expect(calls.isEmpty)
        #expect(buffer.count == "mk2blitbin 00 0000 0000 0002 0001 03e8 00000004\n".utf8.count + 2)
    }

    @Test("Binary blit consumes exact payload")
    func binaryBlitConsumesExactPayload() {
        var buffer = Array("mk2blitbin 00 0000 0000 0002 0001 03e8 00000004\n".utf8)
        buffer.append(contentsOf: [0x12, 0x34, 0xab, 0xcd])
        buffer.append(contentsOf: Array("write-next\n".utf8))
        var calls: [String] = []

        DaemonClientCommandPump.processCompleteLines(
            buffer: &buffer,
            clientID: 3,
            handle: { line, _ in
                calls.append("line:\(line)")
                return "ok \(line)"
            },
            handleBinary: { line, payload, _ in
                calls.append("binary:\(line):\(payload.map { String(format: "%02x", $0) }.joined())")
                return "ok binary"
            },
            writeResponse: { response in
                calls.append("response:\(response)")
            },
            pumpUSB: {
                calls.append("pump")
            }
        )

        #expect(calls == [
            "binary:mk2blitbin 00 0000 0000 0002 0001 03e8 00000004:1234abcd",
            "response:ok binary",
            "pump",
            "line:write-next",
            "response:ok write-next",
            "pump",
        ])
        #expect(buffer.isEmpty)
    }

    @Test("Idle diagnostic display flushes are rate limited")
    func idleDiagnosticDisplayFlushesAreRateLimited() {
        var gate = DaemonIdleDiagnosticFlushGate(
            lastDisplayFlushAt: 0,
            minimumDisplayFlushIntervalNs: 50
        )

        #expect(gate.decide(now: 1_000, needsDisplay: true, needsLightGuide: true) == DaemonIdleDiagnosticFlushDecision(
            writeDisplay: true,
            writeLightGuide: true
        ))
        #expect(gate.decide(now: 1_020, needsDisplay: true, needsLightGuide: true) == DaemonIdleDiagnosticFlushDecision(
            writeDisplay: false,
            writeLightGuide: true
        ))
        #expect(gate.decide(now: 1_050, needsDisplay: true, needsLightGuide: false) == DaemonIdleDiagnosticFlushDecision(
            writeDisplay: true,
            writeLightGuide: false
        ))
    }
}
