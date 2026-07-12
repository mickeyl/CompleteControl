import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// The waveform display element across four material variants: a dense
/// pluck, a sparse envelope, a quiet source riding the display gain, and the
/// empty case. E5-E8 drive loop and markers, the 4-D wheel scrubs the
/// playhead, INSTANCE cycles the source.
final class WaveformDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "waveform",
        title: "Waveform",
        category: .catalogue,
        summary: "Waveform display variants",
        detail: "Region, markers and playhead over four material variants. E5-E8 drive loop and markers, 4-D scrubs the playhead, INSTANCE cycles the source.",
        snapshotVariants: ["sparse", "quiet", "empty"]
    )

    private enum Variant: Int, CaseIterable {
        case pluck, sparse, quiet, empty

        var next: Variant { Self(rawValue: (rawValue + 1) % Self.allCases.count)! }

        var title: String {
            switch self {
                case .pluck: "PLUCK, 2048 BINS"
                case .sparse: "SPARSE, 24 BINS"
                case .quiet: "QUIET SOURCE, GAIN 3.5X"
                case .empty: "EMPTY ENVELOPE"
            }
        }

        var shortTitle: String {
            switch self {
                case .pluck: "PLUCK"
                case .sparse: "SPARSE"
                case .quiet: "QUIET"
                case .empty: "EMPTY"
            }
        }
    }

    private static let startMarker = 0.08
    private static let endMarker = 0.95

    private var variant: Variant = .pluck
    private var loopEnabled = true
    private var loopStartPercent = 42
    private var loopEndPercent = 88
    private var markersEnabled = true
    private var playheadPercent = 55
    private var focusedEncoder: Int?

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        var scene = MK2SurfaceScene2(
            left: displayFrame(),
            right: controlScreen(context).screen.frame,
            lamps: [.instance: .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01)]
        )
        scene.bindings.onPress(.instance) { [weak self] in
            context.update {
                guard let self else { return }
                self.variant = self.variant.next
            }
        }
        scene.bindings.jogScroll = { [weak self] delta, _ in
            context.update {
                guard let self else { return }
                self.playheadPercent = max(0, min(100, self.playheadPercent + delta))
            }
        }
        for value in encoderValues(context) {
            value.apply(bindings: &scene.bindings)
        }
        return scene
    }

    func prepareSnapshot(variant name: String) {
        switch name {
            case "sparse": variant = .sparse
            case "quiet": variant = .quiet
            case "empty": variant = .empty
            default: variant = .pluck
        }
    }

    /// A decaying pluck with a loopable sustain tail — enough dynamics that
    /// the min/max merge, the region dimming and the display gain are all
    /// visible.
    private static func envelope(bins: Int, quiet: Bool = false) -> MK2WaveformEnvelope {
        var minima = [Float](repeating: 0, count: bins)
        var maxima = [Float](repeating: 0, count: bins)
        for bin in 0..<bins {
            let t = Double(bin) / Double(bins)
            let decay = exp(-3.2 * t)
            let carrier = sin(t * 197.0) * 0.6 + sin(t * 41.0) * 0.4
            let noise = sin(t * 1_211.0) * 0.35 * exp(-9.0 * t)
            let amplitude = (abs(carrier) * decay + abs(noise)) * (quiet ? 0.18 : 0.95)
            maxima[bin] = Float(amplitude)
            minima[bin] = Float(-amplitude * (0.7 + 0.3 * sin(t * 63.0)))
        }
        return MK2WaveformEnvelope(minima: minima, maxima: maxima, gain: quiet ? 3.5 : 1)
    }

    private func currentEnvelope() -> MK2WaveformEnvelope {
        switch variant {
            case .pluck: Self.envelope(bins: 2_048)
            case .sparse: Self.envelope(bins: 24)
            case .quiet: Self.envelope(bins: 2_048, quiet: true)
            case .empty: MK2WaveformEnvelope(minima: [], maxima: [])
        }
    }

    private func displayFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        BitmapLabel("WAVEFORM DISPLAY", font: .readout, color: Palette.text).draw(into: &frame, x: 16, y: 12)
        BitmapLabel(variant.title, font: .label, color: Palette.dim).draw(into: &frame, x: 16, y: 44)
        MK2WaveformDisplay(
            envelope: currentEnvelope(),
            rect: MK2PixelRect(x: 8, y: 64, width: 464, height: 200),
            region: loopEnabled
                ? Double(loopStartPercent) / 100...Double(loopEndPercent) / 100
                : nil,
            markers: markersEnabled ? [Self.startMarker, Self.endMarker] : [],
            playhead: Double(playheadPercent) / 100
        ).draw(into: &frame)
        return frame
    }

    private func controlScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        let values = encoderValues(context)
        let variant = variant
        let summary: [(String, UInt16)] = [
            ("SOURCE   \(variant.title)", Palette.text),
            ("LOOP     \(loopEnabled ? "\(loopStartPercent)% - \(loopEndPercent)%" : "OFF")", Palette.text),
            ("MARKERS  \(markersEnabled ? "START + END" : "OFF")", Palette.text),
            ("PLAYHEAD \(playheadPercent)% VIA 4-D WHEEL", Palette.blue),
            ("INSTANCE CYCLES THE SOURCE", Palette.dim),
            ("F-BAR IS A LOOK PROBE, UNBOUND", Palette.dim),
        ]
        return MK2FullScreenDSL(background: Palette.page) {
            // Look-and-feel probe only: deliberately no onPress.
            MK2FunctionKeyBarElement(
                slots: [
                    MK2FunctionKeySlot("Zoom"),
                    MK2FunctionKeySlot("Snap"),
                    MK2FunctionKeySlot("Norm", isEnabled: false),
                    MK2FunctionKeySlot("Trim"),
                ],
                side: .right
            )
            MK2AnyScreenElement { frame, _, _ in
                MK2StatusLine(y: 30, items: [
                    MK2StatusLineItem("WAVEFORM", x: 8, color: Palette.blue),
                    MK2StatusLineItem(variant.shortTitle, x: 140, color: Palette.text, font: .gridBold),
                ]).draw(into: &frame)
                frame.hline(y: 54, x: 0, width: 480, color: Palette.border)
                var y = 66
                for (text, color) in summary {
                    BitmapLabel(text, font: .grid, color: color).draw(into: &frame, x: 8, y: y)
                    y += SurfaceFont.grid.cellHeight + 6
                }
                for value in values {
                    value.drawDisplay(into: &frame)
                }
            }
        }.build(renderer: context.renderer)
    }

    private func encoderValues(_ context: LabContext) -> [MK2EncoderDiscreteValue] {
        let loopColor = loopEnabled ? Palette.text : Palette.dim
        func touch(_ encoder: Int) -> (@Sendable (Bool) -> Void) {
            { [weak self] touched in
                context.update {
                    guard let self else { return }
                    if touched {
                        self.focusedEncoder = encoder
                    } else if self.focusedEncoder == encoder {
                        self.focusedEncoder = nil
                    }
                }
            }
        }
        return [
            MK2EncoderDiscreteValue(
                encoder: 5, value: loopEnabled ? 1 : 0, bounds: 0...1,
                display: display(label: "LOOP", value: loopEnabled ? "ON" : "OFF", encoder: 5, color: loopColor),
                onTouch: touch(5),
                onChange: { [weak self] value in
                    context.update { self?.loopEnabled = value == 1 }
                }
            ),
            MK2EncoderDiscreteValue(
                encoder: 6, value: loopStartPercent, bounds: 0...loopEndPercent,
                display: display(label: "LP ST", value: "\(loopStartPercent)%", encoder: 6, color: loopColor),
                onTouch: touch(6),
                onChange: { [weak self] value in
                    context.update {
                        guard let self else { return }
                        self.loopStartPercent = max(0, min(self.loopEndPercent, value))
                    }
                }
            ),
            MK2EncoderDiscreteValue(
                encoder: 7, value: loopEndPercent, bounds: loopStartPercent...100,
                display: display(label: "LP END", value: "\(loopEndPercent)%", encoder: 7, color: loopColor),
                onTouch: touch(7),
                onChange: { [weak self] value in
                    context.update {
                        guard let self else { return }
                        self.loopEndPercent = max(self.loopStartPercent, min(100, value))
                    }
                }
            ),
            MK2EncoderDiscreteValue(
                encoder: 8, value: markersEnabled ? 1 : 0, bounds: 0...1,
                display: display(label: "MARKS", value: markersEnabled ? "ON" : "OFF", encoder: 8, color: markersEnabled ? Palette.text : Palette.dim),
                onTouch: touch(8),
                onChange: { [weak self] value in
                    context.update { self?.markersEnabled = value == 1 }
                }
            ),
        ]
    }

    private func display(label: String, value: String, encoder: Int, color: UInt16) -> MK2EncoderDiscreteValueDisplay {
        MK2EncoderDiscreteValueDisplay(
            label: label,
            value: value,
            rect: MK2ScreenLayout.encoderSlotRect(encoder - 5),
            isFocused: focusedEncoder == encoder,
            valueFont: .readoutBold,
            cornerRadius: 7,
            colors: labEditCellColors(value: color)
        )
    }
}
