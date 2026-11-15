"""WorldPop age-band extraction: validated math on synthetic tiles.

The real MYS tile set is 1.2 GB and lives outside the repository, so every
test here synthesises a tiny EPSG:4326 grid (30x30 pixels of 0.001 deg,
~111 m, centred on a Kuala Lumpur coordinate) with the SAME 42-file layout
the service verifies, then checks the properties the validated recovery
pipeline guarantees:

  uniform field        → exact band ratios, share, cross-check, COMPLETED
  nodata block         → coverage taxonomy, lower-bound counts, share kept
  all-nodata tiles     → NO_VALUED_PIXELS, counts None (never 0)
  far-away point       → OUT_OF_RASTER / NO_BUFFER_OVERLAP (both radii)
  availability chain   → every missing piece named precisely
  enrichment wiring    → measurement keys == owned columns; unavailable pass-through

No database is touched: the enrichment wiring is exercised through
``_age_population`` with ``session=None``, which never queries.
"""

from __future__ import annotations

import numpy as np
import pytest
import rasterio
from rasterio.transform import from_origin

from sitewise.core.config import settings
from sitewise.services import property_enrichment_service as pes
from sitewise.services.age_band_raster_service import (
    COVERAGE_STATUSES,
    SOURCE_NAME,
    SOURCE_YEAR,
    AgeBandRasterService,
    _expected_filenames,
)
from sitewise.services.enrichment_schema import (
    CATEGORIES,
    CATEGORY_PHASE,
    FEATURE_COLUMNS,
    PHASE_POPULATION,
)
from sitewise.services.property_enrichment_service import (
    _MEASUREMENT_COLUMNS,
    PropertyEnrichmentService,
)

#: Extraction point: the centre of the synthetic grid.
LAT, LON = 3.15, 101.65
GRID = 30
RES = 0.001  # degrees (~111 m at this latitude)
NODATA = -99999.0

_TRANSFORM = from_origin(LON - GRID * RES / 2, LAT + GRID * RES / 2, RES, RES)

# Band-value layout that makes every group ratio exact: m bands carry 1.0,
# f bands carry 2.0, so per valued pixel each band pair contributes 3.0 and
# T_M=20, T_F=40, m+f=60. Group sums are (bands_in_group * 3) * total weight:
# 0_14=12, 15_24=6, 25_34=6, 35_49=9, 50_64=9, 65_plus=18 (units of weight).
_M_VALUE, _F_VALUE = 1.0, 2.0
_EXPECTED_GROUPS = {
    "pop_age_0_14": 12.0,
    "pop_age_15_24": 6.0,
    "pop_age_25_34": 6.0,
    "pop_age_35_49": 9.0,
    "pop_age_50_64": 9.0,
    "pop_age_65_plus": 18.0,
}


def _values_for(key: str) -> float:
    if key.startswith("m_"):
        return _M_VALUE
    if key.startswith("f_"):
        return _F_VALUE
    if key == "T_M":
        return 20.0 * _M_VALUE  # 20 bands x 1.0
    if key == "T_F":
        return 20.0 * _F_VALUE  # 20 bands x 2.0 = 40
    raise AssertionError(f"unexpected asset key {key}")


def _write_tile(path, array):
    with rasterio.open(
        path,
        "w",
        driver="GTiff",
        width=GRID,
        height=GRID,
        count=1,
        dtype="float32",
        crs="EPSG:4326",
        transform=_TRANSFORM,
        nodata=NODATA,
    ) as dst:
        dst.write(array.astype("float32"), 1)


def _build_dir(base, block=None, all_nodata=False, center_disk_px=None):
    """42 tiles; optionally nodata-out pixels [block], everything, or a
    centred disk (radius in pixels) — the disk simulates a hole in the
    product's valued area without moving the tiles."""
    base.mkdir(parents=True, exist_ok=True)
    mask = None
    if center_disk_px is not None:
        # Pixel i's centre sits at (i + 0.5) px in transform space, while the
        # extraction point is exactly at GRID/2 px — align the hole with it.
        rows, cols = np.mgrid[0:GRID, 0:GRID]
        mask = np.sqrt(
            (rows + 0.5 - GRID / 2) ** 2 + (cols + 0.5 - GRID / 2) ** 2
        ) < center_disk_px
    for key, filename in _expected_filenames().items():
        array = np.full((GRID, GRID), _values_for(key), dtype="float64")
        if all_nodata:
            array[:] = NODATA
        elif block is not None:
            array[block] = NODATA
        if mask is not None:
            array[mask] = NODATA
        _write_tile(base / filename, array)
    return base


@pytest.fixture()
def uniform_dir(tmp_path):
    return _build_dir(tmp_path / "uniform")


@pytest.fixture()
def partial_dir(tmp_path):
    # A 6x6 pixel block (~443k m^2) around the extraction point, fully inside
    # the 500 m ring (farthest corner ~393 m) and inside the 1 km ring.
    return _build_dir(tmp_path / "partial", block=(slice(12, 18), slice(12, 18)))


@pytest.fixture()
def empty_dir(tmp_path):
    return _build_dir(tmp_path / "empty", all_nodata=True)


@pytest.fixture()
def ring_dir(tmp_path):
    """Valued everywhere except a centred ~612 m disk: the 500 m buffer sits
    entirely inside the hole (even square-pixel corners stay beyond 533 m,
    so NO_VALUED_PIXELS) while the 1 km ring still sees ~50% valued area
    (LOW_COVERAGE) — radii fail independently."""
    return _build_dir(tmp_path / "ring", center_disk_px=5.5)


# ---------------------------------------------------------------------------
# Expected file layout
# ---------------------------------------------------------------------------


def test_expected_layout_matches_validated_pipeline():
    files = _expected_filenames()
    assert len(files) == 42
    assert files["T_F"] == "mys_T_F_2025_CN_100m_R2025A_v1.tif"
    assert files["m_35"] == "mys_m_35_2025_CN_100m_R2025A_v1.tif"
    assert files["f_00"] == "mys_f_00_2025_CN_100m_R2025A_v1.tif"


# ---------------------------------------------------------------------------
# Extraction on the uniform field: exact ratios, cross-check, coverage
# ---------------------------------------------------------------------------


def test_uniform_field_exact_ratios_and_cross_check(uniform_dir):
    service = AgeBandRasterService(str(uniform_dir))
    result = service.extract(LAT, LON)
    assert result["status"] == "OK"

    for label in ("500m", "1km"):
        radius = result["radii"][label]
        assert radius["status"] == "COMPLETED"
        # Every group is (bands * 3) * weight; ratios are exact.
        base = radius["groups"]["pop_age_15_24"]
        assert base > 0
        for group, expected_per_weight in _EXPECTED_GROUPS.items():
            ratio = radius["groups"][group] / base
            assert ratio == pytest.approx(expected_per_weight / 6.0, rel=1e-9)
        # m+f cross-check against the product totals.
        assert radius["band_total_relative_diff"] < 1e-9
        assert radius["share_age_15_34"] == pytest.approx(0.2, abs=1e-9)
        assert radius["coverage_pct"] == pytest.approx(100.0)
        assert radius["band_bad_pixels"] == 0

    # Geodesic buffers nest, and area scales ~ r^2 (256-gon error < 0.1%).
    r500 = result["radii"]["500m"]["groups"]["pop_age_0_14"]
    r1k = result["radii"]["1km"]["groups"]["pop_age_0_14"]
    assert r1k > r500
    assert r1k / r500 == pytest.approx(4.0, rel=0.02)

    # The absolute total is the pixel value times the buffer's pixel-area
    # weight: ~60 * (pi * r^2 / pixel_area). Sanity-band it.
    pixel_area = (RES * 111_320.0) * (RES * 110_600.0)  # ~12,300 m^2
    expected_1km = 60.0 * (np.pi * 1_000_000.0 / pixel_area)
    assert result["radii"]["1km"]["total_mf"] == pytest.approx(expected_1km, rel=0.05)
    service.close()


def test_nodata_block_low_coverage_and_lower_bounds(partial_dir, uniform_dir):
    partial = AgeBandRasterService(str(partial_dir)).extract(LAT, LON)["radii"]
    uniform = AgeBandRasterService(str(uniform_dir)).extract(LAT, LON)["radii"]

    # 500 m: the whole block sits inside it -> coverage ~44% -> LOW_COVERAGE.
    assert partial["500m"]["status"] == "LOW_COVERAGE"
    # 1 km: the block is ~14% of the ring -> ~86% -> PARTIAL_COVERAGE.
    assert partial["1km"]["status"] == "PARTIAL_COVERAGE"
    for label in ("500m", "1km"):
        assert 0.0 < partial[label]["coverage_pct"] < 99.0
        for group in _EXPECTED_GROUPS:
            assert partial[label]["groups"][group] < uniform[label]["groups"][group]
        # Uniform-valued remainder keeps the share exact.
        assert partial[label]["share_age_15_34"] == pytest.approx(0.2, abs=1e-9)
        assert partial[label]["band_total_relative_diff"] < 1e-9


def test_all_nodata_tiles_never_zero(empty_dir):
    service = AgeBandRasterService(str(empty_dir))
    result = service.extract(LAT, LON)
    assert result["status"] == "OK"
    for label in ("500m", "1km"):
        radius = result["radii"][label]
        assert radius["status"] == "NO_VALUED_PIXELS"
        assert all(value is None for value in radius["groups"].values())
        assert radius["share_age_15_34"] is None
        assert radius["total_mf"] is None


def test_far_away_points_report_why(tmp_path, uniform_dir):
    service = AgeBandRasterService(str(uniform_dir))
    # East of the raster: the buffered extent misses the column range entirely.
    east = service.extract(LAT, LON + 0.1)["radii"]
    assert east["500m"]["status"] == "OUT_OF_RASTER"
    assert east["1km"]["status"] == "OUT_OF_RASTER"
    # Far north: both corners sit above the top edge, so the clamped row
    # window is empty (r1 < r0) — reported as OUT_OF_RASTER, not guessed.
    north = service.extract(LAT + 0.2, LON)["radii"]
    assert north["500m"]["status"] == "OUT_OF_RASTER"
    assert north["1km"]["status"] == "OUT_OF_RASTER"


def test_radii_fail_independently_at_the_edge(uniform_dir):
    """Point 557 m above the top edge: the 500 m ring reaches no pixel at all
    (NO_BUFFER_OVERLAP) while the 1 km ring straddles the tile-set edge —
    refused as RASTER_EDGE_TRUNCATION instead of silently under-counting."""
    service = AgeBandRasterService(str(uniform_dir))
    radii = service.extract(LAT + 0.020, LON)["radii"]
    assert radii["500m"]["status"] == "NO_BUFFER_OVERLAP"
    assert all(value is None for value in radii["500m"]["groups"].values())
    assert radii["1km"]["status"] == "RASTER_EDGE_TRUNCATION"
    assert all(value is None for value in radii["1km"]["groups"].values())


# ---------------------------------------------------------------------------
# Availability: every missing piece named precisely
# ---------------------------------------------------------------------------


def test_availability_chain(tmp_path, monkeypatch, uniform_dir):
    not_configured = AgeBandRasterService("")
    ok, reason = not_configured.availability()
    assert not ok
    assert "SITEWISE_AGE_RASTER_DIR is not configured" in reason

    missing_dir = AgeBandRasterService(str(tmp_path / "nope"))
    ok, reason = missing_dir.availability()
    assert not ok
    assert "does not exist" in reason

    empty = AgeBandRasterService(str(tmp_path / "nothing"))
    (tmp_path / "nothing").mkdir()
    ok, reason = empty.availability()
    assert not ok
    assert "42 of 42 files missing" in reason

    monkeypatch.setattr("sitewise.services.age_band_raster_service._HAS_RASTERIO", False)
    ok, reason = AgeBandRasterService(str(uniform_dir)).availability()
    assert not ok
    assert "rasterio is not installed" in reason


def test_grid_mismatch_is_rejected(tmp_path):
    """A tile that does not share the common grid must fail loudly."""
    bad_dir = _build_dir(tmp_path / "bad")
    rogue = bad_dir / _expected_filenames()["T_M"]
    with rasterio.open(rogue, "w", driver="GTiff", width=GRID + 1, height=GRID,
                       count=1, dtype="float32", crs="EPSG:4326",
                       transform=_TRANSFORM, nodata=NODATA) as dst:
        dst.write(np.zeros((GRID, GRID + 1), dtype="float32"), 1)
    service = AgeBandRasterService(str(bad_dir))
    with pytest.raises(ValueError, match="Grid mismatch"):
        service.extract(LAT, LON)


# ---------------------------------------------------------------------------
# Enrichment wiring (no database: session is never queried)
# ---------------------------------------------------------------------------


@pytest.fixture()
def wire(monkeypatch):
    """Point the enrichment service's cached raster service at a given dir."""
    def _wire(directory):
        monkeypatch.setattr(
            pes, "_AGE_BAND_SERVICE", AgeBandRasterService(str(directory))
        )
        return PropertyEnrichmentService(None)._age_population(LAT, LON, {})

    return _wire


def test_measurement_columns_match_schema():
    """The category owns exactly the age columns the schema defines."""
    owned = {col for col, _ in _MEASUREMENT_COLUMNS["age_population"]}
    schema_age = {
        name
        for name, _ in FEATURE_COLUMNS
        if name.startswith(("pop_age_", "share_age_", "age_"))
    }
    assert owned == schema_age
    assert len(owned) == 19
    assert CATEGORY_PHASE["age_population"] == PHASE_POPULATION
    assert "age_population" in CATEGORIES


def test_wiring_current_writes_only_owned_columns(uniform_dir, wire):
    outcome = wire(uniform_dir)
    assert outcome.status == "current"
    owned = {col for col, _ in _MEASUREMENT_COLUMNS["age_population"]}
    assert set(outcome.measurement) == owned
    assert outcome.measurement["age_data_source"] == SOURCE_NAME
    assert outcome.measurement["age_data_year"] == SOURCE_YEAR
    assert outcome.measurement["age_data_status"] == (
        "500m:COMPLETED,1km:COMPLETED"
    )
    for label in ("500m", "1km"):
        assert outcome.measurement[f"pop_age_0_14_{label}"] > 0
        assert outcome.measurement[f"age_coverage_{label}"] == pytest.approx(100.0)
    provenance = outcome.provenance
    assert provenance["provider"] == "worldpop_age_sex_structures"
    assert provenance["per_radius"]["1km"]["band_total_relative_diff"] < 1e-9


def test_wiring_unavailable_no_valued_pixels(empty_dir, wire):
    outcome = wire(empty_dir)
    assert outcome.status == "unavailable"
    assert "no age-band pixels for either radius" in outcome.provenance["reason"]
    assert outcome.measurement is None
    assert outcome.provenance["per_radius"]["500m"]["status"] == "NO_VALUED_PIXELS"


def test_wiring_mixed_radii_keep_measured_side(ring_dir, wire):
    """500 m inside a nodata hole, 1 km still measured: the category is
    current, the failed radius writes None (never 0), and age_data_status
    names both outcomes."""
    outcome = wire(ring_dir)
    assert outcome.status == "current"
    assert outcome.measurement["age_data_status"] == (
        "500m:NO_VALUED_PIXELS,1km:LOW_COVERAGE"
    )
    assert outcome.measurement["pop_age_0_14_500m"] is None
    assert outcome.measurement["share_age_15_34_500m"] is None
    assert outcome.measurement["age_coverage_500m"] == 0.0
    assert outcome.measurement["pop_age_0_14_1km"] > 0
    assert 0.0 < outcome.measurement["age_coverage_1km"] < 80.0
    owned = {col for col, _ in _MEASUREMENT_COLUMNS["age_population"]}
    assert set(outcome.measurement) == owned


def test_wiring_unavailable_not_configured(monkeypatch):
    monkeypatch.setattr(pes, "_AGE_BAND_SERVICE", None)
    monkeypatch.setattr(settings, "sitewise_age_raster_dir", "")
    outcome = PropertyEnrichmentService(None)._age_population(LAT, LON, {})
    assert outcome.status == "unavailable"
    assert "not configured" in outcome.provenance["reason"]


def test_wiring_unavailable_tiles_missing(tmp_path, monkeypatch):
    """An incomplete tile set names the count, never a guessed value."""
    stub = tmp_path / "stub"
    stub.mkdir()
    monkeypatch.setattr(pes, "_AGE_BAND_SERVICE", AgeBandRasterService(str(stub)))
    outcome = PropertyEnrichmentService(None)._age_population(LAT, LON, {})
    assert outcome.status == "unavailable"
    assert "42 of 42 files missing" in outcome.provenance["reason"]
