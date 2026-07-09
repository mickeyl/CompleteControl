# MIDI Note-Off Bug Investigation

## Hardware

Komplete Kontrol S61 MK2, foreground `.build/debug/ccd` with:

```bash
KK_DAEMON_DEBUG=1 KK_USB_DEBUG=1 LOGLEVEL=TRACE
```

## Symptom

While the daemon owns the idle surface, chord and legato note-off events could
appear delayed. The visible symptom was the MK2 light guide: after releasing a
chord, one or more keys stayed lit until another key event happened.

The light guide was not the root cause. It was the easiest way to see that idle
MIDI state had been updated but not flushed to hardware.

## Root Cause 1 - Fixed: USB MIDI bulk buffer too small

File: `Sources/KontrolUSB/KontrolUSB.c`

The async MIDI transfer used `midiBuffer[256]` on a bulk endpoint whose
`wMaxPacketSize` is 512 bytes (`midi ep0x81 attr0x02 max512 interval0`).

USB bulk transfers complete when the buffer fills or a short packet arrives. With
a 256-byte buffer on a 512-byte max-packet endpoint, libusb could keep the
transfer open until more data accumulated. That made several MIDI events,
including note-offs seconds apart, arrive together in one callback.

Fix: `midiBuffer` is now 512 bytes.

After this change, the chord test log showed each MIDI event arriving as its own
4-byte callback with correct timing.

## Root Cause 2 - Fixed: synchronous output writes can run callbacks reentrantly

File: `Sources/KompleteKontrol/KompleteKontrol.swift`

After the buffer fix, MIDI callbacks arrived promptly, but the idle light-guide
state could still remain stale. The important ordering was:

1. A note-off callback marks the light guide dirty.
2. `flushIdleDiagnosticIfNeeded()` copies the pending state and clears the dirty
   flags.
3. The flush path writes light-guide and/or display reports with synchronous
   libusb calls.
4. While one of those synchronous writes is in flight, libusb dispatches another
   async MIDI callback reentrantly.
5. That callback updates idle state and marks the light guide dirty again.
6. The original flush returns, but no later kqueue edge is guaranteed because the
   synchronous write may already have consumed the libusb readiness.

The pending note-off was not stuck in Swift's MIDI parser or in the light-guide
mapping. It was pending idle output state that could sleep until the next input
event woke the reactor.

Fix: `flushIdleDiagnosticIfNeeded()` now loops after output writes and drains any
newly marked pending idle state before the reactor sleeps again. The loop only
continues when a display, light-guide, or button-LED write is actually due, so a
rate-limited display update cannot spin the reactor.

The general rule is documented in `Docs/daemon-usb-reactor.md`.

## Relevant Code

| File | Notes |
|------|-------|
| `Sources/KontrolUSB/KontrolUSB.c` | `midiBuffer[512]` matches the MIDI endpoint max packet size |
| `Sources/KontrolUSB/KontrolUSB.c` | `libusb_interrupt_transfer`, `libusb_bulk_transfer`, and `libusb_control_transfer` are synchronous output paths that can allow callbacks to run |
| `Sources/KompleteKontrol/KompleteKontrol.swift` | `acknowledgeIdleMIDIInput` updates idle MIDI/light-guide state and sets pending flush flags |
| `Sources/KompleteKontrol/KompleteKontrol.swift` | `updateIdleMK2LightGuide` maps note numbers to MK2 light-guide indices |
| `Sources/KompleteKontrol/KompleteKontrol.swift` | `flushIdleDiagnosticIfNeeded` drains pending idle output and re-checks after synchronous writes |
| `Sources/KompleteKontrol/KompleteKontrolMK2.swift` | `lightGuideReportID = 0x81`, `lightGuideKeyMapSize = 249`, and model-specific note offsets |

## Regression Checklist

- Build `ccd`.
- Run the daemon with trace logging.
- With no client connected, press and release a C major chord on the MK2.
- Confirm each note-off logs as `push midi` promptly.
- Confirm the MK2 light guide clears without waiting for another key.
- Repeat while the idle OLEDs are updating, because that is the path that exposed
  the reentrant callback ordering.
