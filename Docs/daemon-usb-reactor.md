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
- set pending output flags and enqueue the independent output drain

Do not write display, button LED, or light-guide reports directly from completion
callbacks. In particular, never make the callback wait for a synchronous output
transfer. Output writes belong on the independent display/state-report queues.
Their workers may run concurrently with the callback and event pump: libusb is
thread-safe and `SessionUseLock` deliberately grants shared access for transfers,
while close/reopen takes exclusive access.

## Scheduling discipline

When adding USB device communication:

- preserve a single clear owner for session lifetime, close/reopen, and poll-fd
  registration
- on reconnect, forget every previously tracked poll-fd registration before
  re-syncing rather than diffing against it: closing the old session's fds makes
  kqueue silently drop their registrations (BSD semantics), and the OS is very
  likely to hand the new libusb context the same fd numbers back (routine fd
  reuse). A diff against the stale set sees those recycled numbers as "no
  change" and skips `EV_ADD`, so the kqueue never gets re-armed even though the
  daemon still believes it's watching that fd — surface/MIDI input then goes
  silently dead after a real unplug/replug while displays, which write
  synchronously, keep working. `runReconnect` resets `trackedUsbRegistrations`
  to force an unconditional full re-add for exactly this reason
- do not depend on a future kqueue wake after a synchronous libusb transfer
- if code snapshots and clears pending flags before an output transfer, re-check
  pending state after the transfer path returns
- keep display blits and small state reports on separate serial queues; their
  timing requirements differ even when they share one libusb device handle
- enqueue the idle state-report drain directly when a callback changes an LED;
  a callback dispatched reentrantly inside a long display transfer may consume
  the only readiness edge, and waiting for that display to return adds its full
  transfer time to input feedback

## Regression cases

Exercise bursty input while output is active:

- play and release MIDI chords while the idle light guide and OLEDs are updating
- press/release surface controls while the idle display is writing frames
- connect a client during idle diagnostics and verify handoff does not leave stale
  LEDs or light-guide state
- physically power-cycle the device while the daemon is running and confirm
  surface/MIDI input resumes after reconnect, not just displays — a 2026-07-18
  regression on a MASCHINE MK3 bench unit showed a real replug reconnecting
  cleanly (open, claim, `async transfers started input=0`) while the reactor's
  kqueue silently never woke for the resubmitted transfer again, because the OS
  reused the old session's fd number and a plain diff against the previously
  tracked registrations skipped re-registering it

Useful command shape:

```bash
KK_DAEMON_DEBUG=1 KK_USB_DEBUG=1 LOGLEVEL=TRACE .build/debug/ccd --kk-libusb-daemon
```

Then inspect for `push midi`, `push surface`, `write report`, and `MK2 display frame`
ordering. Seeing a callback interleaved with an output write is valid; stale output
after that callback is not.

The MASCHINE MK3 NO CLIENT pad echo is the strongest regression workload because
one full screen takes roughly 40-50 ms on the bcdDevice `0x0146` bench unit. A
2026-07-17 pass paired 104 pad LED edges at 1 ms log resolution after splitting
the queues: median 0 ms and maximum 2 ms from input callback to state-report write
start, even while OLED writes were active.
