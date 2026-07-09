# CompleteControl — Agent Handover

Swift control library + middleware for the **Native Instruments Komplete Kontrol S25 MK1**.
This file is the working context for an agent picking the project up. Pair it with
`Docs/Middleware-Concept.md` (the full middleware design + implementation status).

## Next Session

Resume from `master`. The MK2 screen-formalization work is active:

- `MK2ScreenDSL` now provides declarative `MK2RegularScreenDSL`, `MK2FullScreenDSL`, and
  `MK2DoubleScreenDSL` builders on top of the formal screen model. Regular screens own
  header/footer chrome from `MK2HIG`; screen elements can contribute pixels, lamps,
  light-guide colors, and input bindings.
- `MK2InputBindings2` supports Shift as the only first-class modifier via
  `.unmodified`/`.shift` button bindings. WidgetLab tracker behavior demonstrates the rule:
  `Clear` clears the selected row immediately; `Shift+Clear` opens the pattern-clear
  confirmation dialog.
- Reusable DSL elements now cover wrapped content text, status lines, value cells,
  encoder footers, selection list/grid wrappers, empty states, progress bars, browser
  detail panes, compact page indicators, tab bars, parameter pages, and meters. WidgetLab
  Browser Lab and Selection Lab now render their regular/detail and picker screens through
  these DSL elements.
- `MK2SelectionInputElement` is the first screen-owned navigation helper: it derives
  4-D jog lamps, direction movement, main-rotary movement, and confirm from
  `MK2SelectionNavigation` plus `MK2SelectionLayout`. WidgetLab Browser Lab and Selection
  Lab merge these `MK2ScreenBuildResult`s into their scene, so their picker navigation
  now comes from the screen instead of demo-local jog glue.
- `MK2EncoderDiscreteValueElement` and `MK2EncoderDiscreteValuesElement` let screens own
  single or grouped discrete encoder bindings. Browser Lab and Selection Lab now attach
  their filter encoder bindings to their picker screen results, leaving only mode switching
  and domain-specific mutation in WidgetLab.
- `MK2ParameterPageElement` renders up to eight parameter slots and applies each slot's
  discrete encoder binding. The WidgetLab tracker detail screen uses it for NOTE/INST/VOL/FX,
  so those edit-field bindings now come from the screen result.
- `MK2MeterElement` renders horizontal or vertical multi-channel levels with peak markers
  and warning/danger colours. WidgetLab Unit C is now implemented as the meter acceptance
  screen.
- Encoder-bound value cells sit in canonical, bottom-flush slots:
  `MK2ScreenLayout.encoderSlotRect(_:)` (x 8/126/244/362, 102×38, 2 px above the glass
  edge) is the one place that knows where a cell above a physical encoder belongs —
  trailing whitespace under an encoder cell breaks the hardware mapping.
  `MK2ParameterPageElement` anchors its slot grid to the bottom of its area (clamped to
  the canonical slot bottom) instead of the top, so oversized areas can no longer push
  whitespace under the cells; selection filter cells align to the same bottom edge.
- `MK2ValueCell` (and everything built on it: parameter pages, encoder footers) draws as
  a debossed well: the border ring runs from a dark shadow rim at the top into a lit
  bottom edge, the fill falls slightly the same way — pressed into the panel, lit from
  above. Both ramps use `MK2PixelFrame.fillRoundedVerticalGradient` (dithered via
  `MK2OrderedDither`, antialiased rounded corners) so they stay band-free on the OLED.
- `MK2SelectionFilterEncoderElement` and `MK2SelectionFilterEncoderBinding` package the
  repeated selection-filter pattern: encoder touch updates filter focus, encoder turns
  update the product filter value. Browser Lab and Selection Lab use it in their picker
  screen results.
- The regular screen layout is now header-aware: `MK2ScreenHeader.none` reclaims the
  38 px band (content starts at the top inset), mirroring how footer `.none` always
  reclaimed its space. `MK2ScreenLayout.regular(header:footer:progress:)` takes the
  chrome enums; geometry-only callers that sit under a real header pass a placeholder
  header (see `MK2SelectionLayout`).
- Regular screens own an optional `MK2ScreenProgressBar` chrome slot (third slot beside
  header/footer): placement `.top` hugs the header's bottom rule (or the screen's top
  edge without a header), `.bottom` hugs the footer's top border (or the screen's bottom
  edge without a footer). A `.top` bar under a header lives in the existing 5 px gap, so
  content does not move. Geometry is pinned in `ScreenLayoutTests`. Chrome typography
  is injectable via `MK2ScreenChromeTypography` (caption + footnote pixel sizes) on the
  chrome and the regular-screen DSL, and the band heights derive from it: header =
  `2 * captionPixelSize + 2` → 32 px at the locked-in caption 15 (plus one caption line
  for a leading subtitle), hint footer = `footnotePixelSize + 12` → 25 px at the
  locked-in footnote 13. The footnote style (`MK2HIG.footnoteTextStyle`, body weight at
  13 px) is a general secondary-text role, not footer-only. Band text sits at geometric
  center minus 2 px — the em box carries more dead space below the caps than above, so
  pure centering looks low. Header and footer share one raised-band look
  (`drawChromeBand`: lit top edge, a subtle vertical fill gradient derived from the
  single fill color — ×1.4 at the top falling to ×0.6 at the bottom, so custom chrome
  palettes keep working — and a black bottom shadow). The chrome is
  deliberately neutral graphite (`MK2HIG.Chrome.headerFill` 0x18e3 matching the
  dialog-surface tone, `headerTopLine` 0x632c) so the yellow accent and content colors
  carry the identity; the rounded `footerFill` panel for chrome footers is gone,
  `footerFill` remains a widget track color. The chrome progress bar is 2 px and fills
  with a deep-blue → cyan gradient across its current width
  (`MK2HIG.Chrome.progressFillStart/End`) — deliberately not the yellow accent.
  WidgetLab unit H ("SCENE LAB", F8) is the acceptance screen: `Instance` cycles the
  header/footer combinations, `E5`-`E8` drive progress placement, progress value, and
  caption/footnote sizes (live band resizing), and the left screen outlines the
  resulting `contentRect`; the Meter Lab overview additionally realizes a `.top`
  progress bar.
- Splash/about screens: `MK2PixelImage` decodes PNG/JPEG (anything ImageIO reads) to a
  display-ready RGB565 bitmap at load time, with `.fill`/`.fit` aspect scaling to the
  target size; `MK2ImageElement` draws it (centered by default) with a `brightness`
  scrim so labels stay readable over artwork. `MK2ContentText` gained
  `alignment: .leading/.center/.trailing` (single-line) and a `.footnote` role. The
  Scene Lab SPLASH combination is the acceptance screen: the double splash spans the
  wave panorama across both screens, `E7` dials the virtual bezel-gap columns (the
  hardware-calibration knob for `defaultBezelGapColumns` — bind tweak cells to the
  encoders physically below their drawn slots: x 244/362 on the right display are
  E7/E8) and `E8` the background brightness. Both accumulate raw deltas immediately
  but coalesce the expensive re-render (panorama regeneration + two full-screen
  draws) to ~4/s with a trailing render, so fast turns cannot queue work behind the
  actor. Decode exactness, scaling, and element behavior are pinned in
  `PixelImageTests`. The production Paulinche splash
  (`MK2PaulincheSplashRenderer`) defaults to the generated wave panorama
  (`MK2PaulincheSplashArtwork.panorama` — gradient + two sine waves spanning both
  displays at uniform brightness, with `defaultBezelGapColumns` virtual columns so
  the waves flow through the physical bezel; 53 is bench-calibrated); identity block
  left, status line right. Explicit single-screen artwork falls back to the
  darker-echo layout. Dark gradients and brightness scrims quantize through
  `MK2OrderedDither` (Bayer 4×4) — flat truncation bands visibly on the OLED once a
  scrim compresses the already-few dark 5/6-bit levels.
- `PaulincheSurfaceKit` is a separate Swift module for Paulinche-shaped renderers on top
  of `KontrolSurfaceKit2`, still without a Paulinche package dependency.
  `MK2PaulinchePatternRenderer` now renders the widget-lab tracker design 1:1: full-bleed
  left grid (bitmap-atlas fonts only — no FreeType in the pattern path), 13 rows à 16 px,
  status line, channel headers with M/S toggle chips, row stripes, playhead/cursor fills,
  pattern-overview minimap, and a full-screen edit pane whose NOTE/INST/VOL/FX page is an
  `MK2ParameterPageElement` with `MK2EncoderBindingElement`s forwarding E5–E8 deltas and
  touches as semantic actions. The fixture model is structured
  (`MK2PaulinchePatternCell/Row/Channel`, `rowActivity`, `isPlaying`, `instrumentLabel`);
  the old preformatted cell strings, the custom 44 px header, and the fake channel
  "meters" are gone. `MK2PaulincheInstrumentRenderer` draws its parameters through
  `MK2ParameterPageElement`, forwards E1–E8 through explicit encoder actions (the old
  no-op `MK2EncoderDiscreteValue` bindings swallowed all encoder input while the
  instrument scene was up), and shows the audition playhead via the `.bottom` progress
  slot instead of parameter meters. Renderers no longer construct a per-render
  `FreeTypeTextRenderer` fallback — the client owns one (the Paulinche adapter creates it
  once and runs the surface at 60 Hz).

Next code stages:

1. Keep broadening fixture/snapshot coverage as new Paulinche scene modes appear, before
   they are consumed by the app (SONG/scope are still unreachable from the mapper).
2. Encoder sensitivity as a global + rotary-local DSL modifier (see agent memory
   `encoder-sensitivity-modifier-plan`); Paulinche currently scales continuous
   instrument parameters app-side with `SurfaceEncoderScaler` (a PaulincheControl port
   of `MK2EncoderScaler`, kept there so Paulinche builds without CompleteControl).

## Layout

Two layers, plus a baseline app and a middleware demo:

| Target | Path | Role |
| --- | --- | --- |
| `KompleteKontrol` (lib) | `Sources/KompleteKontrol/` | Low-level driver: USB/daemon transport, surface protocol, display frame, glyph font + names, input/MIDI decoding. |
| `KontrolUSB` (C) | `Sources/KontrolUSB/` | libusb session, async transfers, endpoint discovery. |
| `KontrolSurfaceKit` (lib) | `Sources/KontrolSurfaceKit/` | **The middleware** — declarative `Screen` DSL on top of the driver. Imperative setters are deprecated for client code. |
| `KontrolSurfaceKit2` (lib) | `Sources/KontrolSurfaceKit2/` | MK2 pixel-display kit: RGB565 frames, bitmap fonts, HarfBuzz-shaped/FreeType-rendered text, widgets, input bindings, display diffing. |
| `CFreeType` (system lib) | `Sources/CFreeType/` | SwiftPM system-library shim for Homebrew/pkg-config `freetype2`; only used by Kit2 FreeType text rendering. |
| `CHarfBuzz` (system lib) | `Sources/CHarfBuzz/` | SwiftPM system-library shim for Homebrew/pkg-config `harfbuzz`; used to shape proportional FreeType text runs. |
| `ccd` (exe) | `Tools/ccd/` | Privileged launchd/foreground daemon entry point. Owns USB and transports surface/MIDI events over the socket. |
| `KontrolProbe` (exe) | `Tools/KontrolProbe/` | **Baseline** REPL + AppKit test UI. Leave as-is unless asked. |
| `SurfaceDemo` (exe) | `Tools/SurfaceDemo/` | Console demo exercising every `KontrolSurfaceKit` feature. |
| `MK2WidgetLabDemo` (exe) | `Tools/MK2WidgetLabDemo/` | Hardware workbench for Kit2 widgets; Unit A contains the FreeType typography/icon/dialog lab, with `Instance` switching sub-demos. |

**Platform floor: macOS 26** (decision 2026-07-02) — the pixel hot paths use Swift 6.2
facilities (`Span.isIdentical`, `InlineArray`); do not lower the deployment target. Hot-path
rules for `KontrolSurfaceKit2`: bulk libc ops (`memset_pattern4`/`memcmp`/`memcpy`) for pixel
work — they keep full speed at `-Onone`, per-element Swift loops do not; frame storage is
wire byte order (blit = memcpy); `MK2PixelFrame` stays copyable on purpose (the reconciler's
O(1) unchanged-frame check is CoW buffer identity). Regressions are caught by
`swift test --filter PixelPipelinePerfTests` (prints stage timings).

Build / run / test:

```bash
git submodule update --init --recursive Vendor/libusb
swift build                              # all targets
swift build --product KontrolSurfaceKit  # just the kit
swift build --product ccd                # daemon
swift build --product MK2WidgetLabDemo   # MK2 widget and FreeType typography workbench
swift test                               # focused decoder tests
swift run SurfaceDemo                     # needs the daemon + hardware to see output
swift build -c release --product KontrolProbe
```

The daemon owns the USB device; a client connects over a Unix socket. `make help` lists daemon
targets (`make install-daemon`, `make install-debug-daemon`, `make daemon-status`, …).
libusb is vendored as the pinned `Vendor/libusb` submodule and compiled through the `CLibUSB`
SwiftPM C target; do not add Homebrew/pkg-config fallback paths.
FreeType and HarfBuzz are the exceptions: `CFreeType` and `CHarfBuzz` are SwiftPM
system-library targets that expect `pkg-config freetype2` and `pkg-config harfbuzz`
(Homebrew `freetype harfbuzz`) for host-side text shaping/rasterization.
`make install-daemon` builds and installs the release `ccd`; `make install-debug-daemon` builds and
installs the debug `ccd` with structured trace logging. While no socket client is connected the
daemon renders its idle diagnostic surface; once a client connects, the client owns all surface
rendering until the last socket disconnects. The hardware in this workspace is reachable through a
running daemon.

### Daemon idle diagnostics

When no socket client is connected, `ccd` owns the hardware surface:

- LCDs show `NO CLIENT`, the running git revision (`REV <rev-list count>` plus short hash; a `+`
  marks a dirty/uncommitted build), and an initial surface/MIDI test prompt.
- Surface input is decoded and acknowledged on the LCDs. On the MK2 the idle ack is a
  protocol scope: left display = latest raw surface report (hex), right display = decoded
  event + MIDI summary — disagreement between the two panes is how layout bugs get spotted.
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
- For visible MK2 changes, rebuild and restart the active demo client. Do not leave
  `MK2WidgetLabDemo`, `MK2SurfaceDemo`, and Paulinche running together:
  a newly registered surface client evicts the previous session.
- For FreeType work, run `swift build --product MK2WidgetLabDemo`; Unit A contains the
  typography, icon browser, and action-dialog sub-demos. `Instance` cycles those sub-demos.
- For idle daemon diagnostics, install the debug daemon, make sure no client such as Paulinche or
  SurfaceDemo is connected, and verify the hardware shows `NO CLIENT` plus a `REV` cell. Then press
  a surface control and a MIDI key and inspect `/tmp/media.vanille.kompletekontrol-libusb.stderr.log`
  for `push surface` / `push midi` if the hardware display is not visible.
- `print` is **block-buffered** to a pipe — output only appears after exit/flush.
- For the docs SVGs there are Python generators in scratch; render with `rsvg-convert` and Read
  the PNG to inspect visually.

### MK2 FreeType typography

FreeType support lives in `Sources/KontrolSurfaceKit2/FreeType/` and is documented in
`Docs/MK2-FreeType.md`.

- Use `BitmapLabel`/`SurfaceFont`/`MK2PixelFrame.drawText(...)` for tracker grids and dense,
  bitmap-sharp UI. This path remains atlas-backed and does not call FreeType.
- Use `FreeTypeTextRenderer`/`FreeTypeTextStyle` for larger, calmer UI areas: global dialogs,
  browser/settings views, selection lists, long text, and icon-font-style symbols.
  Proportional text is shaped through HarfBuzz, so standard ligatures and positioning are
  available outside tracker/grid text.
- Keep tracker/grid text on `SurfaceFont` / `drawMonospaced`; that path intentionally avoids
  HarfBuzz shaping and ligatures so one scalar remains one fixed cell.
- Bundled production fonts are IBM Plex Sans Condensed Regular/Medium for text and
  Phosphor Regular for icons (MIT licensed, from the @phosphor-icons/web package —
  its catalog JSON in WidgetLab is generated from that package's regular style.css).
  With Font Awesome Pro gone there is no longer a licensing reason to keep the
  repository private. Swap globally through
  `FreeTypeFontCatalog.production`, not per-screen resource literals. Body text is
  Plex Sans Condensed Regular 16 px; titles are Plex Sans Condensed Medium 24 px;
  action-dialog icons are 48 px.
- `FreeTypeRasterMode.grayscaleHinted` is the OLED default and WidgetLab Unit A renders
  with it fixed. `grayscaleLightHinted`, `grayscaleUnhinted`, and `monochromeHinted`
  remain renderer comparison modes. Do not enable LCD/subpixel rendering for MK2
  RGB565/OLED output; it is likely to create colour fringes.
- Performance boundary: FreeType integration should not slow bitmap rendering because the
  bitmap path is separate. Validate with `swift test --filter PixelPipelinePerfTests`
  (look at `PERF drawText 60 chars scale 3`) plus `FreeTypeTextRendererTests`.

`MK2WidgetLabDemo` Unit A controls:

- `F1`: select the Font Lab unit.
- `Instance`: cycle Surface Font, Typography, Phosphor icon browser, and global action-dialog sub-demos.
- Main rotary: scroll the icon browser list by one icon.
- `4D Up`/`4D Down`: scroll the icon browser list by one visible page.
- `Page Left`/`Page Right`: previous / next icon.
- `Plugin`/`Mixer`: jump -16 / +16 icons; on the dialog page `Mixer` also cycles
  dialog copy.
- `E8`: icon-browser list/grid/filter-list/filter-grid mode.
- `E5`: filtered icon-browser modes: first-letter filter.
- `Preset Down`/`Preset Up`: icon size.

### Simulation mode — run the daemon without hardware

`ccd` can drive a GUI panel app instead of a real device, **transparently to socket clients**.
`CCD_SIMULATE=<socket-path>` (empty ⇒ default `/tmp/kontrol-simulator.sock`) makes
`openDeviceSession()` construct a `SimulatorDeviceSession` (a socket to the `KontrolSimulator`
app) instead of `LibUSBDeviceSession`. Everything above the `KontrolDeviceSession` seam —
reactor, socket protocol, decoders, reconnect — is unaware which backend it opened.

- **The seam**: `KontrolDeviceSession` (protocol, `KontrolDeviceSession.swift`) with
  `LibUSBDeviceSession` (real) and `SimulatorDeviceSession` (simulated). `DaemonHardware`
  reaches the device *only* through it; identity via `===` replaced the old
  `libusbSession == session` staleness checks.
- **Transparency linchpin**: clients decode the *raw* `0x01` HID report themselves (the daemon
  ships raw hex), so the simulator must emit byte-identical reports. `MK2InputReportBuilder`
  synthesizes them from the *same* layout `KKMK2InputReportDecoder` reads (its `buttonBits` /
  offsets are `internal`, one source of truth). `MK2InputReportBuilderTests` round-trips
  builder → decoder per control to prove it.
- **Wire protocol**: `SimWireProtocol` (`SimFrame`/`SimWireCodec`), length-prefixed frames.
  ccd→sim = display blits + LED reports; sim→ccd = *semantic* input (button/encoder/4-D). The
  app is dumb — `SimulatorDeviceSession` lowers semantic input into raw reports; its socket fd
  rides the kqueue reactor exactly where libusb pollfds do, and socket EOF = device-loss.
- **The app**: `KontrolSimulator` (`Tools/KontrolSimulator`) — two 480×272 displays, 8 function
  buttons, side buttons, 8 encoders, the 4-D encoder, with hardware-accurate button LEDs:
  panel-button RGB only for Mute, Solo, and F1-F8; fixed-colour monochrome text for the rest
  (Play green, Record red, otherwise white). All controls are clickable/scrollable. Closing the window
  exercises reconnect.
- **Run it**: `make run-simulator` (GUI, one shell), then either the app's **Daemon menu**
  ("Start Simulator Daemon" — launches the sibling `ccd` build in CCD_SIMULATE mode on
  `/tmp/kontrol-simulator-daemon.sock`, **no sudo**, coexists with the installed hardware
  daemon) plus a client via `make mk2-widget-lab-demo-sim` (exports `KK_DAEMON_SOCKET`),
  or the classic `make daemon-simulate` (sudo, takes over the stock socket). The window
  title shows the daemon attachment state; "Copy Client Environment" puts the
  `KK_DAEMON_SOCKET=…` line on the pasteboard, and "Autostart Daemon If Not Running"
  (persisted) starts the child after a 1.5 s grace period unless a daemon already
  attached — and immediately when toggled on while unattached (skipped in snapshot
  mode; SIGTERM/SIGINT tear the child down with the app). Window title and the
  panel status line show the tri-state: no daemon / starting daemon / connected. Enablers: clients resolve
  `defaultDaemonSocketPath` through `KK_DAEMON_SOCKET`, and beyond that resolve the
  actual connection target per attempt via `clientDaemonSocketPath()` — stock socket
  when it responds, otherwise the simulator daemon socket. `MK2Surface2` reports
  whether it attached to the hardware or simulator daemon; before a successful
  attachment it may try the other available socket, but once a session has
  registered with the simulator daemon it keeps retrying that simulator socket
  and must not fall through to hardware launchd/admin startup. Clients must not
  start, install, restart, or `osascript`-prompt for daemons; they only attach to
  an already-running hardware or simulator daemon and otherwise report retrying.
  The daemon singleton and its lock file are scoped **per socket** (hardware on
  /var/run, simulator on /tmp), and `daemon-preflight` skips the installed
  `/usr/local/bin/ccd` revision check when the simulator daemon is the target or
  the only running daemon. Full
  design + phasing in
  `Docs/Simulator-Plan.md`.
- **MK2 daemon→client handoff**: on client registration the daemon leaves the right
  OLED untouched, replaces only the left `NO CLIENT` title row with the client
  name plus a smaller gray PID, holds client display/state reports for one second, slides the light guide
  left-to-right, then flushes the newest queued client state. Idle chrome colors:
  gray = booted/no client/no I/O, yellow = idle surface/MIDI I/O observed, green =
  client connected.
- **Headless snapshots**: `KONTROLSIM_SNAPSHOT_PATH=<png> KONTROLSIM_SNAPSHOT_DELAY=<s>` renders
  the panel view to a PNG after the delay and exits (`KONTROLSIM_SNAPSHOT_SCALE`, default 2).
  TCC-free (renders the view, not the screen) and needs no daemon/sudo: anything can speak the
  trivial `SimWireProtocol` to `/tmp/kontrol-simulator.sock` and push display blits + LED
  reports directly — the protocol-guide illustrations in `Docs/images/` were produced this way.

### Daemon output pipeline: two independent serial queues, not one

`ccd` drains display blits and LED/light-guide state reports on **separate serial
`DispatchQueue`s** (`displayQueue` / `stateReportQueue` in `KompleteKontrol.swift`), each
taking `sessionIOLock.lockShared()` so they run truly concurrently against libusb. They used
to share one queue; a state report enqueued while a blit was already draining had to wait for
that blit to finish. Measured on hardware (S61 MK2, before the split): up to ~17ms
(full-frame force-replay) or a few ms (typical partial-row-band blit) of pure, avoidable delay
on the "LEDs are tiny and feel-critical" path (see d55b0da's own comment). The split is safe
because displays and LEDs/guide use different USB endpoints (bulk vs. interrupt) with no
shared mutable state at the C layer, and libusb documents concurrent transfers on different
endpoints as safe — verified against `KontrolUSB.c` directly, not just the libusb docs.

Measured blit cost by row-band height (S61 MK2, full 480px width, debug build TRACE log):
~0.4ms fixed + ~0.06ms/row — 1 row ≈0.5ms, 40 rows ≈3ms, 136 rows ≈9ms, full 272 rows
(480×272) ≈17ms. Only force-replays/reconnects send a full frame; a normal tick sends a small
dirty band, so this path's everyday cost is low-single-digit ms, not the full-frame worst case.

**Measurement gotcha**: `writeReport`/`displayBlit` daemon acks fire on *enqueue*, not on
actual hardware completion (latest-wins, fire-and-forget by design) — client-perceived
round-trip time is **not** a valid proxy for real USB latency on this path. To measure the
real thing, read the daemon's own TRACE log (`performDisplayBlit`/`performStateReportWrite`
both log `elapsed=`), not the client's `request()` timing. A synthetic client-side race test
showed near-zero latency for a state report racing a blit purely because the ack doesn't wait
for the transfer; the real serialization only showed up by cross-referencing daemon-side
timestamps for when the underlying libusb call actually ran.

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
without disabling their app workflow. Once connected, the surface keeps the established daemon
session hot without polling under load: every real event/write/blit updates the daemon activity
timestamp, and the idle heartbeat only sends `version` after roughly three seconds with no real
daemon communication.

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

Full protocol findings live in `../docs/MK2-Porting-Plan.md` §2; the bench hardware is an S61 MK2.
The short version:

- Surface HID input report `0x01` (buttons/encoders/wheels/4-D) streams unconditionally. The
  analog controls (wheels, **touch strip**, pedals) and any knob/button **MIDI** go through an
  **onboard mapping engine**: enable with `0xA0 93 00` (`0xA0 00 00` leaves it off — this was
  the "dead ribbon" bug), configure via template reports `0xA1` (buttons+knobs), `0xA2`
  (wheels+strip), `0xA3` (pedals), `0xA4` (keyzones), then `0xAF 00 02`.
- **`A0 00 10` is the real DAW/host mode** (bench 2026-07-02): function-button LEDs (0x80
  indices 2–9), Mute/Solo (0–1), fixed-colour monochrome button indicators, and palette-capable
  ribbon LEDs (44–68) are host-controlled; the strip streams raw on report `0x02` (`[u16 const][u16 const]
  [u16 time ms][u16 pos 0…1024, 0 = release][u16 zero]`, ~100 Hz), keys/wheels stay plain
  USB-MIDI. LED capability is constrained by hardware: Mute, Solo, F1-F8, and the 25 ribbon
  slots accept palette colours; all other panel button LEDs are fixed-colour monochrome
  brightness channels (Play green, Record red, otherwise white). In `93 00` the firmware owns those LEDs and host writes are
  ignored. `ccd` bring-up = `configureMK2HostControl` (`A0 00 10`); the mapping engine +
  factory templates only return in the shutdown handover. Observation trap: LED writes are
  wiped the moment the writing client disconnects (idle repaint) — hold the connection while
  judging LED state.
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
  reconnect + re-init + `device reconnected` push; daemon shutdown → `restoreMK2StandaloneState`
  (factory knob CCs, LEDs/guide/displays cleared).
- **A registered client must force a full state replay on `"device reconnected"`, not just
  treat it as "connection is fine now"** (bug fixed 2026-07-03). If a client registers before
  the device is plugged in (or the daemon reopens the session after a drop), its `reconcile*`
  "last sent" caches (lamp bytes, key colors, the display reconciler's dirty-diff state) had
  already advanced from writes issued while no libusb session existed — those writes silently
  no-op'd daemon-side (`ensureSession()` returns `nil`), but nothing checked the result. Once
  the session actually opens, a plain delta-diff tick has nothing new to send, so the surface
  sits registered-but-blank forever. Fix lives in `MK2Surface2.process(_:)`
  (`Sources/KontrolSurfaceKit2/MK2Surface2.swift`): on `"device reconnected"`, reset those
  caches and force `tick(forceDisplay: true)` plus re-run `configureHostControl()` instead of
  publishing `.retrying`. General lesson: any "hardware became available/reappeared" signal
  needs to force a *replay*, not just flip a connection-state flag — a diff against a cache the
  hardware never actually received will always be empty.
- **Text push lines must never reach binary control clients** (the actual
  reconnect-per-input regression, fixed 2026-07-08). The daemon adds every accepted
  control connection to `clientFDs`, and `pushToClients` wrote the legacy text push
  line (`in @ts hex…`) to all of them — including registered *binary* control
  clients. An ASCII line inside the length-prefixed binary stream is a parse error;
  the old text client filtered push lines via `asyncPushHandler`, but since the
  binary write path with strict EOF/garbage distinction (6c2c260) every hardware
  input poisoned the control channel, the next request missed its ack, and the
  session reset — "reconnect after every input". The daemon now marks control
  connections binary the moment their first binary frame arrives
  (`markControlClientBinary`) and the text fan-out skips them; binary clients get
  pushes as frames on their event channel. Debug with the scripted-input harness:
  a fake `SimWireProtocol` listener + `CCD_SIMULATE` daemon + lab client on
  isolated /tmp sockets reproduces input-driven lifecycle bugs headlessly.
- **The daemon session is generation-stamped; ticks wait for the control client**
  (reconnect-cascade bug fixed 2026-07-08). `MK2Surface2.startDaemonClient` sets
  `daemonThread` immediately but installs the control/display clients asynchronously
  (reader thread → actor hop → `setEventClient`). The 60 Hz tick used to reconcile
  inside that window: writes into a nil control client returned nil, indistinguishable
  from timeouts, so *every* client start flapped into `.retrying` twice, and any
  mid-session hiccup could cascade — a cancelled reader thread's late
  "event socket disconnected" or its deferred setup hop would tear down or hijack the
  *next* session, which read as "reconnects on every hardware action". Now:
  `daemonSessionGeneration` stamps each attempt (bumped on reset/stop/evict), reader
  threads carry their generation and stale callbacks are ignored, `setEventClient`
  refuses to register a zombie session, the tick skips reconcile until the control
  client exists, and a real write timeout probes the daemon (`version`, generous
  deadline) before it is allowed to kill the session — a slow ack is not a dead
  daemon; the client↔daemon connection stays up unless one side actually shuts down.
- **Daemon loss is a recoverable surface lifecycle state, not a client crash path** (bug fixed
  2026-07-08). `KompleteKontrolDaemonBinaryClient` sets `SO_NOSIGPIPE`, so a write to a dead
  Unix socket cannot terminate the process with `SIGPIPE`. Its event read path distinguishes
  timeout from EOF/error; `MK2Surface2` treats event-socket disconnects, failed LED/display writes,
  and setup/registration failures as `.retrying(...)`, drops the stale control/event/display
  clients, resets output caches, and reconnects on the tick. The heartbeat is deliberately
  idle-only: real daemon communication moves `lastDaemonCommunicationNanos`, so playback, pattern
  scrolling, display blits, and input events suppress synthetic `version` probes. Only after about
  three seconds of silence may the heartbeat run, and it does not mark itself as real activity.
  Cross-check: `MK2WidgetLabDemo` uses the same `MK2Surface2` through `MK2SurfaceEventRunner`, so
  this fix belongs in the kit rather than in Paulinche's adapter.
- The old MK2 calibration workbench has been removed. Its protocol findings remain in git
  history and the MK2 tests/docs; new validation should go through `MK2SurfaceDemo`,
  `MK2USBSpy`, and focused tests.

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
SwiftPM dep, integrates directly — **MCU/HUI adapter deprioritized**). **Paulinche targets the
MK2 exclusively** (decision 2026-07-02): a tracker's surfaces — pattern grid, per-channel state,
VU meters — need the pixel displays; the MK1's 16-segment cells can't carry them and the S25
keybed is too small for tracker entry.

**MK1 is frozen, not removed**: the daemon keeps driving it, `KontrolProbe`/`SurfaceDemo` stay
as the regression baseline for the shared middleware, but no new kit features get ported to the
16-segment display pipeline.

**Structure decision (2026-07-02): split the middleware, keep the daemon unified.**
- `ccd` stays **one** binary for both generations — its value is the generation-agnostic
  machinery (libusb session ownership, reactor, device-loss/reconnect lifecycle, socket
  protocol, standalone handover); forking would mean fixing every lifecycle bug twice. The
  MK1 code inside it is inert and cheap. (Deserved refactor, not fork: split the 4000-line
  `KompleteKontrol.swift` into small files per convention.)
- `KontrolSurfaceKit` is **frozen** — no more changes; a freeze only works if the module
  literally stops changing.
- **`KontrolSurfaceKit2`** (new target, same package) is the new major: pixel HIG,
  `PixelDisplayReconciler`, pixel DSL, strip/jog/encoder inputs. Paulinche imports only this.
  Current tracker-facing widgets include `MK2ButtonToggle` (lamp + optional pixel button),
  `MK2ButtonRangeSelection`, `MK2EncoderDiscreteValue` (bounded discrete encoder values with
  optional wrap-around), `MK2StatusLine`, `MK2ValueCell`, `MK2ModalDialog`,
  `MK2SelectionNavigation` (selection index + filter-focus state), `MK2SelectionLayout`
  (shared selection geometry and grid row-step metrics),
  `MK2SelectionList` / `MK2SelectionGrid`, and the FreeType text renderer/catalog for
  large UI typography. Selection views are one-screen list/grid projections with optional
  bottom-third filter controls. Keep filter values in fixed physical `E5`-`E8` slots, and
  do not conflate active filters with focused encoder values: active filters colour labels,
  while only the touched/turned value is inverted. Demos should use `MK2SelectionLayout` for
  content/filter rectangles and grid row-step behavior instead of copying pixel constants.
  `MK2WidgetLabDemo` cycles lab sub-demos with the `Instance` button. Its Font/Icon Lab
  uses the same selection elements for the Phosphor icon browser with `E8` modes and
  an `E5` first-letter filter. `MK2WidgetLabDemo` unit `B` is the
  browser/settings prototype: left detail/preview,
  right selection list/grid, `Instance` modes, 4-D move/confirm, and `E5`/`E6` filters.
  Genuinely generic pieces (`SurfaceClock`, `GestureRecognizer`, daemon-client transport)
  get extracted into a small shared core where the seam is clean, or copied once where
  extraction would contort the frozen kit. This also keeps eventual MK1 deletion a
  mechanical excision.
- **The daemon stays a separate root process; clients never link it** (decision 2026-07-02,
  revisited and reaffirmed): measured IPC cost is <1 ms against a 7.7 ms fixed USB/panel
  cost — privilege separation, crash containment (standalone handover), and session
  continuity across client restarts are worth far more. If profiling ever indicts the
  transport, the prepared escape hatch is a shared-memory framebuffer for the display path
  (bulk via shm, control via socket — the CoreAudio/JACK pattern), not in-process linking.

MK2 kit work Paulinche will pull, in rough priority. The protocol side and basic Kit2
rendering pieces are in; before wiring Paulinche, make the Kit2 screen DSL production-grade:

1. **Formal `MK2ScreenDSL` on top of the new screen model**: declarative `RegularScreen`,
   `FullScreen`, and `DoubleScreen` builders with first-class header/footer/content slots,
   using `MK2HIG` tokens for typography, fonts, colors, and fixed metrics.
2. **Standard content components**: list/grid selection, value rows, encoder footers,
   parameter pages, status rows, empty/error states, progress bars, tabs/page indicators,
   browser detail panes, and meter elements are in.
3. **Screen-owned input bindings**: screens should declare their buttons, encoders, 4-D
   navigation, and modifiers alongside rendering, so Paulinche does not hand-wire hardware
   behavior per view. Shift is the single first-class key modifier; other chords should be
   explicit product gestures rather than a general modifier system.
4. **Snapshot and hardware acceptance set**: every screen class needs a WidgetLab realization
   plus snapshot coverage, so HIG changes and layout regressions are visible before client
   integration.
5. **Paulinche adapter preparation**: define a small semantic `SurfaceProjection` boundary
   where Paulinche emits product state and commands, Kit2 renders screens, and hardware input
   returns as semantic events.
6. **Encoder sensitivity as a global + rotary-local modifier** in the DSL — local *factorizes*
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

For MK2 Kit2 lifecycle changes, also build a real Kit2 client such as
`swift build --product MK2WidgetLabDemo`; if the change affects Paulinche integration, build
Paulinche against the sibling checkout too (`swift build --product PaulincheApp` from the
Paulinche repo).

Commit messages are plain (no attribution/Co-Authored-By trailers).
