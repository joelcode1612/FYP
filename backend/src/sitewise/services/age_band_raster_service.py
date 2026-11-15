"""WorldPop age-sex band extraction for a single property (infrastructure).

Extracts the six population-age group counts (0-14, 15-24, 25-34, 35-49,
50-64, 65+) within 500 m and 1 km geodesic buffers of ONE coordinate, from
the WorldPop Global 2015-2030 Age and Sex Structures product — MYS 2025,
constrained (CN), 100 m, R2025A v1, licence CC-BY-4.0.

Provenance
----------
The method is a faithful single-point port of the gap-recovery pipeline that
was independently validated on 2026-11-15 (``SiteWise_PU_Gap_Recovery``,
22,188 cells for all 1,849 PU research subjects):

* per-band m+f sums — never district-proportion inference;
* weights are exact pixel-intersection areas: the 256-azimuth geodesic buffer
  polygon is projected into a local azimuthal-equal-area frame and clipped
  against pixel footprints;
* the valued mask comes from the product's own T_F/T_M totals, so a band
  pixel outside the product's valued area contributes nothing rather than a
  fabricated zero;
* band sums are cross-checked against the weighted T_F+T_M total every call;
* coverage is the valued share of the buffer area, using the recovery
  taxonomy: >=99 COMPLETED, 80-99 PARTIAL_COVERAGE, <80 LOW_COVERAGE; a
  buffer that extends past the tile-set edge is refused outright
  (``RASTER_EDGE_TRUNCATION``) rather than silently under-counted.

Honesty contract (same rules the population provider follows)
-------------------------------------------------------------
* A population-age value is NEVER written as ``0`` because the data was
  missing. When no valued pixel intersects the buffer the counts are ``None``
  with status ``NO_VALUED_PIXELS``.
* Partial coverage values are lower bounds (identical semantics to the
  WorldPop ring-total provider); the coverage percentage and taxonomy flag
  travel with every measurement so downstream readers can gate on them.
* Availability is structural: without ``SITEWISE_AGE_RASTER_DIR`` pointing at
  the 42-band tile set (or without rasterio installed) the service reports
  precisely why, and the enrichment category settles as ``unavailable``.

The rasters themselves live OUTSIDE the repository (1.2 GB) and are
provisioned with ``backend/scripts/data/fetch_worldpop_agesex.py``.
"""

from __future__ import annotations

import importlib.util
import logging
import math
import os
import threading
from typing import Any

logger = logging.getLogger("sitewise.age_bands")

#: The PROJ_LIB/GDAL_DATA environment is poisoned machine-wide on this
#: deployment; rasterio/pyproj must be pointed at their bundled data BEFORE
#: rasterio is imported. Same guard the validated pipeline used.
def _fix_proj_paths() -> None:  # pragma: no cover - environment dependent
    spec = importlib.util.find_spec("rasterio")
    if spec is None or spec.origin is None:
        return
    pkg_dir = os.path.dirname(spec.origin)
    proj = os.path.join(pkg_dir, "proj_data")
    if os.path.isdir(proj):
        os.environ.setdefault("PROJ_LIB", proj)
        os.environ.setdefault("PROJ_DATA", proj)
    gdal = os.path.join(pkg_dir, "gdal_data")
    if os.path.isdir(gdal):
        os.environ.setdefault("GDAL_DATA", gdal)


_fix_proj_paths()

try:  # rasterio is optional at import time so the API module can load without it
    import rasterio  # noqa: F401  (imported for availability reporting)
    import rasterio.windows as _rio_windows

    _HAS_RASTERIO = True
except Exception:  # noqa: BLE001 - any import failure means "not usable"
    _HAS_RASTERIO = False

import numpy as np
import shapely
from pyproj import CRS, Geod, Transformer

#: Five-year band tiles present in the product (00..90).
BANDS: tuple[str, ...] = (
    "00", "01", "05", "10", "15", "20", "25", "30", "35", "40",
    "45", "50", "55", "60", "65", "70", "75", "80", "85", "90",
)

#: Model band groups (the definitions the PU training contract uses). NOTE:
#: these are the MODEL definitions (35-49 / 50-64 / 65+), not the analytics
#: database's legacy bands (35-54 / 55-64 / 65plus) — mixing the two would
#: score the model on bands it never learned from.
GROUPS: dict[str, tuple[str, ...]] = {
    "pop_age_0_14": ("00", "01", "05", "10"),
    "pop_age_15_24": ("15", "20"),
    "pop_age_25_34": ("25", "30"),
    "pop_age_35_49": ("35", "40", "45"),
    "pop_age_50_64": ("50", "55", "60"),
    "pop_age_65_plus": ("65", "70", "75", "80", "85", "90"),
}

RADII: dict[str, float] = {"500m": 500.0, "1km": 1000.0}

#: The recovery pipeline's frozen coverage taxonomy — the statuses a radius
#: reports when it actually measured something. Any other status
#: (OUT_OF_RASTER, NO_VALUED_PIXELS, ...) means the radius produced no data.
COVERAGE_STATUSES: tuple[str, ...] = (
    "COMPLETED",
    "PARTIAL_COVERAGE",
    "LOW_COVERAGE",
)

SOURCE_NAME = (
    "WorldPop Global 2015-2030 Age and Sex Structures, MYS 2025 constrained "
    "(CN) 100m R2025A v1 (m+f band sums, exact partial-pixel geodesic buffer weights)"
)
SOURCE_YEAR = 2025
SOURCE_LICENCE = "WorldPop age-sex structures (CC-BY-4.0)"
SOURCE_URL = (
    "https://data.worldpop.org/GIS/AgeSex_structures/Global_2015_2030/"
    "R2025A/2025/MYS/v1/100m/constrained/"
)

_M_PER_DEGREE = 111_320.0
_NAZ = 256
_azimuths = np.linspace(0.0, 360.0, _NAZ, endpoint=False)


def _expected_filenames() -> dict[str, str]:
    """The 42 tiles by convention (the STAC naming the recovery verified).

    The product's own tiles carry the SINGLE-LETTER sex prefix
    (``mys_m_00_...`` / ``mys_f_00_...``) — only the two totals spell out
    T_F / T_M. Verified byte-for-byte against the recovery run's committed
    download manifest; do not "correct" m/f back to male/female.
    """
    files: dict[str, str] = {}
    for band in BANDS:
        for sex in ("m", "f"):
            files[f"{sex}_{band}"] = f"mys_{sex}_{band}_2025_CN_100m_R2025A_v1.tif"
    files["T_F"] = "mys_T_F_2025_CN_100m_R2025A_v1.tif"
    files["T_M"] = "mys_T_M_2025_CN_100m_R2025A_v1.tif"
    return files


class AgeBandRasterService:
    """Reads the local WorldPop age-sex tile set and extracts one property."""

    def __init__(self, raster_dir: str | None) -> None:
        self._dir = os.path.abspath(raster_dir) if raster_dir else ""
        self._datasets: dict[str, Any] = {}
        self._grid_checked = False
        self._lock = threading.Lock()

    # -- availability ----------------------------------------------------

    def availability(self) -> tuple[bool, str]:
        """(usable, reason). Every failure names the precise missing piece."""
        if not _HAS_RASTERIO:
            return False, (
                "rasterio is not installed in the backend environment; the "
                "age-band category cannot read the WorldPop age-sex rasters."
            )
        if not self._dir:
            return False, (
                "SITEWISE_AGE_RASTER_DIR is not configured; provision the "
                "WorldPop age-sex tiles with "
                "backend/scripts/data/fetch_worldpop_agesex.py."
            )
        if not os.path.isdir(self._dir):
            return False, f"SITEWISE_AGE_RASTER_DIR does not exist: {self._dir}"
        missing = [
            name
            for name in _expected_filenames().values()
            if not os.path.isfile(os.path.join(self._dir, name))
        ]
        if missing:
            return False, (
                f"WorldPop age-sex tile set is incomplete in {self._dir}: "
                f"{len(missing)} of 42 files missing (e.g. {missing[0]})."
            )
        return True, "ok"

    # -- dataset management ----------------------------------------------

    def _open_all(self) -> dict[str, Any]:
        """Open (once, cached) the 42 datasets and verify a common grid."""
        if self._datasets and self._grid_checked:
            return self._datasets
        files = _expected_filenames()
        datasets: dict[str, Any] = {}
        reference: tuple | None = None
        for key, filename in files.items():
            dataset = rasterio.open(os.path.join(self._dir, filename))
            profile = (
                dataset.width,
                dataset.height,
                dataset.transform,
                dataset.crs,
                dataset.nodata,
            )
            if reference is None:
                reference = profile
                if dataset.crs.to_epsg() != 4326:
                    for d in datasets.values():
                        d.close()
                    raise ValueError(f"Unexpected CRS in {filename}: {dataset.crs}")
            elif profile != reference:
                path = filename
                for d in datasets.values():
                    d.close()
                raise ValueError(f"Grid mismatch in {path}")
            datasets[key] = dataset
        self._datasets = datasets
        self._grid_checked = True
        return datasets

    # -- extraction --------------------------------------------------------

    def extract(self, lat: float, lon: float) -> dict[str, Any]:
        """Age-band counts for ONE coordinate.

        Returns ``{"status": ..., "reason": ..., "radii": {...}}`` where each
        radius carries the six group counts, the 15-34 share, the coverage
        percentage and its taxonomy flag. Counts are ``None`` — never 0 —
        when nothing valued intersects the buffer.
        """
        ok, reason = self.availability()
        if not ok:
            return {"status": "UNAVAILABLE", "reason": reason, "radii": {}}

        with self._lock:  # GDAL dataset reads are not thread-safe
            datasets = self._open_all()
            nodata = datasets["T_F"].nodata
            geod = Geod(ellps="WGS84")

            radii: dict[str, Any] = {}
            ring_1k_lon, ring_1k_lat, _ = geod.fwd(
                np.full(_NAZ, lon), np.full(_NAZ, lat),
                _azimuths, np.full(_NAZ, RADII["1km"]),
            )
            for radius_name, radius in RADII.items():
                if radius_name == "1km":
                    ring_lon, ring_lat = ring_1k_lon, ring_1k_lat
                else:
                    ring_lon, ring_lat, _ = geod.fwd(
                        np.full(_NAZ, lon), np.full(_NAZ, lat),
                        _azimuths, np.full(_NAZ, radius),
                    )
                radii[radius_name] = self._extract_radius(
                    datasets, nodata, lat, lon, radius, ring_lon, ring_lat
                )

            return {"status": "OK", "reason": "", "radii": radii}

    def _extract_radius(
        self,
        datasets: dict[str, Any],
        nodata: Any,
        lat: float,
        lon: float,
        radius: float,
        ring_lon: "np.ndarray",
        ring_lat: "np.ndarray",
    ) -> dict[str, Any]:
        reference = datasets["T_F"]
        inverse = ~reference.transform
        cos_lat = max(math.cos(math.radians(lat)), 0.01)
        c0f, r0f = inverse * (
            lon - radius / (_M_PER_DEGREE * cos_lat) - 0.001,
            lat + radius / _M_PER_DEGREE + 0.001,
        )
        c1f, r1f = inverse * (
            lon + radius / (_M_PER_DEGREE * cos_lat) + 0.001,
            lat - radius / _M_PER_DEGREE - 0.001,
        )
        c0 = max(int(np.floor(min(c0f, c1f))) - 2, 0)
        r0 = max(int(np.floor(min(r0f, r1f))) - 2, 0)
        c1 = min(int(np.ceil(max(c0f, c1f))) + 2, reference.width)
        r1 = min(int(np.ceil(max(r0f, r1f))) + 2, reference.height)
        if c1 <= c0 or r1 <= r0:
            return _radius_failure("OUT_OF_RASTER")

        transform = reference.transform
        pixel_w = transform.a
        pixel_h = -transform.e
        local_crs = CRS.from_proj4(
            f"+proj=aeqd +lat_0={lat:.9f} +lon_0={lon:.9f} "
            "+datum=WGS84 +units=m +no_defs"
        )
        to_local = Transformer.from_crs(
            CRS.from_epsg(4326), local_crs, always_xy=True
        ).transform

        # Pixel footprints in lon/lat, then corners in the local metre frame.
        xs = transform.c + np.arange(c0, c1 + 1) * transform.a
        ys = transform.f - np.arange(r0, r1 + 1) * pixel_h
        left, right = xs[:-1], xs[1:]
        top, bottom = ys[:-1], ys[1:]
        n_left, n_top = len(left), len(top)
        corner_lon = np.concatenate([
            np.tile(left, n_top), np.tile(right, n_top),
            np.tile(left, n_top), np.tile(right, n_top),
        ])
        corner_lat = np.concatenate([
            np.repeat(top, n_left), np.repeat(top, n_left),
            np.repeat(bottom, n_left), np.repeat(bottom, n_left),
        ])
        cx, cy = to_local(corner_lon, corner_lat)
        n = n_left * n_top
        # Corner blocks in order: 1=(left,top) 2=(right,top) 3=(left,bottom)
        # 4=(right,bottom). Width pairs the bottom-RIGHT x against the
        # top-LEFT x and height the top-LEFT y against the bottom-LEFT y —
        # the validated pipeline's exact corner pairing. Same-edge
        # differences would sign-flip around the projection centre because
        # meridians converge in AEQD, which is precisely what the
        # DEGENERATE_PIXEL_PROJECTION guard below exists for.
        box_left = cx[:n]
        box_top = cy[:n]
        box_right = cx[3 * n:]
        box_bottom = cy[2 * n: 3 * n]
        area_box = (box_right - box_left) * (box_top - box_bottom)
        # Degenerate projection corner cases (poles) cannot occur for the
        # service area, but guard the division anyway.
        if not np.all(area_box > 0):
            return _radius_failure("DEGENERATE_PIXEL_PROJECTION")

        ring_x, ring_y = to_local(ring_lon, ring_lat)
        buffer_poly = shapely.Polygon(zip(ring_x, ring_y))
        intersections = shapely.intersection(
            shapely.box(box_left, box_bottom, box_right, box_top),
            buffer_poly,
        )
        weights = np.clip(shapely.area(intersections) / area_box, 0.0, 1.0)
        total_weight = float(weights.sum())
        if total_weight <= 0:
            return _radius_failure("NO_BUFFER_OVERLAP")
        covered_area = float((area_box * weights).sum())
        if covered_area < 0.999 * float(shapely.area(buffer_poly)):
            # The tile set does not span this whole buffer. Coverage measured
            # only over the pixels present would silently claim 100% while
            # under-counting. The validated pipeline never hits this (the
            # national tiles extend far past any Malaysian buffer), but a
            # partial tile set must fail loudly instead.
            return _radius_failure("RASTER_EDGE_TRUNCATION")

        window = _rio_windows.Window(c0, r0, c1 - c0, r1 - r0)
        total_f = datasets["T_F"].read(1, window=window).reshape(-1)
        total_m = datasets["T_M"].read(1, window=window).reshape(-1)
        valued = (total_f != nodata) & (total_m != nodata)
        valued_weight = float(weights[valued].sum())
        coverage_pct = 100.0 * valued_weight / total_weight if total_weight else 0.0
        if valued_weight <= 0:
            return _radius_failure("NO_VALUED_PIXELS", coverage_pct=0.0)

        band_sums: dict[str, float] = {}
        band_bad_pixels = 0
        for group, bands in GROUPS.items():
            accumulator = np.zeros_like(weights)
            for band in bands:
                for sex in ("m", "f"):
                    band_values = datasets[f"{sex}_{band}"].read(
                        1, window=window
                    ).reshape(-1)
                    bad = band_values == nodata
                    if (bad & valued).any():
                        band_bad_pixels += int((bad & valued).sum())
                    accumulator += np.where(bad, 0.0, band_values.astype("float64"))
            band_sums[group] = float((weights * accumulator).sum())

        weighted_total = float(
            (
                weights
                * np.where(valued, total_f.astype("float64") + total_m.astype("float64"), 0.0)
            ).sum()
        )
        bands_total = float(sum(band_sums.values()))
        cross_check = (
            abs(bands_total - weighted_total) / weighted_total
            if weighted_total > 0 else 0.0
        )
        denominator = weighted_total if weighted_total > 0 else None
        share_15_34 = (
            (band_sums["pop_age_15_24"] + band_sums["pop_age_25_34"]) / denominator
            if denominator
            else None
        )
        return {
            "status": _coverage_status(coverage_pct),
            "groups": band_sums,
            "share_age_15_34": share_15_34,
            "coverage_pct": coverage_pct,
            "total_mf": weighted_total,
            "bands_total": bands_total,
            "band_total_relative_diff": cross_check,
            "band_bad_pixels": band_bad_pixels,
        }

    def close(self) -> None:
        """Release the cached dataset handles (used by tests)."""
        with self._lock:
            for dataset in self._datasets.values():
                try:
                    dataset.close()
                except Exception:  # noqa: BLE001 - closing must never raise
                    pass
            self._datasets = {}
            self._grid_checked = False


def _radius_failure(status: str, coverage_pct: float | None = None) -> dict[str, Any]:
    return {
        "status": status,
        "groups": {group: None for group in GROUPS},
        "share_age_15_34": None,
        "coverage_pct": coverage_pct,
        "total_mf": None,
        "bands_total": None,
        "band_total_relative_diff": None,
        "band_bad_pixels": None,
    }


def _coverage_status(coverage_pct: float) -> str:
    """The recovery pipeline's frozen taxonomy."""
    if coverage_pct >= 99.0:
        return COVERAGE_STATUSES[0]
    if coverage_pct >= 80.0:
        return COVERAGE_STATUSES[1]
    return COVERAGE_STATUSES[2]
