"""Locate the photo panel bounds inside the 1536x1024 signup mockup and save
enlarged crops of the copy areas so the removal mask can be drawn precisely.
"""
import numpy as np
from PIL import Image

SRC = r"C:\Users\Lenovo\.workbuddy-ai\blobs\d9\d963123282724e48f3904334905780934e5704d09341393230af2ed3e5e5cdbc.jpg"
OUT = r"C:\Users\Lenovo\AndroidStudioProjects\FYP\fyp_jaspr_web\tool\_diag"

im = Image.open(SRC).convert("RGB")
a = np.asarray(im).astype(np.float32)
H, W, _ = a.shape
lum = a @ np.array([0.299, 0.587, 0.114], np.float32)

# --- right edge of the photo panel: scan several rows, print colour steps ---
for y in (120, 300, 500, 700, 900):
    row = a[y]
    # the flat right-hand page background is a uniform light grey; find where
    # the photo (saturated / textured) ends by looking at local colour spread
    spread = np.abs(np.diff(row, axis=0)).sum(axis=1)
    # print candidate transition points
    cand = [x for x in range(800, 1100) if spread[x] > 2.0]
    print(f"y={y} transitions near panel edge: {cand[:12]}")
    print(f"   px860={row[860].astype(int)} px880={row[880].astype(int)} "
          f"px900={row[900].astype(int)} px920={row[920].astype(int)} "
          f"px1000={row[1000].astype(int)}")

# --- where does the photo start vertically? column x=20 (far left) ---
col = lum[:, 20]
print("\ncol x=20 dark rows:", [y for y in range(60, 1024) if col[y] < 200][:40])
print("col x=20 first <240 row:", next((y for y in range(60, 1024) if col[y] < 240), None))

# --- save crops for visual inspection ---
im.crop((0, 60, 900, 1024)).save(f"{OUT}/panel.png")
im.crop((100, 90, 760, 320)).resize((1320, 460), Image.LANCZOS).save(f"{OUT}/headline.png")
im.crop((100, 320, 560, 620)).resize((920, 600), Image.LANCZOS).save(f"{OUT}/benefits.png")
im.crop((560, 380, 900, 1024)).resize((680, 1288), Image.LANCZOS).save(f"{OUT}/pin.png")
print("\ncrops written to", OUT)
