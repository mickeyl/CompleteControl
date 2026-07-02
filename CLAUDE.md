# CompleteControl — Agent Handover

Swift control library + middleware for the **Native Instruments Komplete Kontrol S25 MK1**.
This file is the working context for an agent picking the project up. Pair it with
`Docs/Middleware-Concept.md` (the full middleware design + implementation status).

## Layout

Two layers, plus a baseline app and a middleware demo:

| Target | Path | Role |
| --- | --- | --- |
| `KompleteKontrol` (lib) | `Sources/KompleteKontrol/` | Low-level driver: USB/daemon transport, surface protocol, display frame, glyph font + names, input/MIDI decoding. |
| `KontrolUSB` (C) | `Sources/KontrolUSB/` | libusb session, async transfers, endpoint discovery. |
| `KontrolSurfaceKit` (lib) | `Sources/KontrolSurfaceKit/` | **The middleware** — declarative `Screen` DSL on top of the driver. Imperative setters are deprecated for client code. |
| `ccd` (exe) | `Tools/ccd/` | Privileged launchd/foreground daemon entry point. Owns USB and transports surface/MIDI events over the socket. |
| `KontrolProbe` (exe) | `Tools/KontrolProbe/` | **Baseline** REPL + AppKit test UI. Leave as-is unless asked. |
| `SurfaceDemo` (exe) | `Tools/SurfaceDemo/` | Console demo exercising every `KontrolSurfaceKit` feature. |

Build / run / test:

```bash
git submodule update --init --recursive Vendor/libusb
swift build                              # all targets
swift build --product KontrolSurfaceKit  # just the kit
swift build --product ccd                # daemon
swift test                               # focused decoder tests
swift run SurfaceDemo                     # needs the daemon + hardware to see output
swift build -c release --product KontrolProbe
```

The daemon owns the USB device; a client connects over a Unix socket. `make help` lists daemon
targets (`make install-daemon`, `make install-debug-daemon`, `make daemon-status`, …).
libusb is vendored as the pinned `Vendor/libusb` submodule and compiled through the `CLibUSB`
SwiftPM C target; do not add Homebrew/pkg-config fallback paths.
`make install-daemon` builds and installs the release `ccd`; `make install-debug-daemon` builds and
installs the debug `ccd` with structured trace logging. While no socket client is connected the
daemon renders its idle diagnostic surface; once a client connects, the client owns all surface
rendering until the last socket disconnects. The hardware in this workspace is reachable through a
running daemon.

### Daemon idle diagnostics

When no socket client is connected, `ccd` owns the hardware surface:

- LCDs show `NO CLIENT`, the running git revision (`REV <rev-list count>` plus short hash; a `+`
  marks a dirty/uncommitted build), and an initial surface/MIDI test prompt.
- Surface input is decoded and acknowledged on the LCDs.
- USB-MIDI input is decoded and acknowledged on the LCDs.
- Pressed MIDI keys light the corresponding light-guide key; note-off clears it.

The revision is embedded at SwiftPM build time by the `GenerateBuildInfo` build-tool plugin. Keep
that plugin attached to the `KompleteKontrol` target; the installed `/usr/local/bin/ccd` should not
need runtime access to the checkout or `.git` directory to show its revision.

Do not write LCDs/light-guide directly from libusb completion callbacks. Callback paths should
update daemon state and set a pending flush flag; the kqueue reactor flushes the idle diagnostic
after `handle_events`. Writing from inside the callback can fail with libusb status `-6` and leave
the LCDs visually stale even though input was received.

### Verifying without seeing the hardware

You usually can't see the LCDs/LEDs. What works:
- `swift build` then run `SurfaceDemo` backgrounded for ~3s and check it stays alive + exits
  clean on SIGINT (it blanks displays on `stop()`).
- For idle daemon diagnostics, install the debug daemon, make sure no client such as Paulinche or
  SurfaceDemo is connected, and verify the hardware shows `NO CLIENT` plus a `REV` cell. Then press
  a surface control and a MIDI key and inspect `/tmp/media.vanille.kompletekontrol-libusb.stderr.log`
  for `push surface` / `push midi` if the hardware display is not visible.
- `print` is **block-buffered** to a pipe — output only appears after exit/flush.
- For the docs SVGs there are Python generators in scratch; render with `rsvg-convert` and Read
  the PNG to inspect visually.

## KontrolSurfaceKit architecture

`Surface` is an **actor**. A single `DispatchSourceTimer` clock (`SurfaceClock`, 60 Hz, chosen
for lowest wake-up latency) drives a reconcile tick. Three reconcilers hold *intended* state and
diff against *last sent*, so unchanged content produces **no USB traffic**:

- `DisplayReconciler` — 9 displays × 3 rows. Diffs at **row granularity** (one USB report = one
  row across all 9 displays). Owns marquee + spinner animation.
- `LEDReconciler` — per-button-LED `LampState` (`off`/`on`/`blink`/`pulse`), animated on the clock.
- `KeyReconciler` — the 25 RGB light-guide keys; one guide report when any key changes.

Input: `device.onInputReport` → `Surface.handleInput` (Task hop onto the actor). MIDI:
`device.onMIDIEvent` → `Surface.midi` (`AsyncStream<KKMIDIEvent>`). Normalized surface events go
out on `Surface.inputs` (`AsyncStream<SurfaceInput>`); gestures are also dispatched to
declarative handlers (below). Connection lifecycle goes out on
`Surface.connectionStates` (`AsyncStream<SurfaceConnectionState>`); clients should show `.retrying`
without disabling their app workflow. Once connected, the surface avoids periodic socket probes and
keeps the established daemon session hot.

### Declarative first — imperative deprecated

Everything lowers to **`SurfaceModel`** (cells + lamps + keys + input handlers). The
declarative `Screen` DSL is the supported client-facing API. The imperative setters still
target the same model, but they are deprecated for application workflows and should be used
only for diagnostics, legacy tools, and short migration shims:

- **Declarative DSL**: a `Screen` has `@ScreenBuilder var body: [any ScreenElement]`.
  `present(screen)` lowers + reconciles; `observe { screen }` re-lowers under
  `withObservationTracking` whenever an `@Observable` the screen read changes (a generation token
  cancels it when something else takes over).
- **Deprecated imperative escape hatch**: `setText/setBar/setGlyphs/setSpinner/setLamp/setKey/
  setStatus/setPage`, plus `setParameterPage`/`setParameterBank`. Do not add new product
  integrations against this path unless the work is explicitly diagnostic or transitional.

DSL elements:
- Cell content: `Cell(n) { Bar(_); Label(_, overflow:); Value(_, format:); Glyphs(_); Spinner(...) }`
  — `Bar` is row 0, the rest fill text rows 1→2 in order.
- Screen-level: `Status(_)` and `PageIndicator(_, of:)` (both target display 0), `Lamp(led, state)`,
  `KeyColors { keyIndex in color? }`, `MainEncoder { delta in }`.
- **Input handlers** attach while lowering: `Cell(n).onEncoder { delta }` (rotary above display n),
  `Lamp(led).onTap/.onHold/.onSecondary { modifier in }`, `MainEncoder { delta }`. The surface
  stores the latest handler set per render and dispatches input to it → with `observe`, a gesture
  mutates the `@Observable` model and the screen re-renders. A screen is fully self-contained
  (display + LED + key + behaviour in one `body`).

**Merge vs redefine on apply**: displays and **keys are redefined** (unset → cleared); **lamps
are merged** (only declared LEDs change, so transport/cross-cutting LEDs survive). `cancelObservation`
(called by every screen takeover: present/observe/setParameterPage/setParameterBank/clearAll/
show/stop) resets handlers + clears keys so nothing leaks between screens. Prefer `present` and
`observe`; `show` is part of the deprecated imperative escape hatch.

### Higher-level pieces
- `Parameter` (value, range, `sensitivity`, `ValueFormat`, `onChange`) + `ParameterPage` (8 params
  → 8 encoders → displays 1–8, title on display 0) + `ParameterBank` (paged set; `bankNext/Previous`).
- `TransportState` + `updateTransport` reflect transport state on LEDs for legacy imperative users;
  product code should do transport reactively via a `Screen`.
- `GestureRecognizer`: `tap` (immediate on release), `hold`, `secondary(modifier:)` (tap while
  another button held — the held one is the modifier, consumed so it doesn't also tap). **No
  double-tap** — express repeats via state. `SurfaceInput.gesture` carries these.

## Hardware quirks that bit us (don't relearn the hard way)

- **Rotary encoders are 1-based**: the decoder emits `rotaryEncoder(index: 1…8)` (and touch 1…8).
  `ParameterPage` maps encoder *e* → slot *e-1* → display *e*. `Cell(n).onEncoder` binds encoder *n*.
- **Rotaries are high-resolution** (10-bit value, many counts per small turn). Naïve `value += delta`
  is far too fast. `ParameterPage` uses a range-relative base step (`span/900` at slow speed) ×
  linear delta × gentle accel (1×/3×/5× by inter-report interval). `Parameter.sensitivity` is a
  per-param multiplier. The main 4-D wheel (`mainEncoder`, byte-wrapping) is likely detented (≈1/detent);
  confirm on hardware — if not, accumulate counts → row steps.
- **9 displays, 8 encoders**: display 0 is the status display by convention (`setStatus`/`setPage`).
- **Display row 0 is the bar only**; rows 1–2 are text/glyphs (8 chars, 16-segment).
- **Glyphs**: CP437 16-seg font in `KKDisplayFrame.font16Segment` (129 entries: 0–127 + cabl extra
  at 128). Names verbatim from cabl `FONT_16-seg.h` via `KKDisplayFrame.glyphName(at:)`. 8×16 = all
  128 of 0–127 fit across displays 1–8.
- **Light-guide base note ≈ 48** (key index = MIDI note − 48; 25 keys, C→C).
- LED brightness is single-channel 0–0x7f (blink/pulse are synthesized on the clock).
- libusb output from callback context is fragile. For daemon-owned idle UI, schedule a flush from
  the reactor rather than writing synchronously in `pushInputToClients` / `pushMidiToClients`.

## MK2 (S49/S61/S88) essentials — don't relearn these either

Full protocol findings live in `Docs/MK2-Porting-Plan.md` §2; the bench hardware is an S61 MK2.
The short version:

- Surface HID input report `0x01` (buttons/encoders/wheels/4-D) streams unconditionally. The
  analog controls (wheels, **touch strip**, pedals) and any knob/button **MIDI** go through an
  **onboard mapping engine**: enable with `0xA0 93 00` (`0xA0 00 00` leaves it off — this was
  the "dead ribbon" bug), configure via template reports `0xA1` (buttons+knobs), `0xA2`
  (wheels+strip), `0xA3` (pedals), `0xA4` (keyzones), then `0xAF 00 02`.
- Engine-on also wakes the factory rotary template (CC14–21); `ccd`'s `enableMK2MappingEngine`
  writes an all-zero `0xA1` to keep the MIDI stream clean, plus the default `0xA2`
  (strip = CC11 unipolar) at bring-up and reconnect.
- Strip modes via `KompleteKontrolMK2Protocol.AnalogAssignment`: `.cc` = unipolar (holds value,
  LEDs fill from left), `.pitchBend` = bipolar 14-bit (springs back to center, LEDs fan from
  center, `decay` 0–8). Runtime switch: `KompleteKontrolSSeriesMK2.configureAnalogControls`.
  Strip LEDs are firmware-animated — no per-LED writes exist or are needed.
- Engine output arrives as USB-MIDI on EP `0x81` and mirrors in HID report `0xAA` (51 bytes:
  knobs at `17+2i`, pitch wheel u16le at 33/34, strip CC at 37). `A0 00 10` (per jnlive)
  instead streams the strip *raw* on HID report `0x02` (i32le at bytes 5–8, `100000 +
  position`, below 100000 = release). The full HID report descriptor is readable without
  claiming the device: `ioreg -l` → `ReportDescriptor`.
- jnlive (`~/Documents/late/misc/jnlive`, `source/komplete.{h,cpp}`) is the best single
  cross-reference: verified `0x80` LED index map (menu buttons 2–9, octave 42/43?, strip
  44–68) and the span/scatter display command stream — see the porting plan's
  "jnlive cross-check" section.
- Byte layouts are pinned in `Tests/KompleteKontrolTests/MK2AnalogAssignmentTests.swift` —
  changing them means re-benching on hardware.
- **Never write `0xA4` (keyzones) blind** — a malformed zone map silences the keybed and darkens
  the light guide until power cycle; with the engine on, zone state also overrides host `0x81`
  guide writes. Lifecycle: device loss → `sessionDeviceLost` reactor check → drop + timed
  reconnect + re-init + `device reconnected` push (clients re-establish their state); daemon
  shutdown → `restoreMK2StandaloneState` (factory knob CCs, LEDs/guide/displays cleared).
- `Tools/MK2Calibrate` is the protocol workbench (socket client; flows for LED↔button binding,
  encoders, 4-D byte-6 capture, function-button backlights, live monitor; answers via lit
  command keys on the bottom octave). Findings land in `mk2-calibration-session.md`.

## Concurrency notes

The kit target is **Swift language mode v5** (relaxed strict-concurrency). The reactive path shares
an `@Observable` model between the app actor (mutates) and the `Surface` actor (reads during
lowering) — this is warning-not-error in v5 and fine for value-typed state, but is the place to
harden if races appear. `Screen` is intentionally **not** `Sendable` (so it can hold an `@Observable`).

## SurfaceDemo pages (Page Left/Right switch; each realizes APIs)

`parameters` (3-page bank, Preset Up/Down) · `glyphs` (full CP437 map + scrollable name detail,
main wheel) · `activity` (spinners, declarative) · `transport` (declarative+reactive: tap/hold/
secondary on LEDs, encoder 5 → filter, main wheel → row) · `keybed` (declarative `KeyColors`: scale
tint + MIDI played-note feedback).

## Next steps (driven by the client)

First concrete client is **Paulinche**, an Amiga MOD tracker (separate macOS app, links this as a
SwiftPM dep, integrates directly — **MCU/HUI adapter deprioritized**). Core surface = 4-channel
pattern editing: live MIDI record, transport, channel via Navigate ◀▶, instrument via Navigate ▲▼,
exact row via the main wheel; 2 displays/channel, display 0 = status. `PatternScreen` lives in
Paulinche on this kit. Kit work it will pull, in rough priority:

1. **Light-guide is done** (`KeyColors`); may want note→key + scale/chord helpers.
2. **Main-wheel row stepping** — accumulate counts → 1 row/detent if the wheel is high-res.
3. **List/menu navigation** (sample/pattern browsing via 4-D + browse/back/enter).
4. **`Meter` widget** (per-channel VU with ballistics).
5. **Encoder sensitivity as a global + rotary-local modifier** in the DSL — local *factorizes*
   (cumulative, not override) with global. See agent memory `encoder-sensitivity-modifier-plan`.

Cross-session memory (client + plans) lives outside the repo under the project's
`.../memory/` (`paulinche-client`, `encoder-sensitivity-modifier-plan`).

## Conventions

Small, well-named files (one concept each). For every new kit API, realize something in
`SurfaceDemo`. Keep `ccd` as the daemon entry point and `KontrolProbe` as the untouched diagnostic
baseline. When touching daemon input/output behavior, run at least:

```bash
swift build --product ccd
swift build --product KontrolSurfaceKit
swift test
```

Commit messages are plain (no attribution/Co-Authored-By trailers).
