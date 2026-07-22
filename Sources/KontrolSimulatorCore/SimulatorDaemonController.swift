import Foundation

/// Owns one user-level child `ccd` in simulator mode. Shared by the AppKit simulator and the
/// headless host so daemon spawning, environment, log redirection, and termination behave
/// identically on both fronts. The controller only ever touches the process handle it created
/// itself — it cannot affect an externally started daemon or the hardware daemon.
public final class SimulatorDaemonController: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var ccdURL: URL
        public var daemonSocketPath: String
        public var deviceSocketPath: String
        public var automationEnabled: Bool
        public var logPath: String
        public var extraEnvironment: [String: String]

        public init(
            ccdURL: URL,
            daemonSocketPath: String,
            deviceSocketPath: String,
            automationEnabled: Bool,
            logPath: String,
            extraEnvironment: [String: String] = [:]
        ) {
            self.ccdURL = ccdURL
            self.daemonSocketPath = daemonSocketPath
            self.deviceSocketPath = deviceSocketPath
            self.automationEnabled = automationEnabled
            self.logPath = logPath
            self.extraEnvironment = extraEnvironment
        }
    }

    public enum StartError: Error, CustomStringConvertible {
        case alreadyRunning
        case daemonBinaryMissing(String)
        case spawnFailed(String)

        public var description: String {
            switch self {
                case .alreadyRunning:
                    return "a controller-owned daemon is already running"
                case let .daemonBinaryMissing(path):
                    return "ccd is not built — expected the daemon at \(path); run: swift build --product ccd"
                case let .spawnFailed(reason):
                    return "failed to start daemon: \(reason)"
            }
        }
    }

    /// Called on the main queue whenever the owned daemon exits, with its termination status.
    public var onTermination: ((Int32) -> Void)?

    private let lock = NSLock()
    private var process: Process?

    public init() {}

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process != nil
    }

    /// The daemon binary as built next to the current executable by `swift build`.
    public static func defaultCCDURL() -> URL {
        Bundle.main.executableURL!
            .deletingLastPathComponent()
            .appendingPathComponent("ccd")
    }

    public func start(_ configuration: Configuration) throws {
        lock.lock()
        guard process == nil else {
            lock.unlock()
            throw StartError.alreadyRunning
        }
        lock.unlock()

        guard FileManager.default.isExecutableFile(atPath: configuration.ccdURL.path) else {
            throw StartError.daemonBinaryMissing(configuration.ccdURL.path)
        }

        FileManager.default.createFile(atPath: configuration.logPath, contents: nil)
        let log = FileHandle(forWritingAtPath: configuration.logPath)

        let child = Process()
        child.executableURL = configuration.ccdURL
        child.arguments = ["--kk-libusb-daemon", configuration.daemonSocketPath]
        var environment = ProcessInfo.processInfo.environment
        environment["CCD_SIMULATE"] = configuration.deviceSocketPath
        environment["LOGLEVEL"] = environment["LOGLEVEL"] ?? "INFO"
        if configuration.automationEnabled {
            environment["CCD_ENABLE_AUTOMATION"] = "1"
        }
        for (key, value) in configuration.extraEnvironment {
            environment[key] = value
        }
        child.environment = environment
        child.standardOutput = log
        child.standardError = log
        child.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.lock.lock()
            if self.process === finished { self.process = nil }
            self.lock.unlock()
            let status = finished.terminationStatus
            DispatchQueue.main.async { self.onTermination?(status) }
        }
        do {
            try child.run()
        } catch {
            throw StartError.spawnFailed("\(error)")
        }
        lock.lock()
        process = child
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let child = process
        lock.unlock()
        child?.terminate()
    }

    /// Terminates the owned daemon and blocks until it has exited, so a caller can guarantee
    /// no child outlives it. Escalates to SIGKILL after the grace period: a SIGTERM sent
    /// during the child's early spawn window can be lost (observed on macOS 26), and a
    /// deterministic host must never hang on shutdown or leave a stale daemon behind.
    /// Safe when no daemon is running.
    public func stopAndWait(gracePeriod: TimeInterval = 5) {
        lock.lock()
        let child = process
        lock.unlock()
        guard let child else { return }
        let pid = child.processIdentifier
        child.terminate()
        let deadline = Date(timeIntervalSinceNow: gracePeriod)
        while kill(pid, 0) == 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
        child.waitUntilExit()
    }
}
