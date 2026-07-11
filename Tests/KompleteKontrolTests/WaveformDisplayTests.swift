import Foundation
import Testing
@testable import KontrolSurfaceKit2

@Suite("Waveform display widget")
struct WaveformDisplayTests {
    private static let rect = MK2PixelRect(x: 10, y: 10, width: 200, height: 100)

    @Test("Envelope columns merge bins wider than the rect")
    func mergesWideEnvelopes() {
        // 2048 bins into 196 columns: every column must keep the min/max extremes.
        let bins = 2_048
        let minima = [Float](repeating: -0.5, count: bins)
        var maxima = [Float](repeating: 0.5, count: bins)
        maxima[bins / 2] = 1.0
        var frame = MK2PixelFrame()
        MK2WaveformDisplay(
            envelope: MK2WaveformEnvelope(minima: minima, maxima: maxima),
            rect: Self.rect
        ).draw(into: &frame)

        let colors = MK2WaveformDisplay.Colors()
        // Uniform ±0.5 amplitude paints roughly half the inner height everywhere.
        let waveCount = count(in: frame, rect: Self.rect, color: colors.wave)
        #expect(waveCount > 196 * 40)
        // The lone full-scale bin must survive the merge: its column reaches the top row.
        #expect(frame[10 + 2 + (bins / 2) * 196 / bins, 10 + 2 + 1] == colors.wave)
    }

    @Test("Envelopes narrower than the rect replicate bins without gaps")
    func replicatesNarrowEnvelopes() {
        let envelope = MK2WaveformEnvelope(minima: [Float](repeating: -1, count: 8), maxima: [Float](repeating: 1, count: 8))
        var frame = MK2PixelFrame()
        MK2WaveformDisplay(envelope: envelope, rect: Self.rect).draw(into: &frame)

        let colors = MK2WaveformDisplay.Colors()
        let innerWidth = Self.rect.width - 4
        let midY = Self.rect.y + 2 + (Self.rect.height - 4) / 2
        let rowCount = count(in: frame, rect: MK2PixelRect(x: Self.rect.x + 2, y: midY, width: innerWidth, height: 1), color: colors.wave)
        #expect(rowCount == innerWidth)
    }

    @Test("Region, markers and playhead draw at their fraction positions")
    func drawsRegionMarkersAndPlayhead() {
        let envelope = MK2WaveformEnvelope(minima: [Float](repeating: -0.4, count: 64), maxima: [Float](repeating: 0.4, count: 64))
        var frame = MK2PixelFrame()
        let colors = MK2WaveformDisplay.Colors()
        MK2WaveformDisplay(
            envelope: envelope,
            rect: Self.rect,
            region: 0.25...0.75,
            markers: [0.1],
            playhead: 0.5,
            colors: colors
        ).draw(into: &frame)

        let inner = MK2PixelRect(x: Self.rect.x + 2, y: Self.rect.y + 2, width: Self.rect.width - 4, height: Self.rect.height - 4)
        // Wave columns outside the region use the dimmed color, inside the primary one.
        #expect(frame[inner.x + 4, inner.y + inner.height / 2 - 10] == colors.waveOutsideRegion)
        #expect(frame[inner.x + inner.width / 2 - 8, inner.y + inner.height / 2 - 10] == colors.wave)
        // Marker and playhead lines span the full inner height at their positions.
        let markerX = inner.x + Int((0.1 * Double(inner.width - 1)).rounded())
        #expect(frame[markerX, inner.y] == colors.marker)
        let playheadX = inner.x + Int((0.5 * Double(inner.width - 1)).rounded())
        #expect(frame[playheadX, inner.y] == colors.playhead)
        // Region fill shows above the wave inside the region only (probe clear of the playhead).
        #expect(frame[inner.x + inner.width * 3 / 8, inner.y + 2] == colors.regionFill)
        #expect(frame[inner.x + 4, inner.y + 2] == colors.background)
    }

    @Test("Empty envelopes draw only the chrome")
    func emptyEnvelopeDrawsChrome() {
        var frame = MK2PixelFrame()
        MK2WaveformDisplay(envelope: MK2WaveformEnvelope(minima: [], maxima: []), rect: Self.rect).draw(into: &frame)
        let colors = MK2WaveformDisplay.Colors()
        #expect(count(in: frame, rect: Self.rect, color: colors.wave) == 0)
        // Probe the border on the top edge center — the corners are rounded now.
        #expect(frame[Self.rect.x + Self.rect.width / 2, Self.rect.y] == colors.border)
    }

    private func count(in frame: MK2PixelFrame, rect: MK2PixelRect, color: UInt16) -> Int {
        guard let clipped = rect.clipped(to: MK2PixelFrame.bounds) else { return 0 }
        var count = 0
        for y in clipped.y..<clipped.maxY {
            for x in clipped.x..<clipped.maxX where frame[x, y] == color {
                count += 1
            }
        }
        return count
    }
}
