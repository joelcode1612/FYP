"""Map the photo silhouette below the copy block in the reference panel.

Prints, per column, the first row at or below the copy block where a dark
photo pixel appears. That tells us exactly where the sky ends and the
buildings/trees begin, so the inpaint region can be bounded correctly.
"""
import numpy as np
from PIL import Image

SRC = r'C:\Users\Lenovo\.workbuddy-ai\blobs\d9\d963123282724e48f3904334905780934e5704d09341393230af2ed3e5e5cdbc.jpg'

im = Image.open(SRC).convert('RGB')
panel = im.crop((0, 68, 878, im.size[1]))
pw, ph = panel.size
a = np.asarray(panel).astype(np.float64)
lum = a @ np.array([0.2126, 0.7152, 0.0722])

print('panel', pw, ph)
print('--- first photo row at/after 415, per column (step 20) ---')
for x in range(0, pw, 20):
    colv = lum[415:, x]
    idx = np.where(colv < 200)[0]
    print('  x=%4d  photo starts %s' % (x, (415 + idx[0]) if len(idx) else '-'))

print('\n--- is the region x 540..700 sky at rows 410..620? (min lum) ---')
for y in range(400, 640, 20):
    row = lum[y, 540:700]
    print('  y=%4d  min=%6.1f  p10=%6.1f  median=%6.1f'
          % (y, row.min(), np.percentile(row, 10), np.median(row)))

print('\n--- sky sample colours (clean picks) ---')
for (x, y, tag) in ((430, 90, 'sky top right of copy'),
                     (100, 300, 'sky left of copy'),
                     (760, 120, 'sky far right top'),
                     (300, 60, 'sky above eyebrow')):
    print('  %-26s (%3d,%3d) rgb=%s' % (tag, x, y, a[y, x].round(1)))
