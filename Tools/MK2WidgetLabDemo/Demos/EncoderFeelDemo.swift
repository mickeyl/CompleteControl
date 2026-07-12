import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// Encoder-feel playground: eight discrete values across both screens with
/// growing domain sizes, so the adaptive counts-per-step derivation and the
/// rate-based sweep acceleration can be judged side by side on hardware.
/// Cells show value/domain plus the derived counts-per-step and acceleration
/// ceiling; double-touch resets to the midpoint.
final class EncoderFeelDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "encoder-feel",
        title: "Encoder Feel",
        category: .calibration,
        summary: "Adaptive throw across domain sizes",
        detail: "Eight discrete values with domains from on/off to 8192. Labels show the derived counts-per-step and acceleration ceiling; double-touch resets to the midpoint."
    )

    /// Small domains double on the left screen, large ones grow 8× on the
    /// right — the sweep acceleration only shows on genuinely big ranges.
    private static let domains = [2, 4, 8, 16, 32, 256, 1024, 8192]
    private var values = EncoderFeelDemo.domains.map { $0 / 2 }

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        MK2DoubleScreenDSL(
            left: screen(range: 0..<4, context: context),
            right: screen(range: 4..<8, context: context)
        ).scene()
    }

    private func screen(range: Range<Int>, context: LabContext) -> MK2ScreenBuildResult {
        let title = range.lowerBound == 0 ? "ENCODER FEEL" : "ADAPTIVE THROW"
        let hint = range.lowerBound == 0 ? "2xTAP = RESET TO MIDPOINT" : "FAST TURNS ACCELERATE UP TO xN"
        let slots = range.map { index -> MK2ParameterPageSlot in
            let domain = Self.domains[index]
            let bounds = 0...(domain - 1)
            let value = values[index]
            let displayValue = domain == 2 ? (value == 1 ? "ON" : "OFF") : "\(value + 1)/\(domain)"
            let countsPerStep = MK2EncoderDiscreteValue.automaticCountsPerStep(for: bounds)
            let acceleration = MK2EncoderDiscreteValue.sweepAcceleration(for: bounds, countsPerStep: countsPerStep)
            let accelerationSuffix = acceleration > 1.5 ? "·\(Int(acceleration.rounded()))X" : ""
            return MK2ParameterPageSlot(
                label: "\(domain)V·\(countsPerStep)C\(accelerationSuffix)",
                value: displayValue,
                encoderValue: MK2EncoderDiscreteValue(
                    encoder: index + 1,
                    value: value,
                    bounds: bounds,
                    defaultValue: domain / 2,
                    onChange: { [weak self] value in
                        context.update { self?.values[index] = value }
                    }
                )
            )
        }
        return MK2FullScreenDSL(
            background: Palette.page,
            header: .status([
                MK2StatusLineItem(title, x: 8, color: Palette.blue),
                MK2StatusLineItem(hint, x: 150, color: Palette.dim),
            ])
        ) {
            MK2ParameterPageElement(slots: slots)
        }.build(renderer: context.renderer)
    }
}
