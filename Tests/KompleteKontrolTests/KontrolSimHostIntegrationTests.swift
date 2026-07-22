import CryptoKit
import Foundation
import Testing

/// End-to-end tests for the headless simulator host: they spawn the real
/// `kontrol-sim-host` and `ccd` binaries from the build products directory and speak the
/// JSON-Lines control plane, exactly like an automation script would.
@Suite("Headless simulator host", .serialized)
struct KontrolSimHostIntegrationTests {
    private static let productsDirectory: URL = {
        Bundle(for: Host.self).bundleURL.deletingLastPathComponent()
    }()

    /// One spawned host process plus line-based control-plane access with deadlines.
    /// All mutable state is guarded by `lock`; the readability handler is the only
    /// concurrent writer.
    private final class Host: @unchecked Sendable {
        let process = Process()
        private let stdinPipe = Pipe()
        private let stdoutPipe = Pipe()
        private let lock = NSLock()
        private var lines: [[String: Any]] = []
        private var buffer = Data()

        init(_ arguments: [String]) throws {
            process.executableURL = productsDirectory.appendingPathComponent("kontrol-sim-host")
            process.arguments = arguments
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.standardError
            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                self?.ingest(handle.availableData)
            }
            try process.run()
        }

        private func ingest(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                if let object = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] {
                    lines.append(object)
                }
            }
            lock.unlock()
        }

        func send(_ object: [String: Any]) {
            let data = try! JSONSerialization.data(withJSONObject: object)
            stdinPipe.fileHandleForWriting.write(data + Data("\n".utf8))
        }

        /// Returns the next message matching `predicate`, discarding non-matching ones.
        func next(timeout: TimeInterval, where predicate: ([String: Any]) -> Bool) -> [String: Any]? {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while Date() < deadline {
                lock.lock()
                let index = lines.firstIndex(where: predicate)
                let message = index.map { lines.remove(at: $0) }
                lock.unlock()
                if let message { return message }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return nil
        }

        func event(_ name: String, timeout: TimeInterval = 15) -> [String: Any]? {
            next(timeout: timeout) { $0["event"] as? String == name }
        }

        func request(_ object: [String: Any], timeout: TimeInterval = 10) -> [String: Any]? {
            send(object)
            return next(timeout: timeout) { $0["event"] == nil }
        }

        func quitAndWait(timeout: TimeInterval = 10) -> Int32? {
            send(["cmd": "quit"])
            let deadline = Date(timeIntervalSinceNow: timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard !process.isRunning else {
                // Never leave a wedged host behind: its inherited stdio descriptors would
                // keep the test runner itself from finishing.
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                return nil
            }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            return process.terminationStatus
        }
    }

    private func uniqueInstance(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8))"
    }

    private static let blackDisplayDigest = SHA256.hash(data: Data(repeating: 0, count: 480 * 272 * 2))
        .map { String(format: "%02x", $0) }.joined()

    @Test("gesture scenario round-trips through daemon and output state", .timeLimit(.minutes(2)))
    func endToEndScenario() throws {
        let instance = uniqueInstance("it-e2e")
        let host = try Host(["--device", "maschine-mk3", "--automation", "--instance", instance])

        let ready = try #require(host.event("ready"))
        #expect(ready["device"] as? String == "maschine-mk3")
        let automationSocket = try #require(ready["automationSocket"] as? String)
        #expect(host.event("daemonConnected") != nil)
        #expect(FileManager.default.fileExists(atPath: automationSocket))

        let status = try #require(host.request(["cmd": "status"]))
        #expect(status["daemonConnected"] as? Bool == true)

        // The daemon's NO CLIENT idle surface must reach the decoded framebuffer.
        var painted = false
        let paintDeadline = Date(timeIntervalSinceNow: 20)
        while Date() < paintDeadline && !painted {
            if let framebuffer = host.request(["cmd": "framebuffer", "display": 0]),
               let digest = framebuffer["sha256"] as? String {
                painted = digest != Self.blackDisplayDigest
            }
            if !painted { Thread.sleep(forTimeInterval: 0.25) }
        }
        #expect(painted, "NO CLIENT idle surface never painted display 0")

        // NO CLIENT mirrors pad strikes to the pad LEDs: a native pad gesture must
        // round-trip device wire -> production decoder -> daemon -> LED output report.
        let lampsBefore = try #require(host.request(["cmd": "lamps"]))
        #expect(host.request(["cmd": "gesture", "gesture": "padStrike", "pad": 5, "velocity": 900])?["ok"] as? Bool == true)
        var mirrored = false
        let mirrorDeadline = Date(timeIntervalSinceNow: 10)
        while Date() < mirrorDeadline && !mirrored {
            if let lamps = host.request(["cmd": "lamps"]) {
                mirrored = lamps["stripAndPads"] as? String != lampsBefore["stripAndPads"] as? String
            }
            if !mirrored { Thread.sleep(forTimeInterval: 0.25) }
        }
        #expect(mirrored, "pad strike never reached the pad LEDs")
        #expect(host.request(["cmd": "gesture", "gesture": "padRelease", "pad": 5])?["ok"] as? Bool == true)

        #expect(host.quitAndWait() == 0)
        #expect(!FileManager.default.fileExists(atPath: "/tmp/kksim-\(instance)"),
                "instance directory must not survive shutdown")
    }

    @Test("two parallel instances stay fully isolated", .timeLimit(.minutes(2)))
    func parallelInstancesAreIsolated() throws {
        let instanceA = uniqueInstance("it-a")
        let instanceB = uniqueInstance("it-b")
        let hostA = try Host(["--device", "maschine-mk3", "--own-daemon", "--instance", instanceA])
        let hostB = try Host(["--device", "komplete-kontrol-s61-mk2", "--own-daemon", "--instance", instanceB])

        let readyA = try #require(hostA.event("ready"))
        let readyB = try #require(hostB.event("ready"))
        #expect(hostA.event("daemonConnected") != nil)
        #expect(hostB.event("daemonConnected") != nil)
        #expect(readyA["daemonSocket"] as? String != readyB["daemonSocket"] as? String)

        // Killing one host (including its owned daemon) must not disturb the other.
        #expect(hostA.quitAndWait() == 0)
        let statusB = try #require(hostB.request(["cmd": "status"]))
        #expect(statusB["daemonConnected"] as? Bool == true)

        #expect(hostB.quitAndWait() == 0)
        #expect(!FileManager.default.fileExists(atPath: "/tmp/kksim-\(instanceA)"))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/kksim-\(instanceB)"))
    }

    @Test("second host on the same instance exits with the busy code", .timeLimit(.minutes(2)))
    func busyInstanceIsRefused() throws {
        let instance = uniqueInstance("it-busy")
        let holder = try Host(["--instance", instance])
        #expect(holder.event("ready") != nil)

        let intruder = Process()
        intruder.executableURL = Self.productsDirectory.appendingPathComponent("kontrol-sim-host")
        intruder.arguments = ["--instance", instance]
        intruder.standardError = FileHandle.nullDevice
        try intruder.run()
        intruder.waitUntilExit()
        #expect(intruder.terminationStatus == 69)

        #expect(holder.quitAndWait() == 0)
    }
}
