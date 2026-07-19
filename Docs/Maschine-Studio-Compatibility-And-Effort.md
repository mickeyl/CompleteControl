# MASCHINE Studio and MK3 Protocol Compatibility and Porting Effort

Status: research note, started 2026-07-14. MASCHINE Studio remains unverified.
A MASCHINE MK3 was connected on 2026-07-17; its identity, interface/endpoints,
HID report sizes, and macOS audio ownership were bench-verified and promoted to
the canonical protocol guide. Its NO CLIENT surface decoder and input-to-LED
echo are implemented; the pad matrix, neutral sentinel, LED slots, and latency
behaviour have controlled captures. Remaining source-derived controls still need
focused captures before becoming a client-facing contract.

## Decision

MASCHINE Studio is **not a MASCHINE MK2 product** in Native Instruments' product
naming. It is a separate controller generation, released between MASCHINE MK2
and MASCHINE MK3. Native Instruments also lists Studio, MK2, and MK3 separately
in its official [MASCHINE downloads matrix][ni-downloads].

Its displays nevertheless belong to the later Native Instruments colour-display
family used by MASCHINE MK3 and Komplete Kontrol S-Series MK2. At the display
layer, Studio is fundamentally compatible with CompleteControl's approach:

- two 480x272 colour displays;
- RGB565 pixel data in big-endian byte order;
- `0x84` packet framing;
- screen selection plus X/Y/width/height rectangle coordinates;
- USB bulk transfers;
- full-frame and rectangular pixel blits.

The precise description is a **command-stream framebuffer protocol**, not a
memory-mapped framebuffer and not JPEG/PNG transport. The host submits RGB565
pixels inside a small command stream containing raw, repeat, skip, commit, and
end operations.

Therefore:

| Question | Answer |
| --- | --- |
| Is MASCHINE Studio officially an MK2 product? | No. It is a separate Studio model. |
| Is its display framebuffer-based? | Yes, through framed RGB565 rectangle blits. |
| Is it in the same display-protocol family as Komplete Kontrol S MK2? | Yes. |
| Can the existing renderer and display diffing be reused? | Very likely without behavioural changes. |
| Can the current USB packet writer be reused byte-for-byte? | Unproven; it needs a Studio transport profile and hardware tests. |
| Is the complete controller protocol drop-in compatible? | No. Inputs, LEDs, pads, wheel, meters, endpoints, and startup behaviour are device-specific. |

MASCHINE MK3 reaches the same display conclusion with stronger evidence for the
rest of the surface: it is not a Komplete Kontrol MK2 device, but it uses the
same 480x272 `0x84` colour-display family. Unlike Studio, substantial public
implementations also document its controls, LEDs, touchstrip, pedal, and pad
pressure reports.

## Protocol-generation comparison

| Device family | USB PID examples | Displays | Display transport | Compatibility with CompleteControl |
| --- | --- | --- | --- | --- |
| MASCHINE MK1 | `0x0808` | Two monochrome displays | Older one-bit protocol | No |
| MASCHINE MK2 | `0x1140` | Two 256x64 one-bit canvases | 2,048 bytes per display, sent as eight 256-byte chunks; header starts with `0xE0 | screen`; endpoint `0x08` | No at the display codec layer |
| MASCHINE Studio | `0x1300` | Two 480x272 colour displays | `0x84`, RGB565, rectangular bulk blits; published proof of concept uses endpoint `0x03` | Yes at the framebuffer/rendering layer; exact packet dialect must be verified |
| MASCHINE MK3 | `0x1600` | Two 480x272 colour displays | Same `0x84` command family; openAV uses display interface 5 and endpoint `0x04` | Same codec family, different USB profile |
| Komplete Kontrol S MK2 | `0x1610`, `0x1620`, `0x1630` | Two 480x272 colour displays | `0x84`, RGB565, interface 3, endpoint `0x03` | Current CompleteControl target |

The MASCHINE MK2 row is supported directly by cabl's
[`GDisplayMaschineMK2` canvas][cabl-mk2-canvas] and
[`MaschineMK2::sendFrame` implementation][cabl-mk2-device]. It is the important
counterexample: sharing the word “MK2” does not imply sharing the colour display
protocol.

## Strongest evidence for Studio display compatibility

The most useful public evidence is in cabl issue #9:

1. The [cabl maintainer states][cabl-shared-protocol] that MASCHINE Studio,
   MASCHINE MK3, and Komplete Kontrol MK2 use the same display protocol.
2. A later [C++/libusb proof of concept][cabl-studio-proof] opens Native
   Instruments VID `0x17cc`, Studio PID `0x1300`, and writes to endpoint `0x03`.
3. That program constructs `0x84 00 <screen> 60 ...` messages with 480x272
   geometry and big-endian RGB565 pixels.
4. The author reports that it clears and draws on both Studio displays.

This is stronger than identification by dimensions alone: the published code
targets the Studio product ID and exercises both panels with real bulk writes.

The command family observed across the colour devices contains:

| Command | Meaning |
| --- | --- |
| `0x00` | Raw pixel pairs |
| `0x01` | Repeat a pair of pixels |
| `0x02` | Skip pixels |
| `0x03` | Blit/commit |
| `0x40` | End the transfer |

The early cabl description calls this “proprietary compression”. That is
reasonable at the stream level, but it should not be confused with image-file
compression: the useful client abstraction remains a 480x272 RGB565
framebuffer plus rectangle updates.

## What CompleteControl can reuse

The high-value parts are already above the physical USB packet seam:

- [`MK2PixelFrame`][local-pixel-frame] already stores a 480x272 RGB565 frame in
  wire byte order.
- [`PixelDisplayReconciler2`][local-reconciler] already turns changed frames
  into full-width dirty-row blits.
- KontrolSurfaceKit2's screen DSL, text rendering, widgets, images, snapshots,
  display shadow, daemon display queue, and binary client protocol operate on
  logical pixel rectangles rather than USB descriptors.
- Paulinche's two-screen projection can remain at the semantic adapter boundary.

No separate Studio or MK3 renderer should be introduced merely because the
products are not named Komplete Kontrol MK2. The renderer should instead depend
on display capabilities such as `screenCount`, `width`, `height`, pixel format,
and rectangle-blit support.

## What must change for Studio

### Device discovery and transport profile

CompleteControl currently allows only PIDs `0x1610`, `0x1620`, and `0x1630` in
the [`KontrolUSB` descriptor table][local-usb]. It will not open Studio today.
Studio needs its own device profile with at least:

- PID `0x1300`;
- display interface and bulk endpoint discovery/fallback;
- screen count and dimensions;
- colour pixel format;
- packet-header/trailer dialect;
- surface input/output interfaces and endpoints;
- startup, ownership, and shutdown behaviour.

The published Studio proof of concept and the current CompleteControl writer
have a small but important framing difference:

- the Studio example ends with `40 00 <screen> 00`;
- CompleteControl currently ends with `40 00 00 00`;
- CompleteControl emits zero-length `0x02` skip commands before raw pixels and
  before commit, while the minimal Studio example does not.

Both forms fit the same command language, but only a real Studio can establish
which variants are accepted reliably across full frames, partial rectangles,
reconnects, and sustained updates. The correct implementation is a shared
colour-display encoder with a small device-specific framing profile, not an
unconditional addition of `0x1300` to the existing allowlist.

### Surface controls and output

Display compatibility does not make the entire surface compatible. Studio has
a different control topology: velocity/pressure-sensitive pads, jog wheel and
ring, level meters, many dedicated buttons, MIDI I/O, and footswitch inputs. It
does not have the Komplete Kontrol keybed, light guide, or ribbon arrangement.

The following work is therefore independent of the display renderer:

- capture and decode every input report;
- establish encoder and jog-wheel relative encodings;
- decode pad velocity and pressure without adding latency or allocations;
- map button, group, pad, jog-ring, and meter LED output reports;
- determine any host-control handshake and standalone-mode restoration;
- expose Studio capabilities through the daemon and semantic surface port;
- create Studio-specific mappings without leaking raw report details into
  Paulinche.

Rebellion's [device mapping table][rebellion-mappings] recognizes PID `0x1300`,
but its Studio entry lacks the display metadata present for MASCHINE MK3 and
Komplete Kontrol MK2 and uses the older `CONST_PORT_MAIN` path. That is useful
evidence for identification, not proof of complete or tested Studio support.

SynthesiaKontrol is not a display-protocol reference. Its
[`0x81` writes][synthesia-kontrol] drive the Komplete Kontrol MK2 light guide,
which Studio does not have.

## MASCHINE MK3 assessment

### Compatibility decision

MASCHINE MK3 is a better-supported porting target than Studio. It still needs a
new device backend, but much less of that backend has to be inferred from raw
captures.

| Area | MK3 assessment |
| --- | --- |
| Product identity | Separate MASCHINE product, PID `0x1600`; not a Komplete Kontrol MK2 variant |
| Displays | Two 480x272 RGB565 panels using the same `0x84` command-stream framebuffer family |
| Display renderer | Existing `MK2PixelFrame`, screen DSL, image path, and display diffing are reusable |
| Display USB profile | Device-specific: interface 5, bulk OUT endpoint `0x04` in openAV-Ctlra |
| Surface USB profile | Device-specific: HID interface 4, interrupt IN `0x83`, interrupt OUT `0x03` in openAV-Ctlra |
| Inputs | Production decoding covers buttons, eight screen encoders, main encoder/touch, touchstrip, pedal/analogue fields, and pads; pad and shared-control paths are bench-verified while remaining source-derived controls retain their evidence labels |
| Pads | HID report `0x02` is 64 bytes total and its payload is 21 three-byte record slots; physical 1-16 ordering, the slot-3 neutral sentinel, state edges, LED slots, and callback-to-write timing are bench-verified on bcdDevice `0x0146` |
| LEDs | Production codecs and hardware calibration cover normal lamps, groups, pads, and the 25-segment touchstrip using output reports `0x80` and `0x81` |
| Audio/MIDI | Composite USB device; control/display support must not disturb OS-owned audio interfaces. MIDI/DIN handling needs a separate capability decision |
| Drop-in support in CompleteControl today | Device discovery, capability profile, safe interface ownership, displays, output clearing, semantic NO CLIENT decoding, Kit2 compatibility, pad-to-MIDI synthesis, and the single-device visual simulator are implemented |

As of 2026-07-19, the same `KontrolSimulator` executable can present the MK3
profile to arbitrary unchanged daemon clients. Its headless core synthesizes
native MK3 input reports and reduces native output reports; the calibrated
AppKit panel covers both displays, every supported control, all lamps and pads,
the touch strip, profile-specific window/zoom state, and accessibility. This is
single-device workflow/protocol evidence. Instance-isolated mixed operation and
final physical feel/timing calibration remain separate follow-up work.

### Public implementation evidence

The newer [RufusIbiza openAV-Ctlra MASCHINE MK3 branch][openav-mk3] provides a direct libusb
implementation rather than only an identification table. It documents:

- VID/PID `0x17cc:0x1600`;
- HID interface 4 with interrupt endpoints `0x83` and `0x03`;
- display interface 5 with bulk endpoint `0x04`;
- two complete `0x84` RGB565 screen buffers and the same eight-byte
  commit/end footer used by the minimal colour-display stream;
- a 42-byte surface report containing buttons, eight screen encoders, the main
  encoder, touchstrip, and pedal state;
- a pad decoder described as double-pumped, implemented around a 128-byte receive
  buffer; the connected device's HID descriptor and captures establish a
  64-byte report containing 21 three-byte record slots instead;
- button, group, pad, and touchstrip LED output;
- explicit cleanup that clears lamps and both displays on disconnect.

The pad detail matters. On macOS a 256-byte libusb buffer coalesced four complete
64-byte reports into one callback, while a 64-byte transfer delivered one report
per callback. Each logical report can itself carry several non-zero three-byte
records. CompleteControl must preserve those records in order, timestamp them
near the USB callback seam, and move velocity/pressure curve processing off the
callback without allocating. The public “double-pumped” wording must not be
encoded as two 64-byte halves.

[Rebellion][rebellion-readme] independently describes MASCHINE MK3 and Komplete
Kontrol MK2 as its two automatically discovered, tested, working, and completely
mapped device types. Rebellion communicates through the Native Instruments
Hardware Agent rather than CompleteControl's direct libusb path, so its code is
not a transport drop-in. It nevertheless provides useful corroboration that
MK3 control names, LEDs, encoders, and displays have been exercised on hardware.

### Relationship to the current display writer

The branch's March 2026 [partial-screen update documentation][openav-mk3-partial]
and implementation are the best current operational reference in the reviewed
sources. They use synchronous bulk writes, full frames for initial/periodic
keyframes, and bounding-box literal updates for normal changes. Zone coordinates
are aligned to 4-pixel X and 2-pixel Y boundaries. Importantly, the current zone
path changes the `0x84` header geometry and follows it with an `0x00` literal
block; it does not exercise the older `0x01` repeat or `0x02` skip helpers that
remain in the same driver. Those helpers corroborate the command encoding but
are not fresh hardware evidence for their reliability.

The openAV full-frame MK3 message uses:

```text
84 00 <screen> 60 ... geometry ...
00 00 ff 00
<480 x 272 RGB565 pixels>
03 00 00 00 40 00 00 00
```

That footer matches CompleteControl's current end sequence. CompleteControl
also inserts zero-length `0x02` skip commands around the raw block. MK3 sources
document `0x02` skip as a valid partial-update command, so the existing writer
is likely close to wire-compatible. This remains a hardware hypothesis: the
first MK3 test must cover current packets unchanged before adding a special
dialect.

The important transport change is therefore likely the USB profile, not the
pixel codec: claim display interface 5, discover/fall back to endpoint `0x04`,
and independently claim HID interface 4. Audio streaming interfaces must remain
untouched; USB-MIDI should be claimed separately only when DIN MIDI is in scope.

### CompleteControl changes delivered for MK3

The original S-Series assumptions were replaced or contained as follows:

- an MK3 product profile represents its 16 pads without pretending they are keys;
- colour-display capabilities are separate from the S-Series model enum;
- the daemon selects the MK3 input decoder by product profile and report type;
- semantic events cover pads, pressure, touchstrip, the main encoder, and
  the MK3 button set;
- MK3-specific `0x80`/`0x81` output codecs replace accidental reuse of the
  numerically identical S-Series report IDs;
- display and small-output queues remain independent so screen traffic cannot
  delay pad feedback;
- the versioned simulator wire, headless MK3 profile, and calibrated visual panel
  run below the normal daemon seam;
- MK3 calibration scenes and diagnostics run in `widget-lab` without
  leaking product-specific reports into KontrolSurfaceKit2;
- disconnect clears MK3-owned output without claiming audio, MIDI, or DFU
  interfaces.

The built-in audio interface is deliberately outside this backend. The port
should claim only the control and display functions and verify that Core Audio
continues to see and use the audio device. Supporting or proxying audio inside
`ccd` would be a separate project.

## Recommended architecture

Do not model Studio or MK3 as “another MK2 keyboard”. Split protocol family
from physical product identity:

```text
NI USB product profile
  - Studio / MASCHINE MK3 / Komplete Kontrol S MK2
        |
        +-- NI colour-display 0x84 profile
        |     - 2 x 480x272, RGB565, rectangle blits
        |     - interface/endpoint and framing dialect
        |
        +-- device-specific surface codec
              - inputs, LEDs, pads/keybed, wheel/ribbon, MIDI
```

A neutral internal name such as `NIColorDisplay84` or
`NIColorDisplay480x272` is more accurate than extending
`MK2DisplayProtocol`. Existing public `MK2*` API names need not all be renamed
in the first port; introduce the capability/profile seam first and migrate
names only where it materially reduces coupling.

## Studio effort estimate

The estimate assumes one MASCHINE Studio is physically available throughout,
USB interfaces can be claimed on the development Mac, existing CompleteControl
daemon architecture remains in place, and the goal is independent host-mode
control rather than integration with Native Instruments software.

One engineering day means approximately eight focused hours. The ranges include
implementation, focused tests, documentation, and hardware validation, but not
device procurement or waiting for external access.

### Milestones

| Milestone | Scope | Incremental effort | Cumulative effort |
| --- | --- | ---: | ---: |
| Display smoke test | Extend MK2USBSpy or add a safe diagnostic path; claim Studio; clear, colour-bar, and splash-test both displays; verify footer and endpoint | 1-2 days | 1-2 days |
| Production dual-display support | Add device/capability profiles, shared `0x84` encoder, Studio framing, reconnect/error handling, codec fixtures, dirty-rect and regression tests | 2-3 days | **3-5 days** |
| Controls except pads | Capture/decode buttons, encoders, jog wheel, pedal; implement basic lamps, jog ring, and meters; daemon events and simulator fixtures | 4-6 days | **7-11 days** |
| Full Studio surface | Pad velocity/pressure, complete LED/meter behaviour, MIDI/footswitch details, semantic mappings, demo/diagnostics, soak and regression testing | 5-9 days | **12-20 days** |

The planning number for **production-ready display support is 3-5 engineering
days**. A one-off splash on both panels may work in 1-2 days, but that is a
protocol spike, not support suitable for the main daemon.

The planning number for a **production-quality full MASCHINE Studio backend is
12-20 engineering days**, or roughly 2.5-4 calendar weeks for one engineer.
This excludes deep application-specific Paulinche workflow design; once the
semantic surface port exists, an initial useful Paulinche mapping is likely an
additional 2-4 days depending on how many Studio modes are required.

### Work-breakdown basis

| Work package | Estimate |
| --- | ---: |
| Hardware descriptor capture, USB ownership, safe smoke harness | 0.5-1.0 day |
| Shared display-family/profile refactor | 0.5-1.0 day |
| Studio display writer and framing variants | 0.5-1.5 days |
| Display codec, diffing, daemon, and MK2 regression tests | 1.0-1.5 days |
| Real-hardware display validation and recovery tests | 0.5-1.0 day |
| Buttons, encoders, jog wheel, and pedal input | 2-4 days |
| Pad velocity and pressure path | 2-4 days |
| LEDs, pad/group colours, jog ring, and meters | 2-4 days |
| Capability model, simulator, semantic mapping, and demos | 2-4 days |
| Full-surface test pass, documentation, and soak testing | 2-3 days |

Some packages overlap, which is why the summed work-package maxima are larger
than the milestone range.

## MK3 effort estimate

The MK3 estimate uses the same one-engineering-day definition and assumes a
physical MK3 is continuously available. It also assumes direct libusb ownership
of the control/display interfaces, no requirement to run MASCHINE software at
the same time, and no work on the built-in audio interface.

This section is retained as the original planning baseline, not as a statement
of remaining work. The production backend and the single-device simulator
portion through the visual MK3 panel were delivered by 2026-07-19; mixed
topology and final bench calibration are tracked separately.

### Milestones

| Milestone | Scope | Incremental effort | Cumulative effort |
| --- | --- | ---: | ---: |
| Display smoke test | Add a diagnostic MK3 profile; claim interface 5; test current full/partial packets on both displays and verify reconnect | 0.5-1.0 day | 0.5-1.0 day |
| Production dual-display support | Add device/capability profiles, endpoint-specific transport, codec fixtures, daemon recovery, dirty-rect and S-Series regression tests | 1.5-3.0 days | **2-4 days** |
| Core controls and LEDs | Port and verify buttons, eight encoders, main encoder, touch state, pedal, touchstrip, lamps, pad colours, and strip LEDs | 2-3 days | **4-7 days** |
| Full MK3 surface | Correct double-sample pad pressure/velocity path, MIDI policy, simulator fixtures/panel, semantic mappings, diagnostics, soak and regression testing | 4-7 days | **8-14 days** |

The planning number for **production-ready MK3 display support is 2-4
engineering days** when implemented independently. If the shared
`NIColorDisplay84` capability/profile seam has already been built for Studio,
MK3 display support should be only **1-2 additional days**.

The planning number for a **production-quality full MK3 backend is 8-14
engineering days**, lower than Studio's 12-20 day range because openAV-Ctlra and
Rebellion provide hardware-tested mappings for most of the surface. An initial
useful Paulinche mapping remains an additional 2-4 days depending on mode depth.

### Work-breakdown basis

| Work package | Estimate |
| --- | ---: |
| Descriptor capture, interface ownership, and audio coexistence smoke test | 0.5-1.0 day |
| Shared device/capability and colour-display profile seam | 0.5-1.5 days |
| MK3 display endpoint, packet, recovery, and throughput validation | 0.5-1.0 day |
| Surface buttons, encoders, touchstrip, and pedal decoder | 1-2 days |
| MK3 lamp, group, pad, and strip LED codecs | 1-2 days |
| Double-sample pad velocity/pressure path and latency tuning | 2-4 days |
| MIDI policy, simulator, semantic mappings, demos, and documentation | 2-4 days |
| Full hardware regression and soak testing | 1-2 days |

As with the Studio estimate, work packages overlap and should not be summed at
their maxima.

### Estimate comparison

| Target | Display smoke | Production displays | Full surface backend | Initial Paulinche mapping |
| --- | ---: | ---: | ---: | ---: |
| MASCHINE Studio | 1-2 days | 3-5 days | 12-20 days | +2-4 days |
| MASCHINE MK3 | 0.5-1 day | 2-4 days | 8-14 days | +2-4 days |

The display-family refactor is shared work and should be paid only once. If both
devices are planned, implement MK3 first: its public source coverage makes it a
safer reference device for extracting `NIColorDisplay84` from the current
S-Series-specific names. Studio can then add its framing and surface profiles on
top of the proven seam.

## Main risks

- **No device on the bench:** display confidence can be high from published
  evidence, but production support cannot be completed or honestly declared.
- **USB ownership conflicts:** Native Instruments background services may own
  interfaces and add 1-2 days of macOS investigation.
- **Packet-dialect quirks:** malformed or unsupported display sequences can
  stall a panel until reconnect or power cycle; all early writes should use a
  bounded diagnostic tool.
- **Input-report discovery:** public Studio mappings are substantially weaker
  than the display proof. Firmware variants can extend capture time.
- **Pad pressure:** this is the most timing-sensitive part and should remain
  allocation-conscious and independently testable.
- **Scope expansion:** emulating Native Instruments application modes is much
  larger than exposing Studio as a raw, semantic control surface for Paulinche.
- **MK3 audio coexistence:** claiming the whole composite device instead of only
  interfaces 4 and 5 could disrupt the built-in audio interface.
- **MK3 pad latency:** the public decoder establishes the packet layout, not the
  final feel. Both 64-byte sample sets, timestamps, velocity curves, backpressure,
  and LED scheduling need real playing tests.
- **Native Instruments service ownership:** direct libusb support and
  Rebellion-style Hardware Agent IPC are different architectures. Simultaneous
  use with MASCHINE software is not included in either estimate.

## Recommendation

For Studio alone, proceed in two gates:

1. Spend 1-2 days on the display smoke milestone with the actual Studio. The
   exit criterion is stable left/right full-frame and dirty-rectangle updates,
   including reconnect and recovery.
2. If that succeeds, budget the remaining 2-3 days for production display
   support. Decide separately whether buttons/encoders or the complete pad/LED
   surface justify the 7-20 day cumulative investment.

This keeps the low-risk, high-reuse display work independent from the much less
certain full-controller reverse engineering.

For a combined Studio/MK3 roadmap, start with MK3 and use three gates:

1. Prove that the existing CompleteControl `0x84` packet dialect works on MK3
   through interface 5/endpoint `0x04`, while its audio interface remains usable.
2. Extract the shared colour-display and device-capability seams, then complete
   MK3 buttons, encoders, touchstrip, and LEDs.
3. Treat pad velocity/pressure as its own latency-sensitive milestone. Once the
   shared display seam is stable, add Studio as a second transport/surface
   profile rather than another MK2 special case.

## Sources

- [Native Instruments MASCHINE downloads matrix][ni-downloads]
- [cabl issue #9: shared protocol statement and Studio libusb proof][cabl-issue]
- [cabl MASCHINE MK2 monochrome canvas][cabl-mk2-canvas]
- [cabl MASCHINE MK2 device transfer implementation][cabl-mk2-device]
- [RufusIbiza openAV-Ctlra MASCHINE MK3 feature branch][openav-mk3]
- [Current partial-screen update documentation][openav-mk3-partial]
- [Rebellion device support and MK3 completeness statement][rebellion-readme]
- [Rebellion Native Instruments mapping table][rebellion-mappings]
- [SynthesiaKontrol light-guide implementation][synthesia-kontrol]
- [CompleteControl protocol guide][local-protocol-guide]
- [CompleteControl USB implementation][local-usb]

[ni-downloads]: https://www.native-instruments.com/en/products/maschine/production-systems/maschine-studio/downloads-all-maschine/
[cabl-issue]: https://github.com/shaduzlabs/cabl/issues/9
[cabl-shared-protocol]: https://github.com/shaduzlabs/cabl/issues/9#issuecomment-359182811
[cabl-studio-proof]: https://github.com/shaduzlabs/cabl/issues/9#issuecomment-635110609
[cabl-mk2-canvas]: https://github.com/shaduzlabs/cabl/blob/master/src/gfx/displays/GDisplayMaschineMK2.h
[cabl-mk2-device]: https://github.com/shaduzlabs/cabl/blob/master/src/devices/ni/MaschineMK2.cpp
[openav-mk3]: https://github.com/RufusIbiza/openAV-Ctlra/blob/feature/maschine-mk3-support/ctlra/devices/ni_maschine_mk3.c
[openav-mk3-partial]: https://github.com/RufusIbiza/openAV-Ctlra/blob/feature/maschine-mk3-support/resources/maschine_mk3/PARTIAL_SCREEN_UPDATES.md
[rebellion-readme]: https://github.com/terminar/rebellion/blob/main/README.md#native-instrument-devices
[rebellion-mappings]: https://github.com/terminar/rebellion/blob/main/scripts/mappings.lua
[synthesia-kontrol]: https://github.com/ojacques/SynthesiaKontrol/blob/master/SynthesiaKontrol.py
[local-protocol-guide]: Komplete-Kontrol-Protocol-Guide.md
[local-usb]: ../Sources/KontrolUSB/KontrolUSB.c
[local-pixel-frame]: ../Sources/KontrolSurfaceKit2/PixelFrame.swift
[local-reconciler]: ../Sources/KontrolSurfaceKit2/PixelDisplayReconciler2.swift
