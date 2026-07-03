#!/usr/bin/env python3
"""BDF -> packed Swift glyph atlas for KontrolSurfaceKit2.

Offline, run-rarely generator (plan decision: checked-in atlas, not a build plugin).
Each face is composited into a fixed cell (baseline-aligned per the BDF bounding box),
packed MSB-first at ceil(cellWidth/8) bytes per row, and emitted as a base64 blob so the
generated Swift compiles instantly instead of carrying multi-thousand-element literals.

Regenerate after adding/updating a face:

    python3 generate.py

stdlib only. Output overwrites Sources/KontrolSurfaceKit2/Fonts/TamzenAtlas.generated.swift.
"""

import base64
import os

HERE = os.path.dirname(os.path.abspath(__file__))
FONTDIR = os.path.join(HERE, "fonts")
OUT = os.path.normpath(os.path.join(
    HERE, "..", "..", "Sources", "KontrolSurfaceKit2", "Fonts", "TamzenAtlas.generated.swift"))

# Codepoint window baked into every face. ASCII printable + Latin-1 supplement (umlauts,
# ß, etc.). Uniform range keeps runtime lookup a single subtraction.
FIRST_CP = 0x20
LAST_CP = 0xFF
FALLBACK_CP = ord("?")

# role name -> (bdf file, swift static name, metric strategy)
FACES = [
    ("Tamzen8x16r.bdf",  "grid", "fontBoundingBox"),
    ("Tamzen8x16b.bdf",  "gridBold", "fontBoundingBox"),
    ("Cozette.bdf",      "label", "dwidthAscentDescent"),
    ("Tamzen10x20r.bdf", "readout", "fontBoundingBox"),
    ("Tamzen10x20b.bdf", "readoutBold", "fontBoundingBox"),
]


class Glyph:
    __slots__ = ("bbw", "bbh", "bbxo", "bbyo", "dwidth", "rows")


def parse_bdf(path):
    """Return (fbb, props, {codepoint: Glyph}). Mirrors render_mocks.py's parser."""
    fbb = (0, 0, 0, 0)
    props = {}
    glyphs = {}
    g = None
    enc = None
    reading = False
    reading_props = False
    rows = []
    with open(path, errors="ignore") as fh:
        for line in fh:
            q = line.split()
            if not q:
                continue
            k = q[0]
            if k == "FONTBOUNDINGBOX":
                fbb = tuple(int(x) for x in q[1:5])
            elif k == "STARTPROPERTIES":
                reading_props = True
            elif k == "ENDPROPERTIES":
                reading_props = False
            elif reading_props and k in ("FONT_ASCENT", "FONT_DESCENT"):
                props[k] = int(q[1])
            elif k == "STARTCHAR":
                g = Glyph()
                g.bbw = g.bbh = g.bbxo = g.bbyo = 0
                g.dwidth = 0
                rows = []
            elif k == "ENCODING":
                enc = int(q[1])
            elif k == "DWIDTH":
                g.dwidth = int(q[1])
            elif k == "BBX":
                g.bbw, g.bbh, g.bbxo, g.bbyo = (int(x) for x in q[1:5])
            elif k == "BITMAP":
                reading = True
                rows = []
            elif k == "ENDCHAR":
                reading = False
                g.rows = rows
                if enc is not None and enc >= 0:
                    glyphs[enc] = g
                g = None
                enc = None
            elif reading:
                rows.append(int(k, 16))
    return fbb, props, glyphs


def composite(glyph, cell_w, cell_h, ascent):
    """Rasterize one glyph into a cell_h x cell_w bit grid (top-relative), MSB-first
    packed to ceil(cell_w/8) bytes per row. Returns the packed bytes."""
    bpr = (cell_w + 7) // 8
    grid = [0] * cell_h  # one integer of cell_w bits per row, bit (cell_w-1-x)
    if glyph is not None:
        rb = (glyph.bbw + 7) // 8
        top = ascent - (glyph.bbyo + glyph.bbh)
        for r in range(glyph.bbh):
            v = glyph.rows[r] if r < len(glyph.rows) else 0
            out_y = top + r
            if not (0 <= out_y < cell_h):
                continue
            for c in range(glyph.bbw):
                if (v >> (rb * 8 - 1 - c)) & 1:
                    out_x = glyph.bbxo + c
                    if 0 <= out_x < cell_w:
                        grid[out_y] |= 1 << (cell_w - 1 - out_x)
    out = bytearray()
    for row in grid:
        for b in range(bpr):
            shift = (bpr - 1 - b) * 8
            out.append((row >> shift) & 0xFF)
    return bytes(out)


def build_face(path, metric_strategy):
    fbb, props, glyphs = parse_bdf(path)
    cell_w, cell_h, _fbxo, fbyo = fbb
    ascent = cell_h + fbyo  # top-relative baseline row
    if metric_strategy == "dwidthAscentDescent":
        fallback = glyphs.get(FALLBACK_CP)
        if fallback is None:
            raise ValueError(f"{path} does not contain fallback glyph {FALLBACK_CP}")
        cell_w = fallback.dwidth
        ascent = props.get("FONT_ASCENT", ascent)
        descent = props.get("FONT_DESCENT", max(0, cell_h - ascent))
        cell_h = ascent + descent
    bpr = (cell_w + 7) // 8
    fallback = glyphs.get(FALLBACK_CP)
    blob = bytearray()
    covered = 0
    for cp in range(FIRST_CP, LAST_CP + 1):
        g = glyphs.get(cp)
        if g is not None:
            covered += 1
        elif cp == 0x20:
            g = None  # space is intentionally blank even if the BDF omits it
        else:
            g = fallback  # missing glyph renders the '?' fallback
        blob += composite(g, cell_w, cell_h, ascent)
    return {
        "advance": cell_w,
        "cellHeight": cell_h,
        "ascent": ascent,
        "bytesPerRow": bpr,
        "glyphCount": LAST_CP - FIRST_CP + 1,
        "covered": covered,
        "blob": bytes(blob),
    }


def emit(faces):
    lines = []
    lines.append("// Generated by Tools/FontAtlasGen/generate.py — do not edit by hand.")
    lines.append("// Source: vendored BDFs (see Tools/FontAtlasGen/fonts/NOTICE.md).")
    lines.append("//")
    lines.append("// Each face is a fixed-cell bitmap atlas for codepoints "
                 f"0x{FIRST_CP:02X}…0x{LAST_CP:02X}, packed MSB-first at bytesPerRow bytes")
    lines.append("// per row. Missing glyphs in range fall back to '?'; 0x20 stays blank.")
    lines.append("")
    lines.append("enum TamzenAtlas {")
    lines.append("    struct Face {")
    lines.append("        let advance: Int")
    lines.append("        let cellHeight: Int")
    lines.append("        let ascent: Int")
    lines.append("        let bytesPerRow: Int")
    lines.append("        let firstCodepoint: Int")
    lines.append("        let glyphCount: Int")
    lines.append("        let bitmapBase64: String")
    lines.append("    }")
    lines.append("")
    for _path, name, _metric_strategy in faces:
        f = faces_data[name]
        b64 = base64.b64encode(f["blob"]).decode("ascii")
        lines.append(f"    static let {name} = Face(")
        lines.append(f"        advance: {f['advance']},")
        lines.append(f"        cellHeight: {f['cellHeight']},")
        lines.append(f"        ascent: {f['ascent']},")
        lines.append(f"        bytesPerRow: {f['bytesPerRow']},")
        lines.append(f"        firstCodepoint: {FIRST_CP},")
        lines.append(f"        glyphCount: {f['glyphCount']},")
        lines.append(f"        bitmapBase64: \"{b64}\")")
        lines.append("")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


faces_data = {}
for path, name, metric_strategy in FACES:
    faces_data[name] = build_face(os.path.join(FONTDIR, path), metric_strategy)
    d = faces_data[name]
    print(f"{name:12} cell {d['advance']}x{d['cellHeight']} ascent {d['ascent']} "
          f"bpr {d['bytesPerRow']} covered {d['covered']}/{d['glyphCount']} "
          f"blob {len(d['blob'])}B")

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as fh:
    fh.write(emit(FACES))
print(f"wrote {OUT}")
