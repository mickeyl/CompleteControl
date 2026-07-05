# CompleteControl Backlog

## Daemon / libusb architecture

- Revisit the daemon's libusb architecture for MK2 idle and client operation. Display,
  MIDI, surface input, button LEDs, and light guide sit on separate USB interfaces/endpoints,
  but the daemon currently owns them through one device session and one reactor-adjacent
  scheduling model. This can still let slow display work interfere with time-sensitive
  MIDI/light-guide diagnostics even though the hardware endpoints are separate.
- Investigate the least risky path first: keep one libusb device handle, but strictly
  separate the event pump, display blits, and small state reports so MIDI and light-guide
  updates are never queued behind display frames. The NO CLIENT hardware-test mode is a
  good stress case because chords can expose stuck light-guide states.
- Longer-term experiments: dedicated libusb contexts/threads per function class, or
  separate handles for separately claimed interfaces if macOS/libusb behaves cleanly.
  Treat multiple handles as a research item, not the default design, because composite
  USB claiming, shutdown, and reconnect semantics can get fragile.
- Also evaluate whether selected paths should bypass libusb: CoreMIDI for MIDI and IOHID
  for HID-style surface traffic may reduce contention, while MK2 display/custom bulk
  traffic probably remains libusb/IOUSB-level. Avoid mixed backends unless claim conflicts
  and ownership boundaries are understood.

## KontrolSurfaceKit2

- Done: FreeType font rendering is available through `KontrolSurfaceKit2` and
  `MK2FreeTypeDemo` for large, well-hinted typography. The production text choice is
  IBM Plex Sans Condensed Regular 16 px for body and Medium 24 px for titles, rendered
  with `grayscaleHinted`. Icon work uses Font Awesome 7 Pro Light, with 48 px icons for
  action dialogs. The bitmap-font rendering path remains separate for tracker/grid sharpness.
