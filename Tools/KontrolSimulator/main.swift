import AppKit
import KompleteKontrol

/// A standalone macOS app that impersonates the S61 MK2 panel so the daemon can be exercised
/// without hardware. It listens on the device wire socket; when `ccd` (in CCD_SIMULATE mode)
/// connects, display blits and LED reports render into the panel and clicking/scrolling the
/// controls sends semantic input back — the daemon and its clients cannot tell it from the
/// real device.
///
/// The panel is the document view of a magnifiable scroll view; the View menu drives zoom,
/// including a True Size mode that renders the displays at the real panels' physical size.
final class AppController: NSObject, NSApplicationDelegate {
    private let link = DeviceLink(socketPath: SimEndpoint.defaultSocketPath)
    private var window: NSWindow!
    private var scrollView: NSScrollView!
    private var panel: PanelView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Base layout renders the displays at native 480×272 points (magnification 1.0 =
        // "Actual Size"); all zoom is scroll-view magnification so clicks stay accurate.
        panel = PanelView(scale: 1.0)

        let initialSize = NSSize(width: 1040, height: 640)
        scrollView = NSScrollView(frame: NSRect(origin: .zero, size: initialSize))
        scrollView.documentView = panel
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.2
        scrollView.maxMagnification = 5.0
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.backgroundColor = NSColor(white: 0.07, alpha: 1)
        scrollView.drawsBackground = true

        window = NSWindow(contentRect: NSRect(origin: .zero, size: initialSize),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Komplete Kontrol S61 MK2 — Simulator"
        window.contentView = scrollView
        window.center()
        window.makeKeyAndOrderFront(nil)

        buildMenu()

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

        // Initial zoom: True Size if requested, otherwise fit the panel to the window width.
        if ProcessInfo.processInfo.environment["SIM_TRUE_SIZE"] != nil {
            trueSize(nil)
        } else {
            fitToWidth(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "KontrolSimulator")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About KontrolSimulator",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit KontrolSimulator",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        add(to: viewMenu, "Zoom In", #selector(zoomIn), "+")
        add(to: viewMenu, "Zoom Out", #selector(zoomOut), "-")
        add(to: viewMenu, "Actual Size", #selector(actualSize), "0")
        viewMenu.addItem(.separator())
        add(to: viewMenu, "Fit to Width", #selector(fitToWidth), "9")
        add(to: viewMenu, "True Size (95 mm)", #selector(trueSize), "t")

        NSApp.mainMenu = mainMenu
    }

    private func add(to menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
    }

    // MARK: - Zoom actions

    @objc private func zoomIn(_ sender: Any?) { setMagnification(scrollView.magnification * 1.2) }
    @objc private func zoomOut(_ sender: Any?) { setMagnification(scrollView.magnification / 1.2) }
    @objc private func actualSize(_ sender: Any?) { setMagnification(1.0) }

    @objc private func fitToWidth(_ sender: Any?) {
        guard panel.frame.width > 0 else { return }
        setMagnification(scrollView.frame.width / panel.frame.width)
    }

    @objc private func trueSize(_ sender: Any?) {
        guard let magnification = DisplayCalibration.trueSizeMagnification(screen: window.screen ?? NSScreen.main) else { return }
        setMagnification(magnification)
    }

    private func setMagnification(_ value: CGFloat) {
        let clamped = max(scrollView.minMagnification, min(scrollView.maxMagnification, value))
        scrollView.setMagnification(clamped, centeredAt: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
    }

    // MARK: - Daemon output

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

/// Computes the scroll-view magnification at which the 480-point-wide base display renders at
/// the real MK2 panel's physical width on the current monitor. Derived live from
/// `CGDisplayScreenSize` + `NSScreen.frame`, so it stays correct across resolutions/monitors.
enum DisplayCalibration {
    static let panelWidthMM: CGFloat = 95      // measured active area of one MK2 panel
    static let baseDisplayPoints: CGFloat = 480 // display width at magnification 1.0

    static func trueSizeMagnification(screen: NSScreen?) -> CGFloat? {
        guard let screen else { return nil }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        let physicalMM = CGDisplayScreenSize(displayID)
        guard physicalMM.width > 0 else { return nil }
        let pointsPerMM = screen.frame.width / physicalMM.width
        return (panelWidthMM * pointsPerMM) / baseDisplayPoints
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let controller = AppController()
application.delegate = controller
application.run()
