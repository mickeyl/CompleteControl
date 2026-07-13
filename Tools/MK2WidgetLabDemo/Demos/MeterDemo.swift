import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// The multi-channel meter element under live ballistics: touch E1-E4 to punch
/// a pulse into a channel and watch the level shoot up and decay, with the
/// peak marker holding and falling slower. The left screen shows the stereo
/// master (a mix of the four channels), the right the four channels vertical
/// plus a compact horizontal block. 4-D press pulses all four at once — a
/// deliberate stress case for smoothness.
final class MeterDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "meter",
        title: "Meter",
        category: .catalogue,
        summary: "Multi-channel level meters",
        detail: "Horizontal and vertical meter elements with peak markers and warning and danger zones. Touch E1-E4 to pulse a channel and watch the ballistics decay; 4-D press pulses all four."
    )

    // Level ballistics per tick: the bar drops fast, the peak marker holds and
    // falls slowly, so a single pulse reads as a clear attack-and-decay.
    private static let levelDecay = 0.88
    private static let peakDecay = 0.985
    private static let silence = 0.003
    private static let tickMilliseconds = 20

    private var levels = [Double](repeating: 0, count: 4)
    private var peaks = [Double](repeating: 0, count: 4)
    private var pulseSeed = 0
    private var settled = true
    private var animationTask: Task<Void, Never>?

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
        // A static frame for the snapshot: live it opens silent and the user
        // pulses it.
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
                try? await Task.sleep(for: .milliseconds(Self.tickMilliseconds))
                context.update { self?.stepDecay() }
            } while self?.settled == false && !Task.isCancelled
            self?.animationTask = nil
        }
    }

    private func stepDecay() {
        var moving = false
        for index in levels.indices {
            levels[index] *= Self.levelDecay
            if levels[index] < Self.silence { levels[index] = 0 } else { moving = true }
            peaks[index] = max(levels[index], peaks[index] * Self.peakDecay)
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
        MK2RegularScreenDSL(header: .title(title: "Channel Meters", subtitle: "4ch tracker")) {
            MK2MeterElement(
                channels: (0..<4).map { channel in
                    MK2MeterChannel(level: levels[channel], peak: peaks[channel])
                },
                rect: MK2PixelRect(x: 40, y: 16, width: 168, height: 166),
                orientation: .vertical,
                channelGap: 12,
                fill: Palette.green,
                dangerFill: Palette.mute
            )
            MK2MeterElement(
                channels: (0..<4).map { channel in
                    MK2MeterChannel(label: "CH\(channel + 1)", level: levels[channel], peak: peaks[channel])
                },
                rect: MK2PixelRect(x: 238, y: 22, width: 210, height: 122),
                fill: Palette.blue,
                dangerFill: Palette.mute
            )
            MK2ContentText("vertical + compact horizontal", x: 238, y: 162, maxWidth: 220, color: Palette.empty)
        }.build(renderer: context.renderer)
    }
}
