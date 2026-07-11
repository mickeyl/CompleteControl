import Foundation
import KompleteKontrol
import PaulincheSurfaceKit
import Testing
@testable import KontrolSurfaceKit2

/// Ad-hoc timing probe for the instrument editor render path (the 21 ms/tick
/// hot spot seen during encoder turns). Prints component timings; enable with
/// PAULINCHE_RENDER_TIMING=1.
@Suite("Instrument render timing probe")
struct InstrumentRenderTimingTests {
    @Test("Time full render and components")
    func timeRenderComponents() throws {
        guard ProcessInfo.processInfo.environment["PAULINCHE_RENDER_TIMING"] == "1" else { return }
        let renderer = try FreeTypeTextRenderer()
        let samples = (0..<2_048).map { Float(sin(Double($0) * 0.13) * exp(-Double($0) / 900)) }
        let envelope = MK2WaveformEnvelope(minima: samples.map { -abs($0) }, maxima: samples.map { abs($0) })

        func scene(value: Int) -> MK2PaulincheInstrumentScene {
            MK2PaulincheInstrumentScene(
                title: "MOSKWA-ZAP",
                subtitle: "EDIT 01 SAMPLE",
                instrumentIndex: 0,
                kind: .sample,
                infoLines: ["10368 FRAMES · 44100 HZ", "LOOP 821…9864 · 9043 FRM"],
                waveform: envelope,
                loopRegion: 0.1...0.9,
                markers: [Double(value % 400) / 400.0],
                parameters: [
                    MK2PaulinchePatternParameter(label: "LOOP ST", value: "\(821 + value)"),
                    MK2PaulinchePatternParameter(label: "LOOP END", value: "9864"),
                    MK2PaulinchePatternParameter(label: "START", value: "\(2_551 + value)"),
                    MK2PaulinchePatternParameter(label: "END", value: "9577"),
                    MK2PaulinchePatternParameter(label: "LEVEL", value: "100%"),
                    MK2PaulinchePatternParameter(label: "FINE", value: "0ct"),
                    MK2PaulinchePatternParameter(label: "ROOT", value: "C-4"),
                    MK2PaulinchePatternParameter(label: "", value: ""),
                ]
            )
        }

        func time(_ label: String, iterations: Int = 50, _ work: (Int) -> Void) {
            _ = work(0)
            let start = DispatchTime.now().uptimeNanoseconds
            for i in 1...iterations { work(i) }
            let avg = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations) / 1_000_000
            print("TIMING \(label.padding(toLength: 28, withPad: " ", startingAt: 0)) \(String(format: "%8.3f", avg)) ms/call")
        }

        time("full render (2 screens)") { i in
            _ = MK2PaulincheInstrumentRenderer.render(scene(value: i), renderer: renderer)
        }
        time("full render + shift layer") { i in
            var shifted = scene(value: i)
            shifted.softKeys = [
                MK2PaulincheSoftKey(label: "", isEnabled: false),
                MK2PaulincheSoftKey(label: "", isEnabled: false),
                MK2PaulincheSoftKey(label: "", isEnabled: false),
                MK2PaulincheSoftKey(label: "", isEnabled: false),
                MK2PaulincheSoftKey(label: "Cut"),
                MK2PaulincheSoftKey(label: "Crop"),
                MK2PaulincheSoftKey(label: "Fade"),
                MK2PaulincheSoftKey(label: "Norm"),
            ]
            shifted.shiftSoftKeys = [
                MK2PaulincheSoftKey(label: "", isEnabled: false),
                MK2PaulincheSoftKey(label: "", isEnabled: false),
                MK2PaulincheSoftKey(label: "", isEnabled: false),
                MK2PaulincheSoftKey(label: "", isEnabled: false),
                MK2PaulincheSoftKey(label: "Reverse"),
                MK2PaulincheSoftKey(label: "", isEnabled: false),
                MK2PaulincheSoftKey(label: "", isEnabled: false),
                MK2PaulincheSoftKey(label: "DC Fix"),
            ]
            _ = MK2PaulincheInstrumentRenderer.render(shifted, renderer: renderer)
        }
        time("full render, no freetype") { i in
            _ = MK2PaulincheInstrumentRenderer.render(scene(value: i), renderer: nil)
        }
        time("waveform widget only") { i in
            var frame = MK2PixelFrame()
            MK2WaveformDisplay(
                envelope: envelope,
                rect: MK2PixelRect(x: 8, y: 32, width: 464, height: 174),
                region: 0.1...0.9,
                markers: [Double(i % 400) / 400.0]
            ).draw(into: &frame)
        }
        time("frame alloc pair") { _ in
            var a = MK2PixelFrame(fill: 0x0841)
            var b = MK2PixelFrame(fill: 0x0841)
            a.fill(MK2PixelRect(x: 0, y: 0, width: 1, height: 1), 0)
            b.fill(MK2PixelRect(x: 0, y: 0, width: 1, height: 1), 0)
        }
        time("parameter page x2") { i in
            var frame = MK2PixelFrame()
            var result = MK2ScreenBuildResult(screen: .fullScreen(frame))
            let context = MK2ScreenContext(renderer: renderer)
            for _ in 0..<2 {
                MK2ParameterPageElement(
                    slots: [
                        MK2ParameterPageSlot(label: "LOOP ST", value: "\(821 + i)"),
                        MK2ParameterPageSlot(label: "LOOP END", value: "9864"),
                        MK2ParameterPageSlot(label: "START", value: "\(2_551 + i)"),
                        MK2ParameterPageSlot(label: "END", value: "9577"),
                    ],
                    rect: MK2PixelRect(x: 8, y: 215, width: 464, height: 57),
                    columns: 4,
                    relativeToContent: false
                ).apply(to: &frame, context: context, result: &result)
            }
        }
    }
}
