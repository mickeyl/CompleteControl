import Foundation

/// A `DispatchSourceTimer`-backed tick source. A dispatch timer is used instead of
/// a run-loop `Timer` or `CADisplayLink` because it has the lowest and most
/// predictable wake-up latency, which the surface reconciler depends on.
final class SurfaceClock: @unchecked Sendable {
    private let timer: DispatchSourceTimer

    init(intervalMs: Int, handler: @escaping @Sendable () -> Void) {
        let queue = DispatchQueue(label: "kontrolsurface.clock", qos: .userInteractive)
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(intervalMs),
            repeating: .milliseconds(intervalMs),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler(handler: handler)
    }

    func start() { timer.activate() }
    func stop() { timer.cancel() }
}
