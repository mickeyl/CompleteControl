# Porting CompleteControl to Komplete Kontrol S49 MK3

Working plan for extending CompleteControl (today: S25 **MK1**) to the **Kontrol
S-Series MK3** generation, with the S49 MK3 as the concrete target. This is a
*second hardware generation*, not a variant of MK1 — the transport, the display
model, and the keybed all differ. Read this alongside `CLAUDE.md` and
`Middleware-Concept.md`.

> Status of this document: **research + plan**, no code written yet.
>
> **⚠️ Major revision (firmware-image analysis).** Static analysis of the MK3
> firmware updater (`NI/KSMK3Updater.app`) overturns this document's central
> display assumption. See **`MK3-ODR-Protocol-Findings.md`** for the evidence;
> the short version is inlined where it changes a conclusion below, tagged
> **[REVISED]**. In brief: the MK3 display is **not** a host-pushed framebuffer —
> it is rendered on-device by a Qt/QML app (`ni-roda`) driven by a **msgpack-RPC
> semantic protocol** over a dedicated **`ODR` USB interface**. The "framebuffer
> format" is the wrong target; the real target is the RPC schema, which we can
> reconstruct from the (symbol-bearing) device binaries.

## TL;DR verdict

- **Input, MIDI, and light guide are tractable** — the relevant MK3 commands are
  publicly known and confirmed working by the community.
- **The full-pixel display is the prize.** ~~Its framebuffer format is the
  blocker.~~ **[REVISED]** There is **no host framebuffer**. The 1280×480 panel is
  rendered on-device by `ni-roda` (Qt/QML) from a host-pushed *semantic model*
  over **msgpack-RPC** on a dedicated **`ODR` USB interface**. The blocker shrinks
  from "invent a pixel format" to "map a named, typed RPC API" — and the device
  binaries that *decode* it ship in the firmware image. Custom imagery is still
  possible via a **sha256-addressed asset upload** path (webp/png/jpeg), not raw
  pixels.
- ~~**A protocol-level conflict threatens our core architecture:** LED control and
  MIDI input are mutually exclusive (`A0 00 00`/`A0 01 00`).~~ **[REVISED]** That
  mutex is an artifact of the **legacy HID interface** the community probed. On
  the MK3, **MIDI is its own USB interface** and the rich UI is the **ODR
  interface**; they are parallel, not mutually exclusive — which is exactly how
  NI's own stack drives keys + display + light guide simultaneously. Downgrade
  from "showstopper" to "verify the ODR path on the bench." See §2.
- **Our upper architecture survives the move.** `Surface`, the declarative
  `Screen` protocol, `SurfaceModel`, input-handler routing, and the
  diff-and-send-only-changes reconcile loop are not segment-specific. What dies
  is the 16-segment *render subset* (glyph masks, bar-in-row-0, 8-char marquee).

## 1. Hardware delta (MK1 → MK3)

| | S25 **MK1** (today) | S49 **MK3** (target) |
| --- | --- | --- |
| USB IDs | `0x17cc / 0x1340` | `0x17cc / 0x2100` (S49) — *verify on our unit* |
| Transport | HID-style interrupt transfers | **multiple USB interfaces**: HID, MIDI (UMP), DFU, CDC, **ODR** (bulk) |
| Display | 9× 16-segment LCD (report `0xe0`, glyph masks) | **single 1280×480 full-colour panel**, glass |
| Display model | characters / segments | **[REVISED]** on-device Qt/QML render; host pushes a **semantic model via msgpack-RPC**, *not* pixels |
| SoC | (none — peripheral) | **STM32MP1**: Cortex-M4 RT firmware + Cortex-A7 Linux, coupled via rpmsg |
| Keys | 25 | 49 (Fatar, **poly aftertouch, MIDI 2.0**) |
| Light guide | 25 RGB (report `0x82`) | up to 88 RGB (command `0x82`, confirmed working) |
| On-board UI | minimal | substantial (own browser/UI on device) |

PIDs (from firmware-binary analysis in the community RE thread, verify locally):
S49 MK3 `0x2100`, S88 MK3 `0x2120` (S61 expected `0x2110`).

## 2. Protocol knowledge status (the crux)

Two independent sources now exist: the community USB-capture thread
(**tillt/KompleteSynthesia #29**), which probed the **legacy HID interface**, and
**our own static analysis of the shipped firmware image** (`MK3-ODR-Protocol-Findings.md`),
which reveals the **ODR interface** NI's own host stack actually uses for the display.
These look at *different USB interfaces* — reconciling them is the key to §6.

**Known from HID-interface captures (community):**
- **Light guide** — command `0x82`, RGB per key. Working.
- **MIDI input** — working.
- **Init / framing** — 4-byte little-endian payload-size prefix; "legacy LED mode"
  toggled by `A0 00 00` / `A0 01 00`; a display command `0x84` is *identified* but its
  payload was "incompletely understood." **[REVISED]** This is the **legacy HID path**,
  not how the rich UI is driven — see below.

**Known from the firmware image (our analysis) — [REVISED, this is the real display path]:**
- The display is rendered **on-device** by `ni-roda` (Qt/QML, `RodaCore`). The host pushes
  a **semantic model over msgpack-RPC** (`ni::odr::protocol::kks`), *not* a framebuffer.
- Transport is a dedicated **`ODR` USB interface** (bulk), bridged to the Cortex-A7 via
  **rpmsg**. Entry point is a `handshake` / `handshake_reply` RPC.
- Verbs are named and typed: `set_odr_model`, `set_page`, `request_focus`, `set_tempo`,
  `parameter_page_set_model`, `lightguide_set_model`, `browser_set_*`, `smartplay_set_*`, …
- Custom imagery via a **sha256-addressed asset upload** (webp/png/jpeg/tiff), referenced
  by id from models — the realistic "free image on screen" route.
- LED brightness / colour / aftertouch / MIDI templates are set by `ni-roda` on the M4 via
  `KKSMk3FirmwareController` (rpmsg) — device-internal, reached through models.

**Still open (bounded, needs the bench):**
- Exact USB interface/endpoint numbers and PIDs (S49 `0x2100` etc. — verify locally).
- ODR bulk framing (the length-prefix / msgpack envelope) and full msgpack payload schemas.
- Encoder/touch-strip report layout on the input path.
- Whether the **TCP / UDS** msgpack transports `ni-roda` also instantiates are reachable
  externally — if so, a **capture-free RE shortcut** (drive the display over a socket).

**~~Architecture blocker~~ [REVISED — likely a non-issue]:** the community's "LED control
and MIDI input are mutually exclusive (`A0`/`A0`)" finding is a property of the **legacy
HID interface**. On the MK3, **MIDI is a separate USB interface** and the rich UI is the
**ODR interface**; they run in parallel (that is how NI's own software does keys + display
+ light guide at once). Reclassify from "hard prerequisite" to "confirm the ODR + MIDI
interfaces coexist on our unit."

**~~Hope anchor: Maschine MK3 RGB565 framebuffer.~~ [REVISED — wrong template]** The MK3
keyboard does **not** push pixels like the Maschine MK3. The relevant template is a
**msgpack-RPC host-integration protocol** rendered by an on-device app, closer in spirit
to NIHIA than to a framebuffer blit.

## 3. Codebase impact (mapped to the six layers)

Effort and concrete entry points, derived from the current MK1-binding survey.

| Layer | Today | MK3 effort |
| --- | --- | --- |
| USB identity / transport | hardcoded C (`VID/PID/IF=2/EP`) | parameterise + bulk path + device factory — **medium** |
| Display protocol (`KKDisplayFrame`, 16-seg, `0xe0`, ~1200 LOC) | foundationally hardcoded | **[REVISED]** replace with a **msgpack-RPC `ODR` client** (handshake + model encoders), *not* a pixel renderer — schema is RE-able from the device binaries — **high, not blocked** |
| Input decoding (byte offsets, `0x01`) | hardcoded offsets, generic logic | new offset map (49 keys); surface input arrives as ODR model/observer events — **medium** |
| LED / light guide (`0x80`/`0x82`, 25 keys) | parameterisable | new button enum + `keyCount`; LG drivable via legacy HID `0x82` *or* `lightguide_set_model` over ODR — **low** |
| Middleware DSL (`KontrolSurfaceKit`, reconcilers 9×3×8) | geometry-bound | `Surface`/`Screen`/`SurfaceModel`/input **stay**; the reconciler diffs **models pushed over msgpack-RPC** (map DSL → NI widget vocabulary; bitmap→asset for custom views) — **high** |
| Device abstraction | "zero generality", one enum, one class | model enum + capability negotiation + factory — **medium** |

### Concrete intervention points (current `master`, line numbers approximate)

- `Sources/KontrolUSB/KontrolUSB.c:21-25` — `KONTROL_VID/PID/INTERFACE/EP_*`
  defines. Lift to a passed-in descriptor; add a bulk-transfer path.
- `Sources/KontrolUSB/KontrolUSB.c:265-274`, `:565-579` — device discovery and
  `claim_interface` filtered on interface `2`. Make interface/endpoints part of
  the device descriptor.
- `Sources/KompleteKontrol/KompleteKontrol.swift:8-16` — single
  `KompleteKontrolS25MK1Protocol` (VID/PID, `keyCount=25`, report IDs). This is
  where a **device-model enum / protocol abstraction** must be introduced.
- `…/KompleteKontrol.swift:61-90,122-172,1154-1156` — `KKDisplayFrame` geometry,
  16-segment font, row-payload header. This is the block that a pixel renderer
  replaces; do **not** try to retrofit pixels into the segment model.
- `…/KompleteKontrol.swift:368-393,400,430-475` — input report `0x01` decode
  (button names, byte offsets, encoders, strips). New offset map for MK3.
- `…/KompleteKontrol.swift:213-276,837-838,1010-1038` — button-LED enum, guide
  array sizing, `setKey` range. Parameterise by `keyCount`; new button set.
- `Sources/KontrolSurfaceKit/DisplayReconciler.swift:15-30,92-135` — 9×3×8
  geometry, `renderCell` (row 0 = bar), `perimeterMask`, 8-char marquee. Pixel
  port needs a parallel `PixelDisplayReconciler`.
- `Sources/KontrolSurfaceKit/ScreenDSL.swift:21-59,173-180` — `Bar/Label/Value/
  Glyphs/Spinner` (16-seg) and `KeyColors` hardcoded `0..<25`. New pixel-aware
  elements; key count from device descriptor.
- `Sources/KontrolSurfaceKit/Surface.swift`, `SurfaceModel.swift`,
  `CellContent.swift` — **keep the actor, tick loop, model, and input routing**;
  generalise the few `KKDisplayFrame.displayCount/rowCount` references.

## 4. What the display unlocks — and its real constraint

A 1280×480 colour panel still unlocks the "don't look at the computer" vision:
full instrument names without marquee, parameter pages, browser lists, VU/meters.
The DSL's declarative core is reusable; the leaf render elements and the reconciler
change.

**[REVISED] But the rendering model imposes a hard constraint.** We do **not** get
arbitrary pixel control. `ni-roda` renders a **fixed QML widget vocabulary**
(parameter page, browser, lightguide, smartplay, …) from the model we push. Two
consequences:

- For UI that maps onto NI's existing widgets (parameter pages, lists, meters,
  text), we drive it by pushing models — cheap and high-fidelity.
- For anything *outside* that vocabulary (a custom waveform, a pattern-grid
  excerpt, a tracker view), the only route is to **render it ourselves to a bitmap
  and upload it as an asset** (sha256, webp/png/jpeg), then reference that asset id.
  That works, but it makes the "live waveform/pattern" ideas an *image-streaming*
  problem (encode + upload per frame) rather than a draw-call problem — and its
  practicality (frame rate, asset-cache churn, max bitmap size) is a bench unknown.

This is the pivotal design question for a tracker remote on MK3: **how much of
PatternScreen can be expressed in NI's widget set vs. needs per-frame asset
uploads.**

## 5. Effort estimate **[REVISED]**

The firmware-image analysis changes the risk profile: the display RE is no longer
"invent a pixel format" but "implement a named, typed msgpack-RPC client we can read
the device-side decoder for." Still real work, but bounded.

- **Input + light guide + MIDI only:** ~2–3 weeks, low risk. The LED/MIDI mutex is
  likely a non-issue once we use the ODR/MIDI interfaces instead of legacy HID (§2).
- **Full, with display:** the renderer rebuild changes shape — instead of a pixel
  `PixelDisplayReconciler`, the kit becomes a **msgpack-RPC `ODR` client** that pushes
  models. New buckets: (a) ODR USB-bulk transport + msgpack framing, (b) handshake +
  model encoders matching `ni::odr::protocol::kks`, (c) mapping the `Screen` DSL onto
  NI's widget vocabulary, (d) optional bitmap→asset path for custom views. Rough order
  ~6–8 weeks once the schema is mapped, **minus** the open-ended pixel-format invention
  the old plan feared, **plus** a focused schema-RE phase (tasks 2–3) that is already
  underway against the binaries.
- **Honest remaining risk:** not the display *format* but (i) whether direct device
  claiming of the ODR interface is viable without NI's host-integration handshake/auth,
  and (ii) the per-frame-asset cost if PatternScreen needs custom bitmaps (§4).

## 6. Recommended sequence **[REVISED]**

Do **not** port blindly. In order:

1. **Finish the firmware-image schema RE (no hardware needed).** Tasks 2–3 in
   `MK3-ODR-Protocol-Findings.md`: extract `ni-roda`'s `RodaCore` QML to recover every
   model field, and enumerate the full msgpack-RPC verb set + payload schemas. This is
   free intelligence we can mine *now*, before the unit arrives.
2. **Feasibility spike (1–2 days, on hardware).** A throwaway tool (à la `KontrolProbe`)
   that enumerates the MK3's USB interfaces, identifies the **ODR** bulk endpoints (and
   the separate MIDI interface), and attempts the **msgpack `handshake`**. Also probe the
   **TCP/UDS** transports `ni-roda` exposes — if reachable, the whole display protocol is
   exercisable *without* USB-bulk framing (capture-free shortcut). Light guide via `0x82`
   and MIDI confirm the known-good paths in parallel.
3. **Display bring-up via msgpack-RPC**, not pixel capture. Once the handshake lands,
   push a `parameter_page_set_model` / `set_page` and confirm the panel reacts. Capture is
   now a *confirmation* tool, not the primary RE method — we already have the device-side
   decoder.
4. **Prepare the architecture regardless.** Device-model enum + factory + capability model
   (per-model transport: HID-segment for MK1 vs. ODR-msgpack for MK3). Low-regret, can
   start immediately, also benefits the MK1/MK2 story.

Precondition for steps 2–3: **physical S49 MK3 hardware on the bench.** Step 1 needs only
the firmware image we already have.

## 7. Spike tool sketch

Goal: smallest possible proof that we can talk to the MK3 at all. Throwaway, not
production; lives outside the daemon so it can claim the device directly during
investigation.

- Open `0x17cc:0x2100`, list configurations/interfaces/endpoints, **and identify which
  interface is `ODR` vs `MIDI` vs `HID`** (match against the M4 firmware's interface
  string descriptors). Log the actual bulk IN/OUT endpoint addresses per interface.
- **[REVISED] Primary goal: the ODR msgpack handshake.** On the ODR bulk OUT endpoint,
  send the `kks::handshake` (4-byte LE length + msgpack-RPC frame, format per task 3) and
  read `handshake_reply` on the IN endpoint. This is the real "can we talk to the display"
  proof — not a pixel write.
- **Probe the TCP/UDS shortcut.** Check whether `ni-roda`'s `transport::tcp` / `uds`
  servers are reachable (e.g. over the CDC/network interface). If yes, run the same
  handshake over a socket and skip USB framing entirely for early development.
- Legacy HID sanity check: `A0 00 00` + a `82 …` light-guide frame (single bright key →
  rainbow) and MIDI note-on/off, to confirm the known-good HID/MIDI paths.
- **Verify the interfaces coexist:** keep the ODR (or HID light-guide) path active while
  reading MIDI on the MIDI interface. Confirm the old "mutex" does *not* apply across the
  separate interfaces (expected, per §2).
- Hexdump encoder / touch-strip input to start the MK3 input offset map.

Decision gate after the spike: if the handshake succeeds and ODR + MIDI coexist, proceed
to the msgpack model client (§6.3). If the ODR interface refuses direct claiming without
NI's host-integration handshake/auth, fall back to evaluating the NIHIA route
(à la `rebellion`).

## Sources

- **`MK3-ODR-Protocol-Findings.md`** (this repo) — static analysis of the MK3 firmware
  image (`NI/KSMK3Updater.app`, NativeOS 2.1.2). The basis for every **[REVISED]** note above.
- tillt/KompleteSynthesia — Discussion #29 (RE of Kontrol S49/61/88 MK3):
  https://github.com/tillt/KompleteSynthesia/discussions/29
- NI — Kontrol S49/S61/S88 specifications (1280×480, poly-AT, MIDI 2.0):
  https://www.native-instruments.com/en/products/komplete/keyboards/kontrol-s49-s61-s88/specifications/
- terminar/rebellion (NIHIA approach): https://github.com/terminar/rebellion
- Emerah/MMK3-HID-Control (Maschine MK3 display): https://github.com/Emerah/MMK3-HID-Control
- gearnews — Kontrol S MK3 firmware 2.0 overview:
  https://www.gearnews.com/native-instruments-kontrol-s-mk3-series/
