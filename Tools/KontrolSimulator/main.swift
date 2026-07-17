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
        static let stayOnTop = "KontrolSimulator.window.stayOnTop"
        static let cheatSheetVisible = "KontrolSimulator.cheatSheet.visible"
        static let daemonAutostart = "KontrolSimulator.daemon.autostart"
        static let daemonAutomationEnabled = "KontrolSimulator.daemon.automationEnabled"
        static let deviceFirmwareVersion = "KontrolSimulator.deviceIdentity.firmwareVersion"
        static let deviceNameOverride = "KontrolSimulator.deviceIdentity.nameOverride"
    }

    // No bench-verified S61 MK2 bcdDevice is on record — matches SimulatorDeviceSession's
    // own placeholder default so an untouched dialog shows what the daemon already reports.
    private static let defaultFirmwareVersion: UInt16 = 0x0100

    private let link = DeviceLink(socketPath: SimEndpoint.defaultSocketPath)
    private let displayPacketDecoder = MK2DisplayPacketDecoder()

    // Rudimentary control over a user-level simulator daemon: ccd in CCD_SIMULATE
    // mode touches no USB and binds a /tmp socket, so no sudo is involved. Clients
    // attach by exporting KK_DAEMON_SOCKET to the same path.
    static let simulatorDaemonSocketPath = KompleteKontrolLibUSBServer.simulatorDaemonSocketPath
    static let simulatorDaemonLogPath = "/tmp/kontrol-simulator-daemon.log"
    private var daemonProcess: Process?
    private var restartDaemonAfterTermination = false
    private var daemonConnected = false
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var daemonStartItem: NSMenuItem?
    private var daemonStopItem: NSMenuItem?
    private var daemonAutostartItem: NSMenuItem?
    private var daemonAutomationItem: NSMenuItem?
    private var window: NSWindow!
    private var scrollView: NSScrollView!
    private var panel: PanelView!
    private var fitToWidthItem: NSMenuItem?
    private var zoomInOnDisplayItem: NSMenuItem?
    private var stayOnTopItem: NSMenuItem?
    private var cheatSheetItem: NSMenuItem?
    private var cheatSheetWindow: NSWindow?
    private var keybedSizeItems: [PanelView.KeybedSize: NSMenuItem] = [:]
    private var zoomMode: ZoomMode = .manual
    private var displayZoomSnapshot: DisplayZoomSnapshot?
    private var isProgrammaticResize = false
    private var pendingScrollerVisibilityRefresh = false
    private var isRefreshingScrollerVisibility = false

    private enum ZoomMode {
        case manual
        case fitToWidth
    }

    private struct DisplayZoomSnapshot {
        let zoomMode: ZoomMode
        let magnification: CGFloat
        let visibleOrigin: NSPoint
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
        let simulatorScrollView = SimulatorScrollView(frame: NSRect(origin: .zero, size: initialSize))
        simulatorScrollView.onKeyDown = { [weak self] event in
            self?.panel.handleKeyDown(event) ?? false
        }
        simulatorScrollView.onKeyUp = { [weak self] event in
            self?.panel.handleKeyUp(event) ?? false
        }
        simulatorScrollView.onFlagsChanged = { [weak self] event in
            self?.panel.handleFlagsChanged(event) ?? false
        }
        scrollView = simulatorScrollView
        scrollView.documentView = panel
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.2
        scrollView.maxMagnification = 5.0
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.backgroundColor = PanelView.deviceBackgroundColor
        scrollView.drawsBackground = true
        (scrollView as? SimulatorScrollView)?.onViewportChanged = { [weak self] in
            self?.scheduleScrollerVisibilityRefresh()
        }
        (scrollView as? SimulatorScrollView)?.onMagnificationChanged = { [weak self] in
            self?.handleDirectMagnificationChange()
        }

        window = NSWindow(contentRect: NSRect(origin: .zero, size: initialSize),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = Self.baseWindowTitle
        window.delegate = self
        window.contentView = scrollView
        window.initialFirstResponder = scrollView
        let restoredFrame = restoredWindowFrame()
        if let restoredFrame {
            window.setFrame(restoredFrame, display: false)
        } else {
            window.center()
        }
        applyStayOnTop(UserDefaults.standard.bool(forKey: DefaultsKey.stayOnTop))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(scrollView)

        buildMenu()
        if UserDefaults.standard.bool(forKey: DefaultsKey.cheatSheetVisible) {
            showCheatSheet(persist: false)
        }

        panel.onInput = { [weak self] frame in self?.link.send(frame) }
        link.onFrame = { [weak self] frame in self?.handle(frame) }
        link.onConnect = { [weak self] in
            self?.daemonConnected = true
            self?.refreshDaemonStatusPresentation()
            self?.sendDeviceIdentity()
        }
        link.onDisconnect = { [weak self] in
            self?.panel.clearAll()
            self?.daemonConnected = false
            self?.refreshDaemonStatusPresentation()
        }
        if !link.start() {
            NSLog("KontrolSimulator: failed to bind \(SimEndpoint.defaultSocketPath)")
        }
        installTerminationSignalHandlers()
        autostartDaemonIfConfigured()

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
        refreshScrollerVisibility()
        persistWindowPlacement()
        NSApp.activate(ignoringOtherApps: true)

        // Headless acceptance snapshots (mirrors the WidgetLab snapshot mode): render the
        // panel to a PNG after a settle delay — long enough for a driver to connect and
        // paint — then exit. TCC-free because it renders the view, not the screen.
        if let snapshotPath = ProcessInfo.processInfo.environment["KONTROLSIM_SNAPSHOT_PATH"] {
            let delay = Double(ProcessInfo.processInfo.environment["KONTROLSIM_SNAPSHOT_DELAY"] ?? "") ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.writeSnapshot(to: snapshotPath)
                NSApp.terminate(nil)
            }
        }
    }

    private func writeSnapshot(to path: String) {
        let bounds = panel.bounds
        let scale = Double(ProcessInfo.processInfo.environment["KONTROLSIM_SNAPSHOT_SCALE"] ?? "") ?? 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale),
            pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            NSLog("KontrolSimulator: snapshot failed — no bitmap rep")
            return
        }
        rep.size = bounds.size
        panel.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            NSLog("KontrolSimulator: snapshot failed — no PNG data")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            NSLog("KontrolSimulator: snapshot → %@", path)
            NSLog("KontrolSimulator: snapshot panel=%@ displays=%@ workArea=%@ scale=%.2f",
                  NSStringFromRect(bounds),
                  NSStringFromRect(panel.displayBlockRect),
                  NSStringFromRect(panel.displayWorkAreaRect),
                  Double(rep.pixelsWide) / Double(max(1, bounds.width)))
        } catch {
            NSLog("KontrolSimulator: snapshot failed — %@", "\(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        restartDaemonAfterTermination = false
        daemonProcess?.terminate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "KompleteSimulator")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About KompleteSimulator",
                        action: #selector(showAboutPanel), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit KompleteSimulator",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let daemonItem = NSMenuItem()
        mainMenu.addItem(daemonItem)
        let daemonMenu = NSMenu(title: "Daemon")
        daemonMenu.autoenablesItems = false
        daemonItem.submenu = daemonMenu
        daemonStartItem = add(to: daemonMenu, "Start Simulator Daemon", #selector(startSimulatorDaemon), "d")
        daemonStopItem = add(to: daemonMenu, "Stop Simulator Daemon", #selector(stopSimulatorDaemon), "")
        daemonMenu.addItem(.separator())
        daemonAutostartItem = add(to: daemonMenu, "Autostart Daemon If Not Running", #selector(toggleDaemonAutostart), "")
        daemonMenu.addItem(.separator())
        daemonAutomationItem = add(to: daemonMenu, "Enable Test-Automation Socket", #selector(toggleDaemonAutomation), "")
        daemonMenu.addItem(.separator())
        add(to: daemonMenu, "Copy Client Environment", #selector(copyClientEnvironment), "")
        daemonMenu.addItem(.separator())
        add(to: daemonMenu, "Device Identity…", #selector(showDeviceIdentitySettings), "")

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        add(to: viewMenu, "Zoom In", #selector(zoomIn), "+")
        add(to: viewMenu, "Zoom Out", #selector(zoomOut), "-")
        viewMenu.addItem(.separator())
        fitToWidthItem = add(to: viewMenu, "Fit to Width", #selector(fitToWidth), "9")
        add(to: viewMenu, "True Size (95 mm)", #selector(trueSize), "t")
        zoomInOnDisplayItem = add(to: viewMenu, "Zoom In on Display", #selector(toggleZoomInOnDisplay), "z")
        viewMenu.addItem(.separator())
        stayOnTopItem = add(to: viewMenu, "Stay on Top", #selector(toggleStayOnTop), "")
        cheatSheetItem = add(to: viewMenu, "Keyboard Cheat Sheet", #selector(toggleCheatSheet), "")
        viewMenu.addItem(.separator())
        for size in PanelView.KeybedSize.allCases {
            let item = add(to: viewMenu, size.title, #selector(setKeybedSizeFromMenu(_:)), "")
            item.representedObject = size.rawValue
            keybedSizeItems[size] = item
        }

        NSApp.mainMenu = mainMenu
        updateViewMenuState()
        updateDaemonMenuState()
    }

    // MARK: - Simulator daemon control

    @objc private func startSimulatorDaemon() {
        guard daemonProcess == nil else { return }
        let ccdURL = Bundle.main.executableURL!
            .deletingLastPathComponent()
            .appendingPathComponent("ccd")
        guard FileManager.default.isExecutableFile(atPath: ccdURL.path) else {
            let alert = NSAlert()
            alert.messageText = "ccd is not built"
            alert.informativeText = "Expected the daemon next to the simulator at \(ccdURL.path). Run: swift build --product ccd"
            alert.runModal()
            return
        }

        FileManager.default.createFile(atPath: Self.simulatorDaemonLogPath, contents: nil)
        let log = FileHandle(forWritingAtPath: Self.simulatorDaemonLogPath)

        let process = Process()
        process.executableURL = ccdURL
        process.arguments = ["--kk-libusb-daemon", Self.simulatorDaemonSocketPath]
        var environment = ProcessInfo.processInfo.environment
        environment["CCD_SIMULATE"] = link.socketPath
        environment["LOGLEVEL"] = environment["LOGLEVEL"] ?? "INFO"
        if UserDefaults.standard.bool(forKey: DefaultsKey.daemonAutomationEnabled) {
            environment["CCD_ENABLE_AUTOMATION"] = "1"
        }
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.daemonProcess = nil
                let shouldRestart = self.restartDaemonAfterTermination
                    && UserDefaults.standard.bool(forKey: DefaultsKey.daemonAutostart)
                self.restartDaemonAfterTermination = false
                self.refreshDaemonStatusPresentation()
                if shouldRestart {
                    self.startSimulatorDaemon()
                }
            }
        }
        do {
            try process.run()
            daemonProcess = process
        } catch {
            NSLog("KontrolSimulator: failed to start daemon — %@", "\(error)")
        }
        refreshDaemonStatusPresentation()
    }

    @objc private func stopSimulatorDaemon() {
        restartDaemonAfterTermination = false
        daemonProcess?.terminate()
    }

    /// SIGTERM/SIGINT (kill, Ctrl-C from the launching terminal) bypass
    /// applicationWillTerminate and would orphan the child daemon — route them
    /// through a graceful terminate instead.
    private func installTerminationSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    @objc private func toggleDaemonAutostart() {
        let defaults = UserDefaults.standard
        let enabled = !defaults.bool(forKey: DefaultsKey.daemonAutostart)
        defaults.set(enabled, forKey: DefaultsKey.daemonAutostart)
        updateDaemonMenuState()
        // "If not running" applies right now, not just at the next launch.
        if enabled, !daemonConnected, daemonProcess == nil {
            startSimulatorDaemon()
        }
    }

    /// Autostart waits a grace period after launch: an already-running daemon
    /// (foreground `daemon-simulate`, or a child from a previous session) connects to
    /// the freshly bound simulator socket within moments, and then there is nothing
    /// to do. Skipped in snapshot mode so headless acceptance runs stay deterministic.
    private func autostartDaemonIfConfigured() {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.daemonAutostart),
              ProcessInfo.processInfo.environment["KONTROLSIM_SNAPSHOT_PATH"] == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.daemonConnected, self.daemonProcess == nil else { return }
            self.startSimulatorDaemon()
        }
    }

    /// The daemon only reads `CCD_ENABLE_AUTOMATION` at process start. Restart a daemon owned
    /// by the simulator immediately when autostart is enabled; an externally attached daemon
    /// keeps its current setting because its lifetime belongs to its launcher.
    @objc private func toggleDaemonAutomation() {
        let defaults = UserDefaults.standard
        let enabled = !defaults.bool(forKey: DefaultsKey.daemonAutomationEnabled)
        defaults.set(enabled, forKey: DefaultsKey.daemonAutomationEnabled)
        updateDaemonMenuState()
        if defaults.bool(forKey: DefaultsKey.daemonAutostart), daemonProcess != nil {
            restartDaemonAfterTermination = true
            daemonProcess?.terminate()
        } else if defaults.bool(forKey: DefaultsKey.daemonAutostart), !daemonConnected {
            startSimulatorDaemon()
        }
    }

    @objc private func copyClientEnvironment() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("KK_DAEMON_SOCKET=\(Self.simulatorDaemonSocketPath)", forType: .string)
    }

    /// Overrides what the connected daemon reports through `deviceInfo` (firmware version and
    /// display name) — lets a client's about panel be exercised without real hardware. The
    /// simulated product ID/key count stay the real S61 MK2's; only the identity strings a
    /// client reads are overridable.
    @objc private func showDeviceIdentitySettings() {
        let defaults = UserDefaults.standard
        let currentFirmwareVersion = defaults.object(forKey: DefaultsKey.deviceFirmwareVersion) != nil
            ? UInt16(defaults.integer(forKey: DefaultsKey.deviceFirmwareVersion))
            : Self.defaultFirmwareVersion

        let alert = NSAlert()
        alert.messageText = "Simulated Device Identity"
        alert.informativeText = "Overrides what the daemon reports to clients via deviceInfo. Leave the name empty to report the real model name."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        let firmwareLabel = NSTextField(labelWithString: "Firmware version:")
        firmwareLabel.frame = NSRect(x: 0, y: 32, width: 130, height: 18)
        container.addSubview(firmwareLabel)
        let firmwareField = NSTextField(frame: NSRect(x: 134, y: 30, width: 150, height: 22))
        firmwareField.placeholderString = "1.0.0"
        firmwareField.stringValue = KKDeviceInfo.formatBCDVersion(currentFirmwareVersion)
        container.addSubview(firmwareField)

        let nameLabel = NSTextField(labelWithString: "Reported name:")
        nameLabel.frame = NSRect(x: 0, y: 4, width: 130, height: 18)
        container.addSubview(nameLabel)
        let nameField = NSTextField(frame: NSRect(x: 134, y: 2, width: 150, height: 22))
        nameField.placeholderString = "(default)"
        nameField.stringValue = defaults.string(forKey: DefaultsKey.deviceNameOverride) ?? ""
        container.addSubview(nameField)

        alert.accessoryView = container
        alert.window.initialFirstResponder = firmwareField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let firmwareVersion = KKDeviceInfo.parseBCDVersion(firmwareField.stringValue) else {
            let error = NSAlert()
            error.messageText = "Invalid firmware version"
            error.informativeText = "Use major.minor.patch, e.g. 1.4.6 (minor and patch each 0–15)."
            error.runModal()
            return
        }

        defaults.set(Int(firmwareVersion), forKey: DefaultsKey.deviceFirmwareVersion)
        defaults.set(nameField.stringValue, forKey: DefaultsKey.deviceNameOverride)
        sendDeviceIdentity()
    }

    private func sendDeviceIdentity() {
        let defaults = UserDefaults.standard
        let firmwareVersion = defaults.object(forKey: DefaultsKey.deviceFirmwareVersion) != nil
            ? UInt16(defaults.integer(forKey: DefaultsKey.deviceFirmwareVersion))
            : Self.defaultFirmwareVersion
        let nameOverride = defaults.string(forKey: DefaultsKey.deviceNameOverride) ?? ""
        link.send(.identity(firmwareVersion: firmwareVersion, nameOverride: nameOverride))
    }

    private func refreshDaemonStatusPresentation() {
        if daemonConnected {
            panel.setDaemonStatus(.connected)
        } else if daemonProcess != nil {
            panel.setDaemonStatus(.starting)
        } else {
            panel.setDaemonStatus(.none)
        }
        updateWindowTitle()
        updateDaemonMenuState()
    }

    private func updateDaemonMenuState() {
        daemonStartItem?.isEnabled = daemonProcess == nil
        daemonStopItem?.isEnabled = daemonProcess != nil
        daemonAutostartItem?.state = UserDefaults.standard.bool(forKey: DefaultsKey.daemonAutostart) ? .on : .off
        daemonAutomationItem?.state = UserDefaults.standard.bool(forKey: DefaultsKey.daemonAutomationEnabled) ? .on : .off
        daemonStartItem?.title = daemonConnected && daemonProcess == nil
            ? "Start Simulator Daemon (external daemon attached)"
            : "Start Simulator Daemon"
    }

    @discardableResult
    private func add(to menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Zoom actions

    @objc private func zoomIn(_ sender: Any?) {
        displayZoomSnapshot = nil
        setManualMagnification(scrollView.magnification * 1.2, resizeWindow: true)
    }

    @objc private func zoomOut(_ sender: Any?) {
        displayZoomSnapshot = nil
        setManualMagnification(scrollView.magnification / 1.2, resizeWindow: true)
    }

    @objc private func fitToWidth(_ sender: Any?) {
        displayZoomSnapshot = nil
        zoomMode = .fitToWidth
        updateFitToWidthMagnification()
        resizeWindowToCurrentMagnification(preserveContentWidth: true)
        updateViewMenuState()
    }

    @objc private func trueSize(_ sender: Any?) {
        displayZoomSnapshot = nil
        guard let magnification = DisplayCalibration.trueSizeMagnification(screen: window.screen ?? NSScreen.main) else { return }
        if abs(scrollView.magnification - magnification) <= 0.005 {
            alignDisplaysInViewport()
            return
        }
        setManualMagnification(magnification, resizeWindow: true)
    }

    @objc private func toggleZoomInOnDisplay(_ sender: Any?) {
        if let snapshot = displayZoomSnapshot {
            displayZoomSnapshot = nil
            zoomMode = snapshot.zoomMode
            setMagnification(snapshot.magnification)
            scrollDocument(to: snapshot.visibleOrigin)
        } else {
            displayZoomSnapshot = DisplayZoomSnapshot(
                zoomMode: zoomMode,
                magnification: scrollView.magnification,
                visibleOrigin: scrollView.documentVisibleRect.origin
            )
            zoomMode = .manual
            zoomInOnDisplayWorkArea()
        }
        updateViewMenuState()
    }

    @objc private func toggleStayOnTop(_ sender: Any?) {
        let enabled = window.level != .floating
        applyStayOnTop(enabled)
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.stayOnTop)
        updateViewMenuState()
    }

    @objc private func showAboutPanel(_ sender: Any?) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineSpacing = 2
        let credits = NSAttributedString(
            string: """
            A virtual Komplete Kontrol S-Series MK2 surface for hardware-free development, daemon testing, and surface UI iteration.

            Part of CompleteControl.
            Copyright (c) 2026 Dr. Michael Lauer.
            Not affiliated with or endorsed by Native Instruments.
            """,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "KompleteSimulator",
            .applicationIcon: SimulatorAppIcon.make(),
            .version: "CompleteControl Simulator",
            .applicationVersion: "S-Series MK2",
            .credits: credits,
        ])
    }

    @objc private func toggleCheatSheet(_ sender: Any?) {
        if cheatSheetWindow?.isVisible == true {
            hideCheatSheet()
        } else {
            showCheatSheet(persist: true)
        }
    }

    @objc private func setKeybedSizeFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let size = PanelView.KeybedSize(rawValue: rawValue) else { return }
        displayZoomSnapshot = nil
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
        refreshScrollerVisibility()
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
        scheduleScrollerVisibilityRefresh()
    }

    private func alignDisplaysInViewport() {
        refreshScrollerVisibility()
        scrollView.layoutSubtreeIfNeeded()

        let displayBlock = panel.displayBlockRect
        let visibleSize = scrollView.documentVisibleRect.size
        let maxOriginX = max(0, panel.bounds.width - visibleSize.width)
        let maxOriginY = max(0, panel.bounds.height - visibleSize.height)
        let origin = NSPoint(
            x: min(max(0, displayBlock.midX - visibleSize.width / 2), maxOriginX),
            y: min(max(0, displayBlock.minY), maxOriginY)
        )
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func zoomInOnDisplayWorkArea() {
        let padding: CGFloat = 14
        let workArea = panel.displayWorkAreaRect.insetBy(dx: -padding, dy: -padding)
        guard workArea.width > 0, workArea.height > 0 else { return }

        refreshScrollerVisibility()
        scrollView.layoutSubtreeIfNeeded()
        let contentSize = scrollView.contentSize
        let target = min(contentSize.width / workArea.width, contentSize.height / workArea.height)
        setMagnification(target)
        scrollDocument(toCenterOn: workArea)
    }

    private func scrollDocument(toCenterOn rect: NSRect) {
        let visibleSize = NSSize(
            width: scrollView.contentSize.width / max(scrollView.magnification, 0.001),
            height: scrollView.contentSize.height / max(scrollView.magnification, 0.001)
        )
        scrollDocument(to: NSPoint(
            x: rect.midX - visibleSize.width / 2,
            y: rect.midY - visibleSize.height / 2
        ))
    }

    private func scrollDocument(to origin: NSPoint) {
        scrollView.layoutSubtreeIfNeeded()
        let visibleSize = NSSize(
            width: scrollView.contentSize.width / max(scrollView.magnification, 0.001),
            height: scrollView.contentSize.height / max(scrollView.magnification, 0.001)
        )
        let maxOriginX = max(0, panel.bounds.width - visibleSize.width)
        let maxOriginY = max(0, panel.bounds.height - visibleSize.height)
        let clampedOrigin = NSPoint(
            x: min(max(0, origin.x), maxOriginX),
            y: min(max(0, origin.y), maxOriginY)
        )
        scrollView.contentView.scroll(to: clampedOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
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
            self?.refreshScrollerVisibility()
        }
    }

    private func scheduleScrollerVisibilityRefresh() {
        guard !pendingScrollerVisibilityRefresh, !isRefreshingScrollerVisibility else { return }
        pendingScrollerVisibilityRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingScrollerVisibilityRefresh = false
            self.refreshScrollerVisibility()
        }
    }

    private func handleDirectMagnificationChange() {
        displayZoomSnapshot = nil
        zoomMode = .manual
        updateViewMenuState()
        scheduleScrollerVisibilityRefresh()
    }

    private func refreshScrollerVisibility() {
        guard scrollView != nil, panel != nil else { return }
        isRefreshingScrollerVisibility = true
        defer { isRefreshingScrollerVisibility = false }

        let documentSize = NSSize(
            width: panel.frame.width * scrollView.magnification,
            height: panel.frame.height * scrollView.magnification
        )
        var showsHorizontalScroller = scrollView.hasHorizontalScroller
        var showsVerticalScroller = scrollView.hasVerticalScroller

        for _ in 0..<3 {
            scrollView.hasHorizontalScroller = showsHorizontalScroller
            scrollView.hasVerticalScroller = showsVerticalScroller
            scrollView.layoutSubtreeIfNeeded()

            let contentSize = scrollView.contentSize
            let nextShowsHorizontalScroller = documentSize.width > contentSize.width + 0.5
            let nextShowsVerticalScroller = documentSize.height > contentSize.height + 0.5
            if nextShowsHorizontalScroller == showsHorizontalScroller,
               nextShowsVerticalScroller == showsVerticalScroller {
                break
            }
            showsHorizontalScroller = nextShowsHorizontalScroller
            showsVerticalScroller = nextShowsVerticalScroller
        }

        scrollView.hasHorizontalScroller = showsHorizontalScroller
        scrollView.hasVerticalScroller = showsVerticalScroller
        scrollView.reflectScrolledClipView(scrollView.contentView)
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
        zoomInOnDisplayItem?.state = displayZoomSnapshot == nil ? .off : .on
        stayOnTopItem?.state = window?.level == .floating ? .on : .off
        cheatSheetItem?.state = cheatSheetWindow?.isVisible == true ? .on : .off
        for (size, item) in keybedSizeItems {
            item.state = panel.currentKeybedSize == size ? .on : .off
        }
        updateWindowTitle()
    }

    private func applyStayOnTop(_ enabled: Bool) {
        window.level = enabled ? .floating : .normal
        cheatSheetWindow?.level = enabled ? .floating : .normal
    }

    private func showCheatSheet(persist: Bool) {
        let sheet = cheatSheetWindow ?? makeCheatSheetWindow()
        cheatSheetWindow = sheet
        sheet.level = window.level == .floating ? .floating : .normal
        sheet.orderFront(nil)
        if persist {
            UserDefaults.standard.set(true, forKey: DefaultsKey.cheatSheetVisible)
        }
        updateViewMenuState()
    }

    private func hideCheatSheet() {
        cheatSheetWindow?.close()
    }

    private func makeCheatSheetWindow() -> NSWindow {
        let panel = NSPanel(
            contentRect: NSRect(x: window.frame.maxX + 16, y: window.frame.maxY - 420, width: 420, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Simulator Keyboard Cheat Sheet"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.setFrameAutosaveName("KontrolSimulator.KeyboardCheatSheet")

        let scrollView = NSScrollView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 420, height: 420))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.09, alpha: 1)

        let textView = NSTextView(frame: scrollView.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(white: 0.09, alpha: 1)
        textView.textColor = NSColor(white: 0.86, alpha: 1)
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.string = PanelView.keyboardCheatSheetText
        scrollView.documentView = textView
        panel.contentView = scrollView
        return panel
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
        let daemonState: String
        if daemonConnected {
            daemonState = "daemon connected"
        } else if daemonProcess != nil {
            daemonState = "starting daemon …"
        } else {
            daemonState = "no daemon"
        }
        window.title = "\(Self.baseWindowTitle) \(panel.currentKeybedSize.title) (\(Int(percent.rounded()))%) — \(daemonState)"
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
        guard notification.object as? NSWindow === window else { return }
        guard !isProgrammaticResize else {
            persistWindowPlacement()
            return
        }
        if displayZoomSnapshot != nil {
            zoomInOnDisplayWorkArea()
            updateViewMenuState()
            persistWindowPlacement()
            scheduleScrollerVisibilityRefresh()
            return
        }
        zoomMode = .fitToWidth
        updateFitToWidthMagnification()
        updateViewMenuState()
        persistWindowPlacement()
        scheduleScrollerVisibilityRefresh()
    }

    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        persistWindowPlacement()
        scheduleScrollerVisibilityRefresh()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        if zoomMode == .fitToWidth {
            updateFitToWidthMagnification()
        } else {
            updateWindowTitle()
        }
        persistWindowPlacement()
        scheduleScrollerVisibilityRefresh()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        if closingWindow === cheatSheetWindow {
            UserDefaults.standard.set(false, forKey: DefaultsKey.cheatSheetVisible)
            updateViewMenuState()
            return
        }
        guard closingWindow === window else { return }
        panel.releaseKeyboardInputs()
        persistWindowPlacement()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        panel.releaseKeyboardInputs()
    }

    // MARK: - Daemon output

    private func handle(_ frame: SimFrame) {
        switch frame.type {
            case .displayBlit:
                applyBlit(frame.payload)
            case .displayPacket:
                do {
                    let blit = try displayPacketDecoder.decodeAndApply(frame.payload)
                    panel.applyBlit(
                        screen: Int(blit.screen),
                        x: Int(blit.x),
                        y: Int(blit.y),
                        w: Int(blit.width),
                        h: Int(blit.height),
                        be: blit.pixelsBE
                    )
                } catch {
                    NSLog("KontrolSimulator: rejected MK2 display packet: %@", String(describing: error))
                }
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
        let pixels = Array(payload.dropFirst(9))
        panel.applyBlit(screen: screen, x: x, y: y, w: width, h: height, be: pixels)
        displayPacketDecoder.record(MK2DecodedDisplayBlit(
            screen: UInt8(clamping: screen),
            x: UInt16(clamping: x),
            y: UInt16(clamping: y),
            width: UInt16(clamping: width),
            height: UInt16(clamping: height),
            pixelsBE: pixels
        ))
    }
}

private final class SimulatorScrollView: NSScrollView {
    var onViewportChanged: (() -> Void)?
    var onMagnificationChanged: (() -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?
    var onKeyUp: ((NSEvent) -> Bool)?
    var onFlagsChanged: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        onViewportChanged?()
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        onMagnificationChanged?()
        onViewportChanged?()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            zoomWithScrollWheel(event)
            return
        }
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if onKeyUp?(event) == true { return }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if onFlagsChanged?(event) == true { return }
        super.flagsChanged(with: event)
    }

    private func zoomWithScrollWheel(_ event: NSEvent) {
        let raw = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        guard raw != 0 else { return }
        let normalized = event.hasPreciseScrollingDeltas ? raw / 14 : raw / 3
        let factor = pow(1.08, normalized)
        let next = max(minMagnification, min(maxMagnification, magnification * factor))
        guard abs(next - magnification) > 0.0001 else { return }
        let center = documentView?.convert(event.locationInWindow, from: nil)
            ?? NSPoint(x: documentVisibleRect.midX, y: documentVisibleRect.midY)
        setMagnification(next, centeredAt: center)
        onMagnificationChanged?()
        onViewportChanged?()
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
