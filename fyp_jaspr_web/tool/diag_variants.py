"""Compare fill strategies for removing the composited copy from the photo.

Variants
  A  multi-scale normalised blur only
  B  cv2.inpaint (Navier-Stokes) with a generous dilation
  C  multiresolution harmonic (Laplace) solve
  D  harmonic, then SHIFTMAP only where the surroundings are textured
"""
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract_signup_bg as E

src = E.read_source()
mask_full = E.build_mask(src)
panel = src[E.PANEL_Y0:E.PANEL_Y1, E.PANEL_X0:E.PANEL_X1].copy()
mask0 = mask_full[E.PANEL_Y0:E.PANEL_Y1, E.PANEL_X0:E.PANEL_X1].copy()
hole0 = (mask0 > 0).astype(np.uint8)

os.makedirs(E.DBG, exist_ok=True)


# ---------------------------------------------------------------- harmonic
def harmonic(img, hole, levels=4, iters=(600, 400, 250, 160, 100)):
    """Solve Laplace inside the hole with Dirichlet boundary = known pixels,
    coarse-to-fine so large holes converge fast and stay smooth."""
    pyr_i, pyr_h = [img.astype(np.float32)], [hole.astype(np.float32)]
    while len(pyr_i) < levels + 1 and min(pyr_i[-1].shape[:2]) > 24:
        pyr_i.append(cv2.pyrDown(pyr_i[-1]))
        pyr_h.append(cv2.pyrDown(pyr_h[-1]))

    u = None
    for lvl in range(len(pyr_i) - 1, -1, -1):
        im = pyr_i[lvl]
        h = pyr_h[lvl]
        known = h < 0.5
        if u is None:
            u = im.copy()
        else:
            u = cv2.resize(u, (im.shape[1], im.shape[0]), interpolation=cv2.INTER_LINEAR)
            u = np.where(known[..., None], im, u)
        n = iters[min(lvl, len(iters) - 1)]
        for _ in range(n):
            lap = (np.roll(u, 1, 0) + np.roll(u, -1, 0)
                   + np.roll(u, 1, 1) + np.roll(u, -1, 1)) * 0.25
            u = np.where(known[..., None], im, lap)
    return u


# pad so the wrap-around of np.roll never touches the panel border
def padded(img, hole, p=6):
    ip = np.pad(img, ((p, p), (p, p), (0, 0)), mode="edge")
    hp = np.pad(hole, ((p, p), (p, p)), mode="constant")
    return ip, hp, p


def unprepad(arr, p):
    return arr[p:-p, p:-p]


bgr = cv2.cvtColor(panel, cv2.COLOR_RGB2BGR)

results = {}

# A: normalised blur
results["A_blur"] = E.smooth_fill(panel, hole0)

# B: NS inpaint with a bigger dilation
big = cv2.dilate(hole0, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (11, 11)))
results["B_ns"] = cv2.inpaint(bgr, big, 8, cv2.INPAINT_NS).astype(np.float32)

# C: harmonic on the base mask
ip, hp, p = padded(panel, hole0)
harm = unprepad(harmonic(ip, hp), p)
results["C_harm"] = harm

# D: harmonic for smooth areas, SHIFTMAP for textured areas
g = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY).astype(np.float32)
known = (1 - hole0).astype(np.float32)
den = np.maximum(cv2.blur(known, (51, 51)), 1e-3)
gk = g * known
mu = cv2.blur(gk, (51, 51)) / den
var = cv2.blur(gk * gk, (51, 51)) / den - mu * mu
texture = np.sqrt(np.maximum(var, 0)) > 14
print("textured fraction of hole: %.1f%%" % (100 * texture[hole0 > 0].mean()))

inv = (1 - hole0) * 255
lab = cv2.cvtColor(bgr, cv2.COLOR_BGR2LAB)
sm = np.zeros_like(lab)
cv2.xphoto.inpaint(lab, inv, sm, cv2.xphoto.INPAINT_SHIFTMAP)
shift = cv2.cvtColor(sm, cv2.COLOR_LAB2BGR).astype(np.float32)
d = harm.copy()
d[texture] = shift[texture]
results["D_mix"] = d

# evaluate: how flat is the repaired sky? (std of the fill inside the H1 hole)
for k, v in results.items():
    band = v[80:250, 120:690]
    print(f"  {k:8s} H1-band std {band.std():6.2f}")

for k, v in results.items():
    out = np.where(hole0[..., None] > 0, v, panel.astype(np.float32))
    out = np.clip(out, 0, 255).astype(np.uint8)
    cv2.imwrite(os.path.join(E.DBG, f"cmp_{k}.png"), cv2.cvtColor(out, cv2.COLOR_RGB2BGR))
    # tight crop of the H1 so the ghosting is easy to judge
    crop = out[100:310, 100:700]
    cv2.imwrite(os.path.join(E.DBG, f"cmpH1_{k}.png"), cv2.cvtColor(crop, cv2.COLOR_RGB2BGR))

print("variants written")
