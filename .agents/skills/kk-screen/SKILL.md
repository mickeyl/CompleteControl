---
name: kk-screen
description: Capture and inspect live screenshots of the Komplete Kontrol MK2 hardware or simulator displays through the running ccd daemon. Use when the user invokes "$kk-screen" or "kk-screen", asks what is currently shown on the KK screens, or wants to verify hardware-surface rendering. Accept A/left/0 for the left display, B/right/1 for the right display, and default to both.
---

# Komplete Kontrol screen capture

Capture what the hardware or simulator screens currently show without
disturbing the connected client. The screenshot helper reads the daemon's
display shadow over an unregistered control connection.

## Workflow

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

The helper resolves the daemon socket in this order: `KK_DAEMON_SOCKET`, the
hardware socket `/var/run/kompletekontrol-libusb.sock`, then the simulator
socket `/tmp/kontrol-simulator-daemon.sock`. It normally writes
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
