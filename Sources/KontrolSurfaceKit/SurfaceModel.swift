import Foundation
import KompleteKontrol

/// A full, intended snapshot of the surface: content for every LCD row and any
/// declared button LEDs. The declarative DSL builds one of these and the surface
/// applies it through the reconcilers; the imperative setters mutate the same
/// underlying state. Keeping both front-ends lowering to this model is what lets
/// the imperative API be removed later without touching declarative code.
public struct SurfaceModel: Sendable {
    var cells: [[CellContent]]
    var lamps: [KKButtonLED: LampState]

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

    func content(_ display: Int, _ row: Int) -> CellContent { cells[display][row] }
}
