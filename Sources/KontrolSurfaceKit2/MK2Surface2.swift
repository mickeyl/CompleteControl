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

        public init(tickHz: Int = 30, displayTimeoutMs: UInt32 = 1_000) {
            self.tickHz = tickHz
            self.displayTimeoutMs = displayTimeoutMs
        }
    }

    private let options: Options
    private var scene = MK2SurfaceScene2()
    private var displayReconciler = PixelDisplayReconciler2()
    private var timer: DispatchSourceTimer?
    private var running = false
    private var lastTick = DispatchTime.now().uptimeNanoseconds
    private var lampPhase: [KKMK2ButtonLED: Double] = [:]
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
    private let tickGate = TickGate()
    private var eventTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<KKDaemonBinaryFrame>.Continuation?

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
        scene = MK2SurfaceScene2()
        displayReconciler.reset()
        publish(.stopped)
    }

    public func present(_ next: MK2SurfaceScene2) {
        scene = next
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
        if !KompleteKontrolLibUSBServer.daemonSocketIsAvailable() {
            let forceRestart = FileManager.default.fileExists(atPath: KompleteKontrolLibUSBServer.defaultDaemonSocketPath)
            _ = KompleteKontrolLibUSBServer.startDaemonWithAdministratorPrivileges(
                executablePath: nil,
                forceRestart: forceRestart
            ) { message in
                fputs("\(message)\n", stderr)
            }
        }
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
        let thread = Thread { [weak self] in
            guard let eventClient = KompleteKontrolDaemonBinaryClient(channel: .event) else {
                continuation.finish()
                Task { await self?.publish(.retrying("daemon socket unavailable")) }
                return
            }
            Task { await self?.setEventClient(eventClient) }
            while !Thread.current.isCancelled {
                guard let frame = eventClient.readEvent(timeoutUsec: 20_000) else { continue }
                continuation.yield(frame)
            }
            continuation.finish()
        }
        thread.name = "MK2Surface2 daemon reader"
        daemonThread = thread
        thread.start()
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
                } else {
                    publish(.retrying(message))
                }
            default:
                break
        }
    }

    private func evict() {
        guard running else { return }
        running = false
        timer?.cancel()
        timer = nil
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

    private func setEventClient(_ client: KompleteKontrolDaemonBinaryClient) {
        eventClient = client
        guard let control = KompleteKontrolDaemonBinaryClient(channel: .control),
              let display = KompleteKontrolDaemonBinaryClient(channel: .display) else {
            publish(.retrying("daemon binary sockets unavailable"))
            return
        }
        controlClient = control
        displayClient = display
        guard control.request(type: .version, timeoutUsec: 500_000)?.message == "kk-daemon \(KompleteKontrolLibUSBServer.protocolVersion)" else {
            publish(.retrying("daemon protocol mismatch"))
            return
        }
        let registration = KKDaemonBinaryCodec.registerPayload(pid: getpid(), name: ProcessInfo.processInfo.processName)
        guard control.request(type: .register, payload: registration, timeoutUsec: 750_000)?.status == 0,
              client.request(type: .register, payload: registration, timeoutUsec: 750_000)?.status == 0,
              display.request(type: .register, payload: registration, timeoutUsec: 750_000)?.status == 0 else {
            publish(.retrying("binary register failed"))
            return
        }
        configureHostControl()
        tick(forceDisplay: true)
        publish(.connected("MK2 daemon client registered"))
    }

    private func unregisterDaemonClient() {
        _ = controlClient?.request(type: .unregister, timeoutUsec: 200_000)
        _ = eventClient?.request(type: .unregister, timeoutUsec: 200_000)
        _ = displayClient?.request(type: .unregister, timeoutUsec: 200_000)
    }

    private func configureHostControl() {
        _ = writeReport(KompleteKontrolMK2Protocol.initReportID, KompleteKontrolMK2Protocol.initModeHostControl)
        _ = writeReport(KompleteKontrolMK2Protocol.wheelStripMapReportID, KompleteKontrolMK2Protocol.wheelStripMapPayload(strip: .cc(number: 11)))
        _ = writeReport(KompleteKontrolMK2Protocol.mapCommitReportID, KompleteKontrolMK2Protocol.mapCommitPayload)
    }

    private func publish(_ state: MK2SurfaceConnection2) {
        guard connectionState != state else { return }
        connectionState = state
        connectionContinuation?.yield(state)
    }

    private func tick(forceDisplay: Bool) {
        guard running else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let dt = Double(now &- lastTick) / 1_000_000_000.0
        lastTick = now
        advanceLamps(dt: dt)
        reconcileLamps()
        reconcileKeys()
        reconcileDisplays(force: forceDisplay)
    }

    private func advanceLamps(dt: Double) {
        for (led, state) in scene.lamps {
            switch state {
                case let .blink(_, period), let .pulse(_, period):
                    if period > 0 {
                        lampPhase[led, default: 0] += dt / period
                    }
                case .off, .on:
                    lampPhase[led] = 0
            }
        }
    }

    private func reconcileLamps() {
        var bytes = [UInt8](repeating: 0, count: KompleteKontrolMK2Protocol.buttonLEDMapSize)
        for (led, state) in scene.lamps where bytes.indices.contains(led.rawValue) {
            bytes[led.rawValue] = paletteByte(for: state, led: led)
        }
        guard bytes != lastLampBytes else { return }
        lastLampBytes = bytes
        _ = writeReport(KompleteKontrolMK2Protocol.buttonLEDReportID, bytes)
    }

    private func reconcileKeys() {
        let keyCount = 88
        var colors = Array(repeating: KKRGB.off, count: keyCount)
        for (index, color) in scene.keyColors where colors.indices.contains(index) {
            colors[index] = color
        }
        guard colors != lastKeyColors else { return }
        lastKeyColors = colors
        var payload = [UInt8](repeating: 0, count: KompleteKontrolMK2Protocol.lightGuideKeyMapSize)
        for (index, color) in colors.enumerated() where payload.indices.contains(index) {
            payload[index] = KompleteKontrolSSeriesMK2.paletteCode(for: color)
        }
        _ = writeReport(KompleteKontrolMK2Protocol.lightGuideReportID, payload)
    }

    private func reconcileDisplays(force: Bool) {
        let blits = displayReconciler.reconcile(frames: scene.displays, force: force)
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
                publish(.retrying(response ?? "display blit timed out"))
                break
            }
        }
    }

    private func handleSurfacePush(_ payload: [UInt8]) {
        guard let event = KKDaemonBinaryCodec.parseEventPayload(payload), !event.bytes.isEmpty else { return }
        let previous = previousSurfaceReport
        let events = KKMK2InputReportDecoder.eventsForReport(previous: previous, current: event.bytes)
        if event.bytes.first == UInt8(KompleteKontrolMK2Protocol.inputReportID) {
            previousSurfaceReport = event.bytes
        }
        handle(events)
    }

    private func handle(_ events: [KKMK2InputEvent]) {
        for event in events {
            switch event {
                case let .button(name, pressed):
                    if pressed {
                        scene.bindings.buttonDown[name]?()
                    } else {
                        scene.bindings.buttonUp[name]?()
                    }
                case let .knob(index, delta, value):
                    scene.bindings.encoder[index]?(delta, value)
                case let .touchEncoder(index, touched):
                    scene.bindings.encoderTouch[index]?(touched)
                case let .jog(direction):
                    scene.bindings.jog?(direction)
                case let .jogScroll(delta, value):
                    scene.bindings.jogScroll?(delta, value)
                case let .jogTouch(touched):
                    scene.bindings.jogTouch?(touched)
                case let .strip(position, time):
                    scene.bindings.strip?(position, time)
                case .rawChanged:
                    break
            }
        }
    }

    private func handle(midi event: KKMIDIEvent) {
        scene.bindings.midi?(event)
    }

    private func paletteByte(for state: MK2LampState2, led: KKMK2ButtonLED) -> UInt8 {
        switch state {
            case .off:
                return 0
            case let .on(color):
                return KompleteKontrolSSeriesMK2.paletteCode(for: color)
            case let .blink(color, _):
                let phase = lampPhase[led, default: 0].truncatingRemainder(dividingBy: 1)
                return phase < 0.5 ? KompleteKontrolSSeriesMK2.paletteCode(for: color) : 0
            case let .pulse(color, _):
                let phase = lampPhase[led, default: 0].truncatingRemainder(dividingBy: 1)
                let triangle = phase < 0.5 ? phase * 2 : 2 - phase * 2
                let intensity = UInt8(max(1, min(3, Int((triangle * 3).rounded()))))
                return KompleteKontrolSSeriesMK2.paletteCode(for: color, intensity: intensity)
        }
    }

    private func writeReport(_ reportID: UInt8, _ payload: [UInt8]) -> String? {
        let response = controlClient?.request(
            type: .writeReport,
            payload: KKDaemonBinaryCodec.writeReportPayload(reportID: reportID, payload: payload),
            timeoutUsec: 250_000
        )
        guard let response else { return nil }
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
        // Preallocated big-endian conversion — appending 260k bytes one at a time was a
        // measurable part of the per-tick actor stall in unoptimized builds.
        let data = [UInt8](unsafeUninitializedCapacity: pixelsRGB565.count * 2) { buffer, initializedCount in
            pixelsRGB565.withUnsafeBufferPointer { source in
                for index in 0..<source.count {
                    let pixel = source[index]
                    buffer[index * 2] = UInt8(truncatingIfNeeded: pixel >> 8)
                    buffer[index * 2 + 1] = UInt8(truncatingIfNeeded: pixel)
                }
            }
            initializedCount = pixelsRGB565.count * 2
        }
        let ok = displayClient?.sendDisplayBlit(
            screen: UInt8(screen & 0xff),
            x: UInt16(x & 0xffff),
            y: UInt16(y & 0xffff),
            width: UInt16(width & 0xffff),
            height: UInt16(height & 0xffff),
            timeoutMs: timeoutMs,
            pixelsRGB565BE: data
        )
        return ok == true ? "ok" : nil
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
