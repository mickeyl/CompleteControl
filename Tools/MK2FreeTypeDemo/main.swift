import Foundation
import Darwin
import KompleteKontrol
import KontrolSurfaceKit2

@main
struct MK2FreeTypeDemo {
    static func main() async {
        do {
            let surface = MK2Surface2(options: .init(tickHz: 30))
            let demo = try FreeTypeDemo(surface: surface)
            demo.printHelp()
            fflush(stdout)
            await surface.start()
            await demo.render()

            for await state in await surface.connectionStates {
                switch state {
                    case .evicted:
                        log("evicted by another surface client — quitting")
                        exit(0)
                    case let .retrying(reason):
                        log("surface: retrying (\(reason))")
                    case let .connected(detail):
                        log("surface: connected (\(detail))")
                        await demo.render()
                    case .stopped:
                        log("surface: stopped")
                }
            }
        } catch {
            fputs("MK2FreeTypeDemo: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func log(_ message: String) {
        print(message)
        fflush(stdout)
    }
}

private actor FreeTypeDemo {
    private let surface: MK2Surface2
    private let renderer: FreeTypeTextRenderer
    private let catalog = FreeTypeFontCatalog.exploratory
    private let weights = FreeTypeFontWeight.allCases
    private let rasterModes = FreeTypeRasterMode.allCases
    private let sizes = [12, 14, 16, 18, 20, 22, 24, 28, 32, 36, 42, 48, 56, 64]
    private let samples = [
        "Complete Control",
        "Browser: Piano Noir",
        "Settings und lange Texte",
        "0123456789 BPM dB Hz",
        "Icons: \u{25C0} \u{25B6} \u{25A0} \u{25CF} \u{2605}",
    ]

    private var familyIndex = 0
    private var weightIndex = 1
    private var sizeIndex = 8
    private var sampleIndex = 0
    private var rasterModeIndex = 0

    init(surface: MK2Surface2) throws {
        self.surface = surface
        self.renderer = try FreeTypeTextRenderer(catalog: catalog)
    }

    nonisolated func printHelp() {
        let catalog = FreeTypeFontCatalog.exploratory
        let families = catalog.families.enumerated()
            .map { "F\($0.offset + 1)=\($0.element.label)" }
            .joined(separator: ", ")
        let weights = FreeTypeFontWeight.allCases.map(\.label).joined(separator: ", ")
        let rasterModes = FreeTypeRasterMode.allCases.map(\.label).joined(separator: ", ")

        print("""
        MK2FreeTypeDemo — hardware controls

        Font selection:
          Page Left / Page Right       previous / next font family
          F1-F3 lamps                  selected family is bright blue; other available families are dim

        Weight, size, raster:
          Browser / Instance           previous / next weight
          Preset Down / Preset Up      smaller / larger pixel size
          Plugin                       cycle raster mode

        Samples:
          Mixer                        cycle sample text

        Lamp states:
          Dim white                    action is available
          Off                          range edge reached, no action
          Bright white                 momentary mode/sample action
          Bright blue                  active font family

        Families:
          \(families)

        Weights:
          \(weights)

        Sizes:
          12, 14, 16, 18, 20, 22, 24, 28, 32, 36, 42, 48, 56, 64 px

        Raster modes:
          \(rasterModes)

        Recommended OLED default:
          Gray hinted. LCD/subpixel rendering is intentionally not used for the MK2 OLED/RGB565 path.
        """)
    }

    func render() async {
        await surface.present(scene())
    }

    private var family: FreeTypeFontFamily { catalog.families[familyIndex] }
    private var weight: FreeTypeFontWeight { weights[weightIndex] }
    private var pixelSize: Int { sizes[sizeIndex] }
    private var sample: String { samples[sampleIndex] }
    private var rasterMode: FreeTypeRasterMode { rasterModes[rasterModeIndex] }

    private func scene() -> MK2SurfaceScene2 {
        var bindings = MK2InputBindings2()
        var lamps = stateLamps()
        applyRangeControl(
            value: familyIndex,
            bounds: 0...(catalog.families.count - 1),
            previousButton: .pageLeft,
            nextButton: .pageRight,
            lamps: &lamps,
            bindings: &bindings
        ) { [weak self] index in
            Task { await self?.setFamilyIndex(index) }
        }
        applyRangeControl(
            value: weightIndex,
            bounds: 0...(weights.count - 1),
            previousButton: .browser,
            nextButton: .instance,
            lamps: &lamps,
            bindings: &bindings
        ) { [weak self] index in
            Task { await self?.setWeightIndex(index) }
        }
        applyRangeControl(
            value: sizeIndex,
            bounds: 0...(sizes.count - 1),
            previousButton: .presetDown,
            nextButton: .presetUp,
            lamps: &lamps,
            bindings: &bindings
        ) { [weak self] index in
            Task { await self?.setSizeIndex(index) }
        }
        lamps[.mixer] = Self.availableLamp
        bindings.onPress(.mixer) { [weak self] in
            Task { await self?.nextSample() }
        }
        lamps[.plugin] = Self.activeWhiteLamp
        bindings.onPress(.plugin) { [weak self] in
            Task { await self?.nextRasterMode() }
        }

        return MK2SurfaceScene2(left: leftFrame(), right: rightFrame(), lamps: lamps, bindings: bindings)
    }

    private static var availableLamp: MK2LampState2 {
        .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01)
    }

    private static var activeLamp: MK2LampState2 {
        .on(KKRGB(red: 0x00, green: 0x7f, blue: 0xff), intensity: 0x03)
    }

    private static var activeWhiteLamp: MK2LampState2 {
        .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x03)
    }

    private func stateLamps() -> [KKMK2ButtonLED: MK2LampState2] {
        var lamps: [KKMK2ButtonLED: MK2LampState2] = [:]
        for index in catalog.families.indices {
            guard let led = KKMK2ButtonLED(rawValue: KKMK2ButtonLED.function1.rawValue + index) else { continue }
            lamps[led] = index == familyIndex ? Self.activeLamp : Self.availableLamp
        }
        return lamps
    }

    private func applyRangeControl(
        value: Int,
        bounds: ClosedRange<Int>,
        previousButton: KKMK2ButtonLED,
        nextButton: KKMK2ButtonLED,
        lamps: inout [KKMK2ButtonLED: MK2LampState2],
        bindings: inout MK2InputBindings2,
        onSelect: @escaping @Sendable (_ value: Int) -> Void
    ) {
        MK2ButtonRangeSelection(
            value: value,
            bounds: bounds,
            previousButton: previousButton,
            nextButton: nextButton,
            availableLamp: Self.availableLamp,
            onSelect: onSelect
        ).apply(lamps: &lamps, bindings: &bindings)
    }

    private func setFamilyIndex(_ index: Int) async {
        familyIndex = index
        await render()
    }

    private func setWeightIndex(_ index: Int) async {
        weightIndex = index
        await render()
    }

    private func setSizeIndex(_ index: Int) async {
        sizeIndex = index
        await render()
    }

    private func nextSample() async {
        sampleIndex = (sampleIndex + 1).wrapped(to: 0...(samples.count - 1))
        await render()
    }

    private func nextRasterMode() async {
        rasterModeIndex = (rasterModeIndex + 1).wrapped(to: 0...(rasterModes.count - 1))
        await render()
    }

    private func leftFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.background)
        drawBitmapHeader(into: &frame, title: "FREETYPE DEMO", subtitle: "grayscale AA, bitmap grid untouched")

        let title = style(weight: weight, size: pixelSize, color: Palette.text)
        let secondary = style(weight: .regular, size: 17, color: Palette.dim)
        let small = style(weight: .text, size: 14, color: Palette.muted)

        try? renderer.drawText(sample, into: &frame, x: 18, y: 58, style: title, maxWidth: 444)
        try? renderer.drawText("Family \(familyIndex + 1)/\(catalog.families.count): \(family.label)", into: &frame, x: 18, y: 146, style: secondary)
        try? renderer.drawText("Weight: \(weight.label)   Size: \(pixelSize) px", into: &frame, x: 18, y: 174, style: secondary)
        try? renderer.drawText("Raster: \(rasterMode.label)", into: &frame, x: 18, y: 200, style: secondary)
        try? renderer.drawText("Page family | Browser/Instance weight | Preset size", into: &frame, x: 18, y: 224, style: small, maxWidth: 444)
        try? renderer.drawText("Plugin raster | Mixer sample", into: &frame, x: 18, y: 240, style: small, maxWidth: 444)
        BitmapLabel("BITMAP LABEL 0123456789", font: .grid, color: Palette.bitmap)
            .draw(into: &frame, x: 18, y: 256)
        return frame
    }

    private func rightFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.panel)
        drawBitmapHeader(into: &frame, title: "SPECIMEN", subtitle: family.label)

        var y = 56
        for size in [14, 18, 24, 32, 42] {
            let specimenStyle = style(weight: weight, size: size, color: Palette.text)
            try? renderer.drawText("\(size) px  \(weight.label)", into: &frame, x: 18, y: y, style: specimenStyle, maxWidth: 440)
            y += size + 14
        }

        let uiStyle = style(weight: .regular, size: 16, color: Palette.dim)
        try? renderer.drawText("Listen, Dialoge, Browser und Settings koennen hier weich wirken.", into: &frame, x: 18, y: 238, style: uiStyle, maxWidth: 440)
        return frame
    }

    private func style(weight: FreeTypeFontWeight, size: Int, color: UInt16) -> FreeTypeTextStyle {
        FreeTypeTextStyle(
            familyID: family.id,
            weight: weight,
            pixelSize: size,
            color: color,
            rasterMode: rasterMode
        )
    }

    private func drawBitmapHeader(into frame: inout MK2PixelFrame, title: String, subtitle: String) {
        frame.fill(MK2PixelRect(x: 0, y: 0, width: MK2PixelFrame.width, height: 38), Palette.header)
        BitmapLabel(title, font: .gridBold, color: Palette.accent).draw(into: &frame, x: 8, y: 8)
        BitmapLabel(subtitle.uppercased(), font: .label, color: Palette.dim).draw(into: &frame, x: 8, y: 25)
    }
}

private enum Palette {
    static let background: UInt16 = 0x0841
    static let panel: UInt16 = 0x1082
    static let header: UInt16 = 0x0000
    static let text: UInt16 = 0xffff
    static let dim: UInt16 = 0xbdf7
    static let muted: UInt16 = 0x8410
    static let accent: UInt16 = 0x07ff
    static let bitmap: UInt16 = 0xffa0
}

private extension Int {
    func wrapped(to bounds: ClosedRange<Int>) -> Int {
        let count = bounds.upperBound - bounds.lowerBound + 1
        guard count > 0 else { return bounds.lowerBound }
        let raw = (self - bounds.lowerBound) % count
        let offset = raw >= 0 ? raw : raw + count
        return bounds.lowerBound + offset
    }
}
