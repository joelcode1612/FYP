"""Test pre-filters that remove JPEG ringing before the hole is filled.

Ringing around the high-contrast composited text is what makes the repaired
sky look mottled. A light edge-preserving pre-filter should flatten the sky
without harming the building edges.
"""
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract_signup_bg as E


def harmonic(img, hole, levels=4, iters=(600, 400, 250, 160, 100)):
    """Laplace solve inside the hole, coarse-to-fine."""
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


def padded(img, hole, p=6):
    ip = np.pad(img, ((p, p), (p, p), (0, 0)), mode="edge")
    hp = np.pad(hole, ((p, p), (p, p)), mode="constant")
    return ip, hp, p


def unprepad(arr, p):
    return arr[p:-p, p:-p]

src = E.read_source()
mask_full = E.build_mask(src)
panel = src[E.PANEL_Y0:E.PANEL_Y1, E.PANEL_X0:E.PANEL_X1].copy()
hole0 = (mask_full[E.PANEL_Y0:E.PANEL_Y1, E.PANEL_X0:E.PANEL_X1] > 0).astype(np.uint8)

os.makedirs(E.DBG, exist_ok=True)
crops = {}


def run(name, pre):
    p = pre(panel) if pre else panel
    ip, hp, pad = padded(p, hole0)
    h = unprepad(harmonic(ip, hp), pad)
    out = np.where(hole0[..., None] > 0, h, p.astype(np.float32))
    out = np.clip(out, 0, 255).astype(np.uint8)
    cv2.imwrite(os.path.join(E.DBG, f"pre_{name}.png"), cv2.cvtColor(out, cv2.COLOR_RGB2BGR))
    crops[name] = out[100:310, 100:700]
    # flatness metric inside the H1 hole only
    band = out[100:310, 100:700]
    print(f"  {name:14s} H1 std {band.std():6.2f}  mean {band.mean():6.1f}")
    return out


run("none", None)
run("median3", lambda im: cv2.medianBlur(im, 3))
run("median5", lambda im: cv2.medianBlur(im, 5))
run("bilateral", lambda im: cv2.bilateralFilter(im, 5, 30, 7))
run("nlm", lambda im: cv2.fastNlMeansDenoisingColored(im, None, 6, 6, 7, 21))
run("gauss3", lambda im: cv2.GaussianBlur(im, (3, 3), 0.8))

stack = np.concatenate([crops[k] for k in crops], axis=0)
cv2.imwrite(os.path.join(E.DBG, "pre_stack.png"), cv2.cvtColor(stack, cv2.COLOR_RGB2BGR))
print("order:", list(crops))
