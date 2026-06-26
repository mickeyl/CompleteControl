import Foundation
import Observation
import KompleteKontrol

public enum SurfaceConnectionState: Sendable, Equatable {
    case stopped
    case connecting
    case connected
    case retrying(message: String)
}

/// The middleware root. A `Surface` owns the device, a shadow model of the
/// hardware, the animation clock, and the reconciler. Apps describe what the
/// surface should show via declarative ``Screen`` values passed to
/// ``present(_:)`` or ``observe(_:)`` — and the surface reconciles the hardware
/// to match on every clock tick, emitting only the reports that changed.
///
/// The imperative setters on this type are deprecated for client-facing
/// application code. They remain as diagnostics and migration escape hatches
/// while existing tools move to the SwiftUI-like ``Screen`` DSL.
///
/// `Surface` is an `actor`: all surface state is serialized, and the clock and
/// device callbacks hop onto it.
public actor Surface {
    public struct Options: Sendable {
        /// Reconcile/animation rate. 60 Hz keeps marquee motion smooth and
        /// input-driven changes flushed within ~16 ms.
        public var tickHz: Int = 60
        public init(tickHz: Int = 60) { self.tickHz = tickHz }
    }

    private let device: KompleteKontrolS25MK1
    private let options: Options
    private var reconciler = DisplayReconciler()
    private var clock: SurfaceClock?
    private var lastTickNanos: UInt64 = 0
    private var keyReconciler = KeyReconciler()
    private var running = false
    private var activePage: ParameterPage?
    private var activeBank: ParameterBank?
    private var ledReconciler = LEDReconciler()
    private var gestures = GestureRecognizer()
    private var transport = TransportState()
    private var observationGeneration = 0
    private var inputHandlers = InputHandlers()
    private let inputStream: AsyncStream<SurfaceInput>
    private var inputContinuation: AsyncStream<SurfaceInput>.Continuation?
    private let midiStream: AsyncStream<KKMIDIEvent>
    private var midiContinuation: AsyncStream<KKMIDIEvent>.Continuation?
    private let connectionStream: AsyncStream<SurfaceConnectionState>
    private var connectionContinuation: AsyncStream<SurfaceConnectionState>.Continuation?
    private var connectionState: SurfaceConnectionState = .stopped
    private var nextConnectionProbeNanos: UInt64 = 0
    private var hasAttemptedDaemonStartup = false

    public init(device: KompleteKontrolS25MK1 = KompleteKontrolS25MK1(), options: Options = Options()) {
        self.device = device
        self.options = options
        var input: AsyncStream<SurfaceInput>.Continuation!
        inputStream = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { input = $0 }
        inputContinuation = input
        var midiCont: AsyncStream<KKMIDIEvent>.Continuation!
        midiStream = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { midiCont = $0 }
        midiContinuation = midiCont
        var connectionCont: AsyncStream<SurfaceConnectionState>.Continuation!
        connectionStream = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { connectionCont = $0 }
        connectionContinuation = connectionCont
    }

    /// Normalized surface input. Single-consumer; iterate it from one `Task`.
    public var inputs: AsyncStream<SurfaceInput> { inputStream }

    /// USB-MIDI input (keys, pitch, mod, CC). Single-consumer.
    public var midi: AsyncStream<KKMIDIEvent> { midiStream }

    /// Connection lifecycle for the CompleteControl surface. Apps can use this
    /// to display whether hardware output/input is online while still running
    /// without a controller attached.
    public var connectionStates: AsyncStream<SurfaceConnectionState> { connectionStream }

    public func currentConnectionState() -> SurfaceConnectionState {
        connectionState
    }

    // MARK: Lifecycle

    /// Connects to the device and starts the reconcile loop. Idempotent.
    public func start() {
        guard !running else { return }
        running = true
        publishConnectionState(.connecting)
        device.monitorMode = .changed
        device.onInputReport = { [weak self] report in
            guard let self else { return }
            Task { await self.handleInput(report) }
        }
        device.onMIDIEvent = { [weak self] event in
            guard let self else { return }
            Task { await self.forwardMIDI(event) }
        }
        device.startInputMonitoring()
        probeConnection(force: true)
        lastTickNanos = DispatchTime.now().uptimeNanoseconds
        let intervalMs = max(1, 1000 / max(1, options.tickHz))
        let clock = SurfaceClock(intervalMs: intervalMs) { [weak self] in
            guard let self else { return }
            Task { await self.tick() }
        }
        self.clock = clock
        clock.start()
    }

    /// Stops the reconcile loop and blanks the displays.
    public func stop() {
        guard running else { return }
        running = false
        publishConnectionState(.stopped)
        nextConnectionProbeNanos = 0
        hasAttemptedDaemonStartup = false
        cancelObservation()
        clock?.stop()
        clock = nil
        reconciler.clearAll()
        ledReconciler.clearAll()
        device.clearDisplaysAsync()
        _ = device.clearButtonLEDs()
    }

    // MARK: Deprecated imperative display API

    /// Deprecated: prefer `Cell { Label(...) }` in a declarative ``Screen``.
    /// Sets text on `lcd` (0…8), `row` (1 or 2; row 0 is the bar). Strings longer
    /// than the cell are handled per `overflow`, defaulting to a scrolling marquee.
    public func setText(_ lcd: Int, _ row: Int, _ text: String,
                        alignment: KKDisplayAlignment = .center,
                        overflow: TextOverflow = .marquee) {
        reconciler.set(display: lcd, row: row, .text(text, alignment, overflow))
    }

    /// Deprecated: prefer `Cell { Glyphs(...) }` in a declarative ``Screen``.
    /// Sets raw 16-segment glyph masks on a text row, one per column.
    public func setGlyphs(_ lcd: Int, _ row: Int, _ glyphs: [UInt16]) {
        reconciler.set(display: lcd, row: row, .glyphs(glyphs))
    }

    /// Deprecated: prefer `Cell { Bar(...) }` in a declarative ``Screen``.
    /// Sets the row-0 progress bar (0…1) of a display.
    public func setBar(_ value: Double, lcd: Int) {
        reconciler.set(display: lcd, row: 0, .bar(value))
    }

    /// Deprecated: prefer `Cell { Spinner(...) }` in a declarative ``Screen``.
    /// Runs a segment around a cell's rectangle perimeter as an activity
    /// indicator, animated on the surface clock (rows 1 and 2 only).
    /// `column == nil` spins every column of the row in sync; `length` lights
    /// several adjacent segments (a comet); `reverse` runs counter-clockwise.
    public func setSpinner(_ lcd: Int, _ row: Int, column: Int? = nil,
                           speed: Double = 12, length: Int = 1, reverse: Bool = false) {
        reconciler.set(display: lcd, row: row, .spinner(speed: speed, length: length, reverse: reverse, column: column))
    }

    /// Deprecated for app workflows: prefer presenting a new ``Screen`` that
    /// omits the display. Clears all three rows of a single display.
    public func clearDisplay(_ lcd: Int) {
        for row in 0..<KKDisplayFrame.rowCount {
            reconciler.set(display: lcd, row: row, .empty)
        }
    }

    /// Deprecated for app workflows: prefer presenting a new ``Screen``.
    /// Clears every display.
    public func clearAll() {
        cancelObservation()
        reconciler.clearAll()
    }

    // MARK: Display 0 — reserved for global status and page indication

    /// Deprecated: prefer `Status(...)` in a declarative ``Screen``.
    /// Shows a global status line on the status display (display 0), scrolling
    /// if it does not fit.
    public func setStatus(_ text: String) {
        reconciler.set(display: 0, row: 1, .text(text, .center, .marquee))
    }

    /// Deprecated: prefer `PageIndicator(..., of: ...)` in a declarative ``Screen``.
    /// Shows a `page/total` indicator on the status display, with a matching
    /// position bar on row 0.
    public func setPage(_ page: Int, of total: Int) {
        reconciler.set(display: 0, row: 2, .text("\(page)/\(total)", .center, .clip))
        reconciler.set(display: 0, row: 0, .bar(total > 1 ? Double(page - 1) / Double(total - 1) : 0))
    }

    // MARK: Keys and button LEDs (coalesced into the tick)

    /// Deprecated: prefer `KeyColors { ... }` in a declarative ``Screen``.
    public func setKey(_ index: Int, color: KKRGB) {
        keyReconciler.set(index, color)
    }

    /// Deprecated for app workflows: prefer presenting a ``Screen`` whose
    /// `KeyColors` omits those keys. Turns the whole light guide off.
    public func clearKeys() {
        keyReconciler.clearAll()
    }

    /// Deprecated: prefer `Lamp(...)` in a declarative ``Screen``. Sets a button
    /// LED, including animated states (blink/pulse), driven by the surface clock
    /// and reconciled to minimal LED reports.
    public func setLamp(_ led: KKButtonLED, _ state: LampState) {
        ledReconciler.set(led, state)
    }

    /// Deprecated: prefer `Lamp(...)` in a declarative ``Screen``.
    public func setButtonLED(_ name: String, value: UInt8) {
        guard let led = KKButtonLED.allCases.first(where: { $0.protocolName == name }) else { return }
        ledReconciler.set(led, value == 0 ? .off : .on(value))
    }

    // MARK: Transport

    public func transportState() -> TransportState { transport }

    /// Deprecated for app workflows: model transport state in a declarative
    /// ``Screen`` and declare `Lamp` elements there.
    public func updateTransport(_ mutate: (inout TransportState) -> Void) {
        mutate(&transport)
        reflectTransport()
    }

    private func reflectTransport() {
        ledReconciler.set(.play, transport.isPlaying ? .on(0x7f) : .on(0x14))
        ledReconciler.set(.stop, .on(0x14))
        ledReconciler.set(.rec, transport.isRecording ? .blink(period: 0.4, level: 0x7f) : .off)
        ledReconciler.set(.loop, transport.loopEnabled ? .on(0x7f) : .off)
    }

    // MARK: Declarative composition

    /// Presents a declarative screen: lowers it to a model and reconciles to it.
    /// Display content is fully redefined (unset cells clear); declared lamps are
    /// merged so transport/interactive LEDs set elsewhere are left untouched.
    public func present(_ screen: some Screen) {
        surfaceTrace("surface present begin")
        cancelObservation()
        let model = screen.lowered()
        surfaceTrace("surface present lowered \(surfaceTraceSummary(model))")
        apply(model)
    }

    /// Presents a screen and keeps it in sync: whenever any `@Observable` state
    /// the screen reads changes, the screen is re-lowered and reconciled. The
    /// diffing reconciler makes the full re-render cheap. Superseded by the next
    /// `observe`/`present`/page change.
    public func observe(_ build: @escaping () -> any Screen) {
        observationGeneration += 1
        renderObserved(build, generation: observationGeneration)
    }

    private func renderObserved(_ build: @escaping () -> any Screen, generation: Int) {
        guard generation == observationGeneration else { return }
        let model = withObservationTracking {
            build().lowered()
        } onChange: { [weak self] in
            Task { await self?.renderObserved(build, generation: generation) }
        }
        apply(model)
    }

    private func cancelObservation() {
        observationGeneration += 1
        inputHandlers = InputHandlers()
        keyReconciler.clearAll()
    }

    /// Deprecated: use ``present(_:)`` or ``observe(_:)`` with a declarative
    /// ``Screen``. Replaces the whole surface using an inline builder closure.
    public func show(_ build: (isolated Surface) -> Void) {
        cancelObservation()
        reconciler.clearAll()
        build(self)
    }

    private func apply(_ model: SurfaceModel) {
        surfaceTrace("surface apply \(surfaceTraceSummary(model))")
        for display in 0..<KKDisplayFrame.displayCount {
            for row in 0..<KKDisplayFrame.rowCount {
                reconciler.set(display: display, row: row, model.content(display, row))
            }
        }
        for (led, state) in model.lamps {
            ledReconciler.set(led, state)
        }
        keyReconciler.setAll(model.keys)
        inputHandlers = model.handlers
    }

    // MARK: Parameter pages

    /// Makes `page` the active page: renders it and routes encoder turns to it.
    public func setParameterPage(_ page: ParameterPage) {
        cancelObservation()
        activeBank = nil
        activePage = page
        reconciler.clearAll()
        page.render(on: self)
    }

    /// Makes `bank` active: renders its selected page and routes encoder turns to
    /// it. Page with `bankNext` / `bankPrevious`.
    public func setParameterBank(_ bank: ParameterBank) {
        cancelObservation()
        activeBank = bank
        presentBankPage()
    }

    public func bankNext() {
        activeBank?.selectNext()
        presentBankPage()
    }

    public func bankPrevious() {
        activeBank?.selectPrevious()
        presentBankPage()
    }

    private func presentBankPage() {
        guard let bank = activeBank, let page = bank.current else { return }
        activePage = page
        reconciler.clearAll()
        page.render(on: self)
        reconciler.set(display: 0, row: 2, .text("\(bank.index + 1)/\(bank.count)", .center, .clip))
        reconciler.set(display: 0, row: 0, .bar(bank.count > 1 ? Double(bank.index) / Double(bank.count - 1) : 0))
    }

    /// Stops routing encoder turns to a parameter page (input still streams).
    public func clearParameterPage() {
        activePage = nil
        activeBank = nil
    }

    // MARK: Input

    private func handleInput(_ report: KKInputReport) {
        let now = DispatchTime.now().uptimeNanoseconds
        for event in report.events {
            guard let input = SurfaceInput.from(event) else { continue }
            switch input {
                case let .encoder(index, delta, _):
                    if let handler = inputHandlers.encoder[index] {
                        handler(delta)
                    } else {
                        activePage?.handleEncoder(encoder: index, delta: delta, on: self)
                    }
                case let .mainEncoder(delta):
                    inputHandlers.mainEncoder?(delta)
                case let .button(name, pressed):
                    for phase in gestures.buttonChanged(name, pressed: pressed, now: now) {
                        dispatchGesture(name, phase)
                        inputContinuation?.yield(.gesture(button: name, phase: phase))
                    }
                default:
                    break
            }
            inputContinuation?.yield(input)
        }
    }

    private func dispatchGesture(_ button: String, _ phase: GesturePhase) {
        switch phase {
            case .tap: inputHandlers.tap[button]?()
            case .hold: inputHandlers.hold[button]?()
            case let .secondary(modifier): inputHandlers.secondary[button]?(modifier)
            case .down, .up: break
        }
    }

    private func forwardMIDI(_ event: KKMIDIEvent) {
        midiContinuation?.yield(event)
    }

    // MARK: Reconcile tick

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let dt = Double(now &- lastTickNanos) / 1_000_000_000.0
        lastTickNanos = now
        probeConnectionIfNeeded(now: now)

        reconciler.advance(dt: dt)
        for (row, data) in reconciler.render() {
            surfaceTrace("surface tick display row=\(row) blank=\(data.allSatisfy { $0 == 0 }) nonzero=\(data.filter { $0 != 0 }.count) head=\(surfaceTraceBytes(data))")
            device.sendDisplayRowAsync(row, data: data)
        }

        ledReconciler.advance(dt: dt)
        let changedLEDs = ledReconciler.render()
        if !changedLEDs.isEmpty {
            for (index, value) in changedLEDs {
                _ = device.setButtonLED(index: index, value: value, flush: false)
            }
            device.sendButtonLEDsAsync()
        }

        if let keys = keyReconciler.render() {
            for (index, color) in keys.enumerated() {
                _ = device.setKey(index, color: color, flush: false)
            }
            device.sendGuideAsync()
        }

        for gesture in gestures.tick(now: now) {
            dispatchGesture(gesture.name, gesture.phase)
            inputContinuation?.yield(.gesture(button: gesture.name, phase: gesture.phase))
        }
    }

    private nonisolated func surfaceTrace(_ message: @autoclosure () -> String) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PAULINCHE_SURFACE_TRACE"] == "1" || environment["PAULINCHE_SURFACE_TRACE_FILE"] != nil else { return }
        let line = "[KontrolSurface] \(Date().timeIntervalSince1970) \(message())\n"
        if let path = environment["PAULINCHE_SURFACE_TRACE_FILE"] {
            let url = URL(fileURLWithPath: path)
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        } else {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    private func surfaceTraceSummary(_ model: SurfaceModel) -> String {
        var cells: [String] = []
        for display in 0..<KKDisplayFrame.displayCount {
            var rows: [String] = []
            for row in 0..<KKDisplayFrame.rowCount {
                rows.append(surfaceTraceContent(model.content(display, row)))
            }
            cells.append("\(display):\(rows.joined(separator: "|"))")
        }
        return "cells[\(cells.joined(separator: " / "))] lamps=\(model.lamps.count) keys=\(model.keys.count)"
    }

    private func surfaceTraceContent(_ content: CellContent) -> String {
        switch content {
            case .empty:
                return "empty"
            case let .bar(value):
                return String(format: "bar(%.2f)", value)
            case let .text(text, _, _):
                return "text(\(text))"
            case let .glyphs(glyphs):
                return "glyphs(\(glyphs.count))"
            case .spinner:
                return "spinner"
        }
    }

    private nonisolated func surfaceTraceBytes(_ data: [UInt8]) -> String {
        data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func probeConnectionIfNeeded(now: UInt64) {
        guard running, now >= nextConnectionProbeNanos else { return }
        if case .connected = connectionState {
            nextConnectionProbeNanos = now + 60 * 1_000_000_000
            return
        }
        probeConnection(force: false, now: now)
    }

    private func probeConnection(force: Bool, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard running else { return }

        let intervalSeconds: UInt64
        switch connectionState {
            case .connected:
                intervalSeconds = 5
            default:
                intervalSeconds = 2
        }
        nextConnectionProbeNanos = now + intervalSeconds * 1_000_000_000

        if device.usesPrivilegedDaemonTransport,
           !KompleteKontrolLibUSBServer.daemonSocketIsAvailable(),
           hasAttemptedDaemonStartup,
           !force {
            publishConnectionState(.retrying(message: "daemon unavailable"))
            return
        }

        if device.usesPrivilegedDaemonTransport {
            hasAttemptedDaemonStartup = true
        }

        let result = device.handshake()
        if result.succeeded {
            publishConnectionState(.connected)
        } else {
            let message = result.message.isEmpty ? "connection unavailable" : result.message
            publishConnectionState(.retrying(message: message))
        }
    }

    private func publishConnectionState(_ state: SurfaceConnectionState) {
        guard connectionState != state else { return }
        connectionState = state
        connectionContinuation?.yield(state)
    }
}
