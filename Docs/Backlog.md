# CompleteControl Backlog

## Next up

- No item is currently committed as the immediate next slice.

## Recently completed

- **Display-pipeline performance slice and measurement closure (completed
  2026-09-06).** `wip/performance` landed the touch-overlay composite cache
  (`displaysWithTouchOverlays`, keyed on the CoW identity of the base frames
  plus each active overlay's screen, rect, and pixel-buffer identity, so a
  latched-overlay steady tick is O(1) again), the row-memcpy `blit(_:into:)`
  matching PixelFrame's bulk policy, and the up-front-reserved
  `displayBlitPayload`. A hardware branch A/B (master vs branch, 12 iterations
  per fixture, adaptive encoding) showed byte-identical transport payloads
  across all seven fixtures and time parity within single-run noise —
  client-side micro-work cannot move the device-paced USB metrics, and
  byte-identity is the acceptance check for send-path changes. The same run
  closed the open measurement questions: the copy share of a full-frame
  replay is ≤0.2% of wall time (deep copy elimination rejected), and AP2
  multi-rect blits are rejected because the adaptive skip encoding already
  collapses clean gaps at the wire (gap fixture: 190,080 logical bytes →
  368 transport bytes → 0.742 ms USB median). See the Umsetzungsstand in
  `Display-Reconciler-Cross-Review.md`, the result block in
  `transport-latency-optimization-review.md` AP2, and the Protocol Guide's
  display-cost section.
- **Product-bound daemon endpoints for simultaneous KONTROL+MASCHINE
  (completed 2026-08-04).** `ccd --kk-libusb-daemon <socket> --product
  kontrol-mk2|maschine-mk3` binds a daemon's libusb session (initial open and
  every reconnect via `ensureSession`) to one device family;
  `LibUSBDeviceSession.open(family:)` probes only that family's PIDs through
  `KontrolUSBLibUSBSessionOpenForProduct`. An invalid `--product` refuses to
  start instead of silently opening another family's device.
  `MK2Surface2.Options.daemonSocketPath` pins a client to exactly one base
  socket — no auto-discovery, no simulator fallback — so two surfaces in one
  process address their own daemons. `install-daemon.sh` installs the pair
  `media.vanille.kompletekontrol-libusb` (KONTROL, stock socket) and
  `media.vanille.kompletekontrol-maschine`
  (`/var/run/kompletekontrol-maschine.sock`); Makefile daemon targets and
  `daemon-preflight` are endpoint-scoped and never pkill the other product's
  daemon. Paulinche attaches both endpoints through its new
  `CompositeControlSurfacePort` (per-surface `SurfaceID` event provenance,
  output fan-out, fleet connection status). Bench-verified on real S61 MK2 +
  MASCHINE MK3: both daemons own exactly their device and Paulinche renders
  all four displays in mirror operation.

- **Deterministic headless simulator host (completed 2026-07-22).**
  `kontrol-sim-host` launches either profile without AppKit, owns `DeviceLink`,
  optionally starts/stops a matching user-level `ccd` with the automation
  socket enabled per flag (no `UserDefaults`), and speaks a JSON-Lines control
  plane: machine-readable readiness and connection events, native MK3 gesture
  synthesis through the production decoder, lamp snapshots, and post-wire
  decoded framebuffer dumps (PNG/RGB565 plus SHA-256). All paths live in
  `flock`-guarded per-instance directories (`/tmp/kksim-<id>/`,
  `SimulatorInstancePaths`), so parallel runs never collide with the GUI
  simulator, each other, or a hardware daemon; exit codes are a stable
  contract and shutdown escalates a hung child to SIGKILL. Child-daemon
  ownership was extracted into `SimulatorDaemonController`, shared with the
  GUI. End-to-end regression: `KontrolSimHostIntegrationTests` (gesture
  round trip via daemon NO CLIENT mirroring, two-instance isolation, busy
  refusal). See `Docs/automation-testing.md` section 5 and
  `Docs/Headless-Simulator-Host-Plan.md`.

- **Dedicated MASCHINE PAD MODE control identity (completed 2026-07-19).**
  MK3 PAD MODE no longer masquerades as KONTROL KEY MODE in Kit2's
  compatibility plane. Paulinche can bind normal PAD MODE to its
  Mono-Chromatic/Drum-Kit workflow and SHIFT+PAD MODE to the rarer Poly-
  Chromatic action while KONTROL keeps its existing KEY MODE semantics.

- **Typed Paulinche control-surface action bridge (completed 2026-07-19).**
  `ControlSurfaceEvent.button` now carries a closed `ControlSurfaceAction`
  vocabulary instead of a free-form name. Commands, scenes, soft-key layers,
  instrument slots, navigation, paging, root-octave selection, Fixed Velocity,
  Undo, and Redo cross the CompleteControl adapter boundary without string
  construction or parsing. The sole ribbon event is typed as well. Router and
  adapter regression tests cover the end-to-end mappings.

- **Shared simulator core and single-device MASCHINE MK3 simulator (completed
  2026-07-19).** `KontrolSimulatorWire` now provides the versioned authoritative
  device handshake and bounded raw-frame transport; `KontrolSimulatorCore`
  provides headless definitions, native MK3 report synthesis, output reduction,
  and calibrated geometry. The one `KontrolSimulator` executable selects S61
  MK2 or MASCHINE MK3, runs unchanged daemon clients such as `widget-lab`, and
  renders the complete interactive MK3 surface: two displays, lamps, strip,
  pads, encoders, profile-scoped window/zoom state, accessibility, and fixed
  out-of-content daemon status. The Widget Lab executable, sources, automation
  script, and Make targets are now device-independent rather than MK2-named.

- **Typed 4-D Kit input contract (completed 2026-07-19).** `KK4DNavigationDirection` now represents only up/right/down/left; MK2 and MK3 both deliver `jogCenter` only on center release. The historical `"press"` pseudo-direction was removed from the decoder, Kit2 consumers, and demos. A raw MK2/MK3 contract test verifies held SHIFT, directional press/release, and center confirmation through the input adapter and `MK2Surface2` semantic sink.

- **Investigate intermittent 10-second Widget Lab startup latency (noted
  2026-07-15).** On physical MK2 hardware, `widget-lab` sometimes takes
  almost ten seconds before both the REPL prompt and first browser frame appear,
  despite an already-running daemon; Paulinche reaches its first surface much
  sooner. The strongest current suspect is eager demo construction:
  `LabShell.demoRegistry` touches the global `labDemos` array before
  `MK2SurfaceEventRunner.run`, `TrackerPatternDemo` immediately constructs
  `DemoMetronome`, and `DemoMetronome.init()` synchronously prepares and starts
  an `AVAudioEngine`. A cold or reconfiguring CoreAudio route can therefore
  block the executable before surface startup and the REPL. The icon catalog
  JSON load and cold FreeType glyph caches are secondary candidates. First add
  monotonic timing points around LabShell/demo-registry initialization,
  `surface.start()`, `showBrowser()`, daemon registration/host-control setup,
  first `present()`, and REPL launch. Then make the tracker metronome lazy or
  prewarm it off the startup path, as Paulinche already does for realtime audio.
  Also verify whether the runner's current start-before-initial-render ordering
  can queue `showBrowser()` behind a slow daemon handshake. Acceptance: prompt
  appears immediately and the first browser frame follows without a
  multi-second stall on repeated cold and warm hardware launches.

## Simulator

- **Native MK2 gesture synthesis in `SimulatorDeviceRuntime`.** The headless
  host's `gesture` command is MASCHINE MK3-only because the MK2 panel still
  builds semantic frames inside the AppKit `PanelView`. Move MK2 report
  synthesis (buttons, encoders, 4-D, touch strip) into the shared runtime so
  the panel delegates to it and headless MK2 scenarios gain native-report
  fidelity; until then the daemon automation socket is the MK2 input plane
  (slice 4 of `Headless-Simulator-Host-Plan.md`).

- **Phase 5 remainder: isolate simulator instances and the mixed real/sim
  matrices.** The both-real leg is delivered (2026-08-04): product-bound `ccd`
  endpoints, explicit `MK2Surface2.Options.daemonSocketPath`, and Paulinche's
  `CompositeControlSurfacePort` with stable `SurfaceID`s and no daemon
  auto-discovery. Still open: migrate the GUI simulator's global device/daemon
  socket, log, lock, and defaults paths onto validated instance-scoped paths
  (`SimulatorInstancePaths`, `SimulatorDaemonController` exist); make
  child-daemon ownership profile-aware; and add real KONTROL + simulated
  MASCHINE, simulated KONTROL + real MASCHINE, and both-simulated harnesses
  (Paulinche side: `PAULINCHE_KONTROL_SOCKET`/`PAULINCHE_MASCHINE_SOCKET`
  already select explicit endpoints). Also still open from the Phase 5 gate:
  one-surface loss/restart/sleep-wake soak, identical-note ownership across
  surfaces, and the four-display stress evidence. See Phase 5 of
  [Maschine-MK3-Simulator-Plan.md](Maschine-MK3-Simulator-Plan.md).

- **Phase 6: final MK3 bench calibration.** Compare the simulator's remaining
  estimated geometry and interaction constants with the real unit, then verify
  encoder count/touch timing, pad velocity and pressure feel, touch-strip edge
  cases, reconnect/shutdown, audio-interface coexistence, and the final both-real
  four-display stress case. Physical LED brightness curves and the nine-family
  hue collapse were bench-calibrated by 2026-07-20. Simulator evidence must not
  be promoted to USB timing or physical-feel evidence.

- Encoder feel is nearly opaque on the simulator (noted 2026-07-14): rotation
  arrives as bare wire deltas, so acceleration/detent tuning gives almost no
  insight there and every judgement waits for hardware. Wanted: surface the
  derived feel on the simulator panel — e.g. show counts-per-step / acceleration
  state, or visualise the mapped vs raw delta — so at least gross
  mis-calibration is catchable without the bench.

## Daemon / libusb architecture

- **Segment coalescing in the adaptive display encoder (observed 2026-09-06,
  not committed).** The 2026-09-06 hardware benchmark shows USB time is
  per-segment, not per-byte: a meter step moves 11,646 bytes in 7.21 ms
  (~620 ns/byte) while contiguous noise moves 153,632 bytes in 14.72 ms
  (~96 ns/byte) — fragmented literal runs pay fixed per-segment device costs.
  Candidate: widen a literal across a small clean run whenever the segment
  overhead exceeds the saved bytes — a daemon-internal encoder policy inside
  the same `0x84` wire format, no protocol change, legacy fallback unchanged.
  Before building it, sample how often real Paulinche sessions emit
  meter-class fragmented bands (`KONTROL_SURFACE_KIT2_RECONCILER_TELEMETRY=1`
  plus a segment-count counter). Acceptance: meter-fixture USB-median drop on
  the same Widget Lab benchmark with every other fixture unchanged and
  byte-identical encoding for gap/solid fixtures.
- **Blank daemon-owned NO CLIENT displays after inactivity (noted
  2026-07-16).** Add a small visible/blanked state machine to the existing idle
  diagnostic, with a default timeout around 10 minutes and a configurable
  `0 = disabled` escape hatch. Only meaningful surface or MIDI input resets the
  deadline; daemon display writes and controller-mirror floods do not. On
  expiry, send one true-black fill to both displays, retain the current
  diagnostic/log state in memory, and suppress further diagnostic display
  flushes until wake. Any hardware input must wake and still be delivered (the
  first event is never swallowed); a client connection wakes immediately and
  hands display ownership to that client. Keep the scope strictly inside the
  current `shouldDaemonShowIdleSurface()` / NO CLIENT ownership boundary: the
  daemon must not infer application idleness or globally blank displays while a
  registered client owns them. A later client-controlled display-sleep command
  can be designed explicitly if Paulinche needs it; a true global safety policy
  would first require separate desired-client and physical framebuffer shadows.
  Treat this as defensive display blanking, not a promise of panel power-off.
  Acceptance: focused deadline/wake tests plus simulator and physical-MK2 checks
  for one-shot blacking, wake-without-event-loss, client handoff, and absence of
  periodic USB display traffic while blanked.

- Continue revisiting the daemon's libusb architecture for MK2 idle and client operation.
  Display, MIDI, surface input, button LEDs, and light guide sit on separate USB
  interfaces/endpoints, but the daemon still owns them through one device session and one
  reactor-adjacent scheduling model.
- The least risky direction remains: keep one libusb device handle, but preserve strict
  separation between the event pump, display blits, and small state reports so MIDI and
  light-guide updates are never queued behind display frames. The NO CLIENT hardware-test
  mode is a good stress case because chords expose stale-state regressions quickly.
- Longer-term experiments: dedicated libusb contexts/threads per function class, or
  separate handles for separately claimed interfaces if macOS/libusb behaves cleanly.
  Treat multiple handles as a research item, not the default design, because composite
  USB claiming, shutdown, and reconnect semantics can get fragile.
- Also evaluate whether selected paths should bypass libusb: CoreMIDI for MIDI and IOHID
  for HID-style surface traffic may reduce contention, while MK2 display/custom bulk
  traffic probably remains libusb/IOUSB-level. Avoid mixed backends unless claim conflicts
  and ownership boundaries are understood.

## KontrolSurfaceKit2

- **Display ack round-trips moved off the `MK2Surface2` actor (noted
  2026-07-20; fixed and bench-verified 2026-08-04).** The 2026-08-04
  dual-surface stress reproduced the failure: after ~13.8 flawless minutes a
  KONTROL `display blit timed out` (flat 50 ms ack budget hit by a ~261 KB
  full-frame payload) tipped the actor-blocking design into a non-converging
  timeout → full-frame-resend → longer-ack loop with unbounded app memory
  growth (264 MB → 1.4 GB+), while the daemon stayed healthy. Fix:
  `MK2DisplayBlitWriter` owns all blit round-trips on a dedicated serial
  queue with one in-flight batch (ticks skip reconciliation while busy —
  latest-wins at frame granularity, no lost diffs); the ack budget scales
  with payload size (50 ms + 0.2 µs/byte, 1 s cap); display timeouts arm a
  250 ms retry cooldown; consecutive session failures back the redial off
  (1→2→4→8 s). Verification: identical 15-min four-OLED stress with ~3510
  injected events — zero input-delay diagnostics, zero blit
  timeouts/retries, app RSS flat 263-266 MB, daemons ~2 % CPU. Hands-on
  follow-up incident (same day, during manual play): a display send was
  abandoned mid-frame ("stream desynced") because the display channel's
  few-KB kernel send buffer forces a ~261 KB frame through dozens of daemon
  drain rounds inside one send budget; the new convergence machinery
  recovered in ~20 s instead of livelocking. Hardened since: the display
  connection carries a 1 MB `SO_SNDBUF` (a whole dual-screen batch fits
  without depending on momentary drain pace) and blit sends get a patient
  1 s send budget separate from the ack budget — a slow write is
  backpressure, not failure. The partial-write regression test now fills
  the enlarged buffer before expecting desync. Remaining follow-ups from
  the original item: small lamp/light-guide state-report acks still
  round-trip on the actor (50 ms ceiling; benign on the bench), and MK3
  pad-feel should be re-benched hands-on during active playback display
  updates. The tick performs synchronous request/ack round trips
  (`blitDisplay` up to `displayTimeoutMs` 1000 ms, lamp/key state reports) on
  the same actor that processes input frames, so a slow ack queues pad/button
  events behind it — the client-side counterpart of the daemon invariant
  "display frames must not gate feel-critical output". Bench trace 2026-07-20
  (Paulinche + MASCHINE MK3): pad events arrived 300-700 ms late and batched
  while displays were static, so the first confirmed cause was cooperative-pool
  starvation of the default-priority input tasks (fixed: reader thread
  `.userInteractive`, event/tick tasks `priority: .high`, per-frame timestamp
  Task removed, `MK2Surface2: input delayed ...` stage-attributed stderr
  diagnostic added, rate-limited, threshold 100 ms). The structural follow-up
  remains: publish latest frames to a dedicated writer (latest-wins coalescing)
  and keep every blocking ack off the input actor; re-bench pad feel during
  active playback display updates afterwards.

- Connect the MK3 Fixed Velocity button to an application-owned pad setting.
  `KontrolPadMIDIMapping.fixedVelocity` already supports a configured constant;
  the remaining decision is whether the hardware button toggles a persisted
  client preference or only reflects a scene-owned state. Do not introduce a
  hidden global layer in Kit2.

- **Formalize a semantic warning color in `MK2HIG` (priority: medium-high,
  noted 2026-07-15).** Driven by the MK2 Wavetable-Editor Phase 2 concept
  (Paulinche `BACKLOG.md`, "MK2 Wavetable-Editor (Instrument-Editor Phase
  2)") which needs an OCS-incompatibility warning tag on the instrument
  editor surface. `MK2HIG` currently has no general warning semantic beyond
  the `IconGlyph.warning` glyph — only `Meter.warning`/`Meter.danger`
  (level ballistics, yellow/red) and `Chrome.shiftAccent` (SHIFT layer,
  amber `0xfc00`/`#ff8200`), both already owned by a different meaning.
  Proposal: a new `MK2HIG.Semantic` namespace with `warning`, RGB565-
  quantized from Apple's `systemOrange` (the app-side OCS-warning color in
  Paulinche's `ocsWarningRow`/`EditorCard.ocsIncompatibilityReason`) —
  lands around `0xF940`/`#ff9600`, consistent with the existing
  `Design.Waveform`/`Design.Accent` ↔ `MK2HIG.Waveform` coupling rule
  above ("change both sides together"). **Risk, needs a bench check before
  landing:** `#ff9600` sits close enough to `shiftAccent` `#ff8200` that
  the two may be hard to tell apart at a glance on the physical OLED —
  possibly shift the warning hue toward red instead of yellow so a warning
  tag can never be mistaken for a SHIFT hint. Do not fix the final hex
  without hardware confirmation, same as the other color decisions in this
  section.

- Bake the surface-font vertical correction into the metrics (noted 2026-07-14).
  The bitmap `SurfaceFont`s render top-heavy (grid ascent 12 of cellHeight 16),
  so text drawn at a naive top inset reads high, and call sites compensate ad hoc
  with optical offsets (chrome header/footer at -3, the selection list now
  centres on the row height, value cells centre the glyph). This drifts and gets
  forgotten (the arrangement order list sat 2 px high until fixed). Structural
  fix: fold the correction once into the font baseline / `drawText`, so a call
  site that asks to centre in a rect gets an optically centred result with no
  manual nudge — then audit and remove the scattered offsets (chrome, value
  cells, toggles, lists). Concretely wanted: a `drawText(..., centeredIn: rect)`
  / `verticalCenterInset(for style:, height:)` API that derives the baseline +
  optical offset from the font metrics, so mixed mono/proportional rows align
  automatically and nobody hand-tunes a `+1` per case (the selection list needed
  a baseline-alignment *and* a +1 nudge on 2026-07-14 — that should be free).

- Widget Lab hardware review completed on 2026-07-13. The complete rebuilt demo
  catalog and its current shared-HIG presentation were exercised on the physical
  MK2 and accepted as the hardware baseline. This includes chrome typography,
  selection rows, function-bar availability states, value-cell depth, shift
  presentation, tracker geometry, meter ballistics/styles with optional peak hold,
  and the light-guide/LED diagnostics including the physical CLEAR action. Future
  changes to these surfaces require a fresh hardware review rather than reopening
  the accepted baseline implicitly.

- Prototype implemented: Paulinche can optionally use the F1-F4 RGB lamps as
  four channel VU meters while playing a song or pattern. Existing quantized
  realtime telemetry feeds a removable `MK2Surface2` lamp overlay, independent
  of scene/display rendering and the audio thread; disabling it restores the
  scene-owned F-key lamps. It uses normal full 80-byte `0x80` state reports,
  latest-wins coalescing, and writes only when a quantized colour changes. Visual
  response, release feel, latency, and daemon/USB behaviour during playback were
  accepted on hardware; keep the feature. As a separate experiment, test whether
  a shortened `0x80` prefix report preserves
  omitted LEDs, but do not depend on partial reports unless that firmware
  behaviour is repeatable across the supported S49/S61/S88 MK2 models.

- Value-cell deboss tuning accepted on hardware on 2026-07-13: the four gradient
  factors live in `MK2ValueCell.draw` — border ring `0.45` (top shadow rim) → `1.8`
  (lit bottom edge), fill `0.7` → `1.2`. Everything built on `MK2ValueCell`
  follows automatically (parameter pages, encoder footers, selection filter cells).
- Candidates for extending the pseudo-3D language, deliberately deferred: meter and
  progress *tracks* are semantically wells and could deboss like the value cells;
  soft-key strips and button chips are pressable and should read *raised* (chrome-band
  bevel direction) or stay flat — do not deboss them. The value-cell prerequisite is
  now signed off; assess these extensions independently before implementation.

- Shift follow-ups (the scene-owned modifier layer itself is delivered,
  `Docs/Shift-Layer-Plan.md`): `MK2HIG.Chrome.shiftAccent` (amber) and the dim/bright
  shift-lamp intensities were accepted on OLED/hardware on 2026-07-13; other
  held-button layers and a latching shift would be `MK2Surface2`-local extensions
  of the same layer model; MIDI routing deliberately stays base-only under shift;
  multi-band display diffing only if the near-full-band blit on shift flips ever
  shows as a cost.
- Still open: keep tuning cache granularity for shaped runs, whole words, or the fixed set
  of tracker cells (e.g. the 256 hex cells, note names).
- Add a dedicated `SurfaceFont`/FreeType benchmark; the current `PixelPipelinePerfTests`
  `PERF drawText ...` line measures the older 5x7 pixel-font helper, not the JetBrains
  Mono `SurfaceFont` path.

- Caveat to revisit: capital umlauts (`ÄÖÜ`) clip at the top of the 16 px grid cell because
  JetBrains Mono's diacritics + descenders want ~17 px. The tracker grid is ASCII so it is
  unaffected, but grid text with capital umlauts (e.g. instrument names) loses its dots.

- Grow the DSL's first-class element vocabulary; hand-drawn content still hiding in
  `MK2RenderBlock`/`MK2AnyScreenElement` escape hatches bypasses the element contract
  (no build-result participation, no shift-pass awareness, no reuse) and re-invents
  layout constants inline. Remaining offender: the Paulinche instrument
  `infoLines` key/value stack. (Done 2026-07-13: the tracker pattern grid + minimap —
  DSL-review C1 — are now `MK2PatternGridElement` + `MK2OverviewScrollbarElement` in the
  Kit, with `MK2PatternGridColors`/`MK2OverviewScrollbarColors` as the single-source
  hardware palette; WidgetLab `TrackerPatternDemo` and Paulinche `PaulinchePatternRenderer`
  both consume them, pixel-identical before/after.)

- Encoder-slot geometry is duplicated by convention, not enforced: every page passes
  its own footer rect (now `x: 8, width: 464`) into `MK2ParameterPageElement`, and only
  discipline keeps four-column pages aligned with `MK2ScreenLayout.encoderSlotXs`/
  `encoderSlotWidth`. Introduce a dedicated encoder-row container element that owns the
  canonical rect and spacing/padding itself, so individual pages cannot drift.

- Encoder-feel constants should be live-tunable in the widget lab before the
  next tuning round: the ENCODER FEEL rig (scene lab) shows the derived
  counts-per-step and acceleration ceilings, but changing
  `targetSweepCounts`/`maximumCountsPerStep`/`minimumCountsPerStep`/
  `fastSweepCounts` (and the rate thresholds in `MK2EncoderDetents`) still
  means rebuild-and-relaunch per iteration — the 2026-07-12 calibration took
  four builds. Wanted: select a constant with the 4-D encoder, adjust it by
  turning, and have the rig re-derive labels and feel immediately. Requires
  the constants to become an injectable configuration (e.g. an
  `MK2EncoderFeel` struct threaded through `MK2EncoderDiscreteValue` and
  `MK2EncoderDetents`) instead of `static let`s. Current bench-approved
  values: sweep 480, max 42, min 24, fast sweep 600, rates 150/1200 c/s.

- Scene preview thumbnails (idea 2026-07-13): render the next scene as a
  downscaled pixmap and show it as a thumbnail — first use is the demo
  browser's detail pane, but the real target is a reusable
  `MK2ScenePreviewElement` (frames or a whole `MK2SurfaceScene2` + a mode of
  OLED A / OLED B / both-side-by-side + a target rect → scaled + drawn, with
  an optional border and dimmed brightness so it reads as a preview, not the
  live screen). Feasibility is high: the snapshot harness already builds a
  demo's scene without presenting it, `MK2PixelImage` already downscales via
  CoreGraphics `.high` (only its input needs a raw-RGB565 path next to the
  encoded-`Data` one, ~30 lines), and `MK2ImageElement` already embeds a
  pixmap with brightness. Two things to design first: (1) thumbnails must be
  cached — building a scene per 4-D turn would hitch on the heavy demos
  (Waveform's 2048-bin envelope, Panorama's image gen), so build each once
  (ideally all on browser open) keyed by demo id, no invalidation needed;
  (2) previews need a side-effect-free build path — `buildScene` is not pure
  today (the tracker stores its `context`), so a dedicated `preview()` path
  next to `prepareSnapshot()` is cleaner than reusing `buildScene`. Beyond
  the lab, the same element previews what sits behind the Paulinche view
  selectors (PATTERN / PLUGIN / SCENE) before switching. Text is unreadable
  at 2x downscale — the thumbnail conveys layout and colour, not glyphs.

- Enforce content-area size invariants (design direction, 2026-07-13). The
  header/footer formalization gives every scene the correct (footer-shortened)
  `contentRect`, but it only *offers* the geometry — it does not *enforce* it.
  Elements take `contentRect.origin` as their base and then place content with
  absolute y-offsets, and nothing checks against `contentRect.height`, so an
  element can draw past `content.maxY` into the footer band (seen: the
  selection-browser detail pane at `y:112`, whose metadata row at `topY+90`
  landed in the footer once the footer shortened the content). The geometry
  *knew*; it just was not *enforced*. Staged direction, cheapest-first:
  1. Give content elements an `intrinsicMaxHeight` derived from font pixel size
     × maxLines + chrome constants — all compile-time-known, so an element's
     vertical extent stops being a guessed number.
  2. Add a vertical stack container that *computes* child positions from those
     heights instead of letting each screen hand-place magic y-offsets; for
     "normal app" screens (not the widget-lab calibration screens) that removes
     the whole class of guessed offsets. Overflow then reduces to one guard
     point (stack exceeds content), not a scatter of hard-coded y's.
  3. Debug/snapshot guard (wanted perspectively, not now): a check that fires
     when a content element draws below `content.maxY` or above the header —
     zero release cost, catches the dynamic remainder in the snapshot suite,
     and would have caught the `y:112` bug at test time.
  4. Later polish: a `#Screen` Swift macro for real *compile-time* errors on
     fully static production screens (sum literal y-offsets + font×maxLines
     heights, emit an `error` diagnostic on overflow). Only worth the macro
     maintenance once there are enough static production screens to amortize
     it; it only covers literal positions/heights (dynamic offsets fall back to
     the runtime guard). Swift limits to keep in mind: no dependent types / no
     const-generic arithmetic, so the compiler cannot verify `y+h ≤ H` on its
     own, and fully verified layouts are out of scope — macros are the only
     compile-time-error path.

- Meter ballistics approved on hardware 2026-07-13 and lifted into the Kit.
  Release 360 ms, peak hold 300 ms, peak fall 1500 ms (all to -20 dB),
  reference rate 50 fps, silence floor 0.003 — the semantic defaults live in
  `MK2HIG.Meter.Ballistics`. The transformation is now `MK2MeterBallistics`
  (pure, rate-independent, unit-tested): instant attack, exponential release,
  hold-then-fall peak, parametrized in time units so the decay derives from the
  caller's tick interval. Clients own the time driver and call
  `step(tickMilliseconds:)`; the meter demo drives it, a future Paulinche VU
  meter / meter scene shares it. `MK2MeterElement`/`MK2MeterChannel` stay
  stateless (momentary `level`/`peak`).

- Meter bar styles implemented and approved on hardware (2026-07-13):
  `MK2MeterElement.Style` offers `.solid`, `.gradient`, `.segmented`, and
  `.protracker`; all four use the global saturated green-yellow-red
  `MK2HIG.Meter` scale. The ProTracker reminiscence was corrected against a
  magnified original: black track, continuous scale, narrow bright left bevel,
  broad main face, and stepped dark right flank. It is the strongest-looking
  variant in the hardware review. Peak display is orthogonal (`showsPeak`) and
  works with every style. In the meter demo, INSTANCE cycles styles and
  SHIFT+INSTANCE toggles the peak marker. `.solid` remains the API default for
  compatibility; products can select the preferred style explicitly.

- Tracker header zone whitespace accepted on hardware (2026-07-13). The
  pattern grid's top zone carries a fair bit of air: 8 px above the status
  line, then ~14 px between the status line and the channel headers, so the
  status line floats. Not a regression — this geometry is unchanged from the
  original tracker, and the widget-lab `TrackerPatternDemo` and the Paulinche
  `PaulinchePatternRenderer` are metric-identical here (verified 2026-07-13):
  status line y8, channel headers y38, M/S toggles y34 (x+69/x+87), grid rule
  y55, gridTop 60, rowHeight 16, channelXs [48,153,258,363], rulerXs
  [36,141,246,351,456]. Only the status-line *content* differs (widget lab: 5
  hand-drawn labels; Paulinche: `MK2StatusLineElement` with 4 items). The current
  spacing reads correctly on the real OLED and remains the baseline; do not
  tighten it merely to expose more grid rows. The geometry now lives once, in
  `MK2PatternGridElement` (both consumers share it, so it cannot drift); a later
  change edits the element and both follow.

- Beat-stripe verification (2026-07-13): a suspected Paulinche-only "beat cell"
  highlight turned out to be pixel-identical in both implementations — both
  striped every 4th row in `rowStripe` 0x1083. Neither derived the interval from
  the time signature. The shared `MK2PatternGridElement.BeatStripe` is now
  configurable (`.every(interval, phase:)` / `.none`, default `.every(4)`), and
  `MK2PaulinchePatternScene.beatInterval` (default 4) plumbs it through.
  Deferred: the Paulinche app should set `beatInterval` from the song's time
  signature (4/4 → 4, 3/4 → 3) instead of the constant, so odd meters stripe
  on the beat.

- Widget-lab REPL: commit or cut — promoted to **Next up** at the top of this
  backlog (2026-07-14).
