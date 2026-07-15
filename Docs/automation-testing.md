# Test-Automation Input Injection — How To Test

This walks through verifying the automation socket (`CCD_ENABLE_AUTOMATION`) end to end,
from a bare smoke test up to driving a real running Paulinche instance. All paths here are
safe to run alongside a separately running production/hardware daemon — none of them touch
the default socket (`/var/run/kompletekontrol-libusb.sock`) or send `pkill`.

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

Scripts/kk-input.py --socket /tmp/kk-smoke.sock.automation help
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

## 2. Full loop: simulator + a real Paulinche instance

This is the actual "virtual remote control" scenario — driving a live Paulinche window
purely through synthetic hardware input, on an isolated socket pair.

1. Enable the toggle once (persists across launches):

   ```bash
   swift build --product KontrolSimulator --product ccd
   .build/debug/KontrolSimulator -KontrolSimulator.daemon.autostart YES -KontrolSimulator.daemon.automationEnabled YES &
   ```

   Or, if you'd rather use the GUI: launch `make run-simulator`, then in the **Daemon** menu
   check both **Autostart Daemon If Not Running** and **Enable Test-Automation Socket**, then
   **Start Simulator Daemon**. Both checkboxes persist for next time.

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

## 3. Full loop against real hardware

Only once the currently running long-term test daemon is intentionally stopped. Add
`CCD_ENABLE_AUTOMATION=1` to whatever starts it:

- **Manual foreground run**: `sudo env CCD_ENABLE_AUTOMATION=1 KK_MK2_DISPLAY_ENCODING=adaptive /path/to/ccd --kk-libusb-daemon /var/run/kompletekontrol-libusb.sock`
- **Installed LaunchDaemon**: add an `EnvironmentVariables` dict with `CCD_ENABLE_AUTOMATION=1`
  to `/Library/LaunchDaemons/media.vanille.kompletekontrol-libusb.plist`, then
  `make daemon-restart`.

Then run Paulinche normally (`make run`, no `KK_DAEMON_SOCKET` override needed — it'll find
the hardware daemon by default) and drive it with `Scripts/kk-input.py` against
`/var/run/kompletekontrol-libusb.sock.automation`.

## Known caveat

Injected button/encoder/4-D state and real hardware state are tracked in *separate*
`MK2InputReportBuilder` snapshots. If you inject input while a person is also physically
touching the keyboard at the same time, a client's press/release diff can look wrong (e.g. a
physically-held button appearing to "release" because the injected snapshot doesn't know it's
held). Fine for scripted tests run alone; don't mix live human input with automation input in
the same session.
