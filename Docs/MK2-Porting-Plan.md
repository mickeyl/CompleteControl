# Porting CompleteControl to Komplete Kontrol S-Series MK2

Actionable plan for adding **Komplete Kontrol S49/S61/S88 MK2** support to CompleteControl
(today: S25 MK1). Unlike the MK3 (see `MK3-ODR-Protocol-Findings.md`), the MK2 protocol is
**fully reverse-engineered by the community and pixel-based** — this is a bounded engineering
job, not open-ended research. Read alongside `MK3-Porting-Plan.md` §"Sibling generations".

> Status: **hardware milestone reached on S61 MK2.** The protocol constants below were checked
> against the community driver sources, and the first real-device bench confirmed that
> CompleteControl can drive an S61 MK2 without NI software through the privileged `ccd`
> daemon: persistent libusb ownership, bulk display blits, HID button/light-guide output,
> surface input, and USB-MIDI input all work. Remaining work is now narrower: complete the MK2
> input offset map (some controls still surface as `raw`) and identify why the ribbon/touch
> strip is not yet producing daemon input.

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

### Displays — `GoaSkin/qKontrol` `source/qkontrol.cpp` (`drawImage`, verified :1042–1089)
- Two screens, **480×272**, **RGB565** (`QImage::Format_RGB16`).
- **USB bulk, interface 3 / endpoint 3** (`libusb_claim_interface(h, 3)`, `libusb_bulk_transfer(h, 3, …)`).
- Blit command, per screen:
  `84 00` · `<screen 0|1>` · `60 00 00 00 00` · `x`(u16) · `y`(u16) · `w`(u16) · `h`(u16) ·
  `02 00 00 00 00 00` · `<w*h/2>`(u16) · **`w*h` RGB565 halfwords** ·
  trailer `02 00 00 00 03 00 00 00 40 00 00 00`.
- **Endianness — wire format is BIG-endian.** qKontrol serialises x/y/w/h, the `w*h/2` count,
  and every pixel halfword via `QByteArray::number(v,16)` → each u16 is emitted MSB-first. So
  although `QImage::Format_RGB16` is host-native (LE on x86), the bytes that reach the device
  are **byte-swapped to BE**. Build the RGB565 buffer big-endian (or byte-swap before blitting);
  getting this wrong paints a colour-swapped/garbled screen. Confirm on hardware.
- Arbitrary **(x,y,w,h) partial updates** — the basis for high frame rates (§5).

### Light guide — `tillt/KompleteSynthesia` `HIDController.m` (verified :44–58, :138–139)
- HID output report, command **`0x81`** (`kCommandLightGuideUpdateMK2`; MK1 is `0x82`), key
  colour bytes from offset 1 (`_keys = &lightGuideUpdateMessage[1]`).
- Colour is an **indexed palette** (`kMK2Palette[17][3]`, 17 base colours × 4 intensity levels),
  *not* arbitrary RGB.
- **Bytes-per-key resolved: exactly 1 byte/key.** The byte packs `(colorIndex << 2) | intensity`
  — colour mask `0xFC`, intensity mask `0x03`, `kKompleteKontrolColorCount = 17`,
  `…IntensityLevelCount = 4`. Message size **250** (`kKompleteKontrolLightGuideMessageSize`),
  key map = 249 bytes. So `KeyReconciler` maps `KKRGB` → nearest `kMK2Palette` index, then ORs
  the intensity level into the low 2 bits.

### Init handshake — `HIDController.m` (verified :37–38)
- KompleteSynthesia sends a one-shot init HID report **`0xA0`** (`kCommandInit`), payload
  `{0xA0, 0x00, 0x00}`, before driving the surface. qKontrol does **not** — it does a bare
  interface-claim + blit — so the handshake is likely optional for displays. Treat `0xA0`
  as the documented bring-up command; confirm on hardware whether it's required (§6 step 5).

### Button LEDs — `HIDController.m` (verified :62–63)
- HID output report, command **`0x80`** (`kCommandButtonLightsUpdate`), message size **80**
  (`kKompleteKontrolButtonsMessageSize`; 79-byte button map from offset 1). MK2 buttons are RGB.
- KompleteSynthesia carries a full, named button-id map (`kKompleteKontrolButtonId*`:
  transport, page L/R, browser, plugin, mixer, the function buttons, jog, scene, clear, etc.) —
  directly reusable as the MK2 button table.

### Surface input — `HIDController.m` + qKontrol (verified)
- Input report id **`0x01`** (`if (report[0] != 0x01) …ignore`, HIDController.m:308). Both drivers
  parse a `{byte, mask, buttonId}` bit-table — confirmed entries: `{1,0x10}=Function1` …
  `{1,0x80}=Function4`, `{2,0x10}=Play`, `{3,0x80}=PageLeft`, `{3,0x20}=PageRight`,
  `{4,0x20}=Clear`, `{5,0x02}=Plugin`, `{5,0x08}=Setup`, jog at byte 6 (HIDController.m:320–328).
  qKontrol agrees independently: report `0x01`, transport/nav bits in bytes 2–5 (play `[2]&0x10`,
  record `[3]&0x02`, page± `[3]&0x80`/`0x20`, mute `[4]&0x01`, plugin `[5]&0x02`; qkontrol.cpp:436–488).
- qKontrol reads **51-byte** reports (32-byte variant on older builds), knob values at
  `report[17 + i*2]` for the 8 knobs.
- Encoders, encoder-touch, the 4-D jog wheel, pitch/mod/touch strips all arrive in report
  `0x01` — exact offsets to be tabulated on hardware (the bit-table above is the starting point).

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

Initial hardware bench status:

- **Done:** real S61 MK2 (`0x1620`) is auto-detected.
- **Done:** `ccd` claims the MK2 persistently through libusb; no per-frame open/claim/release.
- **Done:** display bulk blits on IF 3 / EP 3 work; the idle daemon renders `NO CLIENT`.
- **Done:** button LEDs and light guide accept HID output reports through the daemon.
- **Done:** surface input and USB-MIDI input arrive as daemon push messages.
- **Open:** a number of surface controls are still named `raw`; their byte/bit offsets need to
  be added to `KKMK2InputReportDecoder`.
- **Open:** the ribbon/touch strip currently produces no observed daemon input; verify whether
  it is a second HID endpoint/interface, a MIDI controller stream, or requires an additional
  device-mode/init report.

Remaining bench items:

1. **FPS reality check.** Repeatedly blit a full 480×272 frame, measure the sustained accept rate.
   Then measure a 480×40 strip. This is the go/no-go for "smooth".
2. **Finish interface/endpoint inventory.** Display, primary HID surface, and USB-MIDI are
   confirmed through persistent libusb. If the ribbon is absent from the current input stream,
   enumerate and claim any additional HID interrupt-IN endpoint/interface before falling back
   to protocol-level hypotheses.
3. **Light-guide encoding is known** (cmd `0x81`, 1 byte/key, `(colorIndex<<2)|intensity`,
   250-byte msg — see §2). Remaining on-hardware item: the **per-model note offset** (S49 = −36)
   and a quick palette-index sanity sweep against `kMK2Palette`.
4. **Tabulate input report `0x01`** offsets for all still-raw controls, encoder-touch, 4-D jog,
   and pitch/mod/touch strips (KompleteSynthesia/qKontrol give the starting layout).
5. **Verify display init:** the candidate handshake is the `0xA0 00 00` init HID report (§2);
   qKontrol skips it and does a bare claim + blit, so confirm whether `0x84` blits work without
   it or whether `0xA0` is required first. Also confirm the **BE pixel/coord endianness** (§2) —
   blit one known-colour rect and check it isn't byte-swapped.

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

All §2 constants were read verbatim from the source below (line numbers cited inline in §2),
not paraphrased from memory or third-hand notes.

- `GoaSkin/qKontrol` — `source/qkontrol.cpp` (display `0x84`/RGB565/480×272 **BE on the wire**,
  bulk IF3/EP3, PIDs `0x1610/20/30`, input report `0x01`, service-stop):
  https://github.com/GoaSkin/qKontrol
- `tillt/KompleteSynthesia` — `HIDController.{h,m}`, `USBController.m` (init `0xA0`, light guide
  `0x81` 1-byte/key palette, buttons `0x80`, device table keys/offset, MK2 colour palette,
  bulk IF/EP MK2=3 / MK3=4): https://github.com/tillt/KompleteSynthesia
- **NI `KKS_MK2_Firmware_Updater.app` v1.4.0 (R205)** — device identity cross-check only:
  confirms VID `0x17cc` + PIDs `0x1610/20/30` in NI's own device table, and that the MK2 USB
  controller is **XMOS** (firmware is composite USB-DFU on the same PID). Carries no operational
  surface/display protocol — it's a DFU `writeImage` tool; the embedded firmware image (~1.17 MB
  in `__TEXT.__const`) is **compressed, not encrypted** (chi-square ≫ uniform; non-stationary
  entropy), but reversing it (NI GP-resource unpack → XMOS XCore disasm) buys nothing the source
  above doesn't already give.
- Generational context + pixel-vs-model spectrum: `Docs/MK3-ODR-Protocol-Findings.md`.
