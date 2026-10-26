"""Debug the removal mask: dump the detected ink overlay and the icon discs."""
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract_signup_bg as E

src = E.read_source()
panel = src[E.PANEL_Y0:E.PANEL_Y1, E.PANEL_X0:E.PANEL_X1].copy()
h, w = panel.shape[:2]

ink, bg, res, lum = E.detect_ink(panel, E.ZONES, E.ART_GUARD)
print("zone pixels     :", int(E.ZONES and sum(
    (y1 - y0) * (x1 - x0) for x0, y0, x1, y1 in E.ZONES)))
print("ink pixels      :", int(ink.sum()), " (%.1f%% of panel)" % (100 * ink.mean()))

vis = panel.copy()
vis[ink] = (0.35 * vis[ink] + 0.65 * np.array([255, 0, 0])).astype(np.uint8)
cv2.imwrite(os.path.join(E.DBG, "dbg_ink.png"), cv2.cvtColor(vis, cv2.COLOR_RGB2BGR))

# residual heat map inside the copy area
heat = np.clip(res, 0, 120).astype(np.uint8)
heat = cv2.applyColorMap(heat, cv2.COLORMAP_JET)
cv2.imwrite(os.path.join(E.DBG, "dbg_res.png"), heat)

discs = E.find_icons(src)
print("discs:", discs)

# lower the chroma bar and report all candidates in the icon column
img = src.astype(np.float32)
mx, mn = img.max(axis=2), img.min(axis=2)
band = np.zeros(src.shape[:2], bool)
band[360 - E.PANEL_Y0:700 - E.PANEL_Y0, 100 - E.PANEL_X0:220 - E.PANEL_X0] = True
for thr in (22, 26, 30, 34, 40):
    sat = ((mx - mn) > thr) & (mx > 60) & band
    n, lab, st, ce = cv2.connectedComponentsWithStats(sat.astype(np.uint8), 8)
    blobs = [(int(st[i][0]), int(st[i][1]), int(st[i][2]), int(st[i][3]), int(st[i][4]))
             for i in range(1, n) if st[i][4] >= 25]
    print(f"chroma>{thr}: {blobs}")
