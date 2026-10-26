"""Zoom into the regions that are most likely to still hold artefacts:
the three icon discs, the benefit text column and the lower-left foliage.
"""
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract_signup_bg as E

OUT_JPG = os.path.join(E.ROOT, "web", "assets", "signup-city.jpg")
out = cv2.cvtColor(cv2.imread(OUT_JPG), cv2.COLOR_BGR2RGB)
panel = out[E.PANEL_Y0:E.PANEL_Y1, E.PANEL_X0:E.PANEL_X1].copy()
h, w = panel.shape[:2]

jobs = {
    "z_icon1": (110, 360, 250, 460),
    "z_icon2": (110, 470, 250, 570),
    "z_icon3": (110, 570, 250, 670),
    "z_benefits": (140, 370, 680, 670),
    "z_lowleft": (0, 640, 200, 958),
}

for name, (x0, y0, x1, y1) in jobs.items():
    crop = panel[y0:y1, x0:x1]
    s = 2.2
    big = cv2.resize(crop, None, fx=s, fy=s, interpolation=cv2.INTER_CUBIC)
    cv2.imwrite(os.path.join(E.DBG, name + ".png"),
                cv2.cvtColor(big, cv2.COLOR_RGB2BGR))
    print("wrote", name, big.shape)
