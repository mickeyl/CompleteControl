import Foundation

/// A thumbnail of a pattern for the arrangement detail pane: the pattern reduced
/// to a downscaled occupancy map — one small mark per filled cell, faint beat
/// stripes, and the play/cursor row. At thumbnail scale the actual glyphs are
/// illegible, so the preview shows the *shape* of the pattern (where the notes
/// sit across channels and rows) rather than its text.
///
/// The client passes the filled cells sparsely (`Marker(row:channel:)`); an empty
/// pattern draws just the framed panel.
public struct MK2ScenePreviewElement: MK2ScreenElement {
    public struct Marker: Sendable, Equatable {
        public var row: Int
        public var channel: Int
        public init(row: Int, channel: Int) {
            self.row = row
            self.channel = channel
        }
    }

    public var rowCount: Int
    public var channelCount: Int
    public var markers: [Marker]
    public var beatInterval: Int
    public var playheadRow: Int?
    public var rect: MK2PixelRect
    public var colors: MK2ScenePreviewColors

    public init(
        rowCount: Int,
        channelCount: Int,
        markers: [Marker],
        beatInterval: Int = 4,
        playheadRow: Int? = nil,
        rect: MK2PixelRect,
        colors: MK2ScenePreviewColors = MK2ScenePreviewColors()
    ) {
        self.rowCount = max(1, rowCount)
        self.channelCount = max(1, channelCount)
        self.markers = markers
        self.beatInterval = max(1, beatInterval)
        self.playheadRow = playheadRow
        self.rect = rect
        self.colors = colors
    }

    private static let padding = 2

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        guard rect.width > 2 * Self.padding + 1, rect.height > 2 * Self.padding + 1 else { return }
        frame.drawRoundedPanel(rect, fill: colors.background, border: colors.border, radius: 4)

        let inner = rect.insetBy(dx: Self.padding, dy: Self.padding)
        let columnWidth = max(1, inner.width / channelCount)
        let markerWidth = max(1, columnWidth - 1)

        // Faint beat stripes give the eye a bar grid to read density against.
        for row in stride(from: 0, to: rowCount, by: beatInterval) {
            let y = rowY(row, in: inner)
            frame.hline(y: y, x: inner.x, width: inner.width, color: colors.beat)
        }

        if let playheadRow, (0..<rowCount).contains(playheadRow) {
            frame.hline(y: rowY(playheadRow, in: inner), x: inner.x, width: inner.width, color: colors.playhead)
        }

        for marker in markers {
            guard (0..<rowCount).contains(marker.row), (0..<channelCount).contains(marker.channel) else { continue }
            let x = inner.x + marker.channel * columnWidth
            frame.fill(MK2PixelRect(x: x, y: rowY(marker.row, in: inner), width: markerWidth, height: 1), colors.marker)
        }
    }

    private func rowY(_ row: Int, in inner: MK2PixelRect) -> Int {
        guard rowCount > 1 else { return inner.y }
        return inner.y + Int((Double(row) / Double(rowCount - 1) * Double(inner.height - 1)).rounded())
    }
}

/// The scene-preview palette, defaulting to the hardware-approved tracker tones.
public struct MK2ScenePreviewColors: Sendable, Equatable {
    public var background: UInt16
    public var border: UInt16
    public var beat: UInt16
    public var marker: UInt16
    public var playhead: UInt16

    public init(
        background: UInt16 = MK2HIG.Chrome.background,
        border: UInt16 = MK2HIG.Chrome.border,
        beat: UInt16 = 0x1083,
        marker: UInt16 = 0x95f2,
        playhead: UInt16 = 0x464f
    ) {
        self.background = background
        self.border = border
        self.beat = beat
        self.marker = marker
        self.playhead = playhead
    }
}
