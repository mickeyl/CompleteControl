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

- Done: FreeType font rendering is available through `KontrolSurfaceKit2` and
  `MK2FreeTypeDemo` for large, well-hinted typography. The production text choice is
  IBM Plex Sans Condensed Regular 16 px for body and Medium 24 px for titles, rendered
  with `grayscaleHinted`. Icon work uses Font Awesome 7 Pro Light, with 48 px icons for
  action dialogs. The bitmap-font rendering path remains separate for tracker/grid sharpness.

- Experiment (branch `freetype`): the whole `SurfaceFont`/`BitmapLabel`/`drawText` path
  now lowers to FreeType + JetBrains Mono (Regular + Bold), reproducing the retired
  Tamzen atlas metrics exactly so no layout moves. See `FreeTypeTextRenderer.drawMonospaced`.

- Text should render whole **glyph runs, not glyph-by-glyph.** Per-glyph rasterization
  (the current `drawMonospaced` / `drawText`) is the wrong shape: it re-runs the hinter +
  rasterizer for every glyph on every frame, and it throws away kerning because the pen
  advances one isolated glyph at a time. Runs fix both:
  - **Kerning:** a run lets FreeType apply pair kerning / (ideally) HarfBuzz shaping, which
    only exists across adjacent glyphs. Matters for the proportional path (Plex titles/body);
    moot for the fixed-pitch monospace faces, but the renderer is shared so the run API
    should carry kerning for the proportional case.
  - **Caching at block granularity:** cache larger units — shaped runs, whole words, or the
    fixed set of tracker cells (e.g. the 256 hex cells, note names) — keyed by
    `(face, pixelSize, weight, rasterMode, text)`. A cached block draw becomes a bitmap
    copy/alpha-blend with no shaping or rasterization, recovering most of the old atlas
    speed (which came from run-length `memset_pattern4` fills) even at `-Onone`.
  - Measure via `PixelPipelinePerfTests` (`PERF drawText …`); current per-glyph cost is
    ~0.5 ms / 60 chars at scale 3, dominated by `FT_Load_Char` rasterization, not the blit.

- Caveat to revisit: capital umlauts (`ÄÖÜ`) clip at the top of the 16 px grid cell because
  JetBrains Mono's diacritics + descenders want ~17 px. The tracker grid is ASCII so it is
  unaffected, but grid text with capital umlauts (e.g. instrument names) loses its dots.
