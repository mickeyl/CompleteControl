# MK3 ODR Protocol — Findings from the on-device firmware image

Reverse-engineering notes from the **Komplete Kontrol S-Series MK3 firmware updater**
(`NI/KSMK3Updater.app`). These findings **revise a central assumption** of
`MK3-Porting-Plan.md`: the MK3 display is *not* a host-pushed framebuffer. Read this
first, then the (now-annotated) porting plan.

> Status: **static analysis of the device-side binaries**, no hardware capture yet.
> Everything below is derived from the shipped firmware image — the *device side of
> the protocol* — not from USB sniffing. That makes it high-confidence about
> *structure* and lower-confidence about *exact byte layout* until confirmed on the bench.

## Source material

`KSMK3Updater.app/Contents/Resources/payload` is a **395 MB ext4 image**, volume label
`rootfs`, NativeOS version **`2.1.2 (R0)`**. It is the embedded Linux that runs **on the
keyboard**. Read it without mounting via `7z` (p7zip reads ext4):

```bash
PAYLOAD=NI/KSMK3Updater.app/Contents/Resources/payload
7z l "$PAYLOAD"                       # list
7z x "$PAYLOAD" usr/bin/ni-roda -o/tmp/x   # extract a path
```

Key artifacts inside:

| Path | What it is |
| --- | --- |
| `usr/bin/ni-roda` | **The on-device rendering app.** 26 MB ARM-32 Qt/QML app. *Stripped of locals but RTTI/typeinfo + RPC method-name strings are intact.* This is the device-side protocol decoder. |
| `lib/firmware/ni-m4firmware-stm32mp1-S{32,49,61,88}.elf` | **Cortex-M4 realtime firmware**, per model. *Statically linked, not stripped.* Owns USB, keybed, LEDs, MIDI. |
| `lib/systemd/system/ni-roda.service` | systemd unit: *"Komplete Kontrol on-device rendering app"*. |
| `etc/ni-user.env` | Qt eglfs config: **1280×480**, physical 209×78 mm, `QT_QPA_PLATFORM=eglfs`. |
| `usr/bin/NIDisplayTool`, `NIHIDTool`, `NIUSBTool`, `ni-bulk-pipe-validator` | NI bringup/test tools (ARM, stripped). |
| `vendor/lib/libGLESv2 / libEGL / libgbm_viv` | Vivante GPU userspace — display is GPU-composited locally. |

## The actual architecture (STM32MP1, dual-core)

The MK3 is **not** a USB peripheral with a dumb panel. It is a small Linux computer:

```
            ┌─────────────────────── STM32MP1 ───────────────────────┐
  USB  ────►│  Cortex-M4 (RT firmware)        Cortex-A7 (Linux)       │
  host      │  ┌───────────────────┐  rpmsg   ┌────────────────────┐  │
            │  │ USB gadget:        │◄────────►│ ni-roda (Qt/QML)   │  │──► 1280×480
            │  │  HID/MIDI/DFU/     │ /dev/    │  RodaCore UI       │  │    panel
            │  │  CDC/**ODR**       │ rpmsg-   │  msgpack-RPC server │  │    (EGL/GLES)
            │  │ keybed/LED/AT/LG   │ ni-sdb   │  AssetCache (sha256)│  │
            │  └───────────────────┘          └────────────────────┘  │
            └─────────────────────────────────────────────────────────┘
```

- The **M4 firmware** exposes **multiple independent USB interfaces** (string-descriptor
  symbols in the M4 ELF): `auUSBDStringIntf{HID,MIDI,DFU,CDCCommand,CDCData,ODR}`, plus
  MIDI 2.0 group terminal blocks (`MIDI2GTB{Main,DAW,ExtIn,ExtOut}`) and three MIDI jacks
  (`Keybed`, `DAW`, `External`). MIDI is UMP / MIDI 2.0.
- The **`ODR` interface** is the dedicated bulk pipe that carries the rich-display
  protocol. The M4 bridges it to the A7 over **rpmsg** (`ni::odr::transport::stm32mp1::
  stm32mp1_bulk_rpmsg_endpoint`, dev node `/dev/rpmsg-ni-sdb`). M4 log strings confirm:
  *"ODR Sync In: Received message when USB not ready."*
- **`ni-roda`** (= *NI Rendering On-Device App*; C++ namespace `ni::odr`) runs the
  msgpack-RPC server, holds the host-driven models, and renders them with **Qt Quick**
  (`qrc:/qt/qml/RodaCore/...`). The display is GPU-composited from a QML scene graph on
  the device — the host never sees pixels.

## The protocol is msgpack-RPC, semantic not pixel

The wire protocol is **MessagePack-RPC** (`ni::msgpack_rpc::dispatcher`,
`make_dispatch_handler`, `request_id_tag`, `msgpack::v2::object`). The command parser
lives in `ni::odr::protocol::kks` (`kks` = Komplete Kontrol S-series):

- `concrete_host_command_parser` / `concrete_device_command_parser`, each with
  `register_handlers()` binding lambdas to typed messages.
- Entry point is a **handshake**: `kks::handshake` → `kks::handshake_reply`
  (`RendererApplicationBase::handleHandshake`). Versioned via `device_protocol_version`.

### Host → device verbs

High-level **actions** (`ni::odr::renderer::actions::device_actions`, a `std::variant`):

```
set_odr_model · set_page · request_focus · release_focus ·
follow_genericdaw_focus · set_plugin_identifier · request_instance_focus ·
set_tempo · request_daw_parameter_page
```

**Model updates** (dispatched RPC method names, verbatim from `ni-roda` log strings):

```
parameter_page_set_model · parameter_page_model_set_data ·
parameter_page_model_set_host_owned_viewstate ·
parameter_page_model_set_device_owned_viewstate ·
lightguide_set_model ·
browser_set_data · browser_set_sounds · browser_set_filters ·
browser_set_filter · browser_set_filter_selection · browser_set_sound_selection ·
smartplay_set_data · smartplay_set_device_owned_viewstate
```

Note the **host-owned vs device-owned viewstate** split: some state the host pushes, some
the device owns (e.g. local cursor/scroll), and they are reconciled — directly analogous
to CompleteControl's own *intended vs last-sent* reconciler model.

### Device → host events

Surface input flows back as model/observer updates: `display_button_event`,
`display_erp_event` / `display_erp_touch_states` (the 8 endless-rotary encoders + their
touch), `lightguide_observer`, `midi_active_note_observer`, focus changes
(`focus_acquire`/`focus_acquired`/`focus_client_changed`), browser navigation, etc.

### A7 → M4 firmware control (over rpmsg, not USB)

`ni::odr::renderer::KKSMk3FirmwareController` issues the low-level hardware commands the
M4 owns: `setLEDBrightness`, `setDefaultLedColor`, `setMIDITemplate`, `setCurrentMIDIPage`,
`setAftertouchMode/Curve/Delay`, `setPedalCalibration`. **Implication:** LED/light-guide
brightness, aftertouch curves and MIDI templates are *device-internal* concerns reached
through ni-roda's models — not raw HID writes from the host.

## Drawing custom graphics: the asset path

There **is** a way to get bespoke imagery on screen, just not via a framebuffer:
`ni::odr::protocol::host_models::file_asset` + `renderer::AssetCache`
(`addAsset`/`removeAsset`/`populateFromCache`). Assets are content-addressed by
**SHA-256** (`device_asset_id_tag`, a 32-byte id over `std::span<const std::byte, 32>`),
cached on device, and referenced by id from the models. Decoders linked into ni-roda:
**webp, png, jpeg, tiff** (`libwebp`, `libpng16`, `libjpeg`, `libtiff`). So the realistic
"free image" path is: upload a compressed image as an asset → reference its id in a model
field. Bitmap size/format constraints are TBD on hardware.

## Multiple transports — a likely RE shortcut

`ni-roda` instantiates the msgpack-RPC server over **three** transports (boost.asio):

- `ni::odr::transport::stm32mp1::stm32mp1_bulk_rpmsg_endpoint` — the production USB→rpmsg path.
- `ni::odr::transport::tcp::device_factory(port, ...)` — **TCP**.
- `ni::odr::transport::uds::device_factory(path)` — **Unix domain socket**.

A `gtest_stream_result_to=HOST:PORT` string and gtest symbols suggest the TCP/UDS paths
exist for host-side testing/emulation. **If the TCP transport is reachable on a dev unit
(or over the CDC/network interface), the entire display protocol could be exercised
without solving USB-bulk framing at all** — a much cheaper RE loop than USB sniffing.
Worth probing early.

## What this overturns in `MK3-Porting-Plan.md`

1. **"Display = host-pushed RGB565 framebuffer over bulk (like Maschine MK3)."** Wrong.
   No host pixel path exists. The panel is rendered on-device by a Qt/QML app; the host
   sends a **semantic model** over msgpack-RPC. The "framebuffer format is the gating
   unknown" framing is the wrong target. The real target is the **msgpack-RPC schema** —
   and we have the device-side decoder to reconstruct it from, rather than black-box
   captures.

2. **"LED control and MIDI input are mutually exclusive (the showstopper)."** Almost
   certainly an artifact of the **legacy HID interface** the community probed (`A0 00 00`
   mode toggle, `0x82`/`0x84`). On the MK3, **MIDI is its own USB interface and the rich
   UI is the ODR interface** — they are not mutually exclusive at the USB level. The
   tracker-remote use case (key input + display + light guide simultaneously) is what
   NI's own stack does every day over these parallel interfaces. The "hard prerequisite /
   product-viability risk" should be downgraded pending a bench check of the ODR path.

3. **Effort/sequence.** The "open-ended display RE phase" shrinks from *invent a
   framebuffer format* to *map a named, typed RPC API we can already read symbol-by-symbol*.
   The remaining unknowns are byte-level msgpack layout and USB-bulk framing of the ODR
   interface — bounded problems.

## Confidence & caveats

- **High confidence:** dual-core architecture; ODR is a distinct USB interface bridged via
  rpmsg; protocol is msgpack-RPC under `ni::odr::protocol::kks`; display is on-device QML;
  asset path is sha256-addressed compressed images; separate MIDI interface.
- **Medium:** exact verb set (only those with vtables / cleartext log strings are visible
  so far — full enumeration is task 3).
- **Unverified (needs hardware):** USB interface/endpoint numbers and PIDs; the ODR bulk
  framing (length-prefix etc.); whether TCP/UDS transports are reachable externally;
  asset bitmap constraints; whether host integration requires NI's handshake/auth.

## RodaCore UI model map (from carved QML)

The QML is embedded in `ni-roda` as uncompressed source (Qt resource, no `.qml` files on
the rootfs). Carved with `NI/extracted/carve_qml.py` → **67 QML blobs** in
`NI/extracted/RodaCore-qml/`. The UI is organised around a set of **host-driven models**;
these are the same models the msgpack-RPC verbs populate, so their fields are the protocol
payload shape. Top-level models and the fields the QML actually reads:

| Model (QML object) | Driven by RPC | Fields seen in QML |
| --- | --- | --- |
| `parameterModel` / `parameterPageModel` | `parameter_page_*` | `parameters`, `name`, `isEmpty`, `editMode`, `background`, `hasBackgroundImage`, `nksControlColor` |
| `mixerModel` | (focus/daw) | `selectedTrackName`, `selectedPluginPresetName`, `dawTempo`, `mixerFocus` |
| `smartplayModel` | `smartplay_set_*` | `arpEngine`, `scaleEngine`, `focus`, `onBoardSelected` |
| `browserModel` + `soundModel`/`productModel`/`scrollListModel`/`tagModel` | `browser_set_*` | `sounds`, … (list/grid views) |
| `midiModel` / `midiTemplateEditorModel` | `midi_template_*` | `name`, `parameters`, `imageData`, `hideName` |
| `instanceClientStateModel` | `set_odr_model` / focus | `browserAvailable`, … |
| `globalViewStateViewModel` | `set_page` / focus | page/view routing |
| `erpTouchStateViewModel` / `erpRowModel` | input (device→host) | the 8 endless-rotary touch/turn states |
| `buttonModel` | input/focus | `visible`, `isChildPlugin`, `isContainerPlugin` |
| `deviceInfoModel` | handshake | `versionNumber`, serial, … |
| `tempoConfigModel` | `set_tempo` | `midiClockTempo` |
| settings: `pedalsSettingsModel`, `buttonsAndKnobsSettingsModel`, `touchstripWheelsSettingsModel` | settings RPC | calibration/preferences |

QML component types worth noting (UI vocabulary we'd map the `Screen` DSL onto):
`VisualSlider`, `EnumParameter`, `FilterLabel`, plus `ListView`/`GridView`/`Flow` for the
browser. Several models carry **image fields** (`parameterModel.hasBackgroundImage`,
`midiModel.imageData`, browser `productImage`/`imageSource`) — these are where the
**sha256 asset path** surfaces in the UI, confirming images reach the screen as uploaded
assets, not framebuffer writes.

## ODR msgpack-RPC method tables (recovered from `register_handlers`)

The dispatcher binds each handler via `msgpack_rpc::dispatcher::wrap_function`. The mangled
`make_dispatch_handler` symbols preserve **each handler's exact C++ parameter type** and its
**registration index** (`'lambdaN'`). Because msgpack-RPC dispatches by an integer/string
method key in registration order, these indices are very likely the on-wire **method ids**.
Demangled and tabulated by `NI/extracted/` (`odr_rpc_table.md`,
`rpc_handlers_demangled.txt`). Every handler also takes a leading `client_name`
(`strong::type<symbol, client_odr_client_name_tag>`) for instance routing — omitted below.

**Direction note:** `concrete_device_command_parser` runs *on the device* → its handlers are
**host → device** commands (the host drives the display). `concrete_host_command_parser`
runs *in NI's host software* → its handlers are **device → host** events (surface input).

### Host → device (48 commands — drive the display)

| # | payload | meaning |
| --- | --- | --- |
| 1 | `handshake` | session open → replies `handshake_reply` |
| 4 | `global_notification` | device-wide notification/toast |
| 5 | `client_notification` | per-instance notification (`show_client_notification`) |
| **6** | **`asset_id, bytes, bytes`** | **asset upload** — id + two byte blobs (image data / metadata). The custom-graphics path. |
| 7 | `asset_id` | asset remove/evict by id |
| 9 | `settings::settings_model_data` | device settings model |
| 11 | `system::system_command` | system control |
| 14 | `instance_info` | plugin/instance identity (`set_plugin_identifier`) |
| 16 | `symbol` | focus/selection by symbol |
| 17 | `host_owned_instance_client_state_data` | instance client state (host-owned) |
| 18 | `variant<device_owned_lightguide, small_vector<pair<midi_note_nr, rgb>>>` | **light-guide model** (`lightguide_set_model`) |
| 19 | `mixer_model_track_data` | mixer track (`mixer_model_set`) |
| 20 | `vector<array<float,2>>` | **mixer meters** — stereo L/R pairs (`mixer_model_meters`) |
| 21 | `mixer_track_data_property, object` | mixer property delta (`mixer_model_update_track_property`) |
| 22 | `int, track_info_property, object` | track-info property delta |
| 23 | `parameter_page_viewmodel_data<asset_id>` | **parameter page model** (`parameter_page_set_model`) |
| 24 | `parameter_page_plugin_data<asset_id>` | parameter-page plugin data |
| 25 / 26 | `parameter_page_{device,host}_owned_viewstate` | viewstate (device/host owned split) |
| 27 | `parameter_page_plugin_data_property, object` | parameter-page property delta |
| 28 | `parameter_id, variant<continuous, toggle, discrete, continuous_bipolar, discrete_bipolar>` | **single parameter value update** |
| 29 | `browser_data<asset_id>` | browser content (`browser_set_data`) |
| 30 | `browser_filters<asset_id>` | filter columns (`browser_set_filters`) |
| 31 / 33 | `browser_filters_property, object` | filter property delta |
| 32 | `sound_results<asset_id>` | result list (`browser_set_sounds`) |
| 34 | `browser_settings` | browser settings |
| 35 | `int, sound_item<asset_id>` | single sound row (index + item) |
| 36–43 | `optional<int>`, `plugin_chain_model_data`, `int`, `project_tree`, `optional<track_orientation>`, `track_plugin_chain_model_data`, `optional<plugin_chain_element_id>`, `project_node_id` | plugin-chain + project-tree navigation models |
| 44 / 45 | `smartplay_engine_state` / `smartplay_device_owned_viewstate` | scale/arp engine (`smartplay_set_*`) |
| 46 | `accessibility_status` | a11y |
| 47 | `midi_template_transfer_event` | MIDI template transfer |
| 48 | `variant<actions::host::reserved_for_future_use>` | reserved |

### Device → host (16 events — surface input)

| # | payload | meaning |
| --- | --- | --- |
| 1 | `handshake_reply` | handshake response |
| 6 | `variant<pad_midi_event>` | pad MIDI event |
| **7** | **`variant<…56 action tags…>`** | **the entire input/control event set** (see below) |
| 8 | `device_owned_instance_client_state_data` | instance state (device-owned) |
| 9 | `system::system_command, string_view` | system command + arg |
| 10 | `system::crashdump` | crash reporting |
| 11 | `map<symbol, variant<none,bool,float,int,string>>` | bulk property map |
| 12 | `symbol, variant<none,bool,float,int,string>` | single property |
| 13 | `data_tracking_event` · 14 `bool` · 15 `accessibility_event` · 16 `midi_template_transfer_event` | telemetry / a11y / templates |

Host-event **#7** is the heart of surface input — one `std::variant` of ~56 tagged structs:
- **Browser:** `navigate_{brand,filetype,product,bank,subbank,type,subtype,character,sound}`
  (scroll events), `load`/`load_next_sound`/`load_previous_sound`, `quick_browse`,
  `toggle_{favorite,prehear,speak_preset,filter_favorite_presets,filter_user_presets}`,
  `reset_filters`.
- **Parameters:** `parameter_value_set`, `parameter_value_change`, `parameter_erp_touched`
  (the 8 endless-rotary touch), `parameter_page_view_address_change`.
- **Transport/DAW:** `set_tempo`, `tap_tempo`, `play`, `restart`, `stop`, `record`, `metro`,
  `loop`, `count_in`, `undo`, `redo`, `quantize`, `quantize_half`, `set_host_pad_mode`.
- **Mixer/track:** `select_track`, `navigate_track`, `navigate_track_depth`, `mute_track`,
  `solo_track`, `track_volume_change`, `track_pan_change`, `octave_change`,
  `select_host_plugin`, `toggle_plugin_container`, `toggle_node_collapsed`.
- **Plugin chain:** `plugin_chain_navigate`, `plugin_chain_entry_move`,
  `plugin_chain_entry_{bypass,remove}`, `master_volume_change`.
- **Smartplay:** `arp_engine_change`, `arp_engine_trigger`, `scale_engine_change`,
  `smartplay_device_owned_viewstate_changed`.

For CompleteControl this is gold: encoder turns, button gestures, transport, and browse all
arrive as these typed events — they map almost 1:1 onto the kit's `SurfaceInput`/gesture
layer.

### What's solid vs. still needs the bench

- **Solid (from symbols):** the full method set, each handler's *type composition*, the
  request/notify split, `client_name` instance routing, the asset-upload command (#6), and
  the complete input-event taxonomy (#7).
- **Needs disassembly or capture:** the **msgpack envelope** (standard msgpack-RPC is
  `[type, msgid, method, params]`; confirm whether `method` is the integer index above or a
  string, and whether NI uses notify (`[2, method, params]`) for model pushes) and the
  **field order/encoding inside each struct** (msgpack adaptors pack structs as arrays or
  maps — recoverable by disassembling the `msgpack::pack`/`convert` adaptors in `ni-roda`,
  or by one clean USB/TCP capture). These are the only remaining unknowns for a working
  Swift client.

## Next

Done so far (static analysis, no hardware): architecture mapped, RodaCore QML carved
(`NI/extracted/RodaCore-qml/`, 67 blobs), full RPC method tables recovered
(`NI/extracted/odr_rpc_table.md`).

Remaining, in order:

1. **Recover the msgpack envelope + struct field layout.** The one real unknown. Either
   disassemble the `msgpack::pack`/`msgpack::convert` adaptors for `handshake`,
   `parameter_page_viewmodel_data`, `lightguide` model and the asset-upload command in
   `ni-roda` (Ghidra/radare on the ARM binary), or capture one clean session. Start with
   `handshake` ⇄ `handshake_reply` (smallest, gates everything).
2. **Bench (needs S49 MK3 hardware):** enumerate USB interfaces, find the **ODR** bulk
   endpoints (vs MIDI/HID), attempt the `handshake`. Probe the **TCP/UDS** transports as a
   capture-free shortcut. Confirm ODR + MIDI coexist (kills the old "mutex" worry).
3. **Prototype a Swift `ODRClient`** (msgpack-RPC over the ODR bulk endpoint): handshake →
   push a `parameter_page_viewmodel_data` / light-guide model → read host-event #7 input.
   This becomes the MK3 transport behind `KontrolSurfaceKit`.

Artifacts in `NI/extracted/` (untracked, alongside the firmware image): `carve_qml.py`,
`RodaCore-qml/` (67 QML), `odr_rpc_table.md`, `rpc_handlers_demangled.txt`,
`m4-usb-strings.txt`. **Do not commit `NI/`** — it holds the 395 MB firmware payload; it is
in `.gitignore`.

## Appendix: the "custom firmware" option (run our own code on the A7)

The ODR protocol confines us to NI's QML widget vocabulary — a pixel-exact tracker pattern
grid is **not** expressible through it (only via per-frame asset uploads, §"What this
unlocks"). The alternative is to stop talking *to* the device and instead **run our own
code on the device**. The A7 runs ordinary Linux with a full GPU stack, so "custom
firmware" really means "our own Linux process drawing to the panel" — and the firmware
image says that is far more open than a typical locked appliance.

**Evidence it is largely unlocked (all from the image, no hardware):**

- **Boot is plain extlinux**, not a signed FIT. Active label `NativeOS-KOM`:
  `boot/extlinux/extlinux.conf` → `KERNEL /boot/uImage`, `FDT /boot/stm32mp157a-ni-kks-mk3.dtb`,
  `APPEND root=PARTUUID=… rootwait rw console=ttySTM0,115200`, `TIMEOUT 20` (= 2.0 s menu
  window). Root is mounted **`rw`**.
- **The console is fully pinned down (from the device tree).** `stm32mp157a-ni-kks-mk3.dtb`:
  `chosen/stdout-path = serial0:115200n8`, `serial0 → /soc/serial@40010000` = **UART4**.
  Its `pinctrl-0` (`uart4-0`) resolves to **TX = PG11 (AF6), RX = PB2 (AF8)**, i.e. the ST
  reference pinout. SoC is **STM32MP157A**. USART2/USART3 are also `okay` (internal wiring,
  not the console). So the physical recon target is concrete: **UART4, 115200 8N1, PG11/PB2**.
- **No rootfs integrity at all** (`boot/5.15/config-5.15.67`): `CONFIG_DM_VERITY`,
  `CONFIG_FS_VERITY`, `CONFIG_BLK_DEV_INTEGRITY` **not set**; `CONFIG_MODULE_SIG` **not set**
  (unsigned kernel modules load). `lockdown` LSM is built in but not enabled by any bootarg.
- **The rootfs is a plain ext4 partition** (`/dev/mmcblk0p5` `/ni`; root is a PARTUUID ext4),
  exactly the image we are reading now — editable offline.
- **But every login is locked — a serial *login* buys nothing.** `etc/shadow`: `root:*`
  (password disabled), and the only app user `ni-kompletekontrol` is `nologin` with `!`. No
  other human account. So the goal is **not** "find a login prompt"; it is **interrupt U-Boot
  and boot `init=/bin/sh`** → passwordless root (rootfs is `rw`, nothing verifies it).
- **NI themselves treat UART4 as the debug console.** A custom polkit rule
  (`etc/polkit-1/rules.d/com.native-instruments.serial-getty.rules`) lets the
  `ni-kompletekontrol` group start/stop/restart `serial-getty@ttySTM0` and `@ttyRPMSG0` at
  runtime. So the getty is **not always running**, but the **kernel/boot log on UART4 is
  unconditional** — ideal for read-only recon. `root` shell is `/bin/sh`.
- **No USB shortcut to a shell.** `securetty` does list `ttyGS0` (USB gadget serial), but no
  getty is auto-spawned on it and root is locked anyway; the CDC interface is data, not a
  login console. Getting a shell genuinely requires the **physical UART** (or the offline
  rootfs-reflash route, vector 2).
- **Recovery is a ROM-level safety net:** STM32MP15 BootROM always offers USB DFU recovery;
  there are `recovery`/`dfu` splashscreens and `NIDFUTool`/`bin2dfu`/`images2dfu` on board.
  A bad rootfs flash is recoverable via STM32CubeProgrammer **unless** secure-boot rejects
  unsigned recovery images.

**Three entry vectors (increasing invasiveness):**

1. **Serial console / U-Boot (cleanest).** Find the **UART4** pads (**TX = PG11, RX = PB2**,
   **115200 8N1**) near the STM32MP157, interrupt U-Boot and boot with `init=/bin/sh` (or edit
   bootargs) → **root shell, no password** (rootfs is `rw`, nothing verifies it). From there,
   install a systemd service that draws our UI. Recon-first, lowest brick risk. See the bench
   procedure below.
2. **Offline rootfs edit + reflash.** Modify this ext4 image (drop in our renderer binary +
   a `.service`, or replace `ni-roda`) and write it back to the eMMC root partition via the
   updater's flashing path / DFU. Nothing on-device checks the rootfs, so it should boot.
3. **Replace/coexist with `ni-roda`.** It is just a systemd unit (`ni-roda.service`). Our
   process uses the same stack it does — `libdrm`/`libgbm`/`libEGL`/`libGLESv2` are already
   in `/vendor/lib`; the panel is `/dev/dri` + `/dev/fb0`, 1280×480. We get **unlimited
   pixel control** — the tracker grid becomes a trivial draw, and we can still talk to the
   M4 (keybed/LEDs/MIDI) over `/dev/rpmsg-ni-sdb`.

**The two genuine unknowns, both bench-answerable:**

- **Is the STM32MP15 "closed" (secure-boot OTP fuses blown)?** Undeterminable from the
  image. If open → trivial. If closed, the ROM→TF-A→U-Boot chain is authenticated, but the
  **extlinux/uImage flow implies U-Boot does *not* verify the kernel/rootfs**, so a modified
  rootfs likely still boots even on a closed device. Replacing U-Boot/kernel would be
  blocked; editing rootfs probably not.
- **Physical access to the UART / eMMC.** Needs opening the unit and locating the **UART4**
  pads (**PG11 = TX, PB2 = RX**, GND; possibly a 3–4-pad group near the SoC) — and JTAG/eMMC
  if we go lower. The pinout is now known from the dtb; the **pad locations** on NI's PCB are
  the only unconfirmed part. Also unknown until the first boot log: the U-Boot `bootdelay`
  (it lives in a separate eMMC env partition, not in the rootfs image), i.e. whether/how
  autoboot can be interrupted.

**Verdict:** technically very plausible — this is "get root on a mostly-open embedded Linux
and run a GLES app," not "write bare-metal firmware." It would fully realise the pattern
display the ODR path cannot. **Costs:** it voids the warranty, risks a brick (mitigated by
ROM DFU recovery *if* the device is open), forfeits NI's host-integration entirely (we'd
re-implement DAW comms ourselves), and every firmware update from NI would overwrite our
changes. It is a fork of the device, not a remote-control client. Recommended only as a
deliberate second track — *and only after* a serial-console recon confirms the device is open.

### Bench procedure: serial recon → U-Boot → first shell

Target confirmed from the image: **UART4, 115200 8N1, TX = PG11, RX = PB2** on an
**STM32MP157A**. Goal of the first session is *read-only recon* — answer "is the device
open?" and "is U-Boot interruptible?" before anything irreversible.

**Gear:** a **3.3 V** USB-UART adapter (CP2102 / FTDI FT232 — *not* 5 V), jumper wires, and
ideally a logic analyzer or scope to locate pads. The MP157 IO is 3.3 V.

1. **Open the unit, locate the pads.** Look for a 3–4-pad group (TX/RX/GND, maybe 3V3) near
   the STM32MP157. GND = continuity to the USB shell/chassis. **TX (PG11)** idles at 3.3 V
   and bursts at power-on — confirm with a scope/analyzer; that pad is the device TX.
2. **Read-only first.** Wire **GND + device-TX → adapter-RX only** (leave adapter-TX and VCC
   disconnected). `screen /dev/tty.usbserial-* 115200` (or `minicom`/`picocom`). Power on,
   capture the full boot log.
3. **From the log, determine:**
   - **Open vs closed device** — TF-A/U-Boot print the secure/OTP state; watch for
     authentication / "secure boot" / BSEC closed messages.
   - **U-Boot interruptibility** — note the `bootdelay` and whether "Hit any key to stop
     autoboot" appears (the env value isn't in the rootfs image, so the log is the source).
4. **Get the shell.** Add **adapter-TX → device-RX (PB2)**. Reset, interrupt autoboot to the
   U-Boot prompt, then either:
   - `setenv bootargs "${bootargs} init=/bin/sh"; run bootcmd` (or `boot`), **or**
   - edit the extlinux append the same way — boot straight to a passwordless root `/bin/sh`.
5. **Confirm on-device facts (still non-destructive):** `cat /proc/cpuinfo`; check the BSEC/OTP
   closed bit under `/sys/bus/nvmem/devices/*` (or `/sys/.../stm32-romem`/`bsec`); `ls /dev/dri
   /dev/fb0`; `ss -lntup` to see whether `ni-roda`'s **TCP/UDS msgpack** transports are
   listening (the capture-free RE shortcut from §"Multiple transports").
6. **Only then** decide the persistence route: set a root password / drop `authorized_keys` +
   enable a getty (so future access needs no soldering), or proceed to the offline rootfs
   reflash (vector 2). Try drawing one rectangle to `/dev/dri` to prove the pixel path before
   committing to the custom-firmware track.

**Non-opening alternative (vector 2 recap):** because the rootfs is unsigned and `rw`, the
same shell access can be gained by editing the ext4 image offline (set a root password / add
a USB getty + `authorized_keys`) and reflashing via the updater's DFU path — no soldering, but
higher brick risk and contingent on the flash path accepting a modified image. Serial recon
(steps 1–3) is the prerequisite either way: it tells us whether a reflash is safe.

---

# Sibling generations: the pixel-vs-model spectrum (MK2, A-series)

For the record, situating the MK3 ODR findings against the other generations. The decisive
axis for *our* "remote control you don't have to look away from" goal is **who owns the
pixels**.

| Gen | Display | Protocol | Pixels owned by | Fit for custom UI |
| --- | --- | --- | --- | --- |
| **MK1** (S25/49/61/88, 2014) | 9× 16-segment LCD | character/glyph masks (HID report `0xe0`) | — (segments) | text only |
| **MK2** (S49/61/88, 2018) | 2× **480×272 colour** | **raw RGB565 framebuffer blit** (`0x84`, USB bulk) | **the host** | **best — free pixels, fully documented** |
| **A-series / M32** (2018) | 1× small **OLED** (used as ~2-line text) | NI HID family; small framebuffer, **no light guide** | host (small) | weak (no light guide) |
| **MK3** (S49/61/88, 2023) | 1× **1280×480 colour** | **semantic msgpack-RPC**, on-device Qt/QML | **the device** | pixels only via asset upload or device hack |

The counterintuitive takeaway: for *arbitrary* on-surface graphics the **MK2 is the easiest of
all four**, not the MK3. The MK3's "intelligence" is exactly what takes pixel ownership away.

## MK2 display protocol (pixel-based — confirmed from qKontrol source)

Authoritative reference: `GoaSkin/qKontrol`, `source/qkontrol.cpp` (`drawImage`).

- **Two screens, each 480×272 px**, **RGB565** (`QImage::Format_RGB16`, 16-bit LE halfwords).
- **Transport: USB bulk on interface 3 / endpoint 3.** VID `0x17cc`; PID per model
  (S61 MK2 = `0x1620`; S49/S88 adjacent, verify). USB **2.0 High Speed (480 Mbit/s)**.
- **Command `0x84` = blit a rectangle.** Header built by qKontrol, per screen:
  `84 00` · `<screen>` · `60 00 00 00 00` · `x`(u16) · `y`(u16) · `w`(u16) · `h`(u16) ·
  `02 00 00 00 00 00` · `<w*h/2>`(u16) · **`w*h` RGB565 halfwords** · trailer
  `02 00 00 00 03 00 00 00 40 00 00 00`. → **arbitrary partial updates** of any (x,y,w,h)
  region; qKontrol paints with QPainter (lines/images/text) then blits.
- **Ownership caveat (same as MK1):** NI background services must be stopped to claim the
  device — exactly the problem `ccd`'s privileged libusb daemon already solves. qKontrol also
  naively `open/claim/release`s the device *per frame*; a real driver keeps it claimed and uses
  async transfers, so CompleteControl's daemon is **better suited to high frame rates** than
  qKontrol's reference code.

**Cross-gen note:** the MK2 blit command is `0x84` — the *same* byte that appeared in the MK3
**HID** captures as "identified but not understood." Plausibly the MK3 keeps an MK2-style
`0x84` pixel path on its legacy HID interface while the rich UI moved to ODR/msgpack.
Unconfirmed, worth a probe if we ever bench an MK3.

## A-series / M32 (for completeness — weak fit)

- **A25/A49/A61** (and the mini **M32**): a **single small OLED**, used by NI as a ~2-line
  parameter/browser readout; 8 touch-sensitive knobs; same `0x17cc` HID family.
- **No per-key light guide** (the A-series omits it entirely), no S-series display array.
- **Verdict for us:** the cheapest entry, but the **missing light guide** guts the
  tracker-remote concept (live note/scale/chord feedback on the keys is a core CompleteControl
  feature). The single small OLED is a downgrade from even the MK1's 9-display layout for our
  purposes. Catalogue it, don't target it.

## Framebuffer latency / FPS budget (MK2) — the "is it smooth?" answer

RGB565 = 2 bytes/px. One 480×272 screen = **255 KB**/full frame; both = **510 KB**. On USB 2.0
**High Speed**, realistic single-endpoint bulk throughput is ~30–40 MB/s.

| Update | Bytes | Transfer @30 MB/s | Ceiling |
| --- | --- | --- | --- |
| Both screens, full frame | 510 KB | ~17 ms | ~59 fps |
| One screen, full frame | 255 KB | ~8.5 ms | ~117 fps |
| One row band (480×40) | 37.5 KB | ~1.3 ms | hundreds fps |

**Verdict:**
- **For the realistic tracker UI (scrolling rows, meters, partial repaints) smooth 60 fps is
  attainable.** You almost never repaint a whole screen per frame; the `0x84` partial blit is
  the right primitive, and CompleteControl's reconciler **already diffs and sends only what
  changed** (row-granular today; the same idea extends to dirty pixel rects). The kit's
  `SurfaceClock` already ticks at **60 Hz**, matching a typical small-TFT panel refresh.
- **Full-frame 60 fps on *both* screens is plausible on paper** (~17 ms ⇒ ~59 fps) **but not
  guaranteed.** Two unknowns gate it, both bench-answerable: (1) the **device's internal ingest
  rate** — the panel/SoC may accept pixels slower than HS line rate; the bus is *not* the only
  bottleneck; (2) **bus sharing** — large blits must interleave with MIDI/surface input without
  adding jitter (chunk big transfers; prefer partial updates).
- **The honest line:** bandwidth is not the limiter for partial updates; the *device ingest
  rate* is the one number we cannot get without hardware. Budget for 60 fps partial, measure
  before promising full-frame video. (Contrast MK3: there you don't control frame timing at all
  — the on-device QML animates from your model deltas, so "smoothness" is NI's, not ours.)
