import Foundation
import KompleteKontrol
import KontrolSurfaceKit

// A multi-page demo. Page Left / Page Right switch between widget showcases.
//
//   - Parameters: eight encoder-bound parameters on displays 1…8.
//   - Glyphs:     the whole CP437 set at once. Displays 1…8 hold 16 glyphs each
//                 (8 per text row) = 128 cells = glyphs 0…127. Display 0 is a
//                 detail view: the focused glyph plus its name as a marquee,
//                 scrolled with the main encoder; it also reaches the 129th
//                 (cabl extra) glyph.
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

    private static let glyphCount = KKDisplayFrame.availableGlyphCount   // 129
    private static let mapDisplays = 1...8                               // displays for glyphs 0…127
    private static let detailDisplay = 0                                 // focused glyph + name

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
                await surface.setPage(target.rawValue + 1, of: Page.allCases.count)
            case .glyphs:
                await surface.clearParameterPage()
                await surface.clearAll()
                await renderGlyphMap()
                await renderGlyphDetail()
            case .activity:
                await surface.clearParameterPage()
                await surface.clearAll()
                await renderActivity()
                await surface.setStatus(target.name)
                await surface.setPage(target.rawValue + 1, of: Page.allCases.count)
        }
    }

    private func next() async {
        await show(Page(rawValue: (current.rawValue + 1) % Page.allCases.count)!)
    }

    private func previous() async {
        await show(Page(rawValue: (current.rawValue + Page.allCases.count - 1) % Page.allCases.count)!)
    }

    /// Lays the full CP437 set across displays 1…8: each display shows 16
    /// consecutive glyphs, the first 8 on row 1 and the next 8 on row 2.
    private func renderGlyphMap() async {
        for display in Self.mapDisplays {
            let base = (display - 1) * 16
            let rowOne = (0..<8).map { KKDisplayFrame.glyph(at: base + $0) ?? 0 }
            let rowTwo = (0..<8).map { KKDisplayFrame.glyph(at: base + 8 + $0) ?? 0 }
            await surface.setGlyphs(display, 1, rowOne)
            await surface.setGlyphs(display, 2, rowTwo)
        }
    }

    private func renderGlyphDetail() async {
        let glyph = KKDisplayFrame.glyph(at: glyphSelection) ?? 0
        await surface.setGlyphs(Self.detailDisplay, 1, [glyph])
        await surface.setText(Self.detailDisplay, 2, KKDisplayFrame.glyphName(at: glyphSelection) ?? "?",
                              alignment: .center, overflow: .marquee())
        await surface.setBar(Double(glyphSelection) / Double(max(1, Self.glyphCount - 1)),
                             lcd: Self.detailDisplay)
    }

    private func scrollGlyphs(_ delta: Int) async {
        glyphSelection = min(Self.glyphCount - 1, max(0, glyphSelection + (delta < 0 ? -1 : 1)))
        await renderGlyphDetail()
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
            case let .encoder(index, delta, _) where current == .glyphs && index == 1:
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
print("Glyphs shows the whole CP437 set; the main encoder scrolls the name detail. Ctrl-C to quit.")

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
