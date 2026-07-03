import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

// A lab bench for the KontrolSurfaceKit2 widget layer. Everything on screen is composed
// exclusively from kit2 public APIs (BitmapLabel, MK2PixelFrame, MK2SurfaceScene2,
// PixelSnapshot) — no private drawing helpers, no legacy placeholder font. If a unit
// needs something the kit can't express yet, that capability goes into the kit first.
//
// Eight units select via the function buttons (later: paging). A readline REPL drives the
// per-unit parameters so we don't have to bind every knob to hardware while iterating.
@main
struct MK2WidgetLabDemo {
    static func main() async {
        let surface = MK2Surface2(options: .init(tickHz: 60))
        let lab = WidgetLab(surface: surface)
        await surface.start()
        await lab.show(.font)
        printBanner()
        startREPL(lab)

        for await state in await surface.connectionStates {
            switch state {
                case .evicted:
                    print("evicted by another surface client — quitting")
                    exit(0)
                case let .retrying(reason):
                    print("surface: retrying (\(reason))")
                case let .connected(detail):
                    print("surface: connected (\(detail))")
                case .stopped:
                    print("surface: stopped")
            }
        }
    }

    private static func printBanner() {
        print("MK2WidgetLabDemo — units A…H via function buttons or REPL. Type 'help' or press Tab.")
    }

    private static func startREPL(_ lab: WidgetLab) {
        let reader = Thread {
            let editor = LineReader(completer: replComplete)
            while let line = editor.readLine(prompt: "› ") {
                let command = line.trimmingCharacters(in: .whitespaces)
                guard !command.isEmpty else { continue }
                editor.addHistory(command)
                // Run the command to completion before reading the next line so its output
                // never interleaves with the live line editor.
                let done = DispatchSemaphore(value: 0)
                Task { await lab.command(command); done.signal() }
                done.wait()
            }
        }
        reader.stackSize = 1 << 20
        reader.name = "widgetlab-repl"
        reader.start()
    }
}

/// The single source of truth for the REPL: drives help output, Tab completion, and the
/// documented argument shapes. Keep it in sync with `WidgetLab.command`.
struct ReplCommand {
    let name: String
    let arg: String
    let summary: String
    let values: [String] // completion candidates for the first argument (empty = free/none)
}

let replCommands: [ReplCommand] = [
    ReplCommand(name: "unit", arg: "<a-h>", summary: "switch unit", values: Unit.allCases.map { $0.letter }),
    ReplCommand(name: "text", arg: "<string>", summary: "font lab: sample text", values: []),
    ReplCommand(name: "face", arg: "grid|label|readout", summary: "focus face", values: ["grid", "label", "readout"]),
    ReplCommand(name: "weight", arg: "regular|bold", summary: "focus weight", values: ["regular", "bold"]),
    ReplCommand(name: "bold", arg: "on|off", summary: "focus bold toggle", values: ["on", "off"]),
    ReplCommand(name: "scale", arg: "<n>", summary: "focus integer pixel scale", values: []),
    ReplCommand(name: "fg", arg: "<rrggbb|name>", summary: "foreground colour", values: namedColors.keys.sorted()),
    ReplCommand(name: "bg", arg: "<rrggbb|name|none>", summary: "focus highlight background", values: namedColors.keys.sorted() + ["none"]),
    ReplCommand(name: "snap", arg: "[path]", summary: "write a two-screen PNG snapshot", values: []),
    ReplCommand(name: "help", arg: "", summary: "show this help", values: []),
    ReplCommand(name: "quit", arg: "", summary: "exit", values: []),
]

func replComplete(_ tokens: [String]) -> [String] {
    if tokens.count <= 1 { return replCommands.map { $0.name } + Unit.allCases.map { $0.letter } }
    guard tokens.count == 2, let command = replCommands.first(where: { $0.name == tokens[0].lowercased() }) else { return [] }
    return command.values
}

func printReplHelp() {
    print("MK2WidgetLabDemo REPL — commands (Tab completes):")
    for command in replCommands {
        let left = "\(command.name) \(command.arg)".padding(toLength: 26, withPad: " ", startingAt: 0)
        print("  \(left)\(command.summary)")
    }
    print("  " + "a…h".padding(toLength: 26, withPad: " ", startingAt: 0) + "shortcut for 'unit <letter>'")
}

private enum Unit: Int, CaseIterable, Sendable {
    case font, chrome, meter, list, pattern, waveform, keys, scene

    var title: String {
        switch self {
            case .font: "FONT LAB"
            case .chrome: "CHROME LAB"
            case .meter: "METER LAB"
            case .list: "LIST LAB"
            case .pattern: "PATTERN LAB"
            case .waveform: "WAVEFORM LAB"
            case .keys: "KEYS LAB"
            case .scene: "SCENE LAB"
        }
    }

    var short: String {
        switch self {
            case .font: "FONT"
            case .chrome: "CHRM"
            case .meter: "METR"
            case .list: "LIST"
            case .pattern: "PATT"
            case .waveform: "WAVE"
            case .keys: "KEYS"
            case .scene: "SCEN"
        }
    }

    var letter: String { String(UnicodeScalar(UInt8(97 + rawValue))) }
    var implemented: Bool { self == .font }
    var functionLED: KKMK2ButtonLED {
        KKMK2ButtonLED(rawValue: KKMK2ButtonLED.function1.rawValue + rawValue)!
    }
}

private actor WidgetLab {
    private let surface: MK2Surface2
    private var unit: Unit = .font

    // Font lab focus: the single combination we render prominently while iterating
    // toward a locked-in choice.
    private var focusRole: SurfaceFont.Role = .grid
    private var focusWeight: SurfaceFont.Weight = .regular
    private var focusScale = 2
    private var focusFG: UInt16 = 0xffff
    private var focusBG: UInt16?
    private var sampleText = "Paulinche 0123 ÄÖÜ"

    init(surface: MK2Surface2) {
        self.surface = surface
    }

    func show(_ next: Unit) async {
        unit = next
        await render()
    }

    private func render() async {
        await surface.present(scene())
    }

    // MARK: - Scene

    private func scene() -> MK2SurfaceScene2 {
        var lamps: [KKMK2ButtonLED: MK2LampState2] = [:]
        for candidate in Unit.allCases {
            lamps[candidate.functionLED] = candidate == unit ? .white : .off
        }

        var bindings = MK2InputBindings2()
        for candidate in Unit.allCases {
            bindings.onPress(candidate.functionLED) { [weak self] in
                Task { await self?.show(candidate) }
            }
        }

        let (left, right) = frames()
        return MK2SurfaceScene2(left: left, right: right, lamps: lamps, bindings: bindings)
    }

    private func frames() -> (MK2PixelFrame, MK2PixelFrame) {
        switch unit {
            case .font: (fontCatalogFrame(), fontFocusFrame())
            default: (comingSoonFrame(), placeholderRightFrame())
        }
    }

    // MARK: - Font lab

    // Left screen: every face rendered at native scale so relative sizes/weights are
    // directly comparable against the same sample string.
    private func fontCatalogFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        BitmapLabel("FONT LAB - CATALOG", font: .label, color: Palette.accent)
            .draw(into: &frame, x: 8, y: 8)

        let faces: [(String, SurfaceFont)] = [
            ("GRID", .grid), ("GRID-B", .gridBold), ("LABEL", .label),
            ("READOUT", .readout), ("READ-B", .readoutBold),
        ]
        var y = 34
        for (name, font) in faces {
            BitmapLabel(name, font: .label, color: Palette.dim).draw(into: &frame, x: 8, y: y + 1)
            BitmapLabel(sampleText, font: font, color: Palette.text)
                .draw(into: &frame, x: 96, y: y, clip: MK2PixelRect(x: 96, y: y, width: 480 - 96, height: font.cellHeight))
            y += font.cellHeight + 10
        }
        return frame
    }

    // Right screen: the focused combination big, over an optional background swatch, with
    // a settings readout — this is the surface we judge a candidate on.
    private func fontFocusFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        let font = SurfaceFont.face(focusRole, focusWeight)

        let readout = "\(roleName) \(weightName) x\(focusScale)  FG \(hex(focusFG))  BG \(focusBG.map(hex) ?? "----")"
        BitmapLabel(readout, font: .label, color: Palette.dim).draw(into: &frame, x: 8, y: 8)

        let swatch = MK2PixelRect(x: 6, y: 34, width: 468, height: 200)
        if let background = focusBG {
            frame.fill(swatch, background)
            frame.stroke(swatch, Palette.border)
        }
        BitmapLabel(sampleText, font: font, color: focusFG, scale: focusScale)
            .draw(into: &frame, x: 16, y: 110, clip: swatch)

        BitmapLabel("ENC/BTN LATER - DRIVE VIA REPL", font: .label, color: Palette.dim)
            .draw(into: &frame, x: 8, y: 250)
        return frame
    }

    // MARK: - Placeholder units

    private func comingSoonFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        BitmapLabel(unit.title, font: .readout, color: Palette.text).draw(into: &frame, x: 16, y: 40)
        BitmapLabel("UNIT \(unit.letter.uppercased()) — NOT BUILT YET", font: .label, color: Palette.dim)
            .draw(into: &frame, x: 16, y: 80)
        BitmapLabel("BUILD ITS WIDGETS INTO KIT2 FIRST", font: .label, color: Palette.dim)
            .draw(into: &frame, x: 16, y: 100)
        return frame
    }

    private func placeholderRightFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        BitmapLabel("A FONT   B CHRM   C METR   D LIST", font: .label, color: Palette.dim)
            .draw(into: &frame, x: 8, y: 40)
        BitmapLabel("E PATT   F WAVE   G KEYS   H SCEN", font: .label, color: Palette.dim)
            .draw(into: &frame, x: 8, y: 60)
        return frame
    }

    // MARK: - REPL

    func command(_ line: String) async {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let verb = parts.first.map(String.init)?.lowercased() ?? ""
        let rest = parts.count > 1 ? String(parts[1]) : ""

        // Single-letter unit switch.
        if verb.count == 1, let unit = Unit.allCases.first(where: { $0.letter == verb }) {
            await show(unit)
            print("→ \(unit.title)")
            return
        }

        switch verb {
            case "unit":
                guard let unit = Unit.allCases.first(where: { $0.letter == rest.lowercased() || $0.short.lowercased() == rest.lowercased() }) else {
                    print("? unit a…h"); return
                }
                await show(unit)
                print("→ \(unit.title)")

            case "text":
                sampleText = rest.isEmpty ? " " : rest
                await render()

            case "face":
                guard let role = Self.role(rest) else { print("? face grid|label|readout"); return }
                focusRole = role
                await render()

            case "weight":
                focusWeight = rest.lowercased() == "bold" ? .bold : .regular
                await render()

            case "bold":
                focusWeight = ["off", "0", "false", "no"].contains(rest.lowercased()) ? .regular : .bold
                await render()

            case "scale":
                guard let value = Int(rest), value > 0 else { print("? scale <n>"); return }
                focusScale = value
                await render()

            case "fg":
                guard let color = Self.color565(rest) else { print("? fg <rrggbb|name>"); return }
                focusFG = color
                await render()

            case "bg":
                if rest.lowercased() == "none" { focusBG = nil; await render(); return }
                guard let color = Self.color565(rest) else { print("? bg <rrggbb|name|none>"); return }
                focusBG = color
                await render()

            case "snap":
                await snapshot(to: rest.isEmpty ? nil : rest)

            case "help", "?":
                printReplHelp()

            case "quit", "exit", "q":
                print("bye"); exit(0)

            default:
                print("? unknown '\(verb)' — try help")
        }
    }

    private func snapshot(to path: String?) async {
        let (left, right) = frames()
        let target = path ?? FileManager.default.currentDirectoryPath + "/widgetlab-\(unit.short.lowercased()).png"
        do {
            let written = try PixelSnapshot.write([left, right], to: target)
            print("snapshot → \(written)")
        } catch {
            print("snapshot failed: \(error)")
        }
    }

    // MARK: - Parsing helpers

    private var roleName: String {
        switch focusRole {
            case .grid: "GRID"
            case .label: "LABEL"
            case .readout: "READOUT"
        }
    }

    private var weightName: String { focusWeight == .bold ? "BOLD" : "REG" }

    private func hex(_ value: UInt16) -> String { String(format: "%04X", value) }

    private static func role(_ text: String) -> SurfaceFont.Role? {
        switch text.lowercased() {
            case "grid": .grid
            case "label": .label
            case "readout": .readout
            default: nil
        }
    }

    // Accepts RRGGBB hex or a small set of names, returns wire-order-agnostic RGB565.
    private static func color565(_ text: String) -> UInt16? {
        if let hit = namedColors[text.lowercased()] { return hit }
        let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
        let r = UInt16((rgb >> 16) & 0xff) >> 3
        let g = UInt16((rgb >> 8) & 0xff) >> 2
        let b = UInt16(rgb & 0xff) >> 3
        return (r << 11) | (g << 5) | b
    }
}

let namedColors: [String: UInt16] = [
    "white": 0xffff, "black": 0x0000, "red": 0xf800, "green": 0x07e0,
    "blue": 0x001f, "yellow": 0xffe0, "cyan": 0x07ff, "magenta": 0xf81f,
    "orange": 0xfc00, "grey": 0x8410, "gray": 0x8410, "dim": 0x4208,
]

private enum Palette {
    static let page: UInt16 = 0x0841       // near-black blue
    static let text: UInt16 = 0xffff
    static let dim: UInt16 = 0x8410        // mid grey
    static let accent: UInt16 = 0xffe0     // yellow
    static let border: UInt16 = 0x4208     // faint frame
}
