"""Row-profile the marketing copy inside the photo panel of the mockup.

Uses a black-hat (morphological closing) to isolate thin dark strokes from the
light sky, and a top-hat for the bright icon discs, then prints contiguous
ink bands so the removal mask can be cut exactly.
"""
import cv2
import numpy as np

SRC = r"C:\Users\Lenovo\.workbuddy-ai\blobs\d9\d963123282724e48f3904334905780934e5704d09341393230af2ed3e5e5cdbc.jpg"

im = cv2.imread(SRC)
H, W = im.shape[:2]
gray = cv2.cvtColor(im, cv2.COLOR_BGR2GRAY).astype(np.float32)

# panel: x 0..888, y 64..1024 (below the white top bar)
PX0, PX1, PY0, PY1 = 0, 890, 64, 1024

k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (21, 21))
black = cv2.morphologyEx(gray, cv2.MORPH_BLACKHAT, k)   # dark thin strokes
top = cv2.morphologyEx(gray, cv2.MORPH_TOPHAT, k)       # bright small blobs

copy_col = (PX0 + 100, PX0 + 700)   # left copy column
c0, c1 = copy_col

def bands(sig, thr, x0, x1, y0, y1, minrun=2):
    prof = (sig[y0:y1, x0:x1] > thr).sum(axis=1)
    out, run = [], None
    for i, v in enumerate(prof):
        if v > 0:
            run = (run or i) if run is not None else i
        else:
            if run is not None and i - run >= minrun:
                out.append((y0 + run, y0 + i - 1, int(prof[run:i].max())))
            run = None
    if run is not None:
        out.append((y0 + run, y0 + len(prof) - 1, int(prof[run:].max())))
    return out

print("== dark-stroke bands in copy column x100-700 ==")
for b in bands(black, 26, c0, c1, PY0, PY1):
    print("  y", b[0], "-", b[1], " peak", b[2])

print("\n== bright-blob bands in copy column ==")
for b in bands(top, 12, c0, c1, PY0, PY1):
    print("  y", b[0], "-", b[1], " peak", b[2])

# horizontal extent of the headline block (y 150-230)
for y0, y1, label in [(118, 150, "eyebrow"), (150, 205, "H1a"), (200, 250, "H1b"),
                      (250, 300, "lead")]:
    prof = (black[y0:y1, :PX1] > 26).sum(axis=0)
    xs = np.nonzero(prof)[0]
    print(f"{label}: ink x {xs.min() if len(xs) else '-'}..{xs.max() if len(xs) else '-'}")
