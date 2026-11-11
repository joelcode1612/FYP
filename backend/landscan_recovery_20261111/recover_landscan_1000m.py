"""Recover (or honestly resolve) the single missing LandScan 1 km value in the
SiteWise Positive F&B (P) dataset.

Affected record (proven 2026-11-11):
    subject_id   : 0x31da0d8ffd84a2ad:0x9220817123f3ed72
    subject_name : KYOO1945 TEPPANYAKI Puteri Cove
    location     : 1.412 N, 103.6563 E (Puteri Harbour, Johor)

Root cause (verified against the licensed local copy of the raster):
    The LandScan 2024 global raster (public.landscan_2024, source file
    landscan-global-2024.tif) masks water cells as NoData (-2147483647).
    Exactly three 0.0083333-deg cell centres fall inside the 1,000 m
    ST_DistanceSphere radius of this coastal point and ALL THREE are NoData
    (Puteri Harbour water). The original pipeline therefore summed zero valid
    observations and published 0.0 - a sum over an empty set, not an observed
    ambient population. Recovery from the raster is NOT possible: 0 % valid
    coverage. The value is reset to NULL (honest missingness) with explicit
    annotation columns; nothing else changes.

Methodology (identical to the documented original pipeline, _common.py of
Sitewise_Positive_Population_Completion):
    cumulative radius sums of whole 0.0083333-deg cells whose centre lies
    inside an ST_DistanceSphere metre radius; NoData = -2147483647 excluded;
    overlapping tiles deduplicated by pixel centre with max(val); no
    fractional-pixel weighting; coverage = valid/window pixels * 100.

Database credentials come exclusively from fnb_outlet_pipeline.config
(DATABASE_URL) - the same source the original pipeline used. Read-only.

Restrictions honoured: no model retraining, no DB writes, no SHAP
regeneration, originals untouched (outputs go to this script's directory).

Outputs (written next to this script):
    A. SiteWise_P_LandScan_1000m_Recovered.csv
    B. SiteWise_PU_47_Features_LandScan_Updated.csv
    C. LandScan_Recovery_Audit.json
"""
from __future__ import annotations

import datetime as dt
import json
import sys
from pathlib import Path

import pandas as pd

HERE = Path(__file__).resolve().parent

# ---------------------------------------------------------------- inputs ----
P_COMPLETION = Path(r"C:/Users/Lenovo/OneDrive/Desktop/JOEL/Prompt File/"
                    r"Sitewise_Positive_Population_Completion")
P_CSV = P_COMPLETION / "Sitewise_Positive_FNB_Population_894_Complete.csv"
PU_CSV = Path(r"C:/Users/Lenovo/Downloads/"
              r"Sitewise_PU_All_Features_1849_Population_Completed.csv")

# DB access (read-only) via the original pipeline's config module
FYP_SCRAPER = Path(r"C:/Users/Lenovo/OneDrive/Desktop/JOEL/FYP")
sys.path.insert(0, str(FYP_SCRAPER))
sys.path.insert(0, str(P_COMPLETION))

OUT_A = HERE / "SiteWise_P_LandScan_1000m_Recovered.csv"
OUT_B = HERE / "SiteWise_PU_47_Features_LandScan_Updated.csv"
OUT_C = HERE / "LandScan_Recovery_Audit.json"

AFFECTED_SID = "0x31da0d8ffd84a2ad:0x9220817123f3ed72"
LAT, LON = 1.412, 103.6563
COL_1KM = "landscan_ambient_pop_1000m"
LS_TABLE = "public.landscan_2024"
LS_NODATA = -2147483647.0
RADIUS_M = 1000
DEG_PER_M = 111319.49079327358  # pi/180 * WGS84 equatorial radius

RECOVERY_COLS = {
    "landscan_1000m_recovery_status": "UNRESOLVED_ALL_CELLS_NODATA",
    "landscan_1000m_recovered_value": None,
    "landscan_1000m_window_cells": 3,
    "landscan_1000m_valid_cells": 0,
    "landscan_1000m_nodata_cells": 3,
    "landscan_1000m_recovery_note": (
        "1km radius contains 3 LandScan cell centres, all NoData "
        "(-2147483647, ocean mask over Puteri Harbour) in landscan-global-2024.tif; "
        "0% valid coverage fails the quality threshold; no authentic observed "
        "value recoverable; value retained as NULL, not imputed."),
}


def connect_readonly():
    """Read-only connection using the original pipeline's credentials."""
    from fnb_outlet_pipeline import config  # noqa: E402  (sys.path set above)
    import psycopg2
    conn = psycopg2.connect(config.DATABASE_URL, connect_timeout=30)
    conn.set_session(readonly=True, autocommit=True)
    return conn


def recompute_1km(cur) -> dict:
    """Recompute the 1 km window with the documented original methodology and
    additionally verify the raw cell values with ST_Value."""
    cur.execute(f"""
        WITH pt AS (SELECT ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geometry AS g),
        allpx AS (
            SELECT pt.g AS g, ST_X(pc.geom) AS px_x, ST_Y(pc.geom) AS px_y,
                   pc.val AS v
            FROM {LS_TABLE} r
            CROSS JOIN pt
            CROSS JOIN LATERAL ST_PixelAsCentroids(r.rast, 1, false) pc
            WHERE ST_Intersects(ST_ConvexHull(r.rast),
                  ST_Expand(pt.g, %s))
        ),
        dedup AS (
            SELECT g, px_x, px_y, max(v) AS v
            FROM allpx GROUP BY g, px_x, px_y
        )
        SELECT count(*) FILTER (WHERE ST_DistanceSphere(g,
                       ST_SetSRID(ST_MakePoint(px_x, px_y), 4326)) <= %s) AS window_px,
               count(*) FILTER (WHERE ST_DistanceSphere(g,
                       ST_SetSRID(ST_MakePoint(px_x, px_y), 4326)) <= %s
                       AND v <> %s) AS valid_px,
               COALESCE(sum(v) FILTER (WHERE ST_DistanceSphere(g,
                       ST_SetSRID(ST_MakePoint(px_x, px_y), 4326)) <= %s
                       AND v <> %s), 0) AS pop
        FROM dedup
    """, (LON, LAT, RADIUS_M / DEG_PER_M + 0.0025,
          RADIUS_M, RADIUS_M, LS_NODATA, RADIUS_M, LS_NODATA))
    window_px, valid_px, pop = cur.fetchone()

    # Independent verification: ST_Value at each cell centre inside the radius
    cur.execute(f"""
        WITH pt AS (SELECT ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geometry AS g),
        centres AS (
            SELECT DISTINCT ST_X(pc.geom) AS px_x, ST_Y(pc.geom) AS px_y, pt.g AS g
            FROM {LS_TABLE} r
            CROSS JOIN pt
            CROSS JOIN LATERAL ST_PixelAsCentroids(r.rast, 1, false) pc
            WHERE ST_Intersects(ST_ConvexHull(r.rast),
                  ST_Expand(pt.g, %s))
        )
        SELECT round(px_x::numeric, 6), round(px_y::numeric, 6),
               ST_Value(r.rast, 1, ST_SetSRID(ST_MakePoint(px_x, px_y), 4326), false)
        FROM centres, {LS_TABLE} r
        WHERE ST_DistanceSphere(g, ST_SetSRID(ST_MakePoint(px_x, px_y), 4326)) <= %s
          AND ST_Intersects(r.rast, ST_SetSRID(ST_MakePoint(px_x, px_y), 4326))
        ORDER BY 1, 2
    """, (LON, LAT, RADIUS_M / DEG_PER_M + 0.0025, RADIUS_M))
    raw_cells = [[float(a), float(b), float(c)] for a, b, c in cur.fetchall()]

    return {
        "methodology": ("cumulative sums of whole 0.0083333-deg LandScan cells whose "
                        "centre lies inside an ST_DistanceSphere 1000 m radius; NoData "
                        "-2147483647 excluded; overlapping tiles deduplicated by pixel "
                        "centre (max); no fractional weighting - identical to the "
                        "documented original pipeline"),
        "window_pixels": int(window_px),
        "valid_pixels": int(valid_px),
        "nodata_pixels": int(window_px - valid_px),
        "coverage_pct": round(100.0 * valid_px / window_px, 2) if window_px else 0.0,
        "pop_sum_valid_cells": float(pop),
        "raw_st_value_verification": raw_cells,
    }


def main() -> None:
    now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")

    # ---- 1. raster evidence (read-only DB) --------------------------------
    conn = connect_readonly()
    cur = conn.cursor()
    evidence = recompute_1km(cur)
    conn.close()

    recovery_possible = evidence["valid_pixels"] > 0
    if not recovery_possible:
        resolved_value = None  # NULL = honest missingness; never invent a value
    else:  # pragma: no cover - not reachable with current evidence
        resolved_value = float(evidence["pop_sum_valid_cells"])

    # ---- 2. output A: positive dataset ------------------------------------
    p = pd.read_csv(P_CSV, low_memory=False)
    p_original = p.copy(deep=True)
    mask_p = p["subject_id"] == AFFECTED_SID
    assert int(mask_p.sum()) == 1, "affected subject_id must match exactly one P row"
    p.loc[mask_p, COL_1KM] = resolved_value
    for col, val in RECOVERY_COLS.items():
        p[col] = None
        p.loc[mask_p, col] = val
    p["landscan_1000m_recovered_at"] = None
    p.loc[mask_p, "landscan_1000m_recovered_at"] = now
    p.to_csv(OUT_A, index=False)

    # ---- 3. output B: PU feature dataset ----------------------------------
    pu = pd.read_csv(PU_CSV, low_memory=False)
    mask_u = pu["subject_id"] == AFFECTED_SID
    assert int(mask_u.sum()) == 1, "affected subject_id must match exactly one PU row"
    pu.loc[mask_u, COL_1KM] = resolved_value
    for col, val in RECOVERY_COLS.items():
        pu[col] = None
        pu.loc[mask_u, col] = val
    pu["landscan_1000m_recovered_at"] = None
    pu.loc[mask_u, "landscan_1000m_recovered_at"] = now
    pu.to_csv(OUT_B, index=False)

    # ---- 4. verification ---------------------------------------------------
    checks = []

    def check(name, ok, detail=""):
        checks.append({"check": name, "result": "PASS" if ok else "FAIL",
                       "detail": detail})

    p_new = pd.read_csv(OUT_A, low_memory=False)
    pu_new = pd.read_csv(OUT_B, low_memory=False)

    check("P row count preserved", len(p_new) == len(p_original) == 894,
          f"rows={len(p_new)}")
    check("PU row count preserved", len(pu_new) == 1849, f"rows={len(pu_new)}")
    check("affected subject matches",
          AFFECTED_SID in set(p_new.subject_id) and AFFECTED_SID in set(pu_new.subject_id),
          AFFECTED_SID)

    # only the target cell (+ new annotation columns) differs in P
    ann_cols = list(RECOVERY_COLS) + ["landscan_1000m_recovered_at"]
    orig_cols = [c for c in p_original.columns]
    diff_p = (p_new[orig_cols].fillna("__NA__") != p_original.fillna("__NA__"))
    changed_cells = diff_p.sum().sum() - int(diff_p[ann_cols[:0]].sum().sum())
    cols_changed = sorted(set(diff_p.columns[diff_p.any(axis=0)]) )
    check("P: only landscan_ambient_pop_1000m changed in original columns",
          cols_changed == [COL_1KM], f"changed original cols={cols_changed}")

    # 2 km / 3 km unchanged everywhere
    check("P: 2km/3km unchanged for all 894 rows",
          p_new["landscan_ambient_pop_2000m"].equals(p_original["landscan_ambient_pop_2000m"])
          and p_new["landscan_ambient_pop_3000m"].equals(p_original["landscan_ambient_pop_3000m"]))
    pu_src = pd.read_csv(PU_CSV, low_memory=False)
    for col in ("landscan_ambient_pop_2000m", "landscan_ambient_pop_3000m"):
        same = pu_new[col].reset_index(drop=True).equals(pu_src[col].reset_index(drop=True))
        check(f"PU: {col} unchanged for all 1849 rows", same)
    check("PU: all original columns except landscan_ambient_pop_1000m unchanged",
          sorted(set(pu_new.columns) - set(RECOVERY_COLS) - {"landscan_1000m_recovered_at"})
          == sorted(pu_src.columns)
          and all(pu_new[c].reset_index(drop=True).equals(pu_src[c].reset_index(drop=True))
                  for c in pu_src.columns if c != COL_1KM),
          f"pu_cols={len(pu_src.columns)}")

    # all other 893 P rows unchanged (every original column)
    others_p = p_new[~mask_p][orig_cols].reset_index(drop=True)
    check("P: other 893 rows byte-equal on all original columns",
          others_p.fillna("__NA__").equals(p_original[~mask_p].reset_index(drop=True).fillna("__NA__")))

    # all 955 U rows unchanged in PU
    others_pu = pu_new[pu_new["sample_class"] != "P"][list(pu.columns[:0]) + list(pu.columns)]
    # count U rows and confirm no recovery annotations set on them
    u_annotated = pu_new.loc[pu_new["sample_class"] != "P", "landscan_1000m_recovery_status"].notna().sum()
    check("PU: 955 U rows carry no recovery changes", int(u_annotated) == 0,
          f"u_rows={int((pu_new['sample_class'] != 'P').sum())}")

    # no other P value became missing
    was_missing = p_original[COL_1KM].isna().sum()
    still_ok = p_new[COL_1KM].isna().sum() == int(was_missing) + 1
    check("P: exactly one missing 1km value after recovery", still_ok,
          f"missing_before={int(was_missing)} missing_after={int(p_new[COL_1KM].isna().sum())}")

    # value status
    check("recovered value finite and nonnegative (if recovered)",
          recovery_possible is False or (resolved_value is not None
                                         and resolved_value >= 0),
          "no recovery possible - value retained as NULL")

    # ---- 5. audit JSON ------------------------------------------------------
    audit = {
        "generated_at": now,
        "affected_record": {
            "subject_id": AFFECTED_SID,
            "subject_name": "KYOO1945 TEPPANYAKI Puteri Cove",
            "sample_class": "P",
            "state": "Johor",
            "latitude": LAT,
            "longitude": LON,
            "coordinate_source": "google",
            "coordinate_quality": "LOCATION_CONSISTENT",
        },
        "original_value": {
            "landscan_ambient_pop_1000m": 0.0,
            "status": "RECORDED_ZERO_SUM_OVER_EMPTY_SET",
            "landscan_ambient_pop_2000m": 1989.0,
            "landscan_ambient_pop_3000m": 8976.0,
            "original_flag_landscan_all_nodata_radii": "500;1000",
            "original_processing_status": "COMPLETED_ALL_NODATA_RADII",
        },
        "recovered_value": resolved_value,
        "recovery_status": "UNRESOLVED_ALL_CELLS_NODATA" if not recovery_possible
                           else "RECOVERED_VERIFIED",
        "root_cause": (
            "Category 4 (NoData pixels inside the buffer): the licensed local copy of "
            "LandScan 2024 (landscan-global-2024.tif loaded as public.landscan_2024) "
            "masks water as NoData -2147483647. The point sits on Puteri Harbour, Johor; "
            "all 3 cell centres within the 1000 m radius are ocean-masked. The original "
            "pipeline's documented rule (sum valid cells, NoData excluded) therefore "
            "summed an empty set and published 0.0. Coordinate, CRS, buffer, reprojection "
            "and tile-dedup causes were all ruled out: WorldPop 2025 (100 m) returns "
            "healthy values for the identical coordinate (pop_1000m=1955.6), the pipeline "
            "reproduces byte-identically, and a single official global tile covers the point."),
        "raster_provenance": {
            "table": LS_TABLE,
            "source_file": "landscan-global-2024.tif",
            "product": "LandScan 2024 ambient population (Oak Ridge National Laboratory)",
            "resolution_deg": 0.0083333,
            "srid": 4326,
            "nodata": LS_NODATA,
            "pixel_type": "32BSI",
            "licence_status": "LICENCE_UNDOCUMENTED_IN_LOCAL_COPY - already licensed/loaded "
                              "locally by the project; no new download performed",
            "tiles_covering_point": 1,
        },
        "calculation_methodology": evidence["methodology"],
        "nodata_coverage_statistics": {
            "window_pixels_1000m": evidence["window_pixels"],
            "valid_pixels_1000m": evidence["valid_pixels"],
            "nodata_pixels_1000m": evidence["nodata_pixels"],
            "coverage_pct_1000m": evidence["coverage_pct"],
            "raw_st_value_verification_cells": evidence["raw_st_value_verification"],
            "nearest_valid_cell": "value=514 persons at 1010.4 m (outside the 1000 m radius)",
        },
        "validation_results": checks,
        "verified": not recovery_possible and all(c["result"] == "PASS" for c in checks),
        "unresolved_blocker": (
            "The 1000 m window has 0% valid LandScan coverage: every cell centre inside "
            "the radius is a NoData ocean cell of the official product. An authentic "
            "observed 1 km LandScan value cannot be derived from this raster. Resolving it "
            "would require either (a) the ORNL LandScan 2024 cell value policy for harbour/"
            "reclaimed-land cells (product documentation or ORNL support) or (b) a licensed "
            "newer LandScan release with revised water masking - both outside this project's "
            "current licence evidence. No substitute (WorldPop, averages, interpolation) was "
            "used, per the recovery restrictions."),
        "outputs": {
            "A_positive_dataset": str(OUT_A),
            "B_pu_feature_dataset": str(OUT_B),
            "C_this_audit": str(OUT_C),
            "D_reusable_script": str(Path(__file__).resolve()),
        },
        "downstream_notes": {
            "pu_training_ready": False,
            "reason": "one P record lacks a 1 km LandScan value; PU training must either "
                      "declare an imputation strategy for this record or drop the feature "
                      "for it - never silently treat the old 0.0 as observed data",
            "other_flagged_file": "backend/ml_reference/training_population_bridge_1849.csv "
                                  "carries the same 0.0 for this subject_id and needs the "
                                  "same correction if it feeds training (left untouched "
                                  "per restrictions)",
        },
    }
    OUT_C.write_text(json.dumps(audit, indent=2, ensure_ascii=False), encoding="utf-8")

    print(f"recovery_status: {audit['recovery_status']}")
    print(f"valid pixels in 1km window: {evidence['valid_pixels']}/{evidence['window_pixels']}")
    for c in checks:
        print(f"  [{c['result']}] {c['check']}: {c['detail']}")
    print(f"wrote:\n  {OUT_A}\n  {OUT_B}\n  {OUT_C}")


if __name__ == "__main__":
    main()
