# Transport Latency: Action Plan

**Date:** 2026-07-09
**Status:** Decided

**Update 2026-09-06:** AP2 is closed by hardware measurement, without being
implemented — see the result block in AP2. The remaining measures are
unchanged.

This document contains exclusively the planned latency measures and the
deliberately rejected alternatives. The current architecture fundamentally
stays: asynchronous libusb IN transfers, kqueue for USB and socket
readiness, three separate Unix sockets, and independent display and state
report queues.

## Order

1. Implement tick-on-present and measure on hardware.
2. Capture the dirty-row distribution in a real Paulinche session.
3. Implement multi-rect blits only once runtime relevance is confirmed.
4. Remove the hex round trip in passing on the next intervention in the
   push path.

## AP1: Tick-on-Present

### Goal

`MK2Surface2.present(_:)` today only replaces the scene. Output then waits
for the next 60 Hz timer tick. Paulinche thereby loses 0–16.7 ms
structurally, on average about 8.3 ms. A new scene should be reconciled
immediately after idle, without producing a tick queue under rapid updates.

### Implementation

- `present(_:)` calls an actor-isolated `requestPresentTick()` after
  setting `scene`.
- The first tick after at least 8 ms of idle runs immediately on the
  surface actor.
- Further presents within that 8 ms window are coalesced into exactly one
  trailing tick. That caps present ticks at 125 Hz and still guarantees
  that the last state of a burst is emitted.
- The trailing task is stored, cancelled in `stop()`, and re-checks
  `running` before ticking.
- `lastTick` stays the shared time base for timer and present ticks.
- The existing timer stays active for lamp animations, heartbeat,
  reconnect, and as a safety net.
- The existing `TickGate` stays on the timer path. A present tick needs no
  additional task hop, because `present(_:)` already runs on the actor.

The trigger explicitly belongs in `present(_:)`, not at the end of input
processing: a binding mutates the app model and only presents the new scene
in a later actor job. A tick directly after input would still emit the old
scene.

### Tests and acceptance

- Unit test: the first present after idle ticks immediately.
- Unit test: several presents within 8 ms produce at most one trailing tick
  and emit the last state.
- Unit test: `stop()` prevents an already armed trailing tick.
- The existing timer, reconnect, and display reconciler tests stay green.
- Hardware: on a single encoder detent, the corresponding
  `display worker` starts within roughly 5 ms after `push surface` in the
  idle case.
- Hardware: fast encoder spin stays at most 125 present ticks/s, produces
  no actor backlog, and ends on the correct value.

## AP2: Dirty-Row Measurement and Atomic Multi-Rect Blits

**Result (2026-09-06): closed without implementation.** This project's
premise — raw band bytes over USB — was removed on 2026-07-15, when adaptive
encoding became the default; the Protocol Guide has since documented that
chained skip/literal/repeat segments reach the goal in one transfer,
without AP2's per-rect fixed costs (16-byte header + 12-byte trailer + one
`libusb_bulk_transfer` each). The 2026-09-06 Widget Lab benchmark confirms
it with numbers: the gap fixture (190,080 logical bytes, two widely
separated strips) goes over the wire as **368 transport bytes in 0.742 ms
USB median** — the USB time avoidable by gap splitting has gone towards
zero, and the phase-1 gate condition below ("implementation only continues
if … the avoidable USB time from them is relevant") is thereby decided
negatively. Incompressible bands — the only case with real millisecond
time — have no clean gaps to split. What would have remained are socket
bytes and daemon scan shares under 1 ms per update. The only remaining
measurable display-path lever is segment coalescing in the adaptive encoder
(see Backlog): fragmented meter-like literal runs pay ~620 ns/byte against
~96 ns/byte for contiguous content.

### Goal

`PixelDisplayReconciler2` today sends one full-width band per screen,
spanning the first through the last changed row. Widely separated small
changes therefore also transport all clean rows in between. The current
Paulinche renderer can produce such shapes; for example, a cursor movement
was observed with 44 changed rows inside a 194-row band with a 140-row gap.

### Phase 1: Measure production data

Before the protocol change, a debug build logs per emitted blit:

- screen and band height,
- number of actually changed rows,
- largest clean gap in the band,
- resulting payload size.

Measured are normal editing, encoder spins, playback, scrubbing, and scene
changes in Paulinche. Implementation only continues if large clean gaps
occur regularly and the avoidable USB time from them is relevant. Recurring
gaps of more than roughly 50 rows serve as the guideline.

### Phase 2: Reconciler and protocol

If phase 1 confirms the benefit:

- Dirty rows are split at clean gaps of at least 12 rows.
- At most four full-width rects remain per screen and tick. With more
  candidates, the smallest gaps are merged back together.
- Full-width geometry is preserved; the panel processes wide bands faster
  than narrow windows.
- The binary codec gains a multi-rect display frame with screen, rect list,
  and the associated RGB565 payloads.
- The daemon treats all rects of one screen and tick as one atomic pending
  unit. Newest-wins always replaces a complete rect set.
- Existing single blits remain valid for older clients.

The atomic unit is mandatory: today's daemon queue holds only one pending
blit per screen. Several loose split blits of the same tick could replace
each other and permanently leave untransported regions behind.

### Tests and acceptance

- Reconciler tests for threshold, band limit, single row, full frame, and
  gaps lying exactly on the threshold.
- Codec tests for multiple rects, payload lengths, and invalid geometry.
- Daemon tests: newest-wins replaces complete sets, never individual rects.
- Hardware: the sum of transfer times in the measured Paulinche scenario
  is clearly below the previous single-band time.
- Hardware: no tearing and no stale regions during fast scrubbing.

## AP3: Build the binary event payload directly

Not a standalone optimization project. On the next intervention in
`pushInputToClients` or `pushMidiToClients`, pass the already existing
timestamp together with the raw bytes directly to
`KKDaemonBinaryCodec.eventPayload(timestamp:bytes:)`.

The hex text stays for logs and old text clients. Only today's
raw bytes → hex string → split → raw bytes round trip for binary clients
disappears, and the binary payload is built before the daemon lock.
Expected gain: microseconds, no perceptible latency change.

## What we are not doing

### No changes to the input transport

Surface and MIDI IN already run over permanently resubmitted asynchronous
libusb transfers. The daemon watches the libusb pollfds with kqueue and
pumps events without a polling interval. Socket `poll()` wakes immediately
on data; its timeout is only an idle bound. There is no structural
millisecond lever here.

### No asynchronous USB OUT transfers

Display and state reports already have separate queues and may use libusb
in parallel on different endpoints. An asynchronous display OUT path would
complicate buffer lifetime, completion, and error logic considerably,
without shortening device time or freeing other work.

### No fire-and-forget socket writes without acks

Display and state report acks already confirm only enqueueing, not USB
completion. The short round trip check carries error detection plus the
timeout/probe/reconnect logic. Removing it saves too little and weakens
session safety.

### No higher default tick rate

Paulinche already uses 60 Hz. After AP1, content changes no longer depend
on the timer raster. The 30 Hz default stays for other clients; later it
can even be checked for Paulinche whether 30 Hz suffices for animations and
heartbeat.

### No compression

The display expects raw RGB565. Compression could only shorten the fast
Unix socket leg; before USB, the daemon would have to decompress again and
transfer the same amount of pixels. Row diffing and, where applicable,
multi-rect blits reduce the data where it counts: before the USB transfer.

### No shared-memory framebuffer and no in-process daemon

The measured IPC share is below 1 ms, while USB and panel need several
milliseconds. Privilege separation, crash isolation, and a hardware session
stable across client restarts are worth more. Shared memory stays only as
an escape hatch, should future profiling unexpectedly identify the socket
transport as the bottleneck.

### No column cropping

Display diffs stay full-width. The hardware measurements show an ingest
penalty for narrow windows; AP2 only splits row bands.
