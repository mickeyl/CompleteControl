import Foundation
import AVFoundation
import KompleteKontrol
import KontrolSurfaceKit2

// A lab bench for the KontrolSurfaceKit2 widget layer. Everything on screen is composed
// exclusively from kit2 public APIs (BitmapLabel, MK2PixelFrame, MK2SurfaceScene2,
// PixelSnapshot) — no private drawing helpers, no legacy placeholder font. If a unit
// needs something the kit can't express yet, that capability goes into the kit first.
//
// Eight units select via the function buttons. Hardware encoders drive the active
// unit's most useful parameters; the readline REPL mirrors them for fast iteration.
@main
struct MK2WidgetLabDemo {
    static func main() async {
        let surface = MK2Surface2(options: .init(tickHz: 60))
        let lab = WidgetLab(surface: surface)
        let runner = MK2SurfaceEventRunner(name: "surface", surface: surface)
        await runner.run { _ in
            await lab.show(.font)
            printBanner()
            startREPL(lab)
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
    ReplCommand(name: "browsemode", arg: "", summary: "browser unit: cycle list/grid/filter mode", values: []),
    ReplCommand(name: "text", arg: "<string>", summary: "font lab: sample text", values: []),
    ReplCommand(name: "face", arg: "grid|label|readout", summary: "focus face", values: ["grid", "label", "readout"]),
    ReplCommand(name: "weight", arg: "regular|bold", summary: "focus weight", values: ["regular", "bold"]),
    ReplCommand(name: "bold", arg: "on|off", summary: "focus bold toggle", values: ["on", "off"]),
    ReplCommand(name: "scale", arg: "<n>", summary: "focus integer pixel scale", values: []),
    ReplCommand(name: "fg", arg: "<rrggbb|name>", summary: "foreground colour", values: namedColors.keys.sorted()),
    ReplCommand(name: "bg", arg: "<rrggbb|name|none>", summary: "focus highlight background", values: namedColors.keys.sorted() + ["none"]),
    ReplCommand(name: "sample", arg: "<0-3>", summary: "font lab: FreeType sample preset", values: ["0", "1", "2", "3"]),
    ReplCommand(name: "body", arg: "<12-22>", summary: "font lab: body pixel size", values: []),
    ReplCommand(name: "title", arg: "<18-32>", summary: "font lab: title pixel size", values: []),
    ReplCommand(name: "icon", arg: "<0-6|name>", summary: "font lab: icon preset", values: []),
    ReplCommand(name: "iconsize", arg: "<32-72>", summary: "font lab: icon pixel size", values: []),
    ReplCommand(name: "selmode", arg: "", summary: "selection unit: cycle list/grid/filter mode", values: []),
    ReplCommand(name: "play", arg: "", summary: "tracker unit: start playback", values: []),
    ReplCommand(name: "stop", arg: "", summary: "tracker unit: stop playback", values: []),
    ReplCommand(name: "clear", arg: "", summary: "tracker unit: clear pattern with confirmation", values: []),
    ReplCommand(name: "row", arg: "<0-63|hex>", summary: "tracker unit: set stopped playhead row", values: []),
    ReplCommand(name: "jog", arg: "<delta>", summary: "tracker unit: emulate 4D row rotation", values: []),
    ReplCommand(name: "ch", arg: "<1-4>", summary: "tracker unit: set focused channel", values: ["1", "2", "3", "4"]),
    ReplCommand(name: "solo", arg: "on|off|toggle", summary: "tracker unit: solo focused channel", values: ["on", "off", "toggle"]),
    ReplCommand(name: "mute", arg: "on|off|toggle", summary: "tracker unit: mute focused channel", values: ["on", "off", "toggle"]),
    ReplCommand(name: "stripe", arg: "off|odd|even|<n>|every <n> [phase]", summary: "tracker unit: row stripe rule", values: ["off", "odd", "even", "4", "16", "every"]),
    ReplCommand(name: "rec", arg: "on|off|toggle", summary: "tracker unit: arm record", values: ["on", "off", "toggle"]),
    ReplCommand(name: "metro", arg: "on|off|toggle", summary: "tracker unit: toggle metronome", values: ["on", "off", "toggle"]),
    ReplCommand(name: "midi", arg: "<note> [velocity]", summary: "tracker unit: route MIDI to focused channel", values: []),
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
            case .chrome: "BROWSER LAB"
            case .meter: "METER LAB"
            case .list: "SELECTION LAB"
            case .pattern: "PATTERN LAB"
            case .waveform: "WAVEFORM LAB"
            case .keys: "KEYS LAB"
            case .scene: "SCENE LAB"
        }
    }

    var short: String {
        switch self {
            case .font: "FONT"
            case .chrome: "BROW"
            case .meter: "METR"
            case .list: "SEL"
            case .pattern: "PATT"
            case .waveform: "WAVE"
            case .keys: "KEYS"
            case .scene: "SCEN"
        }
    }

    var letter: String { String(UnicodeScalar(UInt8(97 + rawValue))) }
    var implemented: Bool { self == .font || self == .chrome || self == .list || self == .pattern }
    var functionLED: KKMK2ButtonLED {
        KKMK2ButtonLED(rawValue: KKMK2ButtonLED.function1.rawValue + rawValue)!
    }
}

private actor WidgetLab {
    private let surface: MK2Surface2
    private let metronome = DemoMetronome()
    private let freeTypeRenderer: FreeTypeTextRenderer?
    private var unit: Unit = .font

    // Font lab focus: the single combination we render prominently while iterating
    // toward a locked-in choice.
    private var focusRole: SurfaceFont.Role = .grid
    private var focusWeight: SurfaceFont.Weight = .regular
    private var focusScale = 2
    private var focusFG: UInt16 = 0xffff
    private var focusBG: UInt16?
    private var browserMode: BrowserDemoMode = .plainList
    private var browserNavigation = MK2SelectionNavigation()
    private var browserAreaIndex = 0
    private var browserSourceIndex = 0
    private var browserConfirmation = "Noch nichts geöffnet"
    private var sampleText = "Paulinche 0123 ÄÖÜ"
    private var fontSampleIndex = 0
    private var bodyPixelSize = 16
    private var titlePixelSize = 24
    private var iconSampleIndex = 1
    private var iconPixelSize = 48
    private var selectionMode: SelectionDemoMode = .plainList
    private var selectionNavigation = MK2SelectionNavigation()
    private var selectionTypeIndex = 0
    private var selectionToneIndex = 0
    private var selectionBankIndex = 0
    private var selectionCellSizeIndex = 1
    private var selectionConfirmation = "Noch nichts bestätigt"
    private var isPlaying = false
    private var recordArmed = false
    private var metronomeEnabled = false
    private var playheadRow = 0
    private var rowStripeMode = RowStripeMode.every(4)
    private var selectedInstrumentIndex = 0
    private var modalDialog: ActiveModalDialog?
    private var playbackTimer: DispatchSourceTimer?
    private var patternRows: [TrackerDemoRow]
    private var focusedChannel = 3
    private var midiInputByChannel = Array(repeating: "NO MIDI", count: 4)
    private var mutedChannels: Set<Int> = []
    private var soloedChannels: Set<Int> = []
    private var focusedEditField: TrackerEditField = .note
    private static let availableIntensity: UInt8 = 0x01
    private static let activeIntensity: UInt8 = 0x03
    private static let actionWhite = KKRGB(red: 0xff, green: 0xff, blue: 0xff)
    private static let actionGreen = KKRGB(red: 0x00, green: 0xff, blue: 0x66)
    private static let actionRed = KKRGB(red: 0xff, green: 0x18, blue: 0x18)
    private static let soloColor = KKRGB(red: 0x00, green: 0x7f, blue: 0xff)
    private static let muteColor = KKRGB(red: 0xff, green: 0x18, blue: 0x18)
    private static let demoInstruments = [
        DemoInstrument(number: "01", name: "Kick Resin"),
        DemoInstrument(number: "02", name: "Snare Alloy"),
        DemoInstrument(number: "03", name: "Hat Needle"),
        DemoInstrument(number: "04", name: "Bass Rubber"),
        DemoInstrument(number: "05", name: "Lead Glass"),
        DemoInstrument(number: "06", name: "Chord Tape"),
        DemoInstrument(number: "07", name: "Arp Carbon"),
        DemoInstrument(number: "08", name: "Pad Violet"),
        DemoInstrument(number: "09", name: "Tom Box"),
        DemoInstrument(number: "0A", name: "Pluck FM"),
        DemoInstrument(number: "0B", name: "Bell Dust"),
        DemoInstrument(number: "0C", name: "Organ Mini"),
        DemoInstrument(number: "0D", name: "Noise Rise"),
        DemoInstrument(number: "0E", name: "Vox Byte"),
        DemoInstrument(number: "0F", name: "Hit Plate"),
        DemoInstrument(number: "10", name: "Sub Pure"),
    ]
    private static let instrumentIndexBounds = 0...(demoInstruments.count - 1)
    private static let fontSamples = [
        FontLabSample(
            label: "Dialog",
            title: "Pattern löschen?",
            body: "Wollen Sie das aktuelle Pattern wirklich löschen?",
            detail: "4D bestätigt, jede andere Hardware-Taste bricht ab."
        ),
        FontLabSample(
            label: "Browser",
            title: "Instrument Browser",
            body: "Kick Resin, Snare Alloy, Hat Needle, Bass Rubber",
            detail: "Längere Listentexte bleiben ruhig und gut lesbar."
        ),
        FontLabSample(
            label: "Settings",
            title: "MIDI Routing",
            body: "Channel 3 empfängt live und schreibt Steps in Pattern 03.",
            detail: "Body Regular, Titel Medium, Icons Pro Light."
        ),
        FontLabSample(
            label: "German",
            title: "Globale Einstellungen",
            body: "Größen, Dicken und Umlaute prüfen: ÄÖÜ äöü ß.",
            detail: "Zahlen und Einheiten: 120 BPM, 16 Steps, 80 %."
        ),
    ]
    private static let fontIconSamples = [
        FontLabIconSample(name: "Info", glyph: "\u{f05a}", color: Palette.blue),
        FontLabIconSample(name: "Warn", glyph: "\u{f071}", color: Palette.accent),
        FontLabIconSample(name: "Error", glyph: "\u{f057}", color: Palette.orange),
        FontLabIconSample(name: "Question", glyph: "\u{f059}", color: Palette.question),
        FontLabIconSample(name: "Save", glyph: "\u{f0c7}", color: Palette.green),
        FontLabIconSample(name: "Sliders", glyph: "\u{f1de}", color: Palette.solo),
        FontLabIconSample(name: "Trash", glyph: "\u{f2ed}", color: Palette.mute),
    ]
    init(surface: MK2Surface2) {
        self.surface = surface
        self.freeTypeRenderer = try? FreeTypeTextRenderer()
        self.patternRows = WidgetLab.demoPatternRows()
    }

    private var selectedInstrument: DemoInstrument {
        let index = max(Self.instrumentIndexBounds.lowerBound, min(Self.instrumentIndexBounds.upperBound, selectedInstrumentIndex))
        return Self.demoInstruments[index]
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
        if let modalDialog {
            return modalScene(modalDialog)
        }

        var lamps: [KKMK2ButtonLED: MK2LampState2] = [:]
        for candidate in Unit.allCases {
            lamps[candidate.functionLED] = candidate == unit
                ? Self.activeLamp(Self.actionWhite)
                : (candidate.implemented ? Self.availableLamp(Self.actionWhite) : .off)
        }
        if unit == .chrome {
            lamps[.instance] = Self.availableLamp(Self.actionWhite)
        } else if unit == .list {
            lamps[.instance] = Self.availableLamp(Self.actionWhite)
        } else if unit == .pattern {
            lamps[.play] = isPlaying ? Self.activeLamp(Self.actionGreen) : Self.availableLamp(Self.actionGreen)
            lamps[.stop] = isPlaying ? Self.availableLamp(Self.actionRed) : Self.activeLamp(Self.actionRed)
            lamps[.record] = recordArmed ? Self.activeLamp(Self.actionRed) : Self.availableLamp(Self.actionRed)
            lamps[.clear] = Self.availableLamp(Self.actionWhite)
            lamps[.pageLeft] = focusedChannel > 0 ? Self.availableLamp(Self.actionWhite) : .off
            lamps[.pageRight] = focusedChannel < 3 ? Self.availableLamp(Self.actionWhite) : .off
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
        bindings.onPress(.record) { [weak self] in
            Task { await self?.toggleRecordArm() }
        }
        bindings.onPress(.clear) { [weak self] in
            Task { await self?.showClearPatternDialog() }
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
        if unit == .font {
            for binding in fontLabEncoderBindings() {
                binding.apply(bindings: &bindings)
            }
        } else if unit == .chrome {
            bindings.onPress(.instance) { [weak self] in
                Task { await self?.cycleBrowserMode() }
            }
            bindings.jog = { [weak self] direction in
                Task { await self?.handleBrowserJog(direction) }
            }
            for binding in browserEncoderBindings() {
                binding.apply(bindings: &bindings)
            }
        } else if unit == .list {
            bindings.onPress(.instance) { [weak self] in
                Task { await self?.cycleSelectionMode() }
            }
            bindings.jog = { [weak self] direction in
                Task { await self?.handleSelectionJog(direction) }
            }
            for binding in selectionEncoderBindings() {
                binding.apply(bindings: &bindings)
            }
        } else if unit == .pattern {
            MK2ButtonToggle(
                button: .metro,
                isOn: metronomeEnabled,
                onLamp: Self.activeLamp(Self.actionWhite),
                offLamp: Self.availableLamp(Self.actionWhite)
            ) { [weak self] enabled in
                Task { await self?.setMetronomeEnabled(enabled) }
            }
            .apply(lamps: &lamps, bindings: &bindings)

            channelMuteToggle(focusedChannel) { [weak self] enabled in
                Task { await self?.setFocusedChannelMute(enabled) }
            }
            .apply(lamps: &lamps, bindings: &bindings)

            channelSoloToggle(focusedChannel) { [weak self] enabled in
                Task { await self?.setFocusedChannelSolo(enabled) }
            }
            .apply(lamps: &lamps, bindings: &bindings)

            for binding in editFieldEncoderBindings() {
                binding.apply(bindings: &bindings)
            }

            MK2ButtonRangeSelection(
                value: selectedInstrumentIndex,
                bounds: Self.instrumentIndexBounds,
                previousButton: .presetUp,
                nextButton: .presetDown,
                availableLamp: Self.availableLamp(Self.actionWhite)
            ) { [weak self] index in
                Task { await self?.setSelectedInstrumentIndex(index) }
            }
            .apply(lamps: &lamps, bindings: &bindings)

            let targetChannel = focusedChannel
            bindings.midiFocus = MIDIFocus("tracker.channel.\(targetChannel + 1)") { [weak self] event in
                Task { await self?.receiveMIDI(event, targetChannel: targetChannel) }
            }
        }

        let (left, right) = frames()
        return MK2SurfaceScene2(left: left, right: right, lamps: lamps, bindings: bindings)
    }

    private func modalScene(_ modalDialog: ActiveModalDialog) -> MK2SurfaceScene2 {
        switch modalDialog {
            case let .clearPattern(selectedIndex):
                return MK2ModalDialog(
                    severity: .warning,
                    title: "PATTERN LÖSCHEN",
                    message: [
                        "Wollen Sie das aktuelle",
                        "Pattern wirklich löschen?",
                    ],
                    actions: [
                        MK2ModalDialogAction("Ja, löschen", detail: "Aktuelles Pattern wird geleert"),
                    ],
                    selectedIndex: selectedIndex,
                    dismissHint: "Andere Hardware-Taste: Abbrechen",
                    onSelectionChange: { [weak self] index in
                        Task { await self?.setModalSelection(index) }
                    },
                    onConfirm: { [weak self] _ in
                        Task { await self?.confirmModalDialog() }
                    },
                    onDismiss: { [weak self] in
                        Task { await self?.dismissModalDialog() }
                    }
                ).scene()
        }
    }

    private static func availableLamp(_ color: KKRGB) -> MK2LampState2 {
        .on(color, intensity: availableIntensity)
    }

    private static func activeLamp(_ color: KKRGB) -> MK2LampState2 {
        .on(color, intensity: activeIntensity)
    }

    private func frames() -> (MK2PixelFrame, MK2PixelFrame) {
        switch unit {
            case .font: (fontCatalogFrame(), fontFocusFrame())
            case .chrome: (browserDetailFrame(), browserPickerFrame())
            case .list: (selectionStatusFrame(), selectionPickerFrame())
            case .pattern: (trackerGridFrame(), trackerDetailFrame())
            default: (comingSoonFrame(), placeholderRightFrame())
        }
    }

    // MARK: - Font lab

    // Left screen: every face rendered at native scale so relative sizes/weights are
    // directly comparable against the same sample string.
    private func fontCatalogFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        BitmapLabel("FONT LAB - FREETYPE + BITMAP", font: .label, color: Palette.accent)
            .draw(into: &frame, x: 8, y: 8)

        drawFreeTypeTitle("Globaler Dialogtitel", into: &frame, x: 8, y: 32, size: 24, color: Palette.text, maxWidth: 448)
        drawFreeTypeBody("Body Regular 16 px: Listen, Dialoge, Browser, Settings.", into: &frame, x: 8, y: 70, size: 16, color: Palette.dim, maxWidth: 448)
        drawFreeTypeBody("Tracker und Grid bleiben bitmap-scharf.", into: &frame, x: 8, y: 94, size: 16, color: Palette.empty, maxWidth: 448)

        let icons = Array(Self.fontIconSamples.prefix(4))
        for (index, icon) in icons.enumerated() {
            let x = 28 + index * 110
            drawFreeTypeIcon(icon.glyph, into: &frame, x: x, y: 122, size: 40, color: icon.color)
            BitmapLabel(icon.name.uppercased(), font: .label, color: Palette.dim)
                .draw(into: &frame, x: x - 10, y: 174, clip: MK2PixelRect(x: x - 10, y: 174, width: 92, height: 14))
        }

        frame.hline(y: 198, x: 8, width: 456, color: Palette.border)

        let faces: [(String, SurfaceFont)] = [
            ("BITMAP GRID", .grid), ("GRID BOLD", .gridBold), ("LABEL", .label),
        ]
        var y = 212
        for (name, font) in faces {
            BitmapLabel(name, font: .label, color: Palette.dim).draw(into: &frame, x: 8, y: y + 1)
            BitmapLabel(sampleText, font: font, color: Palette.text)
                .draw(into: &frame, x: 112, y: y, clip: MK2PixelRect(x: 112, y: y, width: 352, height: font.cellHeight))
            y += font.cellHeight + 8
        }
        return frame
    }

    // MARK: - Browser lab

    private func browserDetailFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        let items = filteredBrowserItems()
        let selected = selectedBrowserItem()
        BitmapLabel("BROWSER LAB", font: .label, color: Palette.accent)
            .draw(into: &frame, x: 8, y: 8)
        drawFreeTypeTitle(browserMode.title, into: &frame, x: 16, y: 40, size: 24, color: Palette.text, maxWidth: 420)
        drawFreeTypeBody("INSTANCE schaltet List/Grid/Filter. 4D wählt, 4D-Press öffnet.", into: &frame, x: 16, y: 78, size: 16, color: Palette.dim, maxWidth: 432)
        drawFreeTypeBody("Treffer: \(items.count) / \(BrowserLabFixtures.items.count)", into: &frame, x: 16, y: 118, size: 16, color: Palette.text, maxWidth: 432)

        if let selected {
            drawFreeTypeIcon(selected.icon, into: &frame, x: 24, y: 148, size: 48, color: Palette.accent)
            drawFreeTypeTitle(selected.title, into: &frame, x: 92, y: 146, size: 24, color: Palette.text, maxWidth: 344)
            drawFreeTypeBody(selected.detail, into: &frame, x: 92, y: 184, size: 16, color: Palette.dim, maxWidth: 344)
            drawFreeTypeBody("\(selected.area) · \(selected.source) · \(selected.status)", into: &frame, x: 92, y: 222, size: 16, color: Palette.blue, maxWidth: 344)
        } else {
            drawFreeTypeBody("Keine Einträge für diese Filter.", into: &frame, x: 16, y: 154, size: 16, color: Palette.empty, maxWidth: 432)
        }
        drawFreeTypeBody(browserConfirmation, into: &frame, x: 16, y: 250, size: 16, color: Palette.empty, maxWidth: 432)
        return frame
    }

    private func browserPickerFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        let items = filteredBrowserItems().map(\.selectionItem)
        let filters = browserMode.hasFilters ? browserFilters() : []
        let colors = MK2SelectionViewColors(
            background: Palette.page,
            text: Palette.text,
            dim: Palette.dim,
            muted: Palette.empty,
            accent: Palette.accent,
            selectionFill: Palette.selectionFill,
            border: Palette.border,
            filterFill: Palette.filterFill
        )
        if browserMode.isGrid {
            MK2SelectionGrid(
                title: browserMode.shortTitle,
                subtitle: browserMode.hasFilters ? "4D select, E5/E6 filter" : "4D select, INSTANCE mode",
                items: items,
                selectedIndex: browserNavigation.selectedIndex,
                cellSize: BrowserLabFixtures.gridCellSizes[0],
                filters: filters,
                colors: colors
            ).draw(into: &frame, renderer: freeTypeRenderer)
        } else {
            MK2SelectionList(
                title: browserMode.shortTitle,
                subtitle: browserMode.hasFilters ? "4D select, E5/E6 filter" : "4D select, INSTANCE mode",
                items: items,
                selectedIndex: browserNavigation.selectedIndex,
                filters: filters,
                rowHeight: browserMode.hasFilters ? 44 : 36,
                colors: colors
            ).draw(into: &frame, renderer: freeTypeRenderer)
        }
        return frame
    }

    // MARK: - Selection lab

    private func selectionStatusFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        let items = filteredSelectionItems()
        let selected = selectedSelectionItem()
        BitmapLabel("SELECTION LAB", font: .label, color: Palette.accent)
            .draw(into: &frame, x: 8, y: 8)
        drawFreeTypeTitle(selectionMode.title, into: &frame, x: 16, y: 42, size: 24, color: Palette.text, maxWidth: 432)
        drawFreeTypeBody("INSTANCE schaltet Plain List, Plain Grid, Filtered List und Filtered Grid.", into: &frame, x: 16, y: 82, size: 16, color: Palette.dim, maxWidth: 432)
        drawFreeTypeBody("4D dreht durch die Auswahl, 4D-Press bestätigt.", into: &frame, x: 16, y: 126, size: 16, color: Palette.dim, maxWidth: 432)
        drawFreeTypeBody("Treffer: \(items.count) / \(SelectionLabFixtures.items.count)", into: &frame, x: 16, y: 164, size: 16, color: Palette.text, maxWidth: 432)
        if let selected {
            drawFreeTypeBody("Aktuell: \(selected.title)", into: &frame, x: 16, y: 192, size: 16, color: Palette.blue, maxWidth: 432)
        }
        drawFreeTypeBody(selectionConfirmation, into: &frame, x: 16, y: 236, size: 16, color: Palette.empty, maxWidth: 432)
        return frame
    }

    private func selectionPickerFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        let items = filteredSelectionItems().map(\.selectionItem)
        let filters = selectionMode.hasFilters ? selectionFilters() : []
        let subtitle = selectionMode.hasFilters ? "4D select, E5-E7 filter" : "4D select, INSTANCE mode"
        let colors = MK2SelectionViewColors(
            background: Palette.page,
            text: Palette.text,
            dim: Palette.dim,
            muted: Palette.empty,
            accent: Palette.accent,
            selectionFill: Palette.selectionFill,
            border: Palette.border,
            filterFill: Palette.filterFill
        )

        if selectionMode.isGrid {
            MK2SelectionGrid(
                title: selectionMode.shortTitle,
                subtitle: subtitle,
                items: items,
                selectedIndex: selectionNavigation.selectedIndex,
                cellSize: SelectionLabFixtures.cellSizes[selectionCellSizeIndex],
                filters: filters,
                colors: colors
            ).draw(into: &frame, renderer: freeTypeRenderer)
        } else {
            MK2SelectionList(
                title: selectionMode.shortTitle,
                subtitle: subtitle,
                items: items,
                selectedIndex: selectionNavigation.selectedIndex,
                filters: filters,
                rowHeight: selectionMode.hasFilters ? 44 : 30,
                colors: colors
            ).draw(into: &frame, renderer: freeTypeRenderer)
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

        for (index, x) in rulerXs.dropLast().enumerated() {
            let active = index == focusedChannel
            BitmapLabel("CHANNEL \(index + 1)", font: .label, color: active ? Palette.blue : Palette.dim)
                .draw(into: &frame, x: x, y: 38)
            drawChannelButton(
                channelMuteToggle(index, display: channelToggleDisplay("M", kind: .mute, x: x + 69, y: 34)),
                into: &frame
            )
            drawChannelButton(
                channelSoloToggle(index, display: channelToggleDisplay("S", kind: .solo, x: x + 87, y: 34)),
                into: &frame
            )
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
            } else if rowStripeMode.matches(row) {
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

        let selectedInstrumentText = "INST \(selectedInstrument.displayName)"

        MK2StatusLine(y: 8, items: [
            MK2StatusLineItem("EDIT", x: 8, color: Palette.blue),
            MK2StatusLineItem("CH\(focusedChannel + 1)", x: 92, color: Palette.dim),
            MK2StatusLineItem("ROW \(hex2(playheadRow))", x: 158, color: Palette.text, font: .gridBold),
        ]).draw(into: &frame)
        BitmapLabel(selectedInstrumentText, font: .grid, color: Palette.instrument)
            .draw(into: &frame, x: 232, y: 8, clip: MK2PixelRect(x: 232, y: 8, width: 240, height: SurfaceFont.grid.cellHeight))

        frame.hline(y: 55, x: 0, width: 480, color: Palette.border)

        let fieldY = 232
        let fieldCornerRadius = 7
        MK2ValueCell(
            label: "NOTE",
            value: cell.note,
            rect: MK2PixelRect(x: 8, y: fieldY, width: 96, height: 36),
            isFocused: focusedEditField == .note,
            valueFont: .readoutBold,
            cornerRadius: fieldCornerRadius,
            colors: editCellColors(value: Palette.text)
        ).draw(into: &frame)
        MK2ValueCell(
            label: "INST",
            value: cell.instrument,
            rect: MK2PixelRect(x: 128, y: fieldY, width: 80, height: 36),
            isFocused: focusedEditField == .instrument,
            valueFont: .readoutBold,
            cornerRadius: fieldCornerRadius,
            colors: editCellColors(value: Palette.instrument)
        ).draw(into: &frame)
        MK2ValueCell(
            label: "VOL",
            value: cell.volume,
            rect: MK2PixelRect(x: 252, y: fieldY, width: 80, height: 36),
            isFocused: focusedEditField == .volume,
            valueFont: .readoutBold,
            cornerRadius: fieldCornerRadius,
            colors: editCellColors(value: Palette.text)
        ).draw(into: &frame)
        MK2ValueCell(
            label: "FX",
            value: cell.effect,
            rect: MK2PixelRect(x: 376, y: fieldY, width: 88, height: 36),
            isFocused: focusedEditField == .effect,
            valueFont: .readoutBold,
            cornerRadius: fieldCornerRadius,
            colors: editCellColors(value: Palette.effect)
        ).draw(into: &frame)
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

    private func drawChannelButton(_ toggle: MK2ButtonToggle, into frame: inout MK2PixelFrame) {
        toggle.drawDisplay(into: &frame)
    }

    private func editCellColors(value: UInt16) -> MK2ValueCellColors {
        MK2ValueCellColors(
            label: Palette.dim,
            value: value,
            border: Palette.border,
            fill: Palette.editFieldFill,
            focusedValue: 0x0000,
            focusedFill: Palette.editFieldFocusedFill,
            focusedBorder: Palette.text
        )
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
        playMetronomeIfNeeded(row: playheadRow)
        await render()
        playbackTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(180), repeating: .milliseconds(180), leeway: .nanoseconds(0))
        timer.setEventHandler {
            Task { await self.advancePlayback() }
        }
        playbackTimer = timer
        timer.resume()
    }

    private func stopPlayback() async {
        let wasPlaying = isPlaying
        isPlaying = false
        playbackTimer?.cancel()
        playbackTimer = nil
        if !wasPlaying {
            playheadRow = 0
        }
        await render()
    }

    private func advancePlayback() async {
        guard isPlaying else { return }
        playheadRow = (playheadRow + 1) % patternRows.count
        playMetronomeIfNeeded(row: playheadRow)
        await render()
    }

    private func turnMainEncoder(_ delta: Int) async {
        guard delta != 0 else { return }
        switch unit {
            case .font:
                setFontSampleIndex(fontSampleIndex + delta)
                await render()
            case .chrome:
                await moveBrowserSelection(delta)
            case .list:
                await moveSelection(delta)
            case .pattern:
                guard !isPlaying else { return }
                playheadRow = max(0, min(patternRows.count - 1, playheadRow + delta))
                await render()
            default:
                return
        }
    }

    private func fontLabEncoderBindings() -> [MK2EncoderDiscreteValue] {
        [
            MK2EncoderDiscreteValue(
                encoder: 5,
                value: bodyPixelSize,
                bounds: 12...22,
                wraps: false,
                onChange: { [weak self] value in
                    Task { await self?.setBodyPixelSize(value) }
                }
            ),
            MK2EncoderDiscreteValue(
                encoder: 6,
                value: titlePixelSize,
                bounds: 18...32,
                wraps: false,
                onChange: { [weak self] value in
                    Task { await self?.setTitlePixelSize(value) }
                }
            ),
            MK2EncoderDiscreteValue(
                encoder: 7,
                value: iconSampleIndex,
                bounds: 0...(Self.fontIconSamples.count - 1),
                wraps: true,
                onChange: { [weak self] value in
                    Task { await self?.setIconSampleIndex(value) }
                }
            ),
            MK2EncoderDiscreteValue(
                encoder: 8,
                value: iconPixelSize,
                bounds: 32...72,
                step: 2,
                wraps: false,
                onChange: { [weak self] value in
                    Task { await self?.setIconPixelSize(value) }
                }
            ),
        ]
    }

    private func setFontSampleIndex(_ value: Int) {
        fontSampleIndex = value.wrapped(to: 0...(Self.fontSamples.count - 1))
        sampleText = Self.fontSamples[fontSampleIndex].title
    }

    private func setBodyPixelSize(_ value: Int) async {
        bodyPixelSize = max(12, min(22, value))
        await render()
    }

    private func setTitlePixelSize(_ value: Int) async {
        titlePixelSize = max(18, min(32, value))
        await render()
    }

    private func setIconSampleIndex(_ value: Int) async {
        iconSampleIndex = value.wrapped(to: 0...(Self.fontIconSamples.count - 1))
        await render()
    }

    private func setIconPixelSize(_ value: Int) async {
        iconPixelSize = max(32, min(72, value))
        await render()
    }

    private func cycleBrowserMode() async {
        guard unit == .chrome else { return }
        browserMode = browserMode.next
        if !browserMode.hasFilters {
            browserNavigation.setFilterFocus(encoder: nil)
        }
        clampBrowserSelection()
        await render()
    }

    private func handleBrowserJog(_ direction: String) async {
        guard unit == .chrome else { return }
        let rowStep = browserMode.isGrid
            ? MK2SelectionLayout.gridRowStep(for: BrowserLabFixtures.gridCellSizes[0])
            : 1
        switch direction {
            case "up":
                await moveBrowserSelection(-rowStep)
            case "down":
                await moveBrowserSelection(rowStep)
            case "press":
                await confirmBrowserSelection()
            default:
                break
        }
    }

    private func moveBrowserSelection(_ delta: Int) async {
        guard unit == .chrome, delta != 0 else { return }
        if browserNavigation.move(by: delta, itemCount: filteredBrowserItems().count) {
            await render()
        }
    }

    private func confirmBrowserSelection() async {
        guard unit == .chrome, let selected = selectedBrowserItem() else { return }
        browserConfirmation = "Geöffnet: \(selected.title)"
        await render()
    }

    private func browserEncoderBindings() -> [MK2EncoderDiscreteValue] {
        guard browserMode.hasFilters else { return [] }
        return [
            MK2EncoderDiscreteValue(
                encoder: 5,
                value: browserAreaIndex,
                bounds: 0...(BrowserLabFixtures.areas.count - 1),
                wraps: true,
                onTouch: { [weak self] touched in
                    Task { await self?.setBrowserFilterFocus(encoder: 5, touched: touched) }
                },
                onChange: { [weak self] value in
                    Task { await self?.setBrowserArea(value) }
                }
            ),
            MK2EncoderDiscreteValue(
                encoder: 6,
                value: browserSourceIndex,
                bounds: 0...(BrowserLabFixtures.sources.count - 1),
                wraps: true,
                onTouch: { [weak self] touched in
                    Task { await self?.setBrowserFilterFocus(encoder: 6, touched: touched) }
                },
                onChange: { [weak self] value in
                    Task { await self?.setBrowserSource(value) }
                }
            ),
        ]
    }

    private func setBrowserArea(_ value: Int) async {
        guard unit == .chrome else { return }
        browserNavigation.setFilterFocus(encoder: 5)
        browserAreaIndex = value.wrapped(to: 0...(BrowserLabFixtures.areas.count - 1))
        clampBrowserSelection()
        await render()
    }

    private func setBrowserSource(_ value: Int) async {
        guard unit == .chrome else { return }
        browserNavigation.setFilterFocus(encoder: 6)
        browserSourceIndex = value.wrapped(to: 0...(BrowserLabFixtures.sources.count - 1))
        clampBrowserSelection()
        await render()
    }

    private func setBrowserFilterFocus(encoder: Int, touched: Bool) async {
        guard unit == .chrome, browserMode.hasFilters else { return }
        browserNavigation.touchFilter(encoder: encoder, touched: touched)
        await render()
    }

    private func selectedBrowserItem() -> BrowserDemoItem? {
        let items = filteredBrowserItems()
        guard let index = browserNavigation.clampedSelectedIndex(itemCount: items.count) else { return nil }
        return items[index]
    }

    private func filteredBrowserItems() -> [BrowserDemoItem] {
        guard browserMode.hasFilters else { return BrowserLabFixtures.items }
        let area = BrowserLabFixtures.areas[browserAreaIndex]
        let source = BrowserLabFixtures.sources[browserSourceIndex]
        return BrowserLabFixtures.items.filter { item in
            (area == "All" || item.area == area)
                && (source == "All" || item.source == source)
        }
    }

    private func browserFilters() -> [MK2SelectionFilter] {
        [
            MK2SelectionFilter(label: "AREA", value: BrowserLabFixtures.areas[browserAreaIndex], encoder: 5, isActive: browserAreaIndex != 0, isFocused: browserNavigation.focusedFilterEncoder == 5),
            MK2SelectionFilter(label: "SRC", value: BrowserLabFixtures.sources[browserSourceIndex], encoder: 6, isActive: browserSourceIndex != 0, isFocused: browserNavigation.focusedFilterEncoder == 6),
        ]
    }

    private func clampBrowserSelection() {
        browserNavigation.clamp(itemCount: filteredBrowserItems().count)
    }

    private func cycleSelectionMode() async {
        guard unit == .list else { return }
        selectionMode = selectionMode.next
        if !selectionMode.hasFilters {
            selectionNavigation.setFilterFocus(encoder: nil)
        }
        clampSelectionIndex()
        await render()
    }

    private func handleSelectionJog(_ direction: String) async {
        guard unit == .list else { return }
        let rowStep = selectionMode.isGrid
            ? MK2SelectionLayout.gridRowStep(for: SelectionLabFixtures.cellSizes[selectionCellSizeIndex])
            : 1
        switch direction {
            case "up":
                await moveSelection(-rowStep)
            case "down":
                await moveSelection(rowStep)
            case "press":
                await confirmSelection()
            default:
                break
        }
    }

    private func moveSelection(_ delta: Int) async {
        guard unit == .list, delta != 0 else { return }
        if selectionNavigation.move(by: delta, itemCount: filteredSelectionItems().count) {
            await render()
        }
    }

    private func confirmSelection() async {
        guard unit == .list, let selected = selectedSelectionItem() else { return }
        selectionConfirmation = "Bestätigt: \(selected.title)"
        await render()
    }

    private func selectionEncoderBindings() -> [MK2EncoderDiscreteValue] {
        guard selectionMode.hasFilters else { return [] }
        var bindings = [
            MK2EncoderDiscreteValue(
                encoder: 5,
                value: selectionTypeIndex,
                bounds: 0...(SelectionLabFixtures.types.count - 1),
                wraps: true,
                onTouch: { [weak self] touched in
                    Task { await self?.setSelectionFilterFocus(encoder: 5, touched: touched) }
                },
                onChange: { [weak self] value in
                    Task { await self?.setSelectionType(value) }
                }
            ),
            MK2EncoderDiscreteValue(
                encoder: 6,
                value: selectionToneIndex,
                bounds: 0...(SelectionLabFixtures.tones.count - 1),
                wraps: true,
                onTouch: { [weak self] touched in
                    Task { await self?.setSelectionFilterFocus(encoder: 6, touched: touched) }
                },
                onChange: { [weak self] value in
                    Task { await self?.setSelectionTone(value) }
                }
            ),
            MK2EncoderDiscreteValue(
                encoder: 7,
                value: selectionBankIndex,
                bounds: 0...(SelectionLabFixtures.banks.count - 1),
                wraps: true,
                onTouch: { [weak self] touched in
                    Task { await self?.setSelectionFilterFocus(encoder: 7, touched: touched) }
                },
                onChange: { [weak self] value in
                    Task { await self?.setSelectionBank(value) }
                }
            )
        ]
        if selectionMode.isGrid {
            bindings.append(
                MK2EncoderDiscreteValue(
                    encoder: 8,
                    value: selectionCellSizeIndex,
                    bounds: 0...(SelectionLabFixtures.cellSizes.count - 1),
                    wraps: true,
                    onTouch: { [weak self] touched in
                        Task { await self?.setSelectionFilterFocus(encoder: 8, touched: touched) }
                    },
                    onChange: { [weak self] value in
                        Task { await self?.setSelectionCellSize(value) }
                    }
                )
            )
        }
        return bindings
    }

    private func setSelectionType(_ value: Int) async {
        guard unit == .list else { return }
        selectionNavigation.setFilterFocus(encoder: 5)
        selectionTypeIndex = value.wrapped(to: 0...(SelectionLabFixtures.types.count - 1))
        clampSelectionIndex()
        await render()
    }

    private func setSelectionTone(_ value: Int) async {
        guard unit == .list else { return }
        selectionNavigation.setFilterFocus(encoder: 6)
        selectionToneIndex = value.wrapped(to: 0...(SelectionLabFixtures.tones.count - 1))
        clampSelectionIndex()
        await render()
    }

    private func setSelectionBank(_ value: Int) async {
        guard unit == .list else { return }
        selectionNavigation.setFilterFocus(encoder: 7)
        selectionBankIndex = value.wrapped(to: 0...(SelectionLabFixtures.banks.count - 1))
        clampSelectionIndex()
        await render()
    }

    private func setSelectionCellSize(_ value: Int) async {
        guard unit == .list else { return }
        selectionNavigation.setFilterFocus(encoder: 8)
        selectionCellSizeIndex = value.wrapped(to: 0...(SelectionLabFixtures.cellSizes.count - 1))
        clampSelectionIndex()
        await render()
    }

    private func setSelectionFilterFocus(encoder: Int, touched: Bool) async {
        guard unit == .list, selectionMode.hasFilters else { return }
        selectionNavigation.touchFilter(encoder: encoder, touched: touched)
        await render()
    }

    private func selectedSelectionItem() -> SelectionDemoItem? {
        let items = filteredSelectionItems()
        guard let index = selectionNavigation.clampedSelectedIndex(itemCount: items.count) else { return nil }
        return items[index]
    }

    private func filteredSelectionItems() -> [SelectionDemoItem] {
        guard selectionMode.hasFilters else { return SelectionLabFixtures.items }
        let type = SelectionLabFixtures.types[selectionTypeIndex]
        let tone = SelectionLabFixtures.tones[selectionToneIndex]
        let bank = SelectionLabFixtures.banks[selectionBankIndex]
        return SelectionLabFixtures.items.filter { item in
            (type == "All" || item.category == type)
                && (tone == "All" || item.tone == tone)
                && (bank == "All" || item.bank == bank)
        }
    }

    private func selectionFilters() -> [MK2SelectionFilter] {
        var filters = [
            MK2SelectionFilter(label: "TYPE", value: SelectionLabFixtures.types[selectionTypeIndex], encoder: 5, isActive: selectionTypeIndex != 0, isFocused: selectionNavigation.focusedFilterEncoder == 5),
            MK2SelectionFilter(label: "TONE", value: SelectionLabFixtures.tones[selectionToneIndex], encoder: 6, isActive: selectionToneIndex != 0, isFocused: selectionNavigation.focusedFilterEncoder == 6),
            MK2SelectionFilter(label: "BANK", value: SelectionLabFixtures.banks[selectionBankIndex], encoder: 7, isActive: selectionBankIndex != 0, isFocused: selectionNavigation.focusedFilterEncoder == 7),
        ]
        if selectionMode.isGrid {
            let size = SelectionLabFixtures.cellSizes[selectionCellSizeIndex]
            filters.append(MK2SelectionFilter(label: "CELL", value: "\(size.width)x\(size.height)", encoder: 8, isActive: true, isFocused: selectionNavigation.focusedFilterEncoder == 8))
        }
        return filters
    }

    private func clampSelectionIndex() {
        selectionNavigation.clamp(itemCount: filteredSelectionItems().count)
    }

    private func moveFocusedChannel(_ delta: Int) async {
        guard unit == .pattern, delta != 0 else { return }
        let next = max(0, min(3, focusedChannel + delta))
        guard next != focusedChannel else { return }
        focusedChannel = next
        await render()
    }

    private func setFocusedChannelSolo(_ enabled: Bool) async {
        guard unit == .pattern else { return }
        if enabled {
            soloedChannels.insert(focusedChannel)
        } else {
            soloedChannels.remove(focusedChannel)
        }
        await render()
    }

    private func setFocusedChannelMute(_ enabled: Bool) async {
        guard unit == .pattern else { return }
        if enabled {
            mutedChannels.insert(focusedChannel)
        } else {
            mutedChannels.remove(focusedChannel)
        }
        await render()
    }

    private func focusEditField(_ field: TrackerEditField) async {
        guard unit == .pattern else { return }
        focusedEditField = field
        await render()
    }

    private func setFocusedEditValue(_ value: Int, field: TrackerEditField) async {
        guard unit == .pattern,
              patternRows.indices.contains(playheadRow),
              patternRows[playheadRow].cells.indices.contains(focusedChannel) else { return }

        focusedEditField = field
        switch field {
            case .note:
                patternRows[playheadRow].cells[focusedChannel].note = Self.midiNoteName(UInt8(max(0, min(127, value))))
            case .instrument:
                patternRows[playheadRow].cells[focusedChannel].instrument = String(format: "%02X", max(0, min(255, value)))
            case .volume:
                patternRows[playheadRow].cells[focusedChannel].volume = String(format: "%02X", max(0, min(64, value)))
            case .effect:
                patternRows[playheadRow].cells[focusedChannel].effect = String(format: "%03X", max(0, min(0xfff, value)))
        }
        await render()
    }

    private func editFieldEncoderBindings() -> [MK2EncoderDiscreteValue] {
        let cell = patternRows[playheadRow].cells[focusedChannel]
        return TrackerEditField.allCases.map { field in
            MK2EncoderDiscreteValue(
                encoder: field.encoder,
                value: editValue(for: field, cell: cell),
                bounds: field.bounds,
                wraps: false,
                onTouch: { [weak self] touched in
                    guard touched else { return }
                    Task { await self?.focusEditField(field) }
                },
                onChange: { [weak self] value in
                    Task { await self?.setFocusedEditValue(value, field: field) }
                }
            )
        }
    }

    private func editValue(for field: TrackerEditField, cell: TrackerDemoCell) -> Int {
        switch field {
            case .note:
                Self.midiNoteValue(cell.note) ?? 60
            case .instrument:
                Int(cell.instrument, radix: 16) ?? Self.instrumentIndexBounds.lowerBound + 1
            case .volume:
                Int(cell.volume, radix: 16) ?? 0
            case .effect:
                Int(cell.effect, radix: 16) ?? 0
        }
    }

    private func channelMuteToggle(
        _ channel: Int,
        display: MK2ButtonToggleDisplay? = nil,
        onToggle: @escaping @Sendable (_ isOn: Bool) -> Void = { _ in }
    ) -> MK2ButtonToggle {
        MK2ButtonToggle(
            button: .m,
            isOn: mutedChannels.contains(channel),
            onLamp: Self.activeLamp(Self.muteColor),
            offLamp: Self.availableLamp(Self.muteColor),
            display: display,
            onToggle: onToggle
        )
    }

    private func channelSoloToggle(
        _ channel: Int,
        display: MK2ButtonToggleDisplay? = nil,
        onToggle: @escaping @Sendable (_ isOn: Bool) -> Void = { _ in }
    ) -> MK2ButtonToggle {
        MK2ButtonToggle(
            button: .s,
            isOn: soloedChannels.contains(channel),
            onLamp: Self.activeLamp(Self.soloColor),
            offLamp: Self.availableLamp(Self.soloColor),
            display: display,
            onToggle: onToggle
        )
    }

    private func channelToggleDisplay(_ label: String, kind: ChannelButtonKind, x: Int, y: Int) -> MK2ButtonToggleDisplay {
        MK2ButtonToggleDisplay(
            label: label,
            rect: MK2PixelRect(x: x, y: y, width: 14, height: 16),
            font: .label,
            colors: kind.displayColors
        )
    }

    private func setSelectedInstrumentIndex(_ index: Int) async {
        guard unit == .pattern else { return }
        let next = max(Self.instrumentIndexBounds.lowerBound, min(Self.instrumentIndexBounds.upperBound, index))
        guard next != selectedInstrumentIndex else { return }
        selectedInstrumentIndex = next
        await render()
    }

    private func showClearPatternDialog() async {
        guard unit == .pattern else { return }
        modalDialog = .clearPattern(selectedIndex: 0)
        await render()
    }

    private func setModalSelection(_ index: Int) async {
        guard let modalDialog else { return }
        switch modalDialog {
            case .clearPattern:
                self.modalDialog = .clearPattern(selectedIndex: max(0, min(0, index)))
        }
        await render()
    }

    private func confirmModalDialog() async {
        guard let modalDialog else { return }
        switch modalDialog {
            case .clearPattern:
                await clearActivePattern()
        }
    }

    private func dismissModalDialog() async {
        guard modalDialog != nil else { return }
        modalDialog = nil
        await render()
    }

    private func clearActivePattern() async {
        isPlaying = false
        playbackTimer?.cancel()
        playbackTimer = nil
        patternRows = Self.emptyPatternRows()
        playheadRow = 0
        midiInputByChannel = Array(repeating: "NO MIDI", count: 4)
        modalDialog = nil
        await render()
    }

    private func toggleRecordArm() async {
        guard unit == .pattern else { return }
        recordArmed.toggle()
        await render()
    }

    private func setRecordArmed(_ armed: Bool) async {
        guard unit == .pattern else { return }
        recordArmed = armed
        await render()
    }

    private func toggleMetronome() async {
        guard unit == .pattern else { return }
        metronomeEnabled.toggle()
        await render()
    }

    private func setMetronomeEnabled(_ enabled: Bool) async {
        guard unit == .pattern else { return }
        metronomeEnabled = enabled
        await render()
    }

    private func playMetronomeIfNeeded(row: Int) {
        guard metronomeEnabled, isPlaying, row.isMultiple(of: 4) else { return }
        metronome.play(accent: row.isMultiple(of: 16))
    }

    private func receiveMIDI(_ event: KKMIDIEvent, targetChannel: Int) async {
        guard unit == .pattern, midiInputByChannel.indices.contains(targetChannel) else { return }
        let row = playheadRow
        let didRecord = recordArmed && record(event, row: row, channel: targetChannel)
        let inputMode = didRecord ? (isPlaying ? "LIVE" : "STEP") : "MON"
        midiInputByChannel[targetChannel] = "\(inputMode) \(hex2(row)) \(Self.midiSummary(event))"
        if didRecord, !isPlaying {
            playheadRow = (playheadRow + 1) % patternRows.count
        }
        await render()
    }

    private func record(_ event: KKMIDIEvent, row: Int, channel: Int) -> Bool {
        guard event.kind == .noteOn, event.velocity > 0 else { return false }
        guard patternRows.indices.contains(row), patternRows[row].cells.indices.contains(channel) else { return false }
        patternRows[row].cells[channel] = TrackerDemoCell(
            note: Self.midiNoteName(event.note),
            instrument: selectedInstrument.number,
            volume: Self.trackerVolume(event.velocity),
            effect: "..."
        )
        return true
    }

    // Right screen: the focused combination big, over an optional background swatch, with
    // a settings readout — this is the surface we judge a candidate on.
    private func fontFocusFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: Palette.page)
        let sample = Self.fontSamples[fontSampleIndex]
        let icon = Self.fontIconSamples[iconSampleIndex]

        BitmapLabel("MAIN SAMPLE  E5 BODY  E6 TITLE  E7 ICON  E8 SIZE", font: .label, color: Palette.dim)
            .draw(into: &frame, x: 8, y: 8)
        BitmapLabel("\(sample.label.uppercased())  \(icon.name.uppercased())", font: .label, color: Palette.accent)
            .draw(into: &frame, x: 8, y: 25, clip: MK2PixelRect(x: 8, y: 25, width: 456, height: 14))

        let dialog = MK2PixelRect(x: 8, y: 48, width: 456, height: 150)
        frame.fill(dialog, Palette.dialogSurface)
        frame.stroke(dialog, icon.color)
        drawFreeTypeIcon(icon.glyph, into: &frame, x: 28, y: 70, size: iconPixelSize, color: icon.color)
        drawFreeTypeTitle(sample.title, into: &frame, x: 112, y: 64, size: titlePixelSize, color: icon.color, maxWidth: 336)
        drawFreeTypeBody(sample.body, into: &frame, x: 112, y: 104, size: bodyPixelSize, color: Palette.text, maxWidth: 336)
        drawFreeTypeBody(sample.detail, into: &frame, x: 112, y: 132, size: max(12, min(18, bodyPixelSize - 1)), color: Palette.dim, maxWidth: 336)

        let valueY = 218
        drawFontLabValue(label: "BODY", value: "\(bodyPixelSize)", x: 8, y: valueY, color: Palette.text, into: &frame)
        drawFontLabValue(label: "TITLE", value: "\(titlePixelSize)", x: 126, y: valueY, color: Palette.text, into: &frame)
        drawFontLabValue(label: "ICON", value: "\(iconSampleIndex + 1)", x: 244, y: valueY, color: icon.color, into: &frame)
        drawFontLabValue(label: "SIZE", value: "\(iconPixelSize)", x: 362, y: valueY, color: icon.color, into: &frame)
        return frame
    }

    private func drawFontLabValue(label: String, value: String, x: Int, y: Int, color: UInt16, into frame: inout MK2PixelFrame) {
        MK2ValueCell(
            label: label,
            value: value,
            rect: MK2PixelRect(x: x, y: y, width: 102, height: 38),
            isFocused: false,
            valueFont: .readoutBold,
            cornerRadius: 7,
            colors: editCellColors(value: color)
        ).draw(into: &frame)
    }

    private func drawFreeTypeTitle(
        _ text: String,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        size: Int,
        color: UInt16,
        maxWidth: Int
    ) {
        drawFreeTypeText(text, into: &frame, x: x, y: y, size: size, weight: .medium, color: color, maxWidth: maxWidth)
    }

    private func drawFreeTypeBody(
        _ text: String,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        size: Int,
        color: UInt16,
        maxWidth: Int
    ) {
        drawFreeTypeText(text, into: &frame, x: x, y: y, size: size, weight: .regular, color: color, maxWidth: maxWidth)
    }

    private func drawFreeTypeText(
        _ text: String,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        size: Int,
        weight: FreeTypeFontWeight,
        color: UInt16,
        maxWidth: Int
    ) {
        let style = FreeTypeTextStyle(
            familyID: FreeTypeFontCatalog.textFamilyID,
            weight: weight,
            pixelSize: size,
            color: color
        )
        guard let freeTypeRenderer,
              (try? freeTypeRenderer.drawText(text, into: &frame, x: x, y: y, style: style, maxWidth: maxWidth)) != nil else {
            BitmapLabel(text, font: weight == .medium ? .gridBold : .grid, color: color)
                .draw(into: &frame, x: x, y: y + 3, clip: MK2PixelRect(x: x, y: y, width: maxWidth, height: max(18, size + 6)))
            return
        }
    }

    private func drawFreeTypeIcon(
        _ glyph: String,
        into frame: inout MK2PixelFrame,
        x: Int,
        y: Int,
        size: Int,
        color: UInt16
    ) {
        let style = FreeTypeTextStyle(
            familyID: FreeTypeFontCatalog.iconProLightFamilyID,
            weight: .regular,
            pixelSize: size,
            color: color
        )
        guard let freeTypeRenderer,
              (try? freeTypeRenderer.drawText(glyph, into: &frame, x: x, y: y, style: style, maxWidth: max(80, size + 20))) != nil else {
            BitmapLabel("?", font: .readoutBold, color: color)
                .draw(into: &frame, x: x + 12, y: y + 14)
            return
        }
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
        BitmapLabel("A FONT   B CHRM   C METR   D SEL", font: .label, color: Palette.dim)
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

            case "sample":
                guard let value = Int(rest.trimmingCharacters(in: .whitespacesAndNewlines)),
                      Self.fontSamples.indices.contains(value) else { print("? sample <0-\(Self.fontSamples.count - 1)>"); return }
                setFontSampleIndex(value)
                await render()

            case "body":
                guard let value = Int(rest.trimmingCharacters(in: .whitespacesAndNewlines)),
                      (12...22).contains(value) else { print("? body <12-22>"); return }
                await setBodyPixelSize(value)

            case "title":
                guard let value = Int(rest.trimmingCharacters(in: .whitespacesAndNewlines)),
                      (18...32).contains(value) else { print("? title <18-32>"); return }
                await setTitlePixelSize(value)

            case "icon":
                guard let value = Self.fontIconIndex(rest) else { print("? icon <0-\(Self.fontIconSamples.count - 1)|name>"); return }
                await setIconSampleIndex(value)

            case "iconsize":
                guard let value = Int(rest.trimmingCharacters(in: .whitespacesAndNewlines)),
                      (32...72).contains(value) else { print("? iconsize <32-72>"); return }
                await setIconPixelSize(value)

            case "browsemode":
                await cycleBrowserMode()

            case "selmode":
                await cycleSelectionMode()

            case "play":
                await play()

            case "stop":
                await stopPlayback()

            case "clear":
                await showClearPatternDialog()

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

            case "solo":
                guard let enabled = Self.triState(rest, current: soloedChannels.contains(focusedChannel)) else {
                    print("? solo on|off|toggle"); return
                }
                await setFocusedChannelSolo(enabled)

            case "mute":
                guard let enabled = Self.triState(rest, current: mutedChannels.contains(focusedChannel)) else {
                    print("? mute on|off|toggle"); return
                }
                await setFocusedChannelMute(enabled)

            case "stripe", "stripes", "rowstripe", "rowstripes":
                guard let mode = Self.rowStripeMode(rest) else {
                    print("? stripe off|odd|even|<n>|every <n> [phase]"); return
                }
                rowStripeMode = mode
                await render()

            case "rec", "record":
                let value = rest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                switch value {
                    case "", "toggle":
                        await toggleRecordArm()
                    case "on", "1", "true", "yes":
                        await setRecordArmed(true)
                    case "off", "0", "false", "no":
                        await setRecordArmed(false)
                    default:
                        print("? rec on|off|toggle")
                }

            case "metro", "metronome":
                let value = rest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                switch value {
                    case "", "toggle":
                        await toggleMetronome()
                    case "on", "1", "true", "yes":
                        await setMetronomeEnabled(true)
                    case "off", "0", "false", "no":
                        await setMetronomeEnabled(false)
                    default:
                        print("? metro on|off|toggle")
                }

            case "midi":
                guard let event = Self.midiEvent(rest) else { print("? midi <note> [velocity]"); return }
                await receiveMIDI(event, targetChannel: focusedChannel)

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
        let currentScene = scene()
        let frames = currentScene.displays.map { $0 ?? MK2PixelFrame() }
        let target = path ?? FileManager.default.currentDirectoryPath + "/widgetlab-\(unit.short.lowercased()).png"
        do {
            let written = try PixelSnapshot.write(frames, to: target)
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

    private static func fontIconIndex(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let index = Int(trimmed), fontIconSamples.indices.contains(index) {
            return index
        }
        return fontIconSamples.firstIndex { $0.name.lowercased() == trimmed }
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

    private static func rowStripeMode(_ text: String) -> RowStripeMode? {
        let parts = text
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        guard let first = parts.first else { return .every(4) }
        switch first {
            case "off", "none", "no":
                return RowStripeMode.none
            case "odd":
                return .every(2, phase: 1)
            case "even":
                return .every(2, phase: 0)
            case "every", "mod", "modulo":
                guard parts.count <= 3,
                      parts.indices.contains(1),
                      let interval = Int(parts[1]),
                      interval > 0 else { return nil }
                let phase = parts.indices.contains(2) ? Int(parts[2]) : 0
                guard let phase else { return nil }
                return .every(interval, phase: phase)
            default:
                guard parts.count == 1,
                      let interval = Int(first),
                      interval > 0 else { return nil }
                return .every(interval)
        }
    }

    private static func triState(_ text: String, current: Bool) -> Bool? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "", "toggle":
                return !current
            case "on", "1", "true", "yes":
                return true
            case "off", "0", "false", "no":
                return false
            default:
                return nil
        }
    }

    private static func demoPatternRows() -> [TrackerDemoRow] {
        var rows = emptyPatternRows()
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

    private static func emptyPatternRows() -> [TrackerDemoRow] {
        (0..<64).map { _ in TrackerDemoRow(cells: Array(repeating: TrackerDemoCell.empty, count: 4)) }
    }

    private static func midiEvent(_ text: String) -> KKMIDIEvent? {
        let parts = text.split(separator: " ").map(String.init)
        guard let noteText = parts.first, let note = UInt8(noteText) else { return nil }
        let velocity = parts.dropFirst().first.flatMap(UInt8.init) ?? 100
        return KKMIDIEvent(kind: .noteOn, channel: 0, note: note, velocity: velocity)
    }

    private static func midiSummary(_ event: KKMIDIEvent) -> String {
        switch event.kind {
            case .noteOn:
                event.velocity > 0 ? "ON \(midiNoteName(event.note)) V\(event.velocity)" : "OFF \(midiNoteName(event.note))"
            case .noteOff:
                "OFF \(midiNoteName(event.note))"
            case .controlChange:
                "CC \(event.control)=\(event.controlValue)"
            case .channelPressure:
                "AT \(event.pressure)"
            case .pitchBend:
                "PB \(event.pitchBendCentered)"
        }
    }

    private static func midiNoteName(_ note: UInt8) -> String {
        let names = ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"]
        let value = Int(note)
        return "\(names[value % 12])\(value / 12 - 1)"
    }

    private static func midiNoteValue(_ note: String) -> Int? {
        guard note.count >= 3 else { return nil }
        let names = ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"]
        let prefix = String(note.prefix(2))
        guard let index = names.firstIndex(of: prefix),
              let octave = Int(note.dropFirst(2)) else { return nil }
        let value = (octave + 1) * 12 + index
        guard (0...127).contains(value) else { return nil }
        return value
    }

    private static func trackerVolume(_ velocity: UInt8) -> String {
        let volume = Int((Double(velocity) / 127.0 * 64.0).rounded())
        return String(format: "%02X", max(0, min(64, volume)))
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

private final class DemoMetronome {
    private let engine = AVAudioEngine()
    private let clickBuffer: AVAudioPCMBuffer
    private let accentBuffer: AVAudioPCMBuffer
    private let players: [AVAudioPlayerNode]
    private var nextPlayer = 0

    init() {
        let hardwareFormat = engine.outputNode.inputFormat(forBus: 0)
        let sampleRate = hardwareFormat.sampleRate > 0 ? hardwareFormat.sampleRate : 48_000
        let channelCount = max(1, min(2, hardwareFormat.channelCount))
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)!

        clickBuffer = Self.makeBuffer(format: format, duration: 0.018, frequency: 1_750, snap: 3_200, gain: 0.52)
        accentBuffer = Self.makeBuffer(format: format, duration: 0.026, frequency: 2_350, snap: 4_400, gain: 0.68)
        players = Self.makePlayers(count: 4, engine: engine, format: format)

        engine.prepare()
        try? engine.start()
    }

    func play(accent: Bool) {
        guard !players.isEmpty else { return }
        if !engine.isRunning {
            try? engine.start()
        }

        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        player.stop()
        player.scheduleBuffer(accent ? accentBuffer : clickBuffer, at: nil, options: .interrupts, completionHandler: nil)
        player.play()
    }

    private static func makePlayers(count: Int, engine: AVAudioEngine, format: AVAudioFormat) -> [AVAudioPlayerNode] {
        (0..<count).map { _ in
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            return player
        }
    }

    private static func makeBuffer(
        format: AVAudioFormat,
        duration: Double,
        frequency: Double,
        snap: Double,
        gain: Double
    ) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(format.sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        guard let channels = buffer.floatChannelData else { return buffer }
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / format.sampleRate
            let progress = Double(frame) / Double(max(1, Int(frameCount) - 1))
            let envelope = exp(-progress * 10)
            let tone = sin(2 * .pi * frequency * time)
            let transient = sin(2 * .pi * snap * time) * exp(-progress * 24)
            let value = Float((tone * 0.72 + transient * 0.28) * envelope * gain)
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = value
            }
        }
        return buffer
    }
}

let namedColors: [String: UInt16] = [
    "white": 0xffff, "black": 0x0000, "red": 0xf800, "green": 0x07e0,
    "blue": 0x001f, "yellow": 0xffe0, "cyan": 0x07ff, "magenta": 0xf81f,
    "orange": 0xfc00, "grey": 0x8410, "gray": 0x8410, "dim": 0x4208,
]

private struct FontLabSample: Sendable {
    var label: String
    var title: String
    var body: String
    var detail: String
}

private struct FontLabIconSample: Sendable {
    var name: String
    var glyph: String
    var color: UInt16
}

private struct TrackerDemoRow: Sendable {
    var cells: [TrackerDemoCell]
}

private enum TrackerEditField: CaseIterable, Sendable {
    case note
    case instrument
    case volume
    case effect

    var encoder: Int {
        switch self {
            case .note: 5
            case .instrument: 6
            case .volume: 7
            case .effect: 8
        }
    }

    var bounds: ClosedRange<Int> {
        switch self {
            case .note: 24...96
            case .instrument: 1...16
            case .volume: 0...64
            case .effect: 0...0xfff
        }
    }
}

private struct DemoInstrument: Sendable {
    var number: String
    var name: String

    var displayName: String {
        "\(number) \(name)"
    }
}

private enum ActiveModalDialog: Sendable {
    case clearPattern(selectedIndex: Int)
}

private enum RowStripeMode: Sendable {
    case none
    case every(Int, phase: Int = 0)

    func matches(_ row: Int) -> Bool {
        switch self {
            case .none:
                return false
            case let .every(interval, phase):
                guard interval > 0 else { return false }
                return row.floorMod(interval) == phase.floorMod(interval)
        }
    }
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

private enum ChannelButtonKind {
    case solo
    case mute

    var accent: UInt16 {
        switch self {
            case .solo: Palette.solo
            case .mute: Palette.mute
        }
    }

    var border: UInt16 {
        switch self {
            case .solo: Palette.soloBorder
            case .mute: Palette.muteBorder
        }
    }

    var displayColors: MK2ButtonToggleDisplayColors {
        MK2ButtonToggleDisplayColors(
            onFill: accent,
            onBorder: border,
            onText: Palette.channelButtonActiveText,
            offFill: Palette.channelButtonFill,
            offBorder: Palette.channelButtonBorder,
            offText: accent
        )
    }
}

private extension Int {
    func floorMod(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder >= 0 ? remainder : remainder + divisor
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
    static let question: UInt16 = 0x9a7f
    static let solo: UInt16 = 0x03ff
    static let soloBorder: UInt16 = 0x5dff
    static let mute: UInt16 = 0xf8c3
    static let muteBorder: UInt16 = 0xf800
    static let note: UInt16 = 0xdedf
    static let instrument: UInt16 = 0x95f2
    static let effect: UInt16 = 0xec88
    static let empty: UInt16 = 0x4a69
    static let ruler: UInt16 = 0x632e
    static let rowStripe: UInt16 = 0x1083
    static let cursorFill: UInt16 = 0x19aa
    static let playheadFill: UInt16 = 0x1125
    static let focusedChannelFill: UInt16 = 0x1026
    static let channelButtonFill: UInt16 = 0x1083
    static let channelButtonBorder: UInt16 = 0x4208
    static let channelButtonActiveText: UInt16 = 0xffff
    static let editFieldFill: UInt16 = 0x1083
    static let editFieldFocusedFill: UInt16 = 0xc618
    static let track: UInt16 = 0x2126
    static let dialogSurface: UInt16 = 0x18e3
    static let selectionFill: UInt16 = 0x2126
    static let filterFill: UInt16 = 0x1083
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

private extension Int {
    func wrapped(to bounds: ClosedRange<Int>) -> Int {
        let count = bounds.upperBound - bounds.lowerBound + 1
        guard count > 0 else { return bounds.lowerBound }
        let raw = (self - bounds.lowerBound) % count
        let offset = raw >= 0 ? raw : raw + count
        return bounds.lowerBound + offset
    }
}
