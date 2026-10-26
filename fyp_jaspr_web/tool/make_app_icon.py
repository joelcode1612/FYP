"""Prepare the Sitewise app icon from the uploaded artwork.

The upload is a 1254x1254 JPEG: a rounded-square tile (an isometric map of
cyan/blue blocks with white roads and glowing nodes) floating on a black
surround. This script cuts the tile out, cleans the JPEG fringe off its
rounded edge and writes the platform-sized assets:

  * web      -- web/assets/sitewise-icon*.png (brand mark + favicons)
  * android  -- fyp_mobile_app/android/.../mipmap-*/ic_launcher.png
  * ios      -- fyp_mobile_app/ios/.../AppIcon.appiconset/Icon-App-*.png
  * macos    -- fyp_mobile_app/macos/.../AppIcon.appiconset/app_icon_*.png

Run `python tool/make_app_icon.py --preview` to write a contact sheet of the
candidate treatments and inspect it before committing to one.
"""
import json
import os
import sys

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'tool', '_src', 'sitewise_icon_source.jpg')
WEB_ASSETS = os.path.join(ROOT, 'web', 'assets')
FYP = os.path.dirname(ROOT)
MOBILE = os.path.join(FYP, 'fyp_mobile_app')

# The surround is pure black; anything with a visible channel is artwork.
SURROUND_MAX = 8


def load():
    return Image.open(SRC).convert('RGB')


def detect_tile(a):
    """Find the tile's bounding box by modal voting on the row/column extents.

    The tile is nearly square but the JPEG is 1254x1254 with the artwork
    centred, so each straight edge lands on one specific pixel column/row.
    Taking the *mode* of the extents finds those straight edges and ignores
    the rounded corners and the soft shadow.
    """
    solid = a.max(axis=2) > SURROUND_MAX

    rows = []
    for y in range(a.shape[0]):
        xs = np.flatnonzero(solid[y])
        if xs.size:
            rows.append((int(xs.min()), int(xs.max())))
    cols = []
    for x in range(a.shape[1]):
        ys = np.flatnonzero(solid[:, x])
        if ys.size:
            cols.append((int(ys.min()), int(ys.max())))

    def mode(vals):
        best, best_n = vals[0], 0
        for v in vals:
            n = sum(1 for w in vals if abs(w - v) <= 1)
            if n > best_n:
                best, best_n = v, n
        return best

    L = mode([r[0] for r in rows])
    R = mode([r[1] for r in rows])
    T = mode([c[0] for c in cols])
    B = mode([c[1] for c in cols])
    return L, R, T, B


def squircle_mask(w, h, radius, feather=1.6, inset=0.0):
    """Anti-aliased rounded-rect mask: 0 outside, 255 inside.

    Uses the standard rounded-box signed distance field. A naive
    "distance to the corner arc" is zero everywhere along the straight
    edges, which silently turns the whole edge into a half-transparent
    band -- so the full SDF is used instead.

    `inset` shrinks the shape by that many pixels, which is how the
    artwork's outermost (haloed) ring of pixels gets excluded.
    """
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    hw, hh = w / 2.0, h / 2.0
    cx, cy = (w - 1) / 2.0, (h - 1) / 2.0
    dx = np.abs(xx - cx) - (hw - radius - inset)
    dy = np.abs(yy - cy) - (hh - radius - inset)
    outside = (np.sqrt(np.maximum(dx, 0) ** 2 + np.maximum(dy, 0) ** 2)
               + np.minimum(np.maximum(dx, dy), 0.0) - radius)
    m = np.clip(0.5 - outside / feather, 0, 1)
    return (m * 255).astype(np.uint8)


def tile_region(img):
    """Crop the tile, and return (rgb, alpha, meta).

    The crop is padded by `PAD` pixels on every side so the squircle's
    straight edges fall strictly inside the canvas. Without the padding the
    edge pixels land on the very first/last row, where the SDF clamps them
    to a half-transparent value and the icon grows a pale border.

    The alpha is the squircle shape pulled in by a pixel: the outermost
    pixels of the crop are a blend of artwork and black, and that dark
    fringe is what makes an extracted icon look like it has a grey outline.
    """
    a = np.asarray(img).astype(np.int16)
    L, R, T, B = detect_tile(a)
    w, h = R - L + 1, B - T + 1

    # The straight left edge starts where the top-left arc ends, so the corner
    # radius is the distance from the tile's top edge to that first straight row.
    solid = a.max(axis=2) > SURROUND_MAX
    first_straight = None
    for y in range(T, B + 1):
        xs = np.flatnonzero(solid[y])
        if xs.size and int(xs.min()) <= L + 1:
            first_straight = y
            break
    radius = max(8, (first_straight - T) if first_straight else int(w * 0.2))

    PAD = 3
    box = (L - PAD, T - PAD, R + 1 + PAD, B + 1 + PAD)
    padded = img.crop(box)
    pw, ph = padded.size

    # The squircle is positioned in the padded canvas, offset by PAD.
    yy, xx = np.mgrid[0:ph, 0:pw].astype(np.float32)
    cx = (w - 1) / 2.0 + PAD
    cy = (h - 1) / 2.0 + PAD
    hw, hh = w / 2.0, h / 2.0
    dx = np.abs(xx - cx) - (hw - radius)
    dy = np.abs(yy - cy) - (hh - radius)
    outside = (np.sqrt(np.maximum(dx, 0) ** 2 + np.maximum(dy, 0) ** 2)
               + np.minimum(np.maximum(dx, dy), 0.0) - radius)
    alpha = (np.clip(0.5 - outside / 2.4, 0, 1) * 255).astype(np.uint8)

    rgb = np.asarray(padded).astype(np.uint8)

    # Inpaint the 2px feather band from the interior so the cropped edge keeps
    # the artwork's own colour instead of a darkened blend.
    band = ((alpha > 0) & (alpha < 250)).astype(np.uint8) * 255
    if band.any():
        rgb = cv2.inpaint(cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR), band, 3,
                          cv2.INPAINT_TELEA)
        rgb = cv2.cvtColor(rgb, cv2.COLOR_BGR2RGB)

    # Pull the alpha in by one pixel so no traced outline survives.
    alpha = np.asarray(Image.fromarray(alpha).filter(ImageFilter.MinFilter(3)))
    return rgb, alpha, (L, R, T, B, radius)


def rounded_master(img, size=1024):
    """The tile on a transparent rounded square -- the web brand mark."""
    rgb, alpha, _ = tile_region(img)
    h, w = alpha.shape
    side = max(w, h)
    canvas = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    canvas.paste(Image.fromarray(rgb), ((side - w) // 2, (side - h) // 2),
                  Image.fromarray(alpha))
    return canvas.resize((size, size), Image.LANCZOS)


def square_master(img, size=1024):
    """A full square icon -- what iOS and Android expect.

    iOS and Android mask a square asset themselves, so the corners outside
    the artwork's own squircle have to be filled. Filling the masked
    outside-of-squircle region with `cv2.inpaint` propagates the surrounding
    interior colours (the navy rim) outward seamlessly, instead of a hard
    uniform frame -- and there is no risk of `np.roll` dragging the bright
    blue rim across the canvas.
    """
    rgb, alpha, _ = tile_region(img)
    h, w = alpha.shape
    side = max(w, h)

    canvas_rgb = np.zeros((side, side, 3), np.uint8)
    canvas_a = np.zeros((side, side), np.uint8)
    ox, oy = (side - w) // 2, (side - h) // 2
    canvas_rgb[oy:oy + h, ox:ox + w] = rgb
    canvas_a[oy:oy + h, ox:ox + w] = alpha

    # Outside the squircle -> inpaint the interior colours outward so the
    # fill matches the artwork's own edge at every point.
    outside = (canvas_a <= 250)
    if outside.any():
        bgr = cv2.cvtColor(canvas_rgb, cv2.COLOR_RGB2BGR)
        filled = cv2.inpaint(bgr, outside.astype(np.uint8) * 255, 200,
                             cv2.INPAINT_TELEA)
        canvas_rgb = cv2.cvtColor(filled, cv2.COLOR_BGR2RGB)
        canvas_a[outside] = 255

    out = Image.fromarray(canvas_rgb, 'RGB')
    return out.resize((size, size), Image.LANCZOS)


def write_preview(img):
    """Contact sheet of the candidate treatments."""
    rgb, alpha, meta = tile_region(img)
    tiles = [
        ('as uploaded', img.resize((300, 300), Image.LANCZOS)),
        ('tight crop', Image.fromarray(rgb).resize((300, 300), Image.LANCZOS)),
        ('rounded + alpha', rounded_master(img, 300)),
        ('square master', square_master(img, 300)),
    ]

    sheet = Image.new('RGB', (len(tiles) * 320, 380), (245, 247, 250))
    d = ImageDraw.Draw(sheet)
    for i, (name, t) in enumerate(tiles):
        if t.mode == 'RGBA':
            bg = Image.new('RGB', t.size, (255, 255, 255))
            bg.paste(t, (0, 0), t)
            t = bg
        sheet.paste(t, (i * 320 + 10, 10))
        d.text((i * 320 + 10, 320), name, fill=(20, 25, 35))
    d.text((10, 350), 'tile bbox L=%d R=%d T=%d B=%d  corner radius=%d' % meta,
           fill=(90, 100, 115))
    out = os.path.join(ROOT, 'tool', '_diag', 'icon_preview.png')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    sheet.save(out)
    print('wrote', out)


def main():
    img = load()
    if '--preview' in sys.argv:
        write_preview(img)
        return

    square = square_master(img, 1024)
    rounded = rounded_master(img, 1024)

    # --- web ---------------------------------------------------------------
    os.makedirs(WEB_ASSETS, exist_ok=True)
    square.save(os.path.join(WEB_ASSETS, 'sitewise-icon.png'), optimize=True)
    for px in (16, 32, 48, 64, 180, 192, 512):
        square.resize((px, px), Image.LANCZOS).save(
            os.path.join(WEB_ASSETS, 'sitewise-icon-%d.png' % px), optimize=True)
    rounded.resize((64, 64), Image.LANCZOS).save(
        os.path.join(WEB_ASSETS, 'sitewise-mark-64.png'), optimize=True)
    print('web assets written to', WEB_ASSETS)

    # --- android -----------------------------------------------------------
    android = os.path.join(MOBILE, 'android', 'app', 'src', 'main', 'res')
    for folder, px in (('mipmap-mdpi', 48), ('mipmap-hdpi', 72), ('mipmap-xhdpi', 96),
                       ('mipmap-xxhdpi', 144), ('mipmap-xxxhdpi', 192)):
        d = os.path.join(android, folder)
        os.makedirs(d, exist_ok=True)
        square.resize((px, px), Image.LANCZOS).save(os.path.join(d, 'ic_launcher.png'), optimize=True)
    print('android launcher icons written')

    # --- ios ---------------------------------------------------------------
    ios_dir = os.path.join(MOBILE, 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
    with open(os.path.join(ios_dir, 'Contents.json'), encoding='utf8') as f:
        spec = json.load(f)
    written = 0
    for entry in spec['images']:
        name = entry.get('filename')
        if not name:
            continue
        size = float(entry['size'].split('x')[0])
        scale = int(entry['scale'].rstrip('x'))
        px = int(round(size * scale))
        square.resize((px, px), Image.LANCZOS).save(os.path.join(ios_dir, name), optimize=True)
        written += 1
    print('ios app icons written (%d)' % written)

    # --- macos -------------------------------------------------------------
    mac_dir = os.path.join(MOBILE, 'macos', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
    for px in (16, 32, 64, 128, 256, 512, 1024):
        p = os.path.join(mac_dir, 'app_icon_%d.png' % px)
        if os.path.exists(p):
            square.resize((px, px), Image.LANCZOS).save(p, optimize=True)
    print('macos app icons written')


if __name__ == '__main__':
    main()
