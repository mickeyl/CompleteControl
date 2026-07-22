# Headless Simulator Host — Implementation Plan

**Status (2026-07-22): slices 1-3 and 5 are delivered** — `SimulatorInstancePaths`
+ lease, `SimulatorDaemonController` (GUI refactored onto it),
`kontrol-sim-host` with control plane and integration tests, docs and
`make sim-host`. Slice 4 (native MK2 runtime synthesis) remains open and is
tracked in `Docs/Backlog.md`. One deviation from the original text: shutdown
escalates a non-responding owned `ccd` to SIGKILL after a grace period — a
SIGTERM sent during the child's early spawn window was observed to get lost,
and the exit contract must not depend on it.

Implements the Backlog item "Add a deterministic headless simulator host for
end-to-end automation" (`Docs/Backlog.md`, Simulator section). The governing
requirement, beyond the backlog text: a headless run must be *incapable by
construction* of colliding with the graphical simulator, another headless run,
or a real-hardware daemon. Isolation must not depend on discipline (nobody
forgetting an env var) but on namespaces that never overlap.

## Goal

A single CLI invocation launches a virtual device (S61 MK2 or MASCHINE MK3)
without AppKit, optionally owns a matching user-level `ccd`, optionally enables
the daemon automation socket, publishes machine-readable readiness, replays
input scenarios at two explicit fidelity levels, exposes device-output state
for assertions, and terminates without stale processes, sockets, or files —
in parallel with any number of sibling runs, a GUI simulator, and a live
hardware daemon.

## Non-goals

- No replacement for AppKit visual acceptance, physical-device feel, USB
  timing, or real-hardware integration checks (explicit in the backlog).
- No mixed real+simulated topology and no Paulinche composite port — that
  remains Phase 5 proper of `Maschine-MK3-Simulator-Plan.md`. This plan only
  builds the instance-path substrate that Phase 5 also needs.
- No multi-device single daemon; one host instance is one virtual device plus
  at most one owned `ccd`.

## Isolation model (the "never collides" guarantee)

Today's globals and how each one is removed for headless runs:

| Global today | Headless replacement |
| --- | --- |
| Device wire socket `/tmp/kontrol-simulator.sock` | `/tmp/kksim-<instance>/device.sock` |
| Daemon socket `/tmp/kontrol-simulator-daemon.sock` (+ `.event/.display/.automation`) | `/tmp/kksim-<instance>/daemon.sock` (+ channels) |
| Daemon log `/tmp/kontrol-simulator-daemon.log` | `/tmp/kksim-<instance>/daemon.log` |
| `UserDefaults` (`daemon.autostart`, `daemon.automationEnabled`, identity overrides, window state) | CLI flags only; the headless host never reads or writes defaults |
| Process ownership via AppKit lifecycle | Explicit child ownership + signal routing in a Foundation controller |

Properties that follow:

- **GUI vs. headless:** the headless namespace `/tmp/kksim-<instance>/` is
  disjoint from both legacy global paths, for *every* instance ID — even
  `--instance main` cannot bind the GUI's sockets. The GUI keeps its legacy
  paths unchanged in this plan (its migration is Phase 5 proper).
- **Headless vs. hardware:** the owned `ccd` runs user-level with an explicit
  instance socket and `CCD_SIMULATE`, so it opens no USB device and needs no
  sudo. The host never sends `pkill` of any kind; it terminates only the child
  process handle it owns (same rule the GUI already follows). The `make
  daemon*` targets with their broad `sudo pkill` are never involved.
- **Headless vs. client auto-discovery:** `daemonSocketPathPreferringSimulator`
  probes only the fixed `/tmp/kontrol-simulator-daemon.sock`. Instance sockets
  are invisible to it, so a desk Paulinche can never accidentally attach to a
  CI instance — and a test client must be pointed explicitly via
  `KK_DAEMON_SOCKET`, which the readiness output provides verbatim.
- **Headless vs. headless:** the instance directory is created with `O_EXCL`
  semantics and holds a `host.lock` (`flock` + pid). A second host on the same
  instance ID exits immediately with a dedicated exit code. A stale directory
  (lock holder dead) is reclaimed by deleting only the known, validated file
  names inside it — never a recursive unlink of arbitrary content.

Instance IDs reuse the existing validation (1–32 chars, `[A-Za-z0-9_-]`).
Default when `--instance` is omitted: `pid<pid>` — unique per invocation, so
parallel test runners need no coordination; stable rigs pass an explicit ID.
Paths stay far below the 104-byte `sun_path` limit.

## Architecture

### Decision: separate executable, not a flag on `KontrolSimulator`

The backlog asks for a "non-AppKit launch mode". Recommended realization: a
new small executable target rather than a `--headless` branch inside
`Tools/KontrolSimulator/main.swift`:

- Not linking AppKit at all guarantees no WindowServer connection, so the host
  runs over SSH, in CI sandboxes, and under launchd without a session — a
  guarantee a runtime branch cannot give.
- It structurally prevents the `UserDefaults` and window-state code paths from
  leaking into deterministic runs.
- The GUI app's main stays untouched; shared logic moves down into
  Foundation-only types both fronts use.

Proposed target: executable `kontrol-sim-host`, sources in
`Tools/KontrolSimHost/`, depending on `KompleteKontrol` +
`KontrolSimulatorCore` only.

### Components

1. **`SimulatorInstancePaths`** (new, `KontrolSimulatorCore`)
   Validated instance ID → directory, device socket, daemon base socket,
   derived channel sockets, log, lock. Owns creation, liveness probing,
   stale reclaim, and teardown. No path string is assembled anywhere else.

2. **`SimulatorDaemonController`** (new, `KontrolSimulatorCore`; extracted
   from `AppController`)
   Foundation-only child-`ccd` ownership: locate binary next to the host
   executable, build environment (`CCD_SIMULATE`, `CCD_ENABLE_AUTOMATION`,
   `LOGLEVEL`), redirect output to the instance log, termination handler,
   optional restart policy, SIGTERM/SIGINT routing. The GUI's
   `startSimulatorDaemon`/`stopSimulatorDaemon`/signal code becomes a thin
   wrapper over this (UserDefaults stay in the GUI layer as its configuration
   source; the controller itself takes plain parameters).

3. **`SimulatorHeadlessHost`** (new, `Tools/KontrolSimHost/`)
   Owns one `DeviceLink` bound to the instance device socket, one
   `SimulatorDeviceRuntime`, one `SimulatorOutputState`, and per-display
   `SimulatorFramebuffer`s. Applies every inbound `SimFrame` to the reduced
   output state (this is exactly what the panel views do, minus drawing), and
   forwards synthesized input frames out. Sends the identity frame on daemon
   connect using CLI-provided overrides instead of defaults.

4. **Control plane: JSON Lines on stdin/stdout**
   Follows the existing `widget-lab --control-stdin` precedent. Events
   (host → stdout, one JSON object per line):

   - `{"event":"ready", "device":"maschine-mk3", "instance":"ci-42",
      "deviceSocket":…, "daemonSocket":…, "automationSocket":…|null,
      "clientEnv":{"KK_DAEMON_SOCKET":…}}` — emitted only after the device
     socket is bound *and*, when the host owns the daemon, the daemon has
     completed the device handshake. Scripts wait for this line instead of
     sleeping.
   - `{"event":"daemonConnected"}` / `{"event":"daemonDisconnected"}` /
     `{"event":"protocolError","message":…}` — live connection state.

   Commands (stdin → host, each answered by `{"ok":true,…}` or
   `{"ok":false,"error":…}`):

   - `{"cmd":"gesture", …}` — native input synthesis via
     `SimulatorDeviceRuntime` (buttons, encoder turn/touch, touch strip,
     pad touch/strike/pressure/release, release-all).
   - `{"cmd":"lamps"}` — decoded reduced output state
     (`SimulatorLampSnapshot`: button bytes, strip/pad bytes, light guide).
   - `{"cmd":"framebuffer","display":0,"format":"rgb565"|"png","path":…}` —
     post-wire decoded panel pixels. This closes the gap noted at the end of
     `automation-testing.md` §4: the daemon shadow (`kk-screenshot.py`)
     verifies completed daemon writes; this endpoint verifies what survived
     the simulator wire and decode.
   - `{"cmd":"identity","firmware":…,"name":…}` — runtime identity override,
     mirroring the GUI dialog without defaults persistence.
   - `{"cmd":"quit"}` — graceful shutdown (same path as SIGTERM).

5. **CLI** (representative invocation from the backlog):

   ```
   kontrol-sim-host --device maschine-mk3 --instance ci-42 \
       --own-daemon --automation [--ccd PATH] [--firmware 1.4.6] [--name "…"]
   ```

   Without `--own-daemon` the host only binds the device socket and waits for
   an externally started `ccd` (`CCD_SIMULATE=<deviceSocket>`), which the
   readiness event also supports (`"daemonSocket":null` until connect).
   `--automation` implies `--own-daemon` and sets `CCD_ENABLE_AUTOMATION=1`
   for the child — no defaults consultation, satisfying the backlog's explicit
   requirement.

   Deterministic exit codes (stable contract for scripts, extending the
   existing `64` usage convention and `kk-input.py`'s stable-status table):

   | Code | Meaning |
   | --- | --- |
   | `0` | clean shutdown (quit command or signal) |
   | `64` | CLI usage error |
   | `69` | instance busy (live lock holder) |
   | `71` | device socket bind failure |
   | `72` | `ccd` binary missing or spawn failure |
   | `73` | daemon exited unexpectedly while owned |

### The two input fidelity levels stay explicit

- **Application-level scenarios** use the daemon automation socket exactly as
  today: `kk-input.py --socket /tmp/kksim-<id>/daemon.sock.automation`. The
  host adds nothing here beyond enabling the socket per flag and printing its
  path in the readiness event. This path lowers semantic commands via
  `MK2InputFrameLowering` and is convenient, but MK2-shaped.
- **Device-profile validation** (especially MK3) uses the `gesture` command:
  `SimulatorDeviceRuntime` synthesizes *native* reports which cross the
  virtual-device wire and the production decoder in `ccd` — the same evidence
  chain as the GUI panel, minus the mouse. Tests choose per scenario; docs and
  the control-plane naming keep the distinction visible.

MK2 note: `SimulatorDeviceRuntime` currently synthesizes only MK3 natively;
the MK2 panel builds its reports inside the AppKit `PanelView`. Slice 4 moves
MK2 synthesis (buttons, encoders, 4-D, touch strip) into the runtime so both
fronts share it; until then, MK2 headless scenarios run at automation-socket
fidelity, which for MK2 is the same report vocabulary anyway.

## Implementation slices

1. **Instance paths + lock** — `SimulatorInstancePaths` with creation,
   collision, stale-reclaim, and teardown; unit tests in `SimulatorCoreTests`
   (parallel creation, busy detection, reclaim deletes only known names).
2. **Daemon controller extraction** — `SimulatorDaemonController`; GUI
   refactored onto it with unchanged behavior (menu toggles, autostart grace
   period, restart-on-automation-change). Manual GUI smoke: start/stop/
   autostart/automation toggle, Ctrl-C cleanup.
3. **`kontrol-sim-host` executable** — host loop, control plane, readiness,
   exit codes, MK3 native gestures, lamp/framebuffer endpoints, identity
   override. Integration test: launch host + owned daemon + a daemon client,
   replay a gesture scenario, assert client-visible event, lamp state, and a
   framebuffer dump; then verify no leftover processes, sockets, or lock.
   A second test runs two instances concurrently and asserts full isolation.
4. **MK2 native runtime synthesis** — move MK2 report building from
   `PanelView` into `SimulatorDeviceRuntime`; `PanelView` delegates. Raises
   MK2 headless fidelity to the native level. (Independent; can follow later.)
5. **Docs** — new section in `automation-testing.md` (headless quick start,
   fidelity guidance), `CLAUDE.md` simulator section, backlog item closure,
   and a `make sim-host` build convenience target.

Slices 1–3 deliver the backlog acceptance; 4–5 round it off. Phase 5 proper
(GUI on instance paths, mixed real/simulated topology, Paulinche composite
port) later reuses slices 1–2 unchanged.

## Acceptance (mirrors the backlog)

A script can, in one invocation each and fully in parallel with a running GUI
simulator and an untouched hardware daemon:

- launch either profile without a window or WindowServer dependency;
- wait for the `ready` event instead of sleeping;
- replay an input scenario at a chosen fidelity level;
- assert client-visible state (daemon automation/event path, display shadow
  via `kk-screenshot.py`) and device-output state (lamps, decoded
  framebuffers) including visual snapshots;
- terminate — by `quit`, SIGTERM, or SIGINT — leaving no process, socket,
  lock, or log outside the instance directory, and reclaim a stale instance
  on the next run.
