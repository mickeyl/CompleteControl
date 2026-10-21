import Foundation
import KompleteKontrol
import KontrolSurfaceKit2
import PaulincheSurfaceKit

/// Product page realization: all eight encoder slots remain physically aligned.
final class InstrumentSequenceDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(id: "instrument-sequence", title: "Instrument Sequence",
        category: .catalogue, summary: "Paulinche pitch and volume steps",
        detail: "E1 selects a step; E2/E3 edit pitch and volume. E4 changes tick speed.")
    private var step = 0
    private var pitches = [0, 7, 12, 7]
    private var volumes = [64, 48, 56, 0]
    private var ticks = 3

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        let labels = ["STEP", "PITCH", "VOLUME", "TICKS", "LOOP", "FROM", "LENGTH", "ENABLED"]
        let values = ["\(step + 1)", "\(pitches[step]) st", "\(volumes[step])", "\(ticks)", "LOOP", "1", "4", "ON"]
        let scene = MK2PaulincheInstrumentScene(title: "01 SEQUENCE", subtitle: "PITCH / VOLUME",
            instrumentIndex: 0, kind: .wavetable, wavetablePage: .stepSequence,
            infoLines: ["4 steps / \(ticks) ticks each", "Pitch and volume restart with each note."],
            waveform: MK2WaveformEnvelope(minima: (0..<256).map { $0 % 32 < 16 ? -0.8 : 0.8 },
                maxima: (0..<256).map { $0 % 32 < 16 ? -0.8 : 0.8 }),
            parameters: zip(labels, values).enumerated().map { index, pair in
                MK2PaulinchePatternParameter(label: pair.0, value: pair.1, isFocused: index == 0, isEnabled: index < 4)
            })
        return MK2PaulincheInstrumentRenderer.surfaceScene(scene, actions: .init(onEncoderChange: { [self] encoder, delta in
            context.update { [self] in
                switch encoder {
                case 1: self.step = min(3, max(0, self.step + delta))
                case 2: self.pitches[self.step] = min(24, max(-24, self.pitches[self.step] + delta))
                case 3: self.volumes[self.step] = min(64, max(0, self.volumes[self.step] + delta))
                case 4: self.ticks = min(16, max(1, self.ticks + delta))
                default: break
                }
            }
        }), renderer: context.renderer)
    }
}
