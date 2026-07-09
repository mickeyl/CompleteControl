# Daemon USB Reactor Notes

This note exists because the daemon has two overlapping execution models:

- the kqueue reactor watches libusb poll fds and calls `handleUsbEvents(timeoutMs: 0)`
- synchronous libusb output calls can also dispatch async input callbacks before they return

Future USB hardware work must account for both.

## Reentrancy rule

Do not assume libusb callbacks only run between the daemon log lines
`handle_events begin` and `handle_events end`.

`libusb_interrupt_transfer`, `libusb_bulk_transfer`, and `libusb_control_transfer`
are synchronous from the caller's point of view, but libusb can still handle pending
events internally while those calls are in flight. If an async MIDI or surface
transfer completes there, the callback can reenter Swift through
`pushMidiToClients` or `pushInputToClients` while the daemon is doing an output
write.

That has two important consequences:

- a callback can mark pending idle state after `flushIdleDiagnosticIfNeeded()` has
  already copied and cleared the previous pending flags
- the synchronous output call can consume the readiness that kqueue would otherwise
  have reported, so no later reactor edge is guaranteed

The fix pattern is to drain state again after output writes that may have allowed
callbacks to run. `flushIdleDiagnosticIfNeeded()` therefore loops while there is an
actually due display, light-guide, or button-LED write. It exits without spinning
when a display update is still pending but rate limited.

## Callback discipline

Keep libusb callback paths small:

- parse/copy the input bytes
- update daemon state
- enqueue or push client messages
- set pending output flags

Do not write display, button LED, or light-guide reports directly from completion
callbacks. Output writes belong in the reactor-adjacent drain paths, after the
callback has returned.

## Scheduling discipline

When adding USB device communication:

- preserve a single clear owner for session lifetime, close/reopen, and poll-fd
  registration
- do not depend on a future kqueue wake after a synchronous libusb transfer
- if code snapshots and clears pending flags before an output transfer, re-check
  pending state after the transfer path returns
- keep display blits and small state reports separate where possible; their timing
  requirements differ even when they share one libusb device handle

## Regression cases

Exercise bursty input while output is active:

- play and release MIDI chords while the idle light guide and OLEDs are updating
- press/release surface controls while the idle display is writing frames
- connect a client during idle diagnostics and verify handoff does not leave stale
  LEDs or light-guide state

Useful command shape:

```bash
KK_DAEMON_DEBUG=1 KK_USB_DEBUG=1 LOGLEVEL=TRACE .build/debug/ccd --kk-libusb-daemon
```

Then inspect for `push midi`, `push surface`, `write report`, and `MK2 display frame`
ordering. Seeing a callback interleaved with an output write is valid; stale output
after that callback is not.
