import Foundation
import Testing
@testable import KontrolSurfaceKit2

@Suite("Music widgets")
struct MusicWidgetsTests {
    @Test("Marquee pauses, scrolls and clips to its viewport")
    func marquee() {
        let rect = MK2PixelRect(x: 20, y: 20, width: 30, height: 12)
        var label = MK2Marquee("A LONG INSTRUMENT NAME", rect: rect, elapsed: 0)
        #expect(label.offset == 0)
        label.elapsed = 2
        #expect(label.offset > 0)
        var frame = MK2PixelFrame()
        label.draw(into: &frame)
        for y in 0..<MK2PixelFrame.height {
            for x in 0..<MK2PixelFrame.width where x < rect.x || x >= rect.maxX || y < rect.y || y >= rect.maxY {
                #expect(frame[x, y] == 0)
            }
        }
    }
    @Test("Pad one appears at bottom left and selection is visible")
    func padOrder() {
        var frame = MK2PixelFrame()
        MK2PadMatrix(pads: [.init("1", occupied: true, selected: true)], rect: .init(x: 10, y: 10, width: 200, height: 200)).draw(into: &frame)
        #expect(frame[10, 160] == 0xffff)
        #expect(frame[10, 10] == 0)
    }
    @Test("Additional waveform regions render alongside selected region")
    func waveformSlices() {
        var frame = MK2PixelFrame()
        let colors = MK2WaveformDisplay.Colors()
        MK2WaveformDisplay(envelope: .init(minima: [], maxima: []), rect: .init(x: 0, y: 0, width: 200, height: 100), region: 0.5...0.7, additionalRegions: [0.1...0.3]).draw(into: &frame)
        #expect(frame[40, 10] == colors.regionFill)
        #expect(frame[120, 10] == colors.regionFill)
        #expect(frame[85, 10] == colors.background)
    }
    @Test("Curve and mixer widgets can be captured together")
    func snapshot() throws {
        var left = MK2PixelFrame(), right = MK2PixelFrame()
        MK2CurvePlot(points: [.init(0, 0), .init(0.3, 1), .init(1, 0.4)], rect: .init(x: 10, y: 10, width: 400, height: 160)).draw(into: &left)
        MK2MixerStrip(label: "CH 1", rect: .init(x: 10, y: 10, width: 100, height: 180), levels: [0.3, 0.7], peaks: [0.5, 0.8], gain: 0.6, selected: true).draw(into: &right)
        let png = PixelSnapshot.pngData(frames: [left, right])
        #expect(png.starts(with: [137, 80, 78, 71]))
        #expect(left[10, 169] == 0x07ff)
        #expect(right[10, 10] == 0xffff)
    }
}
