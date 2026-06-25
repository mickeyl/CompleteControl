import Foundation
import KompleteKontrol
import KontrolSurfaceKit

// Drives two screens on the surface and switches between them with the Browse
// button:
//   - a parameter page (eight encoder-bound parameters on displays 1…8), and
//   - a glyph browser that shows a sliding window of 16-segment glyphs and the
//     selected glyph's name on the bottom row, scrolled as a marquee.
actor DemoController {
    enum Mode { case parameters, glyphs }

    private static let glyphCount = KKDisplayFrame.availableGlyphCount
    private static let glyphWindow = KKDisplayFrame.characterCount
    private static let maxSelection = max(0, glyphCount - glyphWindow)
    private static let glyphDisplay = KKDisplayFrame.displayCount - 1

    private let surface: Surface
    private let page: ParameterPage
    private var mode: Mode = .parameters
    private var glyphSelection = 0

    init(surface: Surface, page: ParameterPage) {
        self.surface = surface
        self.page = page
    }

    func showParameters() async {
        mode = .parameters
        await surface.setParameterPage(page)
    }

    private func showGlyphs() async {
        mode = .glyphs
        await surface.clearParameterPage()
        await surface.clearAll()
        await renderGlyphs()
    }

    private func renderGlyphs() async {
        await surface.setStatus("GLYPH BROWSER")
        await surface.setPage(glyphSelection + 1, of: Self.glyphCount)

        let glyphs = (0..<Self.glyphWindow).map {
            KKDisplayFrame.glyph(at: min(glyphSelection + $0, Self.glyphCount - 1)) ?? 0
        }
        await surface.setGlyphs(Self.glyphDisplay, 1, glyphs)
        await surface.setBar(Self.maxSelection > 0 ? Double(glyphSelection) / Double(Self.maxSelection) : 0,
                             lcd: Self.glyphDisplay)
        let name = KKDisplayFrame.glyphName(at: glyphSelection) ?? "?"
        await surface.setText(Self.glyphDisplay, 2, name, alignment: .center, overflow: .marquee())
    }

    private func scrollGlyphs(_ delta: Int) async {
        let step = delta < 0 ? -1 : 1
        glyphSelection = min(Self.maxSelection, max(0, glyphSelection + step))
        await renderGlyphs()
    }

    func handle(_ event: SurfaceInput) async {
        switch event {
            case let .button(name, pressed) where pressed && name == "browse":
                if mode == .parameters { await showGlyphs() } else { await showParameters() }
            case let .encoder(index, delta, _) where mode == .glyphs && index == 0:
                await scrollGlyphs(delta)
            case let .mainEncoder(delta) where mode == .glyphs:
                await scrollGlyphs(delta)
            default:
                break
        }
    }
}

let device = KompleteKontrolS25MK1()
let surface = Surface(device: device)

let page = ParameterPage(title: "OSC / FILTER", parameters: [
    Parameter(name: "CUTOFF", value: 64, range: 0...127),
    Parameter(name: "RESONANCE", value: 20, range: 0...127),
    Parameter(name: "DRIVE", value: 30, range: 0...100, format: .percent),
    Parameter(name: "ATTACK", value: 5, range: 0...1000, step: 2),
    Parameter(name: "DECAY MILLISECONDS", value: 120, range: 0...2000, step: 4),
    Parameter(name: "SUSTAIN", value: 80, range: 0...100, format: .percent),
    Parameter(name: "RELEASE", value: 200, range: 0...3000, step: 5),
    Parameter(name: "LEVEL", value: -6, range: -60...6, step: 0.5, format: .decibel),
])
let demo = DemoController(surface: surface, page: page)

print("KontrolSurfaceKit demo — turn encoders to edit parameters; press Browse to")
print("toggle the glyph browser (main encoder / encoder 1 scrolls). Ctrl-C to quit.")

let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    Task {
        await surface.stop()
        exit(0)
    }
}
interrupt.resume()
signal(SIGINT, SIG_IGN)

Task {
    await surface.start()
    await demo.showParameters()
    for await event in await surface.inputs {
        await demo.handle(event)
    }
}

dispatchMain()
