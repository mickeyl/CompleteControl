# MK2 Widget Lab — Plan

Status: draft, for iteration before implementation starts. Companion to
`Docs/MK2-Porting-Plan.md` (pixel substrate — reconciler, wire format, perf) and to
`../Paulinche/MK2_SURFACE_PLAN.md` (the client's own MK2 UI design, already detailed —
read that first if you haven't; this plan is scoped to *not* duplicate or diverge from it).

## Why this exists

`KontrolSurfaceKit2`'s engine — `PixelDisplayReconciler2`, wire-order pixel storage,
band-diffing, the queue split, reconnection replay, encoder feel — is now measured-good
and functionally validated (this session's testing: encoder lab rated "PERFECT", all
demo pages functional, button bindings fixed, LED/display serialization fixed on
hardware). But everything built on top of it is still **100% imperative**: every
`MK2SurfaceDemo` page is hand-written pixel arithmetic —

```swift
var frame = MK2PixelFrame(fill: 0x0000)
frame.drawText("RIBBON LAB", x: 20, y: 46, scale: 4, color: 0xffff)
frame.horizontalBar(MK2PixelRect(x: 20, y: 120, width: 440, height: 40), value: 0.5, fill: 0x07e0, track: 0x2104)
```

That's fine for one demo tool with 8 pages. It does not scale to what Paulinche actually
needs (see below) — Paulinche would end up reinventing the same pixel arithmetic under
real product pressure instead of composing proven widgets. `KontrolSurfaceKit` (the MK1
kit) already proved the right shape for this: a declarative `Screen` DSL (`Cell`, `Label`,
`Bar`, `Value`) that lowers to a model and reconciles automatically. Kit2 has the engine
but not that composable layer. CLAUDE.md's own priority list (`Canvas`/`BitmapLabel`/
`Meter`/`PatternGrid`, list/menu nav, strip LED as a DSL element) and
`Docs/MK2-Porting-Plan.md`'s "Path forward" step 3 ("port the Paulinche `PatternScreen`")
both point at this same missing layer.

**The widget lab's job**: build that composable layer and validate each widget
self-contained, against real Paulinche data shapes and the real measured reconciler
costs, *before* Paulinche's actual screens depend on it.

## Grounding: what Paulinche actually needs (read from source, not guessed)

I read `../Paulinche` directly rather than assume. Key facts that shape this plan:

- **`MK2_SURFACE_PLAN.md` already exists and is detailed** — four modes (PATTERN/SONG/
  ARRANGE/INSTRUMENT/PERFORM), a `SurfaceScene` semantic-model architecture (device-
  independent, MK1 becomes a down-projection special case), soft-key semantics, an
  8-encoder binding table per mode, a full color-role palette, and **nine rendered
  mockups** at `../Paulinche/Docs/surface-mocks/*.png` (via a vendored-Tamzen Python
  BDF renderer, `Scripts/surface-mocks/render_mocks.py`). It is phased P0–P4; **only the
  MK1 segment-display path is implemented today** (`Sources/PaulincheControl/
  ControlSurfacePort.swift`, `ControlInputRouter.swift`,
  `Sources/PaulincheCompleteControlAdapter/CompleteControlSurfaceAdapter.swift` — all
  target the frozen `KontrolSurfaceKit`, not kit2). This plan does not re-derive that
  design; it targets producing the pixel primitives P1 onward needs.
- **Real data model** (`Sources/PaulincheCore/Song.swift`, `Note.swift`,
  `Sources/PaulincheCore/AppState.swift`): `PatternCell{note, instrument, volume, effect,
  amigaPeriod}`, `Note{pitchClass, octave}`, `EffectCommand{code, argument}`,
  `PaulincheSong.channelCount` (default 4, MOD-style; plan anticipates XM/S3M wider songs
  via horizontal paging). `PlaybackState.mutedChannels`/`soloedChannels: Set<Int>` — real,
  wired, tested. Live VU: `RealtimePlaybackEngine` polls channel levels every 16ms into
  `ChannelMeterHoldState`/`ChannelMeterBins` (level + peak-hold) — real, running today,
  rendered as a 12-segment LED bar in `ContentView.swift`'s `TransportBar`.
- **What does NOT exist yet**: no per-channel volume/pan fader or EQ model. The `MIXER`
  mockup (`view-mixer.png`) shows sliders/dB values with no backing state in
  `PaulincheAppState` — it's an aspirational sketch, not a data contract. **Don't build a
  Mixer widget against it** until/unless Paulinche's model grows that state.
- **The command surface**: `Command.swift`'s ~59 `PaulincheCommandID` cases are the full
  verb list any widget's input binding ultimately calls into (transport, cursor movement,
  cell editing, tempo/speed, instrument select, order/pattern management). Nothing here
  needs new verbs invented — the lab binds to what already exists.

### The font gap (your tangential question, answered)

**No, we are not using Tamzen or any real bitmap font today.** `KontrolSurfaceKit2`'s
`MK2PixelFont` (`Sources/KontrolSurfaceKit2/PixelFrame.swift:187-238`) is a hand-rolled
placeholder: 5×7 bit patterns for digits, uppercase A–Z, and a handful of symbols
(`-+/:.`?`) — no lowercase, no umlauts, no punctuation beyond that. `drawText` forces
`.uppercased()` on its input (line 129) because lowercase glyphs don't exist. It was
built to get `drawText` *working*, not to be a real font.

Tamzen **is** a real, already-made decision — but it was made on the Paulinche side,
documented in `MK2_SURFACE_PLAN.md`'s "Visuelle Konventionen": a three-tier system (Grid
8×16, Labels 6×12, Readouts 10×20, each with a real Bold cut, no faux-bold, no italic),
189 glyphs (ASCII + Latin-1, covers umlauts and note names), vendored from
`github.com/sunaku/tamzen-font`, with a stated integration plan of "BDF → build step →
glyph atlas → blit." That pipeline is implemented today only in
`Scripts/surface-mocks/render_mocks.py` (pure-Python, for offline mockup rendering) —
**explicitly not** wired into the real Swift app or into CompleteControl. The BDF files
themselves are already vendored at `../Paulinche/Scripts/surface-mocks/fonts/
Tamzen{6x12,8x16,10x20}{r,b}.bdf`.

This is why the font pipeline is **phase A** below, not an afterthought: every other
widget's legibility depends on it, and the current `MK2PixelFont` physically cannot hold
Tamzen-sized glyphs (it's a fixed 7-row `InlineArray`; Tamzen's grid size alone is 16
rows). One thing worth preserving from the current implementation: `drawText`'s
run-merging `memset_pattern4` blit (adjacent set bits in a glyph row become one bulk
write, not per-pixel stores) is exactly the kind of hot-path discipline this project
cares about — the Tamzen blitter needs to keep that pattern, not regress to a naive
per-pixel loop.

## Proposed widget catalog

Each maps to a specific thing I saw in the real mockups or the real data model — not
speculative UI. Ordered by build sequence (see Phases).

1. **Tamzen font pipeline** (foundational, blocking everything else) — a build-time
   step (mirror `render_mocks.py`'s BDF parser, but emit a Swift-consumable glyph atlas
   asset rather than PNGs) + a `SurfaceFont` role enum (`.grid`/`.label`/`.readout`,
   `+bold`) replacing `MK2PixelFont`'s placeholder table. Keeps the fixed-width,
   run-merged blit strategy — Tamzen is monospace bitmap, no proportional-spacing work
   needed.
2. **`BitmapLabel`** — declarative text: font role + color + optional invert (fg/bg
   swap for the cursor/highlight convention Paulinche's doc specifies — "inverse =
   rendering, not a font variant"). Thin wrapper once (1) exists.
3. **`Meter`** — VU/level bar with ballistics (rise/fall/peak-hold), bound directly to
   Paulinche's real `ChannelMeterHoldState`/`Bins` shape. Extends the existing
   `horizontalBar`/`centeredBar` primitives with decay state.
4. **`ToggleChip`** — small M/S-style state chip (red=mute active, yellow=solo active,
   dim=inactive) — matches the *real, state-backed* half of the mixer mock (mute/solo),
   deliberately excluding the fader part.
5. **`ListSelect`** — scrollable list, one highlighted row, optional two-column layout.
   One widget serves two mockups: the INSTRUMENTS browser (`view-instrument.png` left
   pane) and the FX-reference overlay (`view-fx-reference.png`) — same shape, reused.
6. **`SoftKeyRow`** — the 8 context-labeled keys above the display, core to Paulinche's
   whole soft-key concept ("the 8 keys become context-dependent — their function is
   printed right next to them and changes per mode"). Pixel-trivial (an 8-slot label
   strip) but needs a clean label+handler-pair binding API that's reused by every mode.
7. **`PatternGrid`** — the tracker grid itself: rows × channels, per-cell note/inst/
   vol/fx styling, cursor row (blue bg, no `>` prefix per the doc), playhead row (green
   ruler on top + dark green bg, both visible when cursor==playhead per the doc's
   explicit collision rule), dimmed muted channels, dotted channel rulers, hex row
   numbers. The single highest-value, highest-complexity widget in the catalog — it's
   the whole point of PATTERN mode. Build directly against `PatternCell`/`Note`/
   `EffectCommand` shapes so there's no adapter-layer guessing later.
8. **`WaveformView`** with playhead-as-sprite-over-cached-background — the compositing
   pattern Paulinche's doc works out in real detail: cache waveform+beacons as a "clean
   background" buffer, recompute only the dirty band between the old and new playhead
   column, one `0x84` blit per frame (not a full redraw). This is a good lab candidate
   specifically because the perf strategy is already designed on paper — the lab is
   where we prove it against the real reconciler before Paulinche needs it working.

**Explicitly not proposed**: a full per-channel Mixer fader widget (no backing state —
flag to the Paulinche side if/when they add channel volume/pan), a live oscilloscope
(rejected in `MK2_SURFACE_PLAN.md` for latency reasons — VU meters only change bar
length, a scope repaints continuously), on-surface text entry (explicitly deferred in
the same doc).

## Phases

Each phase = widget(s) + one dedicated lab page exercising it + a
`PixelPipelinePerfTests`-style stage-timing addition if the widget adds new hot-path
cost. Measure before calling it done, per this project's established discipline this
session.

- **Phase A — Tamzen font pipeline.** Blocking prerequisite for everything else.
- **Phase B — `BitmapLabel` + `Meter` + `ToggleChip`.** Small, mechanical; exercises the
  new font against the reconciler for the first time.
- **Phase C — `ListSelect` + `SoftKeyRow`.** Needed by both the instrument browser and
  the FX-reference overlay; also the first widget with input bindings (scroll/select),
  not just static render.
- **Phase D — `PatternGrid`.** The centerpiece. Build against real `PatternCell`
  shapes; worth borrowing/mirroring a slice of Paulinche's own pattern fixtures for
  realistic test data rather than inventing placeholder cells.
- **Phase E — `WaveformView` + playhead compositing.** Only needed for INSTRUMENT mode
  (Paulinche P3), can land in parallel with C/D rather than strictly after.

Recommend A–D land before Paulinche's P1 (MK2-pixel-adapter + PATTERN mode) starts,
since P1 needs `PatternGrid` + `BitmapLabel` + `Meter` + `SoftKeyRow` all working
together. E can trail into Paulinche's P2/P3 without blocking P1.

## Open questions before implementation starts

1. **New tool or extend `MK2SurfaceDemo`?** I'd lean **new dedicated tool**
   (`Tools/MK2WidgetLab`) — `MK2SurfaceDemo` is already 670 lines / 8 pages covering
   input-and-lifecycle testing broadly; a widget lab is a different concern (isolated
   widget rendering, not full input/reconnection/eviction coverage) and deserves its own
   small, well-named home per this project's file conventions. Open to argument the
   other way if you'd rather keep one demo binary.
2. **Where does the widget catalog live?** `KontrolSurfaceKit2` proper, not the lab tool
   — Paulinche imports only kit2 per CLAUDE.md's structure decision, so the widgets need
   to be library code, not demo-only.
3. **Tamzen vendoring**: mirror Paulinche's approach (vendor the BDFs under
   `Vendor/` or similar, generate the glyph atlas at build time). The license is already
   established as fine by the sibling repo's own research — re-confirm before vendoring
   a second copy, or consider whether the atlas could be generated once and shared.
4. **Declarative DSL shape**: does kit2 get a `Screen2`-equivalent result-builder DSL
   (mirroring kit1's `@ScreenBuilder`), or do widgets stay as composable structs applied
   imperatively to `MK2SurfaceScene2`? I'd default to mirroring kit1's proven shape
   unless there's a reason not to — but this is a real design decision worth confirming
   before Phase B locks in an API shape.
