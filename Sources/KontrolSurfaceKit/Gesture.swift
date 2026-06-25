import Foundation

/// A recognized button gesture phase. `down`/`up` are the raw edges; `tap`,
/// `doubleTap`, and `hold` are derived. A `tap` is delayed by the double-tap
/// window so it never fires alongside a `doubleTap`.
public enum GesturePhase: Sendable, Equatable {
    case down
    case up
    case tap
    case doubleTap
    case hold
}

/// Turns raw button up/down edges into tap / double-tap / hold gestures. Edge
/// events are fed from input; `tick` is polled on the surface clock to fire
/// holds and to resolve pending taps once the double-tap window passes.
struct GestureRecognizer {
    private struct Press {
        var downAt: UInt64
        var heldFired: Bool
    }

    private var presses: [String: Press] = [:]
    private var pendingTap: [String: UInt64] = [:]

    let holdThreshold: Double = 0.45
    let doubleTapWindow: Double = 0.30

    mutating func buttonChanged(_ name: String, pressed: Bool, now: UInt64) -> [GesturePhase] {
        if pressed {
            presses[name] = Press(downAt: now, heldFired: false)
            return [.down]
        }
        let wasHeld = presses[name]?.heldFired ?? false
        presses[name] = nil
        var phases: [GesturePhase] = [.up]
        guard !wasHeld else { return phases }
        if let firstTap = pendingTap[name], seconds(now - firstTap) <= doubleTapWindow {
            pendingTap[name] = nil
            phases.append(.doubleTap)
        } else {
            pendingTap[name] = now
        }
        return phases
    }

    mutating func tick(now: UInt64) -> [(name: String, phase: GesturePhase)] {
        var out: [(name: String, phase: GesturePhase)] = []
        for (name, press) in presses where !press.heldFired && seconds(now - press.downAt) >= holdThreshold {
            presses[name]?.heldFired = true
            out.append((name, .hold))
        }
        for (name, at) in pendingTap where seconds(now - at) > doubleTapWindow {
            pendingTap[name] = nil
            out.append((name, .tap))
        }
        return out
    }

    private func seconds(_ delta: UInt64) -> Double { Double(delta) / 1_000_000_000 }
}
