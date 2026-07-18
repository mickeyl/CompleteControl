import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// Live MK3 pad laboratory. The HID endpoint supplies a touch-only, native
/// 12-bit hit, or pressure-only contact followed by a 12-bit pressure stream.
/// This demo captures five increasing-force samples per pad and calibrates the
/// two MIDI mappings independently.
final class MK3PadCalibrationDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "mk3-pad-calibration",
        title: "MASCHINE MK3 Pad Calibration",
        category: .calibration,
        summary: "Soft-hit threshold, velocity, and poly-pressure curves",
        detail: "Hit every pad five times from very soft to hard. The left display tracks sample progress in the physical 4x4 layout. The right display distinguishes recovered touch/pressure hits from native strikes and shows the independent pressure signal. E5 sets the soft-hit threshold; E6-E8 tune velocity ceiling and pressure.",
        snapshotVariants: ["strike"]
    )

    private static let padLEDs: [MaschineMK3PadLED] = [
        .pad1, .pad2, .pad3, .pad4,
        .pad5, .pad6, .pad7, .pad8,
        .pad9, .pad10, .pad11, .pad12,
        .pad13, .pad14, .pad15, .pad16,
    ]
    private static let panelRows = [
        [13, 14, 15, 16],
        [9, 10, 11, 12],
        [5, 6, 7, 8],
        [1, 2, 3, 4],
    ]

    private struct HitSample: Sendable {
        var rawVelocity: Int
        var source: KontrolPadHitSource
    }

    private var strikeFloor = 8
    private var strikeCeiling = 768
    private var pressureFloor = 64
    private var pressureCeiling = 3072
    private var analyzer = KontrolPadStrikeAnalyzer()
    private var hitSamples = [[HitSample]](repeating: [], count: 16)
    private var sampledContacts = [Bool](repeating: false, count: 16)
    private var midiHeldPads = [Bool](repeating: false, count: 16)
    private var selectedPadIndex = 0
    private var midiHitCount = 0
    private var focusedEncoder: Int?
    private var refreshTask: Task<Void, Never>?

    private var calibration: KontrolPadVelocityCalibration {
        KontrolPadVelocityCalibration(
            strikeFloor: strikeFloor,
            strikeCeiling: strikeCeiling,
            pressureFloor: pressureFloor,
            pressureCeiling: pressureCeiling
        )
    }

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        var scene = MK2DoubleScreenDSL(
            left: padMatrixScreen(context),
            right: analysisScreen(context)
        ).scene()
        scene.bindings.pad = { [weak self] event in
            context.mutate { [weak self] in
                guard let demo = self else { return }
                demo.receive(event)
                demo.requestRefresh(context)
            }
        }
        scene.diagnosticLEDBytes = padLEDBytes()
        return scene
    }

    func prepareSnapshot(variant: String) {
        refreshTask?.cancel()
        refreshTask = nil
        strikeFloor = 8
        strikeCeiling = 768
        pressureFloor = 64
        pressureCeiling = 3072
        analyzer = KontrolPadStrikeAnalyzer(calibration: calibration)
        hitSamples = [[HitSample]](repeating: [], count: 16)
        sampledContacts = [Bool](repeating: false, count: 16)
        midiHeldPads = [Bool](repeating: false, count: 16)
        selectedPadIndex = 0
        midiHitCount = 0
        focusedEncoder = nil
        guard variant == "strike" else { return }

        feedFixture(padIndex: 0, strikeVelocity: 840, pressures: [120, 760, 1240], release: true)
        feedFixture(padIndex: 5, strikeVelocity: 2200, pressures: [180, 1700, 2600], release: false)
        feedFixture(padIndex: 9, strikeVelocity: 3100, pressures: [90, 920, 2140], release: false)
        selectedPadIndex = 9
    }

    func demoWillClose() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func replCommands() -> [ReplCommand] {
        [
            ReplCommand(name: "padclear", arg: "", summary: "clear MK3 pad calibration history", values: []),
            ReplCommand(name: "padfixture", arg: "", summary: "load representative pad strikes", values: []),
        ]
    }

    func handleRepl(verb: String, rest: String, _ context: LabContext) -> Bool {
        switch verb {
            case "padclear":
                context.update { [weak self] in self?.clear() }
            case "padfixture":
                context.update { [weak self] in self?.prepareSnapshot(variant: "strike") }
            default:
                return false
        }
        return true
    }

    func testState() -> String? {
        let analysis = selectedAnalysis
        return "pad=\(selectedPadIndex + 1) hits=\(midiHitCount) samples=\(hitSamples[selectedPadIndex].count)/5 pressure=\(analysis?.currentPressure ?? 0) velocity=\(analysis?.velocityValue ?? 0)"
    }

    // MARK: - Input and calibration

    private func receive(_ event: KontrolSurfacePadEvent) {
        analyzer.calibration = calibration
        selectedPadIndex = event.index
        guard hitSamples.indices.contains(event.index) else { return }

        let hit: HitSample?
        switch event.phase {
            case .touch:
                hit = HitSample(rawVelocity: event.pressure, source: .softTouch)
            case .down:
                if let strikeVelocity = event.strikeVelocity {
                    hit = HitSample(rawVelocity: strikeVelocity, source: .nativeStrike)
                } else if event.pressure > 0 {
                    hit = HitSample(rawVelocity: event.pressure, source: .pressureFallback)
                } else {
                    hit = nil
                }
            case .pressure, .up:
                hit = nil
        }

        if let hit, !sampledContacts[event.index] {
            sampledContacts[event.index] = true
            if hitSamples[event.index].count < 5 {
                hitSamples[event.index].append(hit)
            }
        }

        let triggersMIDI: Bool
        switch hit?.source {
            case .softTouch, .pressureFallback:
                triggersMIDI = hit.map { calibration.acceptsSoftHit($0.rawVelocity) } ?? false
            case .nativeStrike:
                triggersMIDI = hit != nil
            case nil:
                triggersMIDI = false
        }
        if triggersMIDI, !midiHeldPads[event.index] {
            midiHeldPads[event.index] = true
            midiHitCount += 1
        }
        if event.phase == .up {
            sampledContacts[event.index] = false
            midiHeldPads[event.index] = false
        }

        let analysis = analyzer.receive(event)
        if let hit {
            let source = switch hit.source {
                case .softTouch: "touch"
                case .pressureFallback: "pressure"
                case .nativeStrike: "native"
            }
            let result = triggersMIDI ? "note" : "ignored"
            let midi = analysis?.velocityValue.map(String.init) ?? "-"
            labDiagnostic("pad-cal P\(String(format: "%02d", event.index + 1)) sample=\(hitSamples[event.index].count)/5 source=\(source) raw=\(hit.rawVelocity) midi=\(midi) result=\(result)")
        }
    }

    private func requestRefresh(_ context: LabContext) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            guard !Task.isCancelled else { return }
            context.update { [weak self] in self?.refreshTask = nil }
        }
    }

    private func clear() {
        refreshTask?.cancel()
        refreshTask = nil
        analyzer = KontrolPadStrikeAnalyzer(calibration: calibration)
        hitSamples = [[HitSample]](repeating: [], count: 16)
        sampledContacts = [Bool](repeating: false, count: 16)
        midiHeldPads = [Bool](repeating: false, count: 16)
        selectedPadIndex = 0
        midiHitCount = 0
    }

    private func feedFixture(
        padIndex: Int,
        strikeVelocity: Int,
        pressures: [Int],
        release: Bool
    ) {
        receive(KontrolSurfacePadEvent(
            index: padIndex,
            phase: .down,
            pressure: 0,
            maximumPressure: MaschineMK3Protocol.padMaximumPressure,
            strikeVelocity: strikeVelocity,
            maximumStrikeVelocity: MaschineMK3Protocol.padMaximumStrikeVelocity,
            timestampNanos: 0
        ))
        for (sampleIndex, pressure) in pressures.enumerated() {
            receive(KontrolSurfacePadEvent(
                index: padIndex,
                phase: .pressure,
                pressure: pressure,
                maximumPressure: MaschineMK3Protocol.padMaximumPressure,
                maximumStrikeVelocity: MaschineMK3Protocol.padMaximumStrikeVelocity,
                timestampNanos: UInt64(sampleIndex + 1) * 1_000_000
            ))
        }
        if release {
            receive(KontrolSurfacePadEvent(
                index: padIndex,
                phase: .up,
                pressure: 0,
                maximumPressure: MaschineMK3Protocol.padMaximumPressure,
                maximumStrikeVelocity: MaschineMK3Protocol.padMaximumStrikeVelocity,
                timestampNanos: UInt64(pressures.count + 1) * 1_000_000
            ))
        }
    }

    private var selectedAnalysis: KontrolPadStrikeAnalysis? {
        guard analyzer.analyses.indices.contains(selectedPadIndex) else { return nil }
        return analyzer.analyses[selectedPadIndex]
    }

    private func setStrikeFloor(_ value: Int) {
        strikeFloor = max(1, min(140, value))
        analyzer.calibration = calibration
    }

    private func setStrikeCeiling(_ value: Int) {
        strikeCeiling = max(256, min(4095, value))
        analyzer.calibration = calibration
    }

    private func setPressureFloor(_ value: Int) {
        pressureFloor = max(0, min(1024, value))
        analyzer.calibration = calibration
    }

    private func setPressureCeiling(_ value: Int) {
        pressureCeiling = max(1536, min(4095, value))
        analyzer.calibration = calibration
    }

    // MARK: - LEDs

    private func padLEDBytes() -> [KontrolSurfaceDiagnosticLED: UInt8] {
        var result: [KontrolSurfaceDiagnosticLED: UInt8] = [:]
        for (index, led) in Self.padLEDs.enumerated() {
            guard let analysis = analyzer.analyses[index], analysis.isHeld else {
                result[.maschineMK3Pad(led)] = 0
                continue
            }
            let midi = analysis.currentPressure > 0
                ? Int(calibration.pressureValue(for: analysis.currentPressure))
                : Int(analysis.velocityValue ?? 1)
            let brightness = UInt8(min(3, max(1, midi * 4 / 128)))
            // Hue sector 9 is a cool cyan; RGB pads use linear brightness bits.
            result[.maschineMK3Pad(led)] = (UInt8(9) &<< 2) | brightness
        }
        return result
    }

    // MARK: - Screens

    private func padMatrixScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        let analyses = analyzer.analyses
        let samples = hitSamples
        let selected = selectedPadIndex
        let sampleCount = samples.reduce(0) { $0 + $1.count }
        return MK2RegularScreenDSL(
            header: .title(title: "MK3 Pad Calibration", subtitle: "5 hits per pad: soft to hard"),
            footer: .hint("Clear, then play Pads 1-16 at five increasing levels")
        ) {
            MK2AnyScreenElement { frame, elementContext, _ in
                guard let content = elementContext.layout?.contentRect else { return }
                let left = content.x + 8
                let top = content.y + 5
                BitmapLabel("PHYSICAL PAD MATRIX", font: .gridBold, color: Palette.text)
                    .draw(into: &frame, x: left, y: top, clip: content)
                BitmapLabel("SAMPLES \(sampleCount)/80", font: .grid, color: Palette.dim)
                    .draw(into: &frame, x: left + 318, y: top, clip: content)

                let cellWidth = 106
                let cellHeight = 37
                let gapX = 8
                let gapY = 5
                let matrixTop = top + 27
                for (row, padNumbers) in Self.panelRows.enumerated() {
                    for (column, padNumber) in padNumbers.enumerated() {
                        let index = padNumber - 1
                        let analysis = analyses[index]
                        let pressure = analysis?.currentPressure ?? 0
                        let lastHit = samples[index].last?.rawVelocity ?? 0
                        let isHeld = analysis?.isHeld == true
                        let rect = MK2PixelRect(
                            x: left + column * (cellWidth + gapX),
                            y: matrixTop + row * (cellHeight + gapY),
                            width: cellWidth,
                            height: cellHeight
                        )
                        frame.fill(rect, isHeld ? Palette.cursorFill : Palette.editFieldFill)
                        frame.stroke(rect, index == selected ? Palette.accent : Palette.border, width: index == selected ? 2 : 1)
                        BitmapLabel(String(format: "P%02d", padNumber), font: .gridBold, color: index == selected ? Palette.text : Palette.accent)
                            .draw(into: &frame, x: rect.x + 6, y: rect.y + 4, clip: rect)
                        BitmapLabel("\(samples[index].count)/5", font: .grid, color: isHeld ? Palette.text : Palette.dim)
                            .draw(into: &frame, x: rect.x + 72, y: rect.y + 4, clip: rect)
                        let track = MK2PixelRect(x: rect.x + 6, y: rect.y + 27, width: rect.width - 12, height: 5)
                        frame.fill(track, Palette.track)
                        let meterValue = pressure > 0 ? pressure : lastHit
                        let fillWidth = meterValue * track.width / MaschineMK3Protocol.padMaximumPressure
                        if fillWidth > 0 {
                            frame.fill(MK2PixelRect(x: track.x, y: track.y, width: fillWidth, height: track.height), Palette.green)
                        }
                    }
                }
            }
        }.build(renderer: context.renderer)
    }

    private func analysisScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        let analysis = selectedAnalysis
        let rawHit = analysis?.rawHitVelocity
        let rawPressure = analysis?.currentPressure ?? 0
        let velocityValue = analysis?.velocityValue
        let pressureValue = analysis?.pressureValue ?? 0
        let state = analysis.map {
            if !$0.isHeld { return "RELEASED" }
            switch $0.hitSource {
                case .softTouch: return $0.triggersMIDI ? "SOFT HIT" : "TOUCH IGNORED"
                case .pressureFallback: return $0.triggersMIDI ? "PRESSURE HIT" : "PRESSURE IGNORED"
                case .nativeStrike: return "NATIVE HIT"
                case nil: return "HELD"
            }
        } ?? "WAITING"
        let velocityRange = ">=\(strikeFloor) / \(strikeFloor) -> \(strikeCeiling)"
        let pressureRange = "\(pressureFloor) -> \(pressureCeiling)"
        let sampleText = hitSamples[selectedPadIndex]
            .map { String(format: "%d", $0.rawVelocity) }
            .joined(separator: "  ")
        let selectedSampleCount = hitSamples[selectedPadIndex].count
        let values = encoderValues(context)
        return MK2RegularScreenDSL(
            header: .title(title: "Pad \(selectedPadIndex + 1) Dynamics", subtitle: state),
            footer: .encoderArea()
        ) {
            MK2AnyScreenElement { frame, elementContext, _ in
                guard let content = elementContext.layout?.contentRect else { return }
                let left = content.x + 8
                let top = content.y + 5
                BitmapLabel("HIT VELOCITY", font: .gridBold, color: Palette.text)
                    .draw(into: &frame, x: left, y: top, clip: content)
                BitmapLabel(rawHit.map { String(format: "%4d / 4095", $0) } ?? "---- / 4095", font: .gridBold, color: Palette.accent)
                    .draw(into: &frame, x: left + 160, y: top, clip: content)
                BitmapLabel(velocityValue.map { String(format: "MIDI %3d", $0) } ?? "NO NOTE", font: .readoutBold, color: Palette.accent)
                    .draw(into: &frame, x: left + 344, y: top, clip: content)

                let strikeTrack = MK2PixelRect(x: left, y: top + 24, width: 448, height: 10)
                frame.fill(strikeTrack, Palette.track)
                let strikeWidth = (rawHit ?? 0) * strikeTrack.width / MaschineMK3Protocol.padMaximumStrikeVelocity
                if strikeWidth > 0 {
                    frame.fill(MK2PixelRect(x: strikeTrack.x, y: strikeTrack.y, width: strikeWidth, height: strikeTrack.height), Palette.accent)
                }

                BitmapLabel("POLY PRESSURE", font: .gridBold, color: Palette.text)
                    .draw(into: &frame, x: left, y: top + 52, clip: content)
                BitmapLabel(String(format: "%4d / 4095", rawPressure), font: .gridBold, color: Palette.green)
                    .draw(into: &frame, x: left + 160, y: top + 52, clip: content)
                BitmapLabel(String(format: "MIDI %3d", pressureValue), font: .readoutBold, color: Palette.green)
                    .draw(into: &frame, x: left + 344, y: top + 52, clip: content)

                let pressureTrack = MK2PixelRect(x: left, y: top + 76, width: 448, height: 10)
                frame.fill(pressureTrack, Palette.track)
                let pressureWidth = rawPressure * pressureTrack.width / MaschineMK3Protocol.padMaximumPressure
                if pressureWidth > 0 {
                    frame.fill(MK2PixelRect(x: pressureTrack.x, y: pressureTrack.y, width: pressureWidth, height: pressureTrack.height), Palette.green)
                }

                BitmapLabel("TRIGGER / VELOCITY", font: .gridBold, color: Palette.accent)
                    .draw(into: &frame, x: left, y: top + 106, clip: content)
                BitmapLabel(velocityRange, font: .grid, color: Palette.dim)
                    .draw(into: &frame, x: left + 160, y: top + 106, clip: content)
                BitmapLabel("PRESSURE CURVE", font: .gridBold, color: Palette.green)
                    .draw(into: &frame, x: left, y: top + 130, clip: content)
                BitmapLabel(pressureRange, font: .grid, color: Palette.dim)
                    .draw(into: &frame, x: left + 160, y: top + 130, clip: content)
                BitmapLabel("SAMPLES \(selectedSampleCount)/5  \(sampleText)", font: .grid, color: Palette.dim)
                    .draw(into: &frame, x: left, y: top + 150, clip: content)
            }
            MK2EncoderDiscreteValuesElement(values)
        }.build(renderer: context.renderer)
    }

    private func encoderValues(_ context: LabContext) -> [MK2EncoderDiscreteValue] {
        [
            calibrationValue(
                encoder: 5,
                value: strikeFloor,
                bounds: 1...140,
                step: 1,
                defaultValue: 8,
                label: "TRIGGER",
                icon: MK2HIG.IconGlyph.arrowLineRight,
                displayValue: "\(strikeFloor)",
                context: context,
                set: { [weak self] in self?.setStrikeFloor($0) }
            ),
            calibrationValue(
                encoder: 6,
                value: strikeCeiling,
                bounds: 256...4095,
                step: 64,
                defaultValue: 768,
                label: "V CEILING",
                icon: MK2HIG.IconGlyph.arrowLineLeft,
                displayValue: "\(strikeCeiling)",
                context: context,
                set: { [weak self] in self?.setStrikeCeiling($0) }
            ),
            calibrationValue(
                encoder: 7,
                value: pressureFloor,
                bounds: 0...1024,
                step: 32,
                defaultValue: 64,
                label: "P FLOOR",
                icon: MK2HIG.IconGlyph.arrowLineRight,
                displayValue: "\(pressureFloor)",
                context: context,
                set: { [weak self] in self?.setPressureFloor($0) }
            ),
            calibrationValue(
                encoder: 8,
                value: pressureCeiling,
                bounds: 1536...4095,
                step: 64,
                defaultValue: 3072,
                label: "P CEILING",
                icon: MK2HIG.IconGlyph.arrowLineLeft,
                displayValue: "\(pressureCeiling)",
                context: context,
                set: { [weak self] in self?.setPressureCeiling($0) }
            ),
        ]
    }

    private func calibrationValue(
        encoder: Int,
        value: Int,
        bounds: ClosedRange<Int>,
        step: Int,
        defaultValue: Int,
        label: String,
        icon: String,
        displayValue: String,
        context: LabContext,
        set: @escaping @Sendable (Int) -> Void
    ) -> MK2EncoderDiscreteValue {
        MK2EncoderDiscreteValue(
            encoder: encoder,
            value: value,
            bounds: bounds,
            step: step,
            defaultValue: defaultValue,
            display: MK2EncoderDiscreteValueDisplay(
                label: label,
                iconGlyph: icon,
                value: displayValue,
                rect: MK2ScreenLayout.encoderSlotRect(encoder - 5),
                isFocused: focusedEncoder == encoder,
                valueFont: .readoutBold,
                cornerRadius: 7,
                colors: labEditCellColors(value: Palette.text)
            ),
            onTouch: { [weak self] touched in
                context.update { [weak self] in
                    guard let demo = self else { return }
                    if touched {
                        demo.focusedEncoder = encoder
                    } else if demo.focusedEncoder == encoder {
                        demo.focusedEncoder = nil
                    }
                }
            },
            onChange: { value in
                context.update { set(max(bounds.lowerBound, min(bounds.upperBound, value))) }
            }
        )
    }
}
