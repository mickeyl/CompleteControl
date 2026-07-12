import Foundation
import KompleteKontrol
import PaulincheSurfaceKit
import Testing
@testable import KontrolSurfaceKit2

@Suite("Paulinche instrument renderer")
struct PaulincheInstrumentRendererTests {
    @Test("Instrument scene renders waveform and detail screens in the surface layout")
    func instrumentSceneRendersWaveformAndDetailScreens() {
        let renderer = try? FreeTypeTextRenderer()
        let scene = Self.instrumentFixture()

        let rendered = MK2PaulincheInstrumentRenderer.render(scene, renderer: renderer)

        let left = rendered.left.screen.frame
        let right = rendered.right.screen.frame
        // The waveform fills the left content area: wave columns inside the loop region…
        #expect(left.countPixels(in: MK2PixelRect(x: 100, y: 40, width: 260, height: 160), matching: MK2HIG.Waveform.trace) > 800)
        // …dimmed columns outside, and a playhead line.
        #expect(left.countPixels(in: MK2PixelRect(x: 12, y: 40, width: 60, height: 160), matching: MK2HIG.Waveform.traceOutsideRegion) > 100)
        #expect(left.countPixels(in: MK2PixelRect(x: 8, y: 36, width: 464, height: 166), matching: MK2HIG.Waveform.playhead) > 100)
        // Encoder slots sit bottom-flush on both screens.
        #expect(left.countPixels(in: MK2PixelRect(x: 8, y: 215, width: 464, height: 57), notMatching: 0x0841) > 300)
        #expect(right.countPixels(in: MK2PixelRect(x: 8, y: 215, width: 464, height: 57), notMatching: 0x0841) > 300)

        if let dir = ProcessInfo.processInfo.environment["PAULINCHE_SNAPSHOT_DIR"] {
            try? PixelSnapshot.write([left, right], to: "\(dir)/paulinche-instrument.png")
        }
    }

    @Test("Instrument scene shift soft keys build and dispatch the shift layer")
    func instrumentSceneShiftSoftKeys() async {
        let renderer = try? FreeTypeTextRenderer()
        let base = SoftKeyBox()
        let shift = SoftKeyBox()
        let pad = MK2PaulincheSoftKey(label: "", isEnabled: false)
        var fixture = Self.instrumentFixture()
        fixture.softKeys = [
            pad, pad, pad, pad,
            MK2PaulincheSoftKey(label: "Cut", commandID: "cutSample"),
            MK2PaulincheSoftKey(label: "Crop", commandID: "cropToLoop"),
            MK2PaulincheSoftKey(label: "Fade", commandID: "fadeOut"),
            MK2PaulincheSoftKey(label: "Norm", commandID: "normalize"),
        ]
        fixture.shiftSoftKeys = [
            pad, pad, pad, pad,
            MK2PaulincheSoftKey(label: "Reverse", commandID: "reverseSample"),
            pad,
            pad,
            MK2PaulincheSoftKey(label: "DC Fix", commandID: "removeDCOffset"),
        ]

        let scene = MK2PaulincheInstrumentRenderer.surfaceScene(
            fixture,
            actions: MK2PaulincheInstrumentActions(
                onSoftKey: { index, softKey in
                    base.index = index
                    base.commandID = softKey.commandID
                },
                onShiftSoftKey: { index, softKey in
                    shift.index = index
                    shift.commandID = softKey.commandID
                }
            ),
            renderer: renderer
        )

        // Only the right screen declares shift content; the left keeps its base frame.
        #expect(scene.shift != nil)
        #expect(scene.shift?.displays[0] == nil)
        #expect(scene.shift?.displays[1] != nil)

        let surface = MK2Surface2()
        await surface.present(scene)

        await surface.handleForTesting([.button(led: .function5, pressed: true)])
        await surface.handleForTesting([.button(led: .function5, pressed: false)])
        #expect(base.index == 4)
        #expect(base.commandID == "cutSample")

        await surface.handleForTesting([.button(led: .shift, pressed: true)])
        await surface.handleForTesting([.button(led: .function5, pressed: true)])
        await surface.handleForTesting([.button(led: .function5, pressed: false)])
        #expect(shift.index == 4)
        #expect(shift.commandID == "reverseSample")

        // F6 has a base action (Crop) but an empty shift slot: swallowed under shift.
        await surface.handleForTesting([.button(led: .function6, pressed: true)])
        await surface.handleForTesting([.button(led: .function6, pressed: false)])
        #expect(base.commandID == "cutSample")
        await surface.handleForTesting([.button(led: .shift, pressed: false)])

        if let dir = ProcessInfo.processInfo.environment["PAULINCHE_SNAPSHOT_DIR"],
           let left = scene.displays[0], let shiftRight = scene.shift?.displays[1] {
            try? PixelSnapshot.write([left, shiftRight], to: "\(dir)/paulinche-instrument-shift.png")
        }
    }

    @Test("Instrument scene leaves function buttons unbound and binds all encoders")
    func instrumentSceneLeavesFunctionButtonsUnbound() {
        let rendered = MK2PaulincheInstrumentRenderer.surfaceScene(Self.instrumentFixture())

        #expect(rendered.displays[0] != nil)
        #expect(rendered.displays[1] != nil)
        #expect(rendered.bindings.buttonDown[.function1] == nil)
        #expect(rendered.bindings.buttonDown[.function5] == nil)
        // Non-focused assigned parameter slots carry a touch overlay on the
        // display their encoder sits under.
        #expect(rendered.encoderTouchOverlays[2]?.screen == 0)
        #expect(rendered.encoderTouchOverlays[5]?.screen == 1)
        #expect(rendered.bindings.encoder[1] != nil)
        #expect(rendered.bindings.encoder[8] != nil)
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
                MK2PaulinchePatternParameter(label: "LOOP ST", iconGlyph: MK2HIG.IconGlyph.loop, value: "1440", isFocused: true),
                MK2PaulinchePatternParameter(label: "LOOP END", iconGlyph: MK2HIG.IconGlyph.loop, value: "7900"),
                MK2PaulinchePatternParameter(label: "START", iconGlyph: MK2HIG.IconGlyph.arrowLineRight, value: "420"),
                empty,
                MK2PaulinchePatternParameter(label: "LEVEL", iconGlyph: MK2HIG.IconGlyph.speakerHigh, value: "80%"),
                MK2PaulinchePatternParameter(label: "FINE", iconGlyph: MK2HIG.IconGlyph.waveSine, value: "0ct"),
                MK2PaulinchePatternParameter(label: "ROOT", iconGlyph: MK2HIG.IconGlyph.anchor, value: "C-4"),
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
