# Shift Layer for the Kit2 Screen DSL — Implementation Plan

> **Status: implemented** (all seven steps, 2026-07; exclusive button-layer
> policy added 2026-07-17). One deviation: the
> parameter-page shift variant lives on the element (`MK2ParameterPageElement`
> `shiftSlots:`), not on the slot — Swift rejects the recursive
> `MK2ParameterPageSlot.shift: MK2ParameterPageSlot?` value type, and the
> element-level API mirrors the function bar's `slots`/`shiftSlots` shape.

## Goal

Make SHIFT a first-class, scene-owned modifier in `KontrolSurfaceKit2`: while the
hardware SHIFT button is held, a screen may present alternate content (function-key
bar with rarer actions, changed encoder value cells) and alternate input bindings
(F-buttons, encoders), and everything snaps back on release. Clients declare the
shift variant declaratively in the DSL; no client re-presents scenes on shift
transitions and no view-local chord handling exists (per `Docs/Backlog.md`:
"Keep future modifier behavior in the DSL/input layer").

Concrete driving use case: the Paulinche instrument editor's right screen shows a
function bar with destructive edit actions; holding SHIFT reveals a second set of
rarer actions in the same bar, and encoder cells may swap to alternate parameters
(e.g. fine-step variants).

## Current state (relevant facts)

- `MK2SurfaceScene2` carries two pre-rendered `MK2PixelFrame`s, lamps, key colors,
  and one `MK2InputBindings2`. There is no display variance after `present`.
- Shift exists only as a dispatch filter: `MK2InputBindings2.ModifierRequirement`
  (`.any`/`.unmodified`/`.shift`) on button press/release/hold, resolved in
  `MK2Surface2.buttonHandler(for:event:)` against the actor's `pressedButtons`.
  Encoders, jog, touch, and strip have no modifier dimension.
- The DSL (`MK2RegularScreenDSL`/`MK2FullScreenDSL`) builds eagerly: elements draw
  into the frame and register bindings into one `MK2ScreenBuildResult` at build time.
- `PixelDisplayReconciler2` diffs whole frames as row bands against the last-sent
  pixels, so swapping the visible frame is just a (possibly large) diff — no new
  display machinery needed.
- `MK2FunctionKeyBarElement` owns drawing and F1–F8 bindings; `MK2ParameterPageElement`
  owns encoder value cells and their `MK2EncoderDiscreteValue` bindings.

## Design: a scene-level shift layer

The core idea is a **modal overlay layer** on the scene, not a second modifier axis
on every binding dictionary:

```swift
public struct MK2SurfaceScene2 {
    // existing: displays, lamps, keyColors, bindings
    public var shift: ShiftLayer?

    public struct ShiftLayer: Sendable {
        /// `.fallback` merges button lamps/bindings over the base;
        /// `.exclusive` makes the layer the complete button plane.
        public var buttonPolicy: ButtonPolicy
        /// Per-screen replacement frames; nil keeps the base frame visible.
        public var displays: [MK2PixelFrame?]
        /// Merged over base lamps under `.fallback`; replaces them under `.exclusive`.
        public var lamps: [KKMK2ButtonLED: MK2LampState2]
        /// Merged over base key colors while held.
        public var keyColors: [Int: KKRGB]
        /// Consulted first while held; button fallback follows `buttonPolicy`.
        public var bindings: MK2InputBindings2
    }
}
```

Semantics while SHIFT is physically held **and** `scene.shift != nil`:

1. **Displays** — the reconciler targets `shift.displays[i] ?? displays[i]`.
2. **Bindings** — dispatch consults the layer first. With `.fallback`, unbound
   buttons continue into the base scene; with `.exclusive`, unbound buttons are
   consumed. Encoder, jog, touch, and strip fallback stays independent so the
   policy remains specifically about the illuminated button plane.
3. **Lamps / key colors** — button lamps merge under `.fallback` and are
   replaced by the layer under `.exclusive`; key colors continue to merge.

Why a layer instead of extending `ModifierRequirement` to encoders et al.:
the layer solves display *and* input variance with one concept, keeps
`MK2InputBindings2` unchanged, and matches the mental model ("while SHIFT is
held, the surface is in an alternate mode"). The existing `ModifierRequirement`
API stays fully functional (the WidgetLab tracker's `Shift+Clear` keeps working
unchanged); layer lookup simply happens before the existing resolution.

Why not client-driven re-present on shift press/release: it spreads modifier
logic into every client, adds a full scene rebuild of latency to a purely
visual mode flip, contradicts the backlog rule, and gets the "scene replaced
while shift held" case wrong unless every client handles it.

### Runtime changes (`MK2Surface2`)

- `isShiftHeld` derives from the existing `pressedButtons`. On a `.button(.shift, _)`
  transition with `scene.shift != nil`, trigger an immediate `tick(forceDisplay: false)`
  so the flip does not wait for the next 30 Hz tick (worst case 33 ms feels rubbery
  on a held modifier).
- `reconcileDisplays` and `reconcileLamps`/`reconcileKeys` read through a small
  `activeFrames`/`activeLamps`/`activeKeyColors` accessor that applies the layer.
- Dispatch order for buttons while held: `shift.bindings` (press/release/hold
  dicts, `.any` requirement), then — only for `.fallback` — existing
  `modifiedButton*` `.shift` entries and base `.any` entries.
  Encoders/jog/touch/strip remain `shift.bindings.X ?? bindings.X`.
- **Press/release pairing**: capture, per LED, which binding set resolved the
  press, and resolve the release from the same set. Today a press with shift
  held followed by shift-release-then-button-release resolves the release
  against the unmodified requirement — a latent asymmetry that becomes user-visible
  once F-buttons carry different actions per layer. Fix it as part of this work
  (also for the existing `ModifierRequirement` path).
- Encoder turns are resolved per event; a turn stream crossing a shift
  transition simply switches handlers mid-stream, which is the expected
  hardware idiom (coarse → hold shift → fine).
- `present()` while shift is held needs no special handling: shift state lives
  in the surface, the scene is pure data, and the per-tick accessor picks the
  layer of whatever scene is current.
- **Automatic shift lamp**: if `scene.shift != nil` and neither the scene nor the
  layer defines a `.shift` lamp, light it "available" (dim white) when idle and
  "active" (bright) while held. A scene without a layer leaves the lamp alone.

### Build pipeline changes (DSL)

Two-pass build, second pass only when a screen actually declares shift content:

- `MK2ScreenContext` gains `modifiers: Set<MK2Modifier>` (`enum MK2Modifier { case shift }`;
  the set form keeps the door open for other held-button layers without another
  API change). During build it means "which variant pass is rendering".
- `MK2ScreenBuildResult` gains `shiftScreen: MK2Screen?`, `shiftLamps`,
  `shiftKeyColors`, `shiftBindings`, plus an internal `wantsShiftPass` flag that
  variant-aware elements set during pass 1.
- `MK2RegularScreenDSL.build()` / `MK2FullScreenDSL.build()`: pass 1 renders as
  today. If `wantsShiftPass` is set, pass 2 re-renders chrome + all elements into
  a fresh frame with `context.modifiers = [.shift]`, routing lamp/key/binding
  registrations into the shift variant of the result. Elements without shift
  awareness render identically in both passes (deterministic rendering and the
  glyph-run caches make the second pass cheap); their re-registered bindings in
  the layer are semantically identical to the base fallback, so the duplication
  is harmless. Screens without shift content pay nothing.
- `MK2DoubleScreenDSL.scene()` merges the left/right shift results into
  `scene.shift` when either side produced one (per-screen `displays` entry stays
  nil for a side without shift content).

### DSL surface API

Two levels, built on the same mechanism:

1. **Generic branch element** for arbitrary content:

   ```swift
   MK2ShiftBranch {
       // elements rendered only while SHIFT is held
   } otherwise: {
       // elements rendered only in the base layer (optional)
   }
   ```

   It sets `wantsShiftPass` and applies the matching branch per pass. This is the
   escape hatch that lets *any* screen region vary under shift.

2. **First-class parameters on the canonical elements**, because the two driving
   cases should not require manual branching:

   - `MK2FunctionKeyBarElement(slots:shiftSlots:side:onPress:onShiftPress:)`
     with a **separate** `onShiftPress: (_ slot: Int) -> Void` callback —
     deliberately not a modifier parameter on `onPress`, so base and shift
     actions stay independently copy/paste-able and maintainable. `onPress`
     keeps its existing signature; call sites without shift content are
     untouched. The element draws `slots` in pass 1 and `shiftSlots` in pass 2
     and binds F-buttons in the respective binding set.
   - `MK2ParameterPageSlot` gains an optional `shift: MK2ParameterPageSlot?`
     (alternate label/value/colors and, importantly, an alternate
     `encoderValue`), so a value cell can flip appearance *and* encoder
     behavior under shift. `MK2ParameterPageElement` sets `wantsShiftPass` iff
     any slot carries a shift variant.
   - `MK2EncoderDiscreteValueElement` / `MK2SelectionFilterEncoderElement` can
     follow the same pattern later; not required for the first cut.

### HIG rules (to be added to the Kit2 section of `CLAUDE.md`)

- Shift reveals **rarer** alternates; never relocate a frequently used action.
  A shift slot should be *related* to the base action in the same physical slot
  (e.g. base `CUT` → shift `TRIM`), keeping slot positions stable between layers.
- The shift layer must be visually distinguishable at a glance: shift-layer
  function-key labels render in an accent treatment — one new token
  (`MK2HIG.Chrome.shiftAccent` or reuse of the existing accent) used consistently
  by the function bar and value cells. Decide the exact treatment on the OLED,
  not on PNGs.
- Shift is **momentary** (held), matching the NI hardware convention. No
  latching/double-tap lock in this iteration; the layer model would support it
  later purely in `MK2Surface2` without DSL changes.
- Encoder shift variants follow the existing discrete-value clamp rule
  (`wrapMinimumValueCount`); fine/coarse step variants are the canonical use.
- The shift lamp follows the automatic convention above; scenes should not
  hand-roll it.

## Paulinche instrument editor realization

- `MK2PaulincheInstrumentScene` gains `shiftSoftKeys: [MK2PaulincheSoftKey]`
  (same fixed 8-slot indexing as `softKeys`; empty = slot dark under shift).
- `MK2PaulincheInstrumentActions` gains a parallel
  `onShiftSoftKey: (_ index: Int, _ softKey: MK2PaulincheSoftKey) -> Void`,
  mirroring the element-level decision: separate callbacks per layer,
  `onSoftKey` stays untouched.
- `MK2PaulincheInstrumentRenderer.detailScreen` feeds both lists into
  `MK2FunctionKeyBarElement(slots:shiftSlots:)`.
- Optional second step: route one or two `parameters` slots through
  `MK2ParameterPageSlot.shift` as a fixture proof (e.g. `TUNE` → `FINE`).

## Implementation steps

1. **Scene + runtime**: `ShiftLayer` on `MK2SurfaceScene2`; layer-aware frame/
   lamp/key accessors, dispatch fallback, press-time binding capture, immediate
   tick on shift transitions, automatic shift lamp. Unit tests via
   `handleForTesting` (layer dispatch, fallback, release pairing, present-while-held).
2. **Build pipeline**: `MK2Modifier`, context modifiers, two-pass build in both
   screen DSLs, shift fields on `MK2ScreenBuildResult`, merge in
   `MK2DoubleScreenDSL.scene()`. Tests: no layer unless declared; pass-2
   registrations land in the layer.
3. **Elements**: `MK2ShiftBranch`, `MK2FunctionKeyBarElement.shiftSlots`,
   `MK2ParameterPageSlot.shift`. Snapshot tests for base and shift frames of a
   function-bar + parameter-page screen.
4. **HIG**: accent treatment for the shift layer, shift-lamp convention;
   document the rules in `CLAUDE.md` (Kit2 section).
5. **WidgetLab realization** (required by project policy before Paulinche
   consumption): extend a unit (tracker or scene demo) with shift function-bar
   alternates and one shift-variant encoder cell; snapshot coverage for both
   layers of both screens.
6. **PaulincheSurfaceKit**: `shiftSoftKeys` through the instrument renderer and
   fixture; adjust the instrument fixture demo.
7. **Docs**: update `Docs/Backlog.md` (mark the modifier item, note deferred
   follow-ups: other held-button layers, latching shift, per-band diff
   optimization if shift flips ever show as a cost).

## Costs and edge cases considered

- **Build cost**: only screens declaring shift content render twice; glyph-run
  caches absorb most of the second pass. No cost for shift-free screens.
- **Blit cost on shift flip**: the row-band reconciler will produce a band from
  the function bar (top rows) to the encoder cells (bottom rows) when both vary —
  effectively a near-full frame per transition. Acceptable (same cost as any
  screen change today, and transitions are user-paced); if it ever matters,
  multi-band diffing is a reconciler-local optimization.
- **Ordering/races**: shift state, dispatch, and tick all live on the
  `MK2Surface2` actor — no cross-thread state. Hold timers are unaffected by
  shift transitions.
- **Modal dialogs**: modal scenes replace the whole scene and simply declare no
  shift layer; the layer deactivates naturally.

## Resolved decisions

1. The shift layer **does** drive light-guide key colors (`keyColors` merge
   over base while held) — required, e.g. "shift shows loop region on the
   keybed".
2. Shifted function keys use a **separate `onShiftPress`** callback (and
   `onShiftSoftKey` on the Paulinche adapter) rather than a modifier parameter
   on `onPress`: base and shift action wiring stay independently
   copy/paste-able and existing call sites remain untouched.
