# MASCHINE MK3 simulator and shared simulator core

Status: single-device simulator implemented, 2026-07-19; mixed/parallel operation deferred

## Implementation checkpoint

The requested single-device milestone is implemented through the visual MK3 panel:

- `KontrolSimulatorWire` owns the Foundation-only v2 wire, bounded descriptor
  handshake, payload limits, and raw native input frames.
- `SimulatorDeviceSession` now derives product, capabilities, firmware, and name
  from the authoritative handshake and reports MASCHINE MK3 as product `0x1600`
  with no keybed or USB-MIDI claim.
- `KontrolSimulatorCore` owns device definitions, the app-side virtual-device
  socket, native gesture synthesis, framebuffer/output reduction, and the
  calibrated 320x301-mm MK3 geometry.
- `MaschineMK3InputReportBuilder` shares the production decoder's button table
  and emits native surface and pad reports for buttons, all nine encoders and
  their touch state, two touch-strip fingers, pad touch/strike/pressure/release,
  and the three analogue fields.
- The AppKit shell selects `maschine-mk3` or `komplete-kontrol-s61-mk2` without
  a second simulator product. The MK3 panel renders both displays, all native
  button and group lamps, the 25 strip LEDs, and all 16 pad colours. Mouse,
  multi-held keyboard pads, keyboard shortcuts, zoom, true size, snapshots,
  daemon ownership, and accessibility actions are wired.
- Window position, size, zoom mode, and magnification persist independently per
  device profile. A fixed window status bar keeps daemon state and model name
  outside the magnifiable panel. The MK3 presentation includes calibrated
  section alignment, NOTE REPEAT geometry, pad SHIFT legends, readable unlit
  labels and distinct dim lamps, a shared click/Command-rotate main encoder,
  and smoothed display scaling.
- The device-independent `widget-lab` has been run through the normal daemon
  endpoint against the simulated MK3; its existing MK3 LED calibration scene
  rendered on both simulator displays and illuminated the matching native
  button, group, direction, and pad targets.

Developer flow:

```bash
make run-mk3-simulator
# In the simulator: Daemon -> Start Simulator Daemon
make widget-lab-sim
```

The original `make run-simulator` KONTROL flow remains available and was used
as the regression client of the extraction.

The following planned work is deliberately not part of this checkpoint:

- simultaneous MK2 and MK3 simulator instances;
- product-bound real/simulated daemon pairs and endpoint isolation;
- Paulinche's composite two-surface port and four-display projection;
- both-real coexistence, latency, colour, pressure-feel, and USB calibration.

Those remain Phase 5/6 follow-up work below. The single-device simulator must
not be described as evidence for them.

## Outcome

CompleteControl should keep one `KontrolSimulator` product and extract a shared,
headless simulator core from the current S-Series MK2 implementation. The app
then selects a physical device profile (`komplete-kontrol-mk2` or
`maschine-mk3`) instead of growing a second, independent MASCHINE mock.

The simulator remains below the daemon at the existing `KontrolDeviceSession`
seam. A simulated MK3 must therefore look like an MK3 to the unchanged daemon,
device compatibility adapter, Widget Lab, and Paulinche. It must not inject
already-lowered application commands or pretend to be an MK2.

Mixed operation uses the same topology already selected for the first
KONTROL/MASCHINE parallel-operation phase: one product-bound daemon endpoint per
surface. Either endpoint may be backed by real USB or by a simulator. This gives
the four required combinations without introducing a multi-device daemon:

| KONTROL endpoint | MASCHINE endpoint | Required use |
| --- | --- | --- |
| real | simulated | Main development case without the MK3 at the desk |
| simulated | real | Inverse compatibility and hardware bring-up case |
| simulated | simulated | Deterministic CI and dual-surface development |
| real | real | Final latency, colour, pressure, reconnect, and coexistence evidence |

The simulator is authoritative for mappings, application workflows, daemon
transport, display pixels, and state isolation. It is not evidence for USB
timing, OLED or LED colour, pad mechanics, pressure feel, or physical latency.

## Current state

The existing architecture already has the correct deep boundary:

```text
KontrolSimulator app
    DeviceLink (Unix-socket server)
             |
             | SimWireProtocol
             v
ccd -> SimulatorDeviceSession -> KontrolDeviceSession
             |
             v
unchanged daemon protocol -> Kit2/client
```

This is worth preserving. The real and simulated sessions already participate
in the same daemon reactor, reconnect path, display shadow, output queues, and
client protocol.

The remaining S61 assumptions are concentrated enough to extract, but are
currently structural rather than cosmetic:

- `SimulatorDeviceSession` reports product `0x1620`, 61 keys, and a fixed MK2
  profile. The `hello` frame sent by the app is currently not authoritative.
- Simulator input frames carry MK2 semantic controls. The daemon lowers them
  through `MK2InputReportBuilder`; the wire cannot express native MK3 buttons,
  pads, dual-touch-strip samples, or MK3 report state.
- `PanelView` combines S-Series layout, drawing, hit testing, audio feedback,
  keyboard shortcuts, report interpretation, and input synthesis in one AppKit
  file.
- `DeviceLink`, framebuffer storage, daemon process ownership, endpoint names,
  defaults, snapshots, and window chrome live in the executable instead of a
  reusable core.
- Device and daemon sockets are global singleton paths, which prevents two
  simulator instances and makes mixed-operation orchestration ambiguous.
- The app decodes MK2 output palettes and light-guide reports directly. It has
  no profile-owned MK3 `0x80` button/pad or `0x81` strip/pad output state.

Useful production MK3 code already exists and must be reused:

- `KontrolDeviceProfile` and MK3 capabilities;
- the native `MaschineMK3Button`, LED, pad, input observation, surface decoder,
  pad decoder, and pad state tracker;
- the single Kit2 compatibility mapping and MK3 output lowering in
  `SurfaceDeviceCompatibility.swift`;
- the two-screen 480x272 RGB565 display path and daemon display shadow;
- device-native output clear and reconnect behaviour;
- Widget Lab MK3 LED and pad calibration demos.

The extraction should not rename the public `MK2*` Kit2 surface vocabulary.
That broader naming cleanup is independent and must not block the simulator.

## Target package boundaries

The package graph must remain acyclic. A two-layer extraction is therefore
preferable to moving all simulator code into one target:

```text
KontrolSimulatorWire              Foundation-only leaf target
        ^                                  ^
        |                                  |
KompleteKontrol                    KontrolSimulatorCore
  - production codecs               - device definitions
  - SimulatorDeviceSession           - app-side DeviceLink
  - MK2/MK3 report builders           - panel/output state
        ^                              - headless runtime
        |                                  ^
        +----------------+-----------------+
                         |
                 KontrolSimulator
                    AppKit shell
```

### `KontrolSimulatorWire`

Own only the versioned, length-prefixed wire and endpoint value types:

- frame header/codec and size limits;
- simulator handshake and immutable device descriptor;
- raw surface-input report and raw MIDI-input packet frames;
- output report, display blit, and physical display-packet frames;
- protocol-version negotiation and explicit rejection reasons.

It must not import AppKit, `KontrolUSB`, Kit2, MK2 button enums, or MK3 enums.
The current typed MK2 convenience constructors move out of this leaf.

### `KompleteKontrol`

Keep the daemon-side `SimulatorDeviceSession` here because it implements the
internal production device seam. It consumes the wire descriptor, reports the
real selected product profile, forwards raw simulated input bytes to the same
sinks as libusb, and sends daemon output frames back to the simulator.

Add a production `MaschineMK3InputReportBuilder` alongside the decoder. Builder
and decoder must share the same button-bit, encoder, touch, strip, and pad layout
tables. Do not copy the private decoder table into the simulator. The existing
`MK2InputReportBuilder` remains the MK2 implementation of the same concept.

### `KontrolSimulatorCore`

Own everything useful without an `NSView` or an `NSApplication`:

- simulator instance configuration and endpoint ownership;
- app-side socket server lifecycle and reconnect state;
- selected simulated device definition;
- stateful input-report builders;
- output report reduction into typed lamp, pad, strip, light-guide, and display
  state;
- two RGB565 framebuffers and display-packet decoding;
- profile-defined panel/control geometry;
- deterministic gesture injection for tests and automation;
- observable state snapshots with no dependence on window size or screen DPI.

The core should be usable by unit tests, a future CLI fixture, and the visual
app. It should not start `ccd`; process ownership belongs to the app shell or a
dedicated orchestration command.

### `KontrolSimulator` AppKit shell

Keep window management, menus, magnification, physical-size monitor
calibration, application defaults, sound feedback, and accessibility here.
Select or construct a profile-backed panel rather than an S61-only
`PanelView`.

## Simulator device model

Use separate protocol, panel, and runtime concepts rather than a large switch
inside a generalized view:

```text
SimulatorDeviceDefinition
  identity: product ID, family, firmware, key/pad/display capabilities
  protocolDriver: semantic gesture <-> native report state
  outputDriver: native output report -> typed panel state
  panelDefinition: physical geometry and visual/control descriptors
```

Recommended headless gesture vocabulary:

- button press/release by stable physical control ID;
- encoder touch/release and signed rotation;
- directional encoder push, center press, touch, and rotation;
- key note on/off, velocity, pitch, modulation, and aftertouch for KONTROL;
- pad touch, strike, held pressure, and release for MASCHINE;
- one or two touch-strip fingers with position/release;
- explicit reset/unplug/reconnect operations.

The gesture is converted to a native report inside the selected device driver.
The daemon receives the same report shapes its production decoder receives from
hardware:

- MK2: native `0x01` surface and raw ribbon reports plus USB-MIDI packets;
- MK3: native 42-byte `0x01` surface reports and 64-byte `0x02` pad reports;
- MK3 does not synthesize MK2 MIDI or claim a key count.

For pads, the builder must model the complete lifecycle accepted by the current
pad tracker: below-trigger touch where available, strike velocity, held
pressure samples, and explicit release. The known record-slot-3 neutral sentinel
is a protocol fixture, not a mandatory artefact in every synthetic report; its
presence can be a selectable hardware-fidelity fixture.

## Wire protocol migration

Introduce a version-2 handshake before adding MK3 UI. The current `hello`
message is sent but ignored, so merely adding product ID to it would preserve a
false contract.

The handshake should contain at least:

- wire version;
- product ID and reported key count;
- firmware/bcdDevice value;
- optional reported name override;
- stable simulator instance ID for diagnostics;
- supported input and output frame capabilities.

`SimulatorDeviceSession.open` performs a bounded handshake before exposing a
session to the daemon. It resolves `KontrolDeviceProfile` from the product ID,
rejects an unsupported product or version, and then makes the socket
non-blocking. Device family cannot change on a connected session; changing the
selected profile is an unplug/reconnect and, for an app-owned daemon, a clean
daemon restart. Name and firmware overrides may remain live identity updates.

Version 2 should add raw `surfaceInput` and `midiInput` frames. The existing
semantic MK2 input frames remain temporarily decodable while the current
KONTROL panel migrates, then are removed once both profiles emit raw reports.
This staged compatibility keeps the extraction reviewable and preserves the
current simulator tests during the transition.

Output can retain both existing paths initially:

- logical display blits for the legacy device-session path;
- raw shared `0x84` display packets for adaptive encoding;
- native `reportID + payload` frames for LEDs, pads, strip, and light guide.

The simulator core reduces either display representation into the same
framebuffer. A later shared `NIColorDisplay84` naming cleanup may make the
packet path fully device-neutral, but it is not a prerequisite for the MK3
profile.

## Panel geometry and physical metrics

The official Native Instruments specification gives the MK3 chassis as
320 mm wide, 301 mm deep, and 41 mm high. The official online manual contains a
near-orthogonal full top-panel overview and separate control, edit,
performance, group, transport, and pad-section views. These are sufficient for
a proportionally credible first panel.

Represent panel geometry in physical millimetres, not window pixels:

```swift
struct SimulatorPanelDefinition {
    var physicalSizeMM: CGSize       // MK3: 320 x 301
    var controls: [SimulatorControlDescriptor]
    var displays: [SimulatorDisplayDescriptor]
}
```

The AppKit view maps this canonical space to points and applies scroll-view
magnification. `True Size` should use the whole device footprint for MK3 and
the monitor's reported physical size; it must not reuse the current MK2
display-only 95-mm calibration label.

Calibration process:

1. Rectify the four visible chassis corners of the official top-panel image to
   a 320x301-mm rectangle.
2. Record major section bounds, display active areas, encoder/pad centres,
   button rectangles, and inter-control pitches as derived numeric geometry.
3. Cross-check every label and control count against the manual's detailed
   section images and the production MK3 enums.
4. Keep provenance and confidence (`official dimension`, `image-derived`, or
   `bench-measured`) with the geometry source. Do not silently promote an
   estimate to a measurement.
5. Store the derived coordinates and a calibration note, not a copyrighted NI
   product raster, in the application.

First-pass visual tolerances:

- chassis aspect and overall footprint use the official dimensions exactly;
- major section boundaries and display/pad blocks should be within 3 mm of the
  rectified reference;
- repeated pad and encoder pitches should be internally consistent within
  0.5 mm;
- individual control centres should be within 2 mm of the rectified reference;
- uncertain bevels, radii, legends, and active display dimensions stay marked
  as estimates until measured.

Two full-resolution user photographs with metric rulers are available for the
visual-calibration gate:

- [width calibration, original 4355x4283](images/maschine-mk3-calibration-width-ruler.jpg)
- [depth calibration, original 3917x3285](images/maschine-mk3-calibration-depth-ruler.jpg)

The width view covers the complete 320-mm top edge; the depth view covers the
301-mm side and preserves all four chassis edges. Rectify each face plate from
its four outer corners, then use the ruler as an independent scale check. These
photographs are calibration evidence only and must not be packaged as
`KontrolSimulator` application resources. No additional photograph is required
for the 2-D panel. Optional oblique close-ups would help with control height and
bevels, but those are outside functional simulator acceptance.

Official references:

- [MASCHINE MK3 dimensions and features](https://www.native-instruments.com/de/products/maschine/production-systems/maschine/specifications/)
- [MASCHINE MK3 manual: hardware overview](https://www.native-instruments.com/ni-tech-manuals/maschine-mk3-manual/en/quick-reference#maschine-hardware-overview)
- [MASCHINE manuals and downloads](https://www.native-instruments.com/en/products/maschine/production-systems/maschine/downloads/)

## Reusable visual controls

Extract reusable drawing and interaction pieces only after their state is in
the headless core:

- RGB565 display view and screen bezel;
- labelled illuminated button with separate pressed and lamp state;
- endless touch-sensitive encoder;
- directional/push encoder;
- touch strip with one- and two-finger visualization;
- velocity/pressure pad with colour and held-pressure indication;
- KONTROL key and light-guide strip;
- connection/status overlay and optional raw-value diagnostics.

The existing KONTROL panel is the regression client of this extraction. Migrate
it before drawing the MK3, retaining its current input behaviour, snapshot,
zoom, daemon menu, and keyboard cheat sheet. Do not attempt a simultaneous
photorealistic redesign of the KONTROL panel.

MASCHINE interaction details:

- mouse down/up must emit paired button and pad states even if the pointer
  leaves the original control;
- vertical position or a visible modifier can set pad strike velocity;
- dragging while held changes poly-pressure; the current value should be
  visible in a small diagnostic overlay;
- a mouse can operate one pad at a time, while keyboard shortcuts and headless
  injection must support several held pads for chord/ownership tests;
- encoder wheel/drag emits realistic bundles of counts, while a diagnostics
  overlay can show raw and lowered deltas;
- Command-click may remain the explicit touch-only gesture for touch encoders;
- keyboard mappings must be profile-specific and listed in the cheat sheet;
- all controls need AppKit accessibility roles, labels, values, press actions,
  and keyboard access. Geometry alone is not an interaction model.

Use semantic colours and typography from a small simulator appearance layer.
Device legends may visually remain fixed to the dark hardware, while menus,
dialogs, focus rings, and diagnostics follow macOS appearance, contrast, and
reduced-motion settings. New user-facing strings should be localization-ready.

## Mixed real/simulated operation

The simulator does not itself make Paulinche multi-surface. It supplies one
normal daemon endpoint to the already planned `CompositeControlSurfacePort`.
Keep these responsibilities separate:

```text
real KONTROL USB                     simulated MASCHINE MK3
       |                                      |
ccd --product kontrol-mk2             KontrolSimulator --device maschine-mk3
       |                                      |
hardware daemon socket                 ccd + simulator daemon socket
       |                                      |
CompleteControlSurfaceAdapter A        CompleteControlSurfaceAdapter B
                \                      /
                 CompositeControlSurfacePort
                              |
                     Paulinche command layer
```

Required endpoint changes:

- replace global simulator paths with a validated `SimulatorInstanceID` and
  explicit device socket, daemon base socket, log, and lock paths;
- keep Unix paths short enough for `sockaddr_un`;
- let the app copy a complete client/instance configuration, not only one
  `KK_DAEMON_SOCKET` assignment;
- add explicit `ccd` product selection for real hardware as already planned in
  the parallel-operation backlog;
- never use daemon auto-discovery in a composite configuration;
- an app-owned daemon may be restarted by that simulator instance only;
  cleanup must unlink only the instance's validated socket files and must not
  `pkill` unrelated real or simulated daemons;
- use endpoint-assigned `SurfaceID`s in the two-daemon phase. A simulator
  instance ID is useful provenance but does not replace Paulinche's source
  identity and per-note ownership rules.

Suggested instance commands after implementation:

```text
KontrolSimulator --device maschine-mk3 --instance mk3-dev
KontrolSimulator --device komplete-kontrol-s61-mk2 --instance kk-dev

make mixed-kontrol-real-maschine-sim
make mixed-maschine-real-kontrol-sim
make mixed-both-sim
```

The make targets should print resolved sockets and commands, validate that all
paths are distinct, and leave existing daemons alone unless they own the exact
selected endpoint. The GUI may offer a device picker, but command-line profile
and instance selection are required for deterministic tests.

## Delivery phases

### Phase 0 - freeze evidence and contracts (completed 2026-07-19)

- Record the current simulator target graph, wire frames, paths, snapshots,
  menu behaviour, and KONTROL input/output fixture coverage.
- Add the official MK3 geometry calibration note and derived layout data draft.
- List every native MK3 control against decoder, LED, compatibility mapping,
  and planned panel descriptor; identify deliberately unsupported controls.
- Decide short canonical IDs and endpoint paths.

Gate: there is a reviewed mapping/geometry inventory and no unknown control is
hidden behind a guessed MK2 equivalent.

### Phase 1 - versioned wire and authoritative identity (completed 2026-07-19)

- Add `KontrolSimulatorWire` and move the generic frame codec.
- Implement the version-2 descriptor handshake with bounded open-time timeout.
- Make `SimulatorDeviceSession` select `KontrolDeviceProfile` from the
  descriptor instead of hard-coding S61.
- Add raw surface/MIDI input frames while retaining temporary v1 MK2 lowering.
- Add malformed frame, oversized frame, version mismatch, unknown product,
  partial read/write, EOF, and reconnect tests.

Gate: a headless socketpair can report either S61 MK2 or MASCHINE MK3 through
`deviceInfo`, and unsupported identities fail before client registration.

### Phase 2 - extract the shared seam without changing KONTROL behaviour (milestone complete 2026-07-19)

- Add `KontrolSimulatorCore` and move `DeviceLink`, framebuffers, connection
  state, output reduction, instance configuration, and snapshot state.
- Split S-Series geometry and input/output handling out of `PanelView`.
- Replace direct view-to-wire callbacks with profile gestures and raw reports.
- Migrate current KONTROL UI to shared visual primitives.
- Preserve current panel snapshots or review any intentional pixel changes.

Gate: the S61 simulator passes its existing socket/session tests, visual
snapshot, Widget Lab smoke, zoom/true-size flow, input cheat sheet, daemon
autostart, and unplug/reconnect path with no MK3 selected.

The milestone extracted the wire, device definition, output state, daemon link,
and native MK3 runtime while retaining the mature KONTROL `PanelView` as the
regression frontend. Splitting all KONTROL geometry into descriptors remains an
optional cleanup; it is not required for shared clients or the MK3 profile.

### Phase 3 - headless native MK3 profile (completed 2026-07-19)

- Add the shared-table `MaschineMK3InputReportBuilder`.
- Implement all mapped buttons, main and display encoders, encoder touch,
  touch strip, and pad lifecycle as native reports.
- Reduce MK3 `0x80` and `0x81` output into typed button, group, strip, and pad
  lamp state.
- Reuse the shared display framebuffer/packet path for both 480x272 screens.
- Run the unchanged Kit2 compatibility runtime and Widget Lab against the
  headless profile.

Gate: semantic gestures round-trip through native MK3 bytes, the production MK3
decoder, compatibility adapter, and Widget Lab; no fake MK2 report is generated.

### Phase 4 - visual MK3 panel (completed 2026-07-19)

- Implement the 320x301-mm panel from the calibrated definition.
- Wire every supported control to the headless profile and every native output
  state to shared visual controls.
- Add pad velocity/pressure, multi-held keyboard input, encoder/touch gestures,
  profile-specific shortcuts, accessibility, and diagnostics.
- Add stable disconnected, connecting, connected, reconnecting, and protocol
  error presentations.
- Add full-panel and display-work-area snapshot fixtures.

Gate: every decoded/illuminated MK3 control has one visible, interactive panel
element; geometry meets the first-pass tolerances; snapshots are deterministic.

### Phase 5 - instance isolation and mixed topology (deferred)

- Parameterize instance ID, device socket, daemon socket, logs, defaults, and
  snapshot output.
- Make app-owned daemon startup profile-aware and instance-scoped.
- Add safe orchestration for real+simulated and simulated+simulated matrices.
- Connect the two explicit endpoints through Paulinche's separately planned
  composite port and stable `SurfaceID`s.
- Exercise one-surface loss, restart, sleep/wake, concurrent input, identical
  note ownership, four displays, lamps, light guide, and pads.

Gate: real KONTROL plus simulated MK3 and simulated KONTROL plus real MK3 both
work without endpoint fallback, state leakage, or interruption of the surviving
surface.

### Phase 6 - bench calibration (deferred)

- Compare every visual control with a real MK3 input capture and every lamp/pad
  with known output reports.
- Calibrate pad lifecycle, velocity/pressure curves, encoder counts, touch
  timing, strip behaviour, and reconnect edge cases.
- Optionally rectify a measured user top-down photo and update only geometry
  values whose confidence improves.
- Run the final both-real four-display stress and audio-interface coexistence
  smoke.

Gate: all simulator-only assumptions are documented, and hardware-only evidence
has been collected for timing, physical colour, pressure feel, USB coexistence,
and shutdown restoration.

## Test strategy

### Core and protocol tests

- wire encode/decode, fragmentation, multiple frames, unknown type, and payload
  limit tests;
- authoritative handshake and profile-selection tests;
- stateful MK2 and MK3 builder/decoder round trips for every supported control;
- simultaneous pad, key, button, touch, and release ownership sequences;
- native MK3 output report reduction including raw diagnostic LED bytes;
- display blit and adaptive packet convergence into identical framebuffers;
- device loss, reconnect, output cancellation, and identity-update tests;
- geometry invariants: bounds, unique IDs, repeated pitch, display count, and
  intentional overlap annotations.

### Integration tests

- `SimulatorDeviceSession` socketpair tests for both families;
- unchanged daemon binary client and device-info flow;
- Widget Lab MK2 and MK3 calibration scenarios against headless profiles;
- per-profile simulator snapshot tests;
- two isolated simulator instances with distinct device/daemon sockets;
- dual fake/simulator daemon harness for fan-out, event provenance, and one-side
  failure;
- explicit real/sim matrix smokes, followed by the both-real stress run.

### Manual quality checks

- mouse capture and release outside a control;
- fast encoder rotation, touch-only gesture, and profile keyboard shortcuts;
- multiple keyboard-held pads with pressure changes;
- VoiceOver traversal/order, control names, state/value announcements, and
  activation;
- small window, fit width, display zoom, true size, multiple monitors, and
  monitor changes;
- dark/light macOS shell, increased contrast, reduced motion, and text clipping;
- app-owned daemon termination and absence of stale sockets or orphaned child
  processes.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| New package targets create a dependency cycle | Keep the wire Foundation-only; daemon session remains in `KompleteKontrol`; core depends inward |
| Simulator duplicates or drifts from MK3 mappings | Builder and decoder share production tables; panel refers to production control IDs |
| A semantic sim wire masks real report bugs | Version 2 transports raw native reports from the profile builder |
| Core extraction silently regresses KONTROL | Migrate KONTROL first and keep its current session, snapshot, Widget Lab, and reconnect gates |
| Two simulator instances collide | Require validated instance IDs and explicit, distinct short paths |
| Mixed mode attaches a client to the wrong daemon | Composite mode disables auto-discovery and configures both endpoints explicitly |
| Simulator child cleanup affects real hardware | Track process ownership; never broad-kill; unlink only validated instance files |
| Manual artwork looks exact but is only estimated | Store millimetres with source/confidence and keep hardware-only calibration gate |
| Mouse cannot express polyphonic pad use | Support multi-held keyboard/headless input and treat mouse as a one-pointer convenience |
| Simulator becomes a USB timing oracle | State non-goals in UI/docs and require physical hardware for latency and colour claims |

## Acceptance definition

The single-device MASCHINE simulator milestone is complete:

- `KontrolSimulator` can select MK2 or MK3 without separate product codebases.
- The selected product and capabilities reach daemon clients through the
  production device-info path.
- Every mapped MK3 button, encoder, touch control, and pad gesture becomes a
  native MK3 input report and round-trips through the production decoder.
- Both MK3 displays, button lamps, group lamps, strip LEDs, and pad colours are
  visible from native daemon output reports.
- The MK3 panel uses the official 320x301-mm footprint and reviewed derived
  control geometry.
- Headless tests do not require AppKit and visual tests do not require a daemon.
- Final docs distinguish simulator evidence from hardware-only evidence.

The following acceptance belongs to deferred parallel-operation Phase 5/6, not
to the delivered single-device simulator:

- Two simulator instances can coexist, and one simulated endpoint can coexist
  with a real hardware daemon without path or process collisions.
- Paulinche can attach explicit KONTROL and MASCHINE endpoints, preserve
  `SurfaceID` event ownership, and survive loss of either endpoint.

## Rough effort and recommended order

The originally estimated wire, shared-seam, headless-profile, and visual-panel
sequence is now delivered. Remaining effort is concentrated in instance/path
isolation, two-daemon orchestration, Paulinche's separately planned
`CompositeControlSurfacePort`, mixed-failure testing, and final hardware
calibration. Preserve the implemented dependency order: versioned identity and
native reports remain below the daemon; mixed topology builds on explicit
endpoints rather than weakening that seam.
