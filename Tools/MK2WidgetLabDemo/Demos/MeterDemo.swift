import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// The multi-channel meter element under live, tunable ballistics — the
/// calibration rig for the meter attack/decay before it moves into the Kit.
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
        detail: "Meter elements with peak markers and warning/danger zones under tunable ballistics. Touch E1-E4 to pulse a channel (4-D press all four); E5-E8 calibrate release, peak hold, peak fall and frame rate."
    )

    private static let silence = 0.003
    /// Decay to a tenth (−20 dB) over the configured time; deriving the factor
    /// from time + tick keeps the feel rate-independent.
    private static let decayFloor = 0.1

    private var levels = [Double](repeating: 0, count: 4)
    private var peaks = [Double](repeating: 0, count: 4)
    private var holdTicks = [Int](repeating: 0, count: 4)
    private var pulseSeed = 0
    private var settled = true
    private var animationTask: Task<Void, Never>?

    // Tunable ballistics (E5-E8), in time units.
    private var releaseMs = 360
    private var peakHoldMs = 300
    private var peakFallMs = 1500
    private var frameRate = 50
    private var focusedEncoder: Int?

    private var tickMs: Int { max(4, 1000 / max(1, frameRate)) }
    private var levelDecay: Double { pow(Self.decayFloor, Double(tickMs) / Double(max(1, releaseMs))) }
    private var peakDecay: Double { pow(Self.decayFloor, Double(tickMs) / Double(max(1, peakFallMs))) }
    private var holdTickCount: Int { peakHoldMs / max(1, tickMs) }

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
        return scene
    }

    func prepareSnapshot(variant: String) {
        levels = [0.72, 0.45, 0.93, 0.30]
        peaks = levels.map { min(1.0, $0 + 0.06) }
        settled = true
    }

    func demoWillClose() {
        animationTask?.cancel()
        animationTask = nil
    }

    // MARK: - Ballistics

    private func pulse(_ channels: [Int], _ context: LabContext) {
        context.update {
            for channel in channels where self.levels.indices.contains(channel) {
                let impact = self.nextImpact()
                self.levels[channel] = impact
                self.peaks[channel] = max(self.peaks[channel], impact)
                self.holdTicks[channel] = self.holdTickCount
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
                context.update { self?.stepDecay() }
            } while self?.settled == false && !Task.isCancelled
            self?.animationTask = nil
        }
    }

    private func stepDecay() {
        let levelDecay = self.levelDecay
        let peakDecay = self.peakDecay
        var moving = false
        for index in levels.indices {
            levels[index] *= levelDecay
            if levels[index] < Self.silence { levels[index] = 0 } else { moving = true }

            if holdTicks[index] > 0 {
                holdTicks[index] -= 1
                peaks[index] = max(peaks[index], levels[index])
                moving = true
            } else {
                peaks[index] = max(levels[index], peaks[index] * peakDecay)
            }
            if peaks[index] < Self.silence { peaks[index] = 0 } else { moving = true }
        }
        settled = !moving
    }

    private func masterLevel(_ side: Int) -> Double {
        side == 0 ? max(levels[0], levels[2]) : max(levels[1], levels[3])
    }

    private func masterPeak(_ side: Int) -> Double {
        side == 0 ? max(peaks[0], peaks[2]) : max(peaks[1], peaks[3])
    }

    // MARK: - Screens

    private func overviewScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(
            header: .title(title: "Meter", subtitle: "live ballistics"),
            footer: .hint("Touch E1-E4 to pulse a channel; 4-D press pulses all four.")
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
                fill: Palette.green,
                dangerFill: Palette.mute
            )
            MK2ContentText("Stereo master, a mix of the four channels — peak as a bright marker.", x: 8, y: 164, maxWidth: 432, color: Palette.empty)
        }.build(renderer: context.renderer)
    }

    private func detailScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(header: .title(title: "Ballistics", subtitle: "E5-E8 calibrate")) {
            MK2MeterElement(
                channels: (0..<4).map { channel in
                    MK2MeterChannel(label: "CH\(channel + 1)", level: levels[channel], peak: peaks[channel])
                },
                rect: MK2PixelRect(x: 32, y: 6, width: 416, height: 148),
                orientation: .vertical,
                channelGap: 16,
                fill: Palette.green,
                dangerFill: Palette.mute
            )
            MK2EncoderDiscreteValuesElement(encoderValues(context))
        }.build(renderer: context.renderer)
    }

    private func encoderValues(_ context: LabContext) -> [MK2EncoderDiscreteValue] {
        [
            calibrationValue(encoder: 5, value: releaseMs, bounds: 50...1200, defaultValue: 360, label: "RELEASE", icon: MK2HIG.IconGlyph.waveSine, unit: "MS", context: context) { [weak self] in self?.releaseMs = $0 },
            calibrationValue(encoder: 6, value: peakHoldMs, bounds: 0...2000, defaultValue: 300, label: "PK HOLD", icon: MK2HIG.IconGlyph.timer, unit: "MS", context: context) { [weak self] in self?.peakHoldMs = $0 },
            calibrationValue(encoder: 7, value: peakFallMs, bounds: 200...4000, defaultValue: 1500, label: "PK FALL", icon: MK2HIG.IconGlyph.arrowsDownUp, unit: "MS", context: context) { [weak self] in self?.peakFallMs = $0 },
            calibrationValue(encoder: 8, value: frameRate, bounds: 20...120, defaultValue: 50, label: "RATE", icon: MK2HIG.IconGlyph.gauge, unit: "FPS", context: context) { [weak self] in self?.frameRate = $0 },
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
                context.update {
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
