import Foundation
import KompleteKontrol

/// Binds up to eight ``Parameter``s to the eight encoders and the eight content
/// displays (1…8). The status display (0) carries the page title. Each cell
/// renders as: row 0 progress bar, row 1 name (marquee when long), row 2 value.
///
/// While a page is the surface's active page, encoder turns are routed here
/// automatically, stepped with velocity acceleration, clamped, and reflected
/// back onto the display.
public final class ParameterPage: @unchecked Sendable {
    /// Number of encoders / content displays available to a page.
    public static let capacity = 8

    public var title: String
    public private(set) var parameters: [Parameter]
    private var lastTurnNanos: [UInt64]

    public init(title: String, parameters: [Parameter]) {
        self.title = title
        self.parameters = Array(parameters.prefix(Self.capacity))
        self.lastTurnNanos = Array(repeating: 0, count: self.parameters.count)
    }

    public func value(at index: Int) -> Double? {
        parameters.indices.contains(index) ? parameters[index].value : nil
    }

    /// Display index (1…8) that a parameter slot maps to. Display 0 is status.
    private func display(for index: Int) -> Int { index + 1 }

    func render(on surface: isolated Surface) {
        surface.setStatus(title)
        for (index, parameter) in parameters.enumerated() {
            let display = display(for: index)
            surface.setBar(parameter.normalized, lcd: display)
            surface.setText(display, 1, parameter.name, overflow: .marquee())
            surface.setText(display, 2, parameter.formattedValue, alignment: .center, overflow: .clip)
        }
    }

    /// `encoder` is the hardware encoder index (1…8, as the decoder reports it);
    /// slot 0 / display 1 sits under encoder 1.
    func handleEncoder(encoder: Int, delta: Int, on surface: isolated Surface) {
        let slot = encoder - 1
        guard parameters.indices.contains(slot) else { return }
        parameters[slot].apply(delta: step(for: slot, delta: delta))
        let parameter = parameters[slot]
        parameter.onChange?(parameter.value)

        let display = display(for: slot)
        surface.setBar(parameter.normalized, lcd: display)
        surface.setText(display, 2, parameter.formattedValue, alignment: .center, overflow: .clip)
    }

    /// Velocity-sensitive step. The base increment is range-relative — roughly a
    /// full sweep over ~600 encoder counts at slow speed — so the same feel works
    /// across small and large ranges. Faster turns (shorter interval between
    /// reports) accelerate it. The encoder delta scales linearly, which already
    /// accounts for how far the high-resolution encoder moved.
    private func step(for index: Int, delta: Int) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        let previous = lastTurnNanos[index]
        let elapsed = previous == 0 ? 1.0 : Double(now &- previous) / 1_000_000_000.0
        lastTurnNanos[index] = now

        let parameter = parameters[index]
        let span = max(parameter.range.upperBound - parameter.range.lowerBound, 1)
        let perCount = span / 900.0
        let acceleration: Double
        if elapsed < 0.035 {
            acceleration = 5
        } else if elapsed < 0.090 {
            acceleration = 3
        } else {
            acceleration = 1
        }
        return Double(delta) * perCount * acceleration * parameter.sensitivity
    }
}
