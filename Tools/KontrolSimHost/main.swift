import Foundation
import KontrolSimulatorCore

/// Deterministic headless simulator host for end-to-end automation. See HostOptions.help
/// and Docs/Headless-Simulator-Host-Plan.md.
let options = HostOptions.parse(CommandLine.arguments)

let lease: SimulatorInstanceLease
do {
    lease = try SimulatorInstanceLease.acquire(SimulatorInstancePaths(instanceID: options.instanceID))
} catch let error as SimulatorInstanceError {
    FileHandle.standardError.write(Data("kontrol-sim-host: \(error)\n".utf8))
    if case .busy = error {
        exitHost(.instanceBusy)
    }
    exitHost(.usage)
} catch {
    FileHandle.standardError.write(Data("kontrol-sim-host: \(error)\n".utf8))
    exitHost(.usage)
}

HeadlessHost(options: options, lease: lease).run()
