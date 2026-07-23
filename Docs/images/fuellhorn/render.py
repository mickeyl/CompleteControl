"""Fuellhorn greenfield design exploration: six 480x272 screens, zero chrome
bands, zone hue coding + editorial typography, all shading Bayer-dithered and
RGB565-quantized so the panels show exactly this."""
from PIL import Image, ImageDraw, ImageFont
import numpy as np, os

BASE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../../Sources/KontrolSurfaceKit2/Resources/Fonts')
def F(name, size): return ImageFont.truetype(f'{FONTS}/{name}', size)
plex_m   = lambda s: F('IBMPlexSansCondensed-Medium.otf', s)
plex_r   = lambda s: F('IBMPlexSansCondensed-Regular.otf', s)
mono_r   = lambda s: F('JetBrainsMono-Regular.ttf', s)
mono_b   = lambda s: F('JetBrainsMono-Bold.ttf', s)
phosphor = lambda s: F('Phosphor.ttf', s)

W, H = 480, 272
PAPER, DIM, FAINT = (242,246,255), (138,147,168), (74,80,96)
TEAL, ULTRA, VIOLET = (43,217,200), (92,120,255), (155,107,255)
MAGENTA, LIME, TANGERINE = (255,79,163), (184,230,46), (255,138,43)
CORAL = (255,90,90)

def shade(c, f):
    return tuple(min(255, int(v*f)) for v in c)

def screen():
    img = Image.new('RGB', (W,H), (0,0,0))
    return img, ImageDraw.Draw(img)

def tint_field(img, x0, y0, x1, y1, hue, top=0.30, bottom=0.04, horizontal=False):
    """Vertical (or horizontal) hue->black shading, float; dithered at export."""
    h_, w_ = y1-y0, x1-x0
    if h_ <= 0 or w_ <= 0: return
    t = np.linspace(top, bottom, w_ if horizontal else h_)[None,:] if horizontal else np.linspace(top, bottom, h_)[:,None]
    field = (np.array(hue)[None,None,:] * t[:,:,None]) if not horizontal else (np.array(hue)[None,None,:] * t[:,:,None].transpose(1,0,2))
    a = np.asarray(img).astype(np.float64)
    region = a[y0:y1, x0:x1, :]
    a[y0:y1, x0:x1, :] = np.maximum(region, field if not horizontal else field.transpose(1,0,2)[:h_,:w_,:])
    img.paste(Image.fromarray(np.clip(a,0,255).astype(np.uint8)), (0,0))

def caps(d, x, y, text, font, fill, tracking=2):
    for ch in text:
        d.text((x, y), ch, font=font, fill=fill)
        x += d.textlength(ch, font=font) + tracking
    return x

BAYER = (np.array([[0,8,2,10],[12,4,14,6],[3,11,1,9],[15,7,13,5]])+0.5)/16.0
def quantize565(img):
    a = np.asarray(img).astype(np.float64)
    th = np.tile(BAYER, (H//4, W//4))
    out = np.empty_like(a)
    for ch, levels in ((0,32),(1,64),(2,32)):
        v = a[:,:,ch]/255.0*(levels-1)
        q = np.floor(v + th)
        q = np.clip(q, 0, levels-1)
        out[:,:,ch] = np.round(q*255.0/(levels-1))
    return Image.fromarray(out.astype(np.uint8))

def zone_title(d, title, hue, meta=None):
    caps(d, 10, 8, title, plex_m(20), PAPER, 1)
    if meta:
        w = d.textlength(meta, font=mono_r(10))
        d.text((W-10-w, 14), meta, font=mono_r(10), fill=shade(hue, 0.9))

def knob_row(img, d, items, hue, y=None):
    """Minimum-chrome encoder row: color tick, tracked caps label, big mono value."""
    y = H-46 if y is None else y
    slot = W//len(items)
    for i,(label, value, focus) in enumerate(items):
        x = i*slot + 12
        col = hue if not isinstance(hue, list) else hue[i]
        d.rectangle((x, y, x+22, y+1), fill=col if focus else shade(col,0.45))
        caps(d, x, y+5, label, mono_r(9), shade(col, 0.95) if focus else DIM, 2)
        d.text((x, y+18), value, font=mono_b(17), fill=PAPER if focus else shade(PAPER,0.62))

# ---------------------------------------------------------------- 1 BROWSE
def browse():
    img, d = screen()
    tint_field(img, 0, 0, W, 60, TEAL, 0.22, 0.0)
    d = ImageDraw.Draw(img)
    zone_title(d, 'BROWSE', TEAL, 'FACTORY · 10/48')
    kinds = {'INST': MAGENTA, 'SMPL': TEAL, 'PROJ': LIME}
    rows = [('Piano Noir','INST','felt grand, intimate release'),
            ('Kick Resin','SMPL','round transient, analogue tail'),
            ('Tape Strings','INST','warm ensemble, slow attack'),
            ('Halcyon Sky','PROJ','124 BPM · 8 patterns'),
            ]
    y, sel = 44, 1
    for i,(name, kind, det) in enumerate(rows):
        col = kinds[kind]
        if i == sel:
            tint_field(img, 0, y, W, y+40, TEAL, 0.30, 0.08)
            d = ImageDraw.Draw(img)
            d.rectangle((0, y, 2, y+39), fill=col)
        d.text((14, y+2), name, font=plex_m(17), fill=PAPER if i==sel else shade(PAPER,0.66))
        d.text((14, y+23), det, font=plex_r(12), fill=DIM if i==sel else FAINT)
        caps(d, 424, y+5, kind, mono_r(9), col if i==sel else shade(col,0.55), 1)
        y += 42
    knob_row(img, d, [('FILTER','ALL',True),('SORT','A–Z',False),('BANK','FACT',False),('PREVIEW','ON',False)], TEAL)
    return img

# ---------------------------------------------------------------- 2 PATTERN
def pattern():
    img, d = screen()
    chans = [('KICK', ULTRA), ('BASS', VIOLET), ('LEAD', MAGENTA), ('HATS', TEAL)]
    zone_title(d, 'PAT 04', ULTRA, 'ROW 12 · SPD 6 · PLAY')
    gx, gy, cw, rh = 34, 40, 108, 17
    for c,(name,col) in enumerate(chans):
        x = gx + c*cw + 4
        caps(d, x+26, gy, name, mono_r(9), col, 2)
    rows = ['C-3 01 A08','... .. ...','D#3 05 ...','... .. ...','G-4 03 C40','... .. ...','F-3 01 047','A-3 09 E90']
    for r in range(11):
        y = gy + 16 + r*rh
        absr = 8+r
        if absr == 12:
            tint_field(img, gx-24, y-1, W-8, y+rh-2, LIME, 0.20, 0.20)
            d = ImageDraw.Draw(img)
            d.rectangle((gx-24, y-1, gx-22, y+rh-3), fill=LIME)
        d.text((gx-24+2, y), f'{absr:02X}', font=mono_r(11), fill=PAPER if absr==12 else (DIM if absr%4==0 else FAINT))
        for c,(name,col) in enumerate(chans):
            cell = rows[(r+c*2)%len(rows)]
            empty = cell.startswith('...')
            d.text((gx + c*cw + 6, y), cell, font=mono_r(11),
                   fill=(shade(col,1.0) if absr!=12 else PAPER) if not empty else FAINT)
    return img

# ---------------------------------------------------------------- 3 INSTRUMENT
def instrument():
    img, d = screen()
    tint_field(img, 0, 0, W, 84, MAGENTA, 0.24, 0.0)
    d = ImageDraw.Draw(img)
    caps(d, 10, 6, 'INSTRUMENT 01', mono_r(9), shade(MAGENTA,0.95), 3)
    d.text((8, 18), 'Piano Noir', font=plex_m(34), fill=PAPER)
    d.text((10, 58), 'Muted felt grand with intimate release', font=plex_r(13), fill=DIM)
    xs = np.linspace(0, 1, 300)
    env = np.minimum(xs/0.08, 1.0) * np.exp(-(xs-0.08).clip(0)/0.42)
    pts = [(70+int(x*340), 190-int(e*84)) for x,e in zip(xs,env)]
    poly = pts + [(410,190),(70,190)]
    overlay = Image.new('RGB', (W,H), (0,0,0)); od = ImageDraw.Draw(overlay)
    od.polygon(poly, fill=shade(MAGENTA, 0.30))
    grad = np.linspace(1.0, 0.25, 96)[:,None,None]
    oa = np.asarray(overlay).astype(np.float64)
    oa[94:190,:,:] *= grad
    img.paste(Image.fromarray(np.maximum(np.asarray(img), np.clip(oa,0,255).astype(np.uint8))), (0,0))
    d = ImageDraw.Draw(img)
    d.line(pts, fill=MAGENTA, width=2)
    caps(d, 70, 196, 'ENVELOPE · AMP', mono_r(9), DIM, 3)
    knob_row(img, d, [('ATTACK','8ms',False),('DECAY','420ms',True),('SUSTAIN','62%',False),('RELEASE','1.3s',False)], MAGENTA)
    return img

# ---------------------------------------------------------------- 4 MIX
def mix():
    img, d = screen()
    chans = [('KICK', ULTRA, 0.78, 0.86), ('BASS', VIOLET, 0.64, 0.7), ('LEAD', MAGENTA, 0.88, 1.0), ('HATS', TEAL, 0.5, 0.55)]
    zone_title(d, 'MIX', LIME, 'MASTER −4.8 dB')
    for i,(name,col,lvl,pk) in enumerate(chans):
        x0 = 24 + i*116
        mx0, my0, mw, mh = x0, 52, 84, 150
        tint_field(img, mx0, my0, mx0+mw, my0+mh, col, 0.05, 0.02)
        top = my0 + int(mh*(1-lvl))
        tint_field(img, mx0, top, mx0+mw, my0+mh, col, 0.95, 0.25)
        d = ImageDraw.Draw(img)
        if pk >= 1.0:
            d.rectangle((mx0, my0, mx0+mw, my0+6), fill=TANGERINE)
        else:
            py = my0 + int(mh*(1-pk))
            d.rectangle((mx0, py, mx0+mw, py+1), fill=PAPER)
        caps(d, mx0, my0+mh+8, name, mono_r(10), col, 3)
        d.text((mx0, my0+mh+22), f'{(lvl*60-54):+.1f}', font=mono_b(15), fill=PAPER if pk>=1.0 else shade(PAPER,0.7))
    caps(d, 24+2*116, 30, 'CLIP', mono_r(9), TANGERINE, 2)
    return img

# ---------------------------------------------------------------- 5 DIALOG
def dialog():
    img, d = screen()
    tint_field(img, 0, 0, W, H, TANGERINE, 0.10, 0.0)
    d = ImageDraw.Draw(img)
    d.text((14, 24), '', font=phosphor(30), fill=TANGERINE)
    caps(d, 58, 24, 'CLEAR PATTERN', mono_r(10), shade(TANGERINE,0.95), 3)
    d.text((56, 38), 'Really clear pattern 04?', font=plex_m(26), fill=PAPER)
    y = 118
    for i,(t, det) in enumerate([('Yes, clear','pattern 04 will be emptied'),
                                  ('Clear all patterns','the whole song will be emptied')]):
        if i == 0:
            tint_field(img, 44, y-4, W-44, y+40, TANGERINE, 0.30, 0.10)
            d = ImageDraw.Draw(img)
            d.rectangle((44, y-4, 46, y+39), fill=TANGERINE)
        d.text((58, y), t, font=plex_m(18), fill=PAPER if i==0 else shade(PAPER,0.6))
        d.text((58, y+22), det, font=plex_r(12), fill=DIM if i==0 else FAINT)
        y += 56
    d.text((14, H-22), '4-D confirms — any other button cancels.', font=plex_r(12), fill=DIM)
    return img

# ---------------------------------------------------------------- 6 SAMPLE
def sample():
    img, d = screen()
    zone_title(d, 'KICK RESIN', TEAL, '127.6 ms · 24 BIT')
    rng = np.random.default_rng(7)
    n = 210
    envel = np.exp(-np.linspace(0,4.2,n)) + 0.04
    wave = envel * (0.65*np.sin(np.linspace(0,34,n)) + 0.35*rng.standard_normal(n))
    cx0, cy, ch_ = 16, 118, 64
    loop0, loop1 = 90, 168
    tint_field(img, cx0+loop0*2, cy-ch_, cx0+loop1*2, cy+ch_, VIOLET, 0.16, 0.16)
    d = ImageDraw.Draw(img)
    for i,v in enumerate(wave):
        x = cx0 + i*2
        h2 = max(1, int(abs(v)*ch_))
        f = 0.35 + 0.65*abs(v)
        inloop = loop0 <= i < loop1
        col = shade(VIOLET if inloop else TEAL, f)
        d.rectangle((x, cy-h2, x+1, cy+h2), fill=col)
    for lx, lab in ((loop0,'S'),(loop1,'E')):
        x = cx0+lx*2
        d.rectangle((x, cy-ch_-8, x, cy+ch_), fill=LIME)
        d.text((x+3, cy-ch_-10), lab, font=mono_b(9), fill=LIME)
    caps(d, 16, cy+ch_+8, 'LOOP 42% – 88% · VIOLET FIELD = REGION', mono_r(9), DIM, 2)
    knob_row(img, d, [('START','42%',False),('END','88%',True),('XFADE','64',False),('LOOP','ON',False)], VIOLET)
    return img

sheets = [('1-browse', browse), ('2-pattern', pattern), ('3-instrument', instrument),
          ('4-mix', mix), ('5-dialog', dialog), ('6-sample', sample)]
for name, fn in sheets:
    quantize565(fn()).save(f'{BASE}/fh-{name}.png')

contact = Image.new('RGB', (2*W+30, 3*H+56), (24,24,24))
cd = ImageDraw.Draw(contact)
cd.text((10, 2), 'FUELLHORN — greenfield: zone hues + typography, zero chrome bands, RGB565-dithered', font=plex_r(13), fill=(215,215,215))
for i,(name,_) in enumerate(sheets):
    x, y = 10 + (i%2)*(W+10), 24 + (i//2)*(H+12)
    contact.paste(Image.open(f'{BASE}/fh-{name}.png'), (x,y))
contact.save(f'{BASE}/fh-contact.png')
print('rendered 6 screens + contact sheet')
