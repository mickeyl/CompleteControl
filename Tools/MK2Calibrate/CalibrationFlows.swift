import Foundation
import KompleteKontrol

/// Merges surface reports and console lines into one blocking stream so a flow can
/// wait for "whatever happens next".
final class FlowInputQueue {
    enum Item {
        case surface(raw: [UInt8], events: [KKMK2InputEvent], risingBits: [(byte: Int, mask: UInt8)])
        case console(String)
        case midi(String)
    }

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var items: [Item] = []
    private var previousReport: [UInt8]?

    /// MIDI note of light-guide key 0; command keys sit on the bottom octave so the
    /// hands never have to leave the hardware.
    var commandBaseNote = 36
    static let commandKeys: [(offset: Int, command: String, label: String, color: KKRGB)] = [
        (0, "", "DONE", KKRGB(red: 0x00, green: 0xff, blue: 0x00)),
        (2, "n", "NOTHING LIT", KKRGB(red: 0xff, green: 0x00, blue: 0x00)),
        (4, "s", "LIT NO BUTTON", KKRGB(red: 0xff, green: 0x7f, blue: 0x00)),
        (5, "r", "REPEAT", KKRGB(red: 0x00, green: 0x00, blue: 0xff)),
        (7, "b", "BACK", KKRGB(red: 0xff, green: 0x00, blue: 0xff)),
        (9, "q", "QUIT FLOW", KKRGB(red: 0xff, green: 0xff, blue: 0xff)),
    ]

    func attach(to link: DaemonLink) {
        link.onSurfaceReport = { [weak self] raw in
            self?.ingest(raw)
        }
        link.onMIDIPacket = { [weak self] packet in
            self?.ingestMIDI(packet)
        }
        Thread.detachNewThread { [weak self] in
            while let line = readLine(strippingNewline: true) {
                self?.push(.console(line.lowercased()))
            }
        }
    }

    func next(timeout: TimeInterval = 60) -> Item? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }

    func drain() {
        lock.lock()
        items.removeAll()
        lock.unlock()
        while semaphore.wait(timeout: .now()) == .success {}
    }

    private func ingest(_ raw: [UInt8]) {
        guard raw.first == UInt8(KompleteKontrolMK2Protocol.inputReportID) else { return }
        let previous = previousReport
        previousReport = raw
        let events = KKMK2InputReportDecoder.events(previous: previous, current: raw)
        var rising: [(byte: Int, mask: UInt8)] = []
        if let previous {
            for byte in 1...9 where raw.indices.contains(byte) && previous.indices.contains(byte) {
                let fresh = raw[byte] & ~previous[byte]
                for bit in 0..<8 where (fresh & (1 << bit)) != 0 {
                    rising.append((byte: byte, mask: 1 << bit))
                }
            }
        }
        guard !events.isEmpty || !rising.isEmpty else { return }
        push(.surface(raw: raw, events: events, risingBits: rising))
    }

    private func ingestMIDI(_ packet: [UInt8]) {
        for start in stride(from: 0, to: packet.count - 3, by: 4) {
            let status = packet[start + 1]
            let d1 = packet[start + 2]
            let d2 = packet[start + 3]
            if status & 0xf0 == 0x90 || status & 0xf0 == 0x80 {
                let offset = Int(d1) - commandBaseNote
                if let key = Self.commandKeys.first(where: { $0.offset == offset }) {
                    if status & 0xf0 == 0x90, d2 > 0 {
                        push(.console(key.command))
                    }
                    continue
                }
            }
            if let text = Self.describeMIDI(status: status, d1: d1, d2: d2) {
                push(.midi(text))
            }
        }
    }

    private static func describeMIDI(status: UInt8, d1: UInt8, d2: UInt8) -> String? {
        let channel = (status & 0x0f) + 1
        switch status & 0xf0 {
            case 0x90 where d2 > 0:
                return "note on \(d1) vel \(d2) ch \(channel)"
            case 0x80, 0x90:
                return "note off \(d1) ch \(channel)"
            case 0xb0:
                return "cc \(d1) = \(d2) ch \(channel)"
            case 0xe0:
                return "pitch bend \((Int(d1) | (Int(d2) << 7)) - 8192) ch \(channel)"
            case 0xd0:
                return "aftertouch \(d1) ch \(channel)"
            default:
                return nil
        }
    }

    private func push(_ item: Item) {
        lock.lock()
        items.append(item)
        lock.unlock()
        semaphore.signal()
    }
}

final class SessionLog {
    private var lines: [String] = ["# MK2 calibration session — \(ISO8601DateFormatter().string(from: Date()))", ""]

    func add(_ line: String) {
        lines.append(line)
        print("  log: \(line)")
    }

    func section(_ title: String) {
        lines.append("")
        lines.append("## \(title)")
        lines.append("")
    }

    func writeFile() {
        let path = FileManager.default.currentDirectoryPath + "/mk2-calibration-session.md"
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let combined = existing.isEmpty ? "" : existing + "\n---\n\n"
        try? (combined + lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        print("session log written to \(path)")
    }
}

enum CalibrationFlows {
    private static let ledMapSize = KompleteKontrolMK2Protocol.buttonLEDMapSize

    // Decoder button names vs KKMK2ButtonLED case names that denote the same control.
    private static let nameAliases: [String: String] = [
        "mute": "m",
        "solo": "s",
        "scale": "scaleedit",
        "arp": "arpedit",
    ]

    private static func buttonName(in events: [KKMK2InputEvent]) -> String? {
        for event in events {
            if case let .button(name, pressed) = event, pressed {
                return name
            }
        }
        return nil
    }

    // MARK: Command keys on the light guide

    static func lightCommandKeys(link: DaemonLink) {
        var guide = [UInt8](repeating: 0, count: KompleteKontrolMK2Protocol.lightGuideKeyMapSize)
        for key in FlowInputQueue.commandKeys {
            guide[key.offset] = KompleteKontrolSSeriesMK2.paletteCode(for: key.color)
        }
        link.writeReport(KompleteKontrolMK2Protocol.lightGuideReportID, guide)
    }

    static func clearCommandKeys(link: DaemonLink) {
        link.writeReport(KompleteKontrolMK2Protocol.lightGuideReportID, [UInt8](repeating: 0, count: KompleteKontrolMK2Protocol.lightGuideKeyMapSize))
    }

    // MARK: LED <-> button binding

    static func ledBindingSweep(link: DaemonLink, inputs: FlowInputQueue, log: SessionLog) {
        log.section("LED to button binding sweep")
        print("""

        LED SWEEP: one LED lights bright white at a time. Press the button underneath it,
        or answer with the lit keys on the keybed (red = nothing lit, orange = lit but no
        button, blue = repeat, magenta = back, white = quit flow).
        Caveat: 4-D encoder pushes live in the byte-6 value byte — bind those with flow 4 instead.
        """)
        var bindings: [Int: (byte: Int, mask: UInt8, name: String?)] = [:]
        var index = 0
        sweep: while index < ledMapSize {
            var map = [UInt8](repeating: 0, count: ledMapSize)
            map[index] = KompleteKontrolSSeriesMK2.paletteCode(for: KKRGB(red: 0xff, green: 0xff, blue: 0xff))
            link.writeReport(KompleteKontrolMK2Protocol.buttonLEDReportID, map)
            let presumed = KKMK2ButtonLED(rawValue: index).map { " (\($0.protocolName)?)" } ?? ""
            link.showText("LED \(String(format: "%02d", index))", "PRESS ITS BUTTON", "OR RED KEY", "IF NOTHING LIT")
            print("LED index \(index)\(presumed): press its button …")
            inputs.drain()
            waiting: while true {
                guard let item = inputs.next() else {
                    print("  (still waiting — s to skip)")
                    continue
                }
                switch item {
                    case let .surface(_, events, rising):
                        guard let first = rising.first else { continue }
                        let name = buttonName(in: events)
                        bindings[index] = (byte: first.byte, mask: first.mask, name: name)
                        let enumName = KKMK2ButtonLED(rawValue: index)?.protocolName ?? "-"
                        let canonical = name.map { nameAliases[$0] ?? $0 }
                        let byte6Note = first.byte == 6 ? " BYTE6-VALUE (verify via 4-D flow)" : ""
                        let match = canonical == enumName ? "match" : "MISMATCH enum=\(enumName)"
                        log.add("LED \(index): byte \(first.byte) mask 0x\(DaemonLink.hex(first.mask)) decoder=\(name ?? "UNKNOWN") \(match)\(byte6Note)")
                        index += 1
                        break waiting
                    case let .console(command):
                        switch command {
                            case "n":
                                log.add("LED \(index): nothing lit")
                                index += 1
                                break waiting
                            case "s":
                                log.add("LED \(index): lit, but no pressable button")
                                index += 1
                                break waiting
                            case "r":
                                break waiting
                            case "b":
                                index = max(0, index - 1)
                                break waiting
                            case "q":
                                break sweep
                            default:
                                continue
                        }
                    case .midi:
                        continue
                }
            }
        }
        link.writeReport(KompleteKontrolMK2Protocol.buttonLEDReportID, [UInt8](repeating: 0, count: ledMapSize))
        verifyCycle(link: link, inputs: inputs, log: log, bindings: bindings)
    }

    /// Press any bound button to cycle its LED off -> white -> red -> green -> blue;
    /// the extra white step separates true RGB LEDs from single-colour ones.
    private static func verifyCycle(link: DaemonLink, inputs: FlowInputQueue, log: SessionLog, bindings: [Int: (byte: Int, mask: UInt8, name: String?)]) {
        guard !bindings.isEmpty else { return }
        log.section("RGB verify")
        let cycle: [(String, UInt8)] = [
            ("off", 0x00),
            ("white", KompleteKontrolSSeriesMK2.paletteCode(for: KKRGB(red: 0xff, green: 0xff, blue: 0xff))),
            ("red", KompleteKontrolSSeriesMK2.paletteCode(for: KKRGB(red: 0xff, green: 0x00, blue: 0x00))),
            ("green", KompleteKontrolSSeriesMK2.paletteCode(for: KKRGB(red: 0x00, green: 0xff, blue: 0x00))),
            ("blue", KompleteKontrolSSeriesMK2.paletteCode(for: KKRGB(red: 0x00, green: 0x00, blue: 0xff))),
        ]
        var map = [UInt8](repeating: 0, count: ledMapSize)
        var state = [Int: Int]()
        link.showText("VERIFY RGB", "PRESS BUTTONS", "WHITE KEY ENDS")
        print("\nVERIFY: press any bound button to cycle its LED (off/white/red/green/blue). White key = end.")
        inputs.drain()
        while true {
            guard let item = inputs.next() else { continue }
            switch item {
                case let .surface(_, _, rising):
                    for hit in rising {
                        guard let (index, _) = bindings.first(where: { $0.value.byte == hit.byte && $0.value.mask == hit.mask }) else { continue }
                        let step = ((state[index] ?? 0) + 1) % cycle.count
                        state[index] = step
                        map[index] = cycle[step].1
                        link.writeReport(KompleteKontrolMK2Protocol.buttonLEDReportID, map)
                        print("LED \(index) -> \(cycle[step].0) (code 0x\(DaemonLink.hex(cycle[step].1)))")
                    }
                case let .console(command):
                    if command == "q" {
                        link.writeReport(KompleteKontrolMK2Protocol.buttonLEDReportID, [UInt8](repeating: 0, count: ledMapSize))
                        return
                    }
                case .midi:
                    continue
            }
        }
    }

    // MARK: Encoder capture

    static func encoderCapture(link: DaemonLink, inputs: FlowInputQueue, log: SessionLog) {
        log.section("Encoder capture")
        print("""

        ENCODER CAPTURE: follow the on-device prompts. Green key = next step, white key = quit flow.
        """)
        for encoder in 1...8 {
            for direction in ["CW", "CCW"] {
                link.showText("ENCODER \(encoder)", "TURN \(direction) SLOW", "GREEN KEY", "WHEN DONE")
                print("Encoder \(encoder): turn \(direction) slowly, then hit the green key …")
                inputs.drain()
                var deltas: [Int] = []
                var values: [Int] = []
                var crosstalk = Set<Int>()
                collecting: while true {
                    guard let item = inputs.next() else { continue }
                    switch item {
                        case let .surface(_, events, _):
                            for event in events {
                                if case let .knob(index, delta, value) = event {
                                    if index == encoder {
                                        deltas.append(delta)
                                        values.append(value)
                                    } else {
                                        crosstalk.insert(index)
                                    }
                                }
                            }
                        case let .console(command):
                            if command == "q" { return }
                            break collecting
                        case .midi:
                            continue
                    }
                }
                guard !deltas.isEmpty else {
                    log.add("encoder \(encoder) \(direction): NO EVENTS")
                    continue
                }
                let positive = deltas.filter { $0 > 0 }.count
                let negative = deltas.filter { $0 < 0 }.count
                let sign = positive >= negative ? "+" : "-"
                let consistency = 100 * max(positive, negative) / deltas.count
                let crossNote = crosstalk.isEmpty ? "" : " CROSSTALK from \(crosstalk.sorted())"
                log.add("encoder \(encoder) \(direction): \(deltas.count) events sign \(sign) (\(consistency)% consistent) |delta| avg \(deltas.map { abs($0) }.reduce(0, +) / deltas.count) raw \(values.min() ?? 0)…\(values.max() ?? 0)\(crossNote)")
            }
        }
        link.showText("ENCODERS DONE", "")
    }

    // MARK: 4-D encoder / byte-6 characterization

    /// Byte 6 is a state/value byte (touch, directional push, click, shift), not a bitmask —
    /// rising-bit binding misattributes it. This flow records the full value sequence of
    /// bytes 6 and 30 per guided gesture instead.
    static func fourDCapture(link: DaemonLink, inputs: FlowInputQueue, log: SessionLog) {
        log.section("4-D encoder / byte-6 characterization")
        print("""

        4-D CAPTURE: perform exactly the gesture shown on the displays, then hit the green key.
        Try not to touch anything else. Green key = next step, white key = quit flow.
        """)
        let steps: [(String, String)] = [
            ("TOUCH 4D ONLY", "NO PRESS THEN LIFT"),
            ("CLICK 4D CENTER", "PRESS AND RELEASE"),
            ("PUSH 4D UP", "PRESS AND RELEASE"),
            ("PUSH 4D DOWN", "PRESS AND RELEASE"),
            ("PUSH 4D LEFT", "PRESS AND RELEASE"),
            ("PUSH 4D RIGHT", "PRESS AND RELEASE"),
            ("TURN 4D CW", "ONE DETENT"),
            ("TURN 4D CCW", "ONE DETENT"),
            ("HOLD SHIFT", "PRESS AND RELEASE"),
        ]
        for (title, detail) in steps {
            link.showText(title, detail, "GREEN KEY", "WHEN DONE")
            print("\(title) — \(detail), then green key …")
            inputs.drain()
            var byte6: [UInt8] = []
            var byte30: [UInt8] = []
            var otherRising: Set<String> = []
            collecting: while true {
                guard let item = inputs.next() else { continue }
                switch item {
                    case let .surface(raw, _, rising):
                        if raw.indices.contains(6), byte6.last != raw[6] {
                            byte6.append(raw[6])
                        }
                        if raw.indices.contains(30), byte30.last != raw[30] {
                            byte30.append(raw[30])
                        }
                        for hit in rising where hit.byte != 6 {
                            otherRising.insert("byte \(hit.byte) mask 0x\(DaemonLink.hex(hit.mask))")
                        }
                    case let .console(command):
                        if command == "q" { return }
                        break collecting
                    case .midi:
                        continue
                }
            }
            let sequence6 = byte6.map { "0x\(DaemonLink.hex($0))" }.joined(separator: " → ")
            let sequence30 = byte30.map { "0x\(DaemonLink.hex($0))" }.joined(separator: " → ")
            let stray = otherRising.isEmpty ? "" : " STRAY: \(otherRising.sorted().joined(separator: ", "))"
            log.add("\(title): byte6 [\(sequence6.isEmpty ? "unchanged" : sequence6)] byte30 [\(sequence30.isEmpty ? "unchanged" : sequence30)]\(stray)")
        }
        link.showText("4D CAPTURE", "DONE")
    }

    // MARK: Function-button backlights

    /// The eight touch-buttons above the displays are absent from the 0x80 map; qKontrol
    /// sets their backlights via 8 colour bytes at offset 192 of the 0xA1 template.
    /// Assignment bytes stay zero so the knob/button CC suppression is preserved.
    static func softButtonBacklightProbe(link: DaemonLink, inputs: FlowInputQueue, log: SessionLog) {
        log.section("Function-button backlights (0xA1 offset 192)")
        print("""

        BACKLIGHT PROBE: one backlight position lights at a time — press the button that lit,
        or answer with the lit keys (red = nothing lit, orange = lit but unpressable, white = quit).
        """)
        func write(backlights: [UInt8]) {
            var payload = [UInt8](repeating: 0, count: 203)
            for (offset, value) in backlights.enumerated() where offset < 8 {
                payload[192 + offset] = value
            }
            link.writeReport(KompleteKontrolMK2Protocol.buttonKnobMapReportID, payload)
        }
        position: for position in 0..<8 {
            var backlights = [UInt8](repeating: 0, count: 8)
            backlights[position] = 0x1f
            write(backlights: backlights)
            link.showText("BACKLIGHT \(position)", "PRESS LIT BUTTON", "OR RED KEY", "IF NOTHING LIT")
            print("backlight position \(position): press the lit button …")
            inputs.drain()
            waiting: while true {
                guard let item = inputs.next() else { continue }
                switch item {
                    case let .surface(_, events, rising):
                        guard let first = rising.first else { continue }
                        let name = buttonName(in: events)
                        log.add("backlight \(position): byte \(first.byte) mask 0x\(DaemonLink.hex(first.mask)) decoder=\(name ?? "UNKNOWN")")
                        break waiting
                    case let .console(command):
                        switch command {
                            case "n":
                                log.add("backlight \(position): nothing lit")
                                break waiting
                            case "s":
                                log.add("backlight \(position): lit, but no pressable button")
                                break waiting
                            case "q":
                                break position
                            default:
                                continue
                        }
                    case .midi:
                        continue
                }
            }
        }
        for code: UInt8 in [0x01, 0x06, 0x0a, 0x10, 0x1e, 0x1f] {
            write(backlights: [UInt8](repeating: code, count: 8))
            link.showText("CODE 0x\(DaemonLink.hex(code))", "TYPE THE COLOUR", "GREEN KEY", "TO SKIP")
            print("all backlights set to 0x\(DaemonLink.hex(code)) — type the colour you see (green key = skip):")
            inputs.drain()
            while true {
                guard let item = inputs.next() else { continue }
                if case let .console(answer) = item {
                    if answer == "q" {
                        write(backlights: [UInt8](repeating: 0, count: 8))
                        return
                    }
                    log.add("backlight code 0x\(DaemonLink.hex(code)): \(answer.isEmpty ? "(skipped)" : answer)")
                    break
                }
            }
        }
        write(backlights: [UInt8](repeating: 0, count: 8))
        link.showText("BACKLIGHTS", "DONE")
    }

    // MARK: Live event monitor

    static func liveMonitor(link: DaemonLink, inputs: FlowInputQueue, log: SessionLog) {
        log.section("Live monitor notes")
        link.showText("LIVE MONITOR", "USE ANY CONTROL", "WHITE KEY ENDS")
        print("""

        LIVE MONITOR: every decoded event and raw change is printed. Anything you type
        (other than q) is recorded into the session log as an annotation. White key = end.
        """)
        inputs.drain()
        while true {
            guard let item = inputs.next(timeout: 3600) else { continue }
            switch item {
                case let .surface(raw, events, _):
                    for event in events {
                        if case let .rawChanged(indices) = event {
                            let bytes = indices.map { "[\($0)]=0x\(DaemonLink.hex(raw[$0]))" }.joined(separator: " ")
                            print("raw: \(bytes)")
                        } else {
                            print("event: \(event)")
                        }
                    }
                case let .console(command):
                    if command == "q" { return }
                    // single letters are command-key noise, not annotations
                    if command.count > 1 {
                        log.add("note: \(command)")
                    }
                case let .midi(text):
                    print("midi: \(text)")
            }
        }
    }
}
