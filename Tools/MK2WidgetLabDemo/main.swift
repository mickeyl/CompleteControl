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
        await lab.show(.pattern)
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
    ReplCommand(name: "play", arg: "", summary: "tracker unit: start playback", values: []),
    ReplCommand(name: "stop", arg: "", summary: "tracker unit: stop playback", values: []),
    ReplCommand(name: "row", arg: "<0-63|hex>", summary: "tracker unit: set stopped playhead row", values: []),
    ReplCommand(name: "jog", arg: "<delta>", summary: "tracker unit: emulate 4D row rotation", values: []),
    ReplCommand(name: "ch", arg: "<1-4>", summary: "tracker unit: set focused channel", values: ["1", "2", "3", "4"]),
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
    var implemented: Bool { self == .font || self == .pattern }
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
    private var isPlaying = false
    private var playheadRow = 0
    private var playbackTimer: DispatchSourceTimer?
    private let patternRows: [TrackerDemoRow]
    private var focusedChannel = 3

    init(surface: MK2Surface2) {
        self.surface = surface
        self.patternRows = WidgetLab.demoPatternRows()
    }

    func show(_ next: Unit) async {
        if next != .pattern {
            isPlaying = false
            playbackTimer?.cancel()
            playbackTimer = nil
        }
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
        if unit == .pattern {
            lamps[.play] = isPlaying ? .off : .green
            lamps[.stop] = isPlaying ? .red : .off
            lamps[.pageLeft] = focusedChannel > 0 ? .white : .off
            lamps[.pageRight] = focusedChannel < 3 ? .white : .off
        }

        var bindings = MK2InputBindings2()
        for candidate in Unit.allCases {
            bindings.onPress(candidate.functionLED) { [weak self] in
                Task { await self?.show(candidate) }
            }
        }
        bindings.onPress(.play) { [weak self] in
            Task { await self?.play() }
        }
        bindings.onPress(.stop) { [weak self] in
            Task { await self?.stopPlayback() }
        }
        bindings.onPress(.pageLeft) { [weak self] in
            Task { await self?.moveFocusedChannel(-1) }
        }
        bindings.onPress(.pageRight) { [weak self] in
            Task { await self?.moveFocusedChannel(1) }
        }
        bindings.jogScroll = { [weak self] delta, _ in
            Task { await self?.turnMainEncoder(delta) }
        }

        let (left, right) = frames()
        return MK2SurfaceScene2(left: left, right: right, lamps: lamps, bindings: bindings)
    }

    private func frames() -> (MK2PixelFrame, MK2PixelFrame) {
        switch unit {
            case .font: (fontCatalogFrame(), fontFocusFrame())
            case .pattern: (trackerGridFrame(), trackerDetailFrame())
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

    // MARK: - Tracker unit

    private func trackerGridFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        BitmapLabel("PATTERN 03", font: .grid, color: Palette.blue).draw(into: &frame, x: 8, y: 8)
        BitmapLabel("LEN 64", font: .grid, color: Palette.dim).draw(into: &frame, x: 138, y: 8)
        BitmapLabel("ROW \(hex2(playheadRow))", font: .gridBold, color: Palette.text).draw(into: &frame, x: 232, y: 8)
        BitmapLabel(isPlaying ? "PLAY" : "STOP", font: .gridBold, color: isPlaying ? Palette.green : Palette.orange).draw(into: &frame, x: 330, y: 8)
        BitmapLabel("SPD 06", font: .grid, color: Palette.dim).draw(into: &frame, x: 398, y: 8)

        let gridTop = 60
        let rowHeight = 16
        let rowIndexX = 8
        let channelXs = [48, 153, 258, 363]
        let rulerXs = [36, 141, 246, 351, 456]

        for (index, x) in channelXs.enumerated() {
            BitmapLabel("CHANNEL \(index + 1)", font: .label, color: index == focusedChannel ? Palette.blue : Palette.dim)
                .draw(into: &frame, x: x, y: 38)
        }
        frame.hline(y: 55, x: 0, width: 480, color: Palette.border)

        let firstRow = visibleFirstRow(center: playheadRow)
        for visible in 0..<13 {
            let row = firstRow + visible
            let y = gridTop + visible * rowHeight
            let rowRect = MK2PixelRect(x: 0, y: y, width: 480, height: rowHeight)
            if row == playheadRow {
                frame.fill(rowRect, isPlaying ? Palette.playheadFill : Palette.cursorFill)
                frame.fill(MK2PixelRect(x: 36, y: y, width: 5, height: rowHeight), Palette.green)
            } else if row.isMultiple(of: 4) {
                frame.fill(MK2PixelRect(x: 0, y: y, width: 480, height: rowHeight), Palette.rowStripe)
            }

            let rowColor = row == playheadRow ? Palette.text : Palette.dim
            BitmapLabel(hex2(row), font: .grid, color: rowColor).draw(into: &frame, x: rowIndexX, y: y)
            for channel in 0..<4 {
                drawTrackerCell(patternRows[row].cells[channel], channel: channel, into: &frame, x: channelXs[channel], y: y, highlighted: row == playheadRow)
            }
        }
        for x in rulerXs {
            frame.dottedVLine(x: x, y: 50, height: 218, color: Palette.ruler)
        }

        drawPatternOverview(into: &frame, x: 466, y: 62, height: 200)
        return frame
    }

    private func trackerDetailFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        let cell = patternRows[playheadRow].cells[focusedChannel]

        BitmapLabel("EDIT", font: .grid, color: Palette.blue).draw(into: &frame, x: 24, y: 18)
        BitmapLabel("CH\(focusedChannel + 1)", font: .grid, color: Palette.dim).draw(into: &frame, x: 110, y: 18)
        BitmapLabel("ROW \(hex2(playheadRow))", font: .grid, color: Palette.dim).draw(into: &frame, x: 176, y: 18)
        BitmapLabel(isPlaying ? "PLAYING" : "JOG ROW", font: .label, color: isPlaying ? Palette.green : Palette.orange)
            .draw(into: &frame, x: 360, y: 21)

        drawEditField("NOTE", value: cell.note, color: Palette.text, x: 24, y: 90, width: 72, focused: true, into: &frame)
        drawEditField("INST", value: cell.instrument, color: Palette.instrument, x: 136, y: 90, width: 68, focused: false, into: &frame)
        drawEditField("VOL", value: cell.volume, color: Palette.text, x: 252, y: 90, width: 68, focused: false, into: &frame)
        drawEditField("FX", value: cell.effect, color: Palette.effect, x: 358, y: 90, width: 82, focused: false, into: &frame)

        frame.hline(y: 156, x: 0, width: 480, color: Palette.border)
        BitmapLabel("INST \(cell.instrument)", font: .grid, color: Palette.dim).draw(into: &frame, x: 24, y: 178)
        BitmapLabel("strings2", font: .grid, color: Palette.text).draw(into: &frame, x: 128, y: 178)
        drawPlaceholder("WAVEFORM", into: &frame, rect: MK2PixelRect(x: 326, y: 174, width: 128, height: 40))

        drawPlaceholder("VU METERS", into: &frame, rect: MK2PixelRect(x: 24, y: 212, width: 430, height: 30))

        BitmapLabel("PLAY/STOP TRANSPORT  4D ROTATES ROW ONLY WHEN STOPPED", font: .label, color: Palette.dim)
            .draw(into: &frame, x: 24, y: 254)
        return frame
    }

    private func drawTrackerCell(_ cell: TrackerDemoCell, channel: Int, into frame: inout MK2PixelFrame, x: Int, y: Int, highlighted: Bool) {
        let empty = cell.isEmpty
        let noteColor = highlighted ? Palette.text : (empty ? Palette.empty : Palette.note)
        let instColor = highlighted ? Palette.text : (empty ? Palette.empty : Palette.instrument)
        let fxColor = highlighted ? Palette.text : (cell.effect == "..." ? Palette.empty : Palette.effect)
        if channel == focusedChannel, !highlighted {
            frame.fill(MK2PixelRect(x: x - 4, y: y, width: 92, height: 16), Palette.focusedChannelFill)
        }
        BitmapLabel(cell.note, font: .grid, color: noteColor).draw(into: &frame, x: x, y: y)
        BitmapLabel(cell.instrument, font: .grid, color: instColor).draw(into: &frame, x: x + 38, y: y)
        BitmapLabel(cell.effect, font: .grid, color: fxColor).draw(into: &frame, x: x + 64, y: y)
    }

    private func drawEditField(_ label: String, value: String, color: UInt16, x: Int, y: Int, width: Int, focused: Bool, into frame: inout MK2PixelFrame) {
        BitmapLabel(label, font: .label, color: Palette.dim).draw(into: &frame, x: x, y: y - 24)
        let rect = MK2PixelRect(x: x, y: y, width: width, height: 28)
        if focused {
            frame.fill(rect, 0xc618)
            BitmapLabel(value, font: .readout, color: 0x0000).draw(into: &frame, x: x + 4, y: y + 4)
        } else {
            frame.stroke(rect, Palette.border)
            BitmapLabel(value, font: .readoutBold, color: color).draw(into: &frame, x: x + 4, y: y + 4)
        }
    }

    private func drawPlaceholder(_ title: String, into frame: inout MK2PixelFrame, rect: MK2PixelRect) {
        frame.fill(rect, Palette.placeholderFill)
        frame.stroke(rect, Palette.border)
        BitmapLabel(title, font: .label, color: Palette.dim)
            .draw(into: &frame, x: rect.x + 8, y: rect.y + max(7, (rect.height - SurfaceFont.label.cellHeight) / 2))
    }

    private func drawPatternOverview(into frame: inout MK2PixelFrame, x: Int, y: Int, height: Int) {
        frame.fill(MK2PixelRect(x: x, y: y, width: 5, height: height), Palette.track)
        for row in 0..<64 {
            let markerY = y + Int((Double(row) / 63.0 * Double(height - 1)).rounded())
            let active = patternRows[row].cells.contains { !$0.isEmpty }
            let color = row == playheadRow ? Palette.green : (active ? Palette.blue : Palette.ruler)
            frame.fill(MK2PixelRect(x: x, y: markerY, width: row == playheadRow ? 9 : 5, height: 1), color)
        }
    }

    private func visibleFirstRow(center: Int) -> Int {
        min(max(0, center - 6), max(0, patternRows.count - 13))
    }

    private func hex2(_ value: Int) -> String {
        String(format: "%02X", max(0, min(255, value)))
    }

    private func play() async {
        guard unit == .pattern else { return }
        guard !isPlaying else { return }
        isPlaying = true
        await render()
        playbackTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + .milliseconds(180), repeating: .milliseconds(180), leeway: .milliseconds(5))
        timer.setEventHandler {
            Task { await self.advancePlayback() }
        }
        playbackTimer = timer
        timer.resume()
    }

    private func stopPlayback() async {
        isPlaying = false
        playbackTimer?.cancel()
        playbackTimer = nil
        await render()
    }

    private func advancePlayback() async {
        guard isPlaying else { return }
        playheadRow = (playheadRow + 1) % patternRows.count
        await render()
    }

    private func turnMainEncoder(_ delta: Int) async {
        guard unit == .pattern, !isPlaying, delta != 0 else { return }
        playheadRow = max(0, min(patternRows.count - 1, playheadRow + delta))
        await render()
    }

    private func moveFocusedChannel(_ delta: Int) async {
        guard unit == .pattern, delta != 0 else { return }
        let next = max(0, min(3, focusedChannel + delta))
        guard next != focusedChannel else { return }
        focusedChannel = next
        await render()
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

            case "play":
                await play()

            case "stop":
                await stopPlayback()

            case "row":
                guard let row = Self.rowValue(rest) else { print("? row <0-63|hex>"); return }
                await stopPlayback()
                playheadRow = row
                await render()

            case "jog":
                guard let delta = Int(rest.trimmingCharacters(in: .whitespacesAndNewlines)) else { print("? jog <delta>"); return }
                await turnMainEncoder(delta)

            case "ch", "channel":
                guard let channel = Int(rest.trimmingCharacters(in: .whitespacesAndNewlines)),
                      (1...4).contains(channel) else { print("? ch <1-4>"); return }
                focusedChannel = channel - 1
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

    private static func rowValue(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPrefixedHex = trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X")
        let raw = isPrefixedHex ? String(trimmed.dropFirst(2)) : trimmed
        let hasHexLetters = raw.rangeOfCharacter(from: CharacterSet(charactersIn: "ABCDEFabcdef")) != nil
        let parsed = Int(raw, radix: isPrefixedHex || hasHexLetters ? 16 : 10)
        guard let parsed, (0..<64).contains(parsed) else { return nil }
        return parsed
    }

    private static func demoPatternRows() -> [TrackerDemoRow] {
        var rows = (0..<64).map { _ in TrackerDemoRow(cells: Array(repeating: TrackerDemoCell.empty, count: 4)) }
        let notes = ["C-3", "D#3", "F-3", "G-3", "A#3", "C-4", "D#4", "F-4", "G-4", "A-4", "C-5"]
        let effects = ["...", "A08", "047", "C40", "1F0", "E91", "3A0", "D20", "F06"]

        for row in 0..<64 {
            if row.isMultiple(of: 4) {
                rows[row].cells[0] = TrackerDemoCell(note: notes[(row / 4) % notes.count], instrument: String(format: "%02X", 1 + (row / 16)), volume: "40", effect: effects[(row / 4) % effects.count])
            }
            if row % 8 == 4 {
                rows[row].cells[1] = TrackerDemoCell(note: notes[(row / 8 + 4) % notes.count], instrument: "05", volume: "34", effect: row % 16 == 4 ? "A04" : "...")
            }
            if row % 6 == 0 {
                rows[row].cells[2] = TrackerDemoCell(note: notes[(row / 6 + 7) % notes.count], instrument: "03", volume: "38", effect: row % 12 == 0 ? "C40" : "...")
            }
            if row % 8 == 0 || row % 8 == 2 {
                rows[row].cells[3] = TrackerDemoCell(note: row % 8 == 0 ? "C-4" : "C-5", instrument: row % 16 == 0 ? "07" : "09", volume: "3C", effect: row % 16 == 8 ? "1F0" : "...")
            }
        }

        rows[0].cells[3] = TrackerDemoCell(note: "A-3", instrument: "03", volume: "40", effect: "A09")
        rows[11].cells[3] = TrackerDemoCell(note: "F-4", instrument: "03", volume: "40", effect: "E90")
        rows[31].cells[3] = TrackerDemoCell(note: "G-4", instrument: "08", volume: "34", effect: "200")
        rows[48].cells[3] = TrackerDemoCell(note: "B-4", instrument: "09", volume: "38", effect: "F06")
        return rows
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

private struct TrackerDemoRow: Sendable {
    var cells: [TrackerDemoCell]
}

private struct TrackerDemoCell: Sendable {
    var note: String
    var instrument: String
    var volume: String
    var effect: String

    static let empty = TrackerDemoCell(note: "...", instrument: "..", volume: "..", effect: "...")

    var isEmpty: Bool {
        note == "..." && instrument == ".." && volume == ".." && effect == "..."
    }
}

private enum Palette {
    static let page: UInt16 = 0x0841       // near-black blue
    static let text: UInt16 = 0xffff
    static let dim: UInt16 = 0x8410        // mid grey
    static let accent: UInt16 = 0xffe0     // yellow
    static let border: UInt16 = 0x4208     // faint frame
    static let blue: UInt16 = 0x7dbf
    static let green: UInt16 = 0x464f
    static let orange: UInt16 = 0xec88
    static let note: UInt16 = 0xdedf
    static let instrument: UInt16 = 0x95f2
    static let effect: UInt16 = 0xec88
    static let empty: UInt16 = 0x4a69
    static let ruler: UInt16 = 0x632e
    static let rowStripe: UInt16 = 0x1083
    static let cursorFill: UInt16 = 0x19aa
    static let playheadFill: UInt16 = 0x1125
    static let focusedChannelFill: UInt16 = 0x1026
    static let track: UInt16 = 0x2126
    static let placeholderFill: UInt16 = 0x10a4
}

private extension MK2PixelFrame {
    mutating func hline(y: Int, x: Int, width: Int, color: UInt16) {
        fill(MK2PixelRect(x: x, y: y, width: width, height: 1), color)
    }

    mutating func dottedVLine(x: Int, y: Int, height: Int, color: UInt16) {
        var offset = 0
        while offset < height {
            fill(MK2PixelRect(x: x, y: y + offset, width: 1, height: 1), color)
            offset += 2
        }
    }
}
