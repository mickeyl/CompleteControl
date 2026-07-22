import Foundation
import Testing
import KontrolSimulatorCore

@Suite("Simulator instance paths")
struct SimulatorInstancePathsTests {
    private func uniqueID(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8))"
    }

    @Test("instance ID validation")
    func instanceIDValidation() throws {
        #expect(SimulatorInstancePaths.isValidInstanceID("main"))
        #expect(SimulatorInstancePaths.isValidInstanceID("ci-42_a"))
        #expect(!SimulatorInstancePaths.isValidInstanceID(""))
        #expect(!SimulatorInstancePaths.isValidInstanceID("a/b"))
        #expect(!SimulatorInstancePaths.isValidInstanceID("a b"))
        #expect(!SimulatorInstancePaths.isValidInstanceID(String(repeating: "x", count: 33)))
        #expect(throws: SimulatorInstanceError.invalidInstanceID("a/b")) {
            _ = try SimulatorInstancePaths(instanceID: "a/b")
        }
    }

    @Test("namespace is disjoint from the legacy global simulator paths")
    func namespaceDisjointFromLegacyPaths() throws {
        let paths = try SimulatorInstancePaths(instanceID: "main")
        let legacy = ["/tmp/kontrol-simulator.sock", "/tmp/kontrol-simulator-daemon.sock"]
        for path in [paths.deviceSocketPath, paths.daemonSocketPath] + paths.ownedFilePaths {
            #expect(!legacy.contains(path))
            #expect(path.hasPrefix(paths.directory + "/"))
        }
        // sockaddr_un.sun_path budget, including the daemon's longest derived channel suffix.
        #expect((paths.daemonSocketPath + ".automation").utf8.count < 104)
    }

    @Test("acquire, busy detection, and release")
    func acquireBusyRelease() throws {
        let paths = try SimulatorInstancePaths(instanceID: uniqueID("t-busy"))
        let lease = try SimulatorInstanceLease.acquire(paths)
        #expect(FileManager.default.fileExists(atPath: paths.directory))

        #expect(throws: SimulatorInstanceError.busy(instanceID: paths.instanceID, holderPID: getpid())) {
            _ = try SimulatorInstanceLease.acquire(paths)
        }

        lease.releaseAndCleanUp()
        #expect(!FileManager.default.fileExists(atPath: paths.directory))

        let second = try SimulatorInstanceLease.acquire(paths)
        second.releaseAndCleanUp()
    }

    @Test("reclaim removes only the known owned files")
    func reclaimRemovesOnlyOwnedFiles() throws {
        let paths = try SimulatorInstancePaths(instanceID: uniqueID("t-reclaim"))
        try FileManager.default.createDirectory(atPath: paths.directory, withIntermediateDirectories: false)
        for path in paths.ownedFilePaths {
            FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        }
        let foreignPath = paths.directory + "/foreign.txt"
        FileManager.default.createFile(atPath: foreignPath, contents: Data("keep me".utf8))

        let lease = try SimulatorInstanceLease.acquire(paths)
        for path in paths.ownedFilePaths {
            #expect(!FileManager.default.fileExists(atPath: path))
        }
        #expect(FileManager.default.fileExists(atPath: foreignPath))

        // Teardown must leave the foreign file (and therefore the directory) untouched.
        lease.releaseAndCleanUp()
        #expect(FileManager.default.fileExists(atPath: foreignPath))
        #expect(FileManager.default.fileExists(atPath: paths.directory))

        try FileManager.default.removeItem(atPath: paths.directory)
    }

    @Test("release is idempotent")
    func releaseIsIdempotent() throws {
        let paths = try SimulatorInstancePaths(instanceID: uniqueID("t-idem"))
        let lease = try SimulatorInstanceLease.acquire(paths)
        lease.releaseAndCleanUp()
        lease.releaseAndCleanUp()
        #expect(!FileManager.default.fileExists(atPath: paths.directory))
    }
}
