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
    private var ledsDirty = false
    private var running = false

    public init(device: KompleteKontrolS25MK1 = KompleteKontrolS25MK1(), options: Options = Options()) {
        self.device = device
        self.options = options
    }

    // MARK: Lifecycle

    /// Connects to the device and starts the reconcile loop. Idempotent.
    public func start() {
        guard !running else { return }
        running = true
        device.monitorMode = .changed
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
        device.clearDisplaysAsync()
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

    public func setButtonLED(_ name: String, value: UInt8) {
        _ = device.setButtonLED(name: name, value: value, flush: false)
        ledsDirty = true
    }

    // MARK: Declarative composition

    /// Replaces the whole surface with the content produced by `screen`.
    /// Cells the screen does not set are cleared, giving declarative semantics.
    public func present(_ screen: some Screen) {
        reconciler.clearAll()
        screen.render(on: self)
    }

    /// Replaces the whole surface using an inline builder closure.
    public func show(_ build: (isolated Surface) -> Void) {
        reconciler.clearAll()
        build(self)
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
        if guideDirty {
            device.sendGuideAsync()
            guideDirty = false
        }
        if ledsDirty {
            device.sendButtonLEDsAsync()
            ledsDirty = false
        }
    }
}
