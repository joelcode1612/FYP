"""Derive the exact per-line extent of every copy line in the mockup.

Runs on the FULL source image so line geometry is reported in source pixels.
Uses a black-hat (morphological closing) to isolate thin dark strokes against
the bright sky, then reports, for each line band, the first and last column
that carries ink.
"""
import cv2
import numpy as np

SRC = (r"C:\Users\Lenovo\.workbuddy-ai\blobs\d9"
       r"\d963123282724e48f3904334905780934e5704d09341393230af2ed3e5e5cdbc.jpg")

im = cv2.imread(SRC)
gray = cv2.cvtColor(im, cv2.COLOR_BGR2GRAY).astype(np.float32)
k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (25, 25))
ink = cv2.morphologyEx(gray, cv2.MORPH_BLACKHAT, k)

# candidate line bands in source coords (from the row profile earlier)
BANDS = [
    ("eyebrow", 130, 148),
    ("h1a", 165, 235),
    ("h1b", 232, 296),
    ("lead1", 300, 327),
    ("lead2", 327, 355),
    ("b1title", 378, 402),
    ("b1body1", 404, 428),
    ("b1body2", 428, 452),
    ("b1body3", 452, 476),
    ("b2title", 486, 512),
    ("b2body1", 512, 538),
    ("b2body2", 538, 562),
    ("b3title", 584, 610),
    ("b3body1", 610, 634),
    ("b3body2", 634, 658),
]

for name, y0, y1 in BANDS:
    band = ink[y0:y1]
    prof = (band > 22).sum(axis=0)
    xs = np.nonzero(prof)[0]
    if not len(xs):
        print(f"{name:9s} y{y0}-{y1}: no ink")
        continue
    # trim to the contiguous run containing the bulk of the ink
    strong = np.nonzero(prof >= 2)[0]
    lo, hi = int(strong.min()), int(strong.max())
    print(f"{name:9s} y{y0}-{y1}: x {lo}..{hi}   peak {int(prof.max()):3d}")

# benefit titles are dark + bold; the body is lighter grey. Check the
# threshold sensitivity for the body lines.
print("\n-- body-line extent vs threshold --")
for name, y0, y1 in [("b1body1", 404, 428), ("b2body1", 512, 538),
                     ("b3body1", 610, 634), ("b3body2", 634, 658)]:
    for thr in (10, 14, 18, 22):
        prof = (ink[y0:y1] > thr).sum(axis=0)
        xs = np.nonzero(prof >= 2)[0]
        if len(xs):
            print(f"  {name:8s} thr{thr:3d}: x {int(xs.min())}..{int(xs.max())}")
        else:
            print(f"  {name:8s} thr{thr:3d}: none")
