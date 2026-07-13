import Foundation
import AVFoundation
import KompleteKontrol
import KontrolSurfaceKit2

/// The hand-built tracker: the dense pattern grid with playhead, row stripes
/// and channel toggles on the left, the focused row edit surface with the
/// parameter page and its shift slots on the right. Transport, metronome,
/// record arm, live/step MIDI capture and the clear-pattern confirmation
/// dialog (SHIFT+CLEAR) complete the product-shaped picture.
final class TrackerPatternDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "tracker-pattern",
        title: "Tracker Pattern",
        category: .catalogue,
        summary: "Pattern grid, transport, shift layer",
        detail: "The hand-built tracker grid with playhead, transport and channel toggles, the parameter page with shift slots, and the clear-pattern dialog via SHIFT+CLEAR."
    )

    private var context: LabContext?

    private var isPlaying = false
    private var recordArmed = false
    private var metronomeEnabled = false
    private var playheadRow = 0
    private var beatStripe = MK2PatternGridElement.BeatStripe.every(4)
    private var selectedInstrumentIndex = 0
    private var modalDialog: ActiveModalDialog?
    private var playbackTimer: DispatchSourceTimer?
    private var patternRows = TrackerPatternDemo.demoPatternRows()
    private var focusedChannel = 3
    private var mutedChannels: Set<Int> = []
    private var soloedChannels: Set<Int> = []
    private var focusedEditField: TrackerEditField = .note
    private let metronome = DemoMetronome()

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

    deinit {
        playbackTimer?.cancel()
    }

    private var selectedInstrument: DemoInstrument {
        let index = max(Self.instrumentIndexBounds.lowerBound, min(Self.instrumentIndexBounds.upperBound, selectedInstrumentIndex))
        return Self.demoInstruments[index]
    }

    private static func availableLamp(_ color: KKRGB) -> MK2LampState2 {
        .on(color, intensity: availableIntensity)
    }

    private static func activeLamp(_ color: KKRGB) -> MK2LampState2 {
        .on(color, intensity: activeIntensity)
    }

    // MARK: - Scene

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        self.context = context
        if let modalDialog {
            return modalScene(modalDialog, context)
        }

        var lamps: [KKMK2ButtonLED: MK2LampState2] = [:]
        lamps[.play] = isPlaying ? Self.activeLamp(Self.actionGreen) : Self.availableLamp(Self.actionGreen)
        lamps[.stop] = isPlaying ? Self.availableLamp(Self.actionRed) : Self.activeLamp(Self.actionRed)
        lamps[.record] = recordArmed ? Self.activeLamp(Self.actionRed) : Self.availableLamp(Self.actionRed)
        lamps[.clear] = Self.availableLamp(Self.actionWhite)
        // No explicit shift lamp: the scene declares a shift layer, so the kit's
        // automatic convention (dim = available, bright = held) takes over.
        lamps[.pageLeft] = focusedChannel > 0 ? Self.availableLamp(Self.actionWhite) : .off
        lamps[.pageRight] = focusedChannel < 3 ? Self.availableLamp(Self.actionWhite) : .off

        var bindings = MK2InputBindings2()
        bindings.jogScroll = { [weak self] delta, _ in
            context.update { self?.turnMainEncoder(delta) }
        }
        // The 4-D encoder's directional push: up/down step the row (like the
        // rotary), left/right change the focused channel — the same axes as the
        // dedicated PAGE keys below, so either control works.
        bindings.jog = { [weak self] direction in
            context.update {
                switch direction {
                    case "up": self?.turnMainEncoder(-1)
                    case "down": self?.turnMainEncoder(1)
                    case "left": self?.moveFocusedChannel(-1)
                    case "right": self?.moveFocusedChannel(1)
                    default: break
                }
            }
        }
        bindings.onPress(.play) { [weak self] in
            context.update { self?.play() }
        }
        bindings.onPress(.stop) { [weak self] in
            context.update { self?.stopPlayback() }
        }
        bindings.onPress(.record) { [weak self] in
            context.update { self?.recordArmed.toggle() }
        }
        bindings.onPress(.clear, modifiers: .unmodified) { [weak self] in
            context.update { self?.clearSelectedPatternRow() }
        }
        bindings.onPress(.clear, modifiers: .shift) { [weak self] in
            context.update { self?.modalDialog = .clearPattern(selectedIndex: 0) }
        }
        bindings.onPress(.pageLeft) { [weak self] in
            context.update { self?.moveFocusedChannel(-1) }
        }
        bindings.onPress(.pageRight) { [weak self] in
            context.update { self?.moveFocusedChannel(1) }
        }

        MK2ButtonToggle(
            button: .metro,
            isOn: metronomeEnabled,
            onLamp: Self.activeLamp(Self.actionWhite),
            offLamp: Self.availableLamp(Self.actionWhite)
        ) { [weak self] enabled in
            context.update { self?.metronomeEnabled = enabled }
        }
        .apply(lamps: &lamps, bindings: &bindings)

        channelMuteToggle(focusedChannel) { [weak self] enabled in
            context.update { self?.setFocusedChannelMute(enabled) }
        }
        .apply(lamps: &lamps, bindings: &bindings)

        channelSoloToggle(focusedChannel) { [weak self] enabled in
            context.update { self?.setFocusedChannelSolo(enabled) }
        }
        .apply(lamps: &lamps, bindings: &bindings)

        MK2ButtonRangeSelection(
            value: selectedInstrumentIndex,
            bounds: Self.instrumentIndexBounds,
            previousButton: .presetUp,
            nextButton: .presetDown,
            availableLamp: Self.availableLamp(Self.actionWhite)
        ) { [weak self] index in
            context.update { self?.setSelectedInstrumentIndex(index) }
        }
        .apply(lamps: &lamps, bindings: &bindings)

        let targetChannel = focusedChannel
        bindings.midiFocus = MIDIFocus("tracker.channel.\(targetChannel + 1)") { [weak self] event in
            context.update { self?.receiveMIDI(event, targetChannel: targetChannel) }
        }

        let leftResult = trackerGridResult(context)
        let rightResult = trackerDetailResult(context)
        lamps.merge(leftResult.lamps) { _, next in next }
        lamps.merge(rightResult.lamps) { _, next in next }
        bindings.merge(leftResult.bindings)
        bindings.merge(rightResult.bindings)

        var keyColors = leftResult.keyColors
        keyColors.merge(rightResult.keyColors) { _, next in next }
        return MK2SurfaceScene2(
            left: leftResult.screen.frame,
            right: rightResult.screen.frame,
            lamps: lamps,
            keyColors: keyColors,
            bindings: bindings,
            shift: MK2SurfaceScene2.ShiftLayer(left: leftResult, right: rightResult)
        )
    }

    func demoWillClose() {
        isPlaying = false
        playbackTimer?.cancel()
        playbackTimer = nil
    }

    private func modalScene(_ modalDialog: ActiveModalDialog, _ context: LabContext) -> MK2SurfaceScene2 {
        switch modalDialog {
            case let .clearPattern(selectedIndex):
                return MK2ModalDialog(
                    severity: .warning,
                    title: "CLEAR PATTERN",
                    message: [
                        "Do you really want to clear",
                        "the current pattern?",
                    ],
                    actions: [
                        MK2ModalDialogAction("Yes, clear", detail: "The current pattern will be emptied"),
                    ],
                    selectedIndex: selectedIndex,
                    dismissHint: "Any other hardware button cancels",
                    onSelectionChange: { [weak self] index in
                        context.update { self?.setModalSelection(index) }
                    },
                    onConfirm: { [weak self] _ in
                        context.update { self?.confirmModalDialog() }
                    },
                    onDismiss: { [weak self] in
                        context.update { self?.modalDialog = nil }
                    }
                ).scene()
        }
    }

    // MARK: - Left screen: pattern grid

    private func trackerGridResult(_ context: LabContext) -> MK2ScreenBuildResult {
        let firstRow = visibleFirstRow(center: playheadRow)
        let transportText = isPlaying ? "PLAY" : "STOP"
        let transportColor = isPlaying ? Palette.green : Palette.orange
        let rowText = hex2(playheadRow)
        return MK2FullScreenDSL(background: Palette.page) {
            MK2RenderBlock { frame, _ in
                BitmapLabel("PATTERN 03", font: .grid, color: Palette.blue).draw(into: &frame, x: 8, y: 8)
                BitmapLabel("LEN 64", font: .grid, color: Palette.dim).draw(into: &frame, x: 138, y: 8)
                BitmapLabel("ROW \(rowText)", font: .gridBold, color: Palette.text).draw(into: &frame, x: 232, y: 8)
                BitmapLabel(transportText, font: .gridBold, color: transportColor).draw(into: &frame, x: 330, y: 8)
                BitmapLabel("SPD 06", font: .grid, color: Palette.dim).draw(into: &frame, x: 398, y: 8)
            }
            MK2PatternGridElement(
                rows: trackerGridRows(firstRow: firstRow),
                channels: trackerGridChannels(),
                selectedRowIndex: playheadRow,
                isPlaying: isPlaying,
                beatStripe: beatStripe
            )
            MK2OverviewScrollbarElement(
                rowCount: patternRows.count,
                selectedRowIndex: playheadRow,
                rowActivity: patternRows.map { row in row.cells.contains { !$0.isEmpty } },
                rect: MK2PixelRect(x: 466, y: 62, width: 5, height: 200)
            )
        }.build(renderer: context.renderer)
    }

    private func trackerGridRows(firstRow: Int) -> [MK2PatternGridElement.Row] {
        (0..<MK2PatternGridElement.visibleRowCount).map { visible in
            let row = firstRow + visible
            let cells = patternRows[row].cells.map { $0.gridCell }
            return MK2PatternGridElement.Row(index: row, cells: cells)
        }
    }

    private func trackerGridChannels() -> [MK2PatternGridElement.Channel] {
        (0..<4).map { index in
            MK2PatternGridElement.Channel(
                label: "CHANNEL \(index + 1)",
                isMuted: mutedChannels.contains(index),
                isSoloed: soloedChannels.contains(index),
                isFocused: index == focusedChannel
            )
        }
    }

    private func visibleFirstRow(center: Int) -> Int {
        min(max(0, center - 6), max(0, patternRows.count - 13))
    }

    private func hex2(_ value: Int) -> String {
        String(format: "%02X", max(0, min(255, value)))
    }

    // MARK: - Right screen: row edit surface

    private func trackerDetailResult(_ context: LabContext) -> MK2ScreenBuildResult {
        let cell = patternRows[playheadRow].cells[focusedChannel]
        let selectedInstrumentText = "INST \(selectedInstrument.displayName)"
        let statusItems = [
            MK2StatusLineItem("EDIT", x: 8, color: Palette.blue),
            MK2StatusLineItem("CH\(focusedChannel + 1)", x: 92, color: Palette.dim),
            MK2StatusLineItem("ROW \(hex2(playheadRow))", x: 158, color: Palette.text, font: .gridBold),
        ]
        let slots = trackerEditParameterSlots(cell: cell, context)

        return MK2FullScreenDSL(background: Palette.page) {
            // The base F-slots are decorative look probes without bindings. The shift
            // slots are live: CLR PAT sits above the CLEAR slot, REVERSE above TRIM,
            // and the two empty shift slots demonstrate that an unlabeled slot
            // swallows the press under shift.
            MK2FunctionKeyBarElement(
                slots: [
                    MK2FunctionKeySlot("COPY", iconGlyph: MK2HIG.IconGlyph.copy),
                    MK2FunctionKeySlot("PASTE", iconGlyph: MK2HIG.IconGlyph.clipboard),
                    MK2FunctionKeySlot("CLEAR", iconGlyph: MK2HIG.IconGlyph.eraser, isEnabled: false),
                    MK2FunctionKeySlot("TRIM", iconGlyph: MK2HIG.IconGlyph.crop),
                ],
                shiftSlots: [
                    MK2FunctionKeySlot(),
                    MK2FunctionKeySlot(),
                    MK2FunctionKeySlot("CLR PAT"),
                    MK2FunctionKeySlot("REVERSE"),
                ],
                side: .right,
                onShiftPress: { [weak self] slot in
                    context.update {
                        switch slot {
                            case 2: self?.modalDialog = .clearPattern(selectedIndex: 0)
                            case 3: self?.patternRows.reverse()
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
                shiftSlots: trackerShiftEditParameterSlots(cell: cell, context),
                rect: MK2PixelRect(x: 8, y: 215, width: 464, height: 57),
                columns: 4,
                relativeToContent: false
            )
        }.build(renderer: context.renderer)
    }

    private func trackerEditParameterSlots(cell: TrackerDemoCell, _ context: LabContext) -> [MK2ParameterPageSlot] {
        TrackerEditField.allCases.map { field in
            MK2ParameterPageSlot(
                label: field.label,
                iconGlyph: field.iconGlyph,
                value: editDisplayValue(for: field, cell: cell),
                isFocused: focusedEditField == field,
                encoderValue: MK2EncoderDiscreteValue(
                    encoder: field.encoder,
                    value: editValue(for: field, cell: cell),
                    bounds: field.bounds,
                    wraps: false,
                    onTouch: { [weak self] touched in
                        guard touched else { return }
                        context.update { self?.focusedEditField = field }
                    },
                    onChange: { [weak self] value in
                        context.update { self?.setFocusedEditValue(value, field: field) }
                    }
                ),
                colors: labEditCellColors(value: field.valueColor)
            )
        }
    }

    /// Under shift the NOTE encoder steps in octaves; the other cells keep their
    /// visual but bring no encoder value, so their base bindings stay active.
    private func trackerShiftEditParameterSlots(cell: TrackerDemoCell, _ context: LabContext) -> [MK2ParameterPageSlot] {
        TrackerEditField.allCases.map { field in
            guard field == .note else {
                return MK2ParameterPageSlot(
                    label: field.label,
                    iconGlyph: field.iconGlyph,
                    value: editDisplayValue(for: field, cell: cell),
                    isFocused: focusedEditField == field,
                    colors: labEditCellColors(value: field.valueColor)
                )
            }
            var colors = labEditCellColors(value: field.valueColor)
            colors.label = MK2HIG.Chrome.shiftAccent
            return MK2ParameterPageSlot(
                label: "OCTAVE",
                iconGlyph: MK2HIG.IconGlyph.arrowsDownUp,
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
                        context.update { self?.focusedEditField = .note }
                    },
                    onChange: { [weak self] value in
                        context.update { self?.setFocusedEditValue(value, field: .note) }
                    }
                ),
                colors: colors
            )
        }
    }

    // MARK: - Transport

    private func play() {
        guard !isPlaying else { return }
        isPlaying = true
        playMetronomeIfNeeded(row: playheadRow)
        playbackTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(180), repeating: .milliseconds(180), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            self?.context?.update { self?.advancePlayback() }
        }
        playbackTimer = timer
        timer.resume()
    }

    private func stopPlayback() {
        let wasPlaying = isPlaying
        isPlaying = false
        playbackTimer?.cancel()
        playbackTimer = nil
        if !wasPlaying {
            playheadRow = 0
        }
    }

    private func advancePlayback() {
        guard isPlaying else { return }
        playheadRow = (playheadRow + 1) % patternRows.count
        playMetronomeIfNeeded(row: playheadRow)
    }

    private func playMetronomeIfNeeded(row: Int) {
        guard metronomeEnabled, isPlaying, row.isMultiple(of: 4) else { return }
        metronome.play(accent: row.isMultiple(of: 16))
    }

    // MARK: - Editing

    private func turnMainEncoder(_ delta: Int) {
        guard delta != 0, !isPlaying else { return }
        playheadRow = max(0, min(patternRows.count - 1, playheadRow + delta))
    }

    private func moveFocusedChannel(_ delta: Int) {
        guard delta != 0 else { return }
        focusedChannel = max(0, min(3, focusedChannel + delta))
    }

    private func setFocusedChannelSolo(_ enabled: Bool) {
        if enabled {
            soloedChannels.insert(focusedChannel)
        } else {
            soloedChannels.remove(focusedChannel)
        }
    }

    private func setFocusedChannelMute(_ enabled: Bool) {
        if enabled {
            mutedChannels.insert(focusedChannel)
        } else {
            mutedChannels.remove(focusedChannel)
        }
    }

    private func setFocusedEditValue(_ value: Int, field: TrackerEditField) {
        guard patternRows.indices.contains(playheadRow),
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

    private func setSelectedInstrumentIndex(_ index: Int) {
        selectedInstrumentIndex = max(Self.instrumentIndexBounds.lowerBound, min(Self.instrumentIndexBounds.upperBound, index))
    }

    // MARK: - Modal dialog

    private func setModalSelection(_ index: Int) {
        guard let modalDialog else { return }
        switch modalDialog {
            case .clearPattern:
                self.modalDialog = .clearPattern(selectedIndex: max(0, min(0, index)))
        }
    }

    private func confirmModalDialog() {
        guard let modalDialog else { return }
        switch modalDialog {
            case .clearPattern:
                clearActivePattern()
        }
    }

    private func clearActivePattern() {
        isPlaying = false
        playbackTimer?.cancel()
        playbackTimer = nil
        patternRows = Self.emptyPatternRows()
        playheadRow = 0
        modalDialog = nil
    }

    private func clearSelectedPatternRow() {
        guard patternRows.indices.contains(playheadRow) else { return }
        patternRows[playheadRow] = TrackerDemoRow(cells: Array(repeating: TrackerDemoCell.empty, count: 4))
    }

    // MARK: - MIDI capture

    private func receiveMIDI(_ event: KKMIDIEvent, targetChannel: Int) {
        guard (0..<4).contains(targetChannel) else { return }
        let didRecord = recordArmed && record(event, row: playheadRow, channel: targetChannel)
        if didRecord, !isPlaying {
            playheadRow = (playheadRow + 1) % patternRows.count
        }
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

    // MARK: - REPL

    func replCommands() -> [ReplCommand] {
        [
            ReplCommand(name: "play", arg: "", summary: "tracker: start playback", values: []),
            ReplCommand(name: "stop", arg: "", summary: "tracker: stop playback", values: []),
            ReplCommand(name: "clear", arg: "", summary: "tracker: clear selected row", values: []),
            ReplCommand(name: "patternclear", arg: "", summary: "tracker: clear pattern with confirmation", values: []),
            ReplCommand(name: "row", arg: "<0-63|hex>", summary: "tracker: set stopped playhead row", values: []),
            ReplCommand(name: "jog", arg: "<delta>", summary: "tracker: emulate 4-D row rotation", values: []),
            ReplCommand(name: "ch", arg: "<1-4>", summary: "tracker: set focused channel", values: ["1", "2", "3", "4"]),
            ReplCommand(name: "solo", arg: "on|off|toggle", summary: "tracker: solo focused channel", values: ["on", "off", "toggle"]),
            ReplCommand(name: "mute", arg: "on|off|toggle", summary: "tracker: mute focused channel", values: ["on", "off", "toggle"]),
            ReplCommand(name: "stripe", arg: "off|odd|even|<n>|every <n> [phase]", summary: "tracker: row stripe rule", values: ["off", "odd", "even", "4", "16", "every"]),
            ReplCommand(name: "rec", arg: "on|off|toggle", summary: "tracker: arm record", values: ["on", "off", "toggle"]),
            ReplCommand(name: "metro", arg: "on|off|toggle", summary: "tracker: toggle metronome", values: ["on", "off", "toggle"]),
            ReplCommand(name: "midi", arg: "<note> [velocity]", summary: "tracker: route MIDI to focused channel", values: []),
        ]
    }

    func handleRepl(verb: String, rest: String, _ context: LabContext) -> Bool {
        switch verb {
            case "play":
                context.update { [weak self] in self?.play() }

            case "stop":
                context.update { [weak self] in self?.stopPlayback() }

            case "clear":
                context.update { [weak self] in self?.clearSelectedPatternRow() }

            case "patternclear":
                context.update { [weak self] in self?.modalDialog = .clearPattern(selectedIndex: 0) }

            case "row":
                guard let row = Self.rowValue(rest) else { print("? row <0-63|hex>"); return true }
                context.update { [weak self] in
                    self?.stopPlayback()
                    self?.playheadRow = row
                }

            case "jog":
                guard let delta = Int(rest.trimmingCharacters(in: .whitespacesAndNewlines)) else { print("? jog <delta>"); return true }
                context.update { [weak self] in self?.turnMainEncoder(delta) }

            case "ch", "channel":
                guard let channel = Int(rest.trimmingCharacters(in: .whitespacesAndNewlines)),
                      (1...4).contains(channel) else { print("? ch <1-4>"); return true }
                context.update { [weak self] in self?.focusedChannel = channel - 1 }

            case "solo":
                guard let enabled = Self.triState(rest, current: soloedChannels.contains(focusedChannel)) else {
                    print("? solo on|off|toggle"); return true
                }
                context.update { [weak self] in self?.setFocusedChannelSolo(enabled) }

            case "mute":
                guard let enabled = Self.triState(rest, current: mutedChannels.contains(focusedChannel)) else {
                    print("? mute on|off|toggle"); return true
                }
                context.update { [weak self] in self?.setFocusedChannelMute(enabled) }

            case "stripe", "stripes", "rowstripe", "rowstripes":
                guard let mode = Self.beatStripe(rest) else {
                    print("? stripe off|odd|even|<n>|every <n> [phase]"); return true
                }
                context.update { [weak self] in self?.beatStripe = mode }

            case "rec", "record":
                guard let armed = Self.triState(rest, current: recordArmed) else {
                    print("? rec on|off|toggle"); return true
                }
                context.update { [weak self] in self?.recordArmed = armed }

            case "metro", "metronome":
                guard let enabled = Self.triState(rest, current: metronomeEnabled) else {
                    print("? metro on|off|toggle"); return true
                }
                context.update { [weak self] in self?.metronomeEnabled = enabled }

            case "midi":
                guard let event = Self.midiEvent(rest) else { print("? midi <note> [velocity]"); return true }
                let channel = focusedChannel
                context.update { [weak self] in self?.receiveMIDI(event, targetChannel: channel) }

            default:
                return false
        }
        return true
    }

    // MARK: - Parsing and fixtures

    private static func rowValue(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPrefixedHex = trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X")
        let raw = isPrefixedHex ? String(trimmed.dropFirst(2)) : trimmed
        let hasHexLetters = raw.rangeOfCharacter(from: CharacterSet(charactersIn: "ABCDEFabcdef")) != nil
        let parsed = Int(raw, radix: isPrefixedHex || hasHexLetters ? 16 : 10)
        guard let parsed, (0..<64).contains(parsed) else { return nil }
        return parsed
    }

    private static func beatStripe(_ text: String) -> MK2PatternGridElement.BeatStripe? {
        let parts = text
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        guard let first = parts.first else { return .every(4) }
        switch first {
            case "off", "none", "no":
                return MK2PatternGridElement.BeatStripe.none
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

    private static func midiEvent(_ text: String) -> KKMIDIEvent? {
        let parts = text.split(separator: " ").map(String.init)
        guard let noteText = parts.first, let note = UInt8(noteText) else { return nil }
        let velocity = parts.dropFirst().first.flatMap(UInt8.init) ?? 100
        return KKMIDIEvent(kind: .noteOn, channel: 0, note: note, velocity: velocity)
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
}

// MARK: - Tracker model types

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

    /// The grid drops `volume` (it never showed in the grid) and maps the
    /// sentinel placeholders back to the shared element's per-field optionals.
    var gridCell: MK2PatternGridElement.Cell {
        MK2PatternGridElement.Cell(
            note: note == "..." ? nil : note,
            instrument: instrument == ".." ? nil : instrument,
            effect: effect == "..." ? nil : effect
        )
    }
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

    var iconGlyph: String {
        switch self {
            case .note: MK2HIG.IconGlyph.musicNote
            case .instrument: MK2HIG.IconGlyph.pianoKeys
            case .volume: MK2HIG.IconGlyph.speakerHigh
            case .effect: MK2HIG.IconGlyph.lightning
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

// MARK: - Metronome

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
