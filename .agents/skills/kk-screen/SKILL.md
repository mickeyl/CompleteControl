---
name: kk-screen
description: Capture live screenshots of the Komplete Kontrol MK2 hardware or simulator displays through the running ccd daemon, or push PNG previews onto them (bench A/B comparisons). Use when the user invokes "$kk-screen" or "kk-screen", asks what is currently shown on the KK screens, wants to verify hardware-surface rendering, or asks to show an image/comparison on the panel. Accept A/left/0 for the left display, B/right/1 for the right display, and default to both.
---

# Komplete Kontrol screen capture and preview

Capture what the hardware or simulator screens currently show, or push PNG
previews onto them — both without disturbing the connected client. The
helpers talk the daemon's binary protocol over unregistered out-of-band
connections.

## Capture workflow (read direction)

1. Map the requested display to `--screen`:
   - `A`, `left`, or `0`: `--screen 0`
   - `B`, `right`, or `1`: `--screen 1`
   - No display selection: `--screen both`
2. Resolve this selected `SKILL.md`'s directory and run its bundled helper:

   ```bash
   <skill-directory>/scripts/capture.sh --screen <selection>
   ```

   Replace `<skill-directory>` with the actual directory containing this
   `SKILL.md`. The helper locates the CompleteControl repository independently
   of the current working directory and checkout path.
3. Use the image-inspection tool available in the current host to inspect the
   PNG paths printed by the helper. In Codex, call `view_image`; in Claude Code,
   use its image-capable `Read` tool. Prefer `/tmp/kk-screens/kk-screens.png`
   when both displays were captured.
4. Describe or verify the visible content in the context of the user's task.

## Preview workflow (write direction)

Push one or two PNGs to the physical displays, e.g. for bench A/B
comparisons (established convention: variant A on the left display,
variant B on the right):

```bash
<skill-directory>/scripts/display.sh a.png b.png            # two 480x272 PNGs → screens 0 and 1
<skill-directory>/scripts/display.sh canvas.png             # 960x272 or 961x272 dual canvas, split at the seam
<skill-directory>/scripts/display.sh single.png --screen 1  # one 480x272 PNG on one screen
```

The preview persists only while the helper holds its display connection —
closing the last display connection makes the daemon repaint its idle
surface. The default `--hold 120` keeps it standing for two minutes;
pass a longer `--hold <seconds>` for bench rounds (run in the background
and kill the process to release early), or `--hold 0` to fire and forget
when a registered client owns the displays anyway. A connected client's
next repaint overwrites the preview at any time — this is a preview, not
a takeover. Verify what is actually showing with the capture workflow.

## Socket resolution

Both helpers resolve the daemon socket in this order: `KK_DAEMON_SOCKET`, the
hardware socket `/var/run/kompletekontrol-libusb.sock`, then the simulator
socket `/tmp/kontrol-simulator-daemon.sock`. Capture writes
`kk-screen-0.png`, `kk-screen-1.png`, and, for both displays, the combined
`kk-screens.png` under `/tmp/kk-screens/`.

## Failure modes

- `no reachable daemon socket`: report that ccd is not running and suggest
  starting it.
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
