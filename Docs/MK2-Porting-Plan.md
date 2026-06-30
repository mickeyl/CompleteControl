# Porting CompleteControl to Komplete Kontrol S-Series MK2

Actionable plan for adding **Komplete Kontrol S49/S61/S88 MK2** support to CompleteControl
(today: S25 MK1). Unlike the MK3 (see `MK3-ODR-Protocol-Findings.md`), the MK2 protocol is
**fully reverse-engineered by the community and pixel-based** — this is a bounded engineering
job, not open-ended research. Read alongside `MK3-Porting-Plan.md` §"Sibling generations".

> Status: **plan, pre-hardware.** All protocol constants below are sourced from working
> open-source MK2 drivers (`GoaSkin/qKontrol`, `tillt/KompleteSynthesia`). The remaining
> unknowns are integration-level (interface-claim strategy on macOS, exact light-guide byte
> width, real device framebuffer ingest rate) and are listed in §6 as the bench checklist.

## TL;DR

- The **MK2 is the sweet spot** for our "remote control you don't look away from": two
  **480×272 RGB565 colour screens** the host paints directly (raw framebuffer blit), no
  on-device rendering, no device hacking, protocol public.
- **What ports nearly for free** from the MK1 work: the daemon (`ccd`), the `Surface` actor +
  60 Hz reconcile loop, the `Screen` DSL core, input-handler routing, the device-ownership
  solution, light-guide and button-LED *concepts*.
- **The one substantial new build:** a **pixel `DisplayReconciler` + pixel DSL render
  elements** to replace the 16-segment text pipeline. Everything else is *parameterisation*
  (PIDs, key count, report command bytes, byte offsets).
- **Effort:** ~2–4 weekends for a hobby pace. No brick risk, no warranty issues.

## 1. Hardware / USB topology (MK2)

The MK2 splits across **two transports** — this is the key architectural fact:

| Function | Transport | Detail |
| --- | --- | --- |
| Surface input (buttons, encoders, touch, strips) | **HID** | input report id `0x01` |
| Light guide (per-key colour) | **HID** out | command `0x81` |
| Button LEDs (RGB buttons) | **HID** out | command `0x80` |
| **Displays (2× 480×272)** | **USB bulk** | **interface 3, endpoint 3**, command `0x84` |
| MIDI (keys, pads, wheels) | USB-MIDI | standard class interface |

Contrast: on the **MK1** the surface is a libusb-claimed interrupt interface (IF 2, EP
`0x82`/`0x02`) and there are no pixel displays. On the **MK3** the bulk interface moves to
IF/EP 4 and carries msgpack, not pixels.

**Device IDs** (`VID 0x17cc`; from qKontrol + KompleteSynthesia):

| Model | PID | Keys | Light-guide note offset |
| --- | --- | --- | --- |
| S49 MK2 | `0x1610` | 49 | −36 |
| S61 MK2 | `0x1620` | 61 | −36 |
| S88 MK2 | `0x1630` | 88 | −21 |

## 2. Protocol constants (sourced, verify on hardware)

### Displays — `GoaSkin/qKontrol` `source/qkontrol.cpp` (`drawImage`)
- Two screens, **480×272**, **RGB565** (`QImage::Format_RGB16`, 16-bit LE).
- **USB bulk, interface 3 / endpoint 3.**
- Blit command, per screen:
  `84 00` · `<screen 0|1>` · `60 00 00 00 00` · `x`(u16) · `y`(u16) · `w`(u16) · `h`(u16) ·
  `02 00 00 00 00 00` · `<w*h/2>`(u16) · **`w*h` RGB565 halfwords** ·
  trailer `02 00 00 00 03 00 00 00 40 00 00 00`.
- Arbitrary **(x,y,w,h) partial updates** — the basis for high frame rates (§5).

### Light guide — `tillt/KompleteSynthesia` `HIDController.m`
- HID output report, command **`0x81`** (MK1 is `0x82`), key colour bytes from offset 1.
- Colour is an **indexed palette** (`kMK2Palette`, 17 base colours × 4 intensity levels via
  the `kKompleteKontrolColor*`/`kKompleteKontrolIntensity*` codes), *not* arbitrary RGB.
- Message buffer ~250 bytes. **Exact bytes-per-key (1-byte palette index vs other) is the one
  field to confirm on hardware** — it changes how `KeyReconciler` maps `KKRGB` → MK2 colour.

### Button LEDs — `HIDController.m`
- HID output report, command **`0x80`** (`kCommandButtonLightsUpdate`). MK2 buttons are RGB.
- KompleteSynthesia carries a full, named button-id map (`kKompleteKontrolButtonId*`:
  transport, page L/R, browser, plugin, mixer, the 8 function buttons, jog, etc.) — directly
  reusable as the MK2 button table.

### Surface input — `HIDController.m` + qKontrol
- Input report id **`0x01`**; KompleteSynthesia parses a `{byte, mask, buttonId}` bit-table
  (e.g. `{3,0x80,PageLeft}`, `{3,0x20,PageRight}`). qKontrol reads 51/32-byte reports, knob
  values at `report[17 + i*2]` for the 8 knobs, transport bits at bytes 2–5.
- Encoders, encoder-touch, the 4-D jog wheel, pitch/mod/touch strips all arrive in report
  `0x01` — exact offsets to be tabulated on hardware (qKontrol/KompleteSynthesia give the
  starting points).

### Ownership
- macOS: NI background services (Hardware Agent / Host Integration) must release the device
  first. qKontrol kills them; KompleteSynthesia coexists via HID. **CompleteControl's `ccd`
  daemon already owns this problem** — it claims the device once and refuses duplicates.

## 3. Codebase impact (mapped to the six layers)

Entry points are the same files the MK1 survey flagged; here is reuse-vs-new for MK2.

| Layer | MK1 today | MK2 work |
| --- | --- | --- |
| **USB identity / transport** (`KontrolUSB.c`, `KompleteKontrol.swift:8-16`) | hardcoded VID/PID/IF/EP | **add device-model descriptor** (PID, keys, offset, interfaces); MK2 needs a **bulk-display path on IF 3** *plus* a **HID path** for surface/LG/buttons. Decide claim strategy (§6). **Medium** |
| **Display** (`KKDisplayFrame` 16-seg, `0xe0`, `DisplayReconciler` 9×3, `ScreenDSL` Bar/Label/Value/Glyphs) | segment pipeline | **new `PixelDisplayReconciler`** (framebuffer + dirty-rect diff → `0x84` blits) and **pixel DSL render elements**. The biggest single piece, but the protocol is trivial. **High** |
| **Input decoding** (`KompleteKontrol.swift:368-475`) | report `0x01`, MK1 offsets | new MK2 offset map + button table (KompleteSynthesia's map is a head start). Decode logic is generic. **Medium** |
| **Light guide** (`KeyReconciler`, report `0x82` RGB) | 25 keys RGB | command → `0x81`, `keyCount`/offset per model, `KKRGB`→MK2 palette mapping. **Low–medium** |
| **Button LEDs** (`LEDReconciler`, report `0x80`) | MK1 button enum | MK2 button enum (RGB); report `0x80` already matches. **Low** |
| **Middleware core** (`Surface`, `SurfaceModel`, input routing, 60 Hz `SurfaceClock`) | — | **reuse as-is.** The clock already runs at 60 Hz (matches the panel); the reconciler already "diff and send only changes" (extends to dirty pixel rects). **Reuse** |
| **Device abstraction** | one model, "zero generality" | introduce the model enum + factory (also the MK1-family / S49-MK1 win). **Medium** |

**The shape of it:** keep the whole upper half; replace the display leaf; parameterise the
rest. The 16-segment `Cell/Bar/Label/Glyphs` DSL is retired for MK2 in favour of pixel
elements, but the `Screen`/`observe`/handler model around them is unchanged.

## 4. New display layer — design sketch

- **`PixelDisplayReconciler`** holds an intended framebuffer per screen (2× 480×272 RGB565),
  diffs against last-sent at **tile/dirty-rect granularity**, and emits `0x84` blits for only
  the changed rectangles on each 60 Hz tick. Mirrors today's row-granular `DisplayReconciler`.
- **Pixel DSL elements** under the existing `Screen` DSL: e.g. `Canvas`/`Surface2D` (draw
  closure), `BitmapLabel` (text via a bundled font, since the device has no font), `Meter`
  (VU with ballistics — already on the kit roadmap), `WaveformView`, `PatternGrid` (the
  tracker view). These render into the framebuffer the reconciler owns.
- **Rendering backend:** Core Graphics / `CGContext` into an RGB565 buffer off the main thread
  (the kit's reconcilers already run off-main), or a small software rasteriser. Keep it on the
  daemon-client side; the daemon just ships bytes.
- **Text:** ship a compact bitmap font (the device renders no glyphs itself). One small font
  asset replaces the MK1 16-segment table.

## 5. Frame-rate plan (the "must be 100% smooth" requirement)

RGB565: full screen = 255 KB, both = 510 KB. USB 2.0 **High Speed** (~30–40 MB/s bulk):
full-double-frame ≈ 17 ms (~59 fps), a 480×40 row band ≈ 1.3 ms (hundreds fps).

- **Design for partial updates, not full repaints.** A tracker scrolls a few rows / updates
  meters — push only dirty rects. The reconciler's diff already produces exactly these.
- **60 Hz cadence** from the existing `SurfaceClock` matches a typical small-TFT refresh.
- **The one unmeasured variable is the device's internal ingest rate** (panel/SoC may accept
  pixels slower than HS line rate). **Bench it first** (§6, step 1) before committing to any
  full-frame animation.
- Keep big blits chunked so display traffic never adds jitter to MIDI/surface input on the
  shared bus.

## 6. Bench checklist (first session with the hardware)

Do these before writing the reconciler — they resolve every remaining unknown:

1. **FPS reality check (do this first).** Claim IF 3, repeatedly blit a full 480×272 frame,
   measure the sustained accept rate → the true full-frame ceiling. Then measure a 480×40
   strip. This is the go/no-go for "smooth".
2. **Enumerate interfaces/endpoints** on the real unit; confirm IF 3 / EP 3 for the bulk
   display and identify the HID surface interface. **Decide the claim strategy:** can libusb
   claim the MK2 HID surface interface (as MK1's IF 2, after detaching the kernel driver), or
   must surface I/O go through IOHIDManager while libusb owns only the bulk display? This
   determines whether the daemon stays single-transport or grows a HID path.
3. **Confirm light-guide encoding:** command `0x81`, bytes-per-key, palette vs RGB, and the
   per-model note offset (S49 = −36).
4. **Tabulate input report `0x01`** offsets for encoders, encoder-touch, 4-D jog, pitch/mod/
   touch strips (KompleteSynthesia/qKontrol give the starting layout).
5. **Verify display init:** whether any handshake precedes `0x84` blits (qKontrol does a bare
   claim + blit; confirm nothing else is needed).

## 7. Suggested build order

1. **Device-model abstraction + factory** (enum, descriptor: PID/keys/offset/interfaces).
   Also unlocks the S49 MK1 win. Land this regardless of which keyboard arrives first.
2. **MK2 light guide + button LEDs over HID** (`0x81`/`0x80`) + input report `0x01` decode →
   the surface is alive and reactive with the *existing* DSL handlers.
3. **`PixelDisplayReconciler` + minimal pixel DSL** (`Canvas`, `BitmapLabel`, `Meter`) driven
   by the 60 Hz clock with dirty-rect diffing → the screens light up.
4. **Port a real `Screen`** (the Paulinche pattern view) to the pixel elements; tune dirty-rect
   granularity against the FPS measured in §6.

## Sources

- `GoaSkin/qKontrol` — `source/qkontrol.cpp` (display `0x84`/RGB565/480×272, bulk IF3/EP3,
  PIDs `0x1610/20/30`, input report `0x01`, service-stop): https://github.com/GoaSkin/qKontrol
- `tillt/KompleteSynthesia` — `HIDController.{h,m}`, `USBController.m` (light guide `0x81`,
  buttons `0x80`, device table keys/offset, MK2 colour palette, bulk IF/EP MK2=3 / MK3=4):
  https://github.com/tillt/KompleteSynthesia
- Generational context + pixel-vs-model spectrum: `Docs/MK3-ODR-Protocol-Findings.md`.
