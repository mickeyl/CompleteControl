import Foundation
import KompleteKontrol

/// Holds the intended state of every button LED, advances blink/pulse animations
/// on the surface clock, and reports the LEDs whose brightness changed so the
/// reconcile loop sends a button-LED report only when something actually moves.
struct LEDReconciler {
    private var state: [LampState]
    private var phase: [Double]
    private var lastSent: [UInt8?]

    init() {
        let count = KKButtonLED.allCases.count
        state = Array(repeating: .off, count: count)
        phase = Array(repeating: 0, count: count)
        lastSent = Array(repeating: nil, count: count)
    }

    mutating func set(_ led: KKButtonLED, _ newState: LampState) {
        let index = led.rawValue
        guard state.indices.contains(index) else { return }
        if state[index] != newState {
            state[index] = newState
            phase[index] = 0
        }
    }

    mutating func clearAll() {
        for index in state.indices {
            state[index] = .off
            phase[index] = 0
        }
    }

    mutating func advance(dt: Double) {
        for index in state.indices {
            switch state[index] {
                case let .blink(period, _), let .pulse(period, _):
                    if period > 0 { phase[index] += dt / period }
                default:
                    break
            }
        }
    }

    mutating func render() -> [(index: Int, value: UInt8)] {
        var changed: [(index: Int, value: UInt8)] = []
        for index in state.indices {
            let value = brightness(index)
            if lastSent[index] != value {
                lastSent[index] = value
                changed.append((index, value))
            }
        }
        return changed
    }

    private func brightness(_ index: Int) -> UInt8 {
        switch state[index] {
            case .off:
                return 0
            case let .on(level):
                return level
            case let .blink(_, level):
                return phase[index].truncatingRemainder(dividingBy: 1) < 0.5 ? level : 0
            case let .pulse(_, level):
                let t = phase[index].truncatingRemainder(dividingBy: 1)
                let triangle = t < 0.5 ? t * 2 : 2 - t * 2
                return UInt8(Double(level) * triangle)
        }
    }
}
