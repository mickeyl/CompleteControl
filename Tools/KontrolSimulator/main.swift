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
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let baseWindowTitle = "Komplete Kontrol S61 MK2 — Simulator"
    private enum DefaultsKey {
        static let screenIndex = "KontrolSimulator.window.screenIndex"
        static let x = "KontrolSimulator.window.x"
        static let y = "KontrolSimulator.window.y"
        static let width = "KontrolSimulator.window.width"
        static let height = "KontrolSimulator.window.height"
        static let keybedSize = "KontrolSimulator.keybedSize"
    }

    private let link = DeviceLink(socketPath: SimEndpoint.defaultSocketPath)
    private var window: NSWindow!
    private var scrollView: NSScrollView!
    private var panel: PanelView!
    private var fitToWidthItem: NSMenuItem?
    private var keybedSizeItems: [PanelView.KeybedSize: NSMenuItem] = [:]
    private var zoomMode: ZoomMode = .manual
    private var isProgrammaticResize = false

    private enum ZoomMode {
        case manual
        case fitToWidth
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = SimulatorAppIcon.make()

        // Base layout renders the displays at native 480x272 points; all zoom is scroll-view
        // magnification so clicks stay accurate.
        panel = PanelView(scale: 1.0)
        if let savedSize = PanelView.KeybedSize(rawValue: UserDefaults.standard.integer(forKey: DefaultsKey.keybedSize)) {
            panel.setKeybedSize(savedSize)
        }

        let initialSize = NSSize(width: 1040, height: 640)
        scrollView = NSScrollView(frame: NSRect(origin: .zero, size: initialSize))
        scrollView.documentView = panel
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.2
        scrollView.maxMagnification = 5.0
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .legacy
        scrollView.backgroundColor = PanelView.deviceBackgroundColor
        scrollView.drawsBackground = true

        window = NSWindow(contentRect: NSRect(origin: .zero, size: initialSize),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = Self.baseWindowTitle
        window.delegate = self
        window.contentView = scrollView
        let restoredFrame = restoredWindowFrame()
        if let restoredFrame {
            window.setFrame(restoredFrame, display: false)
        } else {
            window.center()
        }
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

        // Initial zoom: True Size if requested, otherwise fit the panel to the current window
        // width. A restored frame keeps its persisted height instead of being refitted.
        if ProcessInfo.processInfo.environment["SIM_TRUE_SIZE"] != nil {
            trueSize(nil)
        } else {
            zoomMode = .fitToWidth
            updateFitToWidthMagnification()
            if restoredFrame == nil {
                resizeWindowToCurrentMagnification(preserveContentWidth: true)
            }
            updateViewMenuState()
        }
        persistWindowPlacement()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
        viewMenu.addItem(.separator())
        fitToWidthItem = add(to: viewMenu, "Fit to Width", #selector(fitToWidth), "9")
        add(to: viewMenu, "True Size (95 mm)", #selector(trueSize), "t")
        viewMenu.addItem(.separator())
        for size in PanelView.KeybedSize.allCases {
            let item = add(to: viewMenu, size.title, #selector(setKeybedSizeFromMenu(_:)), "")
            item.representedObject = size.rawValue
            keybedSizeItems[size] = item
        }

        NSApp.mainMenu = mainMenu
        updateViewMenuState()
    }

    @discardableResult
    private func add(to menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Zoom actions

    @objc private func zoomIn(_ sender: Any?) {
        setManualMagnification(scrollView.magnification * 1.2, resizeWindow: true)
    }

    @objc private func zoomOut(_ sender: Any?) {
        setManualMagnification(scrollView.magnification / 1.2, resizeWindow: true)
    }

    @objc private func fitToWidth(_ sender: Any?) {
        zoomMode = .fitToWidth
        updateFitToWidthMagnification()
        resizeWindowToCurrentMagnification(preserveContentWidth: true)
        updateViewMenuState()
    }

    @objc private func trueSize(_ sender: Any?) {
        guard let magnification = DisplayCalibration.trueSizeMagnification(screen: window.screen ?? NSScreen.main) else { return }
        setManualMagnification(magnification, resizeWindow: true)
    }

    @objc private func setKeybedSizeFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let size = PanelView.KeybedSize(rawValue: rawValue) else { return }
        panel.setKeybedSize(size)
        UserDefaults.standard.set(size.rawValue, forKey: DefaultsKey.keybedSize)
        if zoomMode == .fitToWidth {
            updateFitToWidthMagnification()
            resizeWindowToCurrentMagnification(preserveContentWidth: true)
        } else {
            resizeWindowToCurrentMagnification(preserveContentWidth: false)
        }
        updateViewMenuState()
        persistWindowPlacement()
    }

    private func setManualMagnification(_ value: CGFloat, resizeWindow: Bool) {
        zoomMode = .manual
        setMagnification(value)
        if resizeWindow {
            resizeWindowToCurrentMagnification(preserveContentWidth: false)
        }
        updateViewMenuState()
    }

    private func updateFitToWidthMagnification() {
        guard panel.frame.width > 0 else { return }
        setMagnification(scrollView.contentSize.width / panel.frame.width)
    }

    private func setMagnification(_ value: CGFloat) {
        let clamped = max(scrollView.minMagnification, min(scrollView.maxMagnification, value))
        scrollView.setMagnification(clamped, centeredAt: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        updateWindowTitle()
    }

    private func resizeWindowToCurrentMagnification(preserveContentWidth: Bool) {
        let magnification = scrollView.magnification
        var targetContentSize = NSSize(
            width: panel.frame.width * magnification,
            height: panel.frame.height * magnification
        )
        if preserveContentWidth {
            targetContentSize.width = scrollView.frame.width
        }

        if let maxContentSize = maxContentSizeForCurrentScreen() {
            targetContentSize.width = min(targetContentSize.width, maxContentSize.width)
            targetContentSize.height = min(targetContentSize.height, maxContentSize.height)
        }
        targetContentSize.width = max(360, targetContentSize.width)
        targetContentSize.height = max(240, targetContentSize.height)

        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContentSize)).size
        var newFrame = NSRect(
            x: window.frame.minX,
            y: window.frame.maxY - frameSize.height,
            width: frameSize.width,
            height: frameSize.height
        )
        if let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            if newFrame.maxX > visibleFrame.maxX {
                newFrame.origin.x = visibleFrame.maxX - newFrame.width
            }
            if newFrame.minX < visibleFrame.minX {
                newFrame.origin.x = visibleFrame.minX
            }
            if newFrame.minY < visibleFrame.minY {
                newFrame.origin.y = visibleFrame.minY
            }
            if newFrame.maxY > visibleFrame.maxY {
                newFrame.origin.y = visibleFrame.maxY - newFrame.height
            }
        }

        guard abs(newFrame.width - window.frame.width) > 0.5 || abs(newFrame.height - window.frame.height) > 0.5 else {
            return
        }

        isProgrammaticResize = true
        window.setFrame(newFrame, display: true, animate: false)
        persistWindowPlacement()
        DispatchQueue.main.async { [weak self] in
            self?.isProgrammaticResize = false
            if self?.zoomMode == .fitToWidth {
                self?.updateFitToWidthMagnification()
            }
        }
    }

    private func maxContentSizeForCurrentScreen() -> NSSize? {
        guard let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return nil }
        let framePadding: CGFloat = 48
        let maxFrameSize = NSSize(
            width: max(360, visibleFrame.width - framePadding),
            height: max(240, visibleFrame.height - framePadding)
        )
        let contentRect = window.contentRect(forFrameRect: NSRect(origin: .zero, size: maxFrameSize))
        return contentRect.size
    }

    private func updateViewMenuState() {
        fitToWidthItem?.state = zoomMode == .fitToWidth ? .on : .off
        for (size, item) in keybedSizeItems {
            item.state = panel.currentKeybedSize == size ? .on : .off
        }
        updateWindowTitle()
    }

    private func updateWindowTitle() {
        guard window != nil else { return }
        let percent: CGFloat
        if let trueSizeMagnification = DisplayCalibration.trueSizeMagnification(screen: window.screen ?? NSScreen.main),
           trueSizeMagnification > 0 {
            percent = scrollView.magnification / trueSizeMagnification * 100
        } else {
            percent = scrollView.magnification * 100
        }
        window.title = "\(Self.baseWindowTitle) \(panel.currentKeybedSize.title) (\(Int(percent.rounded()))%)"
    }

    // MARK: - Window placement

    private func restoredWindowFrame() -> NSRect? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: DefaultsKey.width) != nil,
              defaults.object(forKey: DefaultsKey.height) != nil else {
            return nil
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let storedIndex = defaults.object(forKey: DefaultsKey.screenIndex) as? Int ?? 0
        let screen = screens.indices.contains(storedIndex) ? screens[storedIndex] : (NSScreen.main ?? screens[0])
        let visibleFrame = screen.visibleFrame
        var frame = NSRect(
            x: visibleFrame.minX + defaults.double(forKey: DefaultsKey.x),
            y: visibleFrame.minY + defaults.double(forKey: DefaultsKey.y),
            width: defaults.double(forKey: DefaultsKey.width),
            height: defaults.double(forKey: DefaultsKey.height)
        )
        frame.size.width = max(360, min(frame.width, visibleFrame.width))
        frame.size.height = max(240, min(frame.height, visibleFrame.height))
        return clamped(frame, to: visibleFrame)
    }

    private func persistWindowPlacement() {
        guard let window, let screen = window.screen ?? screenContaining(window.frame) ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let frame = window.frame
        let defaults = UserDefaults.standard
        defaults.set(screenIndex(for: screen) ?? 0, forKey: DefaultsKey.screenIndex)
        defaults.set(frame.minX - visibleFrame.minX, forKey: DefaultsKey.x)
        defaults.set(frame.minY - visibleFrame.minY, forKey: DefaultsKey.y)
        defaults.set(frame.width, forKey: DefaultsKey.width)
        defaults.set(frame.height, forKey: DefaultsKey.height)
    }

    private func screenIndex(for screen: NSScreen) -> Int? {
        NSScreen.screens.firstIndex { $0 === screen }
    }

    private func screenContaining(_ frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        }
    }

    private func clamped(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        var result = frame
        if result.maxX > visibleFrame.maxX {
            result.origin.x = visibleFrame.maxX - result.width
        }
        if result.minX < visibleFrame.minX {
            result.origin.x = visibleFrame.minX
        }
        if result.minY < visibleFrame.minY {
            result.origin.y = visibleFrame.minY
        }
        if result.maxY > visibleFrame.maxY {
            result.origin.y = visibleFrame.maxY - result.height
        }
        return result
    }

    // MARK: - Window resize

    func windowDidResize(_ notification: Notification) {
        guard !isProgrammaticResize else {
            persistWindowPlacement()
            return
        }
        zoomMode = .fitToWidth
        updateFitToWidthMagnification()
        updateViewMenuState()
        persistWindowPlacement()
    }

    func windowDidMove(_ notification: Notification) {
        persistWindowPlacement()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if zoomMode == .fitToWidth {
            updateFitToWidthMagnification()
        } else {
            updateWindowTitle()
        }
        persistWindowPlacement()
    }

    func windowWillClose(_ notification: Notification) {
        persistWindowPlacement()
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

private extension NSRect {
    var area: CGFloat {
        guard width > 0, height > 0 else { return 0 }
        return width * height
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
