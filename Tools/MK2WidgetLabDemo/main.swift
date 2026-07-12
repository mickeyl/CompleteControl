import Foundation
import AVFoundation
import KompleteKontrol
import KontrolSurfaceKit2

// A lab bench for the KontrolSurfaceKit2 widget layer. Everything on screen is composed
// exclusively from kit2 public APIs (BitmapLabel, MK2PixelFrame, MK2SurfaceScene2,
// PixelSnapshot) — no private drawing helpers, no legacy placeholder font. If a demo
// needs something the kit can't express yet, that capability goes into the kit first.
//
// Navigation (rework 2026-07-12, Docs/WidgetLab-Rework-Plan.md): the top level is a
// filterable demo browser — 4-D selects and opens a demo, which then owns every
// control except SCENE, the reserved exit back to the browser.
@main
struct MK2WidgetLabDemo {
    static func main() async {
        let surface = MK2Surface2(options: .init(tickHz: 60))
        let lab = WidgetLab(surface: surface)
        if let snapshotDir = ProcessInfo.processInfo.environment["WIDGETLAB_SNAPSHOT_DIR"] {
            await lab.snapshotAll(to: snapshotDir)
            return
        }
        let runner = MK2SurfaceEventRunner(name: "surface", surface: surface)
        await runner.run { _ in
            await lab.showBrowser()
            let replEnabled = LineReader.hasInteractiveInput
            printBanner(replEnabled: replEnabled)
            if replEnabled {
                startREPL(lab)
            }
        }
    }

    private static func printBanner(replEnabled: Bool) {
        if replEnabled {
            print("MK2WidgetLabDemo — 4-D browses and opens demos, SCENE exits. Type 'help' or press Tab.")
        } else {
            print("MK2WidgetLabDemo — 4-D browses and opens demos, SCENE exits. REPL disabled: stdin is not a TTY.")
        }
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

let ledGroupNames = ["all", "palette", "rgb", "mono", "buttons", "strip", "jog", "functions", "transport"]
let ledCompletionValues = ledGroupNames
    + KKMK2ButtonLED.allCases.map(\.protocolName)
    + (1...8).map { "f\($0)" }
    + ["m", "s", "mute", "solo"]
let guideCompletionValues = ["all", "keys", "off"] + namedLEDColors.keys.sorted()

let replCommands: [ReplCommand] = [
    ReplCommand(name: "list", arg: "", summary: "list demos and their ids", values: []),
    ReplCommand(name: "open", arg: "<id>", summary: "open a demo", values: Unit.registry.map { $0.descriptor.id } + ["encoder-feel", "panorama", "chrome-slots", "forms", "type-specimen", "icon-browser", "dialog-card", "selection-browser", "meter", "waveform"]),
    ReplCommand(name: "exit", arg: "", summary: "leave the demo, back to the browser", values: []),
    ReplCommand(name: "text", arg: "<string>", summary: "type-specimen: sample text", values: []),
    ReplCommand(name: "sample", arg: "<0-3>", summary: "type-specimen: dialog mock preset", values: ["0", "1", "2", "3"]),
    ReplCommand(name: "body", arg: "<12-22>", summary: "type-specimen: body pixel size", values: []),
    ReplCommand(name: "title", arg: "<18-32>", summary: "type-specimen: title pixel size", values: []),
    ReplCommand(name: "icon", arg: "<index|name>", summary: "icon-browser: select icon", values: []),
    ReplCommand(name: "iconsize", arg: "<20-88>", summary: "icon-browser: preview size", values: []),
    ReplCommand(name: "iconmode", arg: "list|grid|filterlist|filtergrid|next", summary: "icon-browser: list/grid mode", values: ["list", "grid", "filterlist", "filtergrid", "next"]),
    ReplCommand(name: "play", arg: "", summary: "tracker unit: start playback", values: []),
    ReplCommand(name: "stop", arg: "", summary: "tracker unit: stop playback", values: []),
    ReplCommand(name: "clear", arg: "", summary: "tracker unit: clear selected row", values: []),
    ReplCommand(name: "patternclear", arg: "", summary: "tracker unit: clear pattern with confirmation", values: []),
    ReplCommand(name: "row", arg: "<0-63|hex>", summary: "tracker unit: set stopped playhead row", values: []),
    ReplCommand(name: "jog", arg: "<delta>", summary: "tracker unit: emulate 4D row rotation", values: []),
    ReplCommand(name: "push", arg: "left|right|up|down|press", summary: "browser/selection unit: emulate 4D push", values: ["left", "right", "up", "down", "press"]),
    ReplCommand(name: "ch", arg: "<1-4>", summary: "tracker unit: set focused channel", values: ["1", "2", "3", "4"]),
    ReplCommand(name: "solo", arg: "on|off|toggle", summary: "tracker unit: solo focused channel", values: ["on", "off", "toggle"]),
    ReplCommand(name: "mute", arg: "on|off|toggle", summary: "tracker unit: mute focused channel", values: ["on", "off", "toggle"]),
    ReplCommand(name: "stripe", arg: "off|odd|even|<n>|every <n> [phase]", summary: "tracker unit: row stripe rule", values: ["off", "odd", "even", "4", "16", "every"]),
    ReplCommand(name: "rec", arg: "on|off|toggle", summary: "tracker unit: arm record", values: ["on", "off", "toggle"]),
    ReplCommand(name: "metro", arg: "on|off|toggle", summary: "tracker unit: toggle metronome", values: ["on", "off", "toggle"]),
    ReplCommand(name: "midi", arg: "<note> [velocity]", summary: "tracker unit: route MIDI to focused channel", values: []),
    ReplCommand(name: "led", arg: "<led|group> <color|off> [0-3]", summary: "override 0x80 button/strip LEDs", values: ledCompletionValues),
    ReplCommand(name: "ledclear", arg: "[led|group]", summary: "toggle 0x80 LED override ownership", values: ledCompletionValues),
    ReplCommand(name: "ledlist", arg: "", summary: "list 0x80 LED names and capabilities", values: []),
    ReplCommand(name: "guide", arg: "<all|key> <color|off>", summary: "override 0x81 light-guide keys", values: guideCompletionValues),
    ReplCommand(name: "guideclear", arg: "[all|key]", summary: "clear light-guide override", values: guideCompletionValues),
    ReplCommand(name: "snap", arg: "[path]", summary: "write a two-screen PNG snapshot", values: []),
    ReplCommand(name: "screenshot", arg: "[path]", summary: "alias for snap", values: []),
    ReplCommand(name: "help", arg: "", summary: "show this help", values: []),
    ReplCommand(name: "quit", arg: "", summary: "exit", values: []),
]

func replComplete(_ tokens: [String]) -> [String] {
    if tokens.count <= 1 { return replCommands.map { $0.name } }
    guard tokens.count == 2, let command = replCommands.first(where: { $0.name == tokens[0].lowercased() }) else { return [] }
    return command.values
}

func printReplHelp() {
    print("MK2WidgetLabDemo REPL — commands (Tab completes):")
    for command in replCommands {
        let left = "\(command.name) \(command.arg)".padding(toLength: 26, withPad: " ", startingAt: 0)
        print("  \(left)\(command.summary)")
    }
}

private enum Unit: Int, CaseIterable, Sendable {
    case pattern


    /// Phase-1 wrapper descriptors: each legacy unit is one browsable demo;
    /// later phases split them into real per-file demos (see the rework plan).
    /// The KEYS placeholder is gone — a Diagnostics light-guide demo replaces
    /// it in a later phase.
    var descriptor: DemoDescriptor {
        DemoDescriptor(
            id: "tracker-pattern",
            title: "Tracker Pattern",
            category: .catalogue,
            summary: "Pattern grid, transport, shift layer",
            detail: "The hand-built tracker grid with playhead, transport and channel toggles, the parameter page with shift slots, and the clear-pattern modal via SHIFT+CLEAR."
        )
    }

    static let registry: [Unit] = [.pattern]
}

private actor WidgetLab {
    private let surface: MK2Surface2
    private let metronome = DemoMetronome()
    private let freeTypeRenderer: FreeTypeTextRenderer?
    private var unit: Unit = .pattern
    /// Browser/demo navigation (rework 2026-07-12): the browser owns the
    /// surface until a demo is opened; an open demo owns everything except
    /// the reserved SCENE exit.
    private enum LabMode { case browser, demo }
    private var mode: LabMode = .browser
    private var demoBrowserNavigation = MK2SelectionNavigation()
    /// 0 = All, 1… = DemoCategory raw value + 1.
    private var demoBrowserCategoryIndex = 0
    /// A browsable demo: either a not-yet-extracted legacy unit or a
    /// self-contained LabDemo instance (rework phases 2-5).
    private enum DemoRef {
        case legacy(Unit)
        case modern(any LabDemo)

        var descriptor: DemoDescriptor {
            switch self {
                case let .legacy(unit): unit.descriptor
                case let .modern(demo): demo.descriptor
            }
        }
    }
    private let modernDemos: [any LabDemo] = [
        EncoderFeelDemo(),
        PanoramaDemo(),
        TypeSpecimenDemo(),
        IconBrowserDemo(),
        DialogCardDemo(),
        ChromeSlotsDemo(),
        FormsDemo(),
        SelectionBrowserDemo(),
        MeterDemo(),
        WaveformDemo(),
    ]
    private lazy var demoRegistry: [DemoRef] = {
        let entries = Unit.registry.map { DemoRef.legacy($0) } + modernDemos.map { DemoRef.modern($0) }
        return DemoCategory.allCases.flatMap { category in
            entries.filter { $0.descriptor.category == category }
        }
    }()
    private var activeDemo: DemoRef?

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
    private var lampOverrides: [KKMK2ButtonLED: MK2LampState2] = [:]
    private var guideOverrides: [Int: KKRGB] = [:]
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

    init(surface: MK2Surface2) {
        self.surface = surface
        self.freeTypeRenderer = try? FreeTypeTextRenderer()
        self.patternRows = WidgetLab.demoPatternRows()
    }

    private var selectedInstrument: DemoInstrument {
        let index = max(Self.instrumentIndexBounds.lowerBound, min(Self.instrumentIndexBounds.upperBound, selectedInstrumentIndex))
        return Self.demoInstruments[index]
    }

    private func render() async {
        await surface.present(scene())
    }

    // MARK: - Scene

    private func scene() -> MK2SurfaceScene2 {
        if let modalDialog {
            var scene = modalScene(modalDialog)
            applyLampOverrides(to: &scene.lamps)
            applyGuideOverrides(to: &scene.keyColors)
            return scene
        }
        switch mode {
            case .browser:
                return demoBrowserScene()
            case .demo:
                if case let .modern(demo) = activeDemo {
                    return modernDemoScene(demo)
                }
                return demoScene()
        }
    }

    private func labContext() -> LabContext {
        LabContext(
            renderer: freeTypeRenderer,
            update: { [weak self] mutation in
                Task { await self?.applyDemoMutation(mutation, rerender: true) }
            },
            mutate: { [weak self] mutation in
                Task { await self?.applyDemoMutation(mutation, rerender: false) }
            }
        )
    }

    private func applyDemoMutation(_ mutation: @escaping @Sendable () -> Void, rerender: Bool) async {
        mutation()
        if rerender {
            await render()
        }
    }

    private func activeModernDemo() -> (any LabDemo)? {
        guard mode == .demo, case let .modern(demo) = activeDemo else { return nil }
        return demo
    }

    private func modernDemoScene(_ demo: any LabDemo) -> MK2SurfaceScene2 {
        var scene = demo.buildScene(labContext())
        // The one control a demo never owns: SCENE always exits to the browser.
        scene.lamps[.scene] = Self.availableLamp(Self.actionWhite)
        scene.bindings.onPress(.scene) { [weak self] in
            Task { await self?.showBrowser() }
        }
        applyLampOverrides(to: &scene.lamps)
        applyGuideOverrides(to: &scene.keyColors)
        return scene
    }

    private func demoScene() -> MK2SurfaceScene2 {
        var lamps: [KKMK2ButtonLED: MK2LampState2] = [:]
        if unit == .pattern {
            lamps[.play] = isPlaying ? Self.activeLamp(Self.actionGreen) : Self.availableLamp(Self.actionGreen)
            lamps[.stop] = isPlaying ? Self.availableLamp(Self.actionRed) : Self.activeLamp(Self.actionRed)
            lamps[.record] = recordArmed ? Self.activeLamp(Self.actionRed) : Self.availableLamp(Self.actionRed)
            lamps[.clear] = Self.availableLamp(Self.actionWhite)
            // No explicit shift lamp: the scene declares a shift layer, so the kit's
            // automatic convention (dim = available, bright = held) takes over.
            lamps[.pageLeft] = focusedChannel > 0 ? Self.availableLamp(Self.actionWhite) : .off
            lamps[.pageRight] = focusedChannel < 3 ? Self.availableLamp(Self.actionWhite) : .off
        }

        var bindings = MK2InputBindings2()
        bindings.jogScroll = { [weak self] delta, _ in
            Task { await self?.turnMainEncoder(delta) }
        }
        if unit == .pattern {
            bindings.onPress(.play) { [weak self] in
                Task { await self?.play() }
            }
            bindings.onPress(.stop) { [weak self] in
                Task { await self?.stopPlayback() }
            }
            bindings.onPress(.record) { [weak self] in
                Task { await self?.toggleRecordArm() }
            }
            bindings.onPress(.clear, modifiers: .unmodified) { [weak self] in
                Task { await self?.clearSelectedPatternRow() }
            }
            bindings.onPress(.clear, modifiers: .shift) { [weak self] in
                Task { await self?.showClearPatternDialog() }
            }
            bindings.onPress(.pageLeft) { [weak self] in
                Task { await self?.moveFocusedChannel(-1) }
            }
            bindings.onPress(.pageRight) { [weak self] in
                Task { await self?.moveFocusedChannel(1) }
            }
        }
        if unit == .pattern {
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

        let (leftResult, rightResult) = screenResults()
        lamps.merge(leftResult.lamps) { _, next in next }
        lamps.merge(rightResult.lamps) { _, next in next }
        bindings.merge(leftResult.bindings)
        bindings.merge(rightResult.bindings)

        // The one control a demo never owns: SCENE always leads back to the
        // browser. Installed after the merge so no demo content can shadow it.
        lamps[.scene] = Self.availableLamp(Self.actionWhite)
        bindings.onPress(.scene) { [weak self] in
            Task { await self?.showBrowser() }
        }

        applyLampOverrides(to: &lamps)
        var keyColors = leftResult.keyColors
        keyColors.merge(rightResult.keyColors) { _, next in next }
        applyGuideOverrides(to: &keyColors)
        return MK2SurfaceScene2(
            left: leftResult.screen.frame,
            right: rightResult.screen.frame,
            lamps: lamps,
            keyColors: keyColors,
            bindings: bindings,
            shift: MK2SurfaceScene2.ShiftLayer(left: leftResult, right: rightResult)
        )
    }

    // MARK: - Demo browser

    private static let demoBrowserCategoryValues = ["All"] + DemoCategory.allCases.map(\.filterValue)

    private func visibleBrowserDemos() -> [DemoRef] {
        guard demoBrowserCategoryIndex > 0,
              let category = DemoCategory(rawValue: demoBrowserCategoryIndex - 1) else { return demoRegistry }
        return demoRegistry.filter { $0.descriptor.category == category }
    }

    private func demoBrowserScene() -> MK2SurfaceScene2 {
        let visible = visibleBrowserDemos()
        let leftResult = demoBrowserListResult(visible)
        let rightResult = demoBrowserDetailPaneResult(visible)

        var lamps = leftResult.lamps
        lamps.merge(rightResult.lamps) { _, next in next }
        var bindings = leftResult.bindings
        bindings.merge(rightResult.bindings)

        applyLampOverrides(to: &lamps)
        var keyColors = leftResult.keyColors
        keyColors.merge(rightResult.keyColors) { _, next in next }
        applyGuideOverrides(to: &keyColors)
        return MK2SurfaceScene2(
            left: leftResult.screen.frame,
            right: rightResult.screen.frame,
            lamps: lamps,
            keyColors: keyColors,
            bindings: bindings
        )
    }

    private func demoBrowserListResult(_ visible: [DemoRef]) -> MK2ScreenBuildResult {
        let items = visible.map { demo in
            MK2SelectionItem(
                title: demo.descriptor.title,
                detail: demo.descriptor.summary,
                badge: demo.descriptor.category.badge
            )
        }
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
        return fullScreenResult {
            MK2SelectionListElement(
                title: "WIDGET LAB",
                subtitle: "4-D opens · E4 filters",
                items: items,
                selectedIndex: demoBrowserNavigation.selectedIndex,
                filters: [
                    MK2SelectionFilter(
                        label: "CATEGORY",
                        value: Self.demoBrowserCategoryValues[demoBrowserCategoryIndex].uppercased(),
                        encoder: 4,
                        isFocused: demoBrowserNavigation.focusedFilterEncoder == 4
                    ),
                ],
                rowHeight: 44,
                colors: colors
            )
            MK2SelectionInputElement(
                navigation: demoBrowserNavigation,
                itemCount: items.count,
                layout: .list(step: 4),
                availableLamp: Self.availableLamp(Self.actionWhite),
                onMove: { [weak self] delta in
                    Task { await self?.moveDemoBrowserSelection(delta) }
                },
                onConfirm: { [weak self] in
                    Task { await self?.confirmDemoBrowserSelection() }
                }
            )
            MK2SelectionFilterEncoderElement([
                MK2SelectionFilterEncoderBinding(
                    encoder: 4,
                    value: demoBrowserCategoryIndex,
                    bounds: 0...(Self.demoBrowserCategoryValues.count - 1),
                    wraps: true,
                    onFocus: { [weak self] _, touched in
                        Task { await self?.setDemoBrowserFilterFocus(touched) }
                    },
                    onChange: { [weak self] value in
                        Task { await self?.setDemoBrowserCategory(value) }
                    }
                ),
            ])
        }
    }

    private func demoBrowserDetailPaneResult(_ visible: [DemoRef]) -> MK2ScreenBuildResult {
        guard let index = demoBrowserNavigation.clampedSelectedIndex(itemCount: visible.count) else {
            return regularScreenResult(header: .title(title: "Widget Lab", subtitle: "Demo Browser")) {
                MK2EmptyStateElement(
                    title: "No demos in this category",
                    detail: "Turn E4 to widen the filter"
                )
            }
        }
        let descriptor = visible[index].descriptor
        return regularScreenResult(
            header: .title(title: descriptor.title, subtitle: descriptor.category.title),
            footer: .hint("4-D press opens the demo · SCENE returns here")
        ) {
            MK2BrowserDetailElement(
                title: descriptor.title,
                detail: descriptor.detail,
                metadata: "\(descriptor.category.title) · open \(descriptor.id)",
                y: 48
            )
        }
    }

    func showBrowser() async {
        stopPatternPlaybackIfNeeded()
        mode = .browser
        demoBrowserNavigation.clamp(itemCount: visibleBrowserDemos().count)
        await render()
    }

    private func openDemo(_ target: DemoRef) async {
        if case let .legacy(legacyUnit) = target {
            if legacyUnit != .pattern {
                stopPatternPlaybackIfNeeded()
            }
            unit = legacyUnit
        } else {
            stopPatternPlaybackIfNeeded()
        }
        activeDemo = target
        mode = .demo
        await render()
    }

    private func stopPatternPlaybackIfNeeded() {
        isPlaying = false
        playbackTimer?.cancel()
        playbackTimer = nil
    }

    private func moveDemoBrowserSelection(_ delta: Int) async {
        guard mode == .browser, delta != 0 else { return }
        if demoBrowserNavigation.move(by: delta, itemCount: visibleBrowserDemos().count) {
            await render()
        }
    }

    private func confirmDemoBrowserSelection() async {
        guard mode == .browser else { return }
        let visible = visibleBrowserDemos()
        guard let index = demoBrowserNavigation.clampedSelectedIndex(itemCount: visible.count) else { return }
        await openDemo(visible[index])
    }

    private func setDemoBrowserCategory(_ value: Int) async {
        let clamped = max(0, min(Self.demoBrowserCategoryValues.count - 1, value))
        guard clamped != demoBrowserCategoryIndex else { return }
        demoBrowserCategoryIndex = clamped
        demoBrowserNavigation.select(0, itemCount: visibleBrowserDemos().count)
        await render()
    }

    private func setDemoBrowserFilterFocus(_ touched: Bool) async {
        demoBrowserNavigation.touchFilter(encoder: 4, touched: touched)
        await render()
    }

    private func applyLampOverrides(to lamps: inout [KKMK2ButtonLED: MK2LampState2]) {
        for (led, state) in lampOverrides {
            lamps[led] = state
        }
    }

    private func applyGuideOverrides(to keyColors: inout [Int: KKRGB]) {
        for (index, color) in guideOverrides {
            keyColors[index] = color
        }
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
        let results = screenResults()
        return (results.0.screen.frame, results.1.screen.frame)
    }

    private func screenResults() -> (MK2ScreenBuildResult, MK2ScreenBuildResult) {
        (screenResult(frame: trackerGridFrame()), trackerDetailResult())
    }

    private func screenResult(frame: MK2PixelFrame, kind: MK2ScreenKind = .fullScreen) -> MK2ScreenBuildResult {
        MK2ScreenBuildResult(screen: MK2Screen(kind: kind, frame: frame))
    }

    private func regularScreenFrame(
        header: MK2ScreenHeader,
        footer: MK2ScreenFooter = .none,
        @MK2ScreenBuilder content: () -> [any MK2ScreenElement]
    ) -> MK2PixelFrame {
        regularScreenResult(header: header, footer: footer, content: content).screen.frame
    }

    private func regularScreenResult(
        header: MK2ScreenHeader,
        footer: MK2ScreenFooter = .none,
        progress: MK2ScreenProgressBar? = nil,
        @MK2ScreenBuilder content: () -> [any MK2ScreenElement]
    ) -> MK2ScreenBuildResult {
        MK2RegularScreenDSL(header: header, footer: footer, progress: progress, content: content)
            .build(renderer: freeTypeRenderer)
    }

    private func fullScreenFrame(
        @MK2ScreenBuilder content: () -> [any MK2ScreenElement]
    ) -> MK2PixelFrame {
        fullScreenResult(content: content).screen.frame
    }

    private func fullScreenResult(
        @MK2ScreenBuilder content: () -> [any MK2ScreenElement]
    ) -> MK2ScreenBuildResult {
        MK2FullScreenDSL(content: content)
            .build(renderer: freeTypeRenderer)
    }

    // MARK: - Font lab

    // MARK: - Scene lab

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
        trackerDetailResult().screen.frame
    }

    private func trackerDetailResult() -> MK2ScreenBuildResult {
        let cell = patternRows[playheadRow].cells[focusedChannel]
        let selectedInstrumentText = "INST \(selectedInstrument.displayName)"
        let statusItems = [
            MK2StatusLineItem("EDIT", x: 8, color: Palette.blue),
            MK2StatusLineItem("CH\(focusedChannel + 1)", x: 92, color: Palette.dim),
            MK2StatusLineItem("ROW \(hex2(playheadRow))", x: 158, color: Palette.text, font: .gridBold),
        ]
        let slots = trackerEditParameterSlots(cell: cell)

        return MK2FullScreenDSL(background: Palette.page) {
            // The base F-buttons stay the lab's unit switchers, so the base bar keeps
            // its decorative labels without bindings. The shift slots are live: CLR PAT
            // sits above the CLEAR slot, REVERSE above TRIM, and the two empty shift
            // slots demonstrate that an unlabeled slot swallows the press under shift.
            MK2FunctionKeyBarElement(
                slots: [
                    MK2FunctionKeySlot("COPY"),
                    MK2FunctionKeySlot("PASTE"),
                    MK2FunctionKeySlot("CLEAR", isEnabled: false),
                    MK2FunctionKeySlot("TRIM"),
                ],
                shiftSlots: [
                    MK2FunctionKeySlot(),
                    MK2FunctionKeySlot(),
                    MK2FunctionKeySlot("CLR PAT"),
                    MK2FunctionKeySlot("REVERSE"),
                ],
                side: .right,
                onShiftPress: { [weak self] slot in
                    Task {
                        switch slot {
                            case 2: await self?.showClearPatternDialog()
                            case 3: await self?.reversePattern()
                            default: break
                        }
                    }
                }
            )
            MK2AnyScreenElement { frame, _, _ in
                MK2StatusLine(y: 26, items: statusItems).draw(into: &frame)
                BitmapLabel(selectedInstrumentText, font: .grid, color: Palette.instrument)
                    .draw(into: &frame, x: 232, y: 26, clip: MK2PixelRect(x: 232, y: 26, width: 240, height: SurfaceFont.grid.cellHeight))
                frame.hline(y: 55, x: 0, width: 480, color: Palette.border)
            }
            MK2ParameterPageElement(
                slots: slots,
                shiftSlots: trackerShiftEditParameterSlots(cell: cell),
                rect: MK2PixelRect(x: 8, y: 215, width: 464, height: 57),
                columns: 4,
                relativeToContent: false
            )
        }.build(renderer: freeTypeRenderer)
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

    private func trackerEditParameterSlots(cell: TrackerDemoCell) -> [MK2ParameterPageSlot] {
        TrackerEditField.allCases.map { field in
            MK2ParameterPageSlot(
                label: field.label,
                value: editDisplayValue(for: field, cell: cell),
                isFocused: focusedEditField == field,
                encoderValue: MK2EncoderDiscreteValue(
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
                ),
                colors: labEditCellColors(value: field.valueColor)
            )
        }
    }

    /// Under shift the NOTE encoder steps in octaves; the other cells keep their
    /// visual but bring no encoder value, so their base bindings stay active.
    private func trackerShiftEditParameterSlots(cell: TrackerDemoCell) -> [MK2ParameterPageSlot] {
        TrackerEditField.allCases.map { field in
            guard field == .note else {
                return MK2ParameterPageSlot(
                    label: field.label,
                    value: editDisplayValue(for: field, cell: cell),
                    isFocused: focusedEditField == field,
                    colors: labEditCellColors(value: field.valueColor)
                )
            }
            var colors = labEditCellColors(value: field.valueColor)
            colors.label = MK2HIG.Chrome.shiftAccent
            return MK2ParameterPageSlot(
                label: "OCTAVE",
                value: editDisplayValue(for: .note, cell: cell),
                isFocused: focusedEditField == .note,
                encoderValue: MK2EncoderDiscreteValue(
                    encoder: field.encoder,
                    value: editValue(for: .note, cell: cell),
                    bounds: field.bounds,
                    step: 12,
                    wraps: false,
                    onTouch: { [weak self] touched in
                        guard touched else { return }
                        Task { await self?.focusEditField(.note) }
                    },
                    onChange: { [weak self] value in
                        Task { await self?.setFocusedEditValue(value, field: .note) }
                    }
                ),
                colors: colors
            )
        }
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
            case .pattern:
                guard !isPlaying else { return }
                playheadRow = max(0, min(patternRows.count - 1, playheadRow + delta))
                await render()
        }
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

    private func editDisplayValue(for field: TrackerEditField, cell: TrackerDemoCell) -> String {
        switch field {
            case .note:
                cell.note
            case .instrument:
                cell.instrument
            case .volume:
                cell.volume
            case .effect:
                cell.effect
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

    private func clearSelectedPatternRow() async {
        guard unit == .pattern, patternRows.indices.contains(playheadRow) else { return }
        patternRows[playheadRow] = TrackerDemoRow(cells: Array(repeating: TrackerDemoCell.empty, count: 4))
        await render()
    }

    private func reversePattern() async {
        guard unit == .pattern else { return }
        patternRows.reverse()
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
    // MARK: - REPL

    func command(_ line: String) async {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let verb = parts.first.map(String.init)?.lowercased() ?? ""
        let rest = parts.count > 1 ? String(parts[1]) : ""

        switch verb {
            case "list":
                for category in DemoCategory.allCases {
                    let demos = demoRegistry.filter { $0.descriptor.category == category }
                    guard !demos.isEmpty else { continue }
                    print("\(category.title):")
                    for demo in demos {
                        let id = demo.descriptor.id.padding(toLength: 18, withPad: " ", startingAt: 0)
                        print("  \(id)\(demo.descriptor.summary)")
                    }
                }

            case "open":
                guard let target = demoRegistry.first(where: { $0.descriptor.id == rest.lowercased() }) else {
                    print("? open <id> — see 'list'"); return
                }
                await openDemo(target)
                print("→ \(target.descriptor.title)")

            case "exit":
                await showBrowser()
                print("→ browser")

            case _ where activeModernDemo()?.handleRepl(verb: verb, rest: rest, labContext()) == true:
                break

            case "play":
                await play()

            case "stop":
                await stopPlayback()

            case "clear":
                await clearSelectedPatternRow()
            case "patternclear":
                await showClearPatternDialog()

            case "row":
                guard let row = Self.rowValue(rest) else { print("? row <0-63|hex>"); return }
                await stopPlayback()
                playheadRow = row
                await render()

            case "jog":
                guard let delta = Int(rest.trimmingCharacters(in: .whitespacesAndNewlines)) else { print("? jog <delta>"); return }
                await turnMainEncoder(delta)

            case "push":
                guard Self.jogPushDirections.contains(rest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                    print("? push left|right|up|down|press"); return
                }
                await handleJogPush(rest)

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

            case "led":
                await handleLEDCommand(rest)

            case "ledclear":
                await clearLEDOverrides(rest)

            case "ledlist":
                Self.printLEDList()

            case "guide", "lightguide", "keys":
                await handleGuideCommand(rest)

            case "guideclear", "lightguideclear", "keyclear":
                await clearGuideOverrides(rest)

            case "snap", "screenshot":
                await snapshot(to: rest.isEmpty ? nil : rest)

            case "help", "?":
                printReplHelp()

            case "quit", "q":
                print("bye"); exit(0)

            default:
                print("? unknown '\(verb)' — try help")
        }
    }

    // Headless verification hook: render each implemented unit's two-screen scene to a PNG
    // without a surface/daemon connection. Driven by WIDGETLAB_SNAPSHOT_DIR at launch.
    func snapshotAll(to directory: String) async {
        // The browser itself, once per category filter.
        mode = .browser
        for index in 0..<Self.demoBrowserCategoryValues.count {
            demoBrowserCategoryIndex = index
            demoBrowserNavigation.select(0, itemCount: visibleBrowserDemos().count)
            await snapshot(to: directory + "/widgetlab-browser-\(Self.snapshotSlug(Self.demoBrowserCategoryValues[index])).png")
        }
        demoBrowserCategoryIndex = 0

        mode = .demo
        for demo in modernDemos {
            activeDemo = .modern(demo)
            for variant in [""] + demo.descriptor.snapshotVariants {
                demo.prepareSnapshot(variant: variant)
                let suffix = variant.isEmpty ? "" : "-\(variant)"
                await snapshot(to: directory + "/widgetlab-\(demo.descriptor.id)\(suffix).png")
            }
            demo.prepareSnapshot(variant: "")
        }
        for candidate in Unit.registry {
            unit = candidate
            activeDemo = .legacy(candidate)
            await snapshot(to: directory + "/widgetlab-\(candidate.descriptor.id).png")
            await snapshot(to: directory + "/widgetlab-\(candidate.descriptor.id)-shift.png", layer: .shift)
        }
    }

    private static func snapshotSlug(_ text: String) -> String {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
    }

    private enum SnapshotLayer {
        case base
        case shift
    }

    private func snapshot(to path: String?, layer: SnapshotLayer = .base) async {
        let currentScene = scene()
        var displays = currentScene.displays
        if layer == .shift, let shift = currentScene.shift {
            displays = displays.enumerated().map { index, base in
                shift.displays.indices.contains(index) ? shift.displays[index] ?? base : base
            }
        }
        let frames = displays.map { $0 ?? MK2PixelFrame() }
        let target = path ?? FileManager.default.currentDirectoryPath + "/widgetlab-snapshot.png"
        do {
            let written = try PixelSnapshot.write(frames, to: target)
            print("snapshot → \(written)")
        } catch {
            print("snapshot failed: \(error)")
        }
    }

    private func handleGuideCommand(_ rest: String) async {
        let parts = rest
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard parts.count == 2 else {
            print("? guide <all|0-87> <color|off>"); return
        }
        guard let targets = Self.guideTargets(parts[0]), !targets.isEmpty else {
            print("? unknown light-guide target '\(parts[0])'"); return
        }

        let colorToken = parts[1].lowercased()
        let color: KKRGB
        if colorToken == "off" {
            color = .off
        } else if let parsed = Self.ledColor(parts[1]) {
            color = parsed
        } else {
            print("? color <rrggbb|name|off>"); return
        }

        for index in targets {
            guideOverrides[index] = color
        }
        await render()
        print("guide \(parts[0]) = \(Self.guideColorDescription(color)) (\(targets.count) key\(targets.count == 1 ? "" : "s"))")
    }

    private func clearGuideOverrides(_ rest: String) async {
        let target = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            let count = guideOverrides.count
            guideOverrides.removeAll()
            await render()
            print("guide middleware control restored for all (\(count) override\(count == 1 ? "" : "s"))")
            return
        }
        guard let targets = Self.guideTargets(target), !targets.isEmpty else {
            print("? unknown light-guide target '\(target)'"); return
        }
        for index in targets {
            guideOverrides.removeValue(forKey: index)
        }
        await render()
        print("guide middleware control restored for \(target) (\(targets.count) key\(targets.count == 1 ? "" : "s"))")
    }

    private func handleLEDCommand(_ rest: String) async {
        let parts = rest
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard parts.count == 2 || parts.count == 3 else {
            print("? led <led|group> <color|off> [0-3]"); return
        }
        guard let targets = Self.ledTargets(parts[0]), !targets.isEmpty else {
            print("? unknown LED/group '\(parts[0])' — try ledlist"); return
        }

        let colorToken = parts[1].lowercased()
        let intensity = parts.count == 3 ? Self.ledIntensity(parts[2]) : 3
        guard let intensity else {
            print("? brightness 0-3, off, dim, mid, full"); return
        }

        let state: MK2LampState2
        if colorToken == "off" || intensity == 0 {
            state = .off
        } else if let color = Self.ledColor(parts[1]) {
            state = .on(color, intensity: intensity)
        } else {
            print("? color <rrggbb|name|off>"); return
        }

        for led in targets {
            lampOverrides[led] = state
        }
        await render()
        print("led \(parts[0]) = \(Self.ledStateDescription(state)) (\(targets.count) target\(targets.count == 1 ? "" : "s"))")
    }

    private func clearLEDOverrides(_ rest: String) async {
        let target = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetLabel = target.isEmpty ? "all" : target
        guard let targets = Self.ledTargets(targetLabel), !targets.isEmpty else {
            print("? unknown LED/group '\(targetLabel)' — try ledlist"); return
        }

        let hasFullOwnership = targets.allSatisfy { lampOverrides[$0] != nil }
        if hasFullOwnership {
            for led in targets {
                lampOverrides.removeValue(forKey: led)
            }
            await render()
            print("led middleware control restored for \(targetLabel) (\(targets.count) target\(targets.count == 1 ? "" : "s"))")
        } else {
            for led in targets {
                lampOverrides[led] = .off
            }
            await render()
            print("led \(targetLabel) override ownership active: off (\(targets.count) target\(targets.count == 1 ? "" : "s"))")
        }
    }

    private static func printLEDList() {
        let rgb = KKMK2ButtonLED.allCases.filter(\.isRGBBacklit).map(\.protocolName).joined(separator: " ")
        let mono = KKMK2ButtonLED.allCases.filter { $0.isMonochromeBacklit && !$0.protocolName.hasPrefix("strip") }.map(\.protocolName).joined(separator: " ")
        let strips = KKMK2ButtonLED.allCases.filter { $0.protocolName.hasPrefix("strip") }.map(\.protocolName).joined(separator: " ")
        print("0x80 palette LEDs: \(rgb)")
        print("0x80 fixed monochrome LEDs: \(mono)")
        print("0x80 touch strip LEDs: \(strips)")
        print("0x80 groups: all palette rgb mono buttons strip jog functions transport")
        print("Usage: led <led|group> <color|off> [0-3], ledclear [led|group]")
        print("Light guide: guide <all|0-87> <color|off>, guideclear [all|0-87]")
        print("ledclear toggles ownership: first call forces off, second call returns control to the scene.")
    }

    // MARK: - Parsing helpers

    private func hex(_ value: UInt16) -> String { String(format: "%04X", value) }





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

    private static let jogPushDirections: Set<String> = ["left", "right", "up", "down", "press"]

    private func handleJogPush(_ direction: String) async {
        let normalized = direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        print("? push emulation was removed — 4-D center-confirm now decodes correctly")
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

    private static func guideTargets(_ text: String) -> [Int]? {
        let key = ledKey(text)
        switch key {
            case "all", "keys", "lightguide", "guide":
                return Array(0..<88)
            default:
                guard let index = Int(text), (0..<88).contains(index) else { return nil }
                return [index]
        }
    }

    private static func ledTargets(_ text: String) -> [KKMK2ButtonLED]? {
        let key = ledKey(text)
        switch key {
            case "all":
                return KKMK2ButtonLED.allCases
            case "palette", "rgb":
                return KKMK2ButtonLED.allCases.filter(\.isRGBBacklit)
            case "mono":
                return KKMK2ButtonLED.allCases.filter(\.isMonochromeBacklit)
            case "buttons":
                return KKMK2ButtonLED.allCases.filter { !$0.protocolName.hasPrefix("strip") }
            case "strip", "strips", "touchstrip":
                return KKMK2ButtonLED.allCases.filter { $0.protocolName.hasPrefix("strip") }
            case "jog", "4d", "4dencoder":
                return [.jogLeft, .jogRight, .jogUp, .jogDown]
            case "functions", "function", "func", "f":
                return [.function1, .function2, .function3, .function4, .function5, .function6, .function7, .function8]
            case "transport":
                return [.play, .record, .stop, .loop, .metro, .tempo]
            default:
                if let led = ledAliases[key] {
                    return [led]
                }
                return nil
        }
    }

    private static var ledAliases: [String: KKMK2ButtonLED] {
        var aliases: [String: KKMK2ButtonLED] = [:]
        for led in KKMK2ButtonLED.allCases {
            aliases[ledKey(led.protocolName)] = led
        }
        aliases["m"] = .m
        aliases["mute"] = .m
        aliases["s"] = .s
        aliases["solo"] = .s
        aliases["left"] = .jogLeft
        aliases["right"] = .jogRight
        aliases["up"] = .jogUp
        aliases["down"] = .jogDown
        aliases["pageleft"] = .pageLeft
        aliases["pageright"] = .pageRight
        for index in 1...8 {
            aliases["f\(index)"] = KKMK2ButtonLED(rawValue: KKMK2ButtonLED.function1.rawValue + index - 1)
        }
        return aliases
    }

    private static func ledKey(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func ledColor(_ text: String) -> KKRGB? {
        if let hit = namedLEDColors[text.lowercased()] {
            return hit
        }
        let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
        return KKRGB(
            red: UInt8((rgb >> 16) & 0xff),
            green: UInt8((rgb >> 8) & 0xff),
            blue: UInt8(rgb & 0xff)
        )
    }

    private static func ledIntensity(_ text: String) -> UInt8? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "off", "none", "0":
                return 0
            case "dim", "low", "half", "1":
                return 1
            case "mid", "medium", "2":
                return 2
            case "full", "high", "on", "3":
                return 3
            default:
                return nil
        }
    }

    private static func ledStateDescription(_ state: MK2LampState2) -> String {
        switch state {
            case .off:
                return "off"
            case let .on(color, intensity):
                return "\(String(format: "#%02x%02x%02x", color.red, color.green, color.blue)) @ \(intensity)"
            case let .blink(color, _, intensity):
                return "blink \(String(format: "#%02x%02x%02x", color.red, color.green, color.blue)) @ \(intensity)"
            case let .pulse(color, _):
                return "pulse \(String(format: "#%02x%02x%02x", color.red, color.green, color.blue))"
        }
    }

    private static func guideColorDescription(_ color: KKRGB) -> String {
        color == .off ? "off" : String(format: "#%02x%02x%02x", color.red, color.green, color.blue)
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


let namedLEDColors: [String: KKRGB] = [
    "white": KKRGB(red: 0xff, green: 0xff, blue: 0xff),
    "black": KKRGB(red: 0x00, green: 0x00, blue: 0x00),
    "red": KKRGB(red: 0xff, green: 0x00, blue: 0x00),
    "green": KKRGB(red: 0x00, green: 0xff, blue: 0x00),
    "blue": KKRGB(red: 0x00, green: 0x00, blue: 0xff),
    "yellow": KKRGB(red: 0xff, green: 0xff, blue: 0x00),
    "cyan": KKRGB(red: 0x00, green: 0xff, blue: 0xff),
    "magenta": KKRGB(red: 0xff, green: 0x00, blue: 0xff),
    "orange": KKRGB(red: 0xff, green: 0x7f, blue: 0x00),
    "grey": KKRGB(red: 0x80, green: 0x80, blue: 0x80),
    "gray": KKRGB(red: 0x80, green: 0x80, blue: 0x80),
    "dim": KKRGB(red: 0x40, green: 0x40, blue: 0x40),
]


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

    var label: String {
        switch self {
            case .note: "NOTE"
            case .instrument: "INST"
            case .volume: "VOL"
            case .effect: "FX"
        }
    }

    var valueColor: UInt16 {
        switch self {
            case .note, .volume:
                Palette.text
            case .instrument:
                Palette.instrument
            case .effect:
                Palette.effect
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


