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
- Done: Shift is a scene-owned modifier layer (`Docs/Shift-Layer-Plan.md`). Scenes carry
  an optional `MK2SurfaceScene2.ShiftLayer` (frames, lamps, key colors, bindings with
  base fallback); the DSL builds it in a second pass when a screen declares shift content
  via `MK2ShiftBranch`, `MK2FunctionKeyBarElement` `shiftSlots`/`onShiftPress`, or
  `MK2ParameterPageElement.shiftSlots`. Realized in the WidgetLab pattern lab (CLR
  PAT/REVERSE shift function keys, NOTE→OCTAVE shift encoder cell, automatic shift lamp)
  and in `MK2PaulincheInstrumentRenderer` via `shiftSoftKeys`/`onShiftSoftKey`.
  Deferred follow-ups: review `MK2HIG.Chrome.shiftAccent` (amber) and the dim/bright
  shift-lamp intensities on the OLED/hardware; other held-button layers and a latching
  shift would be `MK2Surface2`-local extensions of the same layer model; MIDI routing
  deliberately stays base-only under shift; multi-band display diffing only if the
  near-full-band blit on shift flips ever shows as a cost.
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

- Done: FreeType font rendering is available through `KontrolSurfaceKit2` and
  `MK2WidgetLabDemo` Unit A for large, well-hinted typography. The production text choice is
  IBM Plex Sans Condensed Regular 16 px for body and Medium 24 px for titles, rendered
  with `grayscaleHinted`. Icon work uses Font Awesome 7 Pro Light, with 48 px icons for
  action dialogs. The bitmap-font rendering path remains separate for tracker/grid sharpness.

- Experiment (branch `freetype`): the whole `SurfaceFont`/`BitmapLabel`/`drawText` path
  now lowers to FreeType + JetBrains Mono (Regular + Bold), reproducing the retired
  Tamzen atlas metrics exactly so no layout moves. See `FreeTypeTextRenderer.drawMonospaced`.

- Done: FreeType text now renders through cached **glyph runs** in `FreeTypeTextRenderer`.
  Proportional `drawText`/wrapped text is shaped by HarfBuzz first, so standard ligatures
  and positioning apply outside tracker/grid text. Fixed-pitch `drawMonospaced`/`SurfaceFont`
  remains unshaped and advances one fixed cell per scalar. The cache stores alpha masks and
  metrics for reusable glyphs plus complete text runs, keyed by family, weight, pixel size,
  raster mode, layout, and text. Drawing a repeated run is now a bitmap alpha-blend with no
  HarfBuzz shaping and no FreeType load/render call.

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
  awareness, no reuse) and re-invents layout constants inline. Known offenders to
  audit: the WidgetLab unit screens (status rows, ad-hoc labels, separator lines,
  pattern overview strip), the Paulinche renderers' title/tag/info-line drawing, and
  the song scenes' `drawSoftKeyStrip` (already tracked below). Candidates for
  promotion: a titled status row, an icon+label tag chip, a plain separator rule,
  and a key/value info-line stack.

- Encoder-slot geometry is duplicated by convention, not enforced: every page passes
  its own footer rect (now `x: 8, width: 464`) into `MK2ParameterPageElement`, and only
  discipline keeps four-column pages aligned with `MK2ScreenLayout.encoderSlotXs`/
  `encoderSlotWidth`. Introduce a dedicated encoder-row container element that owns the
  canonical rect and spacing/padding itself, so individual pages cannot drift.

- The song scenes still draw their soft keys through the ad-hoc
  `drawSoftKeyStrip` (eight 60 px slots at the footer) instead of
  `MK2FunctionKeyBarElement`. Migrate them so all function-button labels share
  the top-flush uniform-grid bar, then retire the strip helper.
