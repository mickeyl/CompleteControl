# Test-Automation Input Injection — How To Test

This walks through verifying the automation socket (`CCD_ENABLE_AUTOMATION`) end to end,
from a bare smoke test up to driving a real running Paulinche instance. The smoke-test and
simulator paths are safe to run alongside a separately running production/hardware daemon:
they use isolated sockets and never send `pkill`. The real-hardware section is intentionally
separate and must only be used after stopping the long-running test daemon.

**Do not use `make daemon`, `make daemon-debug`, or `make daemon-simulate` for any of this**
while another `ccd`/`ccd-trace` process is running — those targets unconditionally
`sudo pkill -f 'kk-libusb-daemon'` before starting, which kills *any* daemon process
regardless of socket path, including one you didn't mean to touch.

## 1. Quick smoke test (no GUI, no Paulinche)

Confirms the daemon, the opt-in gate, and `kk-input.py` work, using only a throwaway socket.

```bash
swift build --product ccd
rm -f /tmp/kk-smoke.sock*
CCD_ENABLE_AUTOMATION=1 CCD_SIMULATE=/tmp/kk-smoke-sim.sock \
  .build/debug/ccd --kk-libusb-daemon /tmp/kk-smoke.sock &

ls -la /tmp/kk-smoke.sock.automation   # expect: srw-rw-rw- (0666)

Scripts/kk-input.py --socket /tmp/kk-smoke.sock.automation button play down
Scripts/kk-input.py --socket /tmp/kk-smoke.sock.automation button play up

kill %1   # stop the smoke daemon
rm -f /tmp/kk-smoke.sock*
```

`CCD_SIMULATE` points at a socket nothing is listening on — the daemon logs
`simulator not present` and retries in the background, which is fine: the automation
socket doesn't need a working device session at all, only the daemon process itself.

Without `CCD_ENABLE_AUTOMATION` set, repeat the same command and confirm
`/tmp/kk-smoke.sock.automation` never appears.

## 2. `kk-input` CLI and interactive REPL

Run `kk-input` without a command to open its readline-based REPL:

```bash
make kk-input
# Equivalent: Scripts/kk-input.py
```

The REPL keeps one daemon connection open and provides line editing, arrow-key and reverse
history search, and grammar-aware Tab completion. Completion covers automation commands,
every MK2 button name, encoder indices, button/touch states, 4-D actions, and local commands.

Local REPL commands:

| Command | Purpose |
| --- | --- |
| `help [command]` | Show the command catalogue or one command's syntax. |
| `history [count]` | Show recent persistent history entries. |
| `status` | Show the current connection state and automation socket. |
| `reconnect` | Rediscover the socket and establish a fresh connection. |
| `clear` | Clear an interactive terminal. |
| `quit` / `exit` | Close the connection and leave the REPL; Ctrl-D does the same. |

Ctrl-C cancels the current input line. If it interrupts a daemon request, `kk-input` closes the
connection instead of retrying: the input gesture may already have reached a client. Run
`reconnect` before sending another command.

History defaults to `$XDG_STATE_HOME/kk-input/history`, normally
`~/.local/state/kk-input/history`. Use `--history-file PATH`, `--history-size COUNT`, or
`--no-history` to change that behavior. The history file is created with mode `0600`.

### Socket selection

`kk-input` resolves the automation socket in this order:

1. `--socket PATH` (a daemon base path or its `.automation` path).
2. The daemon base path in `KK_DAEMON_SOCKET`.
3. The hardware daemon at `/var/run/kompletekontrol-libusb.sock`.
4. The simulator daemon at `/tmp/kontrol-simulator-daemon.sock`.

When a hardware daemon and simulator daemon may both be active, always select the intended one
explicitly. For example:

```bash
KK_DAEMON_SOCKET=/tmp/kontrol-simulator-daemon.sock make kk-input
```

### One-shot, script, and pipe modes

The original one-shot and script interfaces remain available, and flags can appear before or
after a command:

```bash
Scripts/kk-input.py --socket /tmp/kk-test.sock button play down
Scripts/kk-input.py button play up --socket /tmp/kk-test.sock --plain
Scripts/kk-input.py --script scenario.txt
Scripts/kk-input.py --script - < scenario.txt
printf 'button play down\nbutton play up\n' | Scripts/kk-input.py
```

Script and stdin modes skip blank lines and lines beginning with `#`. Successful responses go
to stdout; connection, I/O, and daemon-command errors go to stderr. By default batch output
includes the command (`button play down -> ok`); `--plain` prints only the daemon response.

Exit statuses are stable for automation scripts:

| Status | Meaning |
| --- | --- |
| `0` | Every command succeeded. |
| `1` | The daemon rejected at least one command. |
| `2` | Invalid CLI usage. |
| `3` | Socket discovery, connection, or response failure. |
| `4` | Local I/O failure, such as an unreadable script or unavailable readline module. |

Use `Scripts/kk-input.py --help` for all options, `Scripts/kk-input.py help <command>` for one
command's syntax, and `Scripts/kk-input.py --version` for the CLI version.

## 3. Full loop: simulator + a real Paulinche instance

This is the actual "virtual remote control" scenario — driving a live Paulinche window
purely through synthetic hardware input, on an isolated socket pair.

1. Enable the toggle once (persists across launches):

   ```bash
   swift build --product KontrolSimulator --product ccd
   .build/debug/KontrolSimulator -KontrolSimulator.daemon.autostart YES -KontrolSimulator.daemon.automationEnabled YES &
   ```

   Add `--device maschine-mk3` to use the MK3 profile, or launch the GUI with
   `make run-simulator` (KONTROL) / `make run-mk3-simulator` (MASCHINE). In the
   **Daemon** menu check both **Autostart Daemon If Not Running** and **Enable
   Test-Automation Socket**. Both checkboxes persist for next time. Changing the
   automation setting restarts a simulator-owned daemon while autostart is
   enabled; an externally launched daemon must be restarted by its owner.
   KONTROL and MASCHINE currently share this default endpoint, so run only one
   profile at a time until instance-scoped mixed topology is implemented.

2. Confirm the simulator's own daemon is up on its own socket (not the hardware default):

   ```bash
   cat /tmp/kontrol-simulator-daemon.log   # "listening control/event/display/automation"
   ls -la /tmp/kontrol-simulator-daemon.sock.automation   # srw-rw-rw-
   ```

3. Launch Paulinche pointed **explicitly** at that socket — never rely on Paulinche's default
   resolution here, or it may find and register on a real hardware daemon instead:

   ```bash
   cd /path/to/Paulinche
   swift build --product PaulincheApp   # or `make build`
   KK_DAEMON_SOCKET=/tmp/kontrol-simulator-daemon.sock .build/Paulinche.app/Contents/MacOS/Paulinche &
   ```

   Watch for `control surface connected - K25/S25 surface online` in its log
   (`LOGLEVEL=TRACE` for full detail, including every `control event received: ...` line).

4. Drive it:

   ```bash
   cd /path/to/CompleteControl
   KK_DAEMON_SOCKET=/tmp/kontrol-simulator-daemon.sock make kk-input
   # Pin the simulator socket so an active hardware daemon can never be selected instead.
   # Use Tab completion; type `help` for commands and `quit` when finished.

   # One-shot commands remain available for scripts:
   Scripts/kk-input.py --socket /tmp/kontrol-simulator-daemon.sock.automation button play down
   Scripts/kk-input.py --socket /tmp/kontrol-simulator-daemon.sock.automation button play up
   # ... playback is now running in the real Paulinche window ...
   Scripts/kk-input.py --socket /tmp/kontrol-simulator-daemon.sock.automation button stop down
   Scripts/kk-input.py --socket /tmp/kontrol-simulator-daemon.sock.automation button stop up
   ```

   `Scripts/kk-screenshot.py --socket /tmp/kontrol-simulator-daemon.sock` grabs what the two
   hardware displays show at any point, for visual/pixel-level assertions.

5. Clean up: quit Paulinche, quit KontrolSimulator (its spawned `ccd` child exits with it), and
   remove the `/tmp/kontrol-simulator*` socket/log files if you want a clean slate.

## 4. Complete Widget Lab smoke, stress, and soak tests

`widget-lab-test.py` launches its own `widget-lab` client, drives actual hardware input
through the daemon's automation socket, and reads the daemon's completed display shadow out of
band. It never starts, stops, restarts, or reconfigures the daemon. The simulator daemon must
already be running with automation enabled as described in section 3.

First validate the catalogue without a daemon. This fails whenever a registered Widget Lab demo
has no scenario, or the manifest references a removed demo:

```bash
make widget-lab-test-validate
```

Then run the normal-use sweep. Every demo is opened, allowed to present its baseline scene, driven
through its real bindings, and checked pixel-for-pixel on both 480×272 displays:

```bash
make widget-lab-smoke
# Equivalent:
Scripts/widget-lab-test.py smoke --socket /tmp/kontrol-simulator-daemon.sock
```

The more aggressive profiles remove the per-scene baseline barrier, accelerate actions, shuffle
the demo order from a recorded seed, and take periodic snapshots:

```bash
make widget-lab-stress                        # 15 minutes
make widget-lab-soak                          # 8 hours

WIDGET_LAB_STRESS_DURATION=30m make widget-lab-stress
WIDGET_LAB_SOAK_DURATION=24h make widget-lab-soak

Scripts/widget-lab-test.py stress --cycles 100 --burst 3 --seed 42
Scripts/widget-lab-test.py soak --duration 8h --snapshot-interval 1m --seed 42
```

`--burst` repeats the external input sequence for ordinary demos. The display benchmark remains
one serialized scenario per catalogue pass because it already performs 12 alternating updates per
fixture and temporarily owns the daemon-wide display-measurement session.

Use `WIDGET_LAB_TEST_SOCKET` to select another simulator daemon and `WIDGET_LAB_TEST_ARGS` for
additional CLI flags. Physical hardware is refused unless the direct CLI is given both its socket
and `--hardware`; the Make targets intentionally default to the simulator socket.

Each run writes `report.json`, the Widget Lab stderr log, expected PNG/RGB565 frames, and—on a
mismatch—actual PNGs plus red diff images. Progress goes to stderr; `--json` emits the final report
on stdout. Ctrl-C stops only the runner-owned Widget Lab process and leaves the daemon untouched.

### Adaptive versus legacy

For a transport comparison, run the same fixed workload twice. Restart the simulator-owned daemon
between runs with the requested `KK_MK2_DISPLAY_ENCODING`; the test tool deliberately does not
change that setting itself.

```bash
# Daemon currently started with adaptive encoding:
Scripts/widget-lab-test.py soak --cycles 1000 --burst 3 --seed 42 \
  --output /tmp/widgetlab-adaptive

# Restart the simulator daemon with legacy encoding, then run the identical workload:
Scripts/widget-lab-test.py soak --cycles 1000 --burst 3 --seed 42 \
  --output /tmp/widgetlab-legacy

make widget-lab-compare \
  ADAPTIVE_REPORT=/tmp/widgetlab-adaptive/report.json \
  LEGACY_REPORT=/tmp/widgetlab-legacy/report.json
```

The comparison requires matching seed, action count, and scenario count. Both runs must have zero
snapshot and transport failures; adaptive must stay within the configured latency threshold and
must not use more bytes than legacy. Use fixed `--cycles`, rather than equal wall-clock durations,
when a byte-for-byte workload comparison matters.

The exact live check compares the Widget Lab's logical RGB565 frame with the daemon shadow after a
display barrier. This verifies client rendering, diffing, completed daemon writes, and transport
health. It does not optically read back a physical OLED. On the GUI simulator it also does not
capture the panel's post-wire decoded pixels; the headless host's `framebuffer` command
(section 5) provides exactly that view for automation, while codec round-trip tests remain the
wire-decoder check inside the test suite.

### Why the Widget Lab REPL remains

The REPL remains the operator/fixture plane: it opens demos, establishes deterministic visual
fixtures, runs the display benchmark, and overrides LEDs or the light guide. `kk-input` and the test
runner use the actual input plane. `--control-stdin` is a JSON-Lines protocol used only for
catalogue discovery, deterministic setup, state queries, and expected snapshots; it never injects
user actions directly.

## 5. Headless simulator host (`kontrol-sim-host`)

For deterministic end-to-end automation without AppKit, a window, or a WindowServer
session, `kontrol-sim-host` replaces the GUI simulator + Daemon menu with one CLI
invocation. Every run is isolated by construction: all sockets, logs, and locks live in
`/tmp/kksim-<instance>/`, which is disjoint from the GUI simulator's global paths and
invisible to client auto-discovery — parallel runs, a running GUI simulator, and a live
hardware daemon can never collide. The host never consults `UserDefaults`.

```bash
make sim-host             # MK3 profile, owned daemon, automation socket
# Equivalent:
swift build --product ccd --product kontrol-sim-host
.build/debug/kontrol-sim-host --device maschine-mk3 --automation --instance ci-42
```

The control plane is JSON Lines on stdin/stdout. Scripts wait for the `ready` event
instead of sleeping; it carries all paths a client needs:

```json
{"event":"ready","device":"maschine-mk3","instance":"ci-42",
 "deviceSocket":"/tmp/kksim-ci-42/device.sock",
 "daemonSocket":"/tmp/kksim-ci-42/daemon.sock",
 "automationSocket":"/tmp/kksim-ci-42/daemon.sock.automation",
 "clientEnv":{"KK_DAEMON_SOCKET":"/tmp/kksim-ci-42/daemon.sock"}}
```

With `--own-daemon`/`--automation` the `ready` event is emitted only after the owned
daemon completed the device handshake, so the daemon sockets are guaranteed to be
listening. `daemonConnected`/`daemonDisconnected` events report the live link state.

Commands (each answered with `{"ok":true,...}` or `{"ok":false,"error":...}`; an `id`
field is echoed back for correlation):

| Command | Purpose |
| --- | --- |
| `{"cmd":"gesture","gesture":"button","button":"play","pressed":true}` | Native MK3 input synthesis through the production decoder. Also: `encoder` (index 0-8, delta), `encoderTouch`, `strip` (finger 1-2, position or null), `padTouch`/`padStrike`/`padPressure`/`padRelease` (pad 1-16), `releaseAll`. |
| `{"cmd":"lamps"}` | Reduced device-output state as hex strings (buttons, strip/pads, light guide). |
| `{"cmd":"framebuffer","display":0,"format":"png","path":"/tmp/a.png"}` | Post-wire decoded panel pixels; always returns width/height and a `sha256` of the raw RGB565 for cheap assertions, `path`/`format` (`png`/`rgb565`) are optional. |
| `{"cmd":"identity","firmware":"1.4.6","name":"…"}` | Runtime identity override, like the GUI dialog but without defaults persistence. |
| `{"cmd":"status"}` | Connection state and instance paths. |
| `{"cmd":"quit"}` | Clean shutdown; stdin EOF, SIGTERM, and SIGINT do the same. |

The two input fidelity levels stay explicit: `gesture` is native-report synthesis (the
profile-validation plane, MASCHINE MK3); the daemon automation socket
(`kk-input.py --socket /tmp/kksim-<id>/daemon.sock.automation`) is the semantic
application-scenario plane and currently the only plane for KONTROL MK2, whose panel
still speaks semantic frames on the simulator wire.

Exit codes are a stable contract: `0` clean shutdown, `64` usage, `69` instance busy
(a live host holds the same `--instance`), `71` device-socket bind failure, `72` daemon
start failure, `73` owned daemon exited unexpectedly. Shutdown escalates a
non-responding owned daemon to SIGKILL after a grace period and removes the instance
directory; a stale directory from a killed host is reclaimed on the next acquire.

`Scripts/kk-screenshot.py --socket /tmp/kksim-<id>/daemon.sock` still reads the daemon's
display shadow (completed daemon writes); the `framebuffer` command complements it with
what actually survived the simulator wire and decode. The end-to-end regression lives in
`Tests/KompleteKontrolTests/KontrolSimHostIntegrationTests.swift`.

## 6. Full loop against real hardware

Only once the currently running long-term test daemon is intentionally stopped. Add
`CCD_ENABLE_AUTOMATION=1` to whatever starts it:

- **Manual foreground run**: `sudo env CCD_ENABLE_AUTOMATION=1 KK_MK2_DISPLAY_ENCODING=adaptive /path/to/ccd --kk-libusb-daemon /var/run/kompletekontrol-libusb.sock`
- **Installed LaunchDaemon**: add an `EnvironmentVariables` dict with `CCD_ENABLE_AUTOMATION=1`
  to `/Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist`, then
  `make daemon-restart`.

Then run Paulinche normally (`make run`, no `KK_DAEMON_SOCKET` override needed — it'll find
the hardware daemon by default) and drive it with `make kk-input`. The CLI selects the hardware
automation socket before the simulator socket unless `KK_DAEMON_SOCKET` overrides it.

## Known caveat

Injected button/encoder/4-D state and real hardware state are tracked in *separate*
`MK2InputReportBuilder` snapshots. If you inject input while a person is also physically
touching the keyboard at the same time, a client's press/release diff can look wrong (e.g. a
physically-held button appearing to "release" because the injected snapshot doesn't know it's
held). Fine for scripted tests run alone; don't mix live human input with automation input in
the same session.
