import Foundation
import KompleteKontrol

public enum MK2SurfaceConnection2: Sendable, Equatable {
    case stopped
    case connected(String)
    /// The daemon session is healthy but no hardware is attached (switched
    /// off or unplugged). Distinct from `retrying`, which means the daemon
    /// itself is unreachable or misbehaving — conflating the two hid which
    /// side actually needs attention.
    case deviceOffline(String)
    case retrying(String)
    /// Another client took over the surface. The kit tears down and stays down —
    /// auto-reconnecting here would make two instances fight over the hardware.
    case evicted
}

public struct MK2DisplayPresentationMeasurement: Sendable, Equatable {
    public var encoding: String
    public var blitCount: Int
    public var logicalPixelBytes: Int
    public var transport: MK2DisplayTransportMetrics
    public var wallNanoseconds: UInt64

    public init(
        encoding: String,
        blitCount: Int,
        logicalPixelBytes: Int,
        transport: MK2DisplayTransportMetrics,
        wallNanoseconds: UInt64
    ) {
        self.encoding = encoding
        self.blitCount = blitCount
        self.logicalPixelBytes = logicalPixelBytes
        self.transport = transport
        self.wallNanoseconds = wallNanoseconds
    }
}

public enum MK2DisplayMeasurementError: Error, Sendable, Equatable, CustomStringConvertible {
    case disconnected
    case sessionInactive
    case barrierUnavailable
    case transportFailure(UInt64)
    case countersReset

    public var description: String {
        switch self {
            case .disconnected: "display daemon is not connected"
            case .sessionInactive: "display measurement session is not active"
            case .barrierUnavailable: "display barrier is unavailable or timed out"
            case let .transportFailure(count): "display transport reported \(count) failed write(s)"
            case .countersReset: "display transport counters changed generation"
        }
    }
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

/// A daemon frame plus its reader-thread reception time, so input latency can
/// be attributed to the right pipeline stage (daemon->reader vs reader->actor).
private struct ReceivedFrame: Sendable {
    var frame: KKDaemonBinaryFrame
    var readNanos: UInt64
}

/// One late input delivery, split across the client pipeline stages. Emitted
/// through `MK2Surface2.Options.inputDelaySink` (or stderr without a sink)
/// when the total exceeds the feel budget.
public struct MK2InputDelayDiagnostic: Sendable, CustomStringConvertible {
    public var totalMilliseconds: UInt64
    public var daemonToReaderMilliseconds: UInt64
    public var readerToActorMilliseconds: UInt64

    public var description: String {
        "input delayed \(totalMilliseconds)ms "
            + "(daemon->reader \(daemonToReaderMilliseconds)ms, "
            + "reader->actor \(readerToActorMilliseconds)ms)"
    }
}

public actor MK2Surface2 {
    public struct Options: Sendable {
        public var tickHz: Int
        public var displayTimeoutMs: UInt32
        public var buttonHoldDelay: TimeInterval
        public var padMIDIMapping: KontrolPadMIDIMapping
        /// Receives blown-feel-budget input deliveries so the host app can
        /// route them into its own logging system. Nil falls back to stderr —
        /// Kit2 deliberately carries no logging dependency of its own.
        public var inputDelaySink: (@Sendable (MK2InputDelayDiagnostic) -> Void)?
        /// Explicit daemon endpoint. When set, this surface talks to exactly
        /// that base socket — no auto-discovery, no simulator fallback, no
        /// alternation — so two surfaces in one process can each address their
        /// own product-bound daemon. Nil keeps the historical discovery.
        public var daemonSocketPath: String?

        public init(
            tickHz: Int = 30,
            displayTimeoutMs: UInt32 = 1_000,
            buttonHoldDelay: TimeInterval = 1.0,
            padMIDIMapping: KontrolPadMIDIMapping = KontrolPadMIDIMapping(),
            inputDelaySink: (@Sendable (MK2InputDelayDiagnostic) -> Void)? = nil,
            daemonSocketPath: String? = nil
        ) {
            self.tickHz = tickHz
            self.displayTimeoutMs = displayTimeoutMs
            self.buttonHoldDelay = buttonHoldDelay
            self.padMIDIMapping = padMIDIMapping
            self.inputDelaySink = inputDelaySink
            self.daemonSocketPath = daemonSocketPath
        }
    }

    private let options: Options
    private var scene = MK2SurfaceScene2()
    /// Compatibility view retained for existing keyboard clients. Nil for
    /// MASCHINE hardware, while `deviceInfo` and `deviceProfile` stay available.
    public private(set) var deviceModel: KompleteKontrolDeviceModel?
    /// Structured identity reported by the daemon. Nil while disconnected or
    /// when talking to a daemon predating the device-info request.
    public private(set) var deviceInfo: KKDeviceInfo?
    /// Hardware-neutral capabilities for the connected controller.
    public private(set) var deviceProfile: KontrolDeviceProfile?
    private var displayReconciler = PixelDisplayReconciler2()
    private var timer: DispatchSourceTimer?
    private var running = false
    private var lastTick = DispatchTime.now().uptimeNanoseconds
    private var lampPhase: [KKMK2ButtonLED: Double] = [:]
    /// Dynamic lamps that change independently of the rendered scene, such as
    /// realtime meters. Empty restores the scene-owned lamp state immediately.
    private var lampOverlay: [KKMK2ButtonLED: MK2LampState2] = [:]
    /// Optional alternate realtime lamps selected while SHIFT is held. Nil uses
    /// the base overlay, preserving existing meter behavior in shifted scenes.
    private var shiftLampOverlay: [KKMK2ButtonLED: MK2LampState2]?
    /// Nil restores scene-owned colors. A non-nil overlay, including an empty
    /// dictionary, fully owns the guide while realtime playback is active.
    private var keyOverlay: [Int: MK2LightGuideColor]?
    /// Nil restores scene-owned performance-pad colors; an empty overlay turns
    /// all pads off while realtime feedback owns them.
    private var padOverlay: [Int: MK2LightGuideColor]?
    private var lastLampReports: [UInt8: [UInt8]] = [:]
    private var lastKeyCodes: [UInt8] = []
    private var controlClient: KompleteKontrolDaemonBinaryClient?
    private var eventClient: KompleteKontrolDaemonBinaryClient?
    private var displayClient: KompleteKontrolDaemonBinaryClient?
    private var displayMeasurementSessionActive = false
    private var daemonThread: Thread?
    private var inputAdapter = KontrolSurfaceInputAdapter()
    private var padMIDISynthesizer: KontrolPadMIDISynthesizer
    private var connectionState: MK2SurfaceConnection2 = .stopped
    private let connectionStream: AsyncStream<MK2SurfaceConnection2>
    private var connectionContinuation: AsyncStream<MK2SurfaceConnection2>.Continuation?
    // Idle-only health checks: real daemon traffic moves this timestamp forward,
    // so playback, scrolling, and display updates suppress synthetic heartbeats.
    private var lastDaemonCommunicationNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var lastInputDelayLogNanos: UInt64 = 0
    private static let inputDelayLogThresholdNanos: UInt64 = 100_000_000
    private var lastDaemonHeartbeatNanos: UInt64 = 0
    private var lastDaemonStartAttemptNanos: UInt64 = 0
    private var activeDaemonSocketPath: String?
    private var preferredDaemonSocketPath: String?
    private var lastFailedDaemonSocketPath: String?
    private let tickGate = TickGate()
    private var eventTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<ReceivedFrame>.Continuation?
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
    /// A held layer may only activate when it already existed in the scene at
    /// button-down time. This prevents a mode-switch binding from publishing
    /// and immediately opening a layer for the same still-held trigger.
    private var eligibleHeldLayerTriggers: Set<KKMK2ButtonLED> = []
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
        padMIDISynthesizer = KontrolPadMIDISynthesizer(mapping: options.padMIDIMapping)
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
        displayMeasurementSessionActive = false
        deviceModel = nil
        deviceInfo = nil
        deviceProfile = nil
        daemonThread?.cancel()
        daemonThread = nil
        eventContinuation?.finish()
        eventContinuation = nil
        eventTask?.cancel()
        eventTask = nil
        inputAdapter.select(family: .kompleteKontrolMK2)
        padMIDISynthesizer.reset()
        lastLampReports.removeAll(keepingCapacity: true)
        lastKeyCodes = []
        lastDaemonCommunicationNanos = DispatchTime.now().uptimeNanoseconds
        lastDaemonHeartbeatNanos = 0
        lastDaemonStartAttemptNanos = 0
        cancelButtonHolds()
        touchedEncoders = []
        latchedEncoder = nil
        scene = MK2SurfaceScene2()
        lampOverlay = [:]
        shiftLampOverlay = nil
        keyOverlay = nil
        padOverlay = nil
        displayReconciler.reset()
        publish(.stopped)
    }

    public func present(_ next: MK2SurfaceScene2) {
        scene = next
    }

    public func beginDisplayMeasurementSession() throws -> String {
        guard running, let displayClient else {
            throw MK2DisplayMeasurementError.disconnected
        }
        guard let snapshot = displayClient.beginDisplayMeasurementSession() else {
            throw MK2DisplayMeasurementError.barrierUnavailable
        }
        displayMeasurementSessionActive = true
        return snapshot.encoding
    }

    @discardableResult
    public func endDisplayMeasurementSession() throws -> MK2DisplayTransportSnapshot {
        guard displayMeasurementSessionActive, let displayClient else {
            throw MK2DisplayMeasurementError.sessionInactive
        }
        defer { displayMeasurementSessionActive = false }
        guard let snapshot = displayClient.endDisplayMeasurementSession() else {
            throw MK2DisplayMeasurementError.barrierUnavailable
        }
        return snapshot
    }

    /// Replaces only the active display framebuffers, sends their reconciled blits,
    /// and waits for the daemon's physical display queue to drain. Existing input
    /// bindings, lamps, and key colours stay active while a benchmark fixture is shown.
    public func presentDisplaysAndMeasure(
        _ displays: [MK2PixelFrame?]
    ) throws -> MK2DisplayPresentationMeasurement {
        guard running, let displayClient else {
            throw MK2DisplayMeasurementError.disconnected
        }
        guard displayMeasurementSessionActive else {
            throw MK2DisplayMeasurementError.sessionInactive
        }
        guard let before = displayClient.waitForDisplayBarrier() else {
            throw MK2DisplayMeasurementError.barrierUnavailable
        }
        scene.displays = Array(displays.prefix(2))
        while scene.displays.count < 2 {
            scene.displays.append(nil)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let reconciliation = reconcileDisplays(force: false, frames: scene.displays)
        guard reconciliation.succeeded else {
            throw MK2DisplayMeasurementError.disconnected
        }
        guard let after = displayClient.waitForDisplayBarrier(),
              after.encoding == before.encoding else {
            throw MK2DisplayMeasurementError.barrierUnavailable
        }
        guard let transport = after.metrics.subtracting(before.metrics) else {
            throw MK2DisplayMeasurementError.countersReset
        }
        guard transport.failureCount == 0 else {
            throw MK2DisplayMeasurementError.transportFailure(transport.failureCount)
        }
        return MK2DisplayPresentationMeasurement(
            encoding: after.encoding,
            blitCount: reconciliation.blitCount,
            logicalPixelBytes: reconciliation.logicalPixelBytes,
            transport: transport,
            wallNanoseconds: DispatchTime.now().uptimeNanoseconds &- start
        )
    }

    /// Updates high-frequency lamp feedback without rebuilding display frames or
    /// replacing scene bindings. Overlay lamps win unless the active held layer
    /// explicitly makes its own matching lamps authoritative.
    public func presentLampOverlay(
        _ lamps: [KKMK2ButtonLED: MK2LampState2],
        shift shiftLamps: [KKMK2ButtonLED: MK2LampState2]? = nil
    ) {
        lampOverlay = lamps
        shiftLampOverlay = shiftLamps
    }

    /// Updates the complete light guide independently of display scenes and
    /// input bindings. Nil restores scene colors; an empty overlay darkens it.
    public func presentKeyOverlay(_ keys: [Int: MK2LightGuideColor]?) {
        keyOverlay = keys
    }

    /// Updates the complete performance-pad guide independently of scenes and
    /// bindings. Nil restores scene colors; an empty overlay darkens all pads.
    public func presentPadOverlay(_ pads: [Int: MK2LightGuideColor]?) {
        padOverlay = pads
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
            // Same explicit priority as the input pipeline: tick jobs share the
            // actor with input processing, so a starved tick stalls input too.
            Task(priority: .high) {
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
        let (stream, continuation) = AsyncStream<ReceivedFrame>.makeStream(bufferingPolicy: .unbounded)
        eventContinuation = continuation
        // Explicit high priority: the whole input path is feel-critical, but a plain
        // Task {} runs at default priority on the cooperative pool — bench traces
        // (2026-07-20) showed those jobs starved for 300-700ms behind main-thread
        // rendering, delivering pad events late and batched.
        eventTask = Task(priority: .high) { [weak self] in
            for await received in stream {
                guard let self else { break }
                await self.process(received)
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
                        continuation.yield(ReceivedFrame(frame: frame, readNanos: KKTiming.now()))
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
        thread.qualityOfService = .userInteractive
        daemonThread = thread
        thread.start()
    }

    private func daemonSocketPathForNextAttempt() -> String {
        if let explicit = options.daemonSocketPath {
            return explicit
        }
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

    private func process(_ received: ReceivedFrame) {
        recordDaemonCommunication()
        let frame = received.frame
        switch frame.type {
            case .input:
                handleSurfacePush(frame.payload, readNanos: received.readNanos)
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
                } else if message.hasPrefix("device disconnected") {
                    // Clear the identity so ticks quiesce (see the tick guard)
                    // instead of reconciling against the vanished device;
                    // replaySurfaceState() re-establishes everything on the
                    // "device reconnected" push.
                    deviceModel = nil
                    deviceInfo = nil
                    deviceProfile = nil
                    padMIDISynthesizer.reset()
                    publish(.deviceOffline("hardware is off or unplugged; the daemon session stays registered"))
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
        displayMeasurementSessionActive = false
        daemonThread?.cancel()
        daemonThread = nil
        eventContinuation?.finish()
        eventContinuation = nil
        eventTask?.cancel()
        eventTask = nil
        deviceModel = nil
        deviceInfo = nil
        deviceProfile = nil
        inputAdapter.select(family: .kompleteKontrolMK2)
        padMIDISynthesizer.reset()
        lastLampReports.removeAll(keepingCapacity: true)
        lastKeyCodes = []
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
              let eventRegistration = client.request(type: .register, payload: registration, timeoutUsec: 750_000),
              eventRegistration.status == 0,
              display.request(type: .register, payload: registration, timeoutUsec: 750_000)?.status == 0 else {
            handleDaemonFailure("binary register failed")
            return
        }
        recordDaemonCommunication()
        refreshDeviceIdentity()
        if let snapshot = KKDaemonBinaryCodec.parseRegistrationInputSnapshot(eventRegistration.message) {
            inputAdapter.prime(with: snapshot.bytes)
        }
        if deviceInfo == nil {
            // The protocol version already matched, so a missing device
            // identity on a healthy registration means no hardware is attached
            // right now. There is nothing to host-control-configure yet — with
            // the MK2 family fallback that write even fails outright and used
            // to flap the session into .retrying. The daemon's "device
            // reconnected" push runs replaySurfaceState(), which performs the
            // deferred setup and flips this to .connected once the hardware
            // comes up.
            preferredDaemonSocketPath = socketPath
            lastFailedDaemonSocketPath = nil
            publish(.deviceOffline("surface client registered with \(daemonConnectionDescription(socketPath: socketPath)); hardware not attached"))
            return
        }
        guard configureHostControl() else {
            handleDaemonFailure("daemon host-control setup failed")
            return
        }
        tick(forceDisplay: true)
        preferredDaemonSocketPath = socketPath
        lastFailedDaemonSocketPath = nil
        publish(.connected("surface client registered with \(daemonConnectionDescription(socketPath: socketPath))"))
    }

    private func replaySurfaceState() {
        guard running else { return }
        refreshDeviceIdentity()
        lastLampReports.removeAll(keepingCapacity: true)
        lastKeyCodes = []
        displayReconciler.reset()
        guard configureHostControl() else {
            handleDaemonFailure("daemon reconnect replay failed")
            return
        }
        tick(forceDisplay: true)
        publish(.connected("surface device reconnected; state replayed via \(daemonConnectionDescription(socketPath: activeDaemonSocketPath))"))
    }

    private func unregisterDaemonClient() {
        _ = controlClient?.request(type: .unregister, timeoutUsec: 200_000)
        _ = eventClient?.request(type: .unregister, timeoutUsec: 200_000)
        _ = displayClient?.request(type: .unregister, timeoutUsec: 200_000)
    }

    private func configureHostControl() -> Bool {
        for report in KontrolSurfaceDeviceCompatibility.hostControlReports(for: activeDeviceFamily) {
            guard writeReport(report.reportID, report.payload) == "ok" else { return false }
        }
        return true
    }

    private var activeDeviceFamily: KontrolDeviceFamily {
        deviceInfo?.family ?? .kompleteKontrolMK2
    }

    private func refreshDeviceIdentity() {
        // Best effort: an older daemon has no device-info request. Falling back
        // to MK2 preserves the behavior Kit2 had before device profiles existed.
        guard let info = controlClient?.deviceInfo(timeoutUsec: 500_000) else {
            deviceModel = nil
            deviceInfo = nil
            deviceProfile = nil
            inputAdapter.select(family: .kompleteKontrolMK2)
            padMIDISynthesizer.reset()
            return
        }
        deviceInfo = info
        deviceProfile = KontrolDeviceProfile.productID(
            info.productID,
            reportedKeyCount: UInt8(clamping: info.keyCount)
        )
        deviceModel = info.family.rawValue == KontrolDeviceFamily.kompleteKontrolMK2.rawValue
            ? KompleteKontrolDeviceModel.productID(Int(info.productID))
            : nil
        inputAdapter.select(family: info.family)
        padMIDISynthesizer.reset()
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
        // No hardware attached: there is nothing to reconcile against, and the
        // MK2 family fallback would emit reports the daemon rejects — stomping
        // the deviceOffline state back into .retrying. replaySurfaceState()
        // replays everything once the device reconnects.
        guard deviceInfo != nil else {
            maybeCheckIdleDaemon(now: now)
            return
        }
        let lamps = activeLamps
        advanceLamps(dt: dt, lamps: lamps)
        reconcileLamps(lamps, performancePads: activePadLights)
        reconcileKeys()
        reconcileDisplays(force: forceDisplay)
        maybeCheckIdleDaemon(now: now)
    }

    // Auto trigger lamp: a scene with a held-button layer advertises its trigger
    // (dim) and confirms the held state (bright) unless the scene or that layer
    // sets the lamp explicitly.
    private static let heldLayerAvailableLamp: MK2LampState2 = .on(KKRGB(red: 0xff, green: 0xff, blue: 0xff), intensity: 0x01)
    private static let heldLayerActiveLamp: MK2LampState2 = .white

    private var activeLamps: [KKMK2ButtonLED: MK2LampState2] {
        var lamps: [KKMK2ButtonLED: MK2LampState2]
        if let active = activeHeldButtonLayer, active.layer.buttonPolicy == .exclusive {
            lamps = active.layer.lamps
        } else {
            lamps = scene.lamps
            if let active = activeHeldButtonLayer {
                lamps.merge(active.layer.lamps) { _, next in next }
            }
        }
        for layer in scene.heldButtonLayers
        where scene.lamps[layer.trigger] == nil && layer.lamps[layer.trigger] == nil {
            lamps[layer.trigger] = pressedButtons.contains(layer.trigger)
                && eligibleHeldLayerTriggers.contains(layer.trigger)
                ? Self.heldLayerActiveLamp
                : Self.heldLayerAvailableLamp
        }
        let overlay = activeHeldButtonLayer?.trigger == .shift
            ? shiftLampOverlay ?? lampOverlay
            : lampOverlay
        lamps.merge(overlay) { _, overlay in overlay }
        if let active = activeHeldButtonLayer,
           active.layer.lampOverlayPolicy == .layerWins {
            lamps.merge(active.layer.lamps) { _, layer in layer }
        }
        return lamps
    }

    private var activeKeyLights: [Int: MK2LightGuideColor] {
        if let keyOverlay { return keyOverlay }
        var lights = scene.keyColors.mapValues { MK2LightGuideColor(color: $0) }
        for (index, intensity) in scene.keyIntensities {
            guard var light = lights[index] else { continue }
            light.intensity = min(3, intensity)
            lights[index] = light
        }
        guard let layer = activeHeldButtonLayer?.layer else { return lights }
        for (index, color) in layer.keyColors {
            lights[index] = MK2LightGuideColor(
                color: color,
                intensity: layer.keyIntensities[index] ?? 3
            )
        }
        for (index, intensity) in layer.keyIntensities where layer.keyColors[index] == nil {
            guard var light = lights[index] else { continue }
            light.intensity = min(3, intensity)
            lights[index] = light
        }
        return lights
    }

    private var activePadLights: [Int: MK2LightGuideColor] {
        if let padOverlay { return padOverlay }
        var lights = scene.padColors.mapValues { MK2LightGuideColor(color: $0) }
        for (index, intensity) in scene.padIntensities {
            guard var light = lights[index] else { continue }
            light.intensity = min(3, intensity)
            lights[index] = light
        }
        return lights
    }

    private var activeDisplays: [MK2PixelFrame?] {
        // Touch overlays stay suppressed while a held layer shows: its
        // slots carry other values, so the base highlight pixels would lie.
        guard let layer = activeHeldButtonLayer?.layer else { return displaysWithTouchOverlays(scene.displays) }
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
                case .off, .on, .rawOutput:
                    lampPhase[led] = 0
            }
        }
    }

    private func reconcileLamps(
        _ lamps: [KKMK2ButtonLED: MK2LampState2],
        performancePads: [Int: MK2LightGuideColor]
    ) {
        var resolved: [KKMK2ButtonLED: KontrolSurfaceLampValue] = [:]
        resolved.reserveCapacity(lamps.count)
        for (led, state) in lamps {
            if let value = lampValue(for: state, led: led) {
                resolved[led] = value
            }
        }
        let reports = KontrolSurfaceDeviceCompatibility.lampReports(
            for: activeDeviceFamily,
            lamps: resolved,
            performancePads: performancePads.mapValues {
                KontrolSurfaceLampValue(color: $0.color, intensity: $0.intensity)
            },
            diagnosticLEDBytes: scene.diagnosticLEDBytes
        )
        for report in reports {
            guard lastLampReports[report.reportID] != report.payload else { continue }
            let response = writeReport(report.reportID, report.payload)
            guard response == "ok" else {
                if let response {
                    handleDaemonFailure(response)
                } else {
                    handleWriteTimeout("button LED write timed out", client: controlClient)
                }
                return
            }
            lastLampReports[report.reportID] = report.payload
        }
    }

    private func reconcileKeys() {
        guard deviceProfile?.capabilities.hasLightGuide ?? true else { return }
        let keyCount = 88
        var codes = [UInt8](repeating: 0, count: keyCount)
        for (index, light) in activeKeyLights where codes.indices.contains(index) {
            codes[index] = light.paletteCode
        }
        guard codes != lastKeyCodes else { return }
        var payload = [UInt8](repeating: 0, count: KompleteKontrolMK2Protocol.lightGuideKeyMapSize)
        for (index, code) in codes.enumerated() where payload.indices.contains(index) {
            payload[index] = code
        }
        let response = writeReport(KompleteKontrolMK2Protocol.lightGuideReportID, payload)
        guard response == "ok" else {
            if let response {
                handleDaemonFailure(response)
            } else {
                handleWriteTimeout("light guide write timed out", client: controlClient)
            }
            return
        }
        lastKeyCodes = codes
    }

    private struct DisplayReconciliation {
        var blitCount: Int
        var logicalPixelBytes: Int
        var succeeded: Bool
    }

    @discardableResult
    private func reconcileDisplays(
        force: Bool,
        frames: [MK2PixelFrame?]? = nil
    ) -> DisplayReconciliation {
        let blits = displayReconciler.reconcile(frames: frames ?? activeDisplays, force: force)
        var logicalPixelBytes = 0
        for blit in blits {
            logicalPixelBytes += blit.pixels.count * MemoryLayout<UInt16>.size
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
                    handleWriteTimeout("display blit timed out", client: displayClient)
                }
                return DisplayReconciliation(
                    blitCount: blits.count,
                    logicalPixelBytes: logicalPixelBytes,
                    succeeded: false
                )
            }
        }
        return DisplayReconciliation(
            blitCount: blits.count,
            logicalPixelBytes: logicalPixelBytes,
            succeeded: true
        )
    }

    // A slow reply is not a dead daemon — same reasoning as handleWriteTimeout's probe,
    // and the same 1s ceiling: brief system contention right after launch (a sandbox
    // permission prompt's XPC round trip, Spotlight, another app starting) can delay a
    // reply well past 50ms without the daemon being unhealthy. A tight timeout here was
    // observed tearing down and reconnecting an otherwise-fine session during exactly
    // that kind of startup contention.
    private func maybeCheckIdleDaemon(now: UInt64) {
        guard case .connected = connectionState else { return }
        guard now &- lastDaemonCommunicationNanos >= Self.daemonHeartbeatIdleNanos else { return }
        guard now &- lastDaemonHeartbeatNanos >= Self.daemonHeartbeatIdleNanos else { return }
        lastDaemonHeartbeatNanos = now
        let response = controlClient?.request(type: .version, timeoutUsec: 1_000_000)
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
    ///
    /// `client` is the connection the timed-out write actually happened on (control for
    /// LED/light-guide reports, display for blits) — probing a *different* channel proves
    /// nothing here: a desynced display connection looks perfectly healthy over control.
    /// If that specific connection wrote a partial frame before timing out, its byte stream
    /// is permanently corrupted from that point on and no amount of waiting fixes it, so skip
    /// the probe and reconnect immediately.
    private func handleWriteTimeout(_ reason: String, client: KompleteKontrolDaemonBinaryClient?) {
        if client?.isDesynced == true {
            handleDaemonFailure(reason)
            return
        }
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
        displayMeasurementSessionActive = false
        deviceModel = nil
        deviceInfo = nil
        deviceProfile = nil
        activeDaemonSocketPath = nil
        daemonThread?.cancel()
        daemonThread = nil
        eventContinuation?.finish()
        eventContinuation = nil
        eventTask?.cancel()
        eventTask = nil
        inputAdapter.select(family: .kompleteKontrolMK2)
        padMIDISynthesizer.reset()
        lastDaemonHeartbeatNanos = 0
        lastLampReports.removeAll(keepingCapacity: true)
        lastKeyCodes = []
        displayReconciler.reset()
        cancelButtonHolds()
    }

    private func handleSurfacePush(_ payload: [UInt8], readNanos: UInt64) {
        guard let event = KKDaemonBinaryCodec.parseEventPayload(payload), !event.bytes.isEmpty else { return }
        logInputDelayIfNeeded(daemonNanos: event.timestamp, readNanos: readNanos)
        let padEvents = inputAdapter.padEvents(for: event.bytes, timestampNanos: event.timestamp)
        let events = inputAdapter.events(for: event.bytes, timestampNanos: event.timestamp)
        handle(events, timestampNanos: event.timestamp)
        handle(padEvents)
    }

    /// The daemon stamps every push with the shared uptime clock (`KKTiming.now()`),
    /// so end-to-end input latency and its split across pipeline stages
    /// (daemon socket -> reader thread -> actor) is directly measurable here.
    /// Logs only when the feel budget is clearly blown, rate-limited so a
    /// draining backlog produces one line instead of one per queued event.
    private func logInputDelayIfNeeded(daemonNanos: UInt64, readNanos: UInt64) {
        let now = KKTiming.now()
        guard daemonNanos > 0, now > daemonNanos,
              now - daemonNanos >= Self.inputDelayLogThresholdNanos else { return }
        guard now - lastInputDelayLogNanos >= 1_000_000_000 else { return }
        lastInputDelayLogNanos = now
        let diagnostic = MK2InputDelayDiagnostic(
            totalMilliseconds: (now - daemonNanos) / 1_000_000,
            daemonToReaderMilliseconds: readNanos > daemonNanos ? (readNanos - daemonNanos) / 1_000_000 : 0,
            readerToActorMilliseconds: now > readNanos ? (now - readNanos) / 1_000_000 : 0
        )
        if let sink = options.inputDelaySink {
            sink(diagnostic)
        } else {
            fputs("MK2Surface2: \(diagnostic)\n", stderr)
        }
    }

    func handleForTesting(_ events: [KKMK2InputEvent], timestampNanos: UInt64 = 0) {
        handle(events, timestampNanos: timestampNanos)
    }

    func handlePadForTesting(_ events: [KontrolSurfacePadEvent]) {
        handle(events)
    }

    func activeDisplaysForTesting() -> [MK2PixelFrame?] { activeDisplays }
    func activeLampsForTesting() -> [KKMK2ButtonLED: MK2LampState2] { activeLamps }
    func activeKeyColorsForTesting() -> [Int: KKRGB] { activeKeyLights.mapValues(\.color) }
    func activeKeyLightsForTesting() -> [Int: MK2LightGuideColor] { activeKeyLights }
    func activePadLightsForTesting() -> [Int: MK2LightGuideColor] { activePadLights }

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
                        // press time: a press taken under a held layer or modifier must
                        // pair with its own release even when the trigger went up first.
                        let resolution = buttonPressResolutions[led] ?? buttonResolution(for: led)
                        let handler = buttonHandler(for: led, event: .release, resolution: resolution)
                        endButtonHold(led)
                        handler?()
                    }
                    if scene.heldButtonLayers.contains(where: { $0.trigger == led }) {
                        // Flip the displayed layer now; waiting for the next 30 Hz tick
                        // makes a held modifier feel rubbery.
                        tick(forceDisplay: false)
                    }
                case let .knob(index, delta, value):
                    (activeHeldButtonLayer?.layer.bindings.rawEncoder[index] ?? scene.bindings.rawEncoder[index])?(delta, value, timestampNanos)
                case let .touchEncoder(index, touched):
                    if touched {
                        touchedEncoders.insert(index)
                        if scene.encoderTouchOverlays[index]?.behavior == .latched {
                            latchedEncoder = index
                        }
                    } else {
                        touchedEncoders.remove(index)
                    }
                    (activeHeldButtonLayer?.layer.bindings.encoderTouch[index] ?? scene.bindings.encoderTouch[index])?(touched)
                    if touched, lastEncoderTouchNanos.indices.contains(index) {
                        let now = DispatchTime.now().uptimeNanoseconds
                        if now &- lastEncoderTouchNanos[index] < Self.doubleTouchWindowNanos {
                            lastEncoderTouchNanos[index] = 0
                            (activeHeldButtonLayer?.layer.bindings.encoderDoubleTouch[index] ?? scene.bindings.encoderDoubleTouch[index])?()
                        } else {
                            lastEncoderTouchNanos[index] = now
                        }
                    }
                    if scene.encoderTouchOverlays[index] != nil {
                        // Flip the highlight now, same as a held layer: waiting
                        // for the next tick makes the touch feel rubbery.
                        tick(forceDisplay: false)
                    }
                case let .jog(direction):
                    (activeHeldButtonLayer?.layer.bindings.jog ?? scene.bindings.jog)?(direction)
                case .jogCenter:
                    (activeHeldButtonLayer?.layer.bindings.jogCenter ?? scene.bindings.jogCenter)?()
                case let .jogScroll(delta, value):
                    (activeHeldButtonLayer?.layer.bindings.jogScroll ?? scene.bindings.jogScroll)?(delta, value)
                case let .jogTouch(touched):
                    (activeHeldButtonLayer?.layer.bindings.jogTouch ?? scene.bindings.jogTouch)?(touched)
                case let .strip(position, time):
                    (activeHeldButtonLayer?.layer.bindings.strip ?? scene.bindings.strip)?(position, time)
                case .rawChanged:
                    break
            }
        }
    }

    private func handle(_ events: [KontrolSurfacePadEvent]) {
        for event in events {
            (activeHeldButtonLayer?.layer.bindings.pad ?? scene.bindings.pad)?(event)
            for midiEvent in padMIDISynthesizer.receive(event) {
                handle(midi: midiEvent)
            }
        }
    }

    private func beginButtonHold(_ led: KKMK2ButtonLED, resolution: ButtonResolution) {
        if scene.heldButtonLayers.contains(where: { $0.trigger == led }) {
            eligibleHeldLayerTriggers.insert(led)
        } else {
            eligibleHeldLayerTriggers.remove(led)
        }
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
        var layerTrigger: KKMK2ButtonLED?
        var requirement: MK2InputBindings2.ModifierRequirement
        var allowsBaseFallback: Bool
    }

    private struct ActiveHeldButtonLayer {
        var trigger: KKMK2ButtonLED
        var layer: MK2SurfaceScene2.HeldButtonLayer
    }

    /// The highest-priority declared layer whose trigger is physically held.
    /// Later declarations are more specific; the compatibility SHIFT layer is
    /// normalized to the first position by `MK2SurfaceScene2`.
    private var activeHeldButtonLayer: ActiveHeldButtonLayer? {
        guard let layer = scene.heldButtonLayers.last(where: {
            pressedButtons.contains($0.trigger)
                && eligibleHeldLayerTriggers.contains($0.trigger)
        }) else { return nil }
        return ActiveHeldButtonLayer(trigger: layer.trigger, layer: layer)
    }

    private func buttonResolution(for led: KKMK2ButtonLED) -> ButtonResolution {
        let shiftHeld = led != .shift && pressedButtons.contains(.shift)
        let active = activeHeldButtonLayer
        let layer = active?.trigger == led ? nil : active
        return ButtonResolution(
            layerTrigger: layer?.trigger,
            requirement: shiftHeld ? .shift : .unmodified,
            allowsBaseFallback: layer?.layer.buttonPolicy != .exclusive
        )
    }

    private func buttonHandler(
        for led: KKMK2ButtonLED,
        event: ButtonBindingEvent,
        resolution: ButtonResolution
    ) -> (@Sendable () -> Void)? {
        let key = MK2InputBindings2.ModifiedButton(led, resolution.requirement)
        if let trigger = resolution.layerTrigger,
           let layer = scene.heldButtonLayers.first(where: { $0.trigger == trigger }),
           let handler = Self.buttonHandler(in: layer.bindings, led: led, key: key, event: event) {
            return handler
        }
        guard resolution.allowsBaseFallback else { return nil }
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
        eligibleHeldLayerTriggers.remove(led)
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
        eligibleHeldLayerTriggers.removeAll()
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

    private func lampValue(
        for state: MK2LampState2,
        led: KKMK2ButtonLED?
    ) -> KontrolSurfaceLampValue? {
        switch state {
            case .off:
                return nil
            case let .rawOutput(byte):
                return KontrolSurfaceLampValue(rawByte: byte)
            case let .on(color, intensity):
                guard color != .off, intensity > 0 else { return nil }
                return KontrolSurfaceLampValue(color: color, intensity: min(intensity, 3))
            case let .blink(color, _, intensity):
                guard let led else { return nil }
                let phase = lampPhase[led, default: 0].truncatingRemainder(dividingBy: 1)
                guard phase < 0.5, color != .off, intensity > 0 else { return nil }
                return KontrolSurfaceLampValue(color: color, intensity: min(intensity, 3))
            case let .pulse(color, _):
                guard let led, color != .off else { return nil }
                let phase = lampPhase[led, default: 0].truncatingRemainder(dividingBy: 1)
                let triangle = phase < 0.5 ? phase * 2 : 2 - phase * 2
                let intensity = UInt8(max(1, min(3, Int((triangle * 3).rounded()))))
                return KontrolSurfaceLampValue(color: color, intensity: intensity)
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
                case 0xa0:
                    events.append(KKMIDIEvent(polyphonicPressure: data2, note: data1, channel: channel, receptionTimestamp: timestamp))
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
