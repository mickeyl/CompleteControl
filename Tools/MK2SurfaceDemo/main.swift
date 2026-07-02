import Foundation
import KompleteKontrol
import KontrolSurfaceKit2

@main
struct MK2SurfaceDemo {
    static func main() async {
        let surface = MK2Surface2(options: .init(tickHz: 24))
        let demo = MK2FeatureDemo(surface: surface)
        await surface.start()
        await demo.show(.overview)
        print("MK2SurfaceDemo running. Use the eight function buttons on the hardware. Ctrl-C quits.")
        // A console demo has nothing left to do without the surface; a real app would
        // show "surface taken over" instead and keep running.
        for await state in await surface.connectionStates {
            switch state {
                case .evicted:
                    print("evicted by another surface client — quitting")
                    exit(0)
                case let .retrying(reason):
                    print("surface connection: retrying (\(reason))")
                case let .connected(detail):
                    print("surface connection: connected (\(detail))")
                case .stopped:
                    print("surface connection: stopped")
            }
        }
    }
}

private enum Feature: Int, CaseIterable, Sendable {
    case overview
    case lightGuide
    case ribbon
    case encoders
    case fourD
    case midiKeys
    case buttons
    case display

    var title: String {
        switch self {
            case .overview: "OVERVIEW"
            case .lightGuide: "LIGHT GUIDE"
            case .ribbon: "RIBBON"
            case .encoders: "ENCODERS"
            case .fourD: "4D ENCODER"
            case .midiKeys: "MIDI KEYS"
            case .buttons: "RGB BUTTONS"
            case .display: "DISPLAY"
        }
    }

    var short: String {
        switch self {
            case .overview: "HOME"
            case .lightGuide: "LIGHT"
            case .ribbon: "RIB"
            case .encoders: "ENC"
            case .fourD: "4D"
            case .midiKeys: "MIDI"
            case .buttons: "BTN"
            case .display: "DISP"
        }
    }

    var functionLED: KKMK2ButtonLED {
        KKMK2ButtonLED(rawValue: KKMK2ButtonLED.function1.rawValue + rawValue)!
    }
}

private actor MK2FeatureDemo {
    private let surface: MK2Surface2
    private var feature: Feature = .overview
    private var hue = 28.0
    private var spreadValue = 7.0
    private var spread: Int { Int(spreadValue.rounded()) }
    private var ribbonModeAccumulator = 0.0
    private var encoderScaler = MK2EncoderScaler()
    private var ribbonPosition: Int?
    private var ribbonMode = 0
    private var encoderValues = [Int](repeating: 500, count: 8)
    private var encoderTouched: Set<Int> = []
    private var jogValue = 0
    private var jogLast = "CENTER"
    private var notes: [UInt8: UInt8] = [:]
    private var buttonColors: [KKMK2ButtonLED: KKRGB] = [:]
    private var displayMeter = 0.35
    private var homeSelection: Feature = .lightGuide
    private var lastEvent = "READY"

    init(surface: MK2Surface2) {
        self.surface = surface
    }

    func show(_ next: Feature) async {
        feature = next
        if next != .overview {
            homeSelection = next
        }
        await render()
    }

    private func render() async {
        await surface.present(scene())
    }

    private func scene() -> MK2SurfaceScene2 {
        var lamps = functionLamps()
        var bindings = MK2InputBindings2()
        bindFeatureKeys(&bindings)

        switch feature {
            case .overview:
                // Lit means bound: all four 4-D directions and the click act on the menu.
                lamps[.jogLeft] = .amber
                lamps[.jogRight] = .amber
                lamps[.jogUp] = .amber
                lamps[.jogDown] = .amber
                bindings.jogScroll = { delta, _ in Task { await self.moveHomeSelection(delta) } }
                bindings.jog = { direction in Task { await self.homeJog(direction) } }
                return MK2SurfaceScene2(
                    left: baseFrame(title: "SURFACEKIT2", lines: ["4D SELECT \(homeSelection.short)", "FUNCTION KEYS DIRECT"], stripStart: 0),
                    right: menuFrame(),
                    lamps: lamps,
                    keyColors: overviewKeys(),
                    bindings: bindings
                )

            case .lightGuide:
                lamps[.clear] = .red
                bindings.encoder[1] = { delta, _ in Task { await self.adjustHue(delta) } }
                bindings.encoder[2] = { delta, _ in Task { await self.adjustSpread(delta) } }
                bindings.onPress(.clear) { Task { await self.resetLightGuide() } }
                return MK2SurfaceScene2(
                    left: baseFrame(title: "LIGHT GUIDE LAB", lines: ["ENC1 HUE \(Int(hue))", "ENC2 SPREAD \(spread)"], stripStart: 0),
                    right: meterFrame(title: "KEY PALETTE", value: Double(spread) / 24, footer: lastEvent, stripStart: 4),
                    lamps: lamps,
                    keyColors: lightGuideKeys(),
                    bindings: bindings
                )

            case .ribbon:
                // The strip LEDs are the ribbon's feedback channel: they follow the finger
                // instead of being decoratively lit.
                if let position = ribbonPosition {
                    let litIndex = min(24, position * 25 / 1025)
                    for offset in 0...litIndex {
                        lamps[KKMK2ButtonLED(rawValue: KKMK2ButtonLED.strip1.rawValue + offset)!] = .blue
                    }
                }
                bindings.strip = { position, time in Task { await self.ribbon(position: position, time: time) } }
                bindings.encoder[1] = { delta, _ in Task { await self.changeRibbonMode(delta) } }
                return MK2SurfaceScene2(
                    left: baseFrame(title: "RIBBON LAB", lines: ["MODE \(ribbonModeName)", "TOUCH STRIP STREAM"], stripStart: 0),
                    right: meterFrame(title: "POSITION", value: Double(ribbonPosition ?? 0) / 1024, footer: lastEvent, stripStart: 4),
                    lamps: lamps,
                    keyColors: ribbonKeys(),
                    bindings: bindings
                )

            case .encoders:
                for index in 1...8 {
                    bindings.encoder[index] = { delta, value in Task { await self.encoder(index, delta: delta, value: value) } }
                    bindings.encoderTouch[index] = { touched in Task { await self.encoderTouch(index, touched: touched) } }
                }
                return MK2SurfaceScene2(
                    left: encoderFrame(0..<4),
                    right: encoderFrame(4..<8),
                    lamps: lamps,
                    keyColors: overviewKeys(),
                    bindings: bindings
                )

            case .fourD:
                lamps[.jogLeft] = .amber
                lamps[.jogRight] = .amber
                lamps[.jogUp] = .amber
                lamps[.jogDown] = .amber
                bindings.jog = { direction in Task { await self.jog(direction) } }
                bindings.jogScroll = { delta, value in Task { await self.jogScroll(delta: delta, value: value) } }
                bindings.jogTouch = { touched in Task { await self.jogTouch(touched) } }
                return MK2SurfaceScene2(
                    left: baseFrame(title: "4D ENCODER", lines: ["LAST \(jogLast)", "VALUE \(jogValue)"], stripStart: 0),
                    right: meterFrame(title: "SCROLL", value: Double(jogValue) / 15, footer: lastEvent, stripStart: 4),
                    lamps: lamps,
                    keyColors: overviewKeys(),
                    bindings: bindings
                )

            case .midiKeys:
                bindings.midi = { event in Task { await self.midi(event) } }
                return MK2SurfaceScene2(
                    left: baseFrame(title: "MIDI KEYS", lines: ["PLAY THE KEYBED", "\(notes.count) NOTES HELD"], stripStart: 0),
                    right: midiFrame(),
                    lamps: lamps,
                    keyColors: midiKeyColors(),
                    bindings: bindings
                )

            case .buttons:
                for led in KKMK2ButtonLED.allCases where led.rawValue < KKMK2ButtonLED.strip1.rawValue {
                    lamps[led] = buttonColors[led].map(MK2LampState2.on) ?? .pulse(KKRGB(red: 0x30, green: 0x90, blue: 0xff), period: 1.4)
                    bindings.onPress(led) { Task { await self.toggleButton(led) } }
                }
                return MK2SurfaceScene2(
                    left: baseFrame(title: "RGB BUTTONS", lines: ["PRESS LIT BUTTONS", "\(buttonColors.count) ASSIGNED"], stripStart: 0),
                    right: buttonFrame(),
                    lamps: lamps,
                    keyColors: overviewKeys(),
                    bindings: bindings
                )

            case .display:
                bindings.encoder[1] = { delta, _ in Task { await self.adjustDisplayMeter(delta) } }
                bindings.jogScroll = { delta, _ in Task { await self.nudgeDisplayMeter(detents: delta) } }
                return MK2SurfaceScene2(
                    left: displayLabFrame(screen: 0),
                    right: displayLabFrame(screen: 1),
                    lamps: lamps,
                    keyColors: overviewKeys(),
                    bindings: bindings
                )
        }
    }

    private func functionLamps() -> [KKMK2ButtonLED: MK2LampState2] {
        var lamps: [KKMK2ButtonLED: MK2LampState2] = [:]
        for item in Feature.allCases {
            lamps[item.functionLED] = item == feature ? .green : .white
        }
        return lamps
    }

    private func bindFeatureKeys(_ bindings: inout MK2InputBindings2) {
        for item in Feature.allCases {
            bindings.onPress(item.functionLED) {
                Task { await self.show(item) }
            }
        }
    }

    private func moveHomeSelection(_ delta: Int) async {
        let features = Feature.allCases
        guard let index = features.firstIndex(of: homeSelection) else { return }
        let nextIndex = (index + delta + features.count * 4) % features.count
        homeSelection = features[nextIndex]
        lastEvent = "SELECT \(homeSelection.short)"
        await render()
    }

    private func homeJog(_ direction: String) async {
        switch direction {
            case "press":
                await show(homeSelection)
            case "left":
                await moveHomeSelection(-1)
            case "right":
                await moveHomeSelection(1)
            case "up":
                await moveHomeSelection(-2)
            case "down":
                await moveHomeSelection(2)
            default:
                break
        }
    }

    private func adjustHue(_ delta: Int) async {
        // Slow full sweep = full colour circle; acceleration covers it quickly.
        let step = encoderScaler.step(encoder: 1, delta: delta, span: 360)
        hue = fmod(hue + step + 360, 360)
        lastEvent = "HUE \(Int(hue))"
        await render()
    }

    private func adjustSpread(_ delta: Int) async {
        let step = encoderScaler.step(encoder: 2, delta: delta, span: 23)
        spreadValue = max(1, min(24, spreadValue + step))
        lastEvent = "SPREAD \(spread)"
        await render()
    }

    private func resetLightGuide() async {
        hue = 28
        spreadValue = 7
        lastEvent = "LIGHT RESET"
        await render()
    }

    private func ribbon(position: Int?, time: Int) async {
        ribbonPosition = position
        lastEvent = position.map { "RIB \($0) T \(time)" } ?? "RIB RELEASE"
        await render()
    }

    private func changeRibbonMode(_ delta: Int) async {
        // Discrete steps out of a high-resolution stream: accumulate the scaled value
        // and only act on whole units (span 6 = six mode steps per slow full sweep).
        ribbonModeAccumulator += encoderScaler.step(encoder: 1, delta: delta, span: 6)
        let steps = Int(ribbonModeAccumulator)
        guard steps != 0 else { return }
        ribbonModeAccumulator -= Double(steps)
        ribbonMode = ((ribbonMode + steps) % 3 + 3) % 3
        lastEvent = "RIBBON \(ribbonModeName)"
        await render()
    }

    private func encoder(_ index: Int, delta: Int, value: Int) async {
        guard encoderValues.indices.contains(index - 1) else { return }
        encoderValues[index - 1] = value
        lastEvent = "ENC \(index) \(delta >= 0 ? "+" : "")\(delta)"
        await render()
    }

    private func encoderTouch(_ index: Int, touched: Bool) async {
        if touched {
            encoderTouched.insert(index)
        } else {
            encoderTouched.remove(index)
        }
        lastEvent = "TOUCH \(index) \(touched ? "ON" : "OFF")"
        await render()
    }

    private func jog(_ direction: String) async {
        jogLast = direction.uppercased()
        lastEvent = "JOG \(jogLast)"
        await render()
    }

    private func jogScroll(delta: Int, value: Int) async {
        jogValue = value
        lastEvent = "SCROLL \(delta >= 0 ? "+" : "")\(delta)"
        await render()
    }

    private func jogTouch(_ touched: Bool) async {
        lastEvent = touched ? "JOG TOUCH" : "JOG RELEASE"
        await render()
    }

    private func midi(_ event: KKMIDIEvent) async {
        switch event.kind {
            case .noteOn:
                notes[event.data1] = event.data2
                lastEvent = "NOTE \(event.data1) VEL \(event.data2)"
            case .noteOff:
                notes.removeValue(forKey: event.data1)
                lastEvent = "NOTE OFF \(event.data1)"
            case .controlChange:
                lastEvent = "CC \(event.data1) \(event.data2)"
            case .pitchBend:
                lastEvent = "BEND \(event.data1) \(event.data2)"
        }
        await render()
    }

    private func toggleButton(_ led: KKMK2ButtonLED) async {
        let next = nextColor(after: buttonColors[led] ?? .off)
        buttonColors[led] = next == .off ? nil : next
        lastEvent = "\(led.protocolName.uppercased()) \(colorName(next))"
        await render()
    }

    // 4-D detents are discrete clicks, not high-resolution counts — fixed step per detent.
    private func nudgeDisplayMeter(detents: Int) async {
        displayMeter = max(0, min(1, displayMeter + Double(detents) * 0.05))
        lastEvent = "METER \(Int(displayMeter * 100))"
        await render()
    }

    private func adjustDisplayMeter(_ delta: Int) async {
        displayMeter = max(0, min(1, displayMeter + encoderScaler.step(encoder: 1, delta: delta, span: 1)))
        lastEvent = "METER \(Int(displayMeter * 100))"
        await render()
    }

    private var ribbonModeName: String {
        ["CC11", "PITCH", "ABS"][ribbonMode]
    }

    private func baseFrame(title: String, lines: [String], stripStart: Int) -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: 0x0841)
        drawFunctionStrip(into: &frame, start: stripStart)
        frame.fill(MK2PixelRect(x: 0, y: 38, width: 480, height: 34), 0x01bf)
        frame.drawText(title, x: 16, y: 46, scale: 3, color: 0xffff, maxWidth: 448)
        for (index, line) in lines.prefix(3).enumerated() {
            frame.drawText(line, x: 22, y: 94 + index * 42, scale: 4, color: index == 0 ? 0xffe0 : 0xffff, maxWidth: 430)
        }
        return frame
    }

    private func menuFrame() -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: 0x0000)
        drawFunctionStrip(into: &frame, start: 4)
        for item in Feature.allCases {
            let row = item.rawValue / 2
            let column = item.rawValue % 2
            let rect = MK2PixelRect(x: 20 + column * 230, y: 50 + row * 50, width: 205, height: 36)
            let selected = item == homeSelection
            let current = item == feature
            frame.fill(rect, selected ? 0xffe0 : (current ? 0x07e0 : 0x2104))
            frame.stroke(rect, selected ? 0x0000 : 0xffff, width: 2)
            frame.drawText("\(item.rawValue + 1) \(item.short)", x: rect.x + 10, y: rect.y + 9, scale: 3, color: selected ? 0x0000 : 0xffff, maxWidth: rect.width - 18)
        }
        return frame
    }

    private func meterFrame(title: String, value: Double, footer: String, stripStart: Int) -> MK2PixelFrame {
        var frame = baseFrame(title: title, lines: [footer], stripStart: stripStart)
        frame.horizontalBar(MK2PixelRect(x: 30, y: 142, width: 420, height: 54), value: value, fill: 0x07ff, track: 0x2104)
        frame.stroke(MK2PixelRect(x: 30, y: 142, width: 420, height: 54), 0xffff, width: 2)
        return frame
    }

    private func encoderFrame(_ range: Range<Int>) -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: 0x0000)
        drawFunctionStrip(into: &frame, start: range.lowerBound >= 4 ? 4 : 0)
        frame.drawText("ENCODER LAB", x: 20, y: 46, scale: 4, color: 0xffff)
        for (slot, index) in range.enumerated() {
            let rect = MK2PixelRect(x: 28 + slot * 112, y: 104, width: 84, height: 104)
            frame.stroke(rect, encoderTouched.contains(index + 1) ? 0xffe0 : 0x07ff, width: 3)
            frame.horizontalBar(MK2PixelRect(x: rect.x + 12, y: rect.y + 72, width: 60, height: 18), value: Double(encoderValues[index]) / 999, fill: 0x07e0, track: 0x2104)
            frame.drawText("E\(index + 1)", x: rect.x + 14, y: rect.y + 12, scale: 4, color: 0xffff)
            frame.drawText("\(encoderValues[index])", x: rect.x + 8, y: rect.y + 48, scale: 2, color: 0xffe0)
        }
        return frame
    }

    private func midiFrame() -> MK2PixelFrame {
        var frame = baseFrame(title: "MIDI MONITOR", lines: [lastEvent], stripStart: 4)
        let sorted = notes.keys.sorted().prefix(8)
        for (index, note) in sorted.enumerated() {
            frame.drawText("\(note)", x: 34 + index * 52, y: 150, scale: 3, color: 0x07e0)
        }
        return frame
    }

    private func buttonFrame() -> MK2PixelFrame {
        var frame = baseFrame(title: "BUTTON LED MAP", lines: [lastEvent], stripStart: 4)
        var index = 0
        for led in KKMK2ButtonLED.allCases.prefix(36) {
            let x = 20 + (index % 6) * 74
            let y = 126 + (index / 6) * 22
            frame.drawText("\(led.rawValue)", x: x, y: y, scale: 2, color: buttonColors[led] == nil ? 0x8410 : 0xffff)
            index += 1
        }
        return frame
    }

    private func displayLabFrame(screen: Int) -> MK2PixelFrame {
        var frame = MK2PixelFrame(fill: screen == 0 ? 0x1008 : 0x0010)
        drawFunctionStrip(into: &frame, start: screen == 0 ? 0 : 4)
        let barY = screen == 0 ? 96 : 144
        frame.drawText("DISPLAY RECONCILER2", x: 18, y: 46, scale: 3, color: 0xffff)
        frame.drawText("ONE BLIT PER DIRTY SCREEN", x: 18, y: 78, scale: 2, color: 0xffe0)
        frame.horizontalBar(MK2PixelRect(x: 34, y: barY, width: 410, height: 52), value: displayMeter, fill: screen == 0 ? 0x07e0 : 0xf81f, track: 0x2104)
        frame.stroke(MK2PixelRect(x: 34, y: barY, width: 410, height: 52), 0xffff, width: 2)
        frame.drawText(lastEvent, x: 24, y: 212, scale: 2, color: 0xffff, maxWidth: 430)
        return frame
    }

    private func drawFunctionStrip(into frame: inout MK2PixelFrame, start: Int) {
        for item in Feature.allCases.dropFirst(start).prefix(4) {
            let screenSlot = item.rawValue - start
            let x = 8 + screenSlot * 118
            let y = 6
            let color: UInt16 = item == feature ? 0x07e0 : 0x39e7
            frame.fill(MK2PixelRect(x: x, y: y, width: 106, height: 24), color)
            frame.drawText(item.short, x: x + 8, y: y + 6, scale: 2, color: 0x0000, maxWidth: 94)
        }
    }

    private func overviewKeys() -> [Int: KKRGB] {
        var keys: [Int: KKRGB] = [:]
        for index in 0..<88 where index % 12 == 0 {
            keys[index] = KKRGB(red: 0x00, green: 0x80, blue: 0xff)
        }
        return keys
    }

    private func lightGuideKeys() -> [Int: KKRGB] {
        var keys: [Int: KKRGB] = [:]
        for index in 0..<88 {
            keys[index] = KKRGB.hsv(fmod(hue + Double(index * spread), 360), 0.9, 1.0)
        }
        return keys
    }

    private func ribbonKeys() -> [Int: KKRGB] {
        var keys: [Int: KKRGB] = [:]
        let lit = Int((Double(ribbonPosition ?? 0) / 1024.0) * 60.0)
        for index in 0...lit {
            keys[index] = KKRGB(red: 0xff, green: 0x7f, blue: 0x00)
        }
        return keys
    }

    private func midiKeyColors() -> [Int: KKRGB] {
        var keys: [Int: KKRGB] = [:]
        for (note, velocity) in notes {
            let index = Int(note) - 36
            keys[index] = KKRGB.hsv(Double(note % 12) * 30, 0.9, max(0.2, Double(velocity) / 127))
        }
        return keys
    }

    private func nextColor(after color: KKRGB) -> KKRGB {
        let palette: [KKRGB] = [
            .off,
            KKRGB(red: 0xff, green: 0x00, blue: 0x00),
            KKRGB(red: 0xff, green: 0x7f, blue: 0x00),
            KKRGB(red: 0xff, green: 0xff, blue: 0x00),
            KKRGB(red: 0x00, green: 0xff, blue: 0x00),
            KKRGB(red: 0x00, green: 0x7f, blue: 0xff),
            KKRGB(red: 0xff, green: 0x00, blue: 0xff),
            KKRGB(red: 0xff, green: 0xff, blue: 0xff),
        ]
        let index = palette.firstIndex(of: color) ?? 0
        return palette[(index + 1) % palette.count]
    }

    private func colorName(_ color: KKRGB) -> String {
        switch color {
            case .off: "OFF"
            case KKRGB(red: 0xff, green: 0x00, blue: 0x00): "RED"
            case KKRGB(red: 0xff, green: 0x7f, blue: 0x00): "ORANGE"
            case KKRGB(red: 0xff, green: 0xff, blue: 0x00): "YELLOW"
            case KKRGB(red: 0x00, green: 0xff, blue: 0x00): "GREEN"
            case KKRGB(red: 0x00, green: 0x7f, blue: 0xff): "BLUE"
            case KKRGB(red: 0xff, green: 0x00, blue: 0xff): "MAGENTA"
            default: "WHITE"
        }
    }
}
