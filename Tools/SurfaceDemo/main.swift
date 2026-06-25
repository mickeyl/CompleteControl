import Foundation
import Observation
import KompleteKontrol
import KontrolSurfaceKit

// Observable transport state. Mutating it re-renders any presented screen that
// reads it — no explicit present call.
@Observable final class TransportModel {
    var isPlaying = false
    var isRecording = false
    var loopEnabled = false
    var lastGesture = "READY"
}

// The transport page, declarative and reactive: both the displays and the LEDs
// are functions of the model, so a gesture that flips the model is enough.
struct TransportScreen: Screen {
    let model: TransportModel

    var body: [any ScreenElement] {
        Status("TRANSPORT")
        PageIndicator(4, of: 4)
        Cell(1) { Label("STATE", overflow: .clip); Label(model.isPlaying ? "PLAY" : "STOP", overflow: .clip) }
        Cell(2) { Label("REC", overflow: .clip); Label(model.isRecording ? "ON" : "OFF", overflow: .clip) }
        Cell(3) { Label("LOOP", overflow: .clip); Label(model.loopEnabled ? "ON" : "OFF", overflow: .clip) }
        Cell(4) { Label("GESTURE", overflow: .clip); Label(model.lastGesture, overflow: .marquee) }
        Lamp(.play, model.isPlaying ? .on : .on(0x14))
        Lamp(.stop, .on(0x14))
        Lamp(.rec, model.isRecording ? .blink : .off)
        Lamp(.loop, model.loopEnabled ? .on : .off)
    }
}

// A multi-page demo. Page Left / Page Right switch between widget showcases.
//
//   - Parameters: eight encoder-bound parameters on displays 1…8.
//   - Glyphs:     the whole CP437 set at once (16 per display); display 0 is a
//                 detail view whose bottom row marquees the focused glyph's name
//                 (main encoder scrolls).
//   - Activity:   spinner widgets running a segment around the cell rectangle.
//   - Transport:  transport state mirrored on the LEDs (play steady, record
//                 blinking, loop steady), driven by gestures: tap Play to toggle,
//                 double-tap Play to restart, hold Stop for return-to-zero. The
//                 Arp LED pulses to show the pulse animator.
// The activity page, written declaratively with the DSL. It lowers to a model
// that `present` reconciles — no imperative setter calls.
struct ActivityScreen: Screen {
    let page: Int
    let total: Int

    var body: [any ScreenElement] {
        Status("ACTIVITY")
        PageIndicator(page, of: total)
        Cell(1) { Spinner(column: 0, speed: 10); Label("SPIN", overflow: .clip) }
        Cell(2) { Spinner(column: 0, speed: 14, length: 2); Label("COMET", overflow: .clip) }
        Cell(3) { Spinner(column: 0, speed: 10, reverse: true); Label("REV", overflow: .clip) }
        Cell(4) { Spinner(speed: 8); Label("ROW", overflow: .clip) }
        Lamp(.arp, .pulse)
    }
}

actor DemoController {
    enum Page: Int, CaseIterable {
        case parameters, glyphs, activity, transport
        var name: String {
            switch self {
                case .parameters: "PARAMETERS"
                case .glyphs: "GLYPHS"
                case .activity: "ACTIVITY"
                case .transport: "TRANSPORT"
            }
        }
    }

    private static let glyphCount = KKDisplayFrame.availableGlyphCount   // 129
    private static let mapDisplays = 1...8
    private static let detailDisplay = 0

    private let surface: Surface
    private let bank: ParameterBank
    private var current: Page = .parameters
    private var glyphSelection = 0
    private let transportModel = TransportModel()

    init(surface: Surface, bank: ParameterBank) {
        self.surface = surface
        self.bank = bank
    }

    func start() async {
        await show(.parameters)
    }

    func show(_ target: Page) async {
        current = target
        await surface.setLamp(.arp, .off)
        switch target {
            case .parameters:
                await surface.setParameterBank(bank)
                return
            case .glyphs:
                await surface.clearParameterPage()
                await surface.clearAll()
                await renderGlyphMap()
                await renderGlyphDetail()
                return
            case .activity:
                await surface.clearParameterPage()
                await surface.present(ActivityScreen(page: target.rawValue + 1, total: Page.allCases.count))
                return
            case .transport:
                await surface.clearParameterPage()
                await surface.observe { [transportModel] in TransportScreen(model: transportModel) }
                return
        }
        await surface.setPage(target.rawValue + 1, of: Page.allCases.count)
    }

    private func next() async {
        await show(Page(rawValue: (current.rawValue + 1) % Page.allCases.count)!)
    }

    private func previous() async {
        await show(Page(rawValue: (current.rawValue + Page.allCases.count - 1) % Page.allCases.count)!)
    }

    // MARK: Glyphs

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

    // MARK: Transport — only the model is mutated; the observed screen re-renders.

    private func handleTransportGesture(button: String, phase: GesturePhase) {
        switch (button, phase) {
            case ("play", .tap):
                transportModel.isPlaying.toggle()
                transportModel.lastGesture = "PLAY TAP"
            case ("play", .doubleTap):
                transportModel.isPlaying = true
                transportModel.lastGesture = "RESTART"
            case ("stop", .tap):
                transportModel.isPlaying = false
                transportModel.lastGesture = "STOP"
            case ("stop", .hold):
                transportModel.isPlaying = false
                transportModel.lastGesture = "RETURN TO ZERO"
            case ("rec", .tap):
                transportModel.isRecording.toggle()
                transportModel.lastGesture = "REC"
            case ("loop", .tap):
                transportModel.loopEnabled.toggle()
                transportModel.lastGesture = "LOOP"
            default:
                break
        }
    }

    // MARK: Input

    func handle(_ event: SurfaceInput) async {
        switch event {
            case let .button(name, pressed) where pressed && name == "page right":
                await next()
            case let .button(name, pressed) where pressed && name == "page left":
                await previous()
            case let .button(name, pressed) where pressed && name == "preset up" && current == .parameters:
                await surface.bankNext()
            case let .button(name, pressed) where pressed && name == "preset down" && current == .parameters:
                await surface.bankPrevious()
            case let .encoder(index, delta, _) where current == .glyphs && index == 1:
                await scrollGlyphs(delta)
            case let .mainEncoder(delta) where current == .glyphs:
                await scrollGlyphs(delta)
            case let .gesture(button, phase):
                handleTransportGesture(button: button, phase: phase)
            default:
                break
        }
    }
}

let device = KompleteKontrolS25MK1()
let surface = Surface(device: device)

let bank = ParameterBank([
    ParameterPage(title: "OSC / FILTER", parameters: [
        Parameter(name: "CUTOFF", value: 64, range: 0...127),
        Parameter(name: "RESONANCE", value: 20, range: 0...127),
        Parameter(name: "DRIVE", value: 30, range: 0...100, format: .percent),
        Parameter(name: "OSC MIX", value: 50, range: 0...100, format: .percent),
        Parameter(name: "DETUNE", value: 0, range: -50...50),
        Parameter(name: "SUB OSC", value: 20, range: 0...100, format: .percent),
        Parameter(name: "NOISE", value: 0, range: 0...100, format: .percent),
        Parameter(name: "KEY TRACK", value: 50, range: 0...100, format: .percent),
    ]),
    ParameterPage(title: "ENVELOPE", parameters: [
        Parameter(name: "ATTACK", value: 5, range: 0...1000, step: 2),
        Parameter(name: "DECAY MILLISECONDS", value: 120, range: 0...2000, step: 4),
        Parameter(name: "SUSTAIN", value: 80, range: 0...100, format: .percent),
        Parameter(name: "RELEASE", value: 200, range: 0...3000, step: 5),
        Parameter(name: "ENV AMOUNT", value: 50, range: 0...100, format: .percent),
        Parameter(name: "VELOCITY", value: 64, range: 0...127),
        Parameter(name: "ENV DELAY", value: 0, range: 0...500, step: 2),
        Parameter(name: "ENV CURVE", value: 0, range: -100...100),
    ]),
    ParameterPage(title: "FX SENDS", parameters: [
        Parameter(name: "REVERB", value: 20, range: 0...100, format: .percent),
        Parameter(name: "DELAY", value: 15, range: 0...100, format: .percent),
        Parameter(name: "CHORUS", value: 0, range: 0...100, format: .percent),
        Parameter(name: "WIDTH", value: 100, range: 0...100, format: .percent),
        Parameter(name: "PAN", value: 0, range: -50...50),
        Parameter(name: "LEVEL", value: -6, range: -60...6, step: 0.5, format: .decibel),
        Parameter(name: "SEND A", value: 30, range: 0...100, format: .percent),
        Parameter(name: "SEND B", value: 10, range: 0...100, format: .percent),
    ]),
])
let demo = DemoController(surface: surface, bank: bank)

print("KontrolSurfaceKit demo — Page Left / Page Right switch widget pages.")
print("Parameters: Preset Up / Down page the bank. Transport: gestures on Play/Rec/Loop/Stop.")

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
    await demo.start()
    for await event in await surface.inputs {
        await demo.handle(event)
    }
}

dispatchMain()
