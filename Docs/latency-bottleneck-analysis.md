# Display & Input Latency Bottleneck Analysis

## Context

This document analyzes the end-to-end latency pipeline of the Komplete Kontrol MK2 surface driver, from USB input event arrival to display/LED output. It covers the daemon-side fixes already applied (commits d55b0da, 88dacad, 0774817, 7869e1f) and identifies remaining bottlenecks ranked by impact.

The target audience is a developer who needs to continue optimizing the pipeline. All file references use absolute paths and line numbers as of the current HEAD.

---

## Architecture Overview

The pipeline has three layers:

1. **Client** (`MK2Surface2` actor in `KontrolSurfaceKit2`) — owns the scene, runs a 30Hz tick timer, sends display blits and LED/guide reports to the daemon via binary sockets.
2. **Daemon** (`DaemonHardware` in `KompleteKontrol.swift`) — owns the libusb session, queues display blits and state reports on a serial `displayQueue`, pumps USB events via kqueue.
3. **C USB layer** (`KontrolUSB.c`) — synchronous libusb transfers (bulk for display, interrupt/control for LEDs/guide).

### Input path (event → user)

```
USB device
  → libusb async transfer callback (C)
    → DaemonHardware.pushInputToClients (Swift, reactor-adjacent)
      → hex string encode → pushToClients
        → binary frame encode → write to event socket fd
          → MK2Surface2 reader thread (poll event socket)
            → AsyncStream yield
              → MK2Surface2.process(frame) [actor]
                → handleSurfacePush → bindings (encoder/button/strip handlers)
```

### Output path (scene → device)

```
MK2Surface2.tick() [actor, 30Hz timer]
  → reconcileDisplays (diff pixel frames, generate blits)
    → blitDisplay → displayClient.sendDisplayBlit (sync socket round-trip, 50ms timeout)
  → reconcileLamps (diff LED state)
    → writeReport → controlClient.request (sync socket round-trip, 50ms timeout)
      → daemon receives binary frame on kqueue
        → DaemonHardware.handleBinaryFrame
          → enqueueDisplayBlit / binaryWriteReport
            → displayQueue.async { drainDisplayBlits }
              → performDisplayBlit → libusb_bulk_transfer (sync, 10-20ms)
              → performStateReportWrite → libusb_interrupt_transfer or libusb_control_transfer (sync, 50-100ms timeout)
```

---

## What the last 4 commits fixed

All four commits targeted **daemon-side blocking** — specifically, the `sessionIOLock` serializing the reactor's event pump behind 10-20ms display blits.

### d55b0da — LED/guide writes moved to async display queue

**Before:** LED/guide writes were synchronous on the daemon, blocking the client's actor behind `sessionIOLock` while a 10-20ms blit was in flight.

**After:** Full-state LED/guide maps (`buttonLEDReportID`, `lightGuideReportID`) are enqueued on the `displayQueue` with newest-wins semantics, same as display blits. Config reports keep the synchronous path (rare, ordering matters).

**File:** `KompleteKontrol.swift:3061-3084` (`binaryWriteReport`)

### 88dacad — sessionIOLock converted from mutex to pthread_rwlock_t

**Before:** A plain `NSLock` / mutex guarded the libusb session. Every `handleUsbEvents` call (reactor event pump) had to acquire it exclusively, but display blits held it for 10-20ms. Input events arrived in bursts aligned to blit completions.

**After:** `SessionUseLock` uses `pthread_rwlock_t` — shared (read) lock for concurrent transfers and event pumping, exclusive (write) lock only for close/reopen. This lets the reactor pump events while a blit is in flight.

**File:** `KompleteKontrol.swift:2718-2740` (`SessionUseLock`)

### 0774817 — Removed redundant USB pump after binary frame processing

**Before:** After processing each binary frame, the daemon called `handleUsbEvents(timeoutMs: 0)` inline. This added latency to the ack and was redundant — kqueue already watches libusb fds and wakes the reactor on actual activity.

**After:** No USB pump in `processClientCommands` for binary connections. The text protocol's `read`/`midiread` still pump (those are polls by design).

**File:** `KompleteKontrol.swift:2439-2441` (comment explaining the decision)

### 7869e1f — writeReport timeout ceiling reduced from 250ms to 50ms

**Before:** `writeReport` used the default 250ms timeout for the socket round-trip.

**After:** `writeReport` uses 50ms timeout, reducing worst-case stall when the daemon is slow to ack.

**File:** `MK2Surface2.swift:388-399` (`writeReport`)

---

## Remaining bottlenecks (ranked by impact)

### 1. The 30Hz tick timer adds 0-33ms of structural latency

**Impact:** 0-33ms (average 16.5ms) of pure wait time before scene changes reach the daemon.

**Location:** `KontrolSurfaceKit2/MK2Surface2.swift:112-126`

```swift
private func startTimer() {
    let intervalNs = UInt64(1_000_000_000 / max(1, options.tickHz))
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
    timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(intervalNs)), leeway: .milliseconds(2))
    timer.setEventHandler { [weak self] in
        guard let self, self.tickGate.begin() else { return }
        Task {
            await self.tick(forceDisplay: false)
            self.tickGate.end()
        }
    }
```

**Problem:** Input events are processed immediately on the actor via `process(frame)`, but **output only happens at the next tick**. The input handler at `MK2Surface2.swift:331-365` updates `scene.bindings` closures but never triggers a reconciliation. The updated scene sits idle until the next timer fires.

At 30Hz, the average wait is 16.5ms. For a knob turn that updates a parameter value on screen, this means the display reaction lags the physical movement by at least one tick period.

**Fix:** After `handle(events:)` returns, call `tick(forceDisplay: false)` immediately if any binding was invoked. The `TickGate` already prevents overlapping ticks. This would cut average end-to-end latency by ~16ms.

**Risk:** If bindings fire at a high rate (e.g., fast encoder spin), this could cause many ticks per second. Consider a debounce or min-interval guard (e.g., don't tick more than once per 8ms). The `TickGate` prevents overlap but not flooding.

### 2. Serial displayQueue blocks LED updates behind in-progress blits

**Impact:** Up to 10-20ms delay for LED/guide updates when a display blit is in flight.

**Location:** `KompleteKontrol.swift:2789`

```swift
private let displayQueue = DispatchQueue(label: "media.vanille.kompletekontrol.display", qos: .userInitiated)
```

**Location:** `KompleteKontrol.swift:3148-3174` (`drainDisplayBlits`)

```swift
private func drainDisplayBlits() {
    while true {
        // ... snapshot blits and reports ...
        for (reportID, payload) in reports {
            performStateReportWrite(reportID: reportID, payload: payload)
        }
        for blit in blits {
            performDisplayBlit(blit)
        }
    }
}
```

**Problem:** State reports (LED/guide) and display blits are both drained on the same serial `displayQueue`. State reports drain before blits **within a drain cycle**, but if a drain is already in progress (processing a 10-20ms blit from the previous tick), new LED reports wait for that blit to finish. The `while true` loop picks them up in the next iteration, but that's after the current blit completes.

The key insight: **LED/guide reports and display blits use different USB endpoints** (control/interrupt vs. bulk-out). They could be concurrent — libusb is documented thread-safe for concurrent transfers (as noted in commit 88dacad). But the serial queue forces them to be sequential.

**Fix:** Use a separate high-priority serial queue for `performStateReportWrite`, or drain state reports immediately upon enqueue instead of batching them with blits. The `sessionIOLock` rwlock already permits concurrent shared access, so the only serialization is the `displayQueue` itself.

**Risk:** Two concurrent `libusb_*_transfer` calls on the same device handle. libusb documentation states this is safe for concurrent transfers on different endpoints. Verify that the display endpoint and the control/interrupt endpoint are indeed different (they are: `displayOutputEndpoint` vs. `outputEndpoint` / `surfaceInterface`).

### 3. Synchronous USB transfers block the display queue

**Impact:** 10-20ms per blit where the display queue cannot do anything else.

**Location:** `KontrolUSB.c:1603` (display blit)

```c
int status = libusb_bulk_transfer(session->handle, session->displayOutputEndpoint, buffer, (int)offset, &transferred, timeout);
```

**Location:** `KontrolUSB.c:1077` (interrupt report)

```c
int status = libusb_interrupt_transfer(handle, endpoint, buffer, (int)totalLen, &transferred, 50);
```

**Location:** `KontrolUSB.c:1096-1104` (HID control report)

```c
int status = libusb_control_transfer(
    handle,
    LIBUSB_REQUEST_TYPE_CLASS | LIBUSB_RECIPIENT_INTERFACE | LIBUSB_ENDPOINT_OUT,
    0x09, (uint16_t)((2 << 8) | reportID), interfaceNumber,
    buffer, (uint16_t)totalLen, 100
);
```

**Problem:** Each `libusb_bulk_transfer` for a display blit blocks the calling thread for 10-20ms. No other work can happen on the `displayQueue` during the transfer. The input path is unaffected (rwlock + kqueue), but output is fully serialized.

This is the root cause behind issue #2 — even if state reports had their own queue, they'd still need `sessionIOLock` shared access, which is fine. But the display queue itself is blocked.

**Fix:** Convert to `libusb_submit_transfer` with a completion callback. This would let the display queue submit a blit and immediately move on to the next state report or blit. This is a bigger change but would allow overlapping USB transfers with queue processing.

**Risk:** Significant refactor. Need to manage transfer lifetimes, handle completion callbacks on libusb's event thread, and ensure the buffer stays alive until the transfer completes. The current synchronous code is simple and correct; async transfers add complexity around buffer ownership and error handling. Consider whether the gain (overlapping transfers) justifies the risk.

**Alternative:** If issue #2 is fixed (separate queue for state reports), this becomes less critical — state reports won't wait behind blits. The display queue being blocked by blits is acceptable if blits are the only thing on it.

### 4. Actor serializes input processing with tick socket round-trips

**Impact:** ~0.5ms per tick round-trip where input frames queue up.

**Location:** `MK2Surface2.swift:388-399` (`writeReport`)

```swift
private func writeReport(_ reportID: UInt8, _ payload: [UInt8]) -> String? {
    let response = controlClient?.request(
        type: .writeReport,
        payload: KKDaemonBinaryCodec.writeReportPayload(reportID: reportID, payload: payload),
        timeoutUsec: 50_000
    )
```

**Location:** `MK2Surface2.swift:401-422` (`blitDisplay`)

```swift
private func blitDisplay(...) -> String? {
    let data = pixelsRGB565.withUnsafeBytes { Array($0) }
    let ok = displayClient?.sendDisplayBlit(...)
```

**Location:** `DaemonBinaryProtocol.swift:266-285` (`request`)

```swift
public func request(...) -> (status: Int32, message: String)? {
    lock.lock()
    defer { lock.unlock() }
    // ... send frame ...
    let deadline = Date().addingTimeInterval(...)
    while Date() < deadline {
        if let frame = readFrame(until: deadline) {
            guard frame.type == .ack, frame.sequence == sequence else { continue }
            return KKDaemonBinaryCodec.parseAckPayload(frame.payload)
        }
    }
    return nil
}
```

**Problem:** `MK2Surface2` is an actor. Both `process(frame)` (input) and `tick()` (output) run on it. The tick does synchronous socket round-trips for LED/guide/display. Each `request()` / `sendDisplayBlit()` is synchronous — it sends a frame and blocks on `poll()` waiting for the ack. The daemon acks immediately (enqueue + return), so the round-trip should be ~0.1-0.5ms. But during that time, input frames queue up in the `AsyncStream`.

This is minor if round-trips are fast, but it compounds with issue #1: if a tick is running when input arrives, the input waits for the tick to finish, then the scene update waits for the *next* tick.

**Fix:** This is mostly resolved by fixing issue #1 (immediate tick after input). If the actor is busy with a tick when input arrives, the input queues for ~0.5ms, then the next tick processes the updated scene immediately. The residual 0.5ms per round-trip is acceptable.

If further optimization is needed, consider making `writeReport` and `blitDisplay` async (fire-and-forget without waiting for ack), but this loses error detection.

### 5. Hex string round-trip on the input hot path

**Impact:** ~5-10μs per input event. Minor but pure waste.

**Location:** `KompleteKontrol.swift:4396-4408` (`pushInputToClients`)

```swift
fileprivate func pushInputToClients(_ data: UnsafePointer<UInt8>, length: UInt32) {
    let bytes = (0..<Int(length)).map { data[$0] }
    let hex = bytes.map(KKHex.byte).joined(separator: " ")
    // ...
    pushToClients("in @\(String(timestamp, radix: 16)) \(hex)", kind: .input)
}
```

**Location:** `KompleteKontrol.swift:4479-4487` (`binaryEventPayload`)

```swift
private func binaryEventPayload(fromTextPush message: String) -> [UInt8] {
    let parts = message.split(separator: " ")
    let timestamp = parts.dropFirst().first.flatMap { ... UInt64(token.dropFirst(), radix: 16) } ?? KKTiming.now()
    let bytes = parts.dropFirst(2).compactMap { UInt8($0, radix: 16) }
    return KKDaemonBinaryCodec.eventPayload(timestamp: timestamp, bytes: bytes)
}
```

**Problem:** Raw bytes → hex string → split → parse hex → bytes. This runs for every input event. The text format exists for legacy text-protocol clients; binary event clients don't need it.

**Fix:** In `pushInputToClients`, construct the binary event payload directly from the raw bytes and timestamp, bypassing the text format entirely for binary event clients. Keep the text path for `clientFDs` (legacy text clients).

**Risk:** Low. The binary payload format is already defined (`KKDaemonBinaryCodec.eventPayload(timestamp:bytes:)`). Just call it directly with the raw bytes instead of round-tripping through hex.

---

## Summary table

| # | Issue | Latency impact | Layer | Fix complexity |
|---|---|---|---|---|
| 1 | 30Hz tick timer | 0-33ms (avg 16.5ms) | Client (`MK2Surface2`) | Low |
| 2 | Serial `displayQueue` | up to 10-20ms | Daemon (`DaemonHardware`) | Low-Medium |
| 3 | Sync USB transfers | 10-20ms per blit | C (`KontrolUSB.c`) | High |
| 4 | Actor serialization | ~0.5ms per tick | Client (`MK2Surface2`) | Resolved by #1 |
| 5 | Hex string round-trip | ~5-10μs per event | Daemon (`DaemonHardware`) | Low |

## Recommended fix order

1. **Issue #1** (tick timer) — highest impact, lowest complexity. Add immediate `tick()` after input handling.
2. **Issue #2** (serial displayQueue) — second highest impact. Split state reports onto their own queue.
3. **Issue #5** (hex round-trip) — low impact but trivial to fix. Clean up while in the area.
4. **Issue #3** (sync USB transfers) — only if #2 doesn't provide enough improvement. Significant refactor risk.

## Key files

- `Sources/KontrolSurfaceKit2/MK2Surface2.swift` — client actor, tick timer, input/output
- `Sources/KontrolSurfaceKit2/PixelDisplayReconciler2.swift` — display frame diffing
- `Sources/KompleteKontrol/KompleteKontrol.swift` — daemon hardware, reactor, display queue
- `Sources/KompleteKontrol/DaemonBinaryProtocol.swift` — binary socket client
- `Sources/KontrolUSB/KontrolUSB.c` — libusb synchronous transfer calls
