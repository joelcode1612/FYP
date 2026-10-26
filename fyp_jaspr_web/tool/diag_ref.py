"""Diagnose the signup reference mockup: geometry of the photo panel, the
overlaid marketing copy, and the artwork (route line + pin) that must survive.

All coordinates printed here are in FULL-SOURCE pixels of the 1536x1024 upload.
"""
import numpy as np
from PIL import Image

SRC = r"C:\Users\Lenovo\.workbuddy-ai\blobs\d9\d963123282724e48f3904334905780934e5704d09341393230af2ed3e5e5cdbc.jpg"
OUT = r"C:\Users\Lenovo\AndroidStudioProjects\FYP\fyp_jaspr_web\tool\_diag"

im = Image.open(SRC).convert("RGB")
a = np.asarray(im).astype(np.float32)
H, W, _ = a.shape
print(f"source {W}x{H}")

lum = a @ np.array([0.299, 0.587, 0.114], np.float32)

# ---------------------------------------------------------------- 1. top bar
row_lum = lum.mean(axis=1)
row_var = lum.std(axis=1)
for y in range(0, 140, 2):
    print(f"y={y:4d} mean={row_lum[y]:7.2f} std={row_var[y]:6.2f} "
          f"px0={a[y,0].astype(int)} px400={a[y,400].astype(int)} "
          f"px1200={a[y,1200].astype(int)}")
