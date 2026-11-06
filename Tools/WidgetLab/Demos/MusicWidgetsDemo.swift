import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// A compact sample/mixer workflow showing the reusable music widgets.
final class MusicWidgetsDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "music-widgets", title: "Music Widgets", category: .catalogue,
        summary: "Slices, pads, mixer, curve and marquee",
        detail: "INSTANCE switches sample and mixer. Turn the 4-D wheel to select a pad or channel. E5 changes the selected channel gain or envelope shape.",
        snapshotVariants: ["mixer", "slices"]
    )
    private var mixer = false
    private var selected = 1
    private var value = 65
    private var elapsed = 0.0
    private var timer: DispatchSourceTimer?
    private var frozen = false

    func prepareSnapshot(variant: String) {
        mixer = variant == "mixer"; selected = mixer ? 2 : 1; value = 65; elapsed = 3
        frozen = true
        timer?.cancel(); timer = nil
    }
    func demoWillClose() { timer?.cancel(); timer = nil; frozen = false; elapsed = 0 }

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        if mixer && timer == nil && !frozen {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                context.update { [weak self] in self?.elapsed += 0.1 }
            }
            self.timer = timer; timer.resume()
        }
        var scene = MK2SurfaceScene2(left: leftFrame(), right: rightFrame())
        scene.lamps[.instance] = .on(KKRGB(red: 255, green: 255, blue: 255), intensity: 1)
        scene.bindings.onPress(.instance) { [weak self] in
            context.update { [weak self] in
                guard let self else { return }; self.mixer.toggle(); self.selected = 0; self.elapsed = 0
                if !self.mixer { self.timer?.cancel(); self.timer = nil }
            }
        }
        scene.bindings.jogScroll = { [weak self] delta, _ in
            context.update { [weak self] in
                guard let self else { return }
                self.selected = max(0, min(self.mixer ? 3 : 15, self.selected + delta)); self.elapsed = 0
            }
        }
        let encoder = MK2EncoderDiscreteValue(encoder: 5, value: value, bounds: 0...100,
            display: MK2EncoderDiscreteValueDisplay(label: mixer ? "GAIN" : "DECAY", value: "\(value)%", rect: MK2ScreenLayout.encoderSlotRect(0), colors: labEditCellColors(value: Palette.text)),
            onChange: { [weak self] value in context.update { [weak self] in self?.value = value } })
        encoder.apply(bindings: &scene.bindings)
        return scene
    }
    private func heading(_ text: String, frame: inout MK2PixelFrame) {
        BitmapLabel(text, font: .readoutBold, color: 0xffff).draw(into: &frame, x: 12, y: 10)
        BitmapLabel("INSTANCE: SWITCH  /  4-D: SELECT", font: .grid, color: 0x8410).draw(into: &frame, x: 12, y: 38)
    }
    private func leftFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: 0x0862)
        heading(mixer ? "FOUR CHANNEL MIXER" : "SAMPLE SLICES", frame: &frame)
        if mixer {
            for i in 0..<4 {
                MK2MixerStrip(label: "CH \(i + 1)", rect: MK2PixelRect(x: 12 + i * 117, y: 65, width: 104, height: 184),
                    levels: [0.36 + Double(i) * 0.12, 0.30 + Double(i) * 0.13], peaks: [0.7, 0.8],
                    gain: i == selected ? Double(value) / 100 : 0.7, muted: i == 3, soloed: i == 2, selected: i == selected).draw(into: &frame)
            }
        } else {
            let decay = 0.4 + Double(value) / 45
            let minima = (0..<256).map { i in -Float(abs(sin(Double(i) * 0.17)) * exp(-decay * Double(i) / 256)) }
            let maxima = minima.map { -$0 }
            let slice = selected
            let ranges = (0..<4).map { Double($0) / 4...Double($0 + 1) / 4 }
            MK2WaveformDisplay(envelope: MK2WaveformEnvelope(minima: minima, maxima: maxima),
                rect: MK2PixelRect(x: 12, y: 72, width: 456, height: 166), region: slice < ranges.count ? ranges[slice] : nil,
                additionalRegions: ranges.enumerated().filter { $0.offset != slice }.map(\.element), playhead: 0.62).draw(into: &frame)
        }
        return frame
    }
    private func rightFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: 0x0862)
        heading(mixer ? "CHANNEL DETAIL" : "PAD SELECTION", frame: &frame)
        if mixer {
            MK2Marquee("A VERY LONG INSTRUMENT NAME FOR THE SELECTED CHANNEL", rect: MK2PixelRect(x: 14, y: 65, width: 320, height: 20), elapsed: elapsed, font: .gridBold, color: 0xffff).draw(into: &frame)
            BitmapLabel("AMPLITUDE ENVELOPE", font: .grid, color: 0x8410).draw(into: &frame, x: 14, y: 103)
            let sustain = Double(value) / 100
            MK2CurvePlot(points: [.init(0, 0), .init(0.12, 1), .init(0.35, sustain), .init(0.72, sustain), .init(1, 0)], rect: MK2PixelRect(x: 14, y: 125, width: 450, height: 80)).draw(into: &frame)
        } else {
            let pads = (0..<16).map { MK2PadMatrix.Pad("\($0 + 1)", occupied: $0 < 4, selected: $0 == selected) }
            MK2PadMatrix(pads: pads, rect: MK2PixelRect(x: 14, y: 62, width: 452, height: 147)).draw(into: &frame)
        }
        let label = mixer ? "GAIN" : "DECAY"
        MK2EncoderDiscreteValueDisplay(label: label, value: "\(value)%", rect: MK2ScreenLayout.encoderSlotRect(0), colors: labEditCellColors(value: Palette.text)).draw(into: &frame, renderer: nil)
        return frame
    }
}
