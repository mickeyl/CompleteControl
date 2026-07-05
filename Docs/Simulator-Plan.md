# CCD Simulation Mode — Implementation Plan

Status: **implemented 2026-07-03** (all phases A–E). This doc is now the design record;
day-to-day usage lives in `CLAUDE.md` → "Simulation mode".

Goal: run the daemon (`ccd`) without real hardware by rendering to, and taking input
from, a separate macOS GUI app that mimics the S61 MK2 panel. **The mode must be 100%
transparent to socket clients** — a client (`MK2WidgetLabDemo`, `MK2FreeTypeDemo`, Paulinche) connects to the
daemon exactly as before and cannot tell hardware from simulator.

## Why it can be transparent

`DaemonHardware` (in `KompleteKontrol.swift`) is the *only* code that touches the USB
device: all 9 libusb entry points are called from its methods. Everything above it — the
kqueue reactor, socket server, input/MIDI **decoding happens client-side** (the daemon
ships raw report hex via `pushInputToClients`/`pushMidiToClients`), reconnect state
machine — talks only to `DaemonHardware`'s Swift methods. So we insert a backend seam
*inside* `DaemonHardware` and leave everything else byte-for-byte identical.

Because clients decode the **raw** `0x01` HID report and raw USB-MIDI themselves, the
simulator path must synthesize **byte-identical raw reports**. That is the linchpin — and
it is verifiable without hardware by round-tripping the builder through the real decoder.

## Decisions

- **Hosting:** separate `KontrolSimulator.app`. `ccd` stays headless. The sim app is the
  "virtual device": it listens on a local socket; `ccd` (in sim mode) connects as a
  client. The sim socket fd rides the existing kqueue reactor exactly where libusb
  pollfds do. Closing the sim window = EOF = device-loss = exercises reconnect.
- **V1 fidelity:** two 480×272 displays (real blits), 8 function buttons, 8 rotary
  encoders (rotate + touch), the side buttons left/right of each display, the 4-D encoder
  (rotate + 8-way + click) — all clickable. Button LED feedback is rendered from report
  `0x80`: panel-button RGB only for Mute, Solo, and F1-F8; the remaining button indicators are
  fixed-colour monochrome LEDs whose brightness controls the text on a black cap
  (Play green, Record red, the rest white). Deferred to V2: light-guide keybed + MIDI
  notes, touch strip/ribbon, transport LED row.

## The seam: `KontrolDeviceSession`

A class-bound protocol (identity via `===` replaces the current `libusbSession ==
session` checks). `DaemonHardware.libusbSession: KontrolUSBLibUSBSessionRef?` becomes
`session: (any KontrolDeviceSession)?`.

```swift
protocol KontrolDeviceSession: AnyObject {
    var productID: UInt16 { get }
    var keyCount: UInt8 { get }
    var generation: UInt8 { get }
    var isDeviceLost: Bool { get }

    func write(reportID: UInt8, payload: [UInt8]) -> KontrolUSBResult
    func writeMK2DisplayBytes(screen: UInt8, x: UInt16, y: UInt16,
                              width: UInt16, height: UInt16,
                              pixels: [UInt8], timeoutMs: UInt32) -> KontrolUSBResult
    func fillMK2Display(screen: UInt8, x: UInt16, y: UInt16,
                        width: UInt16, height: UInt16,
                        rgb565: UInt16, timeoutMs: UInt32) -> KontrolUSBResult

    func startAsyncInput(_ sink: @escaping (UnsafePointer<UInt8>, UInt32) -> Void) -> Bool
    func startAsyncMIDI(_ sink: @escaping (UnsafePointer<UInt8>, UInt32) -> Void) -> Bool
    func stopAsync()

    func pollFds() -> [KontrolUSBPollFd]
    func handleEvents(timeoutMs: Int)
    func close()
}
```

Two conformers:

1. **`LibUSBDeviceSession`** — wraps `KontrolUSBLibUSBSessionRef`; each method is the
   matching C call. `startAsyncInput` bridges the Swift sink to the existing
   `@convention(c)` trampoline via a boxed-closure userData. No behavioural change.
2. **`SimulatorDeviceSession`** — a socket to the sim app. `pollFds()` returns the sim
   socket fd (reactor watches it). `handleEvents` reads pending sim messages and calls the
   input/MIDI sinks with **synthesized raw reports**. `write*`/`writeMK2DisplayBytes`
   serialize to output frames. `isDeviceLost` = socket EOF. `productID` = advertised MK2.

Mode chosen in `ensureSession()` from an env var / launch flag (`CCD_SIMULATE=<path>`),
constructing the right session type.

## Device-side wire protocol (ccd ↔ sim app)

Length-prefixed binary frames: `[u8 type][u32be len][payload]`. Shared codec + control
enums live in `KompleteKontrol`; the sim app depends on `KompleteKontrol` so there is
exactly one codec and one button-id enum.

- ccd→sim: `HELLO_ACK`, `DISPLAY_BLIT{screen,x,y,w,h,rgb565be…}`, `REPORT{id,bytes}`.
- sim→ccd: `HELLO{productID,keyCount}`, `BUTTON{id,down}`, `ENCODER{index,delta}`,
  `ENCODER_TOUCH{index,touched}`, `FOURD{kind,value}`. (`NOTE` reserved for V2.)

The sim app is **dumb**: it emits semantic events. `SimulatorDeviceSession` on the ccd
side keeps a virtual surface state and builds the raw `0x01` report via
`MK2InputReportBuilder`.

## `MK2InputReportBuilder` — the transparency linchpin

Maintains virtual button bitfield + per-encoder absolute positions + 4-D state, and emits
the exact `0x01` report bytes the firmware would. Mirrors the layout the client decoder
reads. Verified by a **round-trip test**: build(event) → decode → assert the decoded
`SurfaceInput` matches the event, for every control. This guarantees transparency at the
byte level with no hardware.

## Phasing (each phase builds + `swift test` green)

- **A. Seam refactor, real backend only.** Introduce the protocol + `LibUSBDeviceSession`;
  route all `DaemonHardware` C calls through it. Pure refactor, no sim. Verify the live
  idle daemon still shows `NO CLIENT` and reacts to input.
- **B. Report builder + wire codec.** `MK2InputReportBuilder` (+ round-trip tests) and the
  frame codec (+ round-trip tests). Pure, no integration.
- **C. `SimulatorDeviceSession` + mode selection.** Implements the protocol over the
  socket. Headless test: a stub sim socket confirms ccd forwards blits and injects input.
- **D. `KontrolSimulator.app`.** AppKit panel: displays, function buttons, encoders, side
  buttons, 4-D, hardware-accurate panel-button RGB LEDs and fixed-colour monochrome button
  text, all clickable. Manual verification (sim app + ccd + client).
- **E. Make targets + docs.** `make run-simulator`, sim-mode ccd run target, CLAUDE.md.

## Verification without hardware

1. `MK2InputReportBuilder` round-trip vs. the real decoder (per control).
2. Wire codec encode/decode round-trip.
3. Headless sim-stub integration: ccd(sim) ↔ stub socket ↔ client registers + receives a
   blit; injecting a stub BUTTON event surfaces the right raw report to the client.
4. Manual: launch the app, click controls, watch a client react. `MK2FreeTypeDemo` is a
   useful display-only client for checking scalable text without touching tracker state.
