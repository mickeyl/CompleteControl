import Foundation

/// A precomputed min/max amplitude envelope, the render-ready form of a
/// waveform. Producers reduce their raw sample frames once (typically far
/// away from the render path) and hand the display a few hundred bins; the
/// widget never touches raw audio.
public struct MK2WaveformEnvelope: Sendable, Equatable {
    /// Per-bin minimum amplitude, nominally in -1…1.
    public var minima: [Float]
    /// Per-bin maximum amplitude, paired with `minima`.
    public var maxima: [Float]
    /// Display gain applied on top of the amplitudes (quiet material can be
    /// boosted by the producer without re-reducing the envelope).
    public var gain: Double

    public init(minima: [Float], maxima: [Float], gain: Double = 1) {
        let count = min(minima.count, maxima.count)
        self.minima = Array(minima.prefix(count))
        self.maxima = Array(maxima.prefix(count))
        self.gain = gain.isFinite ? max(0, gain) : 1
    }

    public var isEmpty: Bool { maxima.isEmpty }
}

/// Draws a sample waveform from a min/max envelope, sized for the MK2 OLEDs:
/// one column pass over the target rect inside an antialiased rounded panel,
/// integer fills only, no text and no
/// allocation in the draw loop. Bins are merged (envelope wider than the
/// rect) or replicated (envelope narrower) so any envelope resolution maps
/// onto any pixel width without aliasing artifacts.
///
/// An optional highlight region (loop), position markers (start offset) and
/// a playhead are drawn as fraction positions in 0…1 of the full envelope.
public struct MK2WaveformDisplay: Sendable {
    public struct Colors: Sendable {
        public var background: UInt16
        public var border: UInt16
        public var centerLine: UInt16
        public var wave: UInt16
        public var waveOutsideRegion: UInt16
        public var regionFill: UInt16
        public var regionEdge: UInt16
        public var marker: UInt16
        public var playhead: UInt16

        public init(
            background: UInt16 = MK2HIG.Waveform.background,
            border: UInt16 = MK2HIG.Waveform.border,
            centerLine: UInt16 = MK2HIG.Waveform.centerLine,
            wave: UInt16 = MK2HIG.Waveform.trace,
            waveOutsideRegion: UInt16 = MK2HIG.Waveform.traceOutsideRegion,
            regionFill: UInt16 = MK2HIG.Waveform.regionFill,
            regionEdge: UInt16 = MK2HIG.Waveform.regionEdge,
            marker: UInt16 = MK2HIG.Waveform.marker,
            playhead: UInt16 = MK2HIG.Waveform.playhead
        ) {
            self.background = background
            self.border = border
            self.centerLine = centerLine
            self.wave = wave
            self.waveOutsideRegion = waveOutsideRegion
            self.regionFill = regionFill
            self.regionEdge = regionEdge
            self.marker = marker
            self.playhead = playhead
        }
    }

    public var envelope: MK2WaveformEnvelope
    public var rect: MK2PixelRect
    /// Highlighted fraction range (e.g. the sample loop). Waveform columns
    /// inside keep the primary wave color, columns outside dim.
    public var region: ClosedRange<Double>?
    /// Vertical marker lines at fraction positions (e.g. the start offset).
    public var markers: [Double]
    /// Additional slice ranges; the primary `region` remains the selected range.
    public var additionalRegions: [ClosedRange<Double>]
    /// Playhead line at a fraction position.
    public var playhead: Double?
    public var cornerRadius: Int
    public var colors: Colors

    public init(
        envelope: MK2WaveformEnvelope,
        rect: MK2PixelRect,
        region: ClosedRange<Double>? = nil,
        markers: [Double] = [],
        additionalRegions: [ClosedRange<Double>] = [],
        playhead: Double? = nil,
        cornerRadius: Int = MK2HIG.Waveform.cornerRadius,
        colors: Colors = Colors()
    ) {
        self.envelope = envelope
        self.rect = rect
        self.region = region.map { Self.clamped01($0.lowerBound)...Self.clamped01(max($0.lowerBound, $0.upperBound)) }
        self.markers = markers.map(Self.clamped01)
        self.additionalRegions = additionalRegions.map { Self.clamped01($0.lowerBound)...Self.clamped01(max($0.lowerBound, $0.upperBound)) }
        self.playhead = playhead.map(Self.clamped01)
        self.cornerRadius = max(0, cornerRadius)
        self.colors = colors
    }

    public func draw(into frame: inout MK2PixelFrame) {
        guard !rect.isEmpty else { return }
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        frame.fillRounded(rect, radius: radius, colors.border, antialiased: true)
        let panel = MK2PixelRect(x: rect.x + 1, y: rect.y + 1, width: rect.width - 2, height: rect.height - 2)
        guard !panel.isEmpty else { return }
        frame.fillRounded(panel, radius: max(0, radius - 1), colors.background, antialiased: true)

        let inner = MK2PixelRect(x: rect.x + 2, y: rect.y + 2, width: rect.width - 4, height: rect.height - 4)
        guard !inner.isEmpty else { return }

        for slice in additionalRegions {
            let columns = columnRange(for: slice, width: inner.width)
            frame.fill(MK2PixelRect(x: inner.x + columns.lowerBound, y: inner.y, width: columns.count, height: inner.height), colors.regionFill)
        }
        let regionColumns = region.map { columnRange(for: $0, width: inner.width) }
        if let regionColumns {
            frame.fill(
                MK2PixelRect(
                    x: inner.x + regionColumns.lowerBound,
                    y: inner.y,
                    width: max(1, regionColumns.count),
                    height: inner.height
                ),
                colors.regionFill
            )
        }

        drawEnvelope(into: &frame, inner: inner, regionColumns: regionColumns)

        if let regionColumns {
            frame.fill(MK2PixelRect(x: inner.x + regionColumns.lowerBound, y: inner.y, width: 1, height: inner.height), colors.regionEdge)
            frame.fill(MK2PixelRect(x: inner.x + min(inner.width - 1, regionColumns.upperBound), y: inner.y, width: 1, height: inner.height), colors.regionEdge)
        }
        for slice in additionalRegions {
            let columns = columnRange(for: slice, width: inner.width)
            frame.fill(MK2PixelRect(x: inner.x + columns.lowerBound, y: inner.y, width: 1, height: inner.height), colors.regionEdge)
            frame.fill(MK2PixelRect(x: inner.x + min(inner.width - 1, columns.upperBound), y: inner.y, width: 1, height: inner.height), colors.regionEdge)
        }
        for marker in markers {
            let x = inner.x + column(for: marker, width: inner.width)
            frame.fill(MK2PixelRect(x: x, y: inner.y, width: 1, height: inner.height), colors.marker)
        }
        if let playhead {
            let x = inner.x + column(for: playhead, width: inner.width)
            frame.fill(MK2PixelRect(x: min(x, inner.maxX - 2), y: inner.y, width: 2, height: inner.height), colors.playhead)
        }
    }

    private func drawEnvelope(into frame: inout MK2PixelFrame, inner: MK2PixelRect, regionColumns: Range<Int>?) {
        let midY = inner.y + inner.height / 2
        frame.fill(MK2PixelRect(x: inner.x, y: midY, width: inner.width, height: 1), colors.centerLine)

        let bins = envelope.maxima.count
        guard bins > 0, inner.height > 2 else { return }
        let halfSpan = Double(inner.height - 2) / 2
        let gain = envelope.gain

        for columnOffset in 0..<inner.width {
            var binStart = columnOffset * bins / inner.width
            var binEnd = (columnOffset + 1) * bins / inner.width
            binStart = min(binStart, bins - 1)
            binEnd = max(binStart + 1, min(binEnd, bins))

            var low = envelope.minima[binStart]
            var high = envelope.maxima[binStart]
            var bin = binStart + 1
            while bin < binEnd {
                if envelope.minima[bin] < low { low = envelope.minima[bin] }
                if envelope.maxima[bin] > high { high = envelope.maxima[bin] }
                bin += 1
            }

            let scaledLow = max(-1, min(1, Double(low) * gain))
            let scaledHigh = max(-1, min(1, Double(high) * gain))
            let yTop = midY - Int((scaledHigh * halfSpan).rounded())
            let yBottom = midY - Int((scaledLow * halfSpan).rounded())
            let inRegion = regionColumns?.contains(columnOffset) ?? true
            frame.fill(
                MK2PixelRect(x: inner.x + columnOffset, y: yTop, width: 1, height: max(1, yBottom - yTop + 1)),
                inRegion ? colors.wave : colors.waveOutsideRegion
            )
        }
    }

    private func column(for fraction: Double, width: Int) -> Int {
        min(width - 1, max(0, Int((fraction * Double(width - 1)).rounded())))
    }

    private func columnRange(for region: ClosedRange<Double>, width: Int) -> Range<Int> {
        let start = column(for: region.lowerBound, width: width)
        let end = column(for: region.upperBound, width: width)
        return start..<max(start + 1, end + 1)
    }

    private static func clamped01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
