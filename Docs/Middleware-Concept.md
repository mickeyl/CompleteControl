# CompleteControl Middleware API — Concept

Status: **draft for discussion**. This document proposes a declarative middleware layer
on top of the existing low-level `KompleteKontrol` driver. Nothing here is implemented yet;
the goal is to agree on the shape before writing code.

## 1. Why a middleware layer

The current public API (`KompleteKontrolS25MK1`) is an excellent *transport*: it speaks the
raw surface protocol — `setKey`, `setButtonLED`, `setDisplayText`, `setDisplayBar`,
`setDisplayGlyph`, `sendDisplaysAsync`, and decoded input events (`KKInputEvent`,
`KKMIDIEvent`). It is **immediate-mode and stateless about intent**: every app has to track
"what is currently on the surface", re-send full frames, debounce its own flushes, scroll its
own text, and translate raw encoder deltas into meaningful values.

`Tools/KontrolProbe/TestUI.swift` already re-implements, by hand, most of what a middleware
should own: adaptive/velocity encoder stepping, per-parameter value ranges, display-frame
coalescing on a 10 ms timer, glyph paging, button→LED mapping, light-guide note feedback.
That code is the proof that these abstractions are needed — and the prototype for them.

The middleware turns the model around: **the app declares the desired surface; the middleware
reconciles hardware to match it**, animates what needs animating, and hands back high-level,
semantic input.

## 2. Design principles

1. **Declarative / retained-mode.** Apps describe *what the surface should show and do*, not
   *which bytes to send*. The middleware owns a render loop and a shadow model of the hardware.
2. **Reconciliation = minimal I/O.** Each frame diffs intended state against the last bytes
   actually sent, and emits only the reports that changed, coalesced into one batched flush
   (built on `performOutputBatch` + the `…Async` senders). This generalizes the TestUI's
   `scheduleDemoDisplayFrame` debounce.
3. **One clock.** A single animation tick drives marquee scrolling, blink, meter ballistics,
   and pulses. No widget owns its own timer.
4. **Semantic input.** Raw `KKInputEvent` becomes `encoderTurned(velocity:)`, button
   `tap/hold/doubleTap`, strip touch/value, 4-D navigation — routed to the focused screen.
5. **Backend-agnostic.** The surface model knows nothing about the controlled app. Adapters
   (MCU/HUI, OSC, native) bridge a DAW's parameters/transport into the model. This is what
   makes the S25 a *first-class remote control for any music app*.
6. **Layered, each layer usable on its own.** You can drop down to the raw driver any time.

## 3. Layering

```
┌─────────────────────────────────────────────────────────────┐
│ App / Adapters   MCU·HUI emulation │ OSC │ native DAW SDK │ … │
├─────────────────────────────────────────────────────────────┤
│ Declarative layer   Screen DSL · Components · Parameter ·     │
│                     Transport · KeyBed · Navigator            │
├─────────────────────────────────────────────────────────────┤
│ Middleware core   Surface · Reconciler/ShadowState ·         │
│                   Clock/Scheduler · InputRouter/Gestures      │
├─────────────────────────────────────────────────────────────┤
│ Driver (exists)   KompleteKontrolS25MK1 · KKDisplayFrame · …  │
└─────────────────────────────────────────────────────────────┘
```

Module name: **`KontrolSurfaceKit`**.

## 4. Core: `Surface`

The root object. Wraps a device, owns the shadow state, the clock, the input router, and the
screen stack.

```swift
public final class Surface {
    public init(device: KompleteKontrolS25MK1 = .init())
    public func start()                       // handshake + input monitoring + clock
    public func stop()

    // Screen stack / router
    public func setRoot(_ screen: some Screen)
    public func push(_ screen: some Screen)
    public func pop()
    public func present(_ overlay: some Screen) // transient popup (auto-dismiss optional)

    // Global, app-agnostic facilities
    public var transport: Transport
    public var keyBed: KeyBed
    public var clock: SurfaceClock            // tick rate, pause/resume

    // Escape hatch: imperative convenience that still goes through reconciliation
    @discardableResult
    public func setText(_ lcd: Int, _ row: Int, _ text: String,
                        overflow: TextOverflow = .marquee()) -> CellHandle
}
```

### Shadow state & reconciliation

The middleware holds the intended state of every addressable element:

- 9 displays × 3 rows × 8 cells of 16-segment content (row 0 is the progress bar only),
- 25 RGB light-guide keys,
- the button LED table (`KKButtonLED`).

Per tick it computes `intended` from the active screen + animations, diffs against
`lastSent`, and flushes only dirty reports. Text/glyph rows collapse to at most one display
report per changed row; key/LED changes collapse to one guide / one LED report. Backpressure:
if the USB output queue is saturated, frames are dropped (latest-wins), never queued
unbounded.

## 5. Text, and the marquee (the early ask)

`setText(lcd, row, text)` is wanted first. Behavior:

- Row 0 rejects text (bar-only) → returns an error/no-op with a diagnostic.
- `text.count <= 8` → static, centered/left per alignment, no animation.
- `text.count > 8` → the cell is registered as a **marquee** with the clock; the reconciler
  renders the visible 8-char window each tick.

`TextOverflow` is the policy knob, reusable everywhere text appears:

```swift
public enum TextOverflow {
    case clip                                   // hard truncate to 8
    case ellipsis                               // "FILTERCU…"
    case fit                                    // abbreviate via a substitution table
    case marquee(speed: Double = 6,             // chars/sec
                 gap: Int = 3,                   // blank cells between wrap repeats
                 style: MarqueeStyle = .wrap,    // .wrap (loop) or .pingPong
                 startDelay: Double = 0.8)
}
```

Marquee mechanics: one scroll offset per cell, advanced by the shared clock; `.pingPong`
pauses at both ends; `.wrap` appends `gap` blanks then repeats. Multiple marquees stay in
phase because they share the tick. `CellHandle` lets the caller update or cancel later.

Declarative equivalent (preferred inside screens):

```swift
Label("Resonance Bandpass 24dB", overflow: .marquee(speed: 5))
```

## 6. Declarative `Screen` and components

A screen is a value that maps content onto the surface, plus input bindings. A result-builder
DSL keeps it readable.

```swift
struct MixerScreen: Screen {
    @Bound var tracks: [Track]

    var body: some SurfaceContent {
        Displays {                              // one cell per LCD, index 0…8
            for (i, t) in tracks.prefix(8).enumerated() {
                Cell(i) {
                    Bar(t.level)                // row 0
                    Label(t.name, overflow: .marquee())  // row 1
                    Value(t.volumeDB, format: .decibel)  // row 2
                }
            }
            Cell(8) { Label("MIX"); Value(tracks.count) }
        }
        Lamps {
            Lamp(.play, on: transport.isPlaying)
            Lamp(.rec,  on: transport.isRecording, blink: true)
        }
        KeyColors { scale(root: .c, .minorPentatonic, color: .teal) }
    }
}
```

Component catalog (all value types, all overflow/format-aware):

- `Label(text, align:, overflow:)`
- `Value(number, format:)` — formatters: `.decibel`, `.percent`, `.hertz`, `.noteName`,
  `.time`, `.integer`, custom.
- `Bar(value)` (row 0) and `Meter(level, peakHold:)` (animated ballistics).
- `Glyph(index)` / `GlyphRow(indices)` — direct 16-segment access (the glyph table the
  docs already render).
- `Cell(displayIndex) { … }` — composes the three rows of one LCD.
- `Lamp(button, on:color:blink:)` — button LED.
- `KeyColors { … }` — light-guide layer (see §9).

Screens compose; overlays stack on top (e.g. a transient "value popup" when an encoder is
turned). The active screen is re-evaluated when its `@Bound` state changes, à la SwiftUI.

## 7. Parameter abstraction

The single most reusable abstraction, generalizing `EncoderDemoRange` + adaptive stepping
from the TestUI.

```swift
public struct Parameter<Value> {
    public var name: String
    public var value: Value
    public var range: ParameterRange<Value>     // continuous, stepped, or enumerated
    public var unit: Unit
    public var format: ValueFormat
    public var stepping: Stepping = .adaptive    // velocity-sensitive (already prototyped)
    public var onChange: (Value) -> Void
}
```

- **`ParameterPage`** binds up to 8 parameters to the 8 encoders and renders each as a
  `Cell` (bar on row 0, name on row 1, value on row 2). Encoder turn → adaptive step →
  `onChange`. Encoder *touch* → momentarily show fine value / highlight. Two-way: when the
  app mutates `value`, the cell refreshes.
- **`ParameterBank`** holds several pages; page-left / page-right buttons switch pages; a
  header (the 9th display, or a brief overlay) shows `page n/N`. This is exactly the
  velocity/page navigation the TestUI fakes today, made first-class.

## 8. Transport abstraction

Semantic transport, decoupled from button names and LED values.

```swift
public struct Transport {
    public var isPlaying = false
    public var isRecording = false
    public var loopEnabled = false
    public var tempo: Double?

    public var onPlay, onStop, onRecord, onLoop, onRewind, onFastForward: (() -> Void)?
    // gestures: hold-stop → return to zero, double-play → restart, etc.
}
```

The middleware maps these to the hardware transport buttons and **reflects host state on the
LEDs** (playing → play lit; recording → rec blinking; loop → loop lit). Apps set state; they
do not touch LED values. Tap/hold/double-tap come from the gesture recognizer (§10).

## 9. KeyBed / light-guide abstraction

A layered model over the 25-key RGB guide, composing renderers:

```swift
public struct KeyBed {
    public func scale(root: Note, _ scale: Scale, color: KKRGB) -> KeyLayer
    public func chord(_ notes: [Note], color: KKRGB) -> KeyLayer
    public func playedNotes(color: KKRGB, fade: Duration) -> KeyLayer   // MIDI-driven
    public func gradient(_ stops: [KKRGB]) -> KeyLayer
    public func custom(_ map: (Int) -> KKRGB?) -> KeyLayer
}
```

Layers stack (base scale tint + played-note override, the TestUI's note feedback being the
`playedNotes` case). Octave/transpose buttons shift the mapping. This is the natural home for
Synthesia-style and scale-trainer use cases.

## 10. Input: semantics, gestures, routing

Raw `KKInputEvent` is normalized into high-level events:

```swift
enum SurfaceInput {
    case encoder(index: Int, steps: Int, velocity: Double, touching: Bool)
    case mainEncoder(.turn(Int) | .press | .release)
    case button(Button, phase: .down | .up | .tap | .hold | .doubleTap)
    case strip(.pitch | .mod, value: Double, touching: Bool)
}
```

- A **gesture recognizer** derives tap vs hold (threshold) and double-tap (window) from
  `button(name:pressed:)` transitions.
- **Velocity** is computed from inter-event timing (the TestUI's `elapsed`-based stepping),
  exposed once, centrally.
- **Routing**: events go to the focused screen's bindings first, then bubble to global
  handlers (transport, navigation). Encoder/strip touch is available for "show-on-touch" UX.

## 11. Remote-control framing (the inspiration)

The surface model is host-agnostic. A thin **abstract host model** sits between adapters and
screens:

```swift
struct ControlModel {
    var tracks: [Track]            // name, level, pan, mute/solo, color
    var parameters: [Parameter]    // focused device / plugin params
    var transport: TransportState  // play/rec/loop/tempo/position
    var time: MusicalTime          // bars·beats / SMPTE for a display
}
```

Adapters fill this model and translate surface input back out:

- **MCU / HUI emulation** over a virtual MIDI port — the highest-leverage backend. Most DAWs
  (Logic, Live, Cubase, Studio One, Reaper, Pro Tools-ish) already speak Mackie Control: 8
  encoders → channel pan/params, transport → MCU transport, the 9 displays → MCU scribble
  strips (with our marquee for long names), `Meter` → MCU meter data. Ship this and the S25
  becomes a working control surface for nearly everything, with zero per-app work.
- **OSC** — generic backend for apps that expose OSC (or a companion plugin).
- **Native SDKs** — per-app where richer integration exists.

Because adapters only touch `ControlModel`, the same screens work across every backend, and
the keybed can stay an instrument (MIDI out) while the surface acts as remote — merging the
"controller" and "control surface" roles the hardware was built for.

## 12. Decisions

- **Module / naming.** `KontrolSurfaceKit`.
- **Reactivity.** Support **both** a declarative path (`Screen` / `show`, with a SwiftUI-style
  result-builder DSL to follow) and the imperative setters.
- **Clock source.** `DispatchSourceTimer` (lowest, most predictable wake-up latency), 60 Hz,
  dirty-only flush at row granularity.
- **Display 0 role.** Reserved as the **status display**: global status line plus page
  indicator (`setStatus` / `setPage`). The other eight are content displays.
- **Concurrency.** `Surface` is its **own actor**; the clock and device callbacks hop onto it.

## 13. Suggested build order

1. **Core skeleton**: `Surface`, shadow state + reconciler, clock, batched flush. Prove it by
   reimplementing a trivial static screen through reconciliation.
2. **`setText` + `TextOverflow.marquee`** — the explicitly-requested early win; needs only
   core + clock.
3. **Components + `Screen` DSL** (`Cell`, `Label`, `Value`, `Bar`, `Lamp`).
4. **Input normalization + gestures**, then **`Transport`**.
5. **`Parameter` / `ParameterPage` / `ParameterBank`** (port the TestUI stepping).
6. **`KeyBed`** layers (port note feedback; add scales).
7. **`ControlModel` + MCU/HUI adapter** — the remote-control payoff.

Step 2 is independently shippable and is the recommended first milestone.

## 14. Implementation status

**Milestone 1 (steps 1–2) is implemented** as the `KontrolSurfaceKit` target:

- `Surface` actor with lifecycle (`start` / `stop`) and a `DispatchSourceTimer` clock.
- Row-granular reconciler (`DisplayReconciler`): diffs the rendered 240-byte payload per row
  and sends only changed rows via `sendDisplayRowAsync`.
- `setText` with `TextOverflow` (`clip` / `ellipsis` / `fit` / `marquee` in `wrap` and
  `pingPong` styles), plus `setGlyphs`, `setBar`, and coalesced `setKey` / `setButtonLED`.
- Display 0 status API (`setStatus`, `setPage`).
- Both styles: imperative setters and a declarative `Screen` / `present` / `show` path.
- `SurfaceDemo` executable (baseline `KontrolProbe` left untouched).

Next: the result-builder `Screen` DSL and components (step 3), then input/gestures and
`Transport` (step 4).
