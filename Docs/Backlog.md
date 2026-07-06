# CompleteControl Backlog

## Daemon / libusb architecture

- Revisit the daemon's libusb architecture for MK2 idle and client operation. Display,
  MIDI, surface input, button LEDs, and light guide sit on separate USB interfaces/endpoints,
  but the daemon currently owns them through one device session and one reactor-adjacent
  scheduling model. This can still let slow display work interfere with time-sensitive
  MIDI/light-guide diagnostics even though the hardware endpoints are separate.
- Investigate the least risky path first: keep one libusb device handle, but strictly
  separate the event pump, display blits, and small state reports so MIDI and light-guide
  updates are never queued behind display frames. The NO CLIENT hardware-test mode is a
  good stress case because chords can expose stuck light-guide states.
- Longer-term experiments: dedicated libusb contexts/threads per function class, or
  separate handles for separately claimed interfaces if macOS/libusb behaves cleanly.
  Treat multiple handles as a research item, not the default design, because composite
  USB claiming, shutdown, and reconnect semantics can get fragile.
- Also evaluate whether selected paths should bypass libusb: CoreMIDI for MIDI and IOHID
  for HID-style surface traffic may reduce contention, while MK2 display/custom bulk
  traffic probably remains libusb/IOUSB-level. Avoid mixed backends unless claim conflicts
  and ownership boundaries are understood.

## KontrolSurfaceKit2

- Continue hardening `MK2ScreenDSL` on top of `MK2ScreenLayout`: the first declarative
  `RegularScreen`, `FullScreen`, and `DoubleScreen` builders exist with formal
  header/footer/content slots, HIG chrome, screen elements, and scene merging. Next,
  route WidgetLab screen construction through `MK2ScreenBuildResult` so element-owned
  lamps, light-guide colors, and bindings are merged instead of copied into demo-local
  scene glue.
- Reusable DSL content elements now cover wrapped text, value cells, encoder footers,
  status lines, empty states, progress bars, browser detail panes, and selection
  list/grid wrappers. Still open before Paulinche integration: page/tabs, parameter pages,
  richer meter widgets, and filter-focus encoder helpers.
- Make input binding screen-owned: screens can already declare buttons, encoders, lamps,
  light-guide colors, and basic selection 4-D navigation next to rendering. Next, move
  WidgetLab Browser/Selection to consume `MK2SelectionInputElement` directly and add
  reusable filter-focus gestures.
- Done in WidgetLab tracker demo: Shift is the only first-class key modifier in Kit2.
  `Clear` deletes the currently selected row immediately, without a confirmation dialog;
  `Shift + Clear` clears the whole pattern and keeps the existing confirmation dialog.
  Keep future modifier behavior in the DSL/input layer, not as view-local chord handling.
- Add a WidgetLab realization plus snapshot coverage for each formal screen/component class
  before Paulinche starts consuming them.
- Prepare the Paulinche boundary as a small semantic `SurfaceProjection`: Paulinche emits
  product state and commands, Kit2 renders screens, and hardware input returns as semantic
  events.

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
