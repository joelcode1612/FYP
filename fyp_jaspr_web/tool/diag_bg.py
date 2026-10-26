"""Diagnostics for the signup background extraction.

Prints the luminance / colour profile of the reference panel so the copy
regions can be masked precisely, and renders annotated crops for review.
"""
import numpy as np
from PIL import Image, ImageDraw

SRC = r'C:\Users\Lenovo\.workbuddy-ai\blobs\d9\d963123282724e48f3904334905780934e5704d09341393230af2ed3e5e5cdbc.jpg'
OUT = r'C:\Users\Lenovo\AndroidStudioProjects\FYP\fyp_jaspr_web\_ref'

im = Image.open(SRC).convert('RGB')
W, H = im.size
TOPBAR = 68
PANEL_RIGHT = 878
panel = im.crop((0, TOPBAR, PANEL_RIGHT, H))
pw, ph = panel.size
a = np.asarray(panel).astype(np.float64)
lum = a @ np.array([0.2126, 0.7152, 0.0722])
print('panel', pw, ph)

# Sky brightness in a clean column band (right of the copy, left of towers)
for y in (60, 120, 180, 240, 300, 360, 420, 480, 540):
    row = lum[y, 100:700]
    print('y=%4d  min=%6.1f  p05=%6.1f  median=%6.1f  max=%6.1f'
          % (y, row.min(), np.percentile(row, 5), np.median(row), row.max()))

# Where does each dark band start/end horizontally? Print dark runs per row.
print('\n-- dark runs (lum<205) per row, x in 90..720 --')
for y in range(40, 560, 20):
    row = lum[y, 90:720] < 205
    runs = []
    start = None
    for i, v in enumerate(row):
        if v and start is None:
            start = i
        elif not v and start is not None:
            if i - start > 3:
                runs.append((start + 90, i + 90))
            start = None
    if start is not None and len(row) - start > 3:
        runs.append((start + 90, 720))
    if runs:
        print('y=%4d  %s' % (y, runs[:6]))

# Annotated preview
ann = panel.copy()
d = ImageDraw.Draw(ann)
for y in range(0, ph, 50):
    d.line([(0, y), (pw, y)], fill=(255, 0, 0), width=1)
    d.text((4, y + 2), str(y), fill=(255, 0, 0))
for x in range(0, pw, 50):
    d.line([(x, 0), (x, ph)], fill=(0, 128, 255), width=1)
    d.text((x + 2, 4), str(x), fill=(0, 128, 255))
ann.save(OUT + r'\panel_grid.png')
print('\nwrote panel_grid.png')
