# Navigation & Arrangement — Proposal (2026-07-13)

Goal: one coherent navigation model across all levels of a song, so a complete
song can be built and arranged on the hardware. The immediate deliverable is the
**Scene** level (called *Arrangement* in the app) on both software and hardware.

## 1. The unifying idea — three cursor levels, one control grammar

The `TrackerCursor` already spans the whole song:

| Level | Cursor field | What it addresses |
| --- | --- | --- |
| **Scene / Arrangement** | `cursor.order` | position in the song's order list (`song.orders`) |
| **Pattern** | `cursor.row`, `cursor.channel` | position inside the current pattern |
| **Cell / Field** | `cursor.field` + value | the field being edited |

The problem today is not the model — it is that controls do not map to these
levels consistently (channel selection lives on E1–E4 touch *and* PAGE *and*
4-D-left/right; order navigation lost its only home when E2 was repurposed; the
demo and the app disagree on what PAGE and the 4-D directional do).

The fix is a **control grammar**: every control class has one role that holds
across every scene.

## 2. Proposed control grammar

### Level switch — dedicated hardware mode buttons
The MK2 already has semantically-named buttons; use them as the top-level switch.

| Button | Switches to | App mode |
| --- | --- | --- |
| **SCENE** | Arrangement scene | `SurfaceSceneMode.arrangement` (new) |
| **PATTERN** | Pattern editor | `.pattern` |
| **TRACK** | Instrument / channel detail | `.instrument` |

`SurfaceSceneMode` today is `.pattern`/`.instrument`; add `.arrangement`. The
buttons are momentary mode switches, lit when their mode is active.

### 4-D wheel — the universal cursor of the active scene
One rule everywhere: **the 4-D wheel navigates the active scene.**

| Gesture | Pattern scene | Arrangement scene | Instrument scene |
| --- | --- | --- | --- |
| Rotary | row (`moveCursorRows`) | order (`selectOrder`) | list scroll |
| Push ↑/↓ | row ±1 | order ±1 | list ±1 |
| Push ←/→ | channel ±1 | (page/section) | — |
| Push center | focus edit field | **drill into order → Pattern scene** | select |

This gives Arrangement its lost navigation back (rotary = order) *and* makes the
center push the "enter" gesture that ties the levels together: on an order in
the Arrangement scene, center drills into that order's pattern.

### E1–E4 — the channel band (already landed for Pattern)
Touch selects the channel (E1→ch0 … E4→ch3), rotate moves the row. Keep as-is in
Pattern. In Arrangement they are inert or mirror the 4-D (rotate = order); decide
when building the scene.

### E5–E8 — the value/field editors
Touch focuses the field, rotate edits it (Pattern: note/inst/vol/fx). In
Arrangement, E5–E8 edit the *selected order's* properties (which pattern it
plays, repeat count) — the same "touch-to-focus, rotate-to-edit" grammar.

### PAGE < > — page the active scene's window (consistently)
Reassign so demo and app agree:

| | Pattern scene | Arrangement scene |
| --- | --- | --- |
| PAGE < / > | channel page (when > 4 channels) | page the order list |

The current Paulinche binding (`appendPattern` / `duplicateCurrentPattern`) moves
to the **Arrangement scene's softkeys**, where pattern/order management belongs.

### Transport — global, unchanged
Play / Stop / Rec / Loop / Metro work identically in every scene.

### Softkeys F1–F8 (+ SHIFT) — scene-specific actions
- Pattern: Copy / Paste / Clear / Trim … (as today).
- Arrangement: **Insert · Duplicate · Delete · Move− · Move+** (base), **Clear
  Arrangement** (shift). All commands already exist (`appendPattern`,
  `duplicateCurrentPattern`, `deleteCurrentOrder`, `moveOrder`,
  `clearArrangement`).

### SHIFT — alternates per scene, momentary (unchanged)

## 3. The Arrangement scene (the new build)

Architecture already supports it: add `SurfaceSceneMode.arrangement`, a
`SurfaceArrangementScene` content case, and an `arrangementScene(...)` builder in
`ControlSurfacePort` beside `trackerScene`. On the Kit side, a renderer that
reuses existing elements.

**Left screen — the order list** (the arrangement):
`POS │ PATTERN │ LEN │ ⟳repeat`, one row per order, current order highlighted.
Reuse the pattern grid's row/selection idiom (`MK2SelectionColumn`, or a slim
`MK2ArrangementListElement`) plus **`MK2OverviewScrollbarElement`** on the right
edge for the whole-song minimap — the element already exists from C1.

**Right screen — the selected order's detail**:
which pattern it plays, its length/repeat, and a **downscaled preview of that
pattern** — the first concrete use of the backlogged scene-preview thumbnail
(`MK2ScenePreviewElement`). E5–E8 edit the order's properties.

**Navigation in Arrangement** (per the grammar above): 4-D rotary / ↑↓ →
`selectOrder`; 4-D center or PATTERN → drill into the order's pattern; softkeys →
insert/duplicate/delete/move.

This closes the loop **Arrangement (SCENE) ↔ Pattern (PATTERN) ↔ cells**, which
is exactly what a complete song needs.

## 4. Reconcile the widget-lab demo with the app
The demo is the calibration reference, so it must model the same grammar: PAGE =
channel page (not channel switch); 4-D ←/→ = channel; E1–E4 = channel band. Add a
new **Arrangement demo** to the widget lab to calibrate the scene before wiring
the app.

## Implementation status (2026-07-13)

Done — the arrangement loop works end to end (SCENE → order list → PATTERN drills in → edit → play):
- **Repeat count** on `OrderEntry`, honoured by both players and the timeline (Paulinche).
- **`MK2ScenePreviewElement`** (pattern thumbnail) and **`MK2PaulincheArrangementRenderer`** (two-screen arrangement scene reusing the list, minimap, preview and parameter-page elements) — CompleteControl.
- **`SurfaceSceneContent.song` + `ControlSurfacePort.songScene`** projecting the arrangement from `song.orders`; adapter maps it to the renderer.
- **Navigation grammar**: `surfaceMode` app-state, SCENE/PATTERN mode switch, 4-D wheel + E1-E4 rotation → `selectOrder` in the arrangement (E1-E4 touch inert there), arrangement soft keys Insert/Dup/Delete/Move±.

Also done:
- **PAGE per mode**: row page (±16) in the pattern grid, order page (±8) in the arrangement; `appendPattern`/`duplicate` moved off PAGE to the arrangement soft keys. (Pattern-mode PAGE pages rows, not the proposal's channel page — channel paging is app-state and only matters past four channels, so it stays deferred.)

Also done:
- **Arrangement layout rework (2026-07-14, hardware review):** the right screen renders the selected order's **real pattern grid** (reused `MK2PatternGridElement` + minimap), not the schematic thumbnail; the order properties are an **E1-E4 footer under the order list** (left screen), where those encoders physically sit. E2 edits REPEAT; the 4-D wheel navigates orders. The pattern-grid projection is now shared (`patternGridContent`) between the editor and the preview. `MK2ScenePreviewElement` stays in the Kit as the reusable thumbnail for the scene-preview backlog item, currently without a consumer.
- **SCENE/PATTERN mode lamps** as a radio pair (active bright, other dim).
- **Repeat-count editing** on E6 in the arrangement (`changeOrderRepeatCount`); E5/E7/E8 (pattern/length/position) are inert until wired, and E5-E8 no longer edit hidden cells in song mode.

Deferred (follow-ups):
- **Channel paging** on PAGE in the pattern grid (needs >4-channel support + app-state wiring).
- **TRACK button** → instrument/channel view.
- **Explicit 4-D-center drill-in** (PATTERN button already drills in).
- **PATTERN/LEN/POS editing** on E5/E7/E8 in the arrangement (repeat count on E6 is wired).

## 5. Order of work (original plan)
1. **Straighten pattern-scene navigation** (small): reconcile PAGE + 4-D roles
   between demo and app; wire 4-D directional in the app router (it is currently
   unbound there). Give `selectOrder` its home on the 4-D rotary once the
   Arrangement scene owns the active level — until then, a stopgap (SHIFT+PAGE).
2. **Kit — Arrangement elements**: `MK2ArrangementListElement` (or reuse
   `MK2SelectionColumn`) + reuse `MK2OverviewScrollbarElement`; build and
   snapshot-test via a new widget-lab Arrangement demo.
3. **Kit — `MK2ScenePreviewElement`**: pattern → downscaled pixmap, for the
   Arrangement detail pane.
4. **App — arrangement mode**: `SurfaceSceneMode.arrangement`,
   `arrangementScene(...)` in `ControlSurfacePort`, SCENE/PATTERN/TRACK buttons
   switch modes, arrangement softkeys + 4-D → `selectOrder`, PAGE reassignment.
5. **End-to-end**: build a full song on hardware — add patterns in Arrangement,
   drill in, edit, arrange, loop, play.

## 6. Decisions (settled 2026-07-13)
- **SCENE / PATTERN / TRACK** are the three mode buttons — accepted.
- **4-D center = drill-in** — accepted.
- **Repeat count per order — now.** `OrderEntry` gains a `repeatCount`, editable
  in the Arrangement detail pane and honoured by playback.
- **Skip the widget-lab Arrangement demo for now** — wire straight into Paulinche
  to avoid duplicating the scene. The reusable pieces still land in the Kit
  (`MK2ScenePreviewElement`, reused `MK2OverviewScrollbarElement`, the arrangement
  list element) so a calibration demo can be added later without a rewrite.
