# CompleteControl

CompleteControl is a Swift control-surface stack for Native Instruments Komplete
Kontrol S-Series MK2 keyboards. It provides a privileged libusb daemon, a
declarative pixel-display middleware, input decoding, LEDs and light guide
control, USB-MIDI delivery, and a hardware-free simulator.

This is an independent project and is not endorsed by Native Instruments.

## Supported Hardware

| Model | VID | PID | Keys |
| --- | --- | --- | ---: |
| Komplete Kontrol S49 MK2 | `0x17cc` | `0x1610` | 49 |
| Komplete Kontrol S61 MK2 | `0x17cc` | `0x1620` | 61 |
| Komplete Kontrol S88 MK2 | `0x17cc` | `0x1630` | 88 |

The supported surface includes:

- two 480x272 RGB565 displays;
- eight encoders plus touch, function/menu/transport buttons, and the 4-D encoder;
- RGB palette button and ribbon LEDs;
- palette light-guide LEDs;
- raw ribbon input and USB-MIDI keybed/performance input.

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
MK2 USB composite device
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
acts as an I/O hardware test: controls illuminate their corresponding lamps,
MIDI keys illuminate the light guide, and recent raw/event activity appears on
the displays. On orderly shutdown the daemon restores the keyboard's standalone
mapping-engine state and clears host-owned output.

See [Docs/daemon-usb-reactor.md](Docs/daemon-usb-reactor.md) before changing USB
scheduling or callback behavior.

## KontrolSurfaceKit2

Add the package products needed by an application:

```swift
.product(name: "KompleteKontrol", package: "CompleteControl"),
.product(name: "KontrolSurfaceKit2", package: "CompleteControl"),
```

`KontrolSurfaceKit2` provides:

- `MK2Surface2` scene reconciliation and daemon reconnect handling;
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
```

- `MK2SurfaceDemo` is the compact hardware feature demo.
- `MK2WidgetLabDemo` exercises the production Kit2 widgets and includes a REPL
  for palette LEDs and light-guide control.
- `KontrolSimulator` emulates the S61 MK2 panel and can start a user-level
  simulator daemon from its Daemon menu.
- `MK2USBSpy` inspects low-level descriptors and input traffic without the
  normal daemon.

To run Widget Lab against the simulator daemon:

```bash
make run-simulator
# Start the daemon from the simulator's Daemon menu.
make mk2-widget-lab-demo-sim
```

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
