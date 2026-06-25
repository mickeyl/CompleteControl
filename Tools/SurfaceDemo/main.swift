import Foundation
import KompleteKontrol
import KontrolSurfaceKit

// A multi-page demo. Page Left / Page Right switch between widget showcases;
// the status display (0) always shows the page name and index.
//
//   - Parameters: eight encoder-bound parameters on displays 1…8.
//   - Glyphs:     a sliding 16-segment glyph window; the bottom row marquees the
//                 selected glyph's name. Main encoder / encoder 1 scrolls.
//   - Activity:   spinner widgets running a segment around the cell rectangle.
actor DemoController {
    enum Page: Int, CaseIterable {
        case parameters, glyphs, activity
        var name: String {
            switch self {
                case .parameters: "PARAMETERS"
                case .glyphs: "GLYPHS"
                case .activity: "ACTIVITY"
            }
        }
    }

    private static let glyphCount = KKDisplayFrame.availableGlyphCount
    private static let glyphWindow = KKDisplayFrame.characterCount
    private static let maxSelection = max(0, glyphCount - glyphWindow)
    private static let glyphDisplay = KKDisplayFrame.displayCount - 1

    private let surface: Surface
    private let page: ParameterPage
    private var current: Page = .parameters
    private var glyphSelection = 0

    init(surface: Surface, page: ParameterPage) {
        self.surface = surface
        self.page = page
    }

    func show(_ target: Page) async {
        current = target
        switch target {
            case .parameters:
                await surface.setParameterPage(page)
            case .glyphs:
                await surface.clearParameterPage()
                await surface.clearAll()
                await renderGlyphs()
                await surface.setStatus(target.name)
            case .activity:
                await surface.clearParameterPage()
                await surface.clearAll()
                await renderActivity()
                await surface.setStatus(target.name)
        }
        await surface.setPage(target.rawValue + 1, of: Page.allCases.count)
    }

    private func next() async {
        await show(Page(rawValue: (current.rawValue + 1) % Page.allCases.count)!)
    }

    private func previous() async {
        await show(Page(rawValue: (current.rawValue + Page.allCases.count - 1) % Page.allCases.count)!)
    }

    private func renderGlyphs() async {
        let glyphs = (0..<Self.glyphWindow).map {
            KKDisplayFrame.glyph(at: min(glyphSelection + $0, Self.glyphCount - 1)) ?? 0
        }
        await surface.setGlyphs(Self.glyphDisplay, 1, glyphs)
        await surface.setBar(Self.maxSelection > 0 ? Double(glyphSelection) / Double(Self.maxSelection) : 0,
                             lcd: Self.glyphDisplay)
        await surface.setText(Self.glyphDisplay, 2, KKDisplayFrame.glyphName(at: glyphSelection) ?? "?",
                              alignment: .center, overflow: .marquee())
    }

    private func scrollGlyphs(_ delta: Int) async {
        glyphSelection = min(Self.maxSelection, max(0, glyphSelection + (delta < 0 ? -1 : 1)))
        await renderGlyphs()
    }

    private func renderActivity() async {
        await surface.setSpinner(1, 1, column: 0, speed: 10)
        await surface.setText(1, 2, "SPIN", alignment: .center, overflow: .clip)

        await surface.setSpinner(2, 1, column: 0, speed: 14, length: 2)
        await surface.setText(2, 2, "COMET", alignment: .center, overflow: .clip)

        await surface.setSpinner(3, 1, column: 0, speed: 10, reverse: true)
        await surface.setText(3, 2, "REV", alignment: .center, overflow: .clip)

        await surface.setSpinner(4, 1, speed: 8)
        await surface.setText(4, 2, "ROW", alignment: .center, overflow: .clip)
    }

    func handle(_ event: SurfaceInput) async {
        switch event {
            case let .button(name, pressed) where pressed && name == "page right":
                await next()
            case let .button(name, pressed) where pressed && name == "page left":
                await previous()
            case let .encoder(index, delta, _) where current == .glyphs && index == 0:
                await scrollGlyphs(delta)
            case let .mainEncoder(delta) where current == .glyphs:
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

print("KontrolSurfaceKit demo — Page Left / Page Right switch widget pages.")
print("On Glyphs, the main encoder scrolls; the bottom row marquees the name. Ctrl-C to quit.")

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
    await demo.show(.parameters)
    for await event in await surface.inputs {
        await demo.handle(event)
    }
}

dispatchMain()
