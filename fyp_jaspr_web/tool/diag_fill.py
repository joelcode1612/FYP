"""Dump the fill intermediates so the residual ghosting can be attributed."""
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract_signup_bg as E

src = E.read_source()
mask_full = E.build_mask(src)
panel = src[E.PANEL_Y0:E.PANEL_Y1, E.PANEL_X0:E.PANEL_X1].copy()
mask = mask_full[E.PANEL_Y0:E.PANEL_Y1, E.PANEL_X0:E.PANEL_X1].copy()
hole = (mask > 0).astype(np.uint8)

# how big is the JPEG ringing halo? measure residual vs a smooth sky fit
smooth = E.smooth_fill(panel, hole)
res = np.abs(panel.astype(np.float32) - smooth).max(axis=2)
print("residual inside hole : mean %.1f  p90 %.1f  max %.1f"
      % (res[hole > 0].mean(), np.percentile(res[hole > 0], 90), res[hole > 0].max()))
print("residual just outside hole (halo ring):")
ring = np.zeros_like(hole, bool)
k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (13, 13))
ring = (cv2.dilate(hole, k) - hole) > 0
print("   mean %.1f  p90 %.1f  max %.1f"
      % (res[ring].mean(), np.percentile(res[ring], 90), res[ring].max()))

# residual heat map over the headline band
heat = np.clip(res, 0, 80).astype(np.uint8)
heat = cv2.applyColorMap(heat, cv2.COLORMAP_JET)
cv2.imwrite(os.path.join(E.DBG, "dbg_res2.png"), heat)

for name, arr in [("dbg_smooth", smooth), ("dbg_panel", panel.astype(np.float32))]:
    cv2.imwrite(os.path.join(E.DBG, name + ".png"),
                cv2.cvtColor(np.clip(arr, 0, 255).astype(np.uint8), cv2.COLOR_RGB2BGR))

# What does the JPEG halo look like? crop the H1 and show residual contrast
crop = res[90:240, 120:690]
print("\nresidual profile across the H1 band (min over rows):")
for x in range(0, 570, 30):
    col = crop[:, x]
    print("  x=%3d  min %5.1f  max %5.1f" % (120 + x, col.min(), col.max()))
