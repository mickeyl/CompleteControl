# Held Command and Setting Popups

`MK2HoldCommandBarElement` is the standard transient F1-F8 command plane for
an already active surface mode. It exposes related structural commands without
replacing the mode or hiding the context that those commands affect.

## HIG distinction: command and setting popups

The two held popup forms have different semantics. Choose the form from the
effect of the F-key press, not from the amount of available screen space.

| Popup | Kit element | Meaning of an F-key press | State after release |
| --- | --- | --- | --- |
| Command popup | `MK2HoldCommandBarElement` | Executes one immediate command | The command has happened; the popup itself stores no selection |
| Setting popup | `MK2HoldActionOverlayElement` | Selects a persistent setting value | The new setting remains active and is shown as the current selection next time |

Use a command popup for actions such as pattern creation, duplication, row
operations, or arrangement reordering. Commands may be undoable, destructive,
or require client-owned confirmation, but they are still direct actions.

Use a setting popup for values such as the note-input root octave. It should
receive the current value through `selectedIndex`, visually identify that value,
and update the persistent client setting immediately when another value is
selected. Releasing the trigger closes the popup; it does not revert the setting.

Do not present direct commands as selected setting values, and do not use the
compact command bar for a persistent setting merely because all values fit.

## Interaction contract

- The trigger button must already have a held layer in the active scene when
  button down arrives. A button press that first changes into the target mode
  does not open the newly published layer. The user must release and press the
  button again. This prevents SCENE or PATTERN from both switching modes and
  unexpectedly opening commands in one press.
- Releasing the trigger restores the base scene immediately.
- The command plane owns all eight function buttons while visible. Empty and
  disabled slots swallow their presses, so no base F-key command can leak
  through the popup.
- Enabled function lamps use the command layer while it is held, even when a
  client publishes high-frequency meter lamps. Disabled and empty slots remain
  dark. Destructive actions use the semantic destructive color.
- The bar is 90 pixels high. It pre-composites over copies of the two base
  frames, dims the remaining base content to half RGB565 brightness, and adds
  an opaque lower shadow. Context remains readable but visually recedes.
- Labels and one- or two-line details use the canonical four-slot function-key
  geometry on each display. Every detail line is centered on the same axis as
  its function-button label.

## Building a layer

Render the base screens first, then build the command bar from their frames and
attach the returned held layer to the final scene:

```swift
let left = buildLeftScreen()
let right = buildRightScreen()

let commandBar = MK2HoldCommandBarElement(
    trigger: .scene,
    title: "Arrangement Commands",
    actions: [
        MK2HoldAction("NEW", detail: "Blank pattern"),
        MK2HoldAction("DUP", detail: "Independent copy"),
        MK2HoldAction("REUSE", detail: "Linked data"),
        MK2HoldAction(
            "CLEAR",
            detail: "Erase all events",
            isDestructive: true
        ),
        MK2HoldAction("MOVE-", detail: "Earlier position", isEnabled: canMoveEarlier),
        MK2HoldAction("MOVE+", detail: "Later position", isEnabled: canMoveLater),
        MK2HoldAction(""), // Reserved F7; the press is swallowed.
        MK2HoldAction(
            "DEL POS",
            detail: "Keep pattern data",
            isEnabled: canDeletePosition,
            isDestructive: true
        ),
    ],
    onSelect: { index in
        dispatchCommand(at: index)
    }
).build(
    baseLeft: left.screen.frame,
    baseRight: right.screen.frame,
    renderer: renderer
)

let scene = MK2DoubleScreenDSL(
    left: left,
    right: right,
    heldButtonLayers: [commandBar]
).scene()
```

The action array maps directly to F1-F8. Keep an empty action in the array when
a physical slot is intentionally reserved; removing it would shift every later
command to a different button.

Rebuild the command bar whenever the base scene or command availability changes.
The frames are pre-composited, so retaining an old layer would also retain an
old copy of the scene body. Clients should still publish the layer only in the
mode where its commands are meaningful; the button-down eligibility rule is a
runtime safeguard, not a substitute for correct scene projection.

Confirmation policy remains client-owned. Mark destructive actions for their
visual treatment, but route a selection that needs confirmation into the
client's normal confirmation workflow instead of performing it directly in the
Kit callback.

## Reference and verification

The copyable reference implementation is
[`HoldActionOverlayDemo`](../Tools/WidgetLab/Demos/HoldActionOverlayDemo.swift).
In Widget Lab, open `hold-action-overlay`. Hold SCENE for the immediate command
popup, or hold KEYBOARD for the persistent root-octave setting popup.

Headless Widget Lab snapshots include
`widgetlab-hold-action-overlay-hold-scene.png`. Focused behavior and rendering
coverage lives in `HoldActionOverlayTests`; centered wrapped text is covered by
`ScreenDSLTests`.
