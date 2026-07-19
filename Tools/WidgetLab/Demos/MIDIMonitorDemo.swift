import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

/// A hardware-neutral view of Kit2's final MIDI stream. MK2 keybed packets and
/// MK3 pad synthesis both arrive through the same `midiFocus` binding, so the
/// demo intentionally contains no device-family checks.
final class MIDIMonitorDemo: LabDemo, @unchecked Sendable {
    let descriptor = DemoDescriptor(
        id: "midi-monitor",
        title: "MIDI Monitor",
        category: .diagnostics,
        summary: "Held notes, chords, velocity and pressure",
        detail: "The common Kit2 MIDI route: play an MK2 keybed or strike MK3 pads and compare Note On/Off, held chords, velocity, poly pressure, channel pressure, CC, and pitch bend. CLEAR resets the monitor.",
        snapshotVariants: ["chord"]
    )

    private struct NoteKey: Hashable {
        var channel: UInt8
        var note: UInt8
    }

    private struct HeldNote {
        var key: NoteKey
        var velocity: UInt8
        var pressure: UInt8
        var order: UInt64
    }

    private struct EventRow {
        var text: String
        var color: UInt16
    }

    private var heldNotes: [NoteKey: HeldNote] = [:]
    private var recentEvents: [EventRow] = []
    private var eventCount: UInt64 = 0
    private var nextOrder: UInt64 = 0
    private var channelPressure: UInt8 = 0
    private var pitchBend = 0
    private var lastCC: (control: UInt8, value: UInt8)?
    private var renderTask: Task<Void, Never>?

    func buildScene(_ context: LabContext) -> MK2SurfaceScene2 {
        var scene = MK2SurfaceScene2(
            left: heldNotesScreen(context).screen.frame,
            right: eventStreamScreen(context).screen.frame,
            lamps: [.clear: .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01)]
        )
        scene.bindings.midiFocus = MIDIFocus("widgetlab.midi-monitor") { [weak self] event in
            self?.receiveLive(event, context: context)
        }
        scene.bindings.onPress(.clear) { [weak self] in
            context.update { [weak self] in self?.clear() }
        }
        return scene
    }

    func prepareSnapshot(variant: String) {
        clear()
        guard variant == "chord" else { return }
        receive(KKMIDIEvent(kind: .noteOn, channel: 0, note: 60, velocity: 82))
        receive(KKMIDIEvent(kind: .noteOn, channel: 0, note: 64, velocity: 104))
        receive(KKMIDIEvent(kind: .noteOn, channel: 0, note: 67, velocity: 118))
        receive(KKMIDIEvent(polyphonicPressure: 73, note: 64, channel: 0))
        receive(KKMIDIEvent(channelPressure: 41, channel: 0))
        receive(KKMIDIEvent(pitchBendLSB: 0, msb: 72, channel: 0))
    }

    func demoWillClose() {
        renderTask?.cancel()
        renderTask = nil
    }

    func replCommands() -> [ReplCommand] {
        [
            ReplCommand(name: "midion", arg: "<note> [velocity] [channel]", summary: "MIDI monitor: inject Note On", values: []),
            ReplCommand(name: "midioff", arg: "<note> [channel]", summary: "MIDI monitor: inject Note Off", values: []),
            ReplCommand(name: "midipressure", arg: "<note> <value> [channel]", summary: "MIDI monitor: inject poly pressure", values: []),
            ReplCommand(name: "midichord", arg: "", summary: "MIDI monitor: hold a C major fixture", values: []),
            ReplCommand(name: "midiclear", arg: "", summary: "MIDI monitor: clear held notes and log", values: []),
        ]
    }

    func handleRepl(verb: String, rest: String, _ context: LabContext) -> Bool {
        let values = rest.split(whereSeparator: \.isWhitespace).compactMap { UInt8($0) }
        switch verb {
            case "midion":
                guard let note = values.first else { print("? midion <note> [velocity] [channel]"); return true }
                let velocity = values.indices.contains(1) ? values[1] : 100
                let channel = values.indices.contains(2) ? min(15, values[2]) : 0
                context.update { [weak self] in
                    self?.receive(KKMIDIEvent(kind: .noteOn, channel: channel, note: note, velocity: max(1, velocity)))
                }
            case "midioff":
                guard let note = values.first else { print("? midioff <note> [channel]"); return true }
                let channel = values.indices.contains(1) ? min(15, values[1]) : 0
                context.update { [weak self] in
                    self?.receive(KKMIDIEvent(kind: .noteOff, channel: channel, note: note, velocity: 0))
                }
            case "midipressure":
                guard values.count >= 2 else { print("? midipressure <note> <value> [channel]"); return true }
                let channel = values.indices.contains(2) ? min(15, values[2]) : 0
                context.update { [weak self] in
                    self?.receive(KKMIDIEvent(polyphonicPressure: min(127, values[1]), note: values[0], channel: channel))
                }
            case "midichord":
                context.update { [weak self] in self?.prepareSnapshot(variant: "chord") }
            case "midiclear":
                context.update { [weak self] in self?.clear() }
            default:
                return false
        }
        return true
    }

    func testState() -> String? {
        "held=\(heldNotes.count) events=\(eventCount)"
    }

    // MARK: - Input

    private func receiveLive(_ event: KKMIDIEvent, context: LabContext) {
        // Pressure can arrive much faster than the displays can refresh. Keep
        // every MIDI state transition immediately, but coalesce visual work to
        // one pending render so input never queues behind framebuffer builds.
        context.mutate { [weak self] in
            guard let self else { return }
            self.receive(event)
            self.scheduleRender(context)
        }
    }

    private func scheduleRender(_ context: LabContext) {
        guard renderTask == nil else { return }
        renderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled else { return }
            context.update { [weak self] in self?.renderTask = nil }
        }
    }

    private func receive(_ event: KKMIDIEvent) {
        eventCount &+= 1
        let key = NoteKey(channel: event.channel, note: event.note)
        switch event.kind {
            case .noteOn where event.velocity > 0:
                nextOrder &+= 1
                heldNotes[key] = HeldNote(
                    key: key,
                    velocity: event.velocity,
                    pressure: heldNotes[key]?.pressure ?? 0,
                    order: nextOrder
                )
                append("ON    \(Self.noteName(event.note))  V\(Self.threeDigits(event.velocity))  CH\(event.channel + 1)", color: Palette.accent)
            case .noteOn, .noteOff:
                heldNotes.removeValue(forKey: key)
                append("OFF   \(Self.noteName(event.note))        CH\(event.channel + 1)", color: Palette.dim)
            case .polyphonicPressure:
                if var held = heldNotes[key] {
                    held.pressure = event.pressure
                    heldNotes[key] = held
                }
                append("POLY  \(Self.noteName(event.note))  P\(Self.threeDigits(event.pressure))  CH\(event.channel + 1)", color: Palette.green)
            case .channelPressure:
                channelPressure = event.pressure
                append("PRESSURE       \(Self.threeDigits(event.pressure))  CH\(event.channel + 1)", color: Palette.green)
            case .controlChange:
                lastCC = (event.control, event.controlValue)
                append("CC\(Self.threeDigits(event.control))         \(Self.threeDigits(event.controlValue))  CH\(event.channel + 1)", color: Palette.orange)
            case .pitchBend:
                pitchBend = event.pitchBendCentered
                append(String(format: "BEND          %+5d  CH%d", pitchBend, event.channel + 1), color: Palette.orange)
        }
    }

    private func append(_ text: String, color: UInt16) {
        recentEvents.insert(EventRow(text: text, color: color), at: 0)
        if recentEvents.count > 7 {
            recentEvents.removeLast(recentEvents.count - 7)
        }
    }

    private func clear() {
        heldNotes.removeAll(keepingCapacity: true)
        recentEvents.removeAll(keepingCapacity: true)
        eventCount = 0
        nextOrder = 0
        channelPressure = 0
        pitchBend = 0
        lastCC = nil
    }

    // MARK: - Screens

    private func heldNotesScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        let notes = heldNotes.values.sorted { $0.order < $1.order }
        let heldSummary = notes.prefix(6).map { Self.noteName($0.key.note) }.joined(separator: " ")
        return MK2RegularScreenDSL(
            header: .title(title: "MIDI Monitor", subtitle: "COMMON KIT2 ROUTE"),
            footer: .hint("MK2 KEYBED / MK3 PADS")
        ) {
            MK2AnyScreenElement { frame, elementContext, _ in
                guard let content = elementContext.layout?.contentRect else { return }
                let left = content.x + 8
                let top = content.y + 5
                BitmapLabel("HELD \(notes.count)", font: .gridBold, color: notes.isEmpty ? Palette.dim : Palette.text)
                    .draw(into: &frame, x: left, y: top, clip: content)
                BitmapLabel(heldSummary.isEmpty ? "PLAY NOTES OR STRIKE PADS" : heldSummary, font: .grid, color: notes.isEmpty ? Palette.empty : Palette.accent)
                    .draw(into: &frame, x: left + 92, y: top, clip: content)

                if notes.isEmpty {
                    BitmapLabel("NO NOTES HELD", font: .readoutBold, color: Palette.empty)
                        .draw(into: &frame, x: left + 126, y: top + 82, clip: content)
                    return
                }

                let cellWidth = 106
                let cellHeight = 68
                let gapX = 8
                let gapY = 10
                let gridTop = top + 28
                for (index, held) in notes.prefix(8).enumerated() {
                    let rect = MK2PixelRect(
                        x: left + (index % 4) * (cellWidth + gapX),
                        y: gridTop + (index / 4) * (cellHeight + gapY),
                        width: cellWidth,
                        height: cellHeight
                    )
                    frame.fill(rect, Palette.focusedChannelFill)
                    frame.stroke(rect, Palette.accent, width: 1)
                    BitmapLabel(Self.noteName(held.key.note), font: .readoutBold, color: Palette.text)
                        .draw(into: &frame, x: rect.x + 7, y: rect.y + 6, clip: rect)
                    BitmapLabel("N\(held.key.note) C\(held.key.channel + 1)", font: .label, color: Palette.dim)
                        .draw(into: &frame, x: rect.x + 54, y: rect.y + 8, clip: rect)
                    BitmapLabel("V\(Self.threeDigits(held.velocity))", font: .gridBold, color: Palette.accent)
                        .draw(into: &frame, x: rect.x + 7, y: rect.y + 34, clip: rect)
                    BitmapLabel("P\(Self.threeDigits(held.pressure))", font: .gridBold, color: held.pressure > 0 ? Palette.green : Palette.dim)
                        .draw(into: &frame, x: rect.x + 57, y: rect.y + 34, clip: rect)
                    let track = MK2PixelRect(x: rect.x + 7, y: rect.maxY - 9, width: rect.width - 14, height: 4)
                    frame.fill(track, Palette.track)
                    let fill = Int(held.velocity) * track.width / 127
                    if fill > 0 {
                        frame.fill(MK2PixelRect(x: track.x, y: track.y, width: fill, height: track.height), Palette.accent)
                    }
                }
            }
        }.build(renderer: context.renderer)
    }

    private func eventStreamScreen(_ context: LabContext) -> MK2ScreenBuildResult {
        let rows = recentEvents
        let heldPitchClasses = Set(heldNotes.values.map { Int($0.key.note) % 12 })
        let count = eventCount
        let pressure = channelPressure
        let bend = pitchBend
        let cc = lastCC
        return MK2RegularScreenDSL(
            header: .title(title: "Unified MIDI Stream", subtitle: "MIDI FOCUS"),
            footer: .hint("CLEAR RESETS MONITOR")
        ) {
            MK2AnyScreenElement { frame, elementContext, _ in
                guard let content = elementContext.layout?.contentRect else { return }
                let left = content.x + 8
                let top = content.y + 5
                let pitchNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
                for pitch in 0..<12 {
                    let rect = MK2PixelRect(x: left + pitch * 37, y: top, width: 33, height: 25)
                    let active = heldPitchClasses.contains(pitch)
                    frame.fill(rect, active ? Palette.cursorFill : Palette.editFieldFill)
                    frame.stroke(rect, active ? Palette.accent : Palette.border, width: 1)
                    BitmapLabel(pitchNames[pitch], font: .label, color: active ? Palette.text : Palette.dim)
                        .draw(into: &frame, x: rect.x + 6, y: rect.y + 6, clip: rect)
                }

                BitmapLabel("RECENT EVENTS", font: .gridBold, color: Palette.text)
                    .draw(into: &frame, x: left, y: top + 37, clip: content)
                BitmapLabel("TOTAL \(count)", font: .grid, color: Palette.dim)
                    .draw(into: &frame, x: left + 340, y: top + 37, clip: content)
                if rows.isEmpty {
                    BitmapLabel("WAITING FOR MIDI INPUT", font: .grid, color: Palette.empty)
                        .draw(into: &frame, x: left, y: top + 66, clip: content)
                } else {
                    for (index, row) in rows.prefix(6).enumerated() {
                        let y = top + 62 + index * 20
                        if index.isMultiple(of: 2) {
                            frame.fill(MK2PixelRect(x: left, y: y - 3, width: 448, height: 19), Palette.rowStripe)
                        }
                        BitmapLabel(row.text, font: .grid, color: row.color)
                            .draw(into: &frame, x: left + 4, y: y, clip: content)
                    }
                }

                let expressionY = top + 185
                frame.fill(MK2PixelRect(x: left, y: expressionY - 5, width: 448, height: 1), Palette.border)
                BitmapLabel("CH PRESS \(Self.threeDigits(pressure))", font: .label, color: pressure > 0 ? Palette.green : Palette.dim)
                    .draw(into: &frame, x: left, y: expressionY, clip: content)
                BitmapLabel(String(format: "BEND %+5d", bend), font: .label, color: bend == 0 ? Palette.dim : Palette.orange)
                    .draw(into: &frame, x: left + 150, y: expressionY, clip: content)
                let ccText = cc.map { "CC\(Self.threeDigits($0.control)) \(Self.threeDigits($0.value))" } ?? "CC --- ---"
                BitmapLabel(ccText, font: .label, color: cc == nil ? Palette.dim : Palette.orange)
                    .draw(into: &frame, x: left + 314, y: expressionY, clip: content)
            }
        }.build(renderer: context.renderer)
    }

    private static func noteName(_ note: UInt8) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let value = Int(note)
        return "\(names[value % 12])\(value / 12 - 1)"
    }

    private static func threeDigits(_ value: UInt8) -> String {
        String(format: "%03d", value)
    }
}
