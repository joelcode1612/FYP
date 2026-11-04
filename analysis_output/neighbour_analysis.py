"""Sitewise property neighbour analysis (500 m / 1 km / 2 km / 3 km).

Reads `Clean Property Data 955` from the user's workbook, computes Haversine
neighbour counts against the same 955-property population for every property,
validates the minimum-three requirement, and writes the mandated Excel
deliverable. No records are invented, moved, or excluded from the main sheet.
"""
import numpy as np
import pandas as pd

SRC = r"C:\Users\Lenovo\Downloads\Telegram Desktop\Full_Complete_Property.xlsx"
SHEET = "Clean Property Data 955"
OUT_DIR = r"C:\Users\Lenovo\AndroidStudioProjects\FYP\analysis_output"
OUT = OUT_DIR + r"\Sitewise_Property_Neighbors_500m_1km_2km_3km.xlsx"

RADII = [500, 1000, 2000, 3000]
RADIUS_COLS = [
    "nearby_properties_500m",
    "nearby_properties_1km",
    "nearby_properties_2km",
    "nearby_properties_3km",
]
BAND_COLS = [
    "band_0_500m",
    "band_500m_1km",
    "band_1km_2km",
    "band_2km_3km",
]

# ---------------------------------------------------------------- load
df = pd.read_excel(SRC, sheet_name=SHEET)
n = len(df)
assert n == 955, f"expected 955 rows, got {n}"
orig_cols = list(df.columns)
ids = df["canonical_property_id"].astype(str)

lat = pd.to_numeric(df["langitude"], errors="coerce").to_numpy(float)
lon = pd.to_numeric(df["longitude"], errors="coerce").to_numpy(float)

# ------------------------------------------------- coordinate validation
# Generous Malaysia bounding box: lat 0.8-7.5, lon 99.6-119.3 (plus margin).
LAT_LO, LAT_HI, LON_LO, LON_HI = -1.5, 8.5, 97.0, 121.0

quality = np.empty(n, dtype=object)
for i in range(n):
    la, lo = lat[i], lon[i]
    if not np.isfinite(la) or not np.isfinite(lo) or (la == 0 and lo == 0):
        quality[i] = "missing_or_zero"
    elif not (LAT_LO <= la <= LAT_HI and LON_LO <= lo <= LON_HI):
        quality[i] = "out_of_range"
    elif 97.0 <= la <= 121.0 and -1.5 <= lo <= 8.5:
        quality[i] = "swapped_suspected"  # plausible transposition; not auto-fixed
    else:
        quality[i] = "candidate"

valid = quality == "candidate"
vi = np.flatnonzero(valid)
vlat, vlon = lat[vi], lon[vi]

# exact-duplicate coordinates among valid properties
key = np.round(np.stack([vlat, vlon], 1), 7)
_, inv, cnts = np.unique(key, axis=0, return_inverse=True, return_counts=True)
dup_mask = cnts[inv] > 1

# decimal precision (area-centroid / rounded-coordinate suspicion)
def decimals(x):
    s = f"{float(x):.10f}".rstrip("0").rstrip(".")
    return len(s.split(".")[1]) if "." in s else 0

prec = np.array([decimals(x) for x in vlat])
low_prec = prec <= 2  # ~1.1 km grid or coarser

q2 = quality.copy()
for k, i in enumerate(vi):
    if dup_mask[k]:
        q2[i] = "duplicate_exact"
    elif low_prec[k]:
        q2[i] = "low_precision_area_centroid"
    else:
        q2[i] = "ok"
quality = q2
usable = np.isin(quality, ["ok", "duplicate_exact", "low_precision_area_centroid"])
ui = np.flatnonzero(usable)
ulat, ulon = lat[ui], lon[ui]

# provisional labelling per spec §5 (approximate locations -> provisional counts)
provisional = np.isin(quality, ["duplicate_exact", "low_precision_area_centroid"])

# ------------------------------------------------------------ haversine
R = 6_371_008.8  # mean Earth radius, metres
phi = np.radians(ulat)
lam = np.radians(ulon)
dphi = phi[:, None] - phi[None, :]
dlam = lam[:, None] - lam[None, :]
a = (
    np.sin(dphi / 2) ** 2
    + np.cos(phi)[:, None] * np.cos(phi)[None, :] * np.sin(dlam / 2) ** 2
)
dist = 2 * R * np.arcsin(np.sqrt(np.clip(a, 0, 1)))
# Round to the delivered precision (0.1 m) BEFORE thresholding, so the pair
# sheet and the radius counts agree exactly on the stored values.
dist = np.round(dist, 1)
np.fill_diagonal(dist, np.inf)  # a property is never its own neighbour

uid = ids.to_numpy()[ui]
utitle = df["property_title"].fillna("").astype(str).to_numpy()[ui]
uaddr = df["property_address"].fillna("").astype(str).to_numpy()[ui]

m = len(ui)
counts = {r: (dist <= r).sum(axis=1) for r in RADII}
c500, c1k, c2k, c3k = (counts[r] for r in RADII)

# nearest three within 3 km
near_ids = np.empty((m, 3), dtype=object)
near_dist = np.full((m, 3), np.nan)
for i in range(m):
    order = np.argsort(dist[i])[:3]
    for k, j in enumerate(order):
        if dist[i, j] <= 3000:
            near_ids[i, k] = uid[j]
            near_dist[i, k] = round(float(dist[i, j]), 1)
        else:
            near_ids[i, k] = ""

# -------------------------------------------------- assemble result frame
res = df.copy()

def full_float(arr):
    out = np.full(n, np.nan)
    out[ui] = arr
    return out

def full_obj(arr):
    out = np.full(n, "UNKNOWN_INVALID_COORDINATE", dtype=object)
    out[ui] = arr
    return out

for col, arr in zip(RADIUS_COLS, [c500, c1k, c2k, c3k]):
    res[col] = full_float(arr.astype(float))
for col, arr in zip(
    BAND_COLS,
    [c500, c1k - c500, c2k - c1k, c3k - c2k],
):
    res[col] = full_float(arr.astype(float))
for k, col in enumerate(["nearest_1_id", "nearest_2_id", "nearest_3_id"]):
    res[col] = full_obj(near_ids[:, k])
for k, col in enumerate(
    ["nearest_1_distance_m", "nearest_2_distance_m", "nearest_3_distance_m"]
):
    res[col] = full_float(near_dist[:, k])

for col, arr in zip(
    ["minimum_3_500m", "minimum_3_1km", "minimum_3_2km", "minimum_3_3km"],
    [c500, c1k, c2k, c3k],
):
    res[col] = full_obj(np.where(arr >= 3, "PASS", "BELOW_MINIMUM_3"))
all_pass = (c500 >= 3) & (c1k >= 3) & (c2k >= 3) & (c3k >= 3)
res["minimum_3_all_radii"] = full_obj(
    np.where(all_pass, "PASS", "BELOW_MINIMUM_3")
)

res["coordinate_quality"] = quality
res["counts_provisional"] = np.where(provisional, "yes", "no")

# ------------------------------------------------------- neighbour pairs
rows_i, rows_j = np.nonzero(dist <= 3000)
pairs = pd.DataFrame(
    {
        "target_property_id": uid[rows_i],
        "target_property_title": utitle[rows_i],
        "target_property_address": uaddr[rows_i],
        "neighbour_property_id": uid[rows_j],
        "neighbour_property_title": utitle[rows_j],
        "neighbour_property_address": uaddr[rows_j],
        "distance_m": np.round(dist[rows_i, rows_j], 1),
    }
)
pairs["radius_band"] = pd.cut(
    pairs["distance_m"],
    [-0.1, 500, 1000, 2000, 3000],
    labels=["0-500m", "500m-1km", "1km-2km", "2km-3km"],
).astype(str)

# ------------------------------------------------------- below-minimum
bad = res["minimum_3_all_radii"] == "BELOW_MINIMUM_3"
below = res.loc[bad, orig_cols + RADIUS_COLS + BAND_COLS + ["minimum_3_all_radii", "coordinate_quality"]].copy()
for col, full_col in zip(BAND_COLS, RADIUS_COLS):
    pass
below["shortfall_500m"] = (3 - below["nearby_properties_500m"]).clip(lower=0)
below["shortfall_1km"] = (3 - below["nearby_properties_1km"]).clip(lower=0)
below["shortfall_2km"] = (3 - below["nearby_properties_2km"]).clip(lower=0)
below["shortfall_3km"] = (3 - below["nearby_properties_3km"]).clip(lower=0)

# ------------------------------------------------------------ QA numbers
monotonic = bool(
    (
        (res[RADIUS_COLS].dropna().diff(axis=1).dropna(axis=1) >= 0).all().all()
    )
)
self_count = int(sum(
    (res[c] == res["canonical_property_id"]).sum()
    for c in ["nearest_1_id", "nearest_2_id", "nearest_3_id"]
))
dup_pairs = int(pairs.duplicated().sum())
pair_reconciles = int(len(pairs) == int(c3k.sum()))
pass_500 = int((res["minimum_3_500m"] == "PASS").sum())
pass_1k = int((res["minimum_3_1km"] == "PASS").sum())
pass_2k = int((res["minimum_3_2km"] == "PASS").sum())
pass_3k = int((res["minimum_3_3km"] == "PASS").sum())
pass_all = int((res["minimum_3_all_radii"] == "PASS").sum())
fail_all = int((res["minimum_3_all_radii"] == "BELOW_MINIMUM_3").sum())
unknown = int((res["minimum_3_all_radii"] == "UNKNOWN_INVALID_COORDINATE").sum())

qa = pd.DataFrame(
    [
        ("total_properties_in_source", n),
        ("valid_coordinates", int(usable.sum())),
        ("invalid_or_flagged_coordinates", int(n - usable.sum())),
        ("coordinate_quality_missing_or_zero", int((quality == "missing_or_zero").sum())),
        ("coordinate_quality_out_of_range", int((quality == "out_of_range").sum())),
        ("coordinate_quality_swapped_suspected", int((quality == "swapped_suspected").sum())),
        ("coordinate_quality_duplicate_exact", int((quality == "duplicate_exact").sum())),
        ("coordinate_quality_low_precision_area_centroid", int((quality == "low_precision_area_centroid").sum())),
        ("coordinate_quality_ok", int((quality == "ok").sum())),
        ("counts_provisional_yes", int((res["counts_provisional"] == "yes").sum())),
        ("pass_500m", pass_500),
        ("pass_1km", pass_1k),
        ("pass_2km", pass_2k),
        ("pass_3km", pass_3k),
        ("pass_all_radii", pass_all),
        ("below_minimum_any_radius", fail_all),
        ("unknown_invalid_coordinate", unknown),
        ("qa_monotonic_counts_500<=1k<=2k<=3k", monotonic),
        ("qa_property_counted_as_own_neighbour", self_count),
        ("qa_duplicate_target_neighbour_pairs", dup_pairs),
        ("qa_pair_rows_equal_sum_of_3km_counts", pair_reconciles),
        ("neighbour_pair_rows_within_3km", int(len(pairs))),
        ("additional_verified_properties_added", 0),
        ("additional_source_inspection", "C:/osm = OSM PBF footprints + routing (excluded per spec); competitor_scraper = F&B Google/Overture/OSM POIs (excluded per spec); no authorized PostGIS commercial-rental table found"),
    ],
    columns=["check", "value"],
)

# ---------------------------------------------------------------- write
import os

os.makedirs(OUT_DIR, exist_ok=True)
addl = pd.DataFrame(
    {
        "note": [
            "No additional commercial rental-property listings were added. Inspection of the specified sources found only OSM building footprints / routing data (C:/osm) and F&B competitor POIs from Google Maps, Overture, OSM and Foursquare (competitor_scraper). Spec section 4 explicitly excludes footprints, business POIs and F&B competitors as neighbour sources. No authorized PostGIS commercial-rental table was available. Actual counts are preserved and affected properties are marked BELOW_MINIMUM_3."
        ]
    }
)

with pd.ExcelWriter(OUT, engine="openpyxl") as xw:
    res.to_excel(xw, sheet_name="Property Neighbor Counts", index=False)
    pairs.to_excel(xw, sheet_name="Neighbor Details", index=False)
    below.to_excel(xw, sheet_name="Below Minimum 3", index=False)
    addl.to_excel(xw, sheet_name="Additional Verified Properties", index=False)
    qa.to_excel(xw, sheet_name="QA Summary", index=False)

print("wrote", OUT)
print(
    f"pass@500m={pass_500} pass@1km={pass_1k} pass@2km={pass_2k} "
    f"pass@3km={pass_3k} pass_all={pass_all} below={fail_all} unknown={unknown}"
)
print(
    "quality:",
    {q: int((quality == q).sum()) for q in pd.unique(quality)},
)
print("pairs:", len(pairs), "monotonic:", monotonic, "dup_pairs:", dup_pairs)
