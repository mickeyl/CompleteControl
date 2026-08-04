---
name: kk-screen
description: Capture live screenshots of the KOMPLETE KONTROL MK2 and MASCHINE MK3 displays through the running product-bound ccd daemons, or push PNG previews onto them (bench A/B comparisons). Use when the user invokes "$kk-screen" or "kk-screen", asks what is currently shown on the KK or MASCHINE screens, wants to verify hardware-surface rendering, or asks to show an image/comparison on a panel. Optional device argument — kontrol/kk/mk2 or maschine/mk3, default all connected devices. Optional screen argument — A/left/0 for the left display, B/right/1 for the right, default both.
---

# KONTROL + MASCHINE screen capture and preview

Capture what the hardware or simulator screens currently show, or push PNG
previews onto them — both without disturbing the connected client. The
helpers talk the daemon's binary protocol over unregistered out-of-band
connections. Since dual operation there is one product-bound daemon per
surface; the device argument selects which one(s) to talk to.

## Capture workflow (read direction)

1. Map the requested device to `--device`:
   - `kontrol`, `kk`, or `mk2`: `--device kontrol`
   - `maschine` or `mk3`: `--device maschine`
   - No device selection: `--device all` (every reachable surface)
2. Map the requested display to `--screen`:
   - `A`, `left`, or `0`: `--screen 0`
   - `B`, `right`, or `1`: `--screen 1`
   - No display selection: `--screen both`
3. Resolve this selected `SKILL.md`'s directory and run its bundled helper:

   ```bash
   <skill-directory>/scripts/capture.sh --device <device> --screen <selection>
   ```

   Replace `<skill-directory>` with the actual directory containing this
   `SKILL.md`. The helper locates the CompleteControl repository independently
   of the current working directory and checkout path.
4. Use the image-inspection tool available in the current host to inspect the
   PNG paths printed by the helper. In Codex, call `view_image`; in Claude Code,
   use its image-capable `Read` tool. Prefer `/tmp/kk-screens/kk-fleet.png`
   (labeled contact sheet, KONTROL row above MASCHINE row) when several
   devices were captured, otherwise the per-device combined image
   (`kontrol.png` / `maschine.png`).
5. Describe or verify the visible content in the context of the user's task.
   In `all` mode an unreachable surface is reported as `<device>: offline` and
   simply skipped — mention it, it is state the user cares about.

## Preview workflow (write direction)

Push one or two PNGs to the physical displays of **one** device, e.g. for
bench A/B comparisons (established convention: variant A on the left display,
variant B on the right):

```bash
<skill-directory>/scripts/display.sh a.png b.png --device kontrol   # two 480x272 PNGs → screens 0 and 1
<skill-directory>/scripts/display.sh canvas.png --device mk3        # 960x272 or 961x272 dual canvas, split at the seam
<skill-directory>/scripts/display.sh single.png --screen 1          # one 480x272 PNG on one screen (KONTROL slot default)
```

A preview belongs on one deliberately chosen surface — `--device all` is
refused. Without `--device` the historical KONTROL-slot resolution applies.

The preview persists only while the helper holds its display connection —
closing the last display connection makes the daemon repaint its idle
surface. The default `--hold 120` keeps it standing for two minutes;
pass a longer `--hold <seconds>` for bench rounds (run in the background
and kill the process to release early), or `--hold 0` to fire and forget
when a registered client owns the displays anyway. A connected client's
next repaint overwrites the preview at any time — this is a preview, not
a takeover. Verify what is actually showing with the capture workflow.

## Socket resolution and output files

- `--device kontrol` keeps the historical resolution: `KK_DAEMON_SOCKET`,
  then the hardware socket `/var/run/kompletekontrol-libusb.sock`, then the
  simulator socket `/tmp/kontrol-simulator-daemon.sock`. Output:
  `kontrol-0.png`, `kontrol-1.png`, combined `kontrol.png`.
- `--device maschine` talks to exactly
  `/var/run/kompletekontrol-maschine.sock` (composite setups address exact
  endpoints, never discovery). Output: `maschine-0.png`, `maschine-1.png`,
  combined `maschine.png`.
- `--device all` captures both and, when both screens of several devices were
  grabbed, additionally writes the labeled `kk-fleet.png` contact sheet.
- Without `--device` (legacy single-daemon invocation) the old names remain:
  `kk-screen-0.png`, `kk-screen-1.png`, `kk-screens.png`.

All files land under `/tmp/kk-screens/` unless `--out` overrides it.

## Failure modes

- `<device> daemon is not reachable`: that product-bound ccd is not running;
  suggest starting it (`sudo launchctl kickstart -k
  system/media.vanille.kompletekontrol-libusb` or
  `…kompletekontrol-maschine`).
- `No device daemon is reachable` (all mode): no ccd at all; suggest
  `make install-daemon` or starting the launchd services.
- `predates displaySnapshot support`: report that the daemon must be rebuilt
  with `swift build` in CompleteControl and restarted with sudo. Ask the user
  to perform the privileged restart.
- `no frame recorded for screen N`: report that nothing has been drawn to that
  display since the daemon started; its shadow becomes available after the
  first display write.
- `Pushing images needs Pillow`: the preview helper decodes PNGs with PIL;
  suggest `python3 -m pip install pillow`.
- Preview vanishes immediately: the daemon is in NO CLIENT mode and the hold
  ended or the helper exited — repeat with a longer `--hold`.
