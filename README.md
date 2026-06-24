# KompleteKontrol-Swift

A Swift library for controlling Native Instruments Komplete Kontrol S25 MK1 hardware.

## Features

- **Low-latency USB communication** via libusb with optimized timeouts
- **HID fallback** using IOKit for direct kernel access
- **Privileged daemon** for non-root USB access via Unix domain socket
- **Full surface control**: LED guides, button LEDs, and 9-segment displays
- **Input monitoring**: Buttons, encoders, touch strips, and MIDI events
- **S25 MK1 protocol** implementation with RGB color support

## Installation

### Requirements

- macOS 15.0+
- libusb-1.0 (install via `brew install libusb`)
- Swift 6.0+

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(path: "../KompleteKontrol-Swift")
]
```

Or use a local path dependency.

## Usage

### Basic Setup

```swift
import KompleteKontrol

let device = KompleteKontrolS25MK1()
device.onInputReport = { report in
    print("Input: \(report.events)")
}
try device.open()
device.startInputMonitoring()
device.handshakeAsync()
```

### LED Control

```swift
// Set key colors
device.setKey(0, color: KKRGB(red: 0x7f, green: 0x00, blue: 0x00))
device.sendGuideAsync()

// Set button LEDs
device.setButtonLED(name: "play", value: 0x7f)
device.sendButtonLEDsAsync()
```

### Display Control

```swift
device.setDisplayText("HELLO", display: 0, row: 1, alignment: .center)
device.setDisplayBar(0.5, display: 1, row: 0)
device.sendDisplaysAsync()
```

### Output Modes

```swift
// Direct libUSB (requires root or device access entitlements)
let device = KompleteKontrolS25MK1(outputMode: .directLibUSB)

// Privileged helper daemon (recommended for non-root)
let device = KompleteKontrolS25MK1(outputMode: .privilegedHelper())
```

## Daemon Mode

For non-root access, the library uses a privileged daemon.

**One-Time Setup (Recommended):**

Run the installer script once to set up the daemon as a launchd service:

```bash
cd KompleteKontrol-Swift
sudo ./install-daemon.sh
```

This installs the daemon as a system service that can start/stop without password prompts. The daemon will automatically start on boot and when requested by applications.

**Manual Start (Fallback):**

If the launchd service is not installed, the library will fall back to the osascript method:

```bash
# Start daemon (requires admin password each time)
sudo KontrolProbe --kk-libusb-daemon /var/run/kompletekontrol-libusb.sock
```

**Controlling the Daemon:**

```bash
# Start
sudo launchctl load /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist

# Stop
sudo launchctl unload /Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist

# Restart
sudo launchctl kickstart -k system/media.vanille.kompletekontrol-libusb

# Check status
sudo launchctl list | grep kompletekontrol
```

## KontrolProbe Tool

The included `KontrolProbe` tool provides testing and diagnostics:

```bash
# Run daemon in foreground
swift run KontrolProbe --kk-libusb-daemon

# Run as daemon client
swift run KontrolProbe --daemon-client

# Test UI with photo overlay
swift run KontrolProbe --test-ui
```

## Architecture

- **KompleteKontrol.swift**: High-level Swift API with output queueing
- **KontrolUSB.c**: Low-level USB I/O via IOKit and libusb
- **Daemon**: Unix domain socket server for privileged USB access

## Latency Optimizations

This library includes several latency improvements over the original implementation:

- USB timeouts reduced from 1000ms to 50ms
- Surface refresh batching reduced from 120ms to 5ms
- Daemon polling timeouts optimized (50ms surface, 20ms MIDI)
- Async output queue with worker thread

## License

See LICENSE file in parent project.

## Protocol

Implements the Native Instruments Komplete Kontrol S25 MK1 HID protocol:
- Vendor ID: 0x17cc
- Product ID: 0x1340
- Interface: 2 (HID)
