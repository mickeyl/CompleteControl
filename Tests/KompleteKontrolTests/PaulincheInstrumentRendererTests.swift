import Foundation
import KompleteKontrol
import Testing
@testable import KontrolSurfaceKit2
@testable import PaulincheSurfaceKit

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

    @Test("Instrument color replaces the subtitle with a rounded vertical gradient")
    func instrumentColorReplacesSubtitle() {
        let renderer = try? FreeTypeTextRenderer()
        let scene = Self.instrumentFixture()
        let left = MK2PaulincheInstrumentRenderer.render(scene, renderer: renderer).left.screen.frame
        let rect = MK2PaulincheInstrumentRenderer.instrumentColorRect
        let centerX = rect.x + rect.width / 2

        let top = left[centerX, rect.y]
        let center = left[centerX, rect.y + Int((Double(rect.height) * 0.48).rounded()) - 1]
        let bottom = left[centerX, rect.maxY - 1]
        #expect(top > center)
        #expect(center > bottom)
        #expect(left[rect.x, rect.y] == 0x0841)

        var changedSubtitle = scene
        changedSubtitle.subtitle = "THIS MUST NOT BE RENDERED"
        let changedLeft = MK2PaulincheInstrumentRenderer.render(
            changedSubtitle,
            renderer: renderer
        ).left.screen.frame
        #expect(changedLeft == left)
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
        #expect(rendered.bindings.rawEncoder[1] != nil)
        #expect(rendered.bindings.rawEncoder[8] != nil)
    }

    @Test("Wavetable scene uses both function bars, page visuals, and enabled encoders")
    func wavetableSceneUsesTheCompleteHardwareSurface() async {
        let renderer = try? FreeTypeTextRenderer()
        let pressed = SoftKeyBox()
        let fixture = Self.wavetableFixture(page: .source)
        let rendered = MK2PaulincheInstrumentRenderer.surfaceScene(
            fixture,
            actions: MK2PaulincheInstrumentActions(onSoftKey: { index, _ in pressed.index = index }),
            renderer: renderer
        )

        #expect(rendered.bindings.buttonDown[.function1] != nil)
        #expect(rendered.bindings.buttonDown[.function4] != nil)
        #expect(rendered.bindings.buttonDown[.function5] == nil)
        #expect(rendered.bindings.buttonDown[.function7] != nil)
        #expect(rendered.bindings.buttonDown[.function8] != nil)
        #expect(rendered.bindings.rawEncoder[1] != nil)
        #expect(rendered.bindings.rawEncoder[7] != nil)
        #expect(rendered.bindings.rawEncoder[8] == nil)
        #expect(rendered.displays[0]?.countPixels(in: MK2PixelRect(x: 8, y: 53, width: 464, height: 151), notMatching: 0x0841) ?? 0 > 1_000)
        #expect(rendered.displays[1]?.countPixels(in: MK2PixelRect(x: 8, y: 53, width: 464, height: 151), notMatching: 0x0841) ?? 0 > 1_000)

        let surface = MK2Surface2()
        await surface.present(rendered)
        await surface.handleForTesting([.button(led: .function8, pressed: true)])
        #expect(pressed.index == 7)

        if let dir = ProcessInfo.processInfo.environment["PAULINCHE_SNAPSHOT_DIR"],
           let left = rendered.displays[0], let right = rendered.displays[1] {
            _ = try? PixelSnapshot.write([left, right], to: "\(dir)/paulinche-wavetable-source.png")
        }
    }

    @Test("Every wavetable page produces a distinct dual-screen visualization")
    func everyWavetablePageProducesAVisualization() {
        let renderer = try? FreeTypeTextRenderer()
        let frames = MK2PaulincheWavetablePage.allCases.map { page in
            MK2PaulincheInstrumentRenderer.render(Self.wavetableFixture(page: page), renderer: renderer)
        }

        for index in 1..<frames.count {
            #expect(frames[index].left.screen.frame != frames[index - 1].left.screen.frame)
            #expect(frames[index].right.screen.frame != frames[index - 1].right.screen.frame)
        }
        if let dir = ProcessInfo.processInfo.environment["PAULINCHE_SNAPSHOT_DIR"] {
            for (page, rendered) in zip(MK2PaulincheWavetablePage.allCases, frames) {
                _ = try? PixelSnapshot.write(
                    [rendered.left.screen.frame, rendered.right.screen.frame],
                    to: "\(dir)/paulinche-wavetable-\(page.rawValue).png"
                )
            }
        }
    }

    @Test("Hybrid attack page shows the active region, handoff, real body, and segmented playhead")
    func hybridAttackPageShowsTheCompleteSignalFlow() {
        let renderer = try? FreeTypeTextRenderer()
        var attackScene = Self.wavetableFixture(page: .attack)
        attackScene.hybridTimeline?.playheadSegment = .attack
        attackScene.hybridTimeline?.playheadProgress = 0.35

        let attackFrames = MK2PaulincheInstrumentRenderer.render(attackScene, renderer: renderer)
        let left = attackFrames.left.screen.frame
        let right = attackFrames.right.screen.frame
        let visualization = MK2PixelRect(x: 8, y: 53, width: 464, height: 151)

        #expect(left.countPixels(in: visualization, matching: MK2HIG.Waveform.regionEdge) > 100)
        #expect(left.countPixels(in: visualization, matching: MK2PaulincheRendererSupport.Palette.orange) > 50)
        #expect(left.countPixels(in: visualization, matching: MK2HIG.Waveform.playhead) > 50)
        #expect(right.countPixels(in: visualization, matching: MK2HIG.Waveform.trace) > 300)
        #expect(right.countPixels(in: visualization, matching: MK2HIG.Waveform.playhead) == 0)

        var bodyScene = attackScene
        bodyScene.hybridTimeline?.playheadSegment = .body
        bodyScene.hybridTimeline?.playheadProgress = 0.62
        let bodyFrames = MK2PaulincheInstrumentRenderer.render(bodyScene, renderer: renderer)
        #expect(bodyFrames.left.screen.frame.countPixels(in: visualization, matching: MK2HIG.Waveform.playhead) == 0)
        #expect(bodyFrames.right.screen.frame.countPixels(in: visualization, matching: MK2HIG.Waveform.playhead) > 30)

        var sourceScene = Self.wavetableFixture(page: .source)
        sourceScene.playheadProgress = 0.35
        let sourceGraph = MK2PixelRect(x: 20, y: 84, width: 440, height: 104)
        let sourceDuringAttack = MK2PaulincheInstrumentRenderer.render(sourceScene, renderer: renderer)
        #expect(sourceDuringAttack.left.screen.frame.countPixels(in: sourceGraph, matching: MK2HIG.Waveform.playhead) == 0)
        #expect(sourceDuringAttack.right.screen.frame.countPixels(in: sourceGraph, matching: MK2HIG.Waveform.playhead) == 0)

        sourceScene.hybridTimeline?.playheadSegment = .body
        sourceScene.hybridTimeline?.playheadProgress = 0.62
        let sourceDuringBody = MK2PaulincheInstrumentRenderer.render(sourceScene, renderer: renderer)
        #expect(sourceDuringBody.left.screen.frame.countPixels(in: sourceGraph, matching: MK2HIG.Waveform.playhead) > 50)
        #expect(sourceDuringBody.right.screen.frame.countPixels(in: sourceGraph, matching: MK2HIG.Waveform.playhead) > 50)

        if let dir = ProcessInfo.processInfo.environment["PAULINCHE_SNAPSHOT_DIR"] {
            _ = try? PixelSnapshot.write(
                [bodyFrames.left.screen.frame, bodyFrames.right.screen.frame],
                to: "\(dir)/paulinche-wavetable-hybrid-body.png"
            )
        }
    }

    private static func wavetableFixture(page: MK2PaulincheWavetablePage) -> MK2PaulincheInstrumentScene {
        let samples = (0..<464).map { index in Float(sin(Double(index) * 0.08) * 0.8) }
        let attackSamples = (0..<464).map { index in
            Float(sin(Double(index) * 0.17) * exp(-Double(index) / 310))
        }
        let bodySamples = (0..<464).map { index in
            Float(sin(Double(index) * 0.045) * (0.3 + 0.7 * sin(Double(index) * 0.006)))
        }
        let labels: [String]
        switch page {
            case .source: labels = ["WAVE", "BASE", "DUTY", "FRAMES", "SIZE", "OCTAVE", "FINE", ""]
            case .attack: labels = ["SAMPLE", "LEVEL", "ROOT", "FINE", "START", "END", "HANDOFF", ""]
            case .performance: labels = ["PITCH", "VOLUME", "WAVE PH", "BANK ST", "SCAN PH", "", "", ""]
            case .filterBank: labels = ["TYPE", "SLOPE", "CUT ST", "CUT END", "RESON", "", "", ""]
            case .ringAndSweep: labels = ["HARM", "DEPTH", "ACROSS", "", "START", "END", "TIME", "MODE"]
            case .pwm, .vibrato, .frameScan, .tremolo: labels = ["SHAPE", "RATE", "SYNC", "DEPTH", "DELAY", "FADE", "", ""]
            case .envelopes: labels = ["ATTACK", "DECAY", "SUSTAIN", "RELEASE", "P START", "P END", "P TIME", ""]
        }
        let values: [String] = switch page {
            case .source: ["PULSE", "80%", "40%", "8", "64", "0", "0ct", ""]
            case .attack: ["MALLET", "80%", "C-4", "0ct", "0", "1200", "1cy", ""]
            case .performance: ["±7ct", "±3%", "±2", "±1", "±4%", "", "", ""]
            case .filterBank: ["LP", "4P", "100%", "8%", "60%", "", "", ""]
            case .ringAndSweep: ["3×", "80%", "YES", "", "100%", "0%", "0.50s", "HOLD"]
            case .pwm: ["TRIANGLE", "0.6Hz", "FREE", "20%", "0.10s", "0.20s", "", ""]
            case .vibrato: ["SINE", "5.0Hz", "FREE", "0.20st", "0.10s", "0.20s", "", ""]
            case .frameScan: ["TRIANGLE", "1.0Hz", "FREE", "7.0fr", "0.10s", "0.20s", "", ""]
            case .tremolo: ["SINE", "4.0Hz", "FREE", "35%", "0.10s", "0.20s", "", ""]
            case .envelopes: ["0.000s", "0.180s", "0%", "0.080s", "+12.0st", "0.0st", "0.120s", ""]
        }
        let parameters = labels.enumerated().map { index, label in
            MK2PaulinchePatternParameter(
                label: label,
                value: label.isEmpty ? "" : values[index],
                level: Double(index + 1) / 9,
                isEnabled: !label.isEmpty
            )
        }
        let pad = MK2PaulincheSoftKey(label: "", isEnabled: false)
        let softKeys: [MK2PaulincheSoftKey] = if page == .source {
            [
                MK2PaulincheSoftKey(label: "PULSE", isSelected: true),
                MK2PaulincheSoftKey(label: "SAW"),
                MK2PaulincheSoftKey(label: "TRI"),
                MK2PaulincheSoftKey(label: "NOISE"),
                pad,
                pad,
                MK2PaulincheSoftKey(label: "INIT"),
                MK2PaulincheSoftKey(label: "RANDOM"),
            ]
        } else {
            [
                MK2PaulincheSoftKey(label: "ON", isSelected: true),
                MK2PaulincheSoftKey(label: "INIT"),
                MK2PaulincheSoftKey(label: "RANDOM"),
                pad,
                pad,
                pad,
                MK2PaulincheSoftKey(label: "INIT"),
                MK2PaulincheSoftKey(label: "RANDOM"),
            ]
        }
        return MK2PaulincheInstrumentScene(
            title: "PULSE LAB",
            subtitle: "01 · \(page.title)",
            instrumentIndex: 0,
            kind: .wavetable,
            wavetablePage: page,
            infoLines: ["SOUND DESIGN PAGE", "DOUBLE TOUCH RESETS"],
            waveform: MK2WaveformEnvelope(minima: samples.map { -abs($0) }, maxima: samples.map(abs)),
            hybridTimeline: MK2PaulincheHybridTimeline(
                attackWaveform: MK2WaveformEnvelope(
                    minima: attackSamples.map { min(0, $0) },
                    maxima: attackSamples.map { max(0, $0) }
                ),
                bodyWaveform: MK2WaveformEnvelope(
                    minima: bodySamples.map { min(0, $0) },
                    maxima: bodySamples.map { max(0, $0) }
                ),
                bodyFrameCount: 8,
                attackStartFraction: 0.08,
                attackEndFraction: 0.92,
                crossfadeFraction: 0.22,
                playheadSegment: .attack,
                playheadProgress: 0.35
            ),
            parameters: parameters,
            softKeys: softKeys
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
            instrumentColorGradient: MK2PaulincheInstrumentColorGradient(
                top: KKRGB(red: 0xff, green: 0x52, blue: 0x52),
                center: KKRGB(red: 0xff, green: 0x00, blue: 0x00),
                bottom: KKRGB(red: 0xb8, green: 0x00, blue: 0x00)
            ),
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
