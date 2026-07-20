import Darwin
import Foundation

/// Runs the shared MK2 console-client lifecycle without owning app state.
///
/// Demos and apps keep their own actors, scenes, and input semantics. The runner only
/// standardizes surface startup, connection-state logging, reconnect hooks, and the
/// "another client took over" policy.
public struct MK2SurfaceEventRunner: Sendable {
    public typealias LogHandler = @Sendable (String) -> Void
    public typealias SurfaceHook = @Sendable (MK2Surface2) async -> Void
    public typealias DetailHook = @Sendable (String, MK2Surface2) async -> Void
    public typealias ReasonHook = @Sendable (String, MK2Surface2) async -> Void

    public enum EvictionPolicy: Sendable, Equatable {
        case exitProcess(Int32)
        case returnToCaller
    }

    public let name: String
    public let surface: MK2Surface2
    public let evictionPolicy: EvictionPolicy
    private let log: LogHandler

    public init(
        name: String,
        surface: MK2Surface2,
        evictionPolicy: EvictionPolicy = .exitProcess(0),
        log: @escaping LogHandler = MK2SurfaceEventRunner.stdoutLog
    ) {
        self.name = name
        self.surface = surface
        self.evictionPolicy = evictionPolicy
        self.log = log
    }

    public static let stdoutLog: LogHandler = { message in
        print(message)
        fflush(stdout)
    }

    public func run(
        initialRender: @escaping SurfaceHook,
        onConnected: DetailHook? = nil,
        onRetrying: ReasonHook? = nil,
        onStopped: SurfaceHook? = nil,
        onEvicted: SurfaceHook? = nil
    ) async {
        await surface.start()
        await initialRender(surface)

        for await state in await surface.connectionStates {
            switch state {
                case let .connected(detail):
                    log("\(name): connected (\(detail))")
                    if let onConnected {
                        await onConnected(detail, surface)
                    }
                case let .deviceOffline(reason):
                    // Daemon session is fine; the surface resumes by itself on
                    // the daemon's "device reconnected" push.
                    log("\(name): hardware offline (\(reason))")
                case let .retrying(reason):
                    log("\(name): retrying (\(reason))")
                    if let onRetrying {
                        await onRetrying(reason, surface)
                    }
                case .stopped:
                    log("\(name): stopped")
                    if let onStopped {
                        await onStopped(surface)
                    }
                case .evicted:
                    log("\(name): evicted by another surface client - quitting")
                    if let onEvicted {
                        await onEvicted(surface)
                    }
                    switch evictionPolicy {
                        case let .exitProcess(code):
                            exit(code)
                        case .returnToCaller:
                            return
                    }
            }
        }
    }
}
