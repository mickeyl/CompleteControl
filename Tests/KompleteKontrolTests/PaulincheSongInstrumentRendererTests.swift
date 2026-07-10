import Foundation
import KompleteKontrol
import PaulincheSurfaceKit
import Testing
@testable import KontrolSurfaceKit2

@Suite("Paulinche song and instrument renderers")
struct PaulincheSongInstrumentRendererTests {
    @Test("Song scene renders order and parameter screens")
    func songSceneRendersOrderAndParameterScreens() {
        let renderer = try? FreeTypeTextRenderer()
        let scene = Self.songFixture()

        let rendered = MK2PaulincheSongRenderer.render(scene, renderer: renderer)

        #expect(rendered.left.screen.kind == .regular)
        #expect(rendered.right.screen.kind == .regular)
        #expect(rendered.left.screen.frame.countPixels(in: MK2PixelRect(x: 0, y: 0, width: 480, height: 1), matching: MK2HIG.Chrome.headerTopLine) == 480)
        #expect(rendered.left.screen.frame.countPixels(in: MK2PixelRect(x: 8, y: 65, width: 460, height: 130), matching: 0x2128) > 120)
        #expect(rendered.right.screen.frame.countPixels(in: MK2PixelRect(x: 16, y: 55, width: 448, height: 120), notMatching: MK2HIG.Chrome.background) > 900)
        #expect(rendered.right.screen.frame.countPixels(in: MK2PixelRect(x: 16, y: 189, width: 432, height: 14), matching: MK2HIG.Chrome.accent) > 80)
        #expect(rendered.left.screen.frame.countPixels(in: MK2PixelRect(x: 0, y: 222, width: 480, height: 42), notMatching: MK2HIG.Chrome.background) > 400)
    }

    @Test("Song scene binds soft keys to function buttons")
    func songSceneBindsSoftKeysToFunctionButtons() {
        let box = SoftKeyBox()
        let rendered = MK2PaulincheSongRenderer.surfaceScene(
            Self.songFixture(),
            actions: MK2PaulincheSongActions { index, softKey in
                box.index = index
                box.commandID = softKey.commandID
                box.payload = softKey.integerPayload
            }
        )

        rendered.bindings.buttonDown[.function4]?()

        #expect(box.index == 3)
        #expect(box.commandID == "duplicateCurrentPattern")
        #expect(box.payload == nil)
    }

    @Test("Instrument scene renders waveform and detail screens in the surface layout")
    func instrumentSceneRendersWaveformAndDetailScreens() {
        let renderer = try? FreeTypeTextRenderer()
        let scene = Self.instrumentFixture()

        let rendered = MK2PaulincheInstrumentRenderer.render(scene, renderer: renderer)

        let left = rendered.left.screen.frame
        let right = rendered.right.screen.frame
        // The waveform fills the left content area: wave columns inside the loop region…
        #expect(left.countPixels(in: MK2PixelRect(x: 100, y: 40, width: 260, height: 160), matching: 0x464f) > 800)
        // …dimmed columns outside, and a playhead line.
        #expect(left.countPixels(in: MK2PixelRect(x: 12, y: 40, width: 60, height: 160), matching: 0x4a69) > 100)
        #expect(left.countPixels(in: MK2PixelRect(x: 8, y: 36, width: 464, height: 166), matching: MK2HIG.Chrome.accent) > 100)
        // Encoder slots sit bottom-flush on both screens.
        #expect(left.countPixels(in: MK2PixelRect(x: 8, y: 215, width: 456, height: 57), notMatching: 0x0841) > 300)
        #expect(right.countPixels(in: MK2PixelRect(x: 8, y: 215, width: 456, height: 57), notMatching: 0x0841) > 300)

        if let dir = ProcessInfo.processInfo.environment["PAULINCHE_SNAPSHOT_DIR"] {
            try? PixelSnapshot.write([left, right], to: "\(dir)/paulinche-instrument.png")
        }
    }

    @Test("Instrument scene leaves function buttons unbound and binds all encoders")
    func instrumentSceneLeavesFunctionButtonsUnbound() {
        let rendered = MK2PaulincheInstrumentRenderer.surfaceScene(Self.instrumentFixture())

        #expect(rendered.displays[0] != nil)
        #expect(rendered.displays[1] != nil)
        #expect(rendered.bindings.buttonDown[.function1] == nil)
        #expect(rendered.bindings.buttonDown[.function5] == nil)
        #expect(rendered.bindings.encoder[1] != nil)
        #expect(rendered.bindings.encoder[8] != nil)
    }

    private static func songFixture() -> MK2PaulincheSongScene {
        MK2PaulincheSongScene(
            title: "BO TRAPS",
            subtitle: "ORDER 04/12",
            progress: 0.42,
            orders: [
                MK2PaulincheSongOrder(index: 0, patternLabel: "P00", title: "Intro", rowCount: 64),
                MK2PaulincheSongOrder(index: 1, patternLabel: "P01", title: "Break", rowCount: 64),
                MK2PaulincheSongOrder(index: 2, patternLabel: "P03", title: "Lead In", rowCount: 48, isPlaybackOrder: true),
                MK2PaulincheSongOrder(index: 3, patternLabel: "P04", title: "Main Theme", rowCount: 64, isSelected: true),
                MK2PaulincheSongOrder(index: 4, patternLabel: "P05", title: "Fill", rowCount: 32),
            ],
            parameters: [
                MK2PaulinchePatternParameter(label: "BPM", value: "125"),
                MK2PaulinchePatternParameter(label: "SPD", value: "06", isFocused: true),
                MK2PaulinchePatternParameter(label: "LEN", value: "12"),
                MK2PaulinchePatternParameter(label: "PAT", value: "05"),
            ],
            softKeys: [
                MK2PaulincheSoftKey(label: "Append", commandID: "appendPattern"),
                MK2PaulincheSoftKey(label: "Clear", commandID: "clearArrangement"),
                MK2PaulincheSoftKey(label: "Loop", commandID: "toggleLoop"),
                MK2PaulincheSoftKey(label: "Dup", commandID: "duplicateCurrentPattern"),
            ]
        )
    }

    private static func instrumentFixture() -> MK2PaulincheInstrumentScene {
        let samples = (0..<512).map { index in
            Float(sin(Double(index) * 0.29) * (0.35 + 0.65 * sin(Double(index) * 0.05)))
        }
        let empty = MK2PaulinchePatternParameter(label: "", value: "")
        return MK2PaulincheInstrumentScene(
            title: "PULSE LEAD",
            subtitle: "EDIT 04 SAMPLE",
            instrumentIndex: 3,
            kind: .sample,
            infoLines: ["8420 FRAMES · 8363 HZ", "LOOP 1440…7900 · 6460 FRM"],
            playheadProgress: 0.38,
            waveform: MK2WaveformEnvelope(
                minima: samples.map { min($0, -abs($0) * 0.6) },
                maxima: samples.map { max($0, abs($0) * 0.6) }
            ),
            loopRegion: 0.17...0.94,
            markers: [0.05],
            parameters: [
                MK2PaulinchePatternParameter(label: "LOOP ST", value: "1440", isFocused: true),
                MK2PaulinchePatternParameter(label: "LOOP END", value: "7900"),
                MK2PaulinchePatternParameter(label: "START", value: "420"),
                empty,
                MK2PaulinchePatternParameter(label: "LEVEL", value: "80%"),
                MK2PaulinchePatternParameter(label: "FINE", value: "0ct"),
                MK2PaulinchePatternParameter(label: "ROOT", value: "C-4"),
                empty,
            ]
        )
    }
}

private final class SoftKeyBox: @unchecked Sendable {
    var index = -1
    var commandID: String?
    var payload: Int?
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
