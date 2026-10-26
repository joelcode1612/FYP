"""Numeric probe of make_app_icon.py masters (no image viewing needed)."""
import numpy as np
import make_app_icon as M

img = M.load()

# --- tile bbox / radius ---
a = np.asarray(img).astype(np.int16)
L, R, T, B = M.detect_tile(a)
print('tile bbox L=%d R=%d T=%d B=%d  w=%d h=%d' % (L, R, T, B, R - L + 1, B - T + 1))

# --- tile_region alpha sanity (corners should be 0, interior solid) ---
rgb, alpha, meta = M.tile_region(img)
print('tile_region alpha: shape', alpha.shape,
      'corner0=%d cornerN=%d' % (alpha[0, 0], alpha[-1, -1]),
      'mean(interior)=%.1f' % alpha[alpha > 200].mean() if (alpha > 200).any() else 0,
      'min=%d max=%d' % (alpha.min(), alpha.max()))
# count of half-transparent band pixels (a band wider than ~4px would be a bug)
band = ((alpha > 10) & (alpha < 245)).sum()
print('half-transparent band pixels (should be thin ~ <2k):', band)

# --- rounded master ---
rm = np.asarray(M.rounded_master(img, 1024))
print('\nrounded_master 1024:',
      'corner TL alpha=%d TR=%d BL=%d BR=%d' % (
          rm[0, 0, 3], rm[0, -1, 3], rm[-1, 0, 3], rm[-1, -1, 3]))
# mid-left-edge vertical alpha profile across the row that should be solid interior
mid = rm.shape[0] // 2
profile = rm[mid, :, 3]
solid = (profile == 255).sum()
trans = (profile == 0).sum()
half = ((profile > 0) & (profile < 255)).sum()
print('  mid-row alpha: solid=%d transparent=%d feather=%d' % (solid, trans, half))
# is there a persistent >120 alpha column near the very edge that reads as a white rim?
edge_rim = profile[:8]
print('  left 8px alpha=', edge_rim.tolist())

# --- square master ---
sm_img = M.square_master(img, 1024)
sm = np.asarray(sm_img)
print('\n_square_master 1024: shape', sm.shape, 'dtype', sm.dtype,
      'global max RGB=', sm[..., :3].max())
print('  pixel (50,50)=', sm[50, 50, :3].tolist(),
      'pixel (0,0)=', sm[0, 0, :3].tolist())
print('  pixel (120,120)=', sm[120, 120, :3].tolist())
# corner 12x12 mean RGB (diffused navy, not bright stripe)
def region_mean(arr, y0, y1, x0, x1):
    return arr[y0:y1, x0:x1, :3].reshape(-1, 3).mean(axis=0).astype(int)
print('  corner TL 40x40 RGB=', region_mean(sm, 0, 40, 0, 40).tolist())
print('  corner TR 40x40 RGB=', region_mean(sm, 0, 40, -40, None).tolist())
print('  corner BL 40x40 RGB=', region_mean(sm, -40, None, 0, 40).tolist())
print('  corner BR 40x40 RGB=', region_mean(sm, -40, None, -40, None).tolist())
# global max blue among diffused (unknown) corners -- a bright blue stripe would spike
corner_mask = np.zeros(sm.shape[:2], bool)
s = 60
corner_mask[:s, :s] = True
corner_mask[:s, -s:] = True
corner_mask[-s:, :s] = True
corner_mask[-s:, -s:] = True
cb = sm[corner_mask, 2]
print('  corner-region max B=%d (bright stripe would be >200)' % cb.max())
print('  DONE')
