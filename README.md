# CompleteControl

CompleteControl is a Swift control-surface stack for Native Instruments Komplete
Kontrol S-Series MK2 keyboards and MASCHINE MK3. It provides a privileged libusb
daemon, declarative pixel-display middleware, input decoding, LED control,
USB-MIDI delivery for S-Series, and a hardware-free simulator.

This is an independent project and is not endorsed by Native Instruments.

## Supported Hardware

| Model | VID | PID | Controls | Status |
| --- | --- | --- | --- | --- |
| Komplete Kontrol S49 MK2 | `0x17cc` | `0x1610` | 49 keys | Production |
| Komplete Kontrol S61 MK2 | `0x17cc` | `0x1620` | 61 keys | Production |
| Komplete Kontrol S88 MK2 | `0x17cc` | `0x1630` | 88 keys | Production |
| MASCHINE MK3 | `0x17cc` | `0x1600` | 16 pads | Shared Kit2 controls verified |

The S-Series MK2 surface includes:

- two 480x272 RGB565 displays;
- eight encoders plus touch, function/menu/transport buttons, and the 4-D encoder;
- RGB palette button and ribbon LEDs;
- palette light-guide LEDs;
- raw ribbon input and USB-MIDI keybed/performance input.

The MASCHINE MK3 path safely claims only HID interface 4 and display interface
5, leaving its audio, MIDI, and DFU functions untouched. It provides both
displays, semantic input decoding, native LED output, and a Kit2 compatibility
adapter so existing scenes can use shared buttons, eight encoders, the main 4-D
encoder, and the touch strip without source changes. The Widget Lab hardware
pass verified those shared inputs plus visible SCENE and VARIATION lamps on
device revision `0x0146`. The complete pad matrix and pad LED ordering are also
bench-verified; HID-to-MIDI pad delivery is a later milestone.

The maintained protocol reference is
[Docs/Komplete-Kontrol-Protocol-Guide.md](Docs/Komplete-Kontrol-Protocol-Guide.md).

## Requirements

- macOS 26 or newer;
- Swift 6.2 or newer;
- Homebrew `freetype` and `harfbuzz`;
- administrator access to install or run the hardware daemon;
- the pinned `Vendor/libusb` submodule.

Initialize and build:

```bash
git submodule update --init --recursive Vendor/libusb
brew install freetype harfbuzz
swift build
swift test
```

## Architecture

```text
Supported NI USB composite device
        |
        v
KontrolUSB + vendored libusb
        |
        v
ccd privileged daemon
  | control socket
  | event socket
  | display socket
        |
        v
KompleteKontrol / KontrolSurfaceKit2
        |
        v
Applications such as Paulinche
```

`ccd` owns the composite USB device and keeps one persistent session open.
Surface and MIDI input are asynchronous libusb transfers integrated with the
daemon's kqueue reactor. Display blits and small state reports use separate
serial queues so display work does not serialize every LED or light-guide write.

Clients normally use `KontrolSurfaceKit2`. Direct protocol APIs in
`KompleteKontrol` remain available for hardware diagnostics and protocol work.

## Daemon

Build and install the release daemon:

```bash
make install-daemon
make daemon-status
```

The default `adaptive` display writer compresses each physical transfer with
hardware-verified literal, repeat-pair, and skip commands.

Use the byte-for-byte original writer as a fail-safe without rolling back code:

```bash
make install-daemon MK2_DISPLAY_ENCODING=legacy
```

An unset value selects `adaptive`; unknown explicit values fail safely to
`legacy`. The installed mode is stored in the LaunchDaemon environment and takes
effect after the installer restarts it.

Run an instrumented foreground daemon:

```bash
make daemon-debug
```

Uninstall:

```bash
make uninstall-daemon
```

The hardware socket defaults to:

```text
/var/run/kompletekontrol-libusb.sock
```

Set `KK_DAEMON_SOCKET` to connect clients to another endpoint.

When no client is connected, the daemon displays its NO CLIENT diagnostic and
acts as an I/O hardware test. On S-Series MK2, controls illuminate their lamps
and MIDI keys illuminate the light guide. On MASCHINE MK3, decoded surface and
pad events appear on the displays while mapped buttons, pads, and ribbon input
illuminate their corresponding LEDs.
On orderly shutdown the daemon restores the MK2 keyboard's standalone mapping
engine or clears MK3-owned lights, then clears both displays.

See [Docs/daemon-usb-reactor.md](Docs/daemon-usb-reactor.md) before changing USB
scheduling or callback behavior.

### Test-Automation Input Injection

Set `CCD_ENABLE_AUTOMATION=1` when starting the daemon to open a fourth, opt-in socket
(`<socket-path>.automation`, `chmod 0600`) that accepts a plain-text line REPL for synthesizing
button presses, encoder turns, MIDI notes, and ribbon/strip input. Injected input reaches every
connected client (Paulinche, the widget lab, demos) exactly as real or simulated hardware input
would — see `MK2InputFrameLowering` and `DaemonHardware.handleAutomation`. Unset (the default),
the socket does not exist at all.

```bash
CCD_ENABLE_AUTOMATION=1 ccd --kk-libusb-daemon /tmp/kk-test.sock
KK_DAEMON_SOCKET=/tmp/kk-test.sock make kk-input
Scripts/kk-input.py --socket /tmp/kk-test.sock.automation button play down
Scripts/kk-input.py --socket /tmp/kk-test.sock.automation --script scenario.txt
```

With no command, `kk-input.py` opens a readline-based REPL with contextual Tab completion,
persistent command history, reconnect/status helpers, and clean Ctrl-C/Ctrl-D handling. The
default `make kk-input` target auto-discovers `KK_DAEMON_SOCKET`, then the hardware and simulator
daemon sockets. History is stored under `XDG_STATE_HOME` (normally
`~/.local/state/kk-input/history`); use `--no-history` or `--history-file` to override it.

Commands: `button <name> down|up`, `encoder <1-8> <delta>`, `encodertouch <1-8> on|off`,
`fourdwheel <delta>`, `fourd left|up|down|right|click|touch|release`,
`note <midiNote> <velocity> on|off`, `midi <statusHex> <data1> <data2>`,
`strip <position 0-1024|release> [timeMs]`, `help`.

## KontrolSurfaceKit2

Add the package products needed by an application:

```swift
.product(name: "KompleteKontrol", package: "CompleteControl"),
.product(name: "KontrolSurfaceKit2", package: "CompleteControl"),
```

`KontrolSurfaceKit2` provides:

- `MK2Surface2` scene reconciliation, daemon reconnect handling, and automatic
  MK2/MASCHINE MK3 adapter selection through `deviceInfo`/`deviceProfile`;
- `MK2ScreenDSL` regular, full-screen, and double-screen layouts;
- parameter pages, value cells, meters, status lines, selection and modal widgets;
- FreeType/HarfBuzz text plus fixed-pitch tracker rendering;
- lamps, light-guide colors, and semantic input bindings;
- display diffing and binary display transport.

New reusable Kit2 APIs should be demonstrated in `MK2WidgetLabDemo` and covered
by focused or snapshot tests.

## Tools

```bash
make mk2-surface-demo
make mk2-widget-lab-demo
make run-simulator
make mk2-usb-spy
make mk2-usb-spy-display-repl
make display-codec-benchmark
```

- `MK2SurfaceDemo` is the compact hardware feature demo.
- `MK2WidgetLabDemo` exercises the production Kit2 widgets and includes a REPL
  for palette LEDs and light-guide control.
- `KontrolSimulator` emulates the S61 MK2 panel and can start a user-level
  simulator daemon from its Daemon menu.
- `MK2USBSpy` inspects low-level descriptors and input traffic without the
  normal daemon. Its display REPL claims only USB interface 3 and sends no
  display data until an explicit command is entered. The Make target stops the
  daemon first; start it again after the session when needed.
- `display-codec-benchmark` runs a deterministic headless replay in release
  configuration and reports encoded bytes, estimated USB wire-time savings, and
  host encoder time. Hardware remains the authority for end-to-end latency.

For an end-to-end hardware comparison, install each mode and run the optimized
Widget Lab build:

```bash
make install-daemon MK2_DISPLAY_ENCODING=legacy
make mk2-widget-lab-demo-release

# In the REPL:
open display-benchmark
displaybench 12
```

Repeat with the default adaptive installation (`make install-daemon`). The same
benchmark is available from the hardware UI under **Diagnostics → Display
Benchmark**; PLAY or 4-D press starts it. It measures seven deterministic workloads
(cursor, rotary value, meter, large gap, large contiguous bitmap, full solid, and
full noisy) and prints machine-readable `BENCH display …` lines in addition to the
OLED result table. Measurement counters exist only for the duration of a run and
are disabled again on completion or cancel.

To run Widget Lab against the simulator daemon:

```bash
make run-simulator
# Start the daemon from the simulator's Daemon menu.
make mk2-widget-lab-demo-sim
```

## Acknowledgements

The adaptive display writer was inspired in part by the openAV-Ctlra community's
[Maschine MK3 display work](https://github.com/openAVproductions/openAV-Ctlra/pull/115),
which helped direct our S-Series MK2 hardware experiments toward the display
command family's repeat-pair and skip operations.

## Development

Primary verification:

```bash
swift build
swift test
swift build -c release --product ccd
```

Protocol changes belong in the canonical protocol guide, not only in handover
notes. Architecture experiments and deferred work belong in
[Docs/Backlog.md](Docs/Backlog.md).
