import Foundation
import Testing
@testable import KontrolSurfaceKit2

@Suite("Display blit writer")
struct MK2DisplayBlitWriterTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []

        func append(_ value: Int) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var snapshot: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private static func blit(screen: Int = 0, pixelCount: Int = 16) -> MK2PixelBlit {
        MK2PixelBlit(
            screen: screen,
            rect: MK2PixelRect(x: 0, y: 0, width: pixelCount, height: 1),
            pixels: [UInt16](repeating: 0xffff, count: pixelCount)
        )
    }

    @Test("submitting without a transport is refused")
    func inactiveSubmitRefused() {
        let writer = MK2DisplayBlitWriter()
        let submitted = writer.submit([Self.blit()], deviceTimeoutMs: 1_000) { _ in }
        #expect(!submitted)
    }

    @Test("a batch completes in order and frees the writer")
    func batchCompletesInOrder() async {
        let writer = MK2DisplayBlitWriter()
        let screens = Recorder()
        writer.activate { blit, _, _ in
            screens.append(blit.screen)
            return .completed
        }
        let outcome = await withCheckedContinuation { continuation in
            let submitted = writer.submit(
                [Self.blit(screen: 0), Self.blit(screen: 1)],
                deviceTimeoutMs: 1_000
            ) { continuation.resume(returning: $0) }
            #expect(submitted)
        }
        #expect(outcome == .completed)
        #expect(screens.snapshot == [0, 1])
        writer.waitUntilIdle()
        #expect(!writer.isBusy)
    }

    @Test("only one batch is in flight; a busy submit is refused without losing the first")
    func busySubmitRefused() async {
        let writer = MK2DisplayBlitWriter()
        let gate = DispatchSemaphore(value: 0)
        writer.activate { _, _, _ in
            gate.wait()
            return .completed
        }
        let outcomeTask = Task {
            await withCheckedContinuation { continuation in
                writer.submit([Self.blit()], deviceTimeoutMs: 1_000) { continuation.resume(returning: $0) }
            }
        }
        while !writer.isBusy {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let second = writer.submit([Self.blit()], deviceTimeoutMs: 1_000) { _ in }
        #expect(!second)
        gate.signal()
        let outcome = await outcomeTask.value
        #expect(outcome == .completed)
    }

    @Test("a failing blit stops the batch and reports the failure")
    func failureStopsBatch() async {
        let writer = MK2DisplayBlitWriter()
        let attempts = Recorder()
        writer.activate { blit, _, _ in
            attempts.append(blit.screen)
            return .timedOut(desynced: false)
        }
        let outcome = await withCheckedContinuation { continuation in
            writer.submit(
                [Self.blit(screen: 0), Self.blit(screen: 1)],
                deviceTimeoutMs: 1_000
            ) { continuation.resume(returning: $0) }
        }
        #expect(outcome == .timedOut(desynced: false))
        #expect(attempts.snapshot == [0])
    }

    @Test("ack budget scales with payload size and stays bounded")
    func ackBudgetScales() {
        #expect(MK2DisplayBlitWriter.ackTimeoutUsec(forPixelBytes: 0) == 50_000)
        // Full 480x272 RGB565 screen: 261,120 bytes.
        #expect(MK2DisplayBlitWriter.ackTimeoutUsec(forPixelBytes: 261_120) == 50_000 + 52_224)
        #expect(MK2DisplayBlitWriter.ackTimeoutUsec(forPixelBytes: 100_000_000) == 1_000_000)
    }
}
