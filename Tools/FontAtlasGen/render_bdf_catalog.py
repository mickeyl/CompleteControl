#!/usr/bin/env python3
"""Render a visual BDF glyph catalog.

The output is intentionally generated from the BDF bitmaps, not from the host text
renderer, so it shows the exact pixels available to KontrolSurfaceKit.

Examples:

    python3 Tools/FontAtlasGen/render_bdf_catalog.py
    python3 Tools/FontAtlasGen/render_bdf_catalog.py --mode all --face Tamzen10x20r.bdf
"""

import argparse
import html
import json
import math
import os
import struct
import unicodedata
import urllib.request
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
FONTDIR = os.path.join(HERE, "fonts")
CACHEDIR = os.path.join(HERE, "cache")
NERD_NAMES_URL = "https://raw.githubusercontent.com/ryanoasis/nerd-fonts/master/glyphnames.json"


class Glyph:
    __slots__ = ("startchar", "encoding", "bbw", "bbh", "bbxo", "bbyo", "dwidth", "rows")

    def __init__(self):
        self.startchar = ""
        self.encoding = -1
        self.bbw = self.bbh = self.bbxo = self.bbyo = 0
        self.dwidth = 0
        self.rows = []


def parse_bdf(path):
    fbb = (0, 0, 0, 0)
    props = {}
    glyphs = {}
    glyph = None
    reading = False
    reading_props = False
    rows = []

    with open(path, errors="ignore") as fh:
        for line in fh:
            parts = line.split()
            if not parts:
                continue
            key = parts[0]
            if key == "FONTBOUNDINGBOX":
                fbb = tuple(int(x) for x in parts[1:5])
            elif key == "STARTPROPERTIES":
                reading_props = True
            elif key == "ENDPROPERTIES":
                reading_props = False
            elif reading_props and key in ("FONT_ASCENT", "FONT_DESCENT"):
                props[key] = int(parts[1])
            elif key == "STARTCHAR":
                glyph = Glyph()
                glyph.startchar = parts[1]
                rows = []
            elif key == "ENCODING":
                glyph.encoding = int(parts[1])
            elif key == "DWIDTH":
                glyph.dwidth = int(parts[1])
            elif key == "BBX":
                glyph.bbw, glyph.bbh, glyph.bbxo, glyph.bbyo = (int(x) for x in parts[1:5])
            elif key == "BITMAP":
                reading = True
                rows = []
            elif key == "ENDCHAR":
                reading = False
                glyph.rows = rows
                if glyph.encoding >= 0:
                    glyphs[glyph.encoding] = glyph
                glyph = None
            elif reading:
                rows.append(int(key, 16))
    return fbb, props, glyphs


def startchar_codepoint(startchar, fallback):
    text = startchar.upper()
    if text.startswith("U+"):
        try:
            return int(text[2:], 16)
        except ValueError:
            return fallback
    if text.startswith("U") and len(text) > 1:
        try:
            return int(text[1:], 16)
        except ValueError:
            return fallback
    return fallback


def unicode_name(codepoint):
    try:
        return unicodedata.name(chr(codepoint))
    except (ValueError, TypeError):
        return "UNNAMED"


def synthetic_startchar(startchar):
    text = startchar.upper()
    if text.startswith("UNI"):
        return all(ch in "0123456789ABCDEF" for ch in text[3:])
    if text.startswith("U"):
        return all(ch in "0123456789ABCDEF" for ch in text[1:])
    return False


def download_nerd_names(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with urllib.request.urlopen(NERD_NAMES_URL, timeout=30) as response:
        data = response.read()
    with open(path, "wb") as fh:
        fh.write(data)


def load_nerd_names(path):
    if not path or not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as fh:
        raw = json.load(fh)

    names = {}
    for name, value in raw.items():
        if not isinstance(value, dict) or "code" not in value:
            continue
        try:
            codepoint = int(value["code"], 16)
        except (TypeError, ValueError):
            continue
        names.setdefault(codepoint, []).append(name)
    return names


def glyph_name(glyph, nerd_names):
    codepoint = startchar_codepoint(glyph.startchar, glyph.encoding)
    nerd = nerd_names.get(codepoint)
    if nerd:
        return nerd[0], "nerd-fonts", nerd[1:]

    name = unicode_name(codepoint)
    if name != "UNNAMED":
        return name, "unicode", []

    if glyph.startchar and not synthetic_startchar(glyph.startchar):
        return glyph.startchar, "startchar", []

    return "UNNAMED", "", []


def is_symbolish(glyph):
    codepoint = startchar_codepoint(glyph.startchar, glyph.encoding)
    if glyph.encoding < 0x20:
        return True
    if 0x2500 <= codepoint <= 0x259F:
        return True
    if 0x2190 <= codepoint <= 0x21FF:
        return True
    if 0x2200 <= codepoint <= 0x27BF:
        return True
    if codepoint >= 0xE000:
        return True
    try:
        category = unicodedata.category(chr(codepoint))
    except ValueError:
        category = "Cn"
    return category[0] in ("P", "S")


def face_metrics(face_name, fbb, props, glyphs):
    cell_w, cell_h, _fbxo, fbyo = fbb
    ascent = cell_h + fbyo
    # Cozette uses a huge global bounding box; use its actual metrics when present.
    if props.get("FONT_ASCENT") and props.get("FONT_DESCENT") and glyphs.get(ord("?")):
        if os.path.basename(face_name).lower().startswith("cozette"):
            cell_w = glyphs[ord("?")].dwidth
            ascent = props["FONT_ASCENT"]
            cell_h = props["FONT_ASCENT"] + props["FONT_DESCENT"]
    return cell_w, cell_h, ascent


def composite(glyph, cell_w, cell_h, ascent):
    grid = [[0] * cell_w for _ in range(cell_h)]
    if glyph is None:
        return grid
    row_bytes = (glyph.bbw + 7) // 8
    top = ascent - (glyph.bbyo + glyph.bbh)
    for row in range(glyph.bbh):
        bits = glyph.rows[row] if row < len(glyph.rows) else 0
        y = top + row
        if not (0 <= y < cell_h):
            continue
        for col in range(glyph.bbw):
            if (bits >> (row_bytes * 8 - 1 - col)) & 1:
                x = glyph.bbxo + col
                if 0 <= x < cell_w:
                    grid[y][x] = 1
    return grid


def put_pixel(img, width, height, x, y, color):
    if 0 <= x < width and 0 <= y < height:
        img[y * width + x] = color


def fill_rect(img, width, height, x, y, w, h, color):
    for yy in range(y, y + h):
        if yy < 0 or yy >= height:
            continue
        base = yy * width
        for xx in range(x, x + w):
            if 0 <= xx < width:
                img[base + xx] = color


def stroke_rect(img, width, height, x, y, w, h, color):
    fill_rect(img, width, height, x, y, w, 1, color)
    fill_rect(img, width, height, x, y + h - 1, w, 1, color)
    fill_rect(img, width, height, x, y, 1, h, color)
    fill_rect(img, width, height, x + w - 1, y, 1, h, color)


def draw_glyph_bitmap(img, width, height, glyph, cell_w, cell_h, ascent, x, y, scale, color):
    grid = composite(glyph, cell_w, cell_h, ascent)
    for row, pixels in enumerate(grid):
        for col, value in enumerate(pixels):
            if value:
                fill_rect(img, width, height, x + col * scale, y + row * scale, scale, scale, color)


def draw_text(img, width, height, glyphs, cell_w, cell_h, ascent, text, x, y, color):
    fallback = glyphs.get(ord("?"))
    cursor = x
    for ch in text:
        if ch == "\t":
            cursor += cell_w * 4
            continue
        glyph = glyphs.get(ord(ch), fallback)
        draw_glyph_bitmap(img, width, height, glyph, cell_w, cell_h, ascent, cursor, y, 1, color)
        cursor += cell_w


def write_png(path, width, height, pixels):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for r, g, b in pixels[y * width:(y + 1) * width]:
            raw += bytes((r, g, b))

    def chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)


def render_catalog(font_path, glyphs, cell_w, cell_h, ascent, rows, output, nerd_names):
    scale = args.scale
    page_w = args.width
    margin = 16
    gap = 8
    columns = max(1, args.columns)
    rows_per_column = int(math.ceil(len(rows) / columns)) if rows else 0
    column_w = (page_w - 2 * margin - gap * (columns - 1)) // columns
    icon_box = max(cell_w * scale + 10, 34)
    text_offset = icon_box + 12
    line_h = max(cell_h * scale + 10, cell_h + 8)
    header_h = 58
    page_h = header_h + margin + rows_per_column * line_h + margin

    bg = (9, 10, 13)
    ink = (225, 230, 221)
    dim = (130, 138, 145)
    grid = (43, 48, 58)
    accent = (91, 166, 255)
    image = [bg] * (page_w * page_h)

    title = f"{os.path.basename(font_path)}  {args.mode.upper()}  {len(rows)} GLYPHS"
    draw_text(image, page_w, page_h, glyphs, cell_w, cell_h, ascent, title, margin, 10, accent)
    for column in range(columns):
        x = margin + column * (column_w + gap)
        draw_text(image, page_w, page_h, glyphs, cell_w, cell_h, ascent, "GLYPH", x, 34, dim)
        draw_text(image, page_w, page_h, glyphs, cell_w, cell_h, ascent, "ENC   STARTCHAR  NAME", x + text_offset, 34, dim)

    for index, glyph in enumerate(rows):
        column = index // rows_per_column if rows_per_column else 0
        row = index % rows_per_column if rows_per_column else 0
        x = margin + column * (column_w + gap)
        y = header_h + row * line_h
        codepoint = startchar_codepoint(glyph.startchar, glyph.encoding)
        name, _source, aliases = glyph_name(glyph, nerd_names)
        if aliases:
            name += f" +{len(aliases)}"
        line = f"0x{glyph.encoding:04X} {glyph.startchar:<9} {name}"
        fill_rect(image, page_w, page_h, x, y + 1, column_w, line_h - 2, (13, 15, 20))
        stroke_rect(image, page_w, page_h, x, y + 1, icon_box, line_h - 2, grid)
        icon_w = cell_w * scale
        icon_h = cell_h * scale
        icon_x = x + (icon_box - icon_w) // 2
        icon_y = y + (line_h - icon_h) // 2
        draw_glyph_bitmap(image, page_w, page_h, glyph, cell_w, cell_h, ascent, icon_x, icon_y, scale, ink)
        draw_text(image, page_w, page_h, glyphs, cell_w, cell_h, ascent, line, x + text_offset, y + (line_h - cell_h) // 2, ink)

    os.makedirs(os.path.dirname(output), exist_ok=True)
    write_png(output, page_w, page_h, image)


def write_tsv(path, rows, nerd_names):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("encoding\tstartchar\tunicode\tname\tsource\taliases\n")
        for glyph in rows:
            codepoint = startchar_codepoint(glyph.startchar, glyph.encoding)
            name, source, aliases = glyph_name(glyph, nerd_names)
            fh.write(
                f"0x{glyph.encoding:04X}\t{glyph.startchar}\tU+{codepoint:04X}\t"
                f"{name}\t{source}\t{','.join(aliases)}\n"
            )


def glyph_svg(glyph, cell_w, cell_h, ascent, scale):
    pixels = []
    grid = composite(glyph, cell_w, cell_h, ascent)
    for row, values in enumerate(grid):
        for col, value in enumerate(values):
            if value:
                pixels.append(f"M{col} {row}h1v1h-1z")
    path = "".join(pixels)
    width = cell_w * scale
    height = cell_h * scale
    return (
        f'<svg class="glyph-svg" viewBox="0 0 {cell_w} {cell_h}" '
        f'width="{width}" height="{height}" aria-hidden="true">'
        f'<path d="{path}"/></svg>'
    )


def write_html(path, font_path, rows, cell_w, cell_h, ascent, nerd_names):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    title = f"{os.path.basename(font_path)} {args.mode} glyph catalog"
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("<!doctype html>\n")
        fh.write('<html lang="en">\n<head>\n')
        fh.write('<meta charset="utf-8">\n')
        fh.write('<meta name="viewport" content="width=device-width, initial-scale=1">\n')
        fh.write(f"<title>{html.escape(title)}</title>\n")
        fh.write(
            """<style>
:root {
  color-scheme: dark;
  --bg: #090a0d;
  --panel: #0f1218;
  --line: #242a33;
  --line-strong: #3b4654;
  --text: #e1e6dd;
  --dim: #8c96a3;
  --accent: #5ba6ff;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
}
header {
  position: sticky;
  top: 0;
  z-index: 2;
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(260px, 420px);
  gap: 16px;
  align-items: end;
  padding: 14px 18px;
  background: rgba(9, 10, 13, 0.96);
  border-bottom: 1px solid var(--line-strong);
}
h1 {
  margin: 0 0 2px;
  color: var(--accent);
  font-size: 15px;
  font-weight: 700;
}
.meta { color: var(--dim); }
input {
  width: 100%;
  border: 1px solid var(--line-strong);
  border-radius: 4px;
  background: #111720;
  color: var(--text);
  padding: 8px 10px;
  font: inherit;
}
main { padding: 12px 18px 24px; }
table {
  width: 100%;
  border-collapse: collapse;
  table-layout: fixed;
}
thead th {
  position: sticky;
  top: 68px;
  z-index: 1;
  background: #0d1016;
  color: var(--dim);
  border-bottom: 1px solid var(--line-strong);
  text-align: left;
}
th, td {
  border-bottom: 1px solid var(--line);
  padding: 5px 8px;
  vertical-align: middle;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
tbody tr:hover { background: #141923; }
.glyph-col { width: 70px; }
.code-col { width: 86px; }
.start-col { width: 110px; }
.char-col { width: 74px; }
.source-col { width: 108px; }
.glyph-box {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 44px;
  height: 34px;
  border: 1px solid var(--line-strong);
  background: #090b10;
}
.glyph-box:hover {
  border-color: var(--accent);
}
.glyph-svg {
  image-rendering: pixelated;
  fill: var(--text);
}
.hover-preview {
  position: fixed;
  top: 86px;
  right: 18px;
  z-index: 5;
  display: block;
  width: 360px;
  padding: 12px;
  background: rgba(9, 10, 13, 0.97);
  border: 1px solid var(--accent);
  box-shadow: 0 16px 44px rgba(0, 0, 0, 0.58);
}
.preview-title {
  margin-bottom: 10px;
  color: var(--accent);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.preview-grid {
  position: relative;
  margin-left: auto;
  width: 300px;
  background:
    linear-gradient(to right, rgba(91, 166, 255, 0.24) 1px, transparent 1px),
    linear-gradient(to bottom, rgba(91, 166, 255, 0.24) 1px, transparent 1px),
    #05070a;
  border: 1px solid var(--line-strong);
}
.preview-grid svg {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  image-rendering: pixelated;
  fill: var(--text);
}
.native-char {
  font-size: 18px;
  color: var(--text);
}
.dim { color: var(--dim); }
.name { color: #f2f6ee; }
.aliases { color: #9cb3c7; }
tbody tr.selected {
  background: #172234;
  outline: 1px solid var(--accent);
  outline-offset: -1px;
}
tbody tr.selected:hover { background: #172234; }
@media (max-width: 820px) {
  header { grid-template-columns: 1fr; }
  thead th { top: 116px; }
  .start-col, .char-col, .source-col { width: 80px; }
  .hover-preview {
    top: 128px;
    left: 18px;
    right: 18px;
    width: auto;
  }
  .preview-grid { width: min(300px, 100%); }
}
</style>\n"""
        )
        fh.write("</head>\n<body>\n")
        fh.write("<header>\n<div>\n")
        fh.write(f"<h1>{html.escape(title)}</h1>\n")
        fh.write(
            f'<div class="meta">{len(rows)} glyphs · cell {cell_w}x{cell_h} · '
            f'names: Unicode + Nerd Fonts glyphnames.json</div>\n'
        )
        fh.write("</div>\n")
        fh.write('<input id="filter" type="search" placeholder="Filter by code, startchar, name, alias">\n')
        fh.write("</header>\n")
        fh.write(
            '<aside id="hover-preview" class="hover-preview" aria-hidden="true">'
            '<div id="preview-title" class="preview-title"></div>'
            '<div id="preview-grid" class="preview-grid"></div>'
            "</aside>\n"
        )
        fh.write("<main>\n")
        fh.write("<table id=\"glyphs\">\n<thead><tr>")
        for label, cls in (
            ("Glyph", "glyph-col"),
            ("Code", "code-col"),
            ("Unicode", "code-col"),
            ("Char", "char-col"),
            ("Startchar", "start-col"),
            ("Name", ""),
            ("Source", "source-col"),
            ("Aliases", ""),
        ):
            fh.write(f'<th class="{cls}">{html.escape(label)}</th>')
        fh.write("</tr></thead>\n<tbody>\n")

        for glyph in rows:
            codepoint = startchar_codepoint(glyph.startchar, glyph.encoding)
            name, source, aliases = glyph_name(glyph, nerd_names)
            alias_text = ", ".join(aliases)
            search = " ".join(
                [
                    f"0x{glyph.encoding:X}",
                    f"U+{codepoint:X}",
                    glyph.startchar,
                    name,
                    source,
                    alias_text,
                ]
            ).lower()
            native_char = f"&#x{codepoint:X};"
            fh.write(f'<tr data-search="{html.escape(search, quote=True)}" tabindex="-1">')
            fh.write(f'<td><span class="glyph-box">{glyph_svg(glyph, cell_w, cell_h, ascent, 2)}</span></td>')
            fh.write(f'<td>0x{glyph.encoding:04X}</td>')
            fh.write(f'<td>U+{codepoint:04X}</td>')
            fh.write(f'<td class="native-char">{native_char}</td>')
            fh.write(f'<td>{html.escape(glyph.startchar)}</td>')
            fh.write(f'<td class="name">{html.escape(name)}</td>')
            fh.write(f'<td class="dim">{html.escape(source)}</td>')
            fh.write(f'<td class="aliases">{html.escape(alias_text)}</td>')
            fh.write("</tr>\n")

        fh.write(
            """</tbody>
</table>
</main>
<script>
const input = document.getElementById("filter");
const rows = [...document.querySelectorAll("#glyphs tbody tr")];
const preview = document.getElementById("hover-preview");
const previewTitle = document.getElementById("preview-title");
const previewGrid = document.getElementById("preview-grid");
let selectedRow = null;

function visibleRows() {
  return rows.filter((row) => !row.hidden);
}

function updatePreview(row) {
  if (!row) {
    previewTitle.textContent = "No glyph selected";
    previewGrid.replaceChildren();
    return;
  }
  const box = row.querySelector(".glyph-box");
  const code = row.children[2].textContent;
  const name = row.children[5].textContent;
  const source = row.children[6].textContent;
  const sourceText = source ? ` · ${source}` : "";
  const svg = box.querySelector("svg").cloneNode(true);
  const viewBox = svg.getAttribute("viewBox").split(/\\s+/).map(Number);
  const cellW = viewBox[2] || 1;
  const cellH = viewBox[3] || 1;
  const previewW = Math.min(300, window.innerWidth - 72);
  const previewH = Math.round(previewW * cellH / cellW);
  svg.removeAttribute("width");
  svg.removeAttribute("height");
  previewTitle.textContent = `${code} · ${name}${sourceText}`;
  previewGrid.replaceChildren(svg);
  previewGrid.style.width = `${previewW}px`;
  previewGrid.style.height = `${previewH}px`;
  previewGrid.style.backgroundSize = `${previewW / cellW}px ${previewH / cellH}px`;
}

function selectRow(row, scroll) {
  if (!row || row.hidden) {
    return;
  }
  if (selectedRow) {
    selectedRow.classList.remove("selected");
    selectedRow.removeAttribute("aria-selected");
  }
  selectedRow = row;
  selectedRow.classList.add("selected");
  selectedRow.setAttribute("aria-selected", "true");
  updatePreview(selectedRow);
  if (scroll) {
    selectedRow.scrollIntoView({ block: "nearest" });
  }
}

input.addEventListener("input", () => {
  const needle = input.value.trim().toLowerCase();
  for (const row of rows) {
    row.hidden = needle && !row.dataset.search.includes(needle);
  }
  if (!selectedRow || selectedRow.hidden) {
    selectRow(visibleRows()[0], false);
  } else {
    updatePreview(selectedRow);
  }
});

for (const row of rows) {
  row.addEventListener("click", () => selectRow(row, false));
}

document.addEventListener("keydown", (event) => {
  if (event.metaKey || event.altKey || event.ctrlKey) {
    return;
  }
  if (event.key !== "ArrowDown" && event.key !== "ArrowUp") {
    return;
  }
  const candidates = visibleRows();
  if (!candidates.length) {
    updatePreview(null);
    return;
  }
  event.preventDefault();
  const currentIndex = Math.max(0, candidates.indexOf(selectedRow));
  const direction = event.key === "ArrowDown" ? 1 : -1;
  const nextIndex = Math.min(candidates.length - 1, Math.max(0, currentIndex + direction));
  selectRow(candidates[nextIndex], true);
});

window.addEventListener("resize", () => updatePreview(selectedRow));
selectRow(visibleRows()[0], false);
</script>
</body>
</html>
"""
        )


def parse_codepoint(text):
    value = text.strip().lower()
    if value.startswith("u+"):
        return int(value[2:], 16)
    if value.startswith("0x"):
        return int(value[2:], 16)
    return int(value, 10)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--face", default="Tamzen8x16r.bdf", help="BDF filename under Tools/FontAtlasGen/fonts")
parser.add_argument("--mode", choices=("symbols", "all"), default="symbols")
parser.add_argument("--output", default="", help="PNG output path")
parser.add_argument("--tsv", default="", help="Optional TSV output path; defaults beside PNG")
parser.add_argument("--html", default="", help="Optional searchable HTML table output path")
parser.add_argument("--no-png", action="store_true", help="Skip PNG rendering")
parser.add_argument("--from", dest="from_cp", default="", help="Minimum Unicode codepoint, e.g. U+E000 or 0x2500")
parser.add_argument("--to", dest="to_cp", default="", help="Maximum Unicode codepoint, inclusive")
parser.add_argument("--width", type=int, default=940)
parser.add_argument("--scale", type=int, default=2)
parser.add_argument("--columns", type=int, default=1)
parser.add_argument(
    "--name-source",
    default=os.path.join(CACHEDIR, "nerd-fonts-glyphnames.json"),
    help="Optional Nerd Fonts glyphnames.json source for PUA icon names",
)
parser.add_argument(
    "--download-nerd-names",
    action="store_true",
    help="Download/update Nerd Fonts glyphnames.json before rendering",
)
args = parser.parse_args()

if args.download_nerd_names:
    download_nerd_names(args.name_source)
nerd_names = load_nerd_names(args.name_source)

font_path = os.path.join(FONTDIR, args.face)
fbb, props, glyphs = parse_bdf(font_path)
cell_w, cell_h, ascent = face_metrics(args.face, fbb, props, glyphs)

rows = [glyphs[encoding] for encoding in sorted(glyphs)]
if args.mode == "symbols":
    rows = [glyph for glyph in rows if is_symbolish(glyph)]
if args.from_cp:
    minimum = parse_codepoint(args.from_cp)
    rows = [glyph for glyph in rows if startchar_codepoint(glyph.startchar, glyph.encoding) >= minimum]
if args.to_cp:
    maximum = parse_codepoint(args.to_cp)
    rows = [glyph for glyph in rows if startchar_codepoint(glyph.startchar, glyph.encoding) <= maximum]

stem = os.path.splitext(os.path.basename(args.face))[0].lower()
output = args.output or os.path.join(HERE, "out", f"{stem}-{args.mode}.png")
tsv = args.tsv or os.path.splitext(output)[0] + ".tsv"
if not args.no_png:
    render_catalog(font_path, glyphs, cell_w, cell_h, ascent, rows, output, nerd_names)
write_tsv(tsv, rows, nerd_names)
if args.html:
    write_html(args.html, font_path, rows, cell_w, cell_h, ascent, nerd_names)
if not args.no_png:
    print(f"rendered {len(rows)} rows -> {output}")
print(f"wrote {tsv}")
if args.html:
    print(f"wrote {args.html}")
if nerd_names:
    print(f"loaded {sum(len(names) for names in nerd_names.values())} Nerd Fonts names from {args.name_source}")
elif args.name_source:
    print(f"no Nerd Fonts names loaded from {args.name_source}")
