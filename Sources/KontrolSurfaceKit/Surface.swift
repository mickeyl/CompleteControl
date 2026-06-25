import Foundation
import KompleteKontrol

/// The middleware root. A `Surface` owns the device, a shadow model of the
/// hardware, the animation clock, and the reconciler. Apps describe what the
/// surface should show — imperatively via the setters below, or declaratively
/// via ``present(_:)`` / ``show(_:)`` — and the surface reconciles the hardware
/// to match on every clock tick, emitting only the reports that changed.
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
    private var guideDirty = false
    private var running = false
    private var activePage: ParameterPage?
    private var ledReconciler = LEDReconciler()
    private var gestures = GestureRecognizer()
    private var transport = TransportState()
    private let inputStream: AsyncStream<SurfaceInput>
    private var inputContinuation: AsyncStream<SurfaceInput>.Continuation?

    public init(device: KompleteKontrolS25MK1 = KompleteKontrolS25MK1(), options: Options = Options()) {
        self.device = device
        self.options = options
        var continuation: AsyncStream<SurfaceInput>.Continuation!
        inputStream = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation = $0 }
        inputContinuation = continuation
    }

    /// Normalized surface input. Single-consumer; iterate it from one `Task`.
    public var inputs: AsyncStream<SurfaceInput> { inputStream }

    // MARK: Lifecycle

    /// Connects to the device and starts the reconcile loop. Idempotent.
    public func start() {
        guard !running else { return }
        running = true
        device.monitorMode = .changed
        device.onInputReport = { [weak self] report in
            guard let self else { return }
            Task { await self.handleInput(report) }
        }
        device.startInputMonitoring()
        device.handshakeAsync()
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
        clock?.stop()
        clock = nil
        reconciler.clearAll()
        ledReconciler.clearAll()
        device.clearDisplaysAsync()
        _ = device.clearButtonLEDs()
    }

    // MARK: Imperative display API

    /// Sets text on `lcd` (0…8), `row` (1 or 2; row 0 is the bar). Strings longer
    /// than the cell are handled per `overflow`, defaulting to a scrolling marquee.
    public func setText(_ lcd: Int, _ row: Int, _ text: String,
                        alignment: KKDisplayAlignment = .center,
                        overflow: TextOverflow = .marquee) {
        reconciler.set(display: lcd, row: row, .text(text, alignment, overflow))
    }

    /// Sets raw 16-segment glyph masks on a text row, one per column.
    public func setGlyphs(_ lcd: Int, _ row: Int, _ glyphs: [UInt16]) {
        reconciler.set(display: lcd, row: row, .glyphs(glyphs))
    }

    /// Sets the row-0 progress bar (0…1) of a display.
    public func setBar(_ value: Double, lcd: Int) {
        reconciler.set(display: lcd, row: 0, .bar(value))
    }

    /// Runs a segment around a cell's rectangle perimeter as an activity
    /// indicator, animated on the surface clock (rows 1 and 2 only).
    /// `column == nil` spins every column of the row in sync; `length` lights
    /// several adjacent segments (a comet); `reverse` runs counter-clockwise.
    public func setSpinner(_ lcd: Int, _ row: Int, column: Int? = nil,
                           speed: Double = 12, length: Int = 1, reverse: Bool = false) {
        reconciler.set(display: lcd, row: row, .spinner(speed: speed, length: length, reverse: reverse, column: column))
    }

    /// Clears all three rows of a single display.
    public func clearDisplay(_ lcd: Int) {
        for row in 0..<KKDisplayFrame.rowCount {
            reconciler.set(display: lcd, row: row, .empty)
        }
    }

    /// Clears every display.
    public func clearAll() {
        reconciler.clearAll()
    }

    // MARK: Display 0 — reserved for global status and page indication

    /// Shows a global status line on the status display (display 0), scrolling
    /// if it does not fit.
    public func setStatus(_ text: String) {
        reconciler.set(display: 0, row: 1, .text(text, .center, .marquee))
    }

    /// Shows a `page/total` indicator on the status display, with a matching
    /// position bar on row 0.
    public func setPage(_ page: Int, of total: Int) {
        reconciler.set(display: 0, row: 2, .text("\(page)/\(total)", .center, .clip))
        reconciler.set(display: 0, row: 0, .bar(total > 1 ? Double(page - 1) / Double(total - 1) : 0))
    }

    // MARK: Keys and button LEDs (coalesced into the tick)

    public func setKey(_ index: Int, color: KKRGB) {
        _ = device.setKey(index, color: color, flush: false)
        guideDirty = true
    }

    /// Sets a button LED, including animated states (blink/pulse), driven by the
    /// surface clock and reconciled to minimal LED reports.
    public func setLamp(_ led: KKButtonLED, _ state: LampState) {
        ledReconciler.set(led, state)
    }

    public func setButtonLED(_ name: String, value: UInt8) {
        guard let led = KKButtonLED.allCases.first(where: { $0.protocolName == name }) else { return }
        ledReconciler.set(led, value == 0 ? .off : .on(value))
    }

    // MARK: Transport

    public func transportState() -> TransportState { transport }

    /// Mutates transport state and reflects it on the hardware transport LEDs.
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
        apply(screen.lowered())
    }

    /// Replaces the whole surface using an inline builder closure (imperative).
    public func show(_ build: (isolated Surface) -> Void) {
        reconciler.clearAll()
        build(self)
    }

    private func apply(_ model: SurfaceModel) {
        for display in 0..<KKDisplayFrame.displayCount {
            for row in 0..<KKDisplayFrame.rowCount {
                reconciler.set(display: display, row: row, model.content(display, row))
            }
        }
        for (led, state) in model.lamps {
            ledReconciler.set(led, state)
        }
    }

    // MARK: Parameter pages

    /// Makes `page` the active page: renders it and routes encoder turns to it.
    public func setParameterPage(_ page: ParameterPage) {
        activePage = page
        reconciler.clearAll()
        page.render(on: self)
    }

    /// Stops routing encoder turns to a parameter page (input still streams).
    public func clearParameterPage() {
        activePage = nil
    }

    // MARK: Input

    private func handleInput(_ report: KKInputReport) {
        let now = DispatchTime.now().uptimeNanoseconds
        for event in report.events {
            guard let input = SurfaceInput.from(event) else { continue }
            if case let .encoder(index, delta, _) = input {
                activePage?.handleEncoder(encoder: index, delta: delta, on: self)
            }
            if case let .button(name, pressed) = input {
                for phase in gestures.buttonChanged(name, pressed: pressed, now: now) {
                    inputContinuation?.yield(.gesture(button: name, phase: phase))
                }
            }
            inputContinuation?.yield(input)
        }
    }

    // MARK: Reconcile tick

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let dt = Double(now &- lastTickNanos) / 1_000_000_000.0
        lastTickNanos = now

        reconciler.advance(dt: dt)
        for (row, data) in reconciler.render() {
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

        if guideDirty {
            device.sendGuideAsync()
            guideDirty = false
        }

        for gesture in gestures.tick(now: now) {
            inputContinuation?.yield(.gesture(button: gesture.name, phase: gesture.phase))
        }
    }
}
