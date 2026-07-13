import Foundation
import Testing
@testable import KontrolSurfaceKit2

@Suite("Scene preview element")
struct ScenePreviewTests {
    private static let colors = MK2ScenePreviewColors()
    private static let rect = MK2PixelRect(x: 300, y: 60, width: 160, height: 120)

    private static func render(_ element: MK2ScenePreviewElement) -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: 0x0000)
        var result = MK2ScreenBuildResult(screen: .fullScreen(frame))
        element.apply(to: &frame, context: MK2ScreenContext(), result: &result)
        return frame
    }

    @Test("An empty pattern draws the framed panel and nothing inside")
    func emptyPanel() {
        let frame = Self.render(MK2ScenePreviewElement(rowCount: 64, channelCount: 4, markers: [], beatInterval: 1_000, rect: Self.rect))
        // The border tone frames the panel…
        #expect(frame.countPixels(in: Self.rect, matching: Self.colors.border) > 0)
        // …and with beats suppressed (interval past the row count) no markers exist.
        #expect(frame.countPixels(in: Self.rect, matching: Self.colors.marker) == 0)
    }

    @Test("Filled cells become marks; the play row and beats draw as lines")
    func marksAndLines() {
        let markers = [
            MK2ScenePreviewElement.Marker(row: 0, channel: 0),
            MK2ScenePreviewElement.Marker(row: 63, channel: 3),
        ]
        let frame = Self.render(MK2ScenePreviewElement(
            rowCount: 64, channelCount: 4, markers: markers, beatInterval: 4, playheadRow: 32, rect: Self.rect
        ))
        #expect(frame.countPixels(in: Self.rect, matching: Self.colors.marker) >= 2)
        #expect(frame.countPixels(in: Self.rect, matching: Self.colors.beat) > 0)
        #expect(frame.countPixels(in: Self.rect, matching: Self.colors.playhead) > 0)
        // The first marker sits near the top-left of the inner panel, the last near
        // the bottom — proving rows map top-to-bottom and channels left-to-right.
        let topLeft = MK2PixelRect(x: Self.rect.x, y: Self.rect.y, width: 60, height: 20)
        let bottomRight = MK2PixelRect(x: Self.rect.maxX - 60, y: Self.rect.maxY - 20, width: 60, height: 20)
        #expect(frame.countPixels(in: topLeft, matching: Self.colors.marker) > 0)
        #expect(frame.countPixels(in: bottomRight, matching: Self.colors.marker) > 0)
    }

    @Test("Out-of-range markers are dropped, not drawn or crashing")
    func outOfRangeMarkers() {
        let markers = [
            MK2ScenePreviewElement.Marker(row: 999, channel: 0),
            MK2ScenePreviewElement.Marker(row: 0, channel: 99),
        ]
        let frame = Self.render(MK2ScenePreviewElement(rowCount: 64, channelCount: 4, markers: markers, beatInterval: 1_000, rect: Self.rect))
        #expect(frame.countPixels(in: Self.rect, matching: Self.colors.marker) == 0)
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
