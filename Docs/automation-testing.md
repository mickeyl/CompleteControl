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

ls -la /tmp/kk-smoke.sock.automation   # expect: srw------- (0600)

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

   Or, if you'd rather use the GUI: launch `make run-simulator`, then in the **Daemon** menu
   check both **Autostart Daemon If Not Running** and **Enable Test-Automation Socket**. Both
   checkboxes persist for next time. Changing the automation setting restarts a simulator-owned
   daemon while autostart is enabled; an externally launched daemon must be restarted by its owner.

2. Confirm the simulator's own daemon is up on its own socket (not the hardware default):

   ```bash
   cat /tmp/kontrol-simulator-daemon.log   # "listening control/event/display/automation"
   ls -la /tmp/kontrol-simulator-daemon.sock.automation   # srw-------
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

## 4. Full loop against real hardware

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
