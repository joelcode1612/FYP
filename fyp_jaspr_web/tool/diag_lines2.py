"""Second-pass diagnostics:
 (a) per-line copy extents restricted to the copy column (x < 700)
 (b) colour signature of the artwork (dashed route line + location pin)
 (c) the exact sky colour profile behind each copy band
"""
import cv2
import numpy as np

SRC = (r"C:\Users\Lenovo\.workbuddy-ai\blobs\d9"
       r"\d963123282724e48f3904334905780934e5704d09341393230af2ed3e5e5cdbc.jpg")

im = cv2.imread(SRC)
rgb = cv2.cvtColor(im, cv2.COLOR_BGR2RGB)
gray = cv2.cvtColor(im, cv2.COLOR_BGR2GRAY).astype(np.float32)
k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (25, 25))
ink = cv2.morphologyEx(gray, cv2.MORPH_BLACKHAT, k)

BANDS = [
    ("eyebrow", 130, 148), ("h1a", 165, 235), ("h1b", 232, 296),
    ("lead1", 300, 327), ("lead2", 327, 355),
    ("b1title", 378, 402), ("b1body1", 404, 428), ("b1body2", 428, 452),
    ("b1body3", 452, 476),
    ("b2title", 486, 512), ("b2body1", 512, 538), ("b2body2", 538, 562),
    ("b3title", 584, 610), ("b3body1", 610, 634), ("b3body2", 634, 658),
]
print("-- copy extents, x limited to the copy column (x<700) --")
for name, y0, y1 in BANDS:
    prof = (ink[y0:y1, :700] > 18).sum(axis=0)
    xs = np.nonzero(prof >= 2)[0]
    print(f"  {name:9s} y{y0}-{y1}: x {int(xs.min()) if len(xs) else '-'}.."
          f"{int(xs.max()) if len(xs) else '-'}")

print("\n-- artwork colour signature (route + pin) --")
# pin marker sits around x 690-760, y 380-460
for label, (x0, y0, x1, y1) in {
    "pin core": (700, 385, 750, 450),
    "route dash": (600, 430, 700, 500),
    "sky above": (600, 200, 700, 300),
}.items():
    reg = rgb[y0:y1, x0:x1].reshape(-1, 3).astype(np.float32)
    print(f"  {label:11s} mean RGB {reg.mean(axis=0).round(1)}  "
          f"min {reg.min(axis=0)}  max {reg.max(axis=0)}")

print("\n-- background colour behind each copy band (median of unmasked sky) --")
for name, y0, y1 in BANDS:
    reg = rgb[y0:y1, 690:860].reshape(-1, 3).astype(np.float32)
    print(f"  {name:9s} sky median RGB {np.median(reg, axis=0).round(1)}")
