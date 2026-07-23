"""Fuellhorn round 2: does big type over a full-surface tint gradient carry
across screen types? Transport, song, hold-popup, master."""
from PIL import Image, ImageDraw, ImageFont
import numpy as np, os

BASE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../../Sources/KontrolSurfaceKit2/Resources/Fonts')
def F(n,s): return ImageFont.truetype(f'{FONTS}/{n}', s)
plex_m, plex_r = (lambda s: F('IBMPlexSansCondensed-Medium.otf', s)), (lambda s: F('IBMPlexSansCondensed-Regular.otf', s))
mono_r, mono_b = (lambda s: F('JetBrainsMono-Regular.ttf', s)), (lambda s: F('JetBrainsMono-Bold.ttf', s))

W,H = 480,272
PAPER, DIM, FAINT = (242,246,255),(138,147,168),(74,80,96)
TEAL,ULTRA,VIOLET = (43,217,200),(92,120,255),(155,107,255)
MAGENTA,LIME,TANGERINE = (255,79,163),(184,230,46),(255,138,43)
def shade(c,f): return tuple(min(255,int(v*f)) for v in c)

def screen(): img=Image.new('RGB',(W,H),(0,0,0)); return img, ImageDraw.Draw(img)

def field(img, hue, top=0.26, until=1.0):
    h_ = int(H*until)
    t = np.concatenate([np.linspace(top, 0.0, h_), np.zeros(H-h_)])[:,None]
    f = np.array(hue)[None,None,:]*t[:,:,None]
    a = np.maximum(np.asarray(img).astype(np.float64), f)
    img.paste(Image.fromarray(np.clip(a,0,255).astype(np.uint8)),(0,0))

def caps(d,x,y,t,f,fill,tr=2):
    for ch in t:
        d.text((x,y),ch,font=f,fill=fill); x += d.textlength(ch,font=f)+tr
    return x

BAYER=(np.array([[0,8,2,10],[12,4,14,6],[3,11,1,9],[15,7,13,5]])+0.5)/16.0
def q565(img):
    a=np.asarray(img).astype(np.float64); th=np.tile(BAYER,(H//4,W//4)); out=np.empty_like(a)
    for ch,l in ((0,32),(1,64),(2,32)):
        out[:,:,ch]=np.round(np.clip(np.floor(a[:,:,ch]/255*(l-1)+th),0,l-1)*255/(l-1))
    return Image.fromarray(out.astype(np.uint8))

def knobs(img,d,items,hue,y=H-46):
    slot=W//len(items)
    for i,(l,v,foc) in enumerate(items):
        x=i*slot+12
        d.rectangle((x,y,x+22,y+1),fill=hue if foc else shade(hue,0.45))
        caps(d,x,y+5,l,mono_r(9),shade(hue,0.95) if foc else DIM,2)
        d.text((x,y+18),v,font=mono_b(17),fill=PAPER if foc else shade(PAPER,0.62))

# ------------------------------------------------ PERFORM: the value IS the screen
def perform():
    img,d=screen(); field(img,LIME,0.20,0.75); d=ImageDraw.Draw(img)
    caps(d,10,8,'PERFORM',plex_m(20),PAPER,1)
    m=d.textlength('· PLAY',font=mono_r(10)); d.text((W-10-70,14),'· PLAY',font=mono_r(10),fill=shade(LIME,0.95))
    caps(d,14,52,'TEMPO',mono_r(10),shade(LIME,0.95),4)
    d.text((8,58),'124.0',font=mono_b(78),fill=PAPER)
    d.text((252,116),'BPM',font=plex_r(15),fill=DIM)
    caps(d,300,52,'POSITION',mono_r(10),DIM,3)
    d.text((298,66),'BAR 17',font=mono_b(26),fill=shade(PAPER,0.85))
    d.text((298,98),'1:1:1',font=mono_r(15),fill=DIM)
    caps(d,300,130,'SWING 54% · GRID 1/16',mono_r(9),DIM,1)
    knobs(img,d,[('TEMPO','124.0',True),('SWING','54%',False),('METRO','ON',False),('COUNT','1BAR',False)],LIME)
    return img

# ------------------------------------------------ SONG: identity + object colors
def song():
    img,d=screen(); field(img,ULTRA,0.24,0.62); d=ImageDraw.Draw(img)
    caps(d,10,6,'SONG · 8 PATTERNS · 3:24',mono_r(9),shade(ULTRA,0.95),3)
    d.text((8,16),'Halcyon Sky',font=plex_m(36),fill=PAPER)
    d.text((10,60),'124 BPM · A-major · last saved 12:03',font=plex_r(13),fill=DIM)
    cols=[ULTRA,VIOLET,MAGENTA,TEAL]
    seq=[0,0,1,2,1,3,2,0]; x0,y0,bw,bh=16,108,54,44
    for i,pi in enumerate(seq):
        x=x0+i*(bw+3); col=cols[pi]
        f=0.9 if i==4 else 0.42
        d.rectangle((x,y0,x+bw,y0+bh),fill=shade(col,0.16*f*4))
        d.rectangle((x,y0,x+bw,y0+3),fill=shade(col,f))
        d.text((x+4,y0+8),f'P{pi+1}',font=mono_b(13),fill=PAPER if i==4 else shade(PAPER,0.6))
        d.text((x+4,y0+26),'16',font=mono_r(10),fill=DIM if i==4 else FAINT)
    d.rectangle((x0+4*(bw+3)-2,y0-6,x0+4*(bw+3)-1,y0+bh+6),fill=LIME)
    caps(d,16,y0+bh+14,'POSITION 5/8 · LOOP OFF',mono_r(9),DIM,2)
    knobs(img,d,[('SECTION','5',True),('LENGTH','16',False),('LOOP','OFF',False),('FOLLOW','ON',False)],ULTRA)
    return img

# ------------------------------------------------ HOLD POPUP: one question, huge answer
def keymode():
    img,d=screen(); field(img,VIOLET,0.30,1.0); d=ImageDraw.Draw(img)
    caps(d,10,8,'KEY MODE — HELD',mono_r(10),shade(VIOLET,0.95),3)
    d.text((6,26),'C2',font=plex_m(96),fill=PAPER)
    d.text((150,64),'root octave',font=plex_r(17),fill=DIM)
    d.text((150,88),'chromatic pads C2–D#3',font=plex_r(13),fill=FAINT)
    slots=['OCT 0','OCT 1','OCT 2','OCT 3','OCT 4','OCT 5','OCT 6','OCT 7']; sel=2
    sw=W//8
    for i,s in enumerate(slots):
        x=i*sw
        if i==sel:
            d.rectangle((x+3,H-96,x+sw-3,H-72),fill=VIOLET)
            d.text((x+8,H-92),s,font=mono_b(11),fill=(16,8,30))
        else:
            d.text((x+8,H-92),s,font=mono_r(11),fill=DIM)
        d.rectangle((x+3,H-70,x+sw-3,H-69),fill=shade(VIOLET,0.9 if i==sel else 0.3))
    d.text((10,H-46),'F1–F8 choose · new notes use the range immediately',font=plex_r(12),fill=DIM)
    d.text((10,H-26),'release KEY MODE to return',font=plex_r(12),fill=FAINT)
    return img

# ------------------------------------------------ MASTER: one number to rule them
def master():
    img,d=screen(); field(img,TEAL,0.22,0.8); d=ImageDraw.Draw(img)
    caps(d,10,8,'MASTER',plex_m(20),PAPER,1)
    d.text((W-10-88,14),'LIMIT OFF',font=mono_r(10),fill=shade(TEAL,0.95))
    d.text((4,44),'-4.8',font=mono_b(86),fill=PAPER)
    d.text((218,108),'dBFS',font=plex_r(16),fill=DIM)
    caps(d,300,52,'PEAK HOLD',mono_r(9),DIM,3)
    d.text((298,64),'-1.2',font=mono_b(24),fill=shade(PAPER,0.85))
    caps(d,300,100,'RMS',mono_r(9),DIM,3)
    d.text((298,112),'-11.6',font=mono_b(24),fill=shade(PAPER,0.85))
    lv=0.72; y=170
    d.rectangle((16,y,16+int(448*lv),y+8),fill=shade(TEAL,0.9))
    d.rectangle((16+int(448*lv),y,16+int(448*lv)+1,y+8),fill=PAPER)
    d.rectangle((16+int(448*0.92),y-3,16+int(448*0.92)+1,y+11),fill=TANGERINE)
    caps(d,16,y+14,'0 dB MARK TANGERINE · PEAK WHITE',mono_r(9),FAINT,2)
    knobs(img,d,[('GAIN','0.0dB',True),('LIMIT','OFF',False),('WIDTH','100%',False),('DC','ON',False)],TEAL)
    return img

for name,fn in [('7-perform',perform),('8-song',song),('9-keymode',keymode),('10-master',master)]:
    q565(fn()).save(f'{BASE}/fh-{name}.png')

sheet=Image.new('RGB',(2*W+30,2*H+50),(24,24,24))
sd=ImageDraw.Draw(sheet)
sd.text((10,2),'FUELLHORN round 2 — big type on full-surface tint fields, across screen types',font=plex_r(13),fill=(215,215,215))
for i,name in enumerate(['7-perform','8-song','9-keymode','10-master']):
    sheet.paste(Image.open(f'{BASE}/fh-{name}.png'),(10+(i%2)*(W+10),24+(i//2)*(H+12)))
sheet.save(f'{BASE}/fh-contact2.png')
print('rendered round 2')
