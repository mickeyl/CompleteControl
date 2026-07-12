# CompleteControl Agent Handover

CompleteControl is the MK2 hardware and middleware stack for Native Instruments
Komplete Kontrol S49/S61/S88 MK2 keyboards. The repository no longer contains a
legacy-generation driver, middleware target, daemon branch, diagnostic tool, or
device descriptor.

## Documentation Policy

`Docs/Komplete-Kontrol-Protocol-Guide.md` is the canonical hardware protocol
reference. Bench-verified protocol findings must be added there in the same
change as the implementation. Keep `README.md` user-facing and
`Docs/Backlog.md` limited to deferred work.

## Products

| Product | Purpose |
| --- | --- |
| `KompleteKontrol` | Protocol types, input decoding, daemon clients, and `ccd` server implementation |
| `KontrolUSB` | Persistent MK2 libusb session and USB endpoint handling |
| `KontrolSurfaceKit2` | Declarative two-screen surface middleware |
| `PaulincheSurfaceKit` | Paulinche-specific Kit2 renderers |
| `ccd` | Privileged hardware/simulator daemon |
| `MK2SurfaceDemo` | Compact hardware feature demo |
| `MK2WidgetLabDemo` | Kit2 demo browser (Calibration, Look & Feel, Kit Catalogue, Diagnostics): per-file `LabDemo`s, snapshot harness, LED/light-guide REPL |
| `KontrolSimulator` | S61 MK2 panel and simulator-daemon host |
| `MK2USBSpy` | Direct descriptor/input diagnostic |

## Build And Test

```bash
swift build
swift test
swift build -c release --product ccd
```

For a reusable Kit2 API, also realize it in `MK2WidgetLabDemo` and add focused
or snapshot coverage. The simulator should remain wire-compatible with the
hardware daemon.

## Daemon

The normal hardware daemon is `ccd --kk-libusb-daemon [socket-path]`. It owns
one persistent MK2 libusb session and exposes independent control, event, and
display channels to clients.

Key invariants:

- keep libusb callback work small and never perform display/state output directly
  inside a completion callback;
- synchronous output may dispatch async callbacks reentrantly, so pending output
  drains must re-check state after writes;
- keep display blits and small state reports on separate serial queues;
- session lifetime, reconnect, poll-fd registration, sleep/wake, and shutdown have
  one owner;
- on shutdown, restore mapping-engine standalone mode and clear host-owned output;
- only S49/S61/S88 MK2 product IDs may be opened by `KontrolUSB`.

Read `Docs/daemon-usb-reactor.md` before changing scheduling.

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

## MK2 Protocol Essentials

- VID `0x17cc`; PIDs `0x1610`, `0x1620`, `0x1630`.
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

## KontrolSurfaceKit2

Applications should express hardware output as `MK2SurfaceScene2` state and
semantic bindings. Keep application-specific state outside Kit2; Paulinche
integration belongs behind the narrow `PaulincheSurfaceKit` adapter.

Layout rules:

- left display is typically the dense tracker/pattern view;
- right display is the focused edit surface;
- encoder-bound values use the canonical bottom-flush encoder slots;
- function-button actions use `MK2FunctionKeyBarElement`: top-flush under the
  physical F-buttons, slots on the same uniform grid as the encoder cells,
  and the element owns both drawing and the F1–F4/F5–F8 press bindings;
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
- encoder double-touch is the "back to default" gesture: declare
  `MK2EncoderDiscreteValue.defaultValue` for value slots (silent when already
  at default); the raw `MK2EncoderBindingElement.onDoubleTouch` hook is for
  actions beyond a reset — never bind double-touch to something destructive;
- value-cell labels name the *parameter or unit*, never the encoder — the
  physical encoder above the cell is identified by position. An optional
  Phosphor label-line icon (`MK2ValueCell.iconGlyph`, curated glyphs in
  `MK2HIG.IconGlyph`) carries the parameter semantics; it renders in its own
  tint (`MK2ValueCellColors.icon`, defaults to a lightened label color),
  never in the label color. Choose one icon position (leading/trailing) per
  screen — never mix. Paulinche parameters carry a semantic
  `SurfaceParameterIcon`; the adapter maps it to the glyph;
- gradients must render dithered (`MK2OrderedDither`, or the gradient tile
  cache via `fillRoundedVerticalGradient`) — per-row/column RGB565 lerps band
  visibly on the OLEDs;
- the encoder/filter footer height derives from its content
  (`MK2ScreenLayout.encoderFooterHeight`); do not reintroduce fixed literals;
- SHIFT is the only first-class modifier and is scene-owned: screens declare a
  shift layer in the DSL (`MK2ShiftBranch`, `MK2FunctionKeyBarElement`
  `shiftSlots`/`onShiftPress`, `MK2ParameterPageElement.shiftSlots`); never
  re-present scenes on shift transitions or hand-roll chord handling. While
  held, layer bindings dispatch first with fallback to the base scene. Shift
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

`KontrolSimulator` emulates an S61 MK2 and communicates through
`SimWireProtocol`. The daemon selects it with `CCD_SIMULATE=<socket>`; clients
then use the simulator daemon socket through `KK_DAEMON_SOCKET`.

```bash
make run-simulator
make mk2-widget-lab-demo-sim
```

Do not special-case simulator behavior above the `KontrolDeviceSession` seam.
