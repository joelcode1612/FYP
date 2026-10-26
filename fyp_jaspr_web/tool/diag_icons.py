"""Diagnose the three benefit icons: bounding boxes of the detected glyph,
and a side-by-side of original vs cleaned in the icon column.
"""
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract_signup_bg as E

src = E.read_source()
panel = src[E.PANEL_Y0:E.PANEL_Y1, E.PANEL_X0:E.PANEL_X1].copy()

x0, y0, x1, y1 = E.ICON_WIN
win = src[y0:y1, x0:x1].astype(np.int16)
mx, mn = win.max(axis=2), win.min(axis=2)
sat = ((mx - mn) > 34) & (mx > 60)
n, lab, stats, cents = cv2.connectedComponentsWithStats(sat.astype(np.uint8), 8)

print("all saturated components in the icon window:")
for i in range(1, n):
    bx, by, bw, bh, area = stats[i]
    cx, cy = cents[i]
    gx, gy = cx + x0, cy + y0
    keep = (200 <= area <= 2200 and bw <= 46 and bh <= 46
            and 135 <= gx <= 205 and bw >= 12 and bh >= 12)
    print(f"  bbox=({bx+x0},{by+y0}) {bw}x{bh} area={area} "
          f"centroid=({gx:.0f},{gy:.0f}) KEEP={keep}")

# what does the whole icon disc look like? find the pale circle bounds by
# scanning for the tinted disc in a wider window
print("\npale disc extents (search for tinted circle around each glyph):")
for centre_y in (413, 526, 622):
    strip = src[centre_y - 45:centre_y + 45, 100:240].astype(np.int16)
    s = strip.max(axis=2) - strip.min(axis=2)
    # the disc is a light, slightly tinted circle: bluish or greenish
    tint = ((strip[:, :, 2] - strip[:, :, 0] > 4) | (strip[:, :, 1] - strip[:, :, 0] > 4))
    lum = strip.mean(axis=2)
    disc = tint & (lum > 225) & (lum < 253)
    ys, xs = np.nonzero(disc)
    if len(xs):
        print(f"  y~{centre_y}: x {100+xs.min()}..{100+xs.max()} "
              f"y {centre_y-45+ys.min()}..{centre_y-45+ys.max()}")
    else:
        print(f"  y~{centre_y}: none")

# side-by-side original vs cleaned in the icon column
out = cv2.cvtColor(cv2.imread(os.path.join(E.ROOT, "web", "assets",
                                            "signup-city.jpg")), cv2.COLOR_BGR2RGB)
outp = out[E.PANEL_Y0:E.PANEL_Y1, E.PANEL_X0:E.PANEL_X1].copy()
crop_o = panel[340:680, 100:260]
crop_n = outp[340:680, 100:260]
s = 2.0
sbs = np.concatenate([
    cv2.resize(crop_o, None, fx=s, fy=s, interpolation=cv2.INTER_CUBIC),
    cv2.resize(crop_n, None, fx=s, fy=s, interpolation=cv2.INTER_CUBIC)], axis=1)
cv2.imwrite(os.path.join(E.DBG, "z_icons_sbs.png"),
            cv2.cvtColor(sbs, cv2.COLOR_RGB2BGR))
print("\nwrote z_icons_sbs.png (left = original, right = cleaned)")
