"""Render grid-annotated crops of the mockup's copy areas so the removal
rectangles can be read off directly in SOURCE pixel coordinates.
"""
import cv2
import numpy as np

SRC = r"C:\Users\Lenovo\.workbuddy-ai\blobs\d9\d963123282724e48f3904334905780934e5704d09341393230af2ed3e5e5cdbc.jpg"
OUT = r"C:\Users\Lenovo\AndroidStudioProjects\FYP\fyp_jaspr_web\tool\_diag"

im = cv2.imread(SRC)
H, W = im.shape[:2]


def grid_crop(x0, y0, x1, y1, step, name, scale=1.0):
    crop = im[y0:y1, x0:x1].copy()
    crop = cv2.resize(crop, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC)
    ch, cw = crop.shape[:2]
    for x in range(x0 - x0 % step + step, x1, step):
        px = int((x - x0) * scale)
        cv2.line(crop, (px, 0), (px, ch), (0, 0, 255), 1)
        cv2.putText(crop, str(x), (px + 2, 14), cv2.FONT_HERSHEY_PLAIN, 0.45, (255, 0, 0), 1)
    for y in range(y0 - y0 % step + step, y1, step):
        py = int((y - y0) * scale)
        cv2.line(crop, (0, py), (cw, py), (0, 0, 255), 1)
        cv2.putText(crop, str(y), (2, py - 3), cv2.FONT_HERSHEY_PLAIN, 0.45, (255, 0, 0), 1)
    cv2.imwrite(f"{OUT}/{name}.png", crop)
    print("wrote", name, crop.shape)


grid_crop(100, 120, 700, 360, 50, "g_headline", 1.6)
grid_crop(100, 360, 560, 700, 50, "g_benefits", 2.0)
grid_crop(560, 330, 900, 1024, 50, "g_art", 1.4)
