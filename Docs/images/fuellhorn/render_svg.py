"""Fuellhorn reference screens as one editable vector SVG.

The PNG renderers (render.py / render2.py) stay the pixel-exact truth for the
panels; this sibling re-emits the same ten screens as real vectors — text as
<text> with family/weight, shading as <linearGradient> — laid out on a
contact-sheet canvas, so the design can be edited in a vector app (Affinity
opens the file directly). Deliberately NOT dithered or RGB565-quantized:
this is the editable master, the panel look comes from the export pipeline.

PIL is used only for text metrics, so SVG baselines and the per-character
tracking positions match the PNG renderers' top-anchored layout.
"""
from PIL import ImageFont
import numpy as np, os, html

BASE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.join(BASE, '../../../Sources/KontrolSurfaceKit2/Resources/Fonts')

FONT_FILES = {
    ('plex', 500): 'IBMPlexSansCondensed-Medium.otf',
    ('plex', 400): 'IBMPlexSansCondensed-Regular.otf',
    ('mono', 400): 'JetBrainsMono-Regular.ttf',
    ('mono', 700): 'JetBrainsMono-Bold.ttf',
    ('phosphor', 400): 'Phosphor.ttf',
}
FAMILY = {'plex': 'IBM Plex Sans Condensed', 'mono': 'JetBrains Mono', 'phosphor': 'Phosphor'}
_font_cache = {}

def pil_font(kind, weight, size):
    key = (kind, weight, size)
    if key not in _font_cache:
        _font_cache[key] = ImageFont.truetype(f'{FONTS}/{FONT_FILES[(kind, weight)]}', size)
    return _font_cache[key]

def ascent(kind, weight, size):
    return pil_font(kind, weight, size).getmetrics()[0]

def text_length(kind, weight, size, text):
    return pil_font(kind, weight, size).getlength(text)

W, H = 480, 272
PAPER, DIM, FAINT = (242, 246, 255), (138, 147, 168), (74, 80, 96)
TEAL, ULTRA, VIOLET = (43, 217, 200), (92, 120, 255), (155, 107, 255)
MAGENTA, LIME, TANGERINE = (255, 79, 163), (184, 230, 46), (255, 138, 43)

def shade(c, f):
    return tuple(min(255, int(v * f)) for v in c)

def rgb(c):
    return f'rgb({c[0]},{c[1]},{c[2]})'

class Screen:
    """Collects SVG elements for one 480x272 screen."""
    def __init__(self, name):
        self.name = name
        self.parts = []
        self.gradients = []
        self._gradient_seq = 0

    def rect(self, x0, y0, x1, y1, fill):
        self.parts.append(
            f'<rect x="{x0}" y="{y0}" width="{max(0, x1 - x0)}" height="{max(0, y1 - y0)}" fill="{rgb(fill)}"/>')

    def text(self, x, y, s, kind, weight, size, fill, letter_spacing=None):
        baseline = y + ascent(kind, weight, size)
        spacing = f' letter-spacing="{letter_spacing}"' if letter_spacing is not None else ''
        self.parts.append(
            f'<text x="{x}" y="{baseline}" font-family="{FAMILY[kind]}" font-weight="{weight}" '
            f'font-size="{size}" fill="{rgb(fill)}"{spacing}>{html.escape(s)}</text>')

    def caps(self, x, y, s, kind, weight, size, fill, tracking=2):
        # PIL's caps() advances per character by glyph width + tracking; SVG
        # letter-spacing adds the same gap after every glyph.
        self.text(x, y, s, kind, weight, size, fill, letter_spacing=tracking)
        return x + text_length(kind, weight, size, s) + tracking * len(s)

    def tint(self, x0, y0, x1, y1, hue, top, bottom, horizontal=False):
        """The renderers' hue->black shading as a linear gradient rect. All
        tints are painted onto black before their content, so plain paint
        order replaces the renderers' lighten blend exactly."""
        self._gradient_seq += 1
        gid = f'{self.name}-g{self._gradient_seq}'
        x2, y2 = ('100%', '0%') if horizontal else ('0%', '100%')
        self.gradients.append(
            f'<linearGradient id="{gid}" x1="0%" y1="0%" x2="{x2}" y2="{y2}">'
            f'<stop offset="0%" stop-color="{rgb(shade(hue, top))}"/>'
            f'<stop offset="100%" stop-color="{rgb(shade(hue, bottom))}"/></linearGradient>')
        self.parts.append(
            f'<rect x="{x0}" y="{y0}" width="{max(0, x1 - x0)}" height="{max(0, y1 - y0)}" fill="url(#{gid})"/>')

    def line(self, points, stroke, width):
        pts = ' '.join(f'{x},{y}' for x, y in points)
        self.parts.append(
            f'<polyline points="{pts}" fill="none" stroke="{rgb(stroke)}" stroke-width="{width}"/>')

    def polygon_gradient(self, points, hue, top, bottom, y0, y1):
        self._gradient_seq += 1
        gid = f'{self.name}-g{self._gradient_seq}'
        self.gradients.append(
            f'<linearGradient id="{gid}" x1="0" y1="{y0}" x2="0" y2="{y1}" gradientUnits="userSpaceOnUse">'
            f'<stop offset="0%" stop-color="{rgb(shade(hue, top))}"/>'
            f'<stop offset="100%" stop-color="{rgb(shade(hue, bottom))}"/></linearGradient>')
        pts = ' '.join(f'{x},{y}' for x, y in points)
        self.parts.append(f'<polygon points="{pts}" fill="url(#{gid})"/>')

    def zone_title(self, title, hue, meta=None):
        self.caps(10, 8, title, 'plex', 500, 20, PAPER, 1)
        if meta:
            w = text_length('mono', 400, 10, meta)
            self.text(W - 10 - w, 14, meta, 'mono', 400, 10, shade(hue, 0.9))

    def knob_row(self, items, hue, y=None):
        y = H - 46 if y is None else y
        slot = W // len(items)
        for i, (label, value, focus) in enumerate(items):
            x = i * slot + 12
            col = hue if not isinstance(hue, list) else hue[i]
            self.rect(x, y, x + 22, y + 2, col if focus else shade(col, 0.45))
            self.caps(x, y + 5, label, 'mono', 400, 9, shade(col, 0.95) if focus else DIM, 2)
            self.text(x, y + 18, value, 'mono', 700, 17, PAPER if focus else shade(PAPER, 0.62))

# ---------------------------------------------------------------- 1 BROWSE
def browse():
    s = Screen('browse')
    s.tint(0, 0, W, 60, TEAL, 0.22, 0.0)
    s.zone_title('BROWSE', TEAL, 'FACTORY · 10/48')
    kinds = {'INST': MAGENTA, 'SMPL': TEAL, 'PROJ': LIME}
    rows = [('Piano Noir', 'INST', 'felt grand, intimate release'),
            ('Kick Resin', 'SMPL', 'round transient, analogue tail'),
            ('Tape Strings', 'INST', 'warm ensemble, slow attack'),
            ('Halcyon Sky', 'PROJ', '124 BPM · 8 patterns')]
    y, sel = 44, 1
    for i, (name, kind, det) in enumerate(rows):
        col = kinds[kind]
        if i == sel:
            s.tint(0, y, W, y + 40, TEAL, 0.30, 0.08)
            s.rect(0, y, 2, y + 39, col)
        s.text(14, y + 2, name, 'plex', 500, 17, PAPER if i == sel else shade(PAPER, 0.66))
        s.text(14, y + 23, det, 'plex', 400, 12, DIM if i == sel else FAINT)
        s.caps(424, y + 5, kind, 'mono', 400, 9, col if i == sel else shade(col, 0.55), 1)
        y += 42
    s.knob_row([('FILTER', 'ALL', True), ('SORT', 'A–Z', False), ('BANK', 'FACT', False), ('PREVIEW', 'ON', False)], TEAL)
    return s

# ---------------------------------------------------------------- 2 PATTERN
def pattern():
    s = Screen('pattern')
    chans = [('KICK', ULTRA), ('BASS', VIOLET), ('LEAD', MAGENTA), ('HATS', TEAL)]
    s.zone_title('PAT 04', ULTRA, 'ROW 12 · SPD 6 · PLAY')
    gx, gy, cw, rh = 34, 40, 108, 17
    for c, (name, col) in enumerate(chans):
        s.caps(gx + c * cw + 4 + 26, gy, name, 'mono', 400, 9, col, 2)
    rows = ['C-3 01 A08', '... .. ...', 'D#3 05 ...', '... .. ...', 'G-4 03 C40', '... .. ...', 'F-3 01 047', 'A-3 09 E90']
    for r in range(11):
        y = gy + 16 + r * rh
        absr = 8 + r
        if absr == 12:
            s.tint(gx - 24, y - 1, W - 8, y + rh - 2, LIME, 0.20, 0.20)
            s.rect(gx - 24, y - 1, gx - 22, y + rh - 3, LIME)
        s.text(gx - 24 + 2, y, f'{absr:02X}', 'mono', 400, 11,
               PAPER if absr == 12 else (DIM if absr % 4 == 0 else FAINT))
        for c, (name, col) in enumerate(chans):
            cell = rows[(r + c * 2) % len(rows)]
            empty = cell.startswith('...')
            s.text(gx + c * cw + 6, y, cell, 'mono', 400, 11,
                   (shade(col, 1.0) if absr != 12 else PAPER) if not empty else FAINT)
    return s

# ---------------------------------------------------------------- 3 INSTRUMENT
def instrument():
    s = Screen('instrument')
    s.tint(0, 0, W, 84, MAGENTA, 0.24, 0.0)
    s.caps(10, 6, 'INSTRUMENT 01', 'mono', 400, 9, shade(MAGENTA, 0.95), 3)
    s.text(8, 18, 'Piano Noir', 'plex', 500, 34, PAPER)
    s.text(10, 58, 'Muted felt grand with intimate release', 'plex', 400, 13, DIM)
    xs = np.linspace(0, 1, 300)
    env = np.minimum(xs / 0.08, 1.0) * np.exp(-(xs - 0.08).clip(0) / 0.42)
    pts = [(70 + int(x * 340), 190 - int(e * 84)) for x, e in zip(xs, env)]
    poly = pts + [(410, 190), (70, 190)]
    s.polygon_gradient(poly, MAGENTA, 0.30, 0.075, 94, 190)
    s.line(pts, MAGENTA, 2)
    s.caps(70, 196, 'ENVELOPE · AMP', 'mono', 400, 9, DIM, 3)
    s.knob_row([('ATTACK', '8ms', False), ('DECAY', '420ms', True), ('SUSTAIN', '62%', False), ('RELEASE', '1.3s', False)], MAGENTA)
    return s

# ---------------------------------------------------------------- 4 MIX
def mix():
    s = Screen('mix')
    chans = [('KICK', ULTRA, 0.78, 0.86), ('BASS', VIOLET, 0.64, 0.7), ('LEAD', MAGENTA, 0.88, 1.0), ('HATS', TEAL, 0.5, 0.55)]
    s.zone_title('MIX', LIME, 'MASTER −4.8 dB')
    for i, (name, col, lvl, pk) in enumerate(chans):
        mx0, my0, mw, mh = 24 + i * 116, 52, 84, 150
        s.tint(mx0, my0, mx0 + mw, my0 + mh, col, 0.05, 0.02)
        top = my0 + int(mh * (1 - lvl))
        s.tint(mx0, top, mx0 + mw, my0 + mh, col, 0.95, 0.25)
        if pk >= 1.0:
            s.rect(mx0, my0, mx0 + mw, my0 + 6, TANGERINE)
        else:
            py = my0 + int(mh * (1 - pk))
            s.rect(mx0, py, mx0 + mw, py + 1, PAPER)
        s.caps(mx0, my0 + mh + 8, name, 'mono', 400, 10, col, 3)
        s.text(mx0, my0 + mh + 22, f'{(lvl * 60 - 54):+.1f}', 'mono', 700, 15, PAPER if pk >= 1.0 else shade(PAPER, 0.7))
    s.caps(24 + 2 * 116, 30, 'CLIP', 'mono', 400, 9, TANGERINE, 2)
    return s

# ---------------------------------------------------------------- 5 DIALOG
def dialog():
    s = Screen('dialog')
    s.tint(0, 0, W, H, TANGERINE, 0.10, 0.0)
    s.text(14, 24, '', 'phosphor', 400, 30, TANGERINE)
    s.caps(58, 24, 'CLEAR PATTERN', 'mono', 400, 10, shade(TANGERINE, 0.95), 3)
    s.text(56, 38, 'Really clear pattern 04?', 'plex', 500, 26, PAPER)
    y = 118
    for i, (t, det) in enumerate([('Yes, clear', 'pattern 04 will be emptied'),
                                  ('Clear all patterns', 'the whole song will be emptied')]):
        if i == 0:
            s.tint(44, y - 4, W - 44, y + 40, TANGERINE, 0.30, 0.10)
            s.rect(44, y - 4, 46, y + 39, TANGERINE)
        s.text(58, y, t, 'plex', 500, 18, PAPER if i == 0 else shade(PAPER, 0.6))
        s.text(58, y + 22, det, 'plex', 400, 12, DIM if i == 0 else FAINT)
        y += 56
    s.text(14, H - 22, '4-D confirms — any other button cancels.', 'plex', 400, 12, DIM)
    return s

# ---------------------------------------------------------------- 6 SAMPLE
def sample():
    s = Screen('sample')
    s.zone_title('KICK RESIN', TEAL, '127.6 ms · 24 BIT')
    rng = np.random.default_rng(7)
    n = 210
    envel = np.exp(-np.linspace(0, 4.2, n)) + 0.04
    wave = envel * (0.65 * np.sin(np.linspace(0, 34, n)) + 0.35 * rng.standard_normal(n))
    cx0, cy, ch_ = 16, 118, 64
    loop0, loop1 = 90, 168
    s.tint(cx0 + loop0 * 2, cy - ch_, cx0 + loop1 * 2, cy + ch_, VIOLET, 0.16, 0.16)
    for i, v in enumerate(wave):
        x = cx0 + i * 2
        h2 = max(1, int(abs(v) * ch_))
        f = 0.35 + 0.65 * abs(v)
        inloop = loop0 <= i < loop1
        s.rect(x, cy - h2, x + 2, cy + h2, shade(VIOLET if inloop else TEAL, min(1.0, f)))
    for lx, lab in ((loop0, 'S'), (loop1, 'E')):
        x = cx0 + lx * 2
        s.rect(x, cy - ch_ - 8, x + 1, cy + ch_, LIME)
        s.text(x + 3, cy - ch_ - 10, lab, 'mono', 700, 9, LIME)
    s.caps(16, cy + ch_ + 8, 'LOOP 42% – 88% · VIOLET FIELD = REGION', 'mono', 400, 9, DIM, 2)
    s.knob_row([('START', '42%', False), ('END', '88%', True), ('XFADE', '64', False), ('LOOP', 'ON', False)], VIOLET)
    return s

# ---------------------------------------------------------------- 7 PERFORM
def perform():
    s = Screen('perform')
    s.tint(0, 0, W, int(H * 0.75), LIME, 0.20, 0.0)
    s.caps(10, 8, 'PERFORM', 'plex', 500, 20, PAPER, 1)
    s.text(W - 10 - 70, 14, '· PLAY', 'mono', 400, 10, shade(LIME, 0.95))
    s.caps(14, 52, 'TEMPO', 'mono', 400, 10, shade(LIME, 0.95), 4)
    s.text(8, 58, '124.0', 'mono', 700, 78, PAPER)
    s.text(252, 116, 'BPM', 'plex', 400, 15, DIM)
    s.caps(300, 52, 'POSITION', 'mono', 400, 10, DIM, 3)
    s.text(298, 66, 'BAR 17', 'mono', 700, 26, shade(PAPER, 0.85))
    s.text(298, 98, '1:1:1', 'mono', 400, 15, DIM)
    s.caps(300, 130, 'SWING 54% · GRID 1/16', 'mono', 400, 9, DIM, 1)
    s.knob_row([('TEMPO', '124.0', True), ('SWING', '54%', False), ('METRO', 'ON', False), ('COUNT', '1BAR', False)], LIME)
    return s

# ---------------------------------------------------------------- 8 SONG
def song():
    s = Screen('song')
    s.tint(0, 0, W, int(H * 0.62), ULTRA, 0.24, 0.0)
    s.caps(10, 6, 'SONG · 8 PATTERNS · 3:24', 'mono', 400, 9, shade(ULTRA, 0.95), 3)
    s.text(8, 16, 'Halcyon Sky', 'plex', 500, 36, PAPER)
    s.text(10, 60, '124 BPM · A-major · last saved 12:03', 'plex', 400, 13, DIM)
    cols = [ULTRA, VIOLET, MAGENTA, TEAL]
    seq = [0, 0, 1, 2, 1, 3, 2, 0]
    x0, y0, bw, bh = 16, 108, 54, 44
    for i, pi in enumerate(seq):
        x = x0 + i * (bw + 3)
        col = cols[pi]
        f = 0.9 if i == 4 else 0.42
        s.rect(x, y0, x + bw, y0 + bh, shade(col, min(1.0, 0.16 * f * 4)))
        s.rect(x, y0, x + bw, y0 + 3, shade(col, f))
        s.text(x + 4, y0 + 8, f'P{pi + 1}', 'mono', 700, 13, PAPER if i == 4 else shade(PAPER, 0.6))
        s.text(x + 4, y0 + 26, '16', 'mono', 400, 10, DIM if i == 4 else FAINT)
    s.rect(x0 + 4 * (bw + 3) - 2, y0 - 6, x0 + 4 * (bw + 3) - 1, y0 + bh + 6, LIME)
    s.caps(16, y0 + bh + 14, 'POSITION 5/8 · LOOP OFF', 'mono', 400, 9, DIM, 2)
    s.knob_row([('SECTION', '5', True), ('LENGTH', '16', False), ('LOOP', 'OFF', False), ('FOLLOW', 'ON', False)], ULTRA)
    return s

# ---------------------------------------------------------------- 9 KEY MODE
def keymode():
    s = Screen('keymode')
    s.tint(0, 0, W, H, VIOLET, 0.30, 0.0)
    s.caps(10, 8, 'KEY MODE — HELD', 'mono', 400, 10, shade(VIOLET, 0.95), 3)
    s.text(6, 26, 'C2', 'plex', 500, 96, PAPER)
    s.text(150, 64, 'root octave', 'plex', 400, 17, DIM)
    s.text(150, 88, 'chromatic pads C2–D#3', 'plex', 400, 13, FAINT)
    slots = ['OCT 0', 'OCT 1', 'OCT 2', 'OCT 3', 'OCT 4', 'OCT 5', 'OCT 6', 'OCT 7']
    sel = 2
    sw = W // 8
    for i, slot in enumerate(slots):
        x = i * sw
        if i == sel:
            s.rect(x + 3, H - 96, x + sw - 3, H - 72, VIOLET)
            s.text(x + 8, H - 92, slot, 'mono', 700, 11, (16, 8, 30))
        else:
            s.text(x + 8, H - 92, slot, 'mono', 400, 11, DIM)
        s.rect(x + 3, H - 70, x + sw - 3, H - 69, shade(VIOLET, 0.9 if i == sel else 0.3))
    s.text(10, H - 46, 'F1–F8 choose · new notes use the range immediately', 'plex', 400, 12, DIM)
    s.text(10, H - 26, 'release KEY MODE to return', 'plex', 400, 12, FAINT)
    return s

# ---------------------------------------------------------------- 10 MASTER
def master():
    s = Screen('master')
    s.tint(0, 0, W, int(H * 0.8), TEAL, 0.22, 0.0)
    s.caps(10, 8, 'MASTER', 'plex', 500, 20, PAPER, 1)
    s.text(W - 10 - 88, 14, 'LIMIT OFF', 'mono', 400, 10, shade(TEAL, 0.95))
    s.text(4, 44, '-4.8', 'mono', 700, 86, PAPER)
    s.text(218, 108, 'dBFS', 'plex', 400, 16, DIM)
    s.caps(300, 52, 'PEAK HOLD', 'mono', 400, 9, DIM, 3)
    s.text(298, 64, '-1.2', 'mono', 700, 24, shade(PAPER, 0.85))
    s.caps(300, 100, 'RMS', 'mono', 400, 9, DIM, 3)
    s.text(298, 112, '-11.6', 'mono', 700, 24, shade(PAPER, 0.85))
    lv, y = 0.72, 170
    s.rect(16, y, 16 + int(448 * lv), y + 8, shade(TEAL, 0.9))
    s.rect(16 + int(448 * lv), y, 16 + int(448 * lv) + 1, y + 8, PAPER)
    s.rect(16 + int(448 * 0.92), y - 3, 16 + int(448 * 0.92) + 1, y + 11, TANGERINE)
    s.caps(16, y + 14, '0 dB MARK TANGERINE · PEAK WHITE', 'mono', 400, 9, FAINT, 2)
    s.knob_row([('GAIN', '0.0dB', True), ('LIMIT', 'OFF', False), ('WIDTH', '100%', False), ('DC', 'ON', False)], TEAL)
    return s

# ---------------------------------------------------------------- assemble
SHEETS = [('1 Browse', browse), ('2 Pattern', pattern), ('3 Instrument', instrument),
          ('4 Mix', mix), ('5 Dialog', dialog), ('6 Sample', sample),
          ('7 Perform', perform), ('8 Song', song), ('9 Key Mode', keymode), ('10 Master', master)]

MARGIN, GAP_X, GAP_Y, LABEL_H = 30, 30, 46, 22
COLS = 2
rows_needed = (len(SHEETS) + COLS - 1) // COLS
DOC_W = MARGIN * 2 + COLS * W + (COLS - 1) * GAP_X
DOC_H = MARGIN * 2 + 26 + rows_needed * (H + LABEL_H + GAP_Y)

defs, groups = [], []
for index, (label, fn) in enumerate(SHEETS):
    screen = fn()
    x = MARGIN + (index % COLS) * (W + GAP_X)
    y = MARGIN + 26 + (index // COLS) * (H + LABEL_H + GAP_Y)
    defs.extend(screen.gradients)
    body = '\n    '.join(screen.parts)
    groups.append(f'''  <text x="{x}" y="{y + 14}" font-family="{FAMILY['mono']}" font-weight="400" font-size="12" fill="rgb(180,186,200)">{html.escape(label.upper())} — 480×272</text>
  <g id="{screen.name}" transform="translate({x},{y + LABEL_H})" clip-path="url(#panel)">
    <rect x="0" y="0" width="{W}" height="{H}" fill="black"/>
    {body}
  </g>''')

svg = f'''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="{DOC_W}" height="{DOC_H}" viewBox="0 0 {DOC_W} {DOC_H}">
  <defs>
    <clipPath id="panel"><rect x="0" y="0" width="{W}" height="{H}"/></clipPath>
    {'''
    '''.join(defs)}
  </defs>
  <rect width="{DOC_W}" height="{DOC_H}" fill="rgb(24,24,24)"/>
  <text x="{MARGIN}" y="{MARGIN - 8}" font-family="{FAMILY['plex']}" font-weight="400" font-size="14" fill="rgb(215,215,215)">FUELLHORN — editable vector master (undithered; the panel look comes from the RGB565 export pipeline)</text>
{chr(10).join(groups)}
</svg>
'''
out = f'{BASE}/fh-screens.svg'
with open(out, 'w') as handle:
    handle.write(svg)
print(f'wrote {out} ({DOC_W}x{DOC_H}, {len(SHEETS)} screens)')
