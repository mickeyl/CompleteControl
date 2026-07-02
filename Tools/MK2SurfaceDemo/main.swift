import AppKit
import Foundation
import KompleteKontrol

@main
final class MK2SurfaceDemoApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let controller = MK2DemoController()

    static func main() {
        if CommandLine.arguments.contains("--smoke-hid") {
            MK2Smoke.run()
            return
        }
        let app = NSApplication.shared
        let delegate = MK2SurfaceDemoApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = MK2SurfaceView(controller: controller)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Komplete Kontrol MK2 Protocol Demo"
        window.minSize = NSSize(width: 980, height: 640)
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        controller.attach(view: view)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private enum MK2Smoke {
    static func run() {
        let device = KompleteKontrolSSeriesMK2(seizeHID: false)
        device.log = { message in
            print(message)
        }
        do {
            try device.open()
            print("mounted \(device.model?.name ?? "unknown MK2")")
            print(String(format: "init -> 0x%08x", device.handshake()))
            _ = device.setAllKeys(color: KKRGB(red: 0xff, green: 0x7f, blue: 0x00), flush: false)
            _ = device.setAllButtonLEDs(color: KKRGB(red: 0xff, green: 0xff, blue: 0xff), flush: false)
            print(String(format: "guide -> 0x%08x", device.sendGuide()))
            print(String(format: "buttons -> 0x%08x", device.sendButtonLEDs()))
            usleep(350_000)
            _ = device.setAllKeys(color: .off, flush: false)
            _ = device.setAllButtonLEDs(color: .off, flush: false)
            print(String(format: "guide clear -> 0x%08x", device.sendGuide()))
            print(String(format: "buttons clear -> 0x%08x", device.sendButtonLEDs()))
            device.close()
        } catch {
            fputs("MK2 HID smoke failed: \(error)\n", stderr)
            exit(1)
        }
    }
}

private final class MK2DemoController: @unchecked Sendable {
    private let device = KompleteKontrolSSeriesMK2(seizeHID: false)
    private weak var view: MK2SurfaceView?
    private var keyColors: [Int: KKRGB] = [:]
    private var buttonColors: [Int: KKRGB] = [:]
    private var displayColors: [Int: UInt16] = [:]
    private let palette: [KKRGB] = [
        .off,
        KKRGB(red: 0xff, green: 0x00, blue: 0x00),
        KKRGB(red: 0xff, green: 0x7f, blue: 0x00),
        KKRGB(red: 0xff, green: 0xff, blue: 0x00),
        KKRGB(red: 0x00, green: 0xff, blue: 0x00),
        KKRGB(red: 0x00, green: 0xff, blue: 0xff),
        KKRGB(red: 0x00, green: 0x00, blue: 0xff),
        KKRGB(red: 0xff, green: 0x00, blue: 0xff),
        KKRGB(red: 0xff, green: 0xff, blue: 0xff),
    ]
    private let displayPalette: [UInt16] = [
        0x0000,
        0xf800,
        0xfd20,
        0xffe0,
        0x07e0,
        0x07ff,
        0x001f,
        0xf81f,
        0xffff,
    ]

    var status = "Starting..."
    var modelLabel = "No MK2 mounted"
    var lastInput = "No input yet"
    var rawBytes: [UInt8] = []
    var knobValues = [Int](repeating: 0, count: 8)
    var knobDeltas = [Int](repeating: 0, count: 8)
    var jogValue = 0
    var keyCount: Int { device.model?.keyCount ?? 61 }

    func attach(view: MK2SurfaceView) {
        self.view = view
        device.log = { [weak self] message in
            DispatchQueue.main.async {
                self?.status = message
                self?.view?.needsDisplay = true
            }
        }
        device.onInputReport = { [weak self] report in
            DispatchQueue.main.async {
                self?.handle(report: report)
            }
        }
        device.startInputMonitoring()
        do {
            try device.open()
            modelLabel = device.model?.name ?? "MK2 mounted"
            status = "HID mounted, sending init"
            _ = device.handshake()
            runStartupPattern()
        } catch {
            status = "Open failed: \(error)"
        }
        view.needsDisplay = true
    }

    func keyColor(_ index: Int) -> KKRGB {
        keyColors[index] ?? .off
    }

    func buttonColor(_ index: Int) -> KKRGB {
        buttonColors[index] ?? .off
    }

    func displayColor(_ index: Int) -> UInt16 {
        displayColors[index] ?? 0x0000
    }

    func toggleKey(_ index: Int) {
        guard index < keyCount else { return }
        let next = nextPaletteColor(after: keyColors[index] ?? .off)
        keyColors[index] = next
        _ = device.setKey(index, color: next, flush: false)
        _ = device.sendGuide()
        status = "Light guide key \(index) -> \(colorName(next))"
        view?.pulse("key:\(index)")
        view?.needsDisplay = true
    }

    func toggleButton(_ index: Int) {
        guard let led = KKMK2ButtonLED(rawValue: index) else { return }
        let next = nextPaletteColor(after: buttonColors[index] ?? .off)
        buttonColors[index] = next
        _ = device.setButtonLED(led, color: next, flush: false)
        _ = device.sendButtonLEDs()
        status = "Button LED \(index) \(led.protocolName) -> \(colorName(next))"
        view?.pulse("button:\(led.protocolName)")
        view?.needsDisplay = true
    }

    func fillDisplay(_ index: Int) {
        guard (0...1).contains(index) else { return }
        let current = displayColors[index] ?? 0x0000
        let currentIndex = displayPalette.firstIndex(of: current) ?? 0
        let next = displayPalette[(currentIndex + 1) % displayPalette.count]
        displayColors[index] = next
        status = "Display \(index) bulk fill queued"
        view?.needsDisplay = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.device.fillDisplay(screen: index, color565: next)
            DispatchQueue.main.async {
                self.status = result.succeeded ? "Display \(index) fill ok" : "Display \(index) fill failed: \(result.message)"
                self.view?.pulse("display:\(index)")
                self.view?.needsDisplay = true
            }
        }
    }

    func clearAll() {
        keyColors.removeAll()
        buttonColors.removeAll()
        displayColors.removeAll()
        _ = device.setAllKeys(color: .off, flush: false)
        _ = device.setAllButtonLEDs(color: .off, flush: false)
        _ = device.sendGuide()
        _ = device.sendButtonLEDs()
        for screen in 0...1 {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                _ = self?.device.fillDisplay(screen: screen, color565: 0x0000)
            }
        }
        status = "Cleared HID lights and displays"
        view?.needsDisplay = true
    }

    private func runStartupPattern() {
        let modelKeys = device.model?.keyCount ?? 0
        for index in 0..<modelKeys {
            let color = palette[(index % (palette.count - 1)) + 1]
            keyColors[index] = color
            _ = device.setKey(index, color: color, flush: false)
        }
        for led in KKMK2ButtonLED.allCases where led.rawValue < KompleteKontrolMK2Protocol.buttonLEDMapSize {
            let color = led.rawValue % 3 == 0 ? KKRGB(red: 0xff, green: 0x7f, blue: 0x00) : KKRGB(red: 0xff, green: 0xff, blue: 0xff)
            buttonColors[led.rawValue] = color
            _ = device.setButtonLED(led, color: color, flush: false)
        }
        _ = device.sendGuide()
        _ = device.sendButtonLEDs()
        fillDisplay(0)
        fillDisplay(1)
        status = "Startup pattern sent"
    }

    private func handle(report: KKMK2InputReport) {
        rawBytes = report.bytes
        if report.events.isEmpty {
            lastInput = KKMK2InputReportDecoder.summary(report.bytes)
        } else {
            lastInput = report.events.map(\.description).joined(separator: " | ")
        }
        for event in report.events {
            switch event {
                case let .button(name, pressed):
                    view?.setActive("button:\(name)", active: pressed)
                case let .jog(direction):
                    view?.pulse("jog:\(direction)")
                case let .jogTouch(touched):
                    view?.setActive("jog:touch", active: touched)
                case .strip:
                    view?.pulse("strip")
                case let .jogScroll(_, value):
                    jogValue = value
                    view?.pulse("jog:scroll")
                case let .knob(index, delta, value):
                    if knobValues.indices.contains(index - 1) {
                        knobValues[index - 1] = value
                        knobDeltas[index - 1] = delta
                    }
                    view?.pulse("knob:\(index)")
                case let .touchEncoder(index, touched):
                    view?.setActive("knobtouch:\(index)", active: touched)
                case .touchStrip:
                    view?.pulse("strip")
                case .rawChanged:
                    break
            }
        }
        view?.needsDisplay = true
    }

    private func nextPaletteColor(after current: KKRGB) -> KKRGB {
        let index = palette.firstIndex(of: current) ?? 0
        return palette[(index + 1) % palette.count]
    }

    private func colorName(_ color: KKRGB) -> String {
        switch color {
            case .off: "off"
            case KKRGB(red: 0xff, green: 0x00, blue: 0x00): "red"
            case KKRGB(red: 0xff, green: 0x7f, blue: 0x00): "orange"
            case KKRGB(red: 0xff, green: 0xff, blue: 0x00): "yellow"
            case KKRGB(red: 0x00, green: 0xff, blue: 0x00): "green"
            case KKRGB(red: 0x00, green: 0xff, blue: 0xff): "cyan"
            case KKRGB(red: 0x00, green: 0x00, blue: 0xff): "blue"
            case KKRGB(red: 0xff, green: 0x00, blue: 0xff): "magenta"
            default: "white"
        }
    }
}

private final class MK2SurfaceView: NSView {
    private let controller: MK2DemoController
    private var pulses: [String: Date] = [:]
    private var active: Set<String> = []

    init(controller: MK2DemoController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    func pulse(_ id: String) {
        pulses[id] = Date()
        needsDisplay = true
    }

    func setActive(_ id: String, active: Bool) {
        if active {
            self.active.insert(id)
        } else {
            self.active.remove(id)
        }
        pulse(id)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if clearRect.contains(point) {
            controller.clearAll()
            return
        }
        for index in 0..<2 where displayRect(index).contains(point) {
            controller.fillDisplay(index)
            return
        }
        for index in 0..<controller.keyCount where keyRect(index).contains(point) {
            controller.toggleKey(index)
            return
        }
        for led in KKMK2ButtonLED.allCases where buttonRect(led.rawValue).contains(point) {
            controller.toggleButton(led.rawValue)
            return
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.075, alpha: 1).setFill()
        dirtyRect.fill()
        drawHeader()
        drawDisplays()
        drawEncoders()
        drawButtonGrid()
        drawKeybed()
        drawRawReport()
        drawFooter()
    }

    private func drawHeader() {
        drawString("Komplete Kontrol MK2 Protocol Demo", in: NSRect(x: 22, y: bounds.height - 42, width: 440, height: 24), size: 18, weight: .semibold, color: .white)
        drawString(controller.modelLabel, in: NSRect(x: 22, y: bounds.height - 68, width: 440, height: 20), size: 13, color: .secondaryLabelColor)
        drawButtonShell(clearRect, label: "Clear", color: .systemRed, active: false)
    }

    private func drawDisplays() {
        for index in 0..<2 {
            let rect = displayRect(index)
            let color = nsColor(rgb565: controller.displayColor(index))
            color.withAlphaComponent(0.82).setFill()
            rounded(rect, radius: 7).fill()
            (isFresh("display:\(index)") ? NSColor.systemCyan : NSColor.white.withAlphaComponent(0.32)).setStroke()
            rounded(rect, radius: 7).stroke()
            drawString("SCREEN \(index) 480x272 RGB565 BULK", in: rect.insetBy(dx: 12, dy: 10), size: 13, weight: .medium, color: color.isDark ? .white : .black)
        }
    }

    private func drawEncoders() {
        for index in 0..<8 {
            let rect = knobRect(index)
            let fresh = isFresh("knob:\(index + 1)")
            let touched = active.contains("knobtouch:\(index + 1)")
            let fill = touched ? NSColor.systemYellow.withAlphaComponent(0.74) : (fresh ? NSColor.systemCyan.withAlphaComponent(0.70) : NSColor.white.withAlphaComponent(0.10))
            fill.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor.white.withAlphaComponent((fresh || touched) ? 0.9 : 0.28).setStroke()
            NSBezierPath(ovalIn: rect).stroke()
            drawString("\(index + 1)", in: rect.insetBy(dx: 0, dy: rect.height * 0.30), size: 13, alignment: .center, color: .white)
            let delta = controller.knobDeltas[index]
            let deltaText = delta == 0 ? "0" : String(format: "%+d", delta)
            drawString("\(deltaText)  \(controller.knobValues[index])", in: NSRect(x: rect.minX - 18, y: rect.minY - 22, width: rect.width + 36, height: 18), size: 10, alignment: .center, color: .secondaryLabelColor)
        }
        let jog = NSRect(x: bounds.width - 160, y: bounds.height - 240, width: 86, height: 86)
        (isFresh("jog:scroll") ? NSColor.systemCyan.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.10)).setFill()
        NSBezierPath(ovalIn: jog).fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        NSBezierPath(ovalIn: jog).stroke()
        drawString("JOG \(controller.jogValue)", in: jog.insetBy(dx: 4, dy: 32), size: 12, alignment: .center, color: .white)
    }

    private func drawButtonGrid() {
        drawString("Button LEDs / Input Bits", in: NSRect(x: 22, y: bounds.height - 290, width: 260, height: 20), size: 14, weight: .semibold, color: .white)
        for led in KKMK2ButtonLED.allCases {
            let rect = buttonRect(led.rawValue)
            let id = "button:\(led.protocolName)"
            let inputActive = active.contains(id) || isFresh(id)
            let fill = inputActive ? NSColor.systemCyan : nsColor(controller.buttonColor(led.rawValue))
            fill.withAlphaComponent(inputActive ? 0.78 : 0.50).setFill()
            rounded(rect, radius: 4).fill()
            NSColor.white.withAlphaComponent(inputActive ? 0.9 : 0.22).setStroke()
            rounded(rect, radius: 4).stroke()
            drawString("\(led.rawValue)", in: rect.insetBy(dx: 2, dy: 3), size: 9, alignment: .center, color: .white)
        }
    }

    private func drawKeybed() {
        let rect = keybedRect
        NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
        rounded(rect, radius: 6).fill()
        let count = max(1, controller.keyCount)
        let keyWidth = rect.width / CGFloat(count)
        for index in 0..<count {
            let key = NSRect(x: rect.minX + CGFloat(index) * keyWidth, y: rect.minY, width: max(3, keyWidth - 1), height: rect.height)
            let color = controller.keyColor(index)
            if color == .off {
                (index % 12 == 1 || index % 12 == 3 || index % 12 == 6 || index % 12 == 8 || index % 12 == 10 ? NSColor(calibratedWhite: 0.04, alpha: 1) : NSColor(calibratedWhite: 0.92, alpha: 1)).setFill()
            } else {
                nsColor(color).withAlphaComponent(0.88).setFill()
            }
            rounded(key, radius: 2).fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            rounded(key, radius: 2).stroke()
        }
        drawString("Light Guide \(count) keys", in: NSRect(x: rect.minX, y: rect.maxY + 8, width: rect.width, height: 18), size: 13, color: .white)
    }

    private func drawRawReport() {
        let rect = rawReportRect
        NSColor.black.withAlphaComponent(0.35).setFill()
        rounded(rect, radius: 6).fill()
        drawString("Raw Report 0x01", in: NSRect(x: rect.minX + 12, y: rect.maxY - 28, width: rect.width - 24, height: 18), size: 13, weight: .semibold, color: .white)
        let bytes = controller.rawBytes
        let columns = 17
        for index in 0..<min(bytes.count, 51) {
            let col = index % columns
            let row = index / columns
            let cell = NSRect(x: rect.minX + 12 + CGFloat(col) * 36, y: rect.maxY - 58 - CGFloat(row) * 28, width: 32, height: 22)
            NSColor.white.withAlphaComponent(bytes[index] == 0 ? 0.08 : 0.22).setFill()
            rounded(cell, radius: 3).fill()
            drawString(String(format: "%02x", bytes[index]), in: cell.insetBy(dx: 2, dy: 4), size: 10, alignment: .center, color: .white)
        }
    }

    private func drawFooter() {
        drawString("Status: \(controller.status)", in: NSRect(x: 22, y: 34, width: bounds.width - 44, height: 22), size: 13, color: .white)
        drawString("Input: \(controller.lastInput)", in: NSRect(x: 22, y: 12, width: bounds.width - 44, height: 20), size: 12, color: .secondaryLabelColor)
    }

    private var clearRect: NSRect {
        NSRect(x: bounds.width - 120, y: bounds.height - 48, width: 92, height: 30)
    }

    private var keybedRect: NSRect {
        NSRect(x: 22, y: 82, width: bounds.width - 44, height: 90)
    }

    private var rawReportRect: NSRect {
        NSRect(x: bounds.width - 660, y: 205, width: 638, height: 138)
    }

    private func displayRect(_ index: Int) -> NSRect {
        let width = min(470, (bounds.width - 72) / 2)
        return NSRect(x: 22 + CGFloat(index) * (width + 28), y: bounds.height - 206, width: width, height: width * 272 / 480)
    }

    private func knobRect(_ index: Int) -> NSRect {
        NSRect(x: 42 + CGFloat(index) * 72, y: bounds.height - 260, width: 46, height: 46)
    }

    private func buttonRect(_ index: Int) -> NSRect {
        let columns = 14
        let col = index % columns
        let row = index / columns
        return NSRect(x: 22 + CGFloat(col) * 44, y: bounds.height - 326 - CGFloat(row) * 34, width: 36, height: 25)
    }

    private func keyRect(_ index: Int) -> NSRect {
        let count = max(1, controller.keyCount)
        let width = keybedRect.width / CGFloat(count)
        return NSRect(x: keybedRect.minX + CGFloat(index) * width, y: keybedRect.minY, width: max(3, width - 1), height: keybedRect.height)
    }

    private func drawButtonShell(_ rect: NSRect, label: String, color: NSColor, active: Bool) {
        color.withAlphaComponent(active ? 0.42 : 0.22).setFill()
        rounded(rect, radius: 6).fill()
        color.withAlphaComponent(0.85).setStroke()
        rounded(rect, radius: 6).stroke()
        drawString(label, in: rect.insetBy(dx: 8, dy: 6), size: 13, alignment: .center, color: .white)
    }

    private func rounded(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    private func isFresh(_ id: String) -> Bool {
        guard let date = pulses[id] else { return false }
        let fresh = Date().timeIntervalSince(date) < 0.24
        if fresh {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
                self?.needsDisplay = true
            }
        }
        return fresh
    }

    private func nsColor(_ color: KKRGB) -> NSColor {
        NSColor(calibratedRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: 1)
    }

    private func nsColor(rgb565: UInt16) -> NSColor {
        let r = CGFloat((rgb565 >> 11) & 0x1f) / 31
        let g = CGFloat((rgb565 >> 5) & 0x3f) / 63
        let b = CGFloat(rgb565 & 0x1f) / 31
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }

    private func drawString(_ text: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, alignment: NSTextAlignment = .left, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        NSString(string: text).draw(in: rect, withAttributes: attributes)
    }
}

private extension NSColor {
    var isDark: Bool {
        guard let rgb = usingColorSpace(.deviceRGB) else { return true }
        return (rgb.redComponent * 0.299 + rgb.greenComponent * 0.587 + rgb.blueComponent * 0.114) < 0.5
    }
}
