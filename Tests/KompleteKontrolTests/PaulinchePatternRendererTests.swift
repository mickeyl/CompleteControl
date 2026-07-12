import Foundation
import KompleteKontrol
import PaulincheSurfaceKit
import Testing
@testable import KontrolSurfaceKit2

@Suite("Paulinche pattern renderer")
struct PaulinchePatternRendererTests {
    private static let background: UInt16 = 0x0841
    private static let cursorFill: UInt16 = 0x19aa
    private static let playheadFill: UInt16 = 0x1125
    private static let muteFill: UInt16 = 0xf8c3
    private static let soloFill: UInt16 = 0x03ff

    @Test("Pattern grid renders full-screen in the widget-lab layout")
    func patternGridRendersLabLayout() {
        let scene = Self.fixture()
        let rendered = MK2PaulinchePatternRenderer.render(scene)

        #expect(rendered.left.screen.kind == .fullScreen)
        #expect(rendered.right.screen.kind == .fullScreen)

        let grid = rendered.left.screen.frame
        // Status line row, channel headers, and grid text all live above a full-bleed background.
        #expect(grid.countPixels(in: MK2PixelRect(x: 8, y: 8, width: 460, height: 16), notMatching: Self.background) > 100)
        // The cursor row (index 0x1F, visible slot 7) is filled edge to edge while stopped.
        let cursorRow = MK2PixelRect(x: 0, y: 60 + 7 * 16, width: 480, height: 16)
        #expect(grid.countPixels(in: cursorRow, matching: Self.cursorFill) > 3_000)
        // Mute chip on channel 3 and solo chip on channel 4 render in their accent fills.
        #expect(grid.countPixels(in: MK2PixelRect(x: 315, y: 34, width: 14, height: 16), matching: Self.muteFill) > 40)
        #expect(grid.countPixels(in: MK2PixelRect(x: 438, y: 34, width: 14, height: 16), matching: Self.soloFill) > 40)
        // The pattern overview minimap occupies the right edge.
        #expect(grid.countPixels(in: MK2PixelRect(x: 466, y: 62, width: 9, height: 200), notMatching: Self.background) > 150)

        // Edit cells carry touch overlays for their encoders (E5–E8); the
        // focused INST slot needs none — touched and focused look identical.
        #expect(rendered.right.touchOverlays[5] != nil)
        #expect(rendered.right.touchOverlays[6] == nil)
        #expect(rendered.right.touchOverlays[7] != nil)
        #expect(rendered.right.touchOverlays[8] != nil)
    }

    @Test("Playback row uses the playhead fill")
    func playbackRowUsesPlayheadFill() {
        var scene = Self.fixture()
        scene.isPlaying = true
        let rendered = MK2PaulinchePatternRenderer.render(scene)
        let cursorRow = MK2PixelRect(x: 0, y: 60 + 7 * 16, width: 480, height: 16)
        #expect(rendered.left.screen.frame.countPixels(in: cursorRow, matching: Self.playheadFill) > 3_000)
        #expect(rendered.left.screen.frame.countPixels(in: cursorRow, matching: Self.cursorFill) == 0)
    }

    @Test("Pattern scene leaves function buttons to hardware actions")
    func patternSceneDoesNotBindEditActionsToFunctionButtons() {
        let scene = Self.fixture()
        let rendered = MK2PaulinchePatternRenderer.surfaceScene(
            scene,
            actions: MK2PaulinchePatternActions { index, softKey in
                _ = index
                _ = softKey
            }
        )

        #expect(rendered.displays[0] != nil)
        #expect(rendered.displays[1] != nil)
        #expect(rendered.bindings.buttonDown[.function5] == nil)
    }

    @Test("Pattern edit screen draws the parameter page and no meters")
    func patternEditScreenDrawsParameterPage() {
        let rendered = MK2PaulinchePatternRenderer.render(Self.fixture())
        let edit = rendered.right.screen.frame
        #expect(edit.countPixels(in: MK2PixelRect(x: 8, y: 215, width: 464, height: 57), notMatching: Self.background) > 300)
        // The area between the status line and the parameter page stays empty (no meters, no hint text).
        #expect(edit.countPixels(in: MK2PixelRect(x: 0, y: 60, width: 480, height: 130), notMatching: Self.background) == 0)
    }

    @Test("Pattern edit footer forwards encoder deltas and touches")
    func patternEditFooterForwardsEncoders() {
        let scene = Self.fixture()
        let recorder = PatternEncoderActionRecorder()
        let rendered = MK2PaulinchePatternRenderer.surfaceScene(
            scene,
            actions: MK2PaulinchePatternActions(
                onEncoderTouch: { encoder, touched in
                    recorder.appendTouch(encoder: encoder, touched: touched)
                },
                onEncoderChange: { encoder, delta in
                    recorder.appendChange(encoder: encoder, delta: delta)
                }
            )
        )

        rendered.bindings.encoderTouch[5]?(true)
        rendered.bindings.encoderTouch[5]?(false)
        rendered.bindings.encoder[5]?(2, 0, 0)
        rendered.bindings.encoder[8]?(-1, 0, 0)

        let touches = recorder.touchesSnapshot()
        let changes = recorder.changesSnapshot()
        #expect(touches.count == 2)
        #expect(touches[0].0 == 5)
        #expect(touches[0].1 == true)
        #expect(touches[1].0 == 5)
        #expect(touches[1].1 == false)
        #expect(changes.count == 2)
        #expect(changes[0].0 == 5)
        #expect(changes[0].1 == 2)
        #expect(changes[1].0 == 8)
        #expect(changes[1].1 == -1)
        #expect(rendered.bindings.encoder[4] == nil)
    }

    @Test("Pattern screens can be captured as a two-screen snapshot")
    func patternSnapshotSmoke() throws {
        var scene = Self.fixture()
        scene.isPlaying = true
        let rendered = MK2PaulinchePatternRenderer.render(scene, renderer: try? FreeTypeTextRenderer())
        let png = PixelSnapshot.pngData(frames: [rendered.left.screen.frame, rendered.right.screen.frame])
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        if let dir = ProcessInfo.processInfo.environment["PAULINCHE_SNAPSHOT_DIR"] {
            try PixelSnapshot.write(
                [rendered.left.screen.frame, rendered.right.screen.frame],
                to: "\(dir)/paulinche-pattern.png"
            )
        }
    }

    private static func fixture() -> MK2PaulinchePatternScene {
        let rows = (0..<13).map { visible in
            let rowIndex = 0x18 + visible
            return MK2PaulinchePatternRow(
                index: rowIndex,
                cells: [
                    visible % 4 == 0 ? MK2PaulinchePatternCell(note: "C-4", instrument: "01") : MK2PaulinchePatternCell(),
                    visible % 5 == 0 ? MK2PaulinchePatternCell(note: "D#4", instrument: "02", effect: "A09") : MK2PaulinchePatternCell(),
                    visible % 3 == 0 ? MK2PaulinchePatternCell(note: "F-3", instrument: "03", effect: "C20") : MK2PaulinchePatternCell(),
                    visible == 7 ? MK2PaulinchePatternCell(note: "A-3", instrument: "04", effect: "F06") : MK2PaulinchePatternCell(),
                ]
            )
        }
        return MK2PaulinchePatternScene(
            title: "PAULINCHE",
            subtitle: "O01/04",
            isPlaying: false,
            rowCount: 64,
            selectedRowIndex: 0x1f,
            selectedChannelIndex: 3,
            instrumentLabel: "INST 04 Pulse Lead",
            rows: rows,
            rowActivity: (0..<64).map { $0 % 4 == 0 },
            channels: [
                MK2PaulinchePatternChannel(label: "CHANNEL 1"),
                MK2PaulinchePatternChannel(label: "CHANNEL 2"),
                MK2PaulinchePatternChannel(label: "CHANNEL 3", isMuted: true),
                MK2PaulinchePatternChannel(label: "CHANNEL 4", isSoloed: true),
            ],
            parameters: [
                MK2PaulinchePatternParameter(label: "NOTE", iconGlyph: MK2HIG.IconGlyph.musicNote, value: "A-3"),
                MK2PaulinchePatternParameter(label: "INST", iconGlyph: MK2HIG.IconGlyph.pianoKeys, value: "04", isFocused: true),
                MK2PaulinchePatternParameter(label: "VOL", iconGlyph: MK2HIG.IconGlyph.speakerHigh, value: "50"),
                MK2PaulinchePatternParameter(label: "FX", iconGlyph: MK2HIG.IconGlyph.lightning, value: "F06"),
            ],
            softKeys: [
                MK2PaulincheSoftKey(label: "Clear", commandID: "clearCell"),
                MK2PaulincheSoftKey(label: "Sel Clr", commandID: "clearPatternEventSelection"),
                MK2PaulincheSoftKey(label: "Nudge+", commandID: "nudgeCellRows", integerPayload: 1),
                MK2PaulincheSoftKey(label: "Nudge-", commandID: "nudgeCellRows", integerPayload: -1),
                MK2PaulincheSoftKey(label: "Oct+", commandID: "transposeFocusedNotes", integerPayload: 12),
                MK2PaulincheSoftKey(label: "Oct-", commandID: "transposeFocusedNotes", integerPayload: -12),
                MK2PaulincheSoftKey(label: "Step-", commandID: "decreaseStepSize"),
                MK2PaulincheSoftKey(label: "Step+", commandID: "increaseStepSize"),
            ]
        )
    }
}

private final class PatternEncoderActionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var touches: [(Int, Bool)] = []
    private var changes: [(Int, Int)] = []

    func appendTouch(encoder: Int, touched: Bool) {
        lock.lock()
        touches.append((encoder, touched))
        lock.unlock()
    }

    func appendChange(encoder: Int, delta: Int) {
        lock.lock()
        changes.append((encoder, delta))
        lock.unlock()
    }

    func touchesSnapshot() -> [(Int, Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return touches
    }

    func changesSnapshot() -> [(Int, Int)] {
        lock.lock()
        defer { lock.unlock() }
        return changes
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
