"""Extract a clean photographic city background from the signup mockup.

The 1536x1024 upload is a render of the whole signup page: the left column is
a photograph of a KL street scene with the marketing copy composited on top of
the sky, and the right column is the form card. To use that scene as the
signup hero background we have to remove the composited copy while keeping the
artwork (the dashed route line and the location pin) intact.

Everything below works in SOURCE pixel coordinates of the 1536x1024 render.

Pipeline
  1. crop the photo panel out of the render
  2. build the removal mask: the copy ink is dark / saturated relative to the
     very light sky it sits on, so a per-band threshold finds it precisely.
     The mask is then grown generously so the JPEG ringing that surrounds the
     high-contrast composited text is swallowed too -- otherwise the halo is
     what remains visible after the fill.
  3. fill the hole:
       - a Laplace (harmonic) solve, run on a reduced-resolution grid and
         upsampled, continues the smooth sky gradient seamlessly
       - exemplar-based SHIFTMAP inpainting where real structure (roofs,
         foliage) sits behind the copy
  4. blend the fill back over the original and re-add the local sky grain
  5. write web/assets/signup-city.jpg
"""
import os

import cv2
import numpy as np

SRC = (r"C:\Users\Lenovo\.workbuddy-ai\blobs\d9"
       r"\d963123282724e48f3904334905780934e5704d09341393230af2ed3e5e5cdbc.jpg")
ROOT = r"C:\Users\Lenovo\AndroidStudioProjects\FYP\fyp_jaspr_web"
OUT = os.path.join(ROOT, "web", "assets", "signup-city.jpg")
DBG = os.path.join(ROOT, "tool", "_diag")

# --- geometry of the render ------------------------------------------------
PANEL_X0, PANEL_X1 = 0, 890      # photo column
PANEL_Y0, PANEL_Y1 = 66, 1024    # below the white top bar

# Copy lines in SOURCE coordinates, measured from the render. Each entry is
# (x0, y0, x1, y1, luminance_threshold) -- the threshold is relative to the
# bright sky the line sits on.
COPY = [
    (130, 128, 515, 150, 205),   # eyebrow
    (130, 162, 678, 234, 205),   # H1 line 1  "Find the right space"
    (128, 232, 678, 298, 205),   # H1 line 2  "for your business."
    (130, 300, 665, 326, 215),   # lead line 1
    (130, 327, 636, 356, 215),   # lead line 2
    (158, 376, 400, 402, 215),   # benefit 1 title
    (228, 404, 500, 428, 225),   # benefit 1 body 1
    (228, 428, 560, 452, 225),   # benefit 1 body 2
    (228, 452, 330, 476, 225),   # benefit 1 body 3
    (158, 486, 360, 512, 215),   # benefit 2 title
    (228, 512, 500, 538, 225),   # benefit 2 body 1
    (228, 538, 480, 562, 225),   # benefit 2 body 2
    (158, 584, 460, 610, 215),   # benefit 3 title
    (228, 610, 520, 634, 225),   # benefit 3 body 1
    (228, 634, 460, 658, 225),   # benefit 3 body 2
]

# The three round benefit icons sit in their own column, far left of the
# benefit text. They are detected, then validated against this expected column.
# Each removal disc is drawn as an ellipse that covers the whole pale disc (and
# its JPEG ringing) around the teal glyph. The route line / location pin live at
# x ~690+ so a wide disc on the left margin never touches the preserved artwork.
ICON_WIN = (92, 352, 252, 700)       # x0, y0, x1, y1 in source coordinates
ICON_CENTER_X = (140, 210)           # accepted centroid range
ICON_DISC_RX = 86                    # half-width of the pale disc around the glyph
ICON_DISC_RY = 56                    # half-height of the pale disc around the glyph

# Extra growth of the mask, in pixels, to swallow JPEG ringing.
RING_GROW = 9


def read_source():
    bgr = cv2.imread(SRC, cv2.IMREAD_COLOR)
    if bgr is None:
        raise SystemExit(f"cannot read {SRC}")
    return cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)


def find_icon_centres(src):
    x0, y0, x1, y1 = ICON_WIN
    win = src[y0:y1, x0:x1].astype(np.int16)
    mx, mn = win.max(axis=2), win.min(axis=2)
    sat = ((mx - mn) > 34) & (mx > 60)
    n, lab, stats, cents = cv2.connectedComponentsWithStats(sat.astype(np.uint8), 8)
    out = []
    for i in range(1, n):
        bx, by, bw, bh, area = stats[i]
        if area < 200 or area > 2200 or bw > 46 or bh > 46:
            continue
        cx, cy = cents[i]
        gx, gy = cx + x0, cy + y0
        if not (ICON_CENTER_X[0] <= gx <= ICON_CENTER_X[1]):
            continue
        if bw < 12 or bh < 12:
            continue
        out.append((int(gx), int(gy), area))
    return sorted(out, key=lambda c: c[1])


def build_mask(src):
    """Binary mask of every composited copy pixel, in source coordinates.

    Returns (mask, icon_zone):
      mask       -- the removal mask, already grown to swallow JPEG ringing
      icon_zone  -- just the benefit-icon discs, undilated. These zones are
                    forced to the smooth harmonic fill in `fill()` because the
                    SHIFTMAP inpainter otherwise pulls saturated blue/building
                    texture into them and leaves a teal ghost.
    """
    h, w = src.shape[:2]
    gray = cv2.cvtColor(src, cv2.COLOR_RGB2GRAY).astype(np.float32)
    mask = np.zeros((h, w), np.uint8)
    icon_zone = np.zeros((h, w), np.uint8)

    for x0, y0, x1, y1, thr in COPY:
        band = gray[y0:y1, x0:x1]
        hit = (band < thr).astype(np.uint8) * 255
        # the blue accent words are not dark but strongly saturated
        reg = src[y0:y1, x0:x1].astype(np.int16)
        sat = reg.max(axis=2) - reg.min(axis=2)
        blue = ((sat > 70) & (reg[:, :, 2] > 140) & (band < 225)).astype(np.uint8) * 255
        hit = cv2.max(hit, blue)
        mask[y0:y1, x0:x1] = cv2.max(mask[y0:y1, x0:x1], hit)

    centres = find_icon_centres(src)
    print("icons found:", centres)
    for gx, gy, _ in centres:
        cv2.ellipse(icon_zone, (gx, gy), (ICON_DISC_RX, ICON_DISC_RY),
                    0, 0, 360, 255, -1)
        cv2.ellipse(mask, (gx, gy), (ICON_DISC_RX, ICON_DISC_RY),
                    0, 0, 360, 255, -1)

    # grow the mask to swallow the JPEG ringing around the composited text
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (RING_GROW * 2 + 1,) * 2)
    mask = cv2.dilate(mask, k)
    return mask, icon_zone


def harmonic_fill(img, hole, scale=4):
    """Laplace solve inside the hole with a Dirichlet boundary of known pixels.

    Run on a reduced-resolution grid and upsampled: the sky is smooth, so the
    extra resolution buys nothing and the solve becomes ~16x cheaper.
    """
    h, w = img.shape[:2]
    small = cv2.resize(img, (w // scale, h // scale), interpolation=cv2.INTER_AREA)
    sh = cv2.resize(hole, (w // scale, h // scale), interpolation=cv2.INTER_NEAREST)
    sh = (sh > 0).astype(np.float32)
    known = sh < 0.5

    # pad so the wrap-around of np.roll never reaches the panel border
    p = 4
    sp = np.pad(small, ((p, p), (p, p), (0, 0)), mode="edge")
    kp = np.pad(known, ((p, p), (p, p)), mode="constant")
    u = sp.copy()

    iters = 1200
    for _ in range(iters):
        lap = (np.roll(u, 1, 0) + np.roll(u, -1, 0)
               + np.roll(u, 1, 1) + np.roll(u, -1, 1)) * 0.25
        u = np.where(kp[..., None], sp, lap)

    u = u[p:-p, p:-p]
    up = cv2.resize(u, (w, h), interpolation=cv2.INTER_CUBIC)
    return np.where((hole > 0)[..., None], up, img.astype(np.float32))


def shiftmap_fill(panel, hole):
    """Exemplar-based inpainting for areas that contain real structure."""
    bgr = cv2.cvtColor(panel, cv2.COLOR_RGB2BGR)
    inv = (1 - (hole > 0).astype(np.uint8)) * 255
    lab = cv2.cvtColor(bgr, cv2.COLOR_BGR2LAB)
    out = np.zeros_like(lab)
    cv2.xphoto.inpaint(lab, inv, out, cv2.xphoto.INPAINT_SHIFTMAP)
    return cv2.cvtColor(out, cv2.COLOR_LAB2BGR).astype(np.float32)


def fill(panel, mask, icon_zone=None):
    """Fill the masked copy out of the photo panel."""
    hole = (mask > 0).astype(np.uint8)
    smooth = harmonic_fill(panel, hole)

    # use the structure-aware fill only where the surroundings carry texture
    bgr = cv2.cvtColor(panel, cv2.COLOR_RGB2BGR)
    g = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY).astype(np.float32)
    known = (1 - hole).astype(np.float32)
    den = np.maximum(cv2.blur(known, (51, 51)), 1e-3)
    gk = g * known
    mu = cv2.blur(gk, (51, 51)) / den
    var = cv2.blur(gk * gk, (51, 51)) / den - mu * mu
    texture = np.sqrt(np.maximum(var, 0)) > 14

    # never let SHIFTMAP touch the benefit-icon discs: near the skyline it
    # pulls saturated blue/building texture in and leaves a teal ghost. Force
    # the smooth harmonic (sky) continuation there instead.
    if icon_zone is not None:
        texture &= (icon_zone == 0)

    if texture.any():
        painted = shiftmap_fill(panel, hole)
        smooth[texture] = painted[texture]

    m3 = hole[..., None].astype(bool)
    res = np.where(m3, smooth, bgr.astype(np.float32))
    return np.clip(res, 0, 255).astype(np.uint8)


def build():
    src = read_source()
    mask_full, icon_full = build_mask(src)
    print("mask coverage %.2f%% of the render" % (100.0 * (mask_full > 0).mean()))

    panel = src[PANEL_Y0:PANEL_Y1, PANEL_X0:PANEL_X1].copy()
    mask = mask_full[PANEL_Y0:PANEL_Y1, PANEL_X0:PANEL_X1].copy()
    icon_zone = icon_full[PANEL_Y0:PANEL_Y1, PANEL_X0:PANEL_X1].copy()

    os.makedirs(DBG, exist_ok=True)
    vis = panel.copy()
    vis[mask > 0] = (0.35 * vis[mask > 0]
                     + 0.65 * np.array([255, 0, 0])).astype(np.uint8)
    cv2.imwrite(os.path.join(DBG, "mask.png"), cv2.cvtColor(vis, cv2.COLOR_RGB2BGR))

    painted = fill(panel, mask, icon_zone)

    # blend the fill over the original with a soft edge so the transition
    # from real pixels to painted pixels is invisible
    soft = cv2.GaussianBlur(mask.astype(np.float32) / 255.0, (9, 9), 0)
    soft = np.clip((soft - 0.15) / 0.7, 0, 1)[..., None]
    out = (panel.astype(np.float32) * (1 - soft)
           + painted.astype(np.float32) * soft)
    out = np.clip(out, 0, 255).astype(np.uint8)

    # re-add a little grain so the repaired sky is not suspiciously flat
    base = cv2.GaussianBlur(panel, (0, 0), 3).astype(np.float32)
    noise = panel.astype(np.float32) - base
    sigma = float(np.std(noise[(mask == 0) & (base.mean(axis=2) > 215)]))
    rng = np.random.default_rng(11)
    grain = rng.normal(0, sigma * 0.6, panel.shape[:2]).astype(np.float32)
    out = np.clip(out + grain[..., None] * (mask > 0)[..., None], 0, 255).astype(np.uint8)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    cv2.imwrite(OUT, cv2.cvtColor(out, cv2.COLOR_RGB2BGR),
                [int(cv2.IMWRITE_JPEG_QUALITY), 92])
    print("wrote", OUT, out.shape, os.path.getsize(OUT) // 1024, "KB")

    cv2.imwrite(os.path.join(DBG, "filled.png"), cv2.cvtColor(out, cv2.COLOR_RGB2BGR))
    cv2.imwrite(os.path.join(DBG, "compare.png"),
                cv2.cvtColor(np.concatenate([panel, out], axis=0), cv2.COLOR_RGB2BGR))
    cv2.imwrite(os.path.join(DBG, "h1.png"), cv2.cvtColor(out[100:310, 100:700],
                                                           cv2.COLOR_RGB2BGR))


if __name__ == "__main__":
    build()
