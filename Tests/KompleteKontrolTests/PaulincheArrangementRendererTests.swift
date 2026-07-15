import Foundation
import KompleteKontrol
import PaulincheSurfaceKit
import Testing
@testable import KontrolSurfaceKit2

@Suite("Paulinche arrangement renderer")
struct PaulincheArrangementRendererTests {
    private static let background: UInt16 = 0x0841

    @Test("Left screen carries the order list and the E1–E4 property footer")
    func leftScreenListAndFooter() {
        let rendered = MK2PaulincheArrangementRenderer.render(Self.fixture())
        #expect(rendered.left.screen.kind == .fullScreen)
        let list = rendered.left.screen.frame
        // Order rows above the footer…
        #expect(list.countPixels(in: MK2PixelRect(x: 0, y: 40, width: 480, height: 160), notMatching: Self.background) > 200)
        // …and the E1–E4 order-property footer at the bottom-flush encoder band.
        #expect(list.countPixels(in: MK2PixelRect(x: 8, y: 215, width: 464, height: 57), notMatching: Self.background) > 200)
    }

    @Test("Right screen renders the selected order's pattern grid, not a thumbnail")
    func rightScreenPatternGrid() {
        let rendered = MK2PaulincheArrangementRenderer.render(Self.fixture())
        let grid = rendered.right.screen.frame
        // Channel headers and the grid body carry real content like the pattern editor.
        #expect(grid.countPixels(in: MK2PixelRect(x: 0, y: 38, width: 480, height: 20), notMatching: Self.background) > 40)
        #expect(grid.countPixels(in: MK2PixelRect(x: 0, y: 60, width: 480, height: 200), notMatching: Self.background) > 200)
        // The minimap occupies the right edge.
        #expect(grid.countPixels(in: MK2PixelRect(x: 466, y: 62, width: 9, height: 200), notMatching: Self.background) > 100)
    }

    @Test("Editable order-property encoders use the calibrated discrete throw")
    func orderPropertyEncodersForward() {
        let recorder = ArrangementEncoderRecorder()
        let rendered = MK2PaulincheArrangementRenderer.surfaceScene(
            Self.fixture(),
            actions: MK2PaulincheArrangementActions(
                onEncoderTouch: { encoder, touched in recorder.appendTouch(encoder, touched) },
                onEncoderChange: { encoder, delta in recorder.appendChange(encoder, delta) }
            )
        )
        for encoder in 1...4 {
            #expect(rendered.bindings.encoder[encoder] != nil)
            #expect(rendered.bindings.encoderTouch[encoder] != nil)
        }
        rendered.bindings.encoderTouch[2]?(true)
        rendered.bindings.encoder[2]?(41, 0, 0)

        #expect(recorder.changes.isEmpty)

        rendered.bindings.encoder[2]?(1, 0, 0)

        #expect(recorder.touches == [2])
        #expect(recorder.changes.first?.0 == 2)
        #expect(recorder.changes.first?.1 == 1)
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
        let notes = ["C-4", "D#4", "F-3", "A-3", "G-4"]
        let rows = (0..<13).map { visible in
            MK2PatternGridElement.Row(
                index: visible,
                cells: (0..<4).map { channel in
                    visible % 4 == channel % 4
                        ? MK2PatternGridElement.Cell(note: notes[(visible + channel) % notes.count], instrument: "01")
                        : MK2PatternGridElement.Cell()
                }
            )
        }
        return MK2PaulincheArrangementScene(
            title: "ARRANGEMENT",
            subtitle: "PAULINCHE",
            isPlaying: true,
            selectedOrderIndex: 1,
            orders: [
                MK2PaulincheArrangementOrder(patternLabel: "00 Intro", length: 64, repeatCount: 1),
                MK2PaulincheArrangementOrder(patternLabel: "01 Verse", length: 64, repeatCount: 2, isPlaying: true),
                MK2PaulincheArrangementOrder(patternLabel: "02 Chorus", length: 32, repeatCount: 1),
            ],
            preview: MK2PaulincheArrangementPreview(
                title: "01 Verse",
                rows: rows,
                channels: (0..<4).map { MK2PatternGridElement.Channel(label: "CH\($0 + 1)") },
                selectedRowIndex: 4,
                rowCount: 64,
                rowActivity: (0..<64).map { $0 % 4 == 0 },
                isPlaying: true,
                beatInterval: 4
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
