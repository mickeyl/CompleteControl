import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// The multi-channel meter element: stereo horizontal with labels and peaks
/// on the left screen, four-channel vertical plus a compact horizontal block
/// on the right. The 4-D wheel scrubs the simulated programme phase, so
/// levels, peaks and the warning and danger zones can be inspected at any
/// point.
final class MeterDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "meter",
        title: "Meter",
        category: .catalogue,
        summary: "Multi-channel level meters",
        detail: "Horizontal and vertical meter elements with peak markers and warning and danger zones. The 4-D wheel scrubs the simulated programme."
    )

    private var phase = 12

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        var scene = MK2DoubleScreenDSL(
            left: overviewScreen(context),
            right: detailScreen(context)
        ).scene()
        scene.bindings.jogScroll = { [weak self] delta, _ in
            context.update {
                guard let self else { return }
                self.phase = (self.phase + delta + 3_200) % 32
            }
        }
        return scene
    }

    private func overviewScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(
            header: .title(title: "Meter", subtitle: "levels + peak"),
            footer: .hint("Ballistics stay product state; 4-D scrubs the programme."),
            progress: MK2ScreenProgressBar(placement: .top, progress: Double(phase) / 31.0)
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
                    MK2MeterChannel(label: "L", level: level(0), peak: peak(0)),
                    MK2MeterChannel(label: "R", level: level(1), peak: peak(1)),
                ],
                rect: MK2PixelRect(x: 8, y: 112, width: 420, height: 34),
                fill: Palette.green,
                dangerFill: Palette.mute
            )
            MK2ContentText("Stereo horizontal, labels leading, peak as a bright marker.", x: 8, y: 164, maxWidth: 432, color: Palette.empty)
        }.build(renderer: context.renderer)
    }

    private func detailScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(header: .title(title: "Channel Meters", subtitle: "4ch tracker")) {
            MK2MeterElement(
                channels: (0..<4).map { channel in
                    MK2MeterChannel(level: level(channel), peak: peak(channel))
                },
                rect: MK2PixelRect(x: 40, y: 16, width: 168, height: 166),
                orientation: .vertical,
                channelGap: 12,
                fill: Palette.green,
                dangerFill: Palette.mute
            )
            MK2MeterElement(
                channels: (0..<4).map { channel in
                    MK2MeterChannel(label: "CH\(channel + 1)", level: level(channel, phaseOffset: 5), peak: peak(channel, phaseOffset: 5))
                },
                rect: MK2PixelRect(x: 238, y: 22, width: 210, height: 122),
                fill: Palette.blue,
                dangerFill: Palette.mute
            )
            MK2ContentText("vertical + compact horizontal", x: 238, y: 162, maxWidth: 220, color: Palette.empty)
        }.build(renderer: context.renderer)
    }

    private func level(_ channel: Int, phaseOffset: Int = 0) -> Double {
        let wavePhase = Double((phase + channel * 7 + phaseOffset) % 32) / 31.0
        let wave = 0.5 + 0.5 * sin(wavePhase * Double.pi * 2.0)
        return min(0.98, 0.12 + wave * (0.58 + Double(channel) * 0.06))
    }

    private func peak(_ channel: Int, phaseOffset: Int = 0) -> Double {
        min(1.0, level(channel, phaseOffset: phaseOffset) + 0.14 + Double(channel) * 0.02)
    }
}
