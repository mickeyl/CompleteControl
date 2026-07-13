import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// The multi-channel meter element under live, globally approved ballistics.
/// Touch E1-E4 to punch a pulse into a channel (4-D press pulses all four);
/// E5-E8 tune the ballistics in time units, so the decay factors derive from
/// the frame rate rather than being magic constants:
///   E5 RELEASE  — bar fall time (ms to -20 dB)
///   E6 PK HOLD  — how long the peak marker holds before it falls (ms)
///   E7 PK FALL  — peak fall time once the hold expires (ms to -20 dB)
///   E8 RATE     — render/tick rate (fps)
/// The left screen shows the stereo master (a mix of the four channels).
final class MeterDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "meter",
        title: "Meter",
        category: .catalogue,
        summary: "Multi-channel level meters",
        detail: "Meter elements with switchable visual styles under the globally approved ballistics. INSTANCE cycles styles; SHIFT+INSTANCE toggles peak hold. Touch E1-E4 to pulse a channel (4-D press all four); E5-E8 retain the calibration rig.",
        snapshotVariants: ["gradient", "segmented", "protracker", "protracker-no-peak"]
    )

    // The ballistics transformation now lives in the Kit (`MK2MeterBallistics`);
    // this demo only owns the four channel states and the time driver.
    private var ballistics = [MK2MeterBallistics](repeating: MK2MeterBallistics(), count: 4)
    private var pulseSeed = 0
    private var settled = true
    private var animationTask: Task<Void, Never>?

    // The render/tick rate stays a demo knob (E8): it drives the loop, not the
    // ballistics, which are rate-independent and take the tick interval directly.
    private var frameRate = MK2HIG.Meter.Ballistics.referenceFrameRate
    private var focusedEncoder: Int?
    private var meterStyle: MK2MeterElement.Style = .solid
    private var showsPeak = true

    private var tickMs: Int { max(4, 1000 / max(1, frameRate)) }

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        var scene = MK2DoubleScreenDSL(
            left: overviewScreen(context),
            right: detailScreen(context)
        ).scene()
        for channel in 0..<4 {
            scene.bindings.encoderTouch[channel + 1] = { [weak self] touched in
                guard touched else { return }
                self?.pulse([channel], context)
            }
        }
        scene.bindings.jogCenter = { [weak self] in
            self?.pulse(Array(0..<4), context)
        }
        scene.lamps[.instance] = .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01)
        scene.bindings.onPress(.instance, modifiers: .unmodified) { [weak self] in
            context.update { [weak self] in self?.cycleStyle() }
        }
        scene.bindings.onPress(.instance, modifiers: .shift) { [weak self] in
            context.update { [weak self] in self?.showsPeak.toggle() }
        }
        return scene
    }

    func prepareSnapshot(variant: String) {
        setFixtureLevels()
        meterStyle = MK2MeterElement.Style(rawValue: variant.replacingOccurrences(of: "-no-peak", with: "")) ?? .solid
        showsPeak = !variant.hasSuffix("-no-peak")
    }

    func demoWillClose() {
        animationTask?.cancel()
        animationTask = nil
    }

    func replCommands() -> [ReplCommand] {
        [
            ReplCommand(name: "meterstyle", arg: "solid|gradient|segmented|protracker|next", summary: "select meter rendering style", values: MK2MeterElement.Style.allCases.map(\.rawValue) + ["next"]),
            ReplCommand(name: "meterpeak", arg: "on|off|toggle", summary: "show or hide peak markers", values: ["on", "off", "toggle"]),
            ReplCommand(name: "meterpulse", arg: "", summary: "pulse all meter channels", values: []),
            ReplCommand(name: "meterfixture", arg: "", summary: "hold representative meter levels", values: []),
        ]
    }

    func handleRepl(verb: String, rest: String, _ context: LabContext) -> Bool {
        switch verb {
            case "meterstyle":
                context.update { [weak self] in
                    guard let self else { return }
                    if let style = MK2MeterElement.Style(rawValue: rest.lowercased()) {
                        self.meterStyle = style
                    } else {
                        self.cycleStyle()
                    }
                }
            case "meterpeak":
                context.update { [weak self] in
                    guard let self else { return }
                    switch rest.lowercased() {
                        case "on": self.showsPeak = true
                        case "off": self.showsPeak = false
                        default: self.showsPeak.toggle()
                    }
                }
            case "meterpulse":
                pulse(Array(0..<4), context)
            case "meterfixture":
                context.update { [weak self] in self?.setFixtureLevels() }
            default:
                return false
        }
        return true
    }

    // MARK: - Ballistics

    private func pulse(_ channels: [Int], _ context: LabContext) {
        context.update {
            for channel in channels where self.ballistics.indices.contains(channel) {
                self.ballistics[channel].pulse(self.nextImpact())
            }
            self.settled = false
        }
        startAnimation(context)
    }

    /// Golden-ratio walk instead of `Math.random` (unavailable in this harness),
    /// so repeated pulses vary a little.
    private func nextImpact() -> Double {
        pulseSeed += 1
        let fraction = (Double(pulseSeed) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1.0)
        return 0.80 + 0.20 * fraction
    }

    private func startAnimation(_ context: LabContext) {
        guard animationTask == nil else { return }
        animationTask = Task { [weak self] in
            repeat {
                let ms = self?.tickMs ?? 20
                try? await Task.sleep(for: .milliseconds(ms))
                context.update { [weak self] in self?.stepDecay() }
            } while self?.settled == false && !Task.isCancelled
            self?.animationTask = nil
        }
    }

    private func stepDecay() {
        let tick = tickMs
        var moving = false
        for index in ballistics.indices where ballistics[index].step(tickMilliseconds: tick) {
            moving = true
        }
        settled = !moving
    }

    private func masterLevel(_ side: Int) -> Double {
        side == 0 ? max(ballistics[0].level, ballistics[2].level) : max(ballistics[1].level, ballistics[3].level)
    }

    private func masterPeak(_ side: Int) -> Double {
        side == 0 ? max(ballistics[0].peak, ballistics[2].peak) : max(ballistics[1].peak, ballistics[3].peak)
    }

    /// Set a ballistics parameter across all four channels (the calibration
    /// encoders tune them together).
    private func setBallisticsParameter(_ keyPath: WritableKeyPath<MK2MeterBallistics, Int>, _ value: Int) {
        for index in ballistics.indices {
            ballistics[index][keyPath: keyPath] = value
        }
    }

    private func cycleStyle() {
        let styles = MK2MeterElement.Style.allCases
        guard let index = styles.firstIndex(of: meterStyle) else {
            meterStyle = .solid
            return
        }
        meterStyle = styles[(index + 1) % styles.count]
    }

    private func setFixtureLevels() {
        animationTask?.cancel()
        animationTask = nil
        let fixture = [0.72, 0.45, 0.93, 0.30]
        for (index, level) in fixture.enumerated() {
            ballistics[index].hold(level: level, peak: min(1.0, level + 0.06))
        }
        settled = true
    }

    // MARK: - Screens

    private func overviewScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(
            header: .title(title: "Meter", subtitle: meterStyle.rawValue),
            footer: .hint("INSTANCE style · SHIFT+INSTANCE peak \(showsPeak ? "on" : "off")")
        ) {
            MK2ContentText("Meter Elements", x: 8, y: 0, role: .title)
            MK2ContentText(
                "Multi-channel levels, peak markers and warning colours run as ordinary screen DSL elements.",
                x: 8,
                y: 40,
                maxWidth: 432,
                color: Palette.dim,
                maxLines: 2,
                lineSpacing: 2
            )
            MK2MeterElement(
                channels: [
                    MK2MeterChannel(label: "L", level: masterLevel(0), peak: masterPeak(0)),
                    MK2MeterChannel(label: "R", level: masterLevel(1), peak: masterPeak(1)),
                ],
                rect: MK2PixelRect(x: 8, y: 112, width: 420, height: 34),
                fill: MK2HIG.Meter.normal,
                warningFill: MK2HIG.Meter.warning,
                dangerFill: MK2HIG.Meter.danger,
                warningThreshold: MK2HIG.Meter.ProTracker.yellowPosition,
                dangerThreshold: MK2HIG.Meter.ProTracker.redPosition,
                style: meterStyle,
                showsPeak: showsPeak
            )
            MK2ContentText("Stereo master, a mix of the four channels — peak as a bright marker.", x: 8, y: 164, maxWidth: 432, color: Palette.empty)
        }.build(renderer: context.renderer)
    }

    private func detailScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(header: .title(title: "Ballistics", subtitle: meterStyle.rawValue)) {
            MK2MeterElement(
                channels: (0..<4).map { channel in
                    MK2MeterChannel(label: "CH\(channel + 1)", level: ballistics[channel].level, peak: ballistics[channel].peak)
                },
                rect: MK2PixelRect(x: 32, y: 6, width: 416, height: 148),
                orientation: .vertical,
                channelGap: 16,
                fill: MK2HIG.Meter.normal,
                warningFill: MK2HIG.Meter.warning,
                dangerFill: MK2HIG.Meter.danger,
                warningThreshold: MK2HIG.Meter.ProTracker.yellowPosition,
                dangerThreshold: MK2HIG.Meter.ProTracker.redPosition,
                style: meterStyle,
                showsPeak: showsPeak
            )
            MK2EncoderDiscreteValuesElement(encoderValues(context))
        }.build(renderer: context.renderer)
    }

    private func encoderValues(_ context: LabContext) -> [MK2EncoderDiscreteValue] {
        [
            calibrationValue(encoder: 5, value: ballistics[0].releaseMilliseconds, bounds: 50...1200, defaultValue: MK2HIG.Meter.Ballistics.releaseMilliseconds, label: "RELEASE", icon: MK2HIG.IconGlyph.waveSine, unit: "MS", context: context) { [weak self] in self?.setBallisticsParameter(\.releaseMilliseconds, $0) },
            calibrationValue(encoder: 6, value: ballistics[0].peakHoldMilliseconds, bounds: 0...2000, defaultValue: MK2HIG.Meter.Ballistics.peakHoldMilliseconds, label: "PK HOLD", icon: MK2HIG.IconGlyph.timer, unit: "MS", context: context) { [weak self] in self?.setBallisticsParameter(\.peakHoldMilliseconds, $0) },
            calibrationValue(encoder: 7, value: ballistics[0].peakFallMilliseconds, bounds: 200...4000, defaultValue: MK2HIG.Meter.Ballistics.peakFallMilliseconds, label: "PK FALL", icon: MK2HIG.IconGlyph.arrowsDownUp, unit: "MS", context: context) { [weak self] in self?.setBallisticsParameter(\.peakFallMilliseconds, $0) },
            calibrationValue(encoder: 8, value: frameRate, bounds: 20...120, defaultValue: MK2HIG.Meter.Ballistics.referenceFrameRate, label: "RATE", icon: MK2HIG.IconGlyph.gauge, unit: "FPS", context: context) { [weak self] in self?.frameRate = $0 },
        ]
    }

    private func calibrationValue(
        encoder: Int,
        value: Int,
        bounds: ClosedRange<Int>,
        defaultValue: Int,
        label: String,
        icon: String,
        unit: String,
        context: LabContext,
        set: @escaping @Sendable (Int) -> Void
    ) -> MK2EncoderDiscreteValue {
        MK2EncoderDiscreteValue(
            encoder: encoder,
            value: value,
            bounds: bounds,
            defaultValue: defaultValue,
            display: MK2EncoderDiscreteValueDisplay(
                label: label,
                iconGlyph: icon,
                value: "\(value) \(unit)",
                rect: MK2ScreenLayout.encoderSlotRect(encoder - 5),
                isFocused: focusedEncoder == encoder,
                valueFont: .readoutBold,
                cornerRadius: 7,
                colors: labEditCellColors(value: Palette.text)
            ),
            onTouch: { [weak self] touched in
                context.update { [weak self] in
                    guard let self else { return }
                    if touched { self.focusedEncoder = encoder } else if self.focusedEncoder == encoder { self.focusedEncoder = nil }
                }
            },
            onChange: { value in
                context.update { set(max(bounds.lowerBound, min(bounds.upperBound, value))) }
            }
        )
    }
}
