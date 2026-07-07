import Foundation
import KompleteKontrol
import PaulincheSurfaceKit
import Testing
@testable import KontrolSurfaceKit2

@Suite("Paulinche pattern renderer")
struct PaulinchePatternRendererTests {
    @Test("Pattern scene renders grid, editor and meter panes")
    func patternSceneRendersBothScreens() {
        let renderer = try? FreeTypeTextRenderer()
        let scene = Self.fixture()

        let rendered = MK2PaulinchePatternRenderer.render(scene, renderer: renderer)

        #expect(rendered.left.screen.kind == .fullScreen)
        #expect(rendered.right.screen.kind == .fullScreen)
        #expect(rendered.left.screen.frame.countPixels(in: MK2PixelRect(x: 0, y: 0, width: 480, height: 1), matching: MK2HIG.Chrome.headerTopLine) == 480)
        #expect(rendered.left.screen.frame.countPixels(in: MK2PixelRect(x: 8, y: 70, width: 460, height: 185), notMatching: MK2HIG.Chrome.background) > 1_000)
        #expect(rendered.left.screen.frame.countPixels(in: MK2PixelRect(x: 6, y: 176, width: 456, height: 16), matching: 0x2128) > 200)
        #expect(rendered.left.screen.frame.countPixels(in: MK2PixelRect(x: 298, y: 50, width: 40, height: 18), matching: 0xfaa0) > 10)
        #expect(rendered.left.screen.frame.countPixels(in: MK2PixelRect(x: 421, y: 50, width: 40, height: 18), matching: 0xffe0) > 10)
        #expect(rendered.right.screen.frame.countPixels(in: MK2PixelRect(x: 18, y: 58, width: 444, height: 118), notMatching: MK2HIG.Chrome.background) > 700)
        #expect(rendered.right.screen.frame.countPixels(in: MK2PixelRect(x: 58, y: 110, width: 380, height: 64), matching: 0x464f) > 120)
        #expect(rendered.right.screen.frame.countPixels(in: MK2PixelRect(x: 0, y: 215, width: 480, height: 57), notMatching: MK2HIG.Chrome.background) > 300)
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

    private static func fixture() -> MK2PaulinchePatternScene {
        let rows = (0..<14).map { row in
            MK2PaulinchePatternRow(
                index: 0x18 + row,
                channelCells: [
                    row % 4 == 0 ? "C-4 01 .. ..." : "--- -- .. ...",
                    row % 5 == 0 ? "D#4 02 40 A09" : "--- -- .. ...",
                    row % 3 == 0 ? "F-3 03 20 C20" : "--- -- .. ...",
                    row == 7 ? "A-3 04 50 F06" : "--- -- .. ...",
                ],
                isPlaybackRow: row == 4
            )
        }
        return MK2PaulinchePatternScene(
            title: "PAULINCHE",
            subtitle: "PAT 03 ROW 1F INST",
            rowProgress: 0.48,
            selectedRowIndex: 0x1f,
            selectedChannelIndex: 3,
            rows: rows,
            parameters: [
                MK2PaulinchePatternParameter(label: "NOTE", value: "A-3"),
                MK2PaulinchePatternParameter(label: "INST", value: "04", isFocused: true),
                MK2PaulinchePatternParameter(label: "VOL", value: "50"),
                MK2PaulinchePatternParameter(label: "FX", value: "F06"),
            ],
            meters: [
                MK2PaulinchePatternMeter(label: "CH1", level: 0.36, peak: 0.52),
                MK2PaulinchePatternMeter(label: "CH2", level: 0.62, peak: 0.74),
                MK2PaulinchePatternMeter(label: "CH3", level: 0.28, peak: 0.42, isMuted: true),
                MK2PaulinchePatternMeter(label: "CH4", level: 0.86, peak: 0.92, isSoloed: true),
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
