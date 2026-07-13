# CompleteControl Backlog

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

- Prototype implemented: Paulinche can optionally use the F1-F4 RGB lamps as
  four channel VU meters while playing a song or pattern. Existing quantized
  realtime telemetry feeds a removable `MK2Surface2` lamp overlay, independent
  of scene/display rendering and the audio thread; disabling it restores the
  scene-owned F-key lamps. It uses normal full 80-byte `0x80` state reports,
  latest-wins coalescing, and writes only when a quantized colour changes. Still
  to assess on hardware: visual response, palette thresholds/release feel, and
  input/display latency plus daemon/USB traffic during dense playback. As a
  separate experiment, test whether a shortened `0x80` prefix report preserves
  omitted LEDs, but do not depend on partial reports unless that firmware
  behaviour is repeatable across the supported S49/S61/S88 MK2 models.

- Value-cell deboss tuning after hardware review: the four gradient factors live in
  `MK2ValueCell.draw` — border ring `0.45` (top shadow rim) → `1.8` (lit bottom edge),
  fill `0.7` → `1.2`. Judged on PNG only so far; adjust on the OLED if the imprint
  should read stronger or calmer. Everything built on `MK2ValueCell` follows
  automatically (parameter pages, encoder footers, selection filter cells).
- Candidates for extending the pseudo-3D language, deliberately deferred: meter and
  progress *tracks* are semantically wells and could deboss like the value cells;
  soft-key strips and button chips are pressable and should read *raised* (chrome-band
  bevel direction) or stay flat — do not deboss them. Decide after the value-cell look
  is signed off on hardware.

- Continue hardening `MK2ScreenDSL` on top of `MK2ScreenLayout`: the first declarative
  `RegularScreen`, `FullScreen`, and `DoubleScreen` builders exist with formal
  header/footer/content slots, HIG chrome, screen elements, and scene merging. WidgetLab
  Browser Lab and Selection Lab now route picker screen construction through
  `MK2ScreenBuildResult`, so element-owned 4-D lamps and bindings are merged instead of
  copied into demo-local scene glue.
- Reusable DSL content elements now cover wrapped text, value cells, encoder footers,
  status lines, empty states, progress bars, browser detail panes, selection list/grid
  wrappers, compact page indicators, tab bars, and parameter pages with screen-owned
  encoder bindings. Meter elements now cover horizontal/vertical multi-channel levels
  with peak markers and warning/danger colours. Still open before Paulinche integration:
  a complete snapshot acceptance set.
- Make input binding screen-owned: screens can already declare buttons, discrete encoders,
  grouped discrete encoder sets, lamps, light-guide colors, and basic selection 4-D
  navigation next to rendering. WidgetLab Browser/Selection picker screens now own their
  4-D navigation and filter encoder bindings; the tracker detail screen now owns its
  edit-field encoder bindings through `MK2ParameterPageElement`. Selection filter encoders
  now use `MK2SelectionFilterEncoderElement`, so focus-touch and value changes are a
  reusable screen-owned pattern.
- Shift follow-ups (the scene-owned modifier layer itself is delivered,
  `Docs/Shift-Layer-Plan.md`): review `MK2HIG.Chrome.shiftAccent` (amber) and the
  dim/bright shift-lamp intensities on the OLED/hardware; other held-button layers
  and a latching shift would be `MK2Surface2`-local extensions of the same layer
  model; MIDI routing deliberately stays base-only under shift; multi-band display
  diffing only if the near-full-band blit on shift flips ever shows as a cost.
- Add a WidgetLab realization plus snapshot coverage for each formal screen/component class
  before Paulinche starts consuming them.
- Prepare the Paulinche boundary as a small semantic `SurfaceProjection`: Paulinche emits
  product state and commands, Kit2 renders screens, and hardware input returns as semantic
  events. Started without coupling the packages: `MK2PaulinchePatternRenderer` renders a
  Paulinche-shaped PATTERN fixture to two MK2 fullscreen panes and binds soft keys through
  function buttons. Continued with FreeType-only SONG and INSTRUMENT fixture renderers so
  the first adapter pass can map concrete Paulinche scene shapes instead of inventing
  screen-local glue. The Paulinche-shaped DSL now lives in the separate
  `PaulincheSurfaceKit` module on top of generic `KontrolSurfaceKit2`.

- Still open: keep tuning cache granularity for shaped runs, whole words, or the fixed set
  of tracker cells (e.g. the 256 hex cells, note names).
- Add a dedicated `SurfaceFont`/FreeType benchmark; the current `PixelPipelinePerfTests`
  `PERF drawText ...` line measures the older 5x7 pixel-font helper, not the JetBrains
  Mono `SurfaceFont` path.

- Caveat to revisit: capital umlauts (`ÄÖÜ`) clip at the top of the 16 px grid cell because
  JetBrains Mono's diacritics + descenders want ~17 px. The tracker grid is ASCII so it is
  unaffected, but grid text with capital umlauts (e.g. instrument names) loses its dots.

- Grow the DSL's first-class element vocabulary; there is still too much hand-drawn
  content hiding in `MK2RenderBlock`/`MK2AnyScreenElement` escape hatches. Every such
  closure bypasses the element contract (no build-result participation, no shift-pass
  awareness, no reuse) and re-invents layout constants inline. Delivered so far
  (DSL review 2026-07-12/13): the tag chip (`MK2Tag`/`MK2TagElement`, B2), the
  separator rule (`MK2SeparatorElement`, A5), the status row (`MK2StatusLineElement`
  with `maxWidth`, A3), and tabular selection lists (`MK2SelectionColumn`, B3). The
  Paulinche instrument/pattern renderers now consume all four instead of drawing them
  by hand. Remaining hand-drawn offenders: the tracker pattern grid + minimap (still
  duplicated WidgetLab ↔ Paulinche — DSL-review C1) and a key/value info-line stack
  (Paulinche instrument `infoLines`, still `MK2RenderBlock`).

- Done 2026-07-13: the Paulinche renderers are migrated onto the standardized
  forms. Instrument-editor title/subtitle → `MK2ContentText` (DSL-review A4),
  pattern-grid status line + right-screen status → `MK2StatusLineElement` with
  the new `MK2StatusLineItem.maxWidth` clip (A3), the info separator →
  `MK2SeparatorElement`, and the kind pill → `MK2Tag` (B2). All three renderer
  snapshots (`paulinche-pattern`, `paulinche-instrument`, `-shift`) are
  pixel-identical before/after. Remaining migration target: the pattern grid +
  minimap themselves (DSL-review C1).

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

- Done 2026-07-13: selection *filter* cells carry the same label-line icons
  as value cells. `MK2SelectionFilter.iconGlyph` reuses `MK2ValueCell.iconGlyph`,
  the filter label dropped its `E<n>` encoder-name prefix (HIG: the cell sits
  above its physical encoder), and the demo browser's CATEGORY filter leads
  with a funnel glyph; the icon browser's LETTER filter leads with an "Aa"
  glyph and MODE with a grid/list glyph that tracks the mode. Remaining
  filter cells (selection demo AREA/SRC) intentionally stay icon-less — no
  distinct glyph suggests itself for a pair of generic filters on one screen.

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

- Lift the meter ballistics into the Kit as a value object (design direction,
  2026-07-13). `MK2MeterElement`/`MK2MeterChannel` render a momentary
  `level`/`peak`; the attack/decay, peak-hold and pulse ballistics live only in
  `MeterDemo`. Any real client (Paulinche's F-key VU meters, a future meter
  scene) would otherwise rebuild the decay loop. Lift the *transformation*
  (`MK2MeterBallistics`: given a momentary value and a time step → smoothed
  level + held-then-falling peak) into the Kit as pure, testable logic; the
  *time driver* (timer/loop) stays app-side — same boundary as the panorama
  render throttle, since a screen element renders statelessly and owns no time.
  The demo already uses the right parametrization to lift: time units
  (release/hold/fall in ms) with the decay factors derived from the frame rate,
  not magic constants. Precondition: bench-approve the values first via the
  meter demo's E5-E8 calibration rig (RELEASE / PK HOLD / PK FALL / RATE) so the
  Kit ships tuned constants, not guessed ones.

- Meter bar styles (2026-07-13): try and support several fill styles for
  `MK2MeterElement`, selectable per use — plain solid, simple gradient (along
  the fill), bi-gradient (two-tone), pseudo-3D (debossed like the value wells,
  since a meter track is semantically a well). Candidates to consider too:
  gradient-by-zone (green→warning→danger along the scale rather than a hard
  threshold flip), and a segmented / LED-ladder style (discrete blocks like
  classic hardware VU). Judge on the OLED. The ballistics calibration rig
  (meter demo, E5-E8) is the place to preview them live.
