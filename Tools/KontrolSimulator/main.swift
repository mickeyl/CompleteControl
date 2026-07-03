import AppKit
import KompleteKontrol

/// A standalone macOS app that impersonates the S61 MK2 panel so the daemon can be exercised
/// without hardware. It listens on the device wire socket; when `ccd` (in CCD_SIMULATE mode)
/// connects, display blits and LED reports render into the panel and clicking/scrolling the
/// controls sends semantic input back — the daemon and its clients cannot tell it from the
/// real device.
final class AppController: NSObject, NSApplicationDelegate {
    private let link = DeviceLink(socketPath: SimEndpoint.defaultSocketPath)
    private var window: NSWindow!
    private var panel: PanelView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let size = NSSize(width: 1072, height: 560)
        panel = PanelView(frame: NSRect(origin: .zero, size: size))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Komplete Kontrol S61 MK2 — Simulator"
        window.contentView = panel
        window.center()
        window.makeKeyAndOrderFront(nil)

        panel.onInput = { [weak self] frame in self?.link.send(frame) }
        link.onFrame = { [weak self] frame in self?.handle(frame) }
        link.onConnect = { [weak self] in self?.panel.setConnected(true) }
        link.onDisconnect = { [weak self] in
            self?.panel.clearAll()
            self?.panel.setConnected(false)
        }
        if !link.start() {
            NSLog("KontrolSimulator: failed to bind \(SimEndpoint.defaultSocketPath)")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handle(_ frame: SimFrame) {
        switch frame.type {
            case .displayBlit:
                applyBlit(frame.payload)
            case .report:
                guard let reportID = frame.payload.first else { return }
                panel.applyReport(reportID: reportID, bytes: Array(frame.payload.dropFirst()))
            default:
                break
        }
    }

    private func applyBlit(_ payload: [UInt8]) {
        guard payload.count >= 9 else { return }
        let screen = Int(payload[0])
        let x = Int(payload[1]) << 8 | Int(payload[2])
        let y = Int(payload[3]) << 8 | Int(payload[4])
        let width = Int(payload[5]) << 8 | Int(payload[6])
        let height = Int(payload[7]) << 8 | Int(payload[8])
        panel.applyBlit(screen: screen, x: x, y: y, w: width, h: height, be: Array(payload.dropFirst(9)))
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let controller = AppController()
application.delegate = controller
application.run()
