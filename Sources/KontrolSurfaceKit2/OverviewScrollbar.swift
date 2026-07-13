import Foundation

/// The pattern minimap: a slim vertical track with one 1 px marker per row,
/// the playhead marker widened and lit, active rows brighter than the empty
/// ruler. It is the whole-song overview alongside the windowed grid, shared by
/// Paulinche's live renderer and the widget lab's Tracker demo.
///
/// `rowActivity` runs the full length of the song (one flag per row); the
/// client derives it however it tracks non-empty rows. Row positions map the
/// row range onto the track height, so the marker density scales with the song
/// length rather than the visible window.
public struct MK2OverviewScrollbarElement: MK2ScreenElement {
    public var rowCount: Int
    public var selectedRowIndex: Int
    public var rowActivity: [Bool]
    public var rect: MK2PixelRect
    public var colors: MK2OverviewScrollbarColors

    public init(
        rowCount: Int,
        selectedRowIndex: Int,
        rowActivity: [Bool],
        rect: MK2PixelRect,
        colors: MK2OverviewScrollbarColors = MK2OverviewScrollbarColors()
    ) {
        self.rowCount = max(0, rowCount)
        self.selectedRowIndex = max(0, selectedRowIndex)
        self.rowActivity = rowActivity
        self.rect = rect
        self.colors = colors
    }

    public func apply(to frame: inout MK2PixelFrame, context: MK2ScreenContext, result: inout MK2ScreenBuildResult) {
        guard rowCount > 1, rect.height > 1 else { return }
        frame.fill(MK2PixelRect(x: rect.x, y: rect.y, width: 5, height: rect.height), colors.track)
        for row in 0..<rowCount {
            let markerY = rect.y + Int((Double(row) / Double(rowCount - 1) * Double(rect.height - 1)).rounded())
            let isPlayhead = row == selectedRowIndex
            let active = rowActivity.indices.contains(row) && rowActivity[row]
            let color = isPlayhead ? colors.playhead : (active ? colors.active : colors.inactive)
            frame.fill(MK2PixelRect(x: rect.x, y: markerY, width: isPlayhead ? 9 : 5, height: 1), color)
        }
    }
}

/// The overview minimap palette, defaulting to the hardware-approved tracker
/// tones (signed off 2026-07-13).
public struct MK2OverviewScrollbarColors: Sendable, Equatable {
    public var track: UInt16
    public var playhead: UInt16
    public var active: UInt16
    public var inactive: UInt16

    public init(
        track: UInt16 = 0x2126,
        playhead: UInt16 = 0x464f,
        active: UInt16 = 0x7dbf,
        inactive: UInt16 = 0x632e
    ) {
        self.track = track
        self.playhead = playhead
        self.active = active
        self.inactive = inactive
    }
}
