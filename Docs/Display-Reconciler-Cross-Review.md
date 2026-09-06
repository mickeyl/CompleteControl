# Display Reconciler: Cross-Review Against the Stream-Deck Stack

**Date:** 2026-08-23
**Status:** Implemented and closed by measurement — T1, T2, T3 stage 1 on `wip/performance`; T3 stages 2/3 and T4 (AP2) closed or rejected by benchmark on 2026-09-06; see Implementation status

This document records a cross-comparison between `PixelDisplayReconciler2`
(here) and the Stream-Deck project's `PageReconciler`
(`auriteq-flow-hacking/elgato/`). The focus is deliberately the direction
**"what CompleteControl should adopt"**; the reverse direction is summarized
at the end only as far as it carries the context of the proposals.

The two reconcilers solve the same problem at different levels, because the
hardware forces them to. Nothing here is a call to converge the architectures.

## Implementation status

**2026-09-02, branch `wip/performance`:** T1, T2, and the `reserveCapacity`
line from T3 are implemented. The 2026-09-06 hardware benchmark (branch vs
master, 12 iterations per fixture, adaptive) then decided both open
questions: T3 stages 2/3 are latency-irrelevant and therefore closed, and
T4 (AP2) is rejected by measurement — see below.

Two corrections against this document:

- The Kit2 default tick is 30 Hz (`MK2Surface2.Options.tickHz`), not 60;
  Paulinche does operate the surface at 60 Hz though (see the transport
  review), so the absolute numbers in T1 remain valid for the main client.
  The structural argument is unaffected.
- T3 is four copies, not three: `KKDaemonBinaryFrame.encoded()` materializes
  the payload a fourth time (capacity-reserved, but complete).

The composite cache is a self-validating cache in
`displaysWithTouchOverlays`: base frames (CoW identity) plus every active
overlay (screen, rect, pixel-buffer identity) form the key. Overlay content
is part of the key because a scene swap can hand the same base buffers back
with swapped overlay pixels — the key proposed below ("base identity +
overlay set") would have left that hole open. Held-layer switches need no
explicit invalidation (layer frames carry their own identity, `?? base`
falls back to the untouched base); both facts are pinned by tests
(`TouchOverlayCompositeCacheTests`). `blit(_:into:)` copies row-wise via
`memcpy` (guard unchanged, differential test over 100 deterministic rects),
and overlay composition runs deterministically in ascending encoder order
instead of dictionary order.

Measurement points from `PixelPipelinePerfTests` (arm64) — each pair
measures the new implementation against a reference implementation of the
old path in the same run:

| Measurement point | Debug | Release |
|---|---|---|
| Overlay blit 464×57: memcpy vs. replaceSubrange | 0.008 vs. 0.011 ms/op | 0.001 vs. 0.001 ms/op |
| Held-overlay tick: cache vs. fresh identity | 0.001 vs. 0.038 ms/op | ~0.000 vs. 0.011 ms/op |
| Display payload full frame: reserved vs. unreserved | 0.005 vs. 0.005 ms/op | 0.004 vs. 0.004 ms/op |

Assessment: the held-overlay tick becomes ~30–40× cheaper — in absolute
terms still no emergency (~0.01–0.04 ms per tick and screen), as already
suspected in T1. The `reserveCapacity` is median-neutral; its win is
allocation churn and tail variance in the timeout-critical replay path, not
median time. The blit memcpy is mainly debug-build consistency with the
file's bulk policy.

### Hardware benchmark 2026-09-06: branch vs master

12 iterations per fixture, adaptive encoding, release builds, S61 MK2.
Result: **transport bytes byte-identical across all seven fixtures**; USB
median and wall P90 scattered within single-run noise in both directions
(small fixtures apparently −18…−43%, large ones +5…+7%; P90 hits such as
rotary at 2.32 ms against a 0.33 ms median are single-sample hiccups).
`usbMedian` comes from the daemon's physical transport counters and cannot
be influenced by the client branch in principle — no mechanism in the
branch can have produced these deltas. Consequences:

- **Safety gate passed**: zero transport failures, byte-identical payloads —
  the `reserveCapacity` acceptance is done.
- **T3 stages 2/3 closed**: the copy share of a full-frame replay is ≤0.2%
  of wall time (four materializations of 261 KB each ≈ 25–50 µs against a
  ~21 ms transfer); any remaining value would be pure allocator hygiene.
- **T4 (AP2) rejected**: the gap fixture sends 190,080 logical bytes as
  **368 transport bytes in 0.742 ms USB** over the wire. The adaptive skip
  encoding collapses clean gaps at the wire level and thereby already
  delivers what AP2 wanted to achieve with a protocol change, atomic
  daemon-queue semantics, and hardware acceptance. AP2's own phase-1 gate
  ("implementation only continues if … the avoidable USB time is relevant")
  is thereby answered in the negative; the historical motivator ("band
  merges up to full frame height → ~24 ms") only applies to incompressible
  bands — and those have no clean gaps to split.

**On attribution, honestly:** the transport review (2026-07-09) was correct
at the time it was written — its premise (raw band bytes over USB) was only
removed on 2026-07-15, when adaptive encoding became the default. But the
Protocol Guide has documented since exactly that day that chained
skip/literal/repeat segments reach the AP2 goal in *one* transfer more
cheaply (AP2 would have paid a 16-byte header + 12-byte trailer + its own
`libusb_bulk_transfer` per rect). This review's T4 statement ("only
confirms the prioritization") never weighed that counter-part sitting in
the repo and reasoned in client-band rather than wire-segment granularity.
That is this document's actual mistake; the recommendation is withdrawn.

**Side finding (recorded in the Protocol Guide):** USB time is
packet-granular, not byte-granular — meter step 11,646 B in 7.21 ms
(~620 ns/B) against large noise 153,632 B in 14.72 ms (~96 ns/B). The only
remaining measurable display-path lever is segment coalescing in the
adaptive encoder (pull a literal across a small gap when the segment
overhead exceeds the saved bytes) — daemon-internal, same wire format;
recorded as an observation in the Backlog, not implemented.

## Baseline

| | CompleteControl | Stream Deck |
|---|---|---|
| Wire format | raw RGB565, arbitrary rects blittable | JPEG, button is atomic |
| Diff level | pixels: CoW identity → `memcmp` per row → one full-width band | semantics: descriptor comparison, skips rendering |
| Second stage | – | 64-bit fingerprint over the JPEG bytes, skips transport |
| Third stage | one in-flight batch, latest-wins per frame | job queue with key coalescing, newest-wins per button/window |
| Failure path | `reconciler.reset()`, cooldown, `pendingForcedDisplayReplay` | missing (currently being added there) |

The asymmetry that matters to us: the Stream-Deck reconciler decides
**before** rendering whether there is anything to do at all. We always
render the scene and decide afterwards, based on the pixels. That is mostly
right for us — the CoW identity check is cheaper than any descriptor
comparison and cannot become incomplete when someone forgets to compare a
newly added field. But there is one path where this premise breaks today.

## T1: Composite cache for touch overlays

**This is the one point where we structurally give away work.**

`activeDisplays` (`MK2Surface2.swift:812`) calls
`displaysWithTouchOverlays(scene.displays)` on every tick. Without an active
overlay the frames stay untouched, CoW identity survives, and `reconcile`
exits in O(1) — exactly as designed.

As soon as an encoder touch overlay is active, however, every tick does:

```swift
guard isActive, var frame = displays[overlay.screen] else { continue }
frame.blit(overlay.pixels, into: overlay.rect)   // MK2Surface2.swift:832-835
```

`var frame` + mutation forces a CoW copy of the complete framebuffer
(480×272×2 = 261,120 bytes), the overlay is copied into it again, and
because the buffer now carries a new identity, `dirtyRowBand` afterwards
scans the whole frame row by row — only to find that nothing changed, and
to set `lastSent` to a bit-identical buffer.

With `behavior == .latched` (`MK2Surface2.swift:830`, set in
`MK2Surface2.swift:1154`) the overlay stays up for many seconds. At 60 Hz
that is roughly 15 MB/s of copying plus 30 MB/s of comparison per affected
screen, for a still image. In absolute terms this is no emergency;
structurally it is the very case the reconciler has the O(1) path for.

**Proposal:** a composite cache in the surface, keyed on (identity of the
base frame, set of active overlays). On a key hit, the cached composited
frame is returned **unmodified** — `isIdentical` applies again and the tick
costs nothing. Only when the scene or the overlay set changes is anything
re-composited.

This is the local equivalent of what the `PageReconciler` does with its
descriptor diff: the question "did anything change content-wise?" is
answered *before* pixels are touched. The difference is that we need no
field-by-field equality for it — buffer identity plus a set of overlay keys
suffices.

**Tests and acceptance**

- Unit test: an active, unchanged overlay over N ticks produces exactly one
  composite operation and no blits.
- Unit test: a scene change with an active overlay invalidates the cache.
- Unit test: transition `.momentary` → released returns the base frame
  without a copy.
- `PixelPipelinePerfTests`: new measurement point "tick with held overlay"
  before and after the change.

## T2: `blit(_:into:)` does not follow its own bulk policy

`MK2PixelFrame` explicitly documents that the hot paths deliberately use
`memset_pattern4`/`memcmp`/`memcpy`, because element-wise Swift loops
collapse in unoptimized builds (`PixelFrame.swift:44-48`). The tile blit
follows that policy (`PixelFrame.swift:196`, `memcpy` per row).

The public `blit(_ sourcePixels: [UInt16], into rect:)`
(`PixelFrame.swift:423`) is the outlier: it copies per row through
`pixels.replaceSubrange(_:with:)`. That is exactly the call from T1, i.e.
the path that runs every tick. Row-wise `memcpy` under
`withUnsafeMutableBufferPointer` — analogous to the tile blit — makes it
consistent and measurably faster in debug builds.

A small intervention, sensible independently of T1, but on the same code.

## T3: Three copies of the band before the socket write

A blit is fully copied three times on its way to the daemon:

1. `let pixels = Array(frame.pixels[…])` — band extracted from the frame
   (`PixelDisplayReconciler2.swift:50`)
2. `blit.pixels.withUnsafeBytes { Array($0) }` — into `[UInt8]`
   (`MK2DisplayBlitWriter.swift:51`)
3. `payload.append(contentsOf: pixelsRGB565BE)` in `displayBlitPayload`
   (`DaemonBinaryProtocol.swift:378`) — there without `reserveCapacity`; the
   array starts with two elements

On a full-frame replay that is 3 × 261 KB per screen, and precisely in the
load case that historically descended into the timeout → resend → timeout
loop, according to the writer's header comment
(`MK2DisplayBlitWriter.swift:14-18`). The Stream-Deck stack has the cleaner
cut here: it passes `std::span` through to report construction and only
copies when building the chunks.

**Proposal, in ascending depth of intervention:**

- Immediately and risk-free: `reserveCapacity(14 + pixels.count)` in
  `displayBlitPayload`.
- Copy 2 disappears when `sendDisplayBlit` takes the pixels as an
  `UnsafeRawBufferPointer` (or `some Sequence<UInt8>`) instead of `[UInt8]`.
- Copy 1 disappears when `MK2PixelBlit` holds the frame and row range
  instead of its own array. With full-width geometry the band is contiguous
  anyway — exactly the property that `pixels(in:)` (`PixelFrame.swift:436`)
  already exploits.

The last stage touches the blit type and the tests; it is only worth it if
T1 and copy 2 do not already suffice.

## T4: Multi-Rect — no new idea, just an added argument

*(Withdrawn on 2026-09-06 — the adaptive skip encoding already fulfills the
purpose at the wire level; see Implementation status and the result block in
`transport-latency-optimization-review.md` AP2. The text below remains as
the historical rationale.)*

`Docs/transport-latency-optimization-review.md` AP2 already planned this
completely (threshold 12 rows, at most four full-width rects, atomic
pending unit in the daemon). The cross-comparison only confirmed the
prioritization: the `PageReconciler` does not have this problem at all,
because its granularity is the tile — an upper status area and a lower
meter are two independent uploads there, while they merge into one band up
to full frame height for us.

One detail not yet in AP2: the break-even constant for the split can be
derived from `MK2DisplayBlitWriter.ackTimeoutUsec(forPixelBytes:)`
(`MK2DisplayBlitWriter.swift:43`) — a 50 ms base budget plus 1 µs per 5
bytes. The ratio of fixed cost to byte cost has thereby already been
determined empirically once, and it can support the "12 rows" threshold in
phase 1 with real measurement data instead of postulating it.

The phase-1 telemetry already exists, env-gated
(`KONTROL_SURFACE_KIT2_RECONCILER_TELEMETRY=1`,
`PixelDisplayReconciler2.swift:62-101`), and delivers exactly
`gaps`/`largestGap`.

## Explicitly not adopting

- **Byte-fingerprint dedup before transport.** In the Stream-Deck stack the
  second line of defense, because a JPEG encode sits between semantics and
  bytes there. Our pixel diff is strictly stronger; hashing over it would
  be pure extra work.
- **Field-by-field descriptor comparison.** The `PageReconciler` pays a real
  price for it (deep comparisons over row and column vectors, plus a deep
  copy of the whole page per present) and carries the known risk that a
  newly added field is forgotten in the comparison. Our buffer identity
  achieves the same in O(1) and cannot become incomplete. T1 only borrows
  the *point in time* of the decision, not its mechanics.
- **Column cropping.** Stays rejected, see AP2 ("No column cropping"). The
  Stream-Deck stack does the opposite in one place — narrow full-height
  columns for the modal choice window's zones — and has to re-measure for
  it; our hardware measurement already exists.

## The reverse direction, for context

What the Stream-Deck stack adopts from here (in implementation there, only
listed for completeness):

1. **Invalidation epoch.** The return channel "the sink discarded your
   pixels" is completely missing there: screensaver, `show_logo()`, and
   fullscreen uploads invalidate the driver cache, but the reconciler above
   keeps believing its state is on the device — after waking up, an
   unchanged descriptor paints nothing new. We have
   `displayReconciler.reset()`, `pendingForcedDisplayReplay`, and
   `replaySurfaceState()` for that.
2. **Dirty-row band before the JPEG encode**, for the 1200×100 touch window.
3. **Backpressure instead of blindly rendering** — our
   `guard !displayWriter.isBusy` saves them the complete JPEG encode that
   the queue would discard anyway.

## Open measurements

- ~~Cost of a tick with a held overlay, before and after T1.~~ Answered (see
  Implementation status): ~30–40× cheaper, in absolute terms ~0.01–0.04 ms
  per tick and screen.
- ~~`replaceSubrange` vs. row-wise `memcpy` in `blit(_:into:)`, debug and
  release.~~ Answered (see Implementation status): debug ~1.4×, release
  neutral.
- ~~Share of copy time in a full-frame replay, to decide whether T3 beyond
  the `reserveCapacity` line is worth it.~~ Answered (hardware benchmark
  2026-09-06, see Implementation status): ≤0.2% of wall time — T3 stages
  2/3 closed, AP2 rejected.
