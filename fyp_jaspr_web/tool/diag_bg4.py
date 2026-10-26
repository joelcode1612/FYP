"""Zoomed crops of the tricky regions in the reference panel, plus a
dark-pixel overlay of the lower copy block, so the mask can be authored
by hand instead of guessed.
"""
import numpy as np
from PIL import Image

SRC = r'C:\Users\Lenovo\.workbuddy-ai\blobs\d9\d963123282724e48f3904334905780934e5704d09341393230af2ed3e5e5cdbc.jpg'
OUT = r'C:\Users\Lenovo\AndroidStudioProjects\FYP\fyp_jaspr_web\_ref'

im = Image.open(SRC).convert('RGB')
panel = im.crop((0, 68, 878, im.size[1]))
pw, ph = panel.size
a = np.asarray(panel).astype(np.float64)
lum = a @ np.array([0.2126, 0.7152, 0.0722])

# 1) Pin + dashed route line + benefit icons zoom
panel.crop((540, 250, 878, 620)).resize((676, 740), Image.LANCZOS).save(OUT + r'\zoom_pin.png')
panel.crop((110, 290, 340, 600)).resize((460, 620), Image.LANCZOS).save(OUT + r'\zoom_icons.png')

# 2) Dark-pixel overlay for the lower copy block (rows 290..620, x 110..720)
sub = lum[290:620, 110:720]
over = panel.crop((110, 290, 720, 620)).convert('RGB')
oa = np.asarray(over).copy()
hit = sub < 200
oa[hit] = [255, 0, 0]
Image.fromarray(oa).resize((1220, 660), Image.LANCZOS).save(OUT + r'\overlay_lower.png')

# 3) Per-row dark x-runs across the lower block, full width
print('--- lower block: dark runs (lum<200) per row, x 110..720 ---')
for y in range(300, 600, 10):
    row = lum[y, 110:720] < 200
    runs = []
    s = None
    for i, v in enumerate(row):
        if v and s is None:
            s = i
        elif not v and s is not None:
            if i - s > 2:
                runs.append((s + 110, i + 110))
            s = None
    if s is not None and 720 - s > 2:
        runs.append((s + 110, 720))
    if runs:
        print('y=%4d %s' % (y, runs))
print('done')
