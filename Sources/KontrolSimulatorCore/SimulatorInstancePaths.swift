import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The complete file namespace of one isolated simulator instance. Every path lives under
/// one short per-instance directory that is disjoint from the graphical simulator's legacy
/// global paths and from the hardware daemon, so parallel headless runs cannot collide with
/// either — regardless of instance ID. No other type may assemble these path strings.
public struct SimulatorInstancePaths: Sendable, Equatable {
    public let instanceID: String
    public let directory: String

    public var deviceSocketPath: String { directory + "/device.sock" }
    public var daemonSocketPath: String { directory + "/daemon.sock" }
    public var daemonLogPath: String { directory + "/daemon.log" }
    public var lockPath: String { directory + "/host.lock" }

    /// Every file a host or its owned daemon may create inside the instance directory.
    /// Reclaim and teardown delete exactly these names and nothing else, so a foreign
    /// file in the directory is never destroyed (the directory then simply remains).
    public var ownedFilePaths: [String] {
        [
            deviceSocketPath,
            daemonSocketPath,
            daemonSocketPath + ".events",
            daemonSocketPath + ".display",
            daemonSocketPath + ".automation",
            directory + "/daemon.lock",
            daemonLogPath,
        ]
    }

    public static func isValidInstanceID(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !value.isEmpty && value.utf8.count <= 32
            && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    public init(instanceID: String) throws {
        guard Self.isValidInstanceID(instanceID) else {
            throw SimulatorInstanceError.invalidInstanceID(instanceID)
        }
        self.instanceID = instanceID
        // Deliberately /tmp, not $TMPDIR: sun_path is limited to 104 bytes on Darwin and
        // the per-user $TMPDIR under /var/folders would eat most of that budget.
        self.directory = "/tmp/kksim-\(instanceID)"
    }
}

public enum SimulatorInstanceError: Error, Equatable, CustomStringConvertible {
    case invalidInstanceID(String)
    case busy(instanceID: String, holderPID: Int32?)
    case ioFailure(String)

    public var description: String {
        switch self {
            case let .invalidInstanceID(value):
                return "invalid instance ID '\(value)'; use 1-32 letters, digits, '-' or '_'"
            case let .busy(instanceID, holderPID):
                let holder = holderPID.map { " (pid \($0))" } ?? ""
                return "instance '\(instanceID)' is already in use\(holder)"
            case let .ioFailure(message):
                return message
        }
    }
}

/// Exclusive ownership of one instance directory for the lifetime of a host process.
/// The `flock` on `host.lock` is the single source of truth: it is released by the kernel
/// even on SIGKILL, so a stale directory from a dead host is reclaimed simply by acquiring
/// the lock again and deleting the known leftover files.
public final class SimulatorInstanceLease: @unchecked Sendable {
    public let paths: SimulatorInstancePaths
    private let lockFD: Int32
    private let lock = NSLock()
    private var released = false

    private init(paths: SimulatorInstancePaths, lockFD: Int32) {
        self.paths = paths
        self.lockFD = lockFD
    }

    deinit {
        releaseAndCleanUp()
    }

    public static func acquire(_ paths: SimulatorInstancePaths) throws -> SimulatorInstanceLease {
        var directoryStat = stat()
        if stat(paths.directory, &directoryStat) == 0 {
            guard (directoryStat.st_mode & S_IFMT) == S_IFDIR else {
                throw SimulatorInstanceError.ioFailure("\(paths.directory) exists and is not a directory")
            }
        } else if mkdir(paths.directory, 0o700) != 0 && errno != EEXIST {
            throw SimulatorInstanceError.ioFailure("cannot create \(paths.directory): \(String(cString: strerror(errno)))")
        }

        let fd = open(paths.lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw SimulatorInstanceError.ioFailure("cannot open \(paths.lockPath): \(String(cString: strerror(errno)))")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let holderPID = readPID(fd: fd)
            close(fd)
            throw SimulatorInstanceError.busy(instanceID: paths.instanceID, holderPID: holderPID)
        }

        // Lock held: any leftovers belong to a dead previous holder and are safe to remove.
        for path in paths.ownedFilePaths { unlink(path) }
        writePID(fd: fd)
        return SimulatorInstanceLease(paths: paths, lockFD: fd)
    }

    /// Removes the instance's owned files, the lock, and — when nothing foreign remains —
    /// the directory itself. Idempotent; also runs from `deinit` as a safety net.
    public func releaseAndCleanUp() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        for path in paths.ownedFilePaths { unlink(path) }
        unlink(paths.lockPath)
        rmdir(paths.directory)
        close(lockFD)
    }

    private static func readPID(fd: Int32) -> Int32? {
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0,
              let text = String(bytes: buffer[0..<count], encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }

    private static func writePID(fd: Int32) {
        let text = "\(getpid())\n"
        ftruncate(fd, 0)
        _ = text.withCString { pwrite(fd, $0, strlen($0), 0) }
    }
}
