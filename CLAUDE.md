# CompleteControl Agent Handover

CompleteControl is the hardware and middleware stack for Native Instruments
Komplete Kontrol S49/S61/S88 MK2 keyboards and MASCHINE MK3, including a
single-device simulator profile for each family.
The repository no longer contains a legacy-generation driver, middleware
target, daemon branch, diagnostic tool, or device descriptor.

## Documentation Policy

`Docs/Komplete-Kontrol-Protocol-Guide.md` is the canonical hardware protocol
reference. Bench-verified protocol findings must be added there in the same
change as the implementation. Keep `README.md` user-facing and
`Docs/Backlog.md` limited to deferred work.

## Products

| Product | Purpose |
| --- | --- |
| `KompleteKontrol` | Protocol types, input decoding, daemon clients, and `ccd` server implementation |
| `KontrolUSB` | Persistent profile-driven libusb session and USB endpoint handling |
| `KontrolSimulatorWire` | Foundation-only versioned simulator descriptor and bounded frame codec |
| `KontrolSimulatorCore` | Headless virtual-device definitions, native MK3 gesture synthesis, output reduction, and calibrated geometry |
| `KontrolSurfaceKit2` | Declarative two-screen surface middleware |
| `PaulincheSurfaceKit` | Paulinche-specific Kit2 renderers |
| `ccd` | Privileged hardware/simulator daemon |
| `MK2SurfaceDemo` | Compact hardware feature demo |
| `widget-lab` | Device-independent Kit2 demo browser (Calibration, Look & Feel, Kit Catalogue, Diagnostics): per-file `LabDemo`s, snapshot harness, LED/light-guide REPL |
| `KontrolSimulator` | Profile-driven S61 MK2/MASCHINE MK3 panel and simulator-daemon host |
| `MK2USBSpy` | Direct descriptor/input diagnostic with safe per-interface MK3 capture |

## Build And Test

```bash
swift build
swift test
swift build -c release --product ccd
swift build --product KontrolSimulator
swift test --filter SimulatorCoreTests
```

For a reusable Kit2 API, also realize it in `widget-lab` and add focused
or snapshot coverage. The simulator should remain wire-compatible with the
hardware daemon.

Validation is change-scoped. During implementation, use the narrowest build,
focused test, snapshot, harness, simulator flow, or hardware smoke that can fail
because of the change. Run daemon, USB, protocol, display, simulator, and
real-device smokes only when their corresponding subsystem is affected; their
existence does not make them mandatory for unrelated work. Documentation- and
agent-rule-only changes require diff and command review, not product builds or
smokes.

Run typography or text-rendering smokes only after changes to rendered
user-facing copy, localization, presentation formatting, font metrics, or text
layout. Apply microtypography only to rendered user-facing text and deliberately
published end-user content. In implementation source, comments, doc comments,
logs, test diagnostics, identifiers, protocol strings, file names, and
machine-readable data, use ordinary spaces and plain developer punctuation;
never paste literal `U+00A0` or `U+202F` characters there. If source must emit
one for user-facing output, use localization, a presentation formatter, or
visible Unicode escape syntax instead of an invisible literal.

Unless release, integration, broad shared-contract work, an explicit user
request, or full-suite-only diagnosis requires otherwise, run the broad
all-target/full suite at most once per local calendar day at the end of the
substantive working session. A passing result covers only the revision and
worktree state it actually tested; later changes still need focused validation.

## Daemon

The normal hardware daemon is `ccd --kk-libusb-daemon [socket-path]`. It owns
one persistent profile-driven libusb session and exposes independent control,
event, and display channels to clients.

Adaptive MK2 display encoding is the production default. The device-session
backend owns its successfully-written framebuffer shadow and chooses the smallest
single-transfer literal/repeat/skip packet. Keep
`KK_MK2_DISPLAY_ENCODING=legacy` as the byte-for-byte fail-safe override; invalid
explicit values must continue to select that safe path.

Key invariants:

- keep libusb callback work small and never perform display/state output directly
  inside a completion callback;
- synchronous output may dispatch async callbacks reentrantly, so pending output
  drains must re-check state after writes;
- keep display blits and small state reports on separate serial queues;
- session lifetime, reconnect, poll-fd registration, sleep/wake, and shutdown have
  one owner;
- a reconnect must fully re-register poll fds rather than diff against what was
  previously tracked: closing the old session's fds makes kqueue silently drop
  their registrations, and the OS is likely to hand the new session the same fd
  numbers back, so a stale diff sees "no change" and leaves input dead — see
  `Docs/daemon-usb-reactor.md`;
- on shutdown, restore MK2 mapping-engine standalone mode or clear MK3-owned
  lights, then clear host-owned displays;
- only S49/S61/S88 MK2 and MASCHINE MK3 product IDs may be opened by
  `KontrolUSB`;
- MASCHINE MK3 may claim only HID interface 4 and display interface 5; never
  claim or detach its audio interfaces 0-2, MIDI interface 3, or DFU interface 6.

Read `Docs/daemon-usb-reactor.md` before changing scheduling.

Debug logging: `make daemon-debug` traces live to stderr; `make daemon-debug-trace`
runs the daemon as a flight recorder — `KKStderrLog` buffers formatted TRACE lines
in an in-RAM ring (`KK_LOG_RING=<seconds>`, Makefile default `DAEMON_RING_KEEP=30`)
and writes to `DAEMON_TRACE_LOG` only on flush: `sudo pkill -USR1 -f kk-libusb-daemon`,
or automatically when an error-level line is logged. Use the flight recorder for
timing-sensitive investigations (log I/O perturbs USB/display timing and can hide
the bug); reproduce first, then flush — flushing clears the ring.
`DAEMON_RING_KEEP=0 make daemon-debug-trace` restores direct live tracing. The ring
lives in `KKStderrLog` (KompleteKontrol.swift) with state confined to its serial
log queue; it deliberately has no CornucopiaCore dependency.

`Scripts/kk-screenshot.py` (also available as the `/kk-screen` skill) grabs
live PNGs of both hardware screens from the
running daemon (hardware or simulator) and prints the file paths. It is
out-of-band: it reads the daemon's display shadow over an unregistered control
connection (`displaySnapshot`), so it never evicts, stalls, or otherwise
disturbs the connected client. The shadow is recorded at the
`KontrolDeviceSession` seam, so all display paths are mirrored.

The NO CLIENT mode is an active hardware test. Surface controls drive their
lamps, MIDI keys drive the light guide, and both displays show decoded and raw
activity. It is also the stress case for MIDI chord release and callback
reentrancy.

For MASCHINE MK3, NO CLIENT shows semantic events plus raw evidence and mirrors
bench-verified buttons, pads, and ribbon input to their LEDs. The exact pad
record-slot-3 triplet `0d 40 00` is a neutral sentinel, not a Pad 13 release,
but slot 3 can also carry live or stale pad pressure. Reconcile each report per
pad: active contact wins over a trailing zero, while explicit release wins over
trailing positive pressure except for the verified Pad 14 slot-4 firmware
shadow. A frozen positive-pressure slot can also keep repeating verbatim after
a pad's explicit release (verified Pad 12 slot-2, 2026-07-20); the tracker
snapshots that value at release time and ignores identical pressure-only
re-onsets until a real marker or a differing value arrives, so the phantom
cannot re-trigger and hang the pad. Pad input distinguishes below-trigger
touch, a 12-bit strike word,
12-bit held-pressure words, and explicit touch/strike release markers. Pad
hardware indices 0-15 map directly to `0x81` payload offsets 25-40. Use
`make maschine-mk3-probe` for a read-only descriptor dump and
`make maschine-mk3-input-spy` for an explicitly bounded HID-interface capture.

## MK2 Protocol Essentials

- VID `0x17cc`; PIDs `0x1610`, `0x1620`, `0x1630`.
- Bench-verified S61 MK2 unit revision `bcdDevice 0x0060` (firmware 0.6.0);
  this is the simulator's default MK2 identity.
- Host-control mode: report `0xA0`, payload `00 10`.
- Mapping-engine standalone mode: `0xA0 93 00`, templates `0xA1`/`0xA2`,
  commit `0xAF 00 02`.
- Surface snapshot: report `0x01`.
- Raw ribbon: report `0x02`.
- Button and ribbon palette LEDs: report `0x80`.
- Light guide: report `0x81`.
- Displays: report/framing `0x84` over bulk OUT, RGB565 big-endian.
- Keybed, aftertouch, pitch, and modulation arrive through USB-MIDI.

Do not infer mappings from similar devices. Record captures, hardware model, and
firmware context for new findings.

## MASCHINE MK3 Protocol Essentials

- VID/PID `0x17cc:0x1600`; bench unit revision `bcdDevice 0x0146`.
- HID surface: interface 4, interrupt OUT `0x03`, interrupt IN `0x83`.
- Displays: interface 5, bulk OUT `0x04`, two 480x272 RGB565 panels.
- Surface input `0x01`: 42 bytes total; pad input `0x02`: 64 bytes total.
- Button/pad LED output `0x80`: 62-byte payload; touch-strip output `0x81`:
  41-byte payload.
- Pad input matrix is bottom-up by row: indices 12-15 are Pads 1-4 and indices
  0-3 are Pads 13-16; pad LED payload offsets are the direct index plus 25.
- Keep LED/state writes on the state-report queue, independent from MK3 OLED
  transfers; full MK3 display frames take tens of milliseconds and must not gate
  feel-critical output.
- Audio interfaces 0-2, MIDI interface 3, and DFU interface 6 stay unclaimed.
- Do not reuse MK2 `0xA0` mapping-engine setup or MK2 USB-MIDI claiming on MK3.

## KontrolSurfaceKit2

Applications should express hardware output as `MK2SurfaceScene2` state and
semantic bindings. Keep application-specific state outside Kit2; Paulinche
integration belongs behind the narrow `PaulincheSurfaceKit` adapter.

`MK2Surface2` is also the compatibility runtime for MASCHINE MK3. It selects
the native device adapter from `KKDeviceInfo`, while existing scenes retain the
current MK2-named semantic vocabulary. Keep input lowering and reverse lamp
mapping in the single `SurfaceDeviceCompatibility.swift` mapping table; never
synthesize fake MK2 USB reports and never create a parallel MK3 scene runtime.
Unsupported capabilities such as the MK3 light guide are skipped rather than
treated as connection failures. Pads stay outside the button compatibility map;
their native timed stream is exposed separately and
`KontrolPadMIDISynthesizer` lowers accepted strikes, held pressure, and releases
into the same MIDI binding used by the MK2 keybed.

Layout rules:

- left display is typically the dense tracker/pattern view;
- right display is the focused edit surface;
- encoder-bound values use the canonical bottom-flush encoder slots;
- E5–E8 are the bottom-flush value encoders (parameter page cells); E1–E4 are
  the top-flush channel encoders in the tracker pattern scene — touch selects
  the channel directly, rotation moves the cursor row (same axis as the 4-D
  wheel). E1–E4 carry no value cells; they share the top-flush zone with the
  function-key bar but are encoder-touch/rotation only;
- function-button actions use `MK2FunctionKeyBarElement`: top-flush under the
  physical F-buttons, slots on the same uniform grid as the encoder cells,
  and the element owns both drawing and the F1–F4/F5–F8 press bindings;
- scene-owned structural command planes use `MK2HoldCommandBarElement`: it
  pre-composites a 90-row F1-F8 header and centered, two-line quick help over
  copies of the base frames, dims the remaining scene body to half brightness,
  and owns all F-key presses and lamps while held. A layer is eligible only if
  it existed in the active scene at button-down time. See
  `Docs/Held-Command-Bar.md`. HIG terminology is semantic: this is a command
  popup whose selection immediately performs an action;
- persistent settings use `MK2HoldActionOverlayElement`, a setting popup whose
  selected value remains active after release and is shown again on the next
  hold. Do not choose between the two popup forms based only on screen space;
- passive prompts use `MK2PopupOverlayElement`: it preserves the current scene's
  lamps and bindings, dims each targeted OLED background to half RGB565
  brightness, then composites a stable popup card on the left display, right
  display, or both. Clients own the prompt lifecycle and supply only semantic
  left/right content;
- hardware labels must describe the action/value directly above the physical
  control they belong to;
- pixel display diffs must preserve deterministic rendering and stable geometry.

Interaction and rendering rules:

- `MK2HIG.Waveform` mirrors the Paulinche app's `Design.Waveform` /
  `Design.Accent` tokens (PaulincheApp/EditorDesign.swift) quantized to
  RGB565 — change both sides together so hardware and app render sample
  material in one identity;
- encoder-bound discrete values never wrap on tiny domains (on/off, few
  modes); `MK2EncoderDiscreteValue` enforces the clamp below
  `wrapMinimumValueCount`;
- discrete values scale their throw to the domain: counts-per-step derives
  from the domain size (`targetSweepCounts` full sweep, clamped to
  `maximumCountsPerStep`), so a three-way mode is not swept in two raw
  counts; override per value via `countsPerStep` — never re-derive raw
  1:1 count mapping in a client;
- `MK2EncoderBindingElement` and `MK2InputBindings2.encoder` are deprecated
  because their neutral names made raw 1:1 encoder handling too easy.
  Value-bearing controls use `MK2EncoderDiscreteValueElement`. The explicitly
  named `MK2RawEncoderBindingElement` and `rawEncoder` dictionary are escape
  hatches only for a documented client-side span-aware scaler, genuine
  non-value action, or hardware diagnostic; every use must state that reason
  at the call site;
- encoder double-touch is the "back to default" gesture: declare
  `MK2EncoderDiscreteValue.defaultValue` for value slots (silent when already
  at default); the raw `MK2RawEncoderBindingElement.onDoubleTouch` hook is for
  actions beyond a reset — never bind double-touch to something destructive;
- value-cell and filter-cell labels name the *parameter/unit/filter*, never
  the encoder — the physical encoder above the cell is identified by position
  (so no `E<n>` prefix in the label). An optional Phosphor label-line icon
  (`MK2ValueCell.iconGlyph`, `MK2SelectionFilter.iconGlyph`; curated glyphs in
  `MK2HIG.IconGlyph`, grown on demand from `PhosphorIcons.regular.json`)
  carries the semantics; it renders in its own tint (`MK2ValueCellColors.icon`,
  defaults to a lightened label color), never in the label color. Choose one
  icon position (leading/trailing) per screen — never mix. Paulinche
  parameters carry a semantic `SurfaceParameterIcon`; the adapter maps it to
  the glyph;
- gradients must render dithered (`MK2OrderedDither`, or the gradient tile
  cache via `fillRoundedVerticalGradient`) — per-row/column RGB565 lerps band
  visibly on the OLEDs;
- the encoder/filter footer height derives from its content
  (`MK2ScreenLayout.encoderFooterHeight`); do not reintroduce fixed literals;
- SHIFT is the only first-class modifier and is scene-owned: screens declare a
  shift layer in the DSL (`MK2ShiftBranch`, `MK2FunctionKeyBarElement`
  `shiftSlots`/`onShiftPress`, `MK2ParameterPageElement.shiftSlots`); never
  re-present scenes on shift transitions or hand-roll chord handling.
  `MK2SurfaceScene2.ShiftLayer.buttonPolicy` chooses `.fallback` (the
  compatibility default: layer button bindings/lamps override the base) or
  `.exclusive` (only layer buttons/lamps remain active; every intended
  passthrough must be repeated explicitly in both bindings and lamps). Display
  fallback and continuous-control fallback remain independent: a nil shift
  frame keeps the base OLED visible, and unmodified encoders/jog/strip remain
  available unless the layer replaces them. Shift
  reveals rarer alternates related to the base action in the same physical
  slot (base CUT → shift TRIM); it never relocates a frequent action.
  Shift-layer function labels render in `MK2HIG.Chrome.shiftAccent`; the shift
  button lamp is automatic (dim = layer available, bright = held) unless a
  scene sets it explicitly. Shift is momentary, never latching.

- encoder touch selection is runtime-owned: encoder-bound `MK2ParameterPageSlot`s
  capture a prepared touch overlay (`MK2EncoderSelectionBehavior`, default
  `.momentary`; `.latched` keeps the last-touched slot; `.none` opts out) and
  the surface flips the highlight locally on touch events — never rebuild the
  app-side `.encoderTouch` → state → `isFocused` round trip per scene. Touched
  and focused render identically (the `focused*` ValueCell tokens), so an app
  confirming a touch via `isFocused` causes no visible change. Overlays are
  suppressed while the shift layer is held.

Typography uses FreeType/HarfBuzz for proportional UI and fixed-pitch rendering
for tracker/grid content. Keep repeated text in the glyph/run caches.

## Simulator

`KontrolSimulator` is one executable with S61 MK2 and MASCHINE MK3 profiles.
`KontrolSimulatorWire` version 2 begins every connection with a bounded,
authoritative descriptor containing product, capabilities, firmware, reported
name, and diagnostic instance ID. MK3 gestures are synthesized as native input
reports by `KontrolSimulatorCore` and pass through the production decoder;
KONTROL retains its compatibility lowering while sharing the same descriptor,
framebuffer, daemon, and client boundary. The daemon selects the virtual device
with `CCD_SIMULATE=<socket>`; unchanged clients use its normal endpoint through
`KK_DAEMON_SOCKET`.

```bash
make run-simulator
make run-mk3-simulator
make widget-lab-sim
```

The default profile is `komplete-kontrol-s61-mk2`; deterministic launches may
pass `--device komplete-kontrol-s61-mk2` or `--device maschine-mk3`. Keep window
frame, zoom mode, and magnification defaults profile-scoped. Connection state
and the model name belong in the fixed window status bar, never in the
magnifiable hardware document. Preserve the MK3 320x301-mm calibrated geometry,
the shared combined click/Command-rotate main encoder, multi-held keyboard pads,
accessibility controls, and the profile keyboard cheat sheet.

The default device and daemon socket paths are still global. `--instance` is
descriptor provenance only; it does not isolate paths or permit two simulator
daemons. Real/simulated mixed operation and simultaneous KONTROL+MASCHINE remain
Phase 5 of `Docs/Maschine-MK3-Simulator-Plan.md`.

For visual acceptance snapshots, set `KONTROLSIM_SNAPSHOT_PATH`; optional
`KONTROLSIM_SNAPSHOT_SCALE`, `KONTROLSIM_SNAPSHOT_DELAY`, and
`KONTROLSIM_SNAPSHOT_INCLUDE_CHROME=1` select resolution, settle time, and the
full window including the fixed status bar. Snapshot runs must not overwrite
the user's persisted window profiles.

Do not special-case simulator behavior above the `KontrolDeviceSession` seam.
