import Foundation
import Testing
import KompleteKontrol
@testable import KontrolSurfaceKit2

@Suite("Button hold")
struct ButtonHoldTests {
    @Test("Hold callback fires after the configured delay")
    func holdFiresAfterDelay() async throws {
        let box = ButtonHoldBox()
        let surface = MK2Surface2(options: .init(buttonHoldDelay: 0.01))
        var bindings = MK2InputBindings2()
        bindings.onHold(.browser) {
            box.append("hold")
        }
        await surface.present(MK2SurfaceScene2(bindings: bindings))

        await surface.handleForTesting([.button(led: .browser, pressed: true)])
        // Poll instead of a fixed sleep: the 10 ms hold timer plus actor hops can
        // exceed a small fixed margin when the suite runs fully parallel.
        for _ in 0..<200 where box.events.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(box.events == ["hold"])
    }

    @Test("Release before the configured delay cancels hold")
    func releaseCancelsHold() async throws {
        let box = ButtonHoldBox()
        let surface = MK2Surface2(options: .init(buttonHoldDelay: 0.03))
        var bindings = MK2InputBindings2()
        bindings.onHold(.browser) {
            box.append("hold")
        }
        await surface.present(MK2SurfaceScene2(bindings: bindings))

        await surface.handleForTesting([.button(led: .browser, pressed: true)])
        await surface.handleForTesting([.button(led: .browser, pressed: false)])
        try await Task.sleep(nanoseconds: 60_000_000)

        #expect(box.events == [])
    }

    @Test("Press callback remains immediate when hold is registered")
    func pressRemainsImmediate() async throws {
        let box = ButtonHoldBox()
        let surface = MK2Surface2(options: .init(buttonHoldDelay: 0.03))
        var bindings = MK2InputBindings2()
        bindings.onPress(.browser) {
            box.append("press")
        }
        bindings.onHold(.browser) {
            box.append("hold")
        }
        await surface.present(MK2SurfaceScene2(bindings: bindings))

        await surface.handleForTesting([.button(led: .browser, pressed: true)])

        #expect(box.events == ["press"])
    }
}

private final class ButtonHoldBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}
