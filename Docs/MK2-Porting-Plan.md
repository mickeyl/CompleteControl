# Porting CompleteControl to Komplete Kontrol S-Series MK2

Actionable plan for adding **Komplete Kontrol S49/S61/S88 MK2** support to CompleteControl
(today: S25 MK1). Unlike the MK3 (see `MK3-ODR-Protocol-Findings.md`), the MK2 protocol is
**fully reverse-engineered by the community and pixel-based** — this is a bounded engineering
job, not open-ended research. Read alongside `MK3-Porting-Plan.md` §"Sibling generations".

> Status: **hardware milestone reached on S61 MK2.** The protocol constants below were checked
> against the community driver sources, and the first real-device bench confirmed that
> CompleteControl can drive an S61 MK2 without NI software through the privileged `ccd`
> daemon: persistent libusb ownership, bulk display blits, HID button/light-guide output,
> surface input, and USB-MIDI input all work. **The ribbon/touch strip mystery is solved**
> (2026-07-02 hardware session): the strip is driven by an onboard MIDI mapping engine that
> must be enabled with `0xA0 93 00` and configured via output report `0xA2` — see
> §2 "Onboard MIDI mapping engine". `ccd` now does both at session bring-up.

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
  `report[17 + i*2]` for the 8 knobs. The live S61 MK2 daemon session on 2026-07-01 showed the
  32-byte HID report used by CompleteControl has its encoder values earlier: knob 1 starts at
  bytes `10/11`, then the remaining knobs continue as 16-bit little-endian pairs through
  bytes `24/25`.
- The regular encoders report wrapped absolute counters rather than signed step bytes. The
  observed S61 MK2 counter range wraps around `0x0000`/`0x03ff`; e.g. encoder 8 moved left
  from `0x0002` to `0x03e6` and right from `0x03af` to `0x03b2`. Decode with wrapped deltas,
  and show the signed delta separately from the raw absolute value in diagnostics.
- Encoder touch is byte `7`, with the mask order reversed from the natural index order:
  knob 1 = `0x80`, knob 2 = `0x40`, knob 3 = `0x20`, knob 4 = `0x10`, continuing downward.
- The 4-D encoder rotation uses byte `30` as a low-nibble counter. Byte `6=0x04` marks the
  rotation-active edge and can coincide with a counter jump that should be ignored; the next
  byte-30 transition carries the actual direction (`3 -> 4` = right/+1, `4 -> 3` = left/-1).
- The first hardware pass resolved these additional button swaps: browser = byte `5`/`0x04`,
  mixer = byte `5`/`0x01`, octave down = byte `8`/`0x01`, octave up = byte `8`/`0x02`,
  fixed velocity = byte `8`/`0x04`.
- Encoders, encoder-touch, and the 4-D jog wheel arrive in report `0x01` (32 bytes incl. ID:
  9 button-bit bytes, 8×u16le knobs @10, 2×u16le wheels @26, 4-D nibbles @30, 1 aux byte).
  The "pitch mirror at offset 33" seen earlier is **not** report `0x01` — it is report `0xAA`.

### Onboard MIDI mapping engine — wheels, touch strip, pedals (verified on hardware 2026-07-02)

The analog controls are driven by a mapping engine inside the firmware; the host writes
templates, the firmware emits USB-MIDI itself. With the engine off (our old init) the strip is
completely dead — no HID, no MIDI. Verified live on the S61 MK2 through the `ccd` socket:

- **`0xA0` takes mode flags.** `A0 00 00` (SynthesiaKontrol heritage) leaves the mapping engine
  *off*; **`A0 93 00`** (from a captured NI init, jnlive) switches it *on* — the strip started
  emitting 1.4 s after this single write, with the `0xA2` config already latched. NI's full init
  also uses `A0 10 00` at the end (semantics unknown). LEDs/light-guide/displays keep working in
  mode `93`.
- **Turning the engine on also activates the factory MIDI-mode template for the rotaries**
  (CC14–21) and potentially the buttons. Those live in their own template, **`0xA1`**
  (203-byte payload: 8 buttons ×12 + 8 knobs ×12 + 8 backlight + 3 trailer); an **all-zero
  `0xA1` suppresses them** without affecting the HID `0x01` stream. `ccd` writes this at
  bring-up so the DAW-mode MIDI stream stays clean.
- **`0xA2` (44-byte payload)** = three 12-byte slots — pitch wheel, mod wheel, touch strip — plus
  an 8-byte trailer. Slot types: `0x00` off, `0x03` CC (`03 cc# ch 20 min 00 max 00 …`), `0x06`
  14-bit pitch bend (`06 00 ch 00 00 00 ff 3f 00 00 01 00`), `0x08` "host-only" (qKontrol;
  behaved like `0x03` in our bench). Trailer: byte 0 = pitch-bend decay (8−n), byte 3 = strip LED
  zero point (`0x00` left origin, `0x02` center origin). `0xA1`/`0xA3`/`0xA4` are the sibling
  templates (buttons+knobs / pedals / keyzones, qKontrol layouts); `0xAF 00 02` follows the
  template block in NI's init (commit-ish; not required for `0xA2`+`A0 93 00` to take effect).
- **Strip data arrives as regular USB-MIDI** on EP `0x81` (CC 7-bit or pitch-bend 14-bit on the
  configured channel — prefer pitch bend on a dedicated channel for resolution) **and mirrors in
  HID input report `0xAA`** (51 bytes; knob values at `17+2i` per qKontrol, pitch wheel u16le at
  33/34 — `0x2000` center, strip CC value at 37). `0xAA` only streams while the engine is on.
- **Strip LEDs are firmware-animated** — follow-finger in CC mode (left origin), bidirectional
  from center with spring-back in pitch mode. No per-LED host writes needed.
- The declared HID input report `0x02` (2×u16 @11-bit + 3×u16) never appeared in any tested
  mode; on sibling devices it carries the high-rate touch stream (JAM strips, MK3 pads). Not
  needed — pitch-bend mode already gives 14-bit — but it may hide behind an untested `0xA0` flag.
- The config survives a daemon restart (device stays powered), but the engine must be re-enabled
  after every `A0 00 00`. `ccd`'s `enableMK2MappingEngine` (bring-up + reconnect) sends
  `A0 93 00`, all-off `0xA1` (knob/button CC suppression), the default `0xA2` map (pitch
  wheel = PB ch 1, mod = CC1, strip = CC11), then `AF 00 02`.

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
- **Done/in validation:** main surface button bits, encoder value pairs, and encoder touch masks
  are mapped from the 2026-07-01 S61 MK2 daemon session.
- **Done:** the ribbon/touch strip is resolved — it was both a hidden mode (`A0 93 00`) *and* a
  MIDI-template dependency (`0xA2`); see §2 "Onboard MIDI mapping engine".
- **Done:** `MK2USBSpy` can dump the full MK2 USB topology, HID report descriptor, claim all
  interfaces, and print packets from every readable IN endpoint.

Remaining bench items:

1. **FPS reality check.** Repeatedly blit a full 480×272 frame, measure the sustained accept rate.
   Then measure a 480×40 strip. This is the go/no-go for "smooth".
2. **Touch strip: done** (see §2 "Onboard MIDI mapping engine"). The driver exposes
   `KompleteKontrolMK2Protocol.AnalogAssignment` (`.off` / `.cc` unipolar / `.pitchBend`
   bipolar) with `wheelStripMapPayload(pitchWheel:modWheel:strip:)`, and clients can switch at
   runtime through `KompleteKontrolSSeriesMK2.configureAnalogControls(...)`. Remaining
   niceties: surface this in the `KontrolSurfaceKit` DSL, and decode the `0xAA` mirror. The full HID report descriptor is readable
   without claiming the device (`ioreg -l` → `ReportDescriptor` property); it also declares
   feature reports `0xD0/0xD8/0xD9/0xF0/0xF1/0xF8/0xF9` (version/config blocks, unexplored).
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
- `joostn/jnlive` — `test1/komplete.md`: full S61 MK2 HID report descriptor dump + a captured
  init sequence of NI's Komplete Kontrol software (`A0 93 00`, template block `A4/A1/A2/A3`,
  `AF 00 02`, `A0 10 00`) — the source of the mapping-engine mode flags:
  https://github.com/joostn/jnlive/blob/master/test1/komplete.md
- **NI `KKS_MK2_Firmware_Updater.app` v1.4.0 (R205)** — device identity cross-check only:
  confirms VID `0x17cc` + PIDs `0x1610/20/30` in NI's own device table, and that the MK2 USB
  controller is **XMOS** (firmware is composite USB-DFU on the same PID). Carries no operational
  surface/display protocol — it's a DFU `writeImage` tool; the embedded firmware image (~1.17 MB
  in `__TEXT.__const`) is **compressed, not encrypted** (chi-square ≫ uniform; non-stationary
  entropy), but reversing it (NI GP-resource unpack → XMOS XCore disasm) buys nothing the source
  above doesn't already give.
- Generational context + pixel-vs-model spectrum: `Docs/MK3-ODR-Protocol-Findings.md`.
