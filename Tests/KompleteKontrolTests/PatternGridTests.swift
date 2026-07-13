import Foundation
import Testing
@testable import KontrolSurfaceKit2

@Suite("Pattern grid element")
struct PatternGridTests {
    private static let page: UInt16 = 0x0841
    private static let colors = MK2PatternGridColors()

    private static func windowRows(count: Int = MK2PatternGridElement.visibleRowCount, cell: (Int) -> MK2PatternGridElement.Cell = { _ in .init() }) -> [MK2PatternGridElement.Row] {
        (0..<count).map { index in
            MK2PatternGridElement.Row(index: index, cells: (0..<4).map { _ in cell(index) })
        }
    }

    private static func channels(focused: Int? = nil, muted: Set<Int> = [], soloed: Set<Int> = []) -> [MK2PatternGridElement.Channel] {
        (0..<4).map { index in
            MK2PatternGridElement.Channel(
                label: "CHANNEL \(index + 1)",
                isMuted: muted.contains(index),
                isSoloed: soloed.contains(index),
                isFocused: focused == index
            )
        }
    }

    private static func render(_ element: MK2PatternGridElement) -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: page)
        var result = MK2ScreenBuildResult(screen: .fullScreen(frame))
        element.apply(to: &frame, context: MK2ScreenContext(), result: &result)
        return frame
    }

    private static func rowRect(visibleIndex: Int) -> MK2PixelRect {
        MK2PixelRect(x: 0, y: MK2PatternGridElement.gridTop + visibleIndex * MK2PatternGridElement.rowHeight, width: MK2PixelFrame.width, height: MK2PatternGridElement.rowHeight)
    }

    @Test("Playhead row fills with the cursor tone while stopped, the playhead tone while playing")
    func playheadFill() {
        let stopped = Self.render(MK2PatternGridElement(rows: Self.windowRows(), channels: Self.channels(), selectedRowIndex: 5, isPlaying: false, beatStripe: .none))
        #expect(stopped.countPixels(in: Self.rowRect(visibleIndex: 5), matching: Self.colors.cursorFill) > 3_000)

        let playing = Self.render(MK2PatternGridElement(rows: Self.windowRows(), channels: Self.channels(), selectedRowIndex: 5, isPlaying: true, beatStripe: .none))
        #expect(playing.countPixels(in: Self.rowRect(visibleIndex: 5), matching: Self.colors.playheadFill) > 3_000)
        #expect(playing.countPixels(in: Self.rowRect(visibleIndex: 5), matching: Self.colors.cursorFill) == 0)
    }

    @Test("The beat stripe interval is configurable: 4/4 stripes every fourth row, 3/4 every third")
    func configurableBeatInterval() {
        // Selected row 1 keeps the playhead off the beat rows under test.
        let four = Self.render(MK2PatternGridElement(rows: Self.windowRows(), channels: Self.channels(), selectedRowIndex: 1, beatStripe: .every(4)))
        // Row index 4 (visible slot 4) is a 4/4 beat; row 3 is not.
        #expect(four.countPixels(in: Self.rowRect(visibleIndex: 4), matching: Self.colors.beatStripe) > 3_000)
        #expect(four.countPixels(in: Self.rowRect(visibleIndex: 3), matching: Self.colors.beatStripe) == 0)

        let three = Self.render(MK2PatternGridElement(rows: Self.windowRows(), channels: Self.channels(), selectedRowIndex: 1, beatStripe: .every(3)))
        // Row index 3 (visible slot 3) is a 3/4 beat; row 4 is not.
        #expect(three.countPixels(in: Self.rowRect(visibleIndex: 3), matching: Self.colors.beatStripe) > 3_000)
        #expect(three.countPixels(in: Self.rowRect(visibleIndex: 4), matching: Self.colors.beatStripe) == 0)
    }

    @Test("A none stripe leaves every non-playhead row on the page background")
    func noneStripe() {
        let frame = Self.render(MK2PatternGridElement(rows: Self.windowRows(), channels: Self.channels(), selectedRowIndex: 6, beatStripe: .none))
        #expect(frame.countPixels(in: Self.rowRect(visibleIndex: 4), matching: Self.colors.beatStripe) == 0)
        #expect(frame.countPixels(in: Self.rowRect(visibleIndex: 0), matching: Self.colors.beatStripe) == 0)
    }

    private static func region(_ frame: MK2PixelFrame, x: Int, y: Int, width: Int) -> [UInt16] {
        var pixels: [UInt16] = []
        for row in y..<(y + MK2PatternGridElement.rowHeight) {
            for column in x..<(x + width) { pixels.append(frame[column, row]) }
        }
        return pixels
    }

    @Test("Cells colour each field independently: an empty field never borrows a populated neighbour's ink")
    func perFieldCellColoring() {
        // A cell carrying only a note. Under whole-cell colouring its instrument
        // placeholder would light up with the note; per-field colouring keeps the
        // instrument field byte-identical to a fully empty cell.
        let noteOnly = Self.render(MK2PatternGridElement(
            rows: Self.windowRows { $0 == 2 ? MK2PatternGridElement.Cell(note: "C-4") : MK2PatternGridElement.Cell() },
            channels: Self.channels(), selectedRowIndex: 6, beatStripe: .none))
        let allEmpty = Self.render(MK2PatternGridElement(
            rows: Self.windowRows(), channels: Self.channels(), selectedRowIndex: 6, beatStripe: .none))
        let y = MK2PatternGridElement.gridTop + 2 * MK2PatternGridElement.rowHeight
        // The note field differs — one is lit, the other empty…
        #expect(Self.region(noteOnly, x: 48, y: y, width: 30) != Self.region(allEmpty, x: 48, y: y, width: 30))
        // …but the instrument field is identical: it ignores the note entirely.
        #expect(Self.region(noteOnly, x: 86, y: y, width: 30) == Self.region(allEmpty, x: 86, y: y, width: 30))
    }

    @Test("The focused channel shades its column and tints its header label")
    func focusedChannelHighlight() {
        let frame = Self.render(MK2PatternGridElement(rows: Self.windowRows(), channels: Self.channels(focused: 2), selectedRowIndex: 6, beatStripe: .none))
        // Channel 3 column (x 258) is shaded on a non-playhead row.
        let y = MK2PatternGridElement.gridTop + 2 * MK2PatternGridElement.rowHeight
        #expect(frame.countPixels(in: MK2PixelRect(x: 254, y: y, width: 92, height: MK2PatternGridElement.rowHeight), matching: Self.colors.focusedChannelFill) > 200)
    }

    @Test("Mute and solo chips render in their accent fills")
    func muteSoloChips() {
        let frame = Self.render(MK2PatternGridElement(rows: Self.windowRows(), channels: Self.channels(muted: [2], soloed: [3]), selectedRowIndex: 6, beatStripe: .none))
        // Channel 3 mute chip at ruler x 246 + 69, channel 4 solo chip at 351 + 87.
        #expect(frame.countPixels(in: MK2PixelRect(x: 246 + 69, y: MK2PatternGridElement.toggleY, width: 14, height: 16), matching: Self.colors.muteAccent) > 40)
        #expect(frame.countPixels(in: MK2PixelRect(x: 351 + 87, y: MK2PatternGridElement.toggleY, width: 14, height: 16), matching: Self.colors.soloAccent) > 40)
    }
}

@Suite("Overview scrollbar element")
struct OverviewScrollbarTests {
    private static let colors = MK2OverviewScrollbarColors()

    private static func render(_ element: MK2OverviewScrollbarElement) -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: 0x0000)
        var result = MK2ScreenBuildResult(screen: .fullScreen(frame))
        element.apply(to: &frame, context: MK2ScreenContext(), result: &result)
        return frame
    }

    @Test("The playhead marker is wider and lit; active rows read brighter than empty ones")
    func markers() {
        let activity = (0..<64).map { $0 == 16 }
        let frame = Self.render(MK2OverviewScrollbarElement(
            rowCount: 64,
            selectedRowIndex: 0,
            rowActivity: activity,
            rect: MK2PixelRect(x: 466, y: 62, width: 5, height: 200)
        ))
        // Playhead at row 0 → markerY 62, width 9 in the playhead tone.
        #expect(frame.countPixels(in: MK2PixelRect(x: 466, y: 62, width: 9, height: 1), matching: Self.colors.playhead) == 9)
        // The active row 16 maps into the track and reads in the active tone.
        let activeY = 62 + Int((16.0 / 63.0 * 199.0).rounded())
        #expect(frame.countPixels(in: MK2PixelRect(x: 466, y: activeY, width: 5, height: 1), matching: Self.colors.active) == 5)
        // The track fill shows through on an empty, non-marker sliver.
        #expect(frame.countPixels(in: MK2PixelRect(x: 466, y: 62, width: 5, height: 200), matching: Self.colors.track) > 100)
    }

    @Test("A degenerate row count draws nothing")
    func emptyGuard() {
        let frame = Self.render(MK2OverviewScrollbarElement(
            rowCount: 1,
            selectedRowIndex: 0,
            rowActivity: [true],
            rect: MK2PixelRect(x: 466, y: 62, width: 5, height: 200)
        ))
        #expect(frame.countPixels(in: MK2PixelRect(x: 466, y: 62, width: 9, height: 200), matching: 0x0000) == 9 * 200)
    }
}

private extension MK2PixelFrame {
    func countPixels(in rect: MK2PixelRect, matching color: UInt16) -> Int {
        guard let clipped = rect.clipped(to: MK2PixelFrame.bounds) else { return 0 }
        var count = 0
        for y in clipped.y..<clipped.maxY {
            for x in clipped.x..<clipped.maxX where self[x, y] == color {
                count += 1
            }
        }
        return count
    }
}
