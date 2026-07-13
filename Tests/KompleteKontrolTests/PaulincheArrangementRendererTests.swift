import Foundation
import KompleteKontrol
import PaulincheSurfaceKit
import Testing
@testable import KontrolSurfaceKit2

@Suite("Paulinche arrangement renderer")
struct PaulincheArrangementRendererTests {
    private static let background: UInt16 = 0x0841

    @Test("Arrangement renders order list left, order detail right")
    func rendersTwoScreens() {
        let rendered = MK2PaulincheArrangementRenderer.render(Self.fixture())
        #expect(rendered.left.screen.kind == .fullScreen)
        #expect(rendered.right.screen.kind == .fullScreen)

        // The order list fills the left screen with text above the background.
        let list = rendered.left.screen.frame
        #expect(list.countPixels(in: MK2PixelRect(x: 0, y: 40, width: 480, height: 200), notMatching: Self.background) > 200)

        // The right screen shows the preview panel and the parameter page.
        let detail = rendered.right.screen.frame
        #expect(detail.countPixels(in: MK2PixelRect(x: 8, y: 66, width: 464, height: 140), notMatching: Self.background) > 100)
        #expect(detail.countPixels(in: MK2PixelRect(x: 8, y: 215, width: 464, height: 57), notMatching: Self.background) > 200)
    }

    @Test("Order-property encoders E5–E8 forward touch and rotation")
    func orderPropertyEncodersForward() {
        let recorder = ArrangementEncoderRecorder()
        let rendered = MK2PaulincheArrangementRenderer.surfaceScene(
            Self.fixture(),
            actions: MK2PaulincheArrangementActions(
                onEncoderTouch: { encoder, touched in recorder.appendTouch(encoder, touched) },
                onEncoderChange: { encoder, delta in recorder.appendChange(encoder, delta) }
            )
        )
        rendered.bindings.encoderTouch[5]?(true)
        rendered.bindings.encoder[6]?(3, 0, 0)

        #expect(recorder.touches == [5])
        #expect(recorder.changes.first?.0 == 6)
        #expect(recorder.changes.first?.1 == 3)
        // E1–E4 are the app's navigation axis, not the renderer's — left unbound here.
        #expect(rendered.bindings.encoder[4] == nil)
    }

    @Test("Arrangement screens can be captured as a two-screen snapshot")
    func snapshotSmoke() throws {
        let rendered = MK2PaulincheArrangementRenderer.render(Self.fixture(), renderer: try? FreeTypeTextRenderer())
        let png = PixelSnapshot.pngData(frames: [rendered.left.screen.frame, rendered.right.screen.frame])
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        if let dir = ProcessInfo.processInfo.environment["PAULINCHE_SNAPSHOT_DIR"] {
            try PixelSnapshot.write(
                [rendered.left.screen.frame, rendered.right.screen.frame],
                to: "\(dir)/paulinche-arrangement.png"
            )
        }
    }

    private static func fixture() -> MK2PaulincheArrangementScene {
        MK2PaulincheArrangementScene(
            title: "ARRANGEMENT",
            subtitle: "PAULINCHE",
            isPlaying: true,
            selectedOrderIndex: 1,
            orders: [
                MK2PaulincheArrangementOrder(patternLabel: "00 Intro", length: 64, repeatCount: 1),
                MK2PaulincheArrangementOrder(patternLabel: "01 Verse", length: 64, repeatCount: 2, isPlaying: true),
                MK2PaulincheArrangementOrder(patternLabel: "02 Chorus", length: 32, repeatCount: 1),
                MK2PaulincheArrangementOrder(patternLabel: "00 Intro", length: 64, repeatCount: 1),
            ],
            preview: MK2PaulincheArrangementPreview(
                rowCount: 64,
                channelCount: 4,
                markers: (0..<16).map { MK2ScenePreviewElement.Marker(row: $0 * 4, channel: $0 % 4) },
                beatInterval: 4,
                playheadRow: 12
            ),
            parameters: [
                MK2PaulinchePatternParameter(label: "PATTERN", value: "01"),
                MK2PaulinchePatternParameter(label: "REPEAT", value: "2", isFocused: true),
                MK2PaulinchePatternParameter(label: "LEN", value: "64"),
                MK2PaulinchePatternParameter(label: "POS", value: "01"),
            ],
            softKeys: [
                MK2PaulincheSoftKey(label: "Insert", commandID: "appendPattern"),
                MK2PaulincheSoftKey(label: "Dup", commandID: "duplicateCurrentPattern"),
                MK2PaulincheSoftKey(label: "Delete", commandID: "deleteCurrentOrder"),
            ]
        )
    }
}

private final class ArrangementEncoderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var touches: [Int] = []
    private(set) var changes: [(Int, Int)] = []

    func appendTouch(_ encoder: Int, _ touched: Bool) {
        lock.lock(); if touched { touches.append(encoder) }; lock.unlock()
    }

    func appendChange(_ encoder: Int, _ delta: Int) {
        lock.lock(); changes.append((encoder, delta)); lock.unlock()
    }
}

private extension MK2PixelFrame {
    func countPixels(in rect: MK2PixelRect, notMatching color: UInt16) -> Int {
        guard let clipped = rect.clipped(to: MK2PixelFrame.bounds) else { return 0 }
        var count = 0
        for y in clipped.y..<clipped.maxY {
            for x in clipped.x..<clipped.maxX where self[x, y] != color {
                count += 1
            }
        }
        return count
    }
}
