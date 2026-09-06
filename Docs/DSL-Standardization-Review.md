# DSL Standardization Review

Review from 2026-07-11, worked through by 2026-07-13. Implemented are
recommendations A1–A5, B1, B2, B3, and D2 (A1/A2 became moot when the song
renderer was removed), plus, from the backlog side, the per-level lamps, the
removal of `isHardwareShiftPressed`, and the `ControlLampName` enum. The
complete analysis and the finished items are in this document's git history.

**All items worked off (D1 done 2026-07-13).**

## C1 — Tracker grid + minimap into the kit (done 2026-07-13)

`MK2PatternGridElement` (tracker grid) and `MK2OverviewScrollbarElement`
(minimap) now live in the kit, with `MK2PatternGridColors`/
`MK2OverviewScrollbarColors` as the single source of the hardware-approved
palette (2026-07-13). Widget Lab's `TrackerPatternDemo` and Paulinche's
`PaulinchePatternRenderer` both consume them — the five draw helpers on each
side and the inline geometry constants are gone. Before/after
pixel-identical (snapshot diff of 0 pixels for base and shift; the six
Paulinche renderer tests unchanged green), plus eight new focused kit tests.

Careful divergence check beforehand (user suspicion: Paulinche-only beat
cells): the beat stripe was already pixel-identical in both (all 4 rows,
0x1083). The one real divergence was cell coloring — Widget Lab colored
whole cells (`isEmpty`), Paulinche per field (`== nil`); the shared element
adopts the more correct per-field variant. The data model is Paulinche's
optional triad (`note?/instrument?/effect?`); Widget Lab's dead `volume`
grid field is dropped. New: `BeatStripe` is configurable
(`.every(interval, phase:)`/`.none`), so odd time signatures stripe on the
beat — wiring it to the time signature on the app side is in the backlog.

## D1 — Kit-internal helper consolidation (done 2026-07-13)

Four byte-identically duplicated helpers now live exactly once in
`DrawingSupport.swift`: `scaled565(by:)` (color scaling, was 4× in
FunctionKeyBar/ValueCell/Tag/ScreenLayout), `MK2PixelRect.insetBy(dx:dy:)`
(2×, Meter/ScreenDSL), `Int.wrapped(to:)` (2×,
EncoderDiscreteValue/SelectionView), and
`MK2PixelFrame.drawRoundedPanel(…)` (2×, ModalDialog/SelectionView; the
superset with `borderWidth` + the `max(0,…)` guard). All 238 tests unchanged
green.

Deliberately *not* merged: the two `wrappedBitmapLines` (ModalDialog vs
ScreenDSL) are different algorithms — pixel-exact via `font.measure` versus
character-based with `maxLines` and a hard wrap — not a real duplicate.

## Appendix: rejected ideas

- **`FunctionKeyBar` with `edge: .bottom`** — rejected: the hardware has
  function keys only at the top; a bottom variant would produce labels
  without a spatially associated key. The footer belongs to encoder cells
  (bottom-flush, same x slots), not to F-key labels.
