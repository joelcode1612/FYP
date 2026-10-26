"""Precise copy-localisation for the signup background extraction.

Finds, in the reference panel:
  * the text rows (dark glyphs against bright sky),
  * the horizontal extent of each text row,
  * the benefit icon circles (bluish pixels in the icon column),
  * the location pin + dashed route line (kept - part of the artwork).
"""
import numpy as np
from PIL import Image

SRC = r'C:\Users\Lenovo\.workbuddy-ai\blobs\d9\d963123282724e48f3904334905780934e5704d09341393230af2ed3e5e5cdbc.jpg'

im = Image.open(SRC).convert('RGB')
W, H = im.size
TOPBAR = 68
PANEL_RIGHT = 878
panel = im.crop((0, TOPBAR, PANEL_RIGHT, H))
pw, ph = panel.size
a = np.asarray(panel).astype(np.float64)
lum = a @ np.array([0.2126, 0.7152, 0.0722])
R, G, B = a[..., 0], a[..., 1], a[..., 2]

# ---- text rows: strong dark pixels inside the copy column -------------
X0, X1 = 100, 720
col = lum[:, X0:X1]
rowmin = col.min(axis=1)
rowcnt = (col < 200).sum(axis=1)
print('--- candidate text rows (count of lum<200) ---')
runs = []
inrun = False
for y in range(ph):
    if rowcnt[y] > 2 and not inrun:
        inrun, start = True, y
    elif rowcnt[y] <= 2 and inrun:
        inrun = False
        runs.append((start, y - 1))
if inrun:
    runs.append((start, ph - 1))
for (s, e) in runs:
    if e - s < 4:
        continue
    xs = np.where(lum[s:e + 1, X0:X1] < 200)[1] + X0
    print('  rows %4d..%4d  x %4d..%4d  minlum=%5.1f'
          % (s, e, xs.min(), xs.max(), lum[s:e + 1, X0:X1].min()))

# ---- benefit icon circles: bluish pixels in the icon column -----------
print('--- bluish runs in icon column x 120..215 ---')
icon = (B - R > 10) & (lum > 150)
band = icon[:, 120:215].sum(axis=1)
inrun, start = False, 0
iruns = []
for y in range(ph):
    if band[y] > 6 and not inrun:
        inrun, start = True, y
    elif band[y] <= 6 and inrun:
        inrun = False
        iruns.append((start, y - 1))
if inrun:
    iruns.append((start, ph - 1))
for (s, e) in iruns:
    ys = np.where(icon[s:e + 1, 120:215])[1] + 120
    print('  rows %4d..%4d  x %4d..%4d' % (s, e, ys.min(), ys.max()))

# ---- the location pin (right of copy, keep it) ------------------------
print('--- pin / dashed line region (x>700) ---')
sub = lum[:, 700:878]
ys = np.where((sub < 215).any(axis=1))[0]
if len(ys):
    print('  rows %d..%d' % (ys.min(), ys.max()))
    xs = np.where((sub < 215).any(axis=0))[0] + 700
    print('  cols %d..%d' % (xs.min(), xs.max()))

# ---- sky/photo boundary: first row (per column) where dark photo starts
print('--- photo silhouette (first row with lum<200 per column, sampled) ---')
for x in range(0, pw, 60):
    colv = lum[:, x]
    idx = np.where(colv < 200)[0]
    print('  x=%4d  first dark row=%s' % (x, idx[0] if len(idx) else '-'))
