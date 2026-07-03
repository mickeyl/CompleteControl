# Vendored fonts

These BDF bitmap fonts are the source for the MK2 widget font atlas. The offline
generator (`../generate.py`) compiles them into a packed Swift glyph atlas
(`Sources/KontrolSurfaceKit2/Fonts/TamzenAtlas.generated.swift`). The generated atlas
is what ships and runs; these BDFs are build-time input only, checked in so the atlas
is reproducible offline.

## Cozette

- Files: `Cozette.bdf`
- Source: local candidate from `~/Downloads/cozette.bdf` for MK2 label-style evaluation.
- Copyright: `(c) 2020-2025 Ines <ines@moonwit.ch>` as recorded in the BDF.
- License: MIT.

## Tamzen

- Files: `Tamzen8x16r.bdf`, `Tamzen8x16b.bdf`, `Tamzen6x12r.bdf`, `Tamzen10x20r.bdf`, `Tamzen10x20b.bdf`
- Source: https://github.com/sunaku/tamzen-font (a fork of Tamsyn by Scott Fial,
  http://www.fial.com/~scott/tamsyn-font/)
- License: permissive — free to use, copy, modify, and distribute. See the upstream
  `LICENSE` for the exact wording.

To regenerate the atlas after adding or updating a face, run `python3 generate.py`
from this tool's directory.
