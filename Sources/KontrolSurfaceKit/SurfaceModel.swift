import Foundation
import KompleteKontrol

/// Input handlers a screen attaches to its elements while lowering. The surface
/// stores the latest set after each render and dispatches input to it.
struct InputHandlers {
    var encoder: [Int: (Int) -> Void] = [:]          // rotary encoder index 1…8 -> delta
    var mainEncoder: ((Int) -> Void)?                // 4-D wheel -> delta
    var tap: [String: () -> Void] = [:]              // button name -> tap
    var hold: [String: () -> Void] = [:]             // button name -> hold
    var secondary: [String: (String) -> Void] = [:]  // button name -> (modifier)
}

/// A full, intended snapshot of the surface: content for every LCD row, declared
/// button LEDs, and the input handlers a screen attached. The declarative DSL
/// builds one of these and the surface applies it through the reconcilers; the
/// imperative setters mutate the same underlying state. Keeping both front-ends
/// lowering to this model is what lets the imperative API be removed later
/// without touching declarative code.
public struct SurfaceModel {
    var cells: [[CellContent]]
    var lamps: [KKButtonLED: LampState]
    var keys: [Int: KKRGB] = [:]
    var handlers = InputHandlers()

    public init() {
        cells = Array(
            repeating: Array(repeating: .empty, count: KKDisplayFrame.rowCount),
            count: KKDisplayFrame.displayCount
        )
        lamps = [:]
    }

    public mutating func set(_ display: Int, _ row: Int, _ content: CellContent) {
        guard cells.indices.contains(display), cells[display].indices.contains(row) else { return }
        cells[display][row] = content
    }

    public mutating func setLamp(_ led: KKButtonLED, _ state: LampState) {
        lamps[led] = state
    }

    public mutating func setKey(_ index: Int, _ color: KKRGB) {
        keys[index] = color
    }

    func content(_ display: Int, _ row: Int) -> CellContent { cells[display][row] }
}
