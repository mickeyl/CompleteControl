import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// Double-screen panoramas for hardware calibration: a generated wave
/// artwork and the photographic AboutHero image span both displays plus a
/// configurable count of virtual bezel-gap columns, so the right constant
/// for the physical display gap can be judged on the device. E7 dials the
/// gap, E8 the brightness; INSTANCE toggles the image source.
final class PanoramaDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "panorama",
        title: "Panorama & Bezel Gap",
        category: .calibration,
        summary: "Cross-display artwork, gap calibration",
        detail: "A generated wave panorama and the AboutHero photo across both screens. E7 dials the virtual bezel-gap columns, E8 the brightness; INSTANCE toggles the image.",
        snapshotVariants: ["hero"]
    )

    private enum Source { case waves, hero }

    private var source: Source = .waves
    private var gapColumns = 53
    private var brightnessPercent = 42
    private var focusedEncoder: Int?
    private var cachedWaves: MK2PixelImage?
    private var cachedWavesGap = -1
    private var cachedHero: MK2PixelImage?
    private var cachedHeroGap = -1
    private var renderTask: Task<Void, Never>?
    private var renderPending = false

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        var scene = MK2DoubleScreenDSL(
            left: leftScreen(context),
            right: rightScreen(context)
        ).scene()
        scene.lamps[.instance] = .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01)
        scene.bindings.onPress(.instance) { [weak self] in
            context.update { self?.source = self?.source == .waves ? .hero : .waves }
        }
        // Raw delta bindings with a render throttle: every encoder count lands
        // in the value immediately, but the expensive part (panorama
        // regeneration plus two full-screen draws) runs at most a few times
        // per second with a trailing render, so fast turns cannot queue work.
        scene.bindings.encoderTouch[7] = { [weak self] touched in
            context.update { self?.focus(7, touched) }
        }
        scene.bindings.rawEncoder[7] = { [weak self] delta, _, _ in
            self?.adjust(context) { demo in
                demo.gapColumns = max(0, min(128, demo.gapColumns + delta))
            }
        }
        scene.bindings.encoderTouch[8] = { [weak self] touched in
            context.update { self?.focus(8, touched) }
        }
        scene.bindings.rawEncoder[8] = { [weak self] delta, _, _ in
            self?.adjust(context) { demo in
                demo.brightnessPercent = max(0, min(100, demo.brightnessPercent + delta))
            }
        }
        return scene
    }

    func prepareSnapshot(variant: String) {
        source = variant == "hero" ? .hero : .waves
    }

    private func leftScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        let brightness = Double(brightnessPercent) / 100.0
        return MK2FullScreenDSL(background: Palette.page) {
            switch source {
                case .waves:
                    MK2ImageElement(wavesPanorama(), x: 0, brightness: brightness)
                    MK2ContentText("PAULINCHE", x: 0, y: 88, maxWidth: 480, role: .title, alignment: .center)
                    MK2ContentText("AMIGA MOD TRACKER", x: 0, y: 128, maxWidth: 480, color: Palette.dim, alignment: .center)
                    MK2ContentText("VERSION 0.1 — KONTROLSURFACEKIT2", x: 0, y: 244, maxWidth: 480, role: .footnote, color: Palette.dim, alignment: .center)
                case .hero:
                    if let hero = heroPanorama() {
                        MK2ImageElement(hero, x: 0, brightness: brightness)
                    } else {
                        MK2ContentText("AboutHero.png missing from bundle", x: 0, y: 128, maxWidth: 480, color: Palette.orange, alignment: .center)
                    }
            }
        }.build(renderer: context.renderer)
    }

    private func rightScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        let brightness = Double(brightnessPercent) / 100.0
        let displays = encoderDisplays()
        return MK2FullScreenDSL(background: Palette.page) {
            switch source {
                case .waves:
                    MK2ImageElement(wavesPanorama(), x: MK2PixelFrame.width - wavesPanorama().width, brightness: brightness)
                case .hero:
                    if let hero = heroPanorama() {
                        MK2ImageElement(hero, x: MK2PixelFrame.width - hero.width, brightness: brightness)
                    }
            }
            MK2EncoderFooterElement(displays)
        }.build(renderer: context.renderer)
    }

    private func wavesPanorama() -> MK2PixelImage {
        if let cachedWaves, cachedWavesGap == gapColumns { return cachedWaves }
        let width = MK2PixelFrame.width * 2 + gapColumns
        let height = MK2PixelFrame.height
        var pixels = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            let t = Double(y) / Double(height - 1)
            let r = 3.0 * (1 - t)
            let g = 10.0 * (1 - t)
            let b = 20.0 * (1 - t) + 2
            for x in 0..<width {
                pixels[y * width + x] = MK2OrderedDither.rgb565(r: r, g: g, b: b, x: x, y: y)
            }
        }
        func plot(x: Int, y: Int, height waveHeight: Int, color: UInt16) {
            for row in y..<(y + waveHeight) where row >= 0 && row < height {
                pixels[row * width + x] = color
            }
        }
        for x in 0..<width {
            let phase = Double(x) / Double(MK2PixelFrame.width) * .pi * 4
            let y1 = 136 + Int((sin(phase) * 78).rounded())
            let y2 = 136 + Int((sin(phase + 1.2) * 52).rounded())
            plot(x: x, y: y1 - 1, height: 3, color: Palette.green)
            plot(x: x, y: y2, height: 2, color: Palette.solo)
        }
        let image = MK2PixelImage(width: width, height: height, pixels: pixels)
        cachedWaves = image
        cachedWavesGap = gapColumns
        return image
    }

    private func heroPanorama() -> MK2PixelImage? {
        if let cachedHero, cachedHeroGap == gapColumns { return cachedHero }
        let decoded = Bundle.module.url(forResource: "AboutHero", withExtension: "png")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { MK2PixelImage(data: $0, width: MK2PixelFrame.width * 2 + gapColumns, height: MK2PixelFrame.height, scaling: .fill) }
        cachedHero = decoded
        cachedHeroGap = gapColumns
        return decoded
    }

    private func focus(_ encoder: Int, _ touched: Bool) {
        if touched {
            focusedEncoder = encoder
        } else if focusedEncoder == encoder {
            focusedEncoder = nil
        }
    }

    /// Applies the mutation immediately, but coalesces the expensive
    /// re-render onto a 250 ms trailing loop.
    private func adjust(_ context: LabContext, _ mutation: @escaping @Sendable (PanoramaDemo) -> Void) {
        context.mutate { [weak self] in
            guard let self else { return }
            mutation(self)
        }
        guard renderTask == nil else {
            renderPending = true
            return
        }
        renderTask = Task { [weak self] in
            repeat {
                self?.renderPending = false
                context.update {}
                try? await Task.sleep(for: .milliseconds(250))
            } while self?.renderPending == true
            self?.renderTask = nil
        }
    }

    private func encoderDisplays() -> [MK2EncoderDiscreteValueDisplay] {
        let entries: [(label: String, icon: String, value: String, encoder: Int, slot: Int)] = [
            ("GAP", MK2HIG.IconGlyph.arrowsOutLineHorizontal, "\(gapColumns)", 7, 2),
            ("BRIGHT", MK2HIG.IconGlyph.sun, "\(brightnessPercent)%", 8, 3),
        ]
        return entries.map { entry in
            MK2EncoderDiscreteValueDisplay(
                label: entry.label,
                iconGlyph: entry.icon,
                value: entry.value,
                rect: MK2ScreenLayout.encoderSlotRect(entry.slot),
                isFocused: focusedEncoder == entry.encoder,
                valueFont: .readoutBold,
                cornerRadius: 7,
                colors: labEditCellColors(value: Palette.text)
            )
        }
    }
}
