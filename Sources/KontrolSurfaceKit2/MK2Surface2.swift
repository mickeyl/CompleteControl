import Foundation
import KompleteKontrol

public enum MK2SurfaceConnection2: Sendable, Equatable {
    case stopped
    case connected(String)
    case retrying(String)
    /// Another client took over the surface. The kit tears down and stays down —
    /// auto-reconnecting here would make two instances fight over the hardware.
    case evicted
}

/// Bounds the number of in-flight tick tasks to one. Without it a tick that runs longer
/// than the timer interval (synchronous socket round-trips + frame diffing) makes the
/// timer enqueue actor tasks faster than they drain — input events then queue behind an
/// ever-growing backlog and surface latency climbs into seconds.
private final class TickGate: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func end() {
        lock.lock()
        scheduled = false
        lock.unlock()
    }
}

public actor MK2Surface2 {
    public struct Options: Sendable {
        public var tickHz: Int
        public var displayTimeoutMs: UInt32
        public var buttonHoldDelay: TimeInterval

        public init(tickHz: Int = 30, displayTimeoutMs: UInt32 = 1_000, buttonHoldDelay: TimeInterval = 1.0) {
            self.tickHz = tickHz
            self.displayTimeoutMs = displayTimeoutMs
            self.buttonHoldDelay = buttonHoldDelay
        }
    }

    private let options: Options
    private var scene = MK2SurfaceScene2()
    /// The connected device's identity, queried from the daemon at session
    /// setup. Nil while disconnected or against a daemon predating deviceInfo.
    public private(set) var deviceModel: KompleteKontrolDeviceModel?
    private var displayReconciler = PixelDisplayReconciler2()
    private var timer: DispatchSourceTimer?
    private var running = false
    private var lastTick = DispatchTime.now().uptimeNanoseconds
    private var lampPhase: [KKMK2ButtonLED: Double] = [:]
    /// Dynamic lamps that change independently of the rendered scene, such as
    /// realtime meters. Empty restores the scene-owned lamp state immediately.
    private var lampOverlay: [KKMK2ButtonLED: MK2LampState2] = [:]
    private var lastLampBytes = [UInt8](repeating: 0xff, count: KompleteKontrolMK2Protocol.buttonLEDMapSize)
    private var lastKeyColors: [KKRGB] = []
    private var controlClient: KompleteKontrolDaemonBinaryClient?
    private var eventClient: KompleteKontrolDaemonBinaryClient?
    private var displayClient: KompleteKontrolDaemonBinaryClient?
    private var daemonThread: Thread?
    private var previousSurfaceReport: [UInt8]?
    private var connectionState: MK2SurfaceConnection2 = .stopped
    private let connectionStream: AsyncStream<MK2SurfaceConnection2>
    private var connectionContinuation: AsyncStream<MK2SurfaceConnection2>.Continuation?
    // Idle-only health checks: real daemon traffic moves this timestamp forward,
    // so playback, scrolling, and display updates suppress synthetic heartbeats.
    private var lastDaemonCommunicationNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var lastDaemonHeartbeatNanos: UInt64 = 0
    private var lastDaemonStartAttemptNanos: UInt64 = 0
    private var activeDaemonSocketPath: String?
    private var preferredDaemonSocketPath: String?
    private var lastFailedDaemonSocketPath: String?
    private let tickGate = TickGate()
    private var eventTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<KKDaemonBinaryFrame>.Continuation?
    private static let doubleTouchWindowNanos: UInt64 = 350_000_000
    private static let daemonHeartbeatIdleNanos: UInt64 = 3_000_000_000
    private static let daemonReconnectIntervalNanos: UInt64 = 1_000_000_000
    private var lastEncoderTouchNanos = [UInt64](repeating: 0, count: 9)
    // Stamps one daemon-session attempt. Reader threads and their actor callbacks
    // carry the generation they were spawned for, so a cancelled thread's late
    // failure (or its deferred setup hop) can never tear down or hijack a newer
    // session — that stale-callback path was the reconnect-cascade bug.
    private var daemonSessionGeneration: UInt64 = 0
    private var pressedButtons: Set<KKMK2ButtonLED> = []
    // Touch selection state for the scene's encoder overlays. Physical state
    // like `pressedButtons`, so it survives scene re-presents: an app that
    // re-projects while a finger rests on an encoder must not lose the
    // highlight, and a latch keeps pointing at its slot across projections.
    private var touchedEncoders: Set<Int> = []
    private var latchedEncoder: Int?
    private var buttonPressResolutions: [KKMK2ButtonLED: ButtonResolution] = [:]
    private var buttonHoldTokens: [KKMK2ButtonLED: UInt64] = [:]
    private var buttonHoldTasks: [KKMK2ButtonLED: Task<Void, Never>] = [:]
    private var nextButtonHoldToken: UInt64 = 0
    public init(device: KompleteKontrolSSeriesMK2 = KompleteKontrolSSeriesMK2(seizeHID: false), options: Options = Options()) {
        _ = device
        self.options = options
        var continuation: AsyncStream<MK2SurfaceConnection2>.Continuation!
        connectionStream = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation = $0 }
        connectionContinuation = continuation
    }

    public var connectionStates: AsyncStream<MK2SurfaceConnection2> { connectionStream }

    public func start() {
        guard !running else { return }
        running = true
        startDaemonClient()
        startTimer()
    }

    public func stop() {
        guard running else { return }
        running = false
        timer?.cancel()
        timer = nil
        unregisterDaemonClient()
        daemonSessionGeneration &+= 1
        controlClient = nil
        eventClient = nil
        displayClient = nil
        deviceModel = nil
        daemonThread?.cancel()
        daemonThread = nil
        eventContinuation?.finish()
        eventContinuation = nil
        eventTask?.cancel()
        eventTask = nil
        previousSurfaceReport = nil
        lastDaemonCommunicationNanos = DispatchTime.now().uptimeNanoseconds
        lastDaemonHeartbeatNanos = 0
        lastDaemonStartAttemptNanos = 0
        cancelButtonHolds()
        touchedEncoders = []
        latchedEncoder = nil
        scene = MK2SurfaceScene2()
        lampOverlay = [:]
        displayReconciler.reset()
        publish(.stopped)
    }

    public func present(_ next: MK2SurfaceScene2) {
        scene = next
    }

    /// Updates high-frequency lamp feedback without rebuilding display frames or
    /// replacing scene bindings. Overlay lamps win over base and shift-layer lamps.
    public func presentLampOverlay(_ lamps: [KKMK2ButtonLED: MK2LampState2]) {
        lampOverlay = lamps
    }

    public func present(_ screen: MK2DoubleScreenDSL) {
        present(screen.scene())
    }

    public func present(
        left: MK2RegularScreenDSL,
        right: MK2RegularScreenDSL,
        renderer: FreeTypeTextRenderer? = nil,
        lamps: [KKMK2ButtonLED: MK2LampState2] = [:],
        keyColors: [Int: KKRGB] = [:],
        bindings: MK2InputBindings2 = MK2InputBindings2()
    ) {
        present(MK2DoubleScreenDSL(
            left: left.build(renderer: renderer),
            right: right.build(renderer: renderer),
            lamps: lamps,
            keyColors: keyColors,
            bindings: bindings
        ))
    }

    public func present(
        left: MK2FullScreenDSL,
        right: MK2FullScreenDSL,
        renderer: FreeTypeTextRenderer? = nil,
        lamps: [KKMK2ButtonLED: MK2LampState2] = [:],
        keyColors: [Int: KKRGB] = [:],
        bindings: MK2InputBindings2 = MK2InputBindings2()
    ) {
        present(MK2DoubleScreenDSL(
            left: left.build(renderer: renderer),
            right: right.build(renderer: renderer),
            lamps: lamps,
            keyColors: keyColors,
            bindings: bindings
        ))
    }

    private func startTimer() {
        let intervalNs = UInt64(1_000_000_000 / max(1, options.tickHz))
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(intervalNs)), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, self.tickGate.begin() else { return }
            Task {
                await self.tick(forceDisplay: false)
                self.tickGate.end()
            }
        }
        self.timer = timer
        lastTick = DispatchTime.now().uptimeNanoseconds
        timer.resume()
    }

    private func startDaemonClient() {
        guard daemonThread == nil else { return }
        lastDaemonStartAttemptNanos = DispatchTime.now().uptimeNanoseconds
        let socketPath = daemonSocketPathForNextAttempt()
        activeDaemonSocketPath = socketPath
        // Single ordered pipeline: the reader thread only yields into the stream and one
        // consumer task processes frames sequentially on the actor. One detached Task per
        // event would neither preserve ordering (encoder deltas!) nor bound the backlog.
        let (stream, continuation) = AsyncStream<KKDaemonBinaryFrame>.makeStream(bufferingPolicy: .unbounded)
        eventContinuation = continuation
        eventTask = Task { [weak self] in
            for await frame in stream {
                guard let self else { break }
                await self.process(frame)
            }
        }
        let generation = daemonSessionGeneration
        let thread = Thread { [weak self] in
            guard let eventClient = KompleteKontrolDaemonBinaryClient(channel: .event, socketPath: socketPath) else {
                continuation.finish()
                Task { await self?.handleDaemonFailure("daemon socket unavailable", generation: generation) }
                return
            }
            Task { await self?.setEventClient(eventClient, socketPath: socketPath, generation: generation) }
            while !Thread.current.isCancelled {
                switch eventClient.readEventResult(timeoutUsec: 20_000) {
                    case let .frame(frame):
                        Task { await self?.recordDaemonCommunication() }
                        continuation.yield(frame)
                    case .timeout:
                        continue
                    case .disconnected:
                        continuation.finish()
                        Task { await self?.handleDaemonFailure("daemon event socket disconnected", generation: generation) }
                        return
                }
            }
            continuation.finish()
        }
        thread.name = "MK2Surface2 daemon reader"
        daemonThread = thread
        thread.start()
    }

    private func daemonSocketPathForNextAttempt() -> String {
        let configured = KompleteKontrolLibUSBServer.defaultDaemonSocketPath
        let simulator = KompleteKontrolLibUSBServer.simulatorDaemonSocketPath
        if configured == simulator {
            return simulator
        }
        if preferredDaemonSocketPath == simulator {
            return simulator
        }
        if let preferredDaemonSocketPath,
           KompleteKontrolLibUSBServer.daemonSocketIsAvailable(socketPath: preferredDaemonSocketPath) {
            return preferredDaemonSocketPath
        }
        var candidates = [configured]
        if configured != simulator {
            candidates.append(simulator)
        }
        let available = candidates.filter {
            KompleteKontrolLibUSBServer.daemonSocketIsAvailable(socketPath: $0)
        }
        if let lastFailedDaemonSocketPath,
           available.count > 1,
           let alternate = available.first(where: { $0 != lastFailedDaemonSocketPath }) {
            return alternate
        }
        return KompleteKontrolLibUSBServer.clientDaemonSocketPath()
    }

    private func daemonKindDescription(socketPath: String) -> String {
        socketPath == KompleteKontrolLibUSBServer.simulatorDaemonSocketPath ? "simulator daemon" : "hardware daemon"
    }

    private func daemonConnectionDescription(socketPath: String?) -> String {
        guard let socketPath else { return "daemon socket unknown" }
        return "\(daemonKindDescription(socketPath: socketPath)) at \(socketPath)"
    }

    private func process(_ frame: KKDaemonBinaryFrame) {
        switch frame.type {
            case .input:
                handleSurfacePush(frame.payload)
            case .midi:
                for event in Self.parseMIDIPush(frame.payload) {
                    handle(midi: event)
                }
            case .device:
                let message = String(bytes: frame.payload, encoding: .utf8) ?? "device"
                if message == KKDaemonSessionPolicy.evictionNotice {
                    evict()
                } else if message.hasPrefix("device reconnected") {
                    // A session that registered before the device was plugged in (or
                    // survived an unplug) already ran its lamp/key/display writes once —
                    // those calls updated the "last sent" caches even though the daemon
                    // silently dropped them (no libusb session yet). Nothing here checks
                    // write status, so without a forced replay the surface would sit
                    // registered-but-blank forever: reconcile* only sends deltas, and the
                    // delta against a cache the hardware never actually received is empty.
                    replaySurfaceState()
                } else {
                    publish(.retrying(message))
                }
            default:
                break
        }
    }

    private func evict() {
        guard running else { return }
        // Teardown is the kit's job; deciding whether to quit is the app's (observe
        // connectionStates). The stderr notice guarantees eviction is never silent.
        fputs("MK2Surface2: surface taken over by another client — this session is evicted\n", stderr)
        running = false
        timer?.cancel()
        timer = nil
        daemonSessionGeneration &+= 1
        controlClient = nil
        eventClient = nil
        displayClient = nil
        daemonThread?.cancel()
        daemonThread = nil
        eventContinuation?.finish()
        eventContinuation = nil
        eventTask?.cancel()
        eventTask = nil
        previousSurfaceReport = nil
        displayReconciler.reset()
        publish(.evicted)
    }

    private func setEventClient(_ client: KompleteKontrolDaemonBinaryClient, socketPath: String, generation: UInt64) {
        guard running, generation == daemonSessionGeneration else { return }
        eventClient = client
        guard let control = KompleteKontrolDaemonBinaryClient(channel: .control, socketPath: socketPath),
              let display = KompleteKontrolDaemonBinaryClient(channel: .display, socketPath: socketPath) else {
            handleDaemonFailure("daemon binary sockets unavailable")
            return
        }
        controlClient = control
        displayClient = display
        guard KompleteKontrolLibUSBServer.isCurrentProtocolMessage(control.request(type: .version, timeoutUsec: 500_000)?.message) else {
            handleDaemonFailure("daemon protocol mismatch")
            return
        }
        let registration = KKDaemonBinaryCodec.registerPayload(pid: getpid(), name: ProcessInfo.processInfo.processName)
        guard control.request(type: .register, payload: registration, timeoutUsec: 750_000)?.status == 0,
              client.request(type: .register, payload: registration, timeoutUsec: 750_000)?.status == 0,
              display.request(type: .register, payload: registration, timeoutUsec: 750_000)?.status == 0 else {
            handleDaemonFailure("binary register failed")
            return
        }
        recordDaemonCommunication()
        // Best effort: an older daemon answers "unexpected type" (status != 0)
        // and the model stays unknown — clients keep their fallback mapping.
        if let info = control.request(type: .deviceInfo, timeoutUsec: 500_000), info.status == 0 {
            deviceModel = KompleteKontrolDeviceModel.parse(deviceInfoMessage: info.message)
        }
        guard configureHostControl() else {
            handleDaemonFailure("daemon host-control setup failed")
            return
        }
        tick(forceDisplay: true)
        preferredDaemonSocketPath = socketPath
        lastFailedDaemonSocketPath = nil
        publish(.connected("MK2 client registered with \(daemonConnectionDescription(socketPath: socketPath))"))
    }

    private func replaySurfaceState() {
        guard running else { return }
        lastLampBytes = [UInt8](repeating: 0xff, count: KompleteKontrolMK2Protocol.buttonLEDMapSize)
        lastKeyColors = []
        displayReconciler.reset()
        guard configureHostControl() else {
            handleDaemonFailure("daemon reconnect replay failed")
            return
        }
        tick(forceDisplay: true)
        publish(.connected("MK2 device reconnected; state replayed via \(daemonConnectionDescription(socketPath: activeDaemonSocketPath))"))
    }

    private func unregisterDaemonClient() {
        _ = controlClient?.request(type: .unregister, timeoutUsec: 200_000)
        _ = eventClient?.request(type: .unregister, timeoutUsec: 200_000)
        _ = displayClient?.request(type: .unregister, timeoutUsec: 200_000)
    }

    private func configureHostControl() -> Bool {
        writeReport(KompleteKontrolMK2Protocol.initReportID, KompleteKontrolMK2Protocol.initModeHostControl) == "ok"
            && writeReport(KompleteKontrolMK2Protocol.wheelStripMapReportID, KompleteKontrolMK2Protocol.wheelStripMapPayload(strip: .cc(number: 11))) == "ok"
            && writeReport(KompleteKontrolMK2Protocol.mapCommitReportID, KompleteKontrolMK2Protocol.mapCommitPayload) == "ok"
    }

    private func publish(_ state: MK2SurfaceConnection2) {
        guard connectionState != state else { return }
        connectionState = state
        connectionContinuation?.yield(state)
    }

    private func tick(forceDisplay: Bool) {
        guard running else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if daemonThread == nil {
            maybeRestartDaemonClient(now: now)
            return
        }
        // The session comes up asynchronously (reader thread → actor hop): between
        // daemonThread appearing and setEventClient installing the control client,
        // reconciling would issue writes into a nil client — indistinguishable from
        // timeouts, and the reason every client start used to flap into .retrying.
        guard controlClient != nil else { return }
        let dt = Double(now &- lastTick) / 1_000_000_000.0
        lastTick = now
        let lamps = activeLamps
        advanceLamps(dt: dt, lamps: lamps)
        reconcileLamps(lamps)
        reconcileKeys()
        reconcileDisplays(force: forceDisplay)
        maybeCheckIdleDaemon(now: now)
    }

    // Auto shift lamp: a scene with a shift layer advertises it (dim) and confirms
    // the held state (bright) unless the scene or its layer set the lamp explicitly.
    private static let shiftAvailableLamp: MK2LampState2 = .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01)
    private static let shiftHeldLamp: MK2LampState2 = .white

    private var activeLamps: [KKMK2ButtonLED: MK2LampState2] {
        var lamps = scene.lamps
        if let layer = activeShiftLayer {
            lamps.merge(layer.lamps) { _, next in next }
        }
        if scene.shift != nil, scene.lamps[.shift] == nil, scene.shift?.lamps[.shift] == nil {
            lamps[.shift] = pressedButtons.contains(.shift) ? Self.shiftHeldLamp : Self.shiftAvailableLamp
        }
        lamps.merge(lampOverlay) { _, overlay in overlay }
        return lamps
    }

    private var activeKeyColors: [Int: KKRGB] {
        guard let layer = activeShiftLayer, !layer.keyColors.isEmpty else { return scene.keyColors }
        var colors = scene.keyColors
        colors.merge(layer.keyColors) { _, next in next }
        return colors
    }

    private var activeDisplays: [MK2PixelFrame?] {
        // Touch overlays stay suppressed while the shift layer shows: its
        // slots carry other values, so the base highlight pixels would lie.
        guard let layer = activeShiftLayer else { return displaysWithTouchOverlays(scene.displays) }
        return scene.displays.enumerated().map { index, base in
            layer.displays.indices.contains(index) ? layer.displays[index] ?? base : base
        }
    }

    private func displaysWithTouchOverlays(_ base: [MK2PixelFrame?]) -> [MK2PixelFrame?] {
        var displays = base
        for (encoder, overlay) in scene.encoderTouchOverlays {
            let isActive = switch overlay.behavior {
                case .none:
                    false
                case .momentary:
                    touchedEncoders.contains(encoder)
                case .latched:
                    latchedEncoder == encoder || touchedEncoders.contains(encoder)
            }
            guard isActive,
                  displays.indices.contains(overlay.screen),
                  var frame = displays[overlay.screen] else { continue }
            frame.blit(overlay.pixels, into: overlay.rect)
            displays[overlay.screen] = frame
        }
        return displays
    }

    private func advanceLamps(dt: Double, lamps: [KKMK2ButtonLED: MK2LampState2]) {
        for (led, state) in lamps {
            switch state {
                case let .blink(_, period, _), let .pulse(_, period):
                    if period > 0 {
                        lampPhase[led, default: 0] += dt / period
                    }
                case .off, .on:
                    lampPhase[led] = 0
            }
        }
    }

    private func reconcileLamps(_ lamps: [KKMK2ButtonLED: MK2LampState2]) {
        var bytes = [UInt8](repeating: 0, count: KompleteKontrolMK2Protocol.buttonLEDMapSize)
        for (led, state) in lamps where bytes.indices.contains(led.rawValue) {
            bytes[led.rawValue] = paletteByte(for: state, led: led)
        }
        guard bytes != lastLampBytes else { return }
        let response = writeReport(KompleteKontrolMK2Protocol.buttonLEDReportID, bytes)
        guard response == "ok" else {
            if let response {
                handleDaemonFailure(response)
            } else {
                handleWriteTimeout("button LED write timed out")
            }
            return
        }
        lastLampBytes = bytes
    }

    private func reconcileKeys() {
        let keyCount = 88
        var colors = Array(repeating: KKRGB.off, count: keyCount)
        for (index, color) in activeKeyColors where colors.indices.contains(index) {
            colors[index] = color
        }
        guard colors != lastKeyColors else { return }
        var payload = [UInt8](repeating: 0, count: KompleteKontrolMK2Protocol.lightGuideKeyMapSize)
        for (index, color) in colors.enumerated() where payload.indices.contains(index) {
            payload[index] = KompleteKontrolSSeriesMK2.paletteCode(for: color)
        }
        let response = writeReport(KompleteKontrolMK2Protocol.lightGuideReportID, payload)
        guard response == "ok" else {
            if let response {
                handleDaemonFailure(response)
            } else {
                handleWriteTimeout("light guide write timed out")
            }
            return
        }
        lastKeyColors = colors
    }

    private func reconcileDisplays(force: Bool) {
        let blits = displayReconciler.reconcile(frames: activeDisplays, force: force)
        for blit in blits {
            let response = blitDisplay(
                screen: blit.screen,
                x: blit.rect.x,
                y: blit.rect.y,
                width: blit.rect.width,
                height: blit.rect.height,
                pixelsRGB565: blit.pixels,
                timeoutMs: options.displayTimeoutMs
            )
            if response != "ok" {
                if let response {
                    handleDaemonFailure(response)
                } else {
                    // The reconciler already advanced its last-sent state, so force a
                    // clean resend on the next tick before the soft retry.
                    displayReconciler.reset()
                    handleWriteTimeout("display blit timed out")
                }
                break
            }
        }
    }

    private func maybeCheckIdleDaemon(now: UInt64) {
        guard case .connected = connectionState else { return }
        guard now &- lastDaemonCommunicationNanos >= Self.daemonHeartbeatIdleNanos else { return }
        guard now &- lastDaemonHeartbeatNanos >= Self.daemonHeartbeatIdleNanos else { return }
        lastDaemonHeartbeatNanos = now
        let response = controlClient?.request(type: .version, timeoutUsec: 50_000)
        guard KompleteKontrolLibUSBServer.isCurrentProtocolMessage(response?.message) else {
            handleDaemonFailure("daemon idle heartbeat failed")
            return
        }
    }

    private func maybeRestartDaemonClient(now: UInt64) {
        guard running, daemonThread == nil else { return }
        guard now &- lastDaemonStartAttemptNanos >= Self.daemonReconnectIntervalNanos else { return }
        startDaemonClient()
    }

    private func recordDaemonCommunication() {
        lastDaemonCommunicationNanos = DispatchTime.now().uptimeNanoseconds
    }

    /// A slow ack is not a dead daemon. Writes carry a tight ceiling so the actor
    /// never stalls long, but a single timeout must not tear down the session — the
    /// client↔daemon connection stays up unless one side actually shuts down. On a
    /// write timeout, probe the control channel with a generous deadline: only a
    /// failed probe kills the session, otherwise the write retries on the next tick
    /// because the reconcile caches stay unchanged (a late ack for the timed-out
    /// write is discarded by the sequence check in the binary client).
    private func handleWriteTimeout(_ reason: String) {
        let probe = controlClient?.request(type: .version, timeoutUsec: 1_000_000)
        guard KompleteKontrolLibUSBServer.isCurrentProtocolMessage(probe?.message) else {
            handleDaemonFailure(reason)
            return
        }
        recordDaemonCommunication()
    }

    private func handleDaemonFailure(_ reason: String, generation: UInt64? = nil) {
        guard running else { return }
        if let generation, generation != daemonSessionGeneration { return }
        lastFailedDaemonSocketPath = activeDaemonSocketPath
        publish(.retrying("\(reason) (\(daemonConnectionDescription(socketPath: activeDaemonSocketPath)))"))
        resetDaemonSession()
    }

    private func resetDaemonSession() {
        daemonSessionGeneration &+= 1
        controlClient = nil
        eventClient = nil
        displayClient = nil
        deviceModel = nil
        activeDaemonSocketPath = nil
        daemonThread?.cancel()
        daemonThread = nil
        eventContinuation?.finish()
        eventContinuation = nil
        eventTask?.cancel()
        eventTask = nil
        previousSurfaceReport = nil
        lastDaemonHeartbeatNanos = 0
        lastLampBytes = [UInt8](repeating: 0xff, count: KompleteKontrolMK2Protocol.buttonLEDMapSize)
        lastKeyColors = []
        displayReconciler.reset()
        cancelButtonHolds()
    }

    private func handleSurfacePush(_ payload: [UInt8]) {
        guard let event = KKDaemonBinaryCodec.parseEventPayload(payload), !event.bytes.isEmpty else { return }
        let previous = previousSurfaceReport
        let events = KKMK2InputReportDecoder.eventsForReport(previous: previous, current: event.bytes)
        if event.bytes.first == UInt8(KompleteKontrolMK2Protocol.inputReportID) {
            previousSurfaceReport = event.bytes
        }
        handle(events, timestampNanos: event.timestamp)
    }

    func handleForTesting(_ events: [KKMK2InputEvent], timestampNanos: UInt64 = 0) {
        handle(events, timestampNanos: timestampNanos)
    }

    func activeDisplaysForTesting() -> [MK2PixelFrame?] { activeDisplays }
    func activeLampsForTesting() -> [KKMK2ButtonLED: MK2LampState2] { activeLamps }
    func activeKeyColorsForTesting() -> [Int: KKRGB] { activeKeyColors }

    private func handle(_ events: [KKMK2InputEvent], timestampNanos: UInt64) {
        for event in events {
            switch event {
                case let .button(led, pressed):
                    if pressed {
                        let resolution = buttonResolution(for: led)
                        buttonPressResolutions[led] = resolution
                        beginButtonHold(led, resolution: resolution)
                        buttonHandler(for: led, event: .press, resolution: resolution)?()
                    } else {
                        // Resolve the release against the layer/requirement captured at
                        // press time: a press taken under shift must pair with its own
                        // release even when shift went up first.
                        let resolution = buttonPressResolutions[led] ?? buttonResolution(for: led)
                        let handler = buttonHandler(for: led, event: .release, resolution: resolution)
                        endButtonHold(led)
                        handler?()
                    }
                    if led == .shift, scene.shift != nil {
                        // Flip the displayed layer now; waiting for the next 30 Hz tick
                        // makes a held modifier feel rubbery.
                        tick(forceDisplay: false)
                    }
                case let .knob(index, delta, value):
                    (activeShiftLayer?.bindings.encoder[index] ?? scene.bindings.encoder[index])?(delta, value, timestampNanos)
                case let .touchEncoder(index, touched):
                    if touched {
                        touchedEncoders.insert(index)
                        if scene.encoderTouchOverlays[index]?.behavior == .latched {
                            latchedEncoder = index
                        }
                    } else {
                        touchedEncoders.remove(index)
                    }
                    (activeShiftLayer?.bindings.encoderTouch[index] ?? scene.bindings.encoderTouch[index])?(touched)
                    if touched, lastEncoderTouchNanos.indices.contains(index) {
                        let now = DispatchTime.now().uptimeNanoseconds
                        if now &- lastEncoderTouchNanos[index] < Self.doubleTouchWindowNanos {
                            lastEncoderTouchNanos[index] = 0
                            (activeShiftLayer?.bindings.encoderDoubleTouch[index] ?? scene.bindings.encoderDoubleTouch[index])?()
                        } else {
                            lastEncoderTouchNanos[index] = now
                        }
                    }
                    if scene.encoderTouchOverlays[index] != nil {
                        // Flip the highlight now, same as the shift layer: waiting
                        // for the next tick makes the touch feel rubbery.
                        tick(forceDisplay: false)
                    }
                case let .jog(direction):
                    (activeShiftLayer?.bindings.jog ?? scene.bindings.jog)?(direction)
                case .jogCenter:
                    (activeShiftLayer?.bindings.jogCenter ?? scene.bindings.jogCenter)?()
                case let .jogScroll(delta, value):
                    (activeShiftLayer?.bindings.jogScroll ?? scene.bindings.jogScroll)?(delta, value)
                case let .jogTouch(touched):
                    (activeShiftLayer?.bindings.jogTouch ?? scene.bindings.jogTouch)?(touched)
                case let .strip(position, time):
                    (activeShiftLayer?.bindings.strip ?? scene.bindings.strip)?(position, time)
                case .rawChanged:
                    break
            }
        }
    }

    private func beginButtonHold(_ led: KKMK2ButtonLED, resolution: ButtonResolution) {
        pressedButtons.insert(led)
        buttonHoldTasks[led]?.cancel()
        guard let handler = buttonHandler(for: led, event: .hold, resolution: resolution) else { return }

        nextButtonHoldToken &+= 1
        let token = nextButtonHoldToken
        buttonHoldTokens[led] = token
        let delayNanos = Self.nanoseconds(for: options.buttonHoldDelay)
        buttonHoldTasks[led] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanos)
            } catch {
                return
            }
            await self?.fireButtonHold(led, token: token, handler: handler)
        }
    }

    private enum ButtonBindingEvent {
        case press
        case release
        case hold
    }

    private struct ButtonResolution {
        var viaShiftLayer: Bool
        var requirement: MK2InputBindings2.ModifierRequirement
    }

    /// The shift layer of the current scene, but only while SHIFT is physically held.
    private var activeShiftLayer: MK2SurfaceScene2.ShiftLayer? {
        guard pressedButtons.contains(.shift) else { return nil }
        return scene.shift
    }

    private func buttonResolution(for led: KKMK2ButtonLED) -> ButtonResolution {
        let shiftHeld = led != .shift && pressedButtons.contains(.shift)
        return ButtonResolution(
            viaShiftLayer: shiftHeld && scene.shift != nil,
            requirement: shiftHeld ? .shift : .unmodified
        )
    }

    private func buttonHandler(
        for led: KKMK2ButtonLED,
        event: ButtonBindingEvent,
        resolution: ButtonResolution
    ) -> (@Sendable () -> Void)? {
        let key = MK2InputBindings2.ModifiedButton(led, resolution.requirement)
        if resolution.viaShiftLayer, let layer = scene.shift,
           let handler = Self.buttonHandler(in: layer.bindings, led: led, key: key, event: event) {
            return handler
        }
        return Self.buttonHandler(in: scene.bindings, led: led, key: key, event: event)
    }

    private static func buttonHandler(
        in bindings: MK2InputBindings2,
        led: KKMK2ButtonLED,
        key: MK2InputBindings2.ModifiedButton,
        event: ButtonBindingEvent
    ) -> (@Sendable () -> Void)? {
        switch event {
            case .press:
                bindings.modifiedButtonDown[key] ?? bindings.buttonDown[led]
            case .release:
                bindings.modifiedButtonUp[key] ?? bindings.buttonUp[led]
            case .hold:
                bindings.modifiedButtonHold[key] ?? bindings.buttonHold[led]
        }
    }

    private func endButtonHold(_ led: KKMK2ButtonLED) {
        pressedButtons.remove(led)
        buttonPressResolutions[led] = nil
        buttonHoldTokens[led] = nil
        buttonHoldTasks[led]?.cancel()
        buttonHoldTasks[led] = nil
    }

    private func fireButtonHold(
        _ led: KKMK2ButtonLED,
        token: UInt64,
        handler: @escaping @Sendable () -> Void
    ) {
        guard pressedButtons.contains(led), buttonHoldTokens[led] == token else { return }
        buttonHoldTokens[led] = nil
        buttonHoldTasks[led] = nil
        handler()
    }

    private func cancelButtonHolds() {
        for task in buttonHoldTasks.values {
            task.cancel()
        }
        pressedButtons.removeAll()
        buttonPressResolutions.removeAll()
        buttonHoldTokens.removeAll()
        buttonHoldTasks.removeAll()
    }

    private static func nanoseconds(for delay: TimeInterval) -> UInt64 {
        guard delay.isFinite, delay > 0 else { return 0 }
        let nanoseconds = delay * 1_000_000_000
        guard nanoseconds < Double(UInt64.max) else { return UInt64.max }
        return UInt64(nanoseconds.rounded())
    }

    private func handle(midi event: KKMIDIEvent) {
        if let midiFocus = scene.bindings.midiFocus {
            midiFocus.receive(event)
        } else {
            scene.bindings.midi?(event)
        }
    }

    private func paletteByte(for state: MK2LampState2, led: KKMK2ButtonLED) -> UInt8 {
        switch state {
            case .off:
                return 0
            case let .on(color, intensity):
                return led.ledByte(for: color, intensity: intensity)
            case let .blink(color, _, intensity):
                let phase = lampPhase[led, default: 0].truncatingRemainder(dividingBy: 1)
                return phase < 0.5 ? led.ledByte(for: color, intensity: intensity) : 0
            case let .pulse(color, _):
                let phase = lampPhase[led, default: 0].truncatingRemainder(dividingBy: 1)
                let triangle = phase < 0.5 ? phase * 2 : 2 - phase * 2
                let intensity = UInt8(max(1, min(3, Int((triangle * 3).rounded()))))
                if led.isRGBBacklit {
                    return KompleteKontrolSSeriesMK2.paletteCode(for: color, intensity: intensity)
                }
                return KompleteKontrolSSeriesMK2.paletteCode(
                    for: led.fixedMonochromeBacklightColor,
                    intensity: intensity
                )
        }
    }

    private func writeReport(_ reportID: UInt8, _ payload: [UInt8]) -> String? {
        let response = controlClient?.request(
            type: .writeReport,
            payload: KKDaemonBinaryCodec.writeReportPayload(reportID: reportID, payload: payload),
            // Ceiling, not cost: healthy acks arrive in <1 ms. 50 ms bounds the actor's
            // worst-case stall if the daemon wedges, without inviting spurious timeouts
            // on debug-build tail latencies the way single-digit ceilings would.
            timeoutUsec: 50_000
        )
        guard let response else { return nil }
        recordDaemonCommunication()
        return response.status == 0 ? "ok" : "err \(response.status) \(response.message)"
    }

    private func blitDisplay(
        screen: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        pixelsRGB565: [UInt16],
        timeoutMs: UInt32
    ) -> String? {
        // Frame storage is already wire byte order (see MK2PixelFrame) — one memcpy.
        let data = pixelsRGB565.withUnsafeBytes { Array($0) }
        let ok = displayClient?.sendDisplayBlit(
            screen: UInt8(screen & 0xff),
            x: UInt16(x & 0xffff),
            y: UInt16(y & 0xffff),
            width: UInt16(width & 0xffff),
            height: UInt16(height & 0xffff),
            timeoutMs: timeoutMs,
            pixelsRGB565BE: data
        )
        guard ok == true else { return nil }
        recordDaemonCommunication()
        return "ok"
    }

    private static func parseMIDIPush(_ payload: [UInt8]) -> [KKMIDIEvent] {
        guard let eventPayload = KKDaemonBinaryCodec.parseEventPayload(payload) else { return [] }
        let timestamp = eventPayload.timestamp
        let bytes = eventPayload.bytes
        var events: [KKMIDIEvent] = []
        var index = 0
        while index + 3 < bytes.count {
            let status = bytes[index + 1]
            let data1 = bytes[index + 2]
            let data2 = bytes[index + 3]
            let channel = status & 0x0f
            switch status & 0xf0 {
                case 0x80:
                    events.append(KKMIDIEvent(kind: .noteOff, channel: channel, note: data1, velocity: data2, receptionTimestamp: timestamp))
                case 0x90:
                    events.append(KKMIDIEvent(kind: data2 == 0 ? .noteOff : .noteOn, channel: channel, note: data1, velocity: data2, receptionTimestamp: timestamp))
                case 0xb0:
                    events.append(KKMIDIEvent(control: data1, value: data2, channel: channel, receptionTimestamp: timestamp))
                case 0xd0:
                    events.append(KKMIDIEvent(channelPressure: data1, channel: channel, receptionTimestamp: timestamp))
                case 0xe0:
                    events.append(KKMIDIEvent(pitchBendLSB: data1, msb: data2, channel: channel, receptionTimestamp: timestamp))
                default:
                    break
            }
            index += 4
        }
        return events
    }
}
