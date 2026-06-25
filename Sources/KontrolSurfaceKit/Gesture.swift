import Foundation

/// A recognized button gesture. `down`/`up` are the raw edges. `tap` fires
/// immediately on release for low latency. `hold` fires once a button has been
/// held past the threshold. `secondary` is a tap on one button while another is
/// held down (a chord / modifier — e.g. Shift + Loop); the held button is then
/// consumed so its own release produces no `tap`.
///
/// There is deliberately no double-tap: repeated-press semantics are better
/// expressed through state (e.g. a second Stop tap means return-to-zero).
public enum GesturePhase: Sendable, Equatable {
    case down
    case up
    case tap
    case hold
    case secondary(modifier: String)
}

/// Turns raw button up/down edges into tap / hold / secondary gestures. Edges
/// are fed from input and resolved immediately; `tick` is polled on the surface
/// clock only to fire holds while a button stays down.
struct GestureRecognizer {
    private struct Press {
        var downAt: UInt64
        var heldFired: Bool
        var consumed: Bool
    }

    private var presses: [String: Press] = [:]

    let holdThreshold: Double = 0.45

    mutating func buttonChanged(_ name: String, pressed: Bool, now: UInt64) -> [GesturePhase] {
        if pressed {
            presses[name] = Press(downAt: now, heldFired: false, consumed: false)
            return [.down]
        }
        let press = presses[name]
        presses[name] = nil
        var phases: [GesturePhase] = [.up]
        guard let press, !press.heldFired, !press.consumed else { return phases }
        if let modifier = heldModifier() {
            presses[modifier]?.consumed = true
            phases.append(.secondary(modifier: modifier))
        } else {
            phases.append(.tap)
        }
        return phases
    }

    mutating func tick(now: UInt64) -> [(name: String, phase: GesturePhase)] {
        var out: [(name: String, phase: GesturePhase)] = []
        for (name, press) in presses where !press.heldFired && seconds(now - press.downAt) >= holdThreshold {
            presses[name]?.heldFired = true
            out.append((name, .hold))
        }
        return out
    }

    /// A button still held while another is tapped acts as the modifier. Shift
    /// wins if it is one of them; otherwise any held button.
    private func heldModifier() -> String? {
        presses.keys.contains("shift") ? "shift" : presses.keys.first
    }

    private func seconds(_ delta: UInt64) -> Double { Double(delta) / 1_000_000_000 }
}
