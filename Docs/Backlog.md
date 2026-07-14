# CompleteControl Backlog

## Next up

- **Full REPL remote control / headless UI-testing (prioritised 2026-07-14).**
  Bore the half-remote out into a real one: remote control of every button,
  encoder turn, encoder touch/double-touch and 4-D gesture, injected at the
  `MK2Surface2` input seam (not per-demo verbs), so the widget lab *and* a real
  client (Paulinche via the daemon) can be 100% driven headless. That unlocks
  UI-testing automation — script a sequence of presses/turns and assert on the
  resulting frames through the snapshot path. Concrete motivation: the arrangement
  work (2026-07-14) shipped a SCENE button that lit but emitted no input event
  (missing from the adapter's bind list); a headless remote would have caught that
  in a scripted test instead of on the bench. The simulator wire already carries
  these events, so the missing piece is the REPL/command surface at the input seam.

## Simulator

- Encoder feel is nearly opaque on the simulator (noted 2026-07-14): rotation
  arrives as bare wire deltas, so acceleration/detent tuning gives almost no
  insight there and every judgement waits for hardware. Wanted: surface the
  derived feel on the simulator panel — e.g. show counts-per-step / acceleration
  state, or visualise the mapped vs raw delta — so at least gross
  mis-calibration is catchable without the bench.

## Daemon / libusb architecture

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
