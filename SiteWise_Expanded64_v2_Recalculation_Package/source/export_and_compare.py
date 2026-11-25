"""Export recalculated Expanded64_v2 features and compare with the originals.

Reads the per-subject JSONL checkpoints written by extract_expanded64_v2.py.
No database access and no writes to any source dataset.
"""
from __future__ import annotations

import csv
import json
import math
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.stats import pearsonr, spearmanr

ROOT = Path(__file__).resolve().parents[1]
CHECKPOINTS = ROOT / "checkpoints"
TRAINING_CSV = ROOT / "original_training_data" / "SiteWise_PU_1796_Expanded_Observed.csv"
INVENTORY = ROOT / "expanded64_v2_source_inventory.json"

TARGETS = (
    "road_length_density_500m_km_km2",
    "osm_walkway_length_density_500m_km_km2",
    "pop_2000m",
    "pop_3000m",
    "walk_isochrone_area_10min_km2",
    "worldpop_walk_reachable_10min",
)
GROUP_OF = {
    "road_length_density_500m_km_km2": "road_geometry",
    "osm_walkway_length_density_500m_km_km2": "road_geometry",
    "pop_2000m": "population_rings",
    "pop_3000m": "population_rings",
    "walk_isochrone_area_10min_km2": "isochrone_population",
    "worldpop_walk_reachable_10min": "isochrone_population",
}
#: Runtime calculators round to these precisions. The tolerance is one half
#: of the last reported unit, i.e. the maximum rounding error of the runtime.
TOLERANCE = {
    "road_length_density_500m_km_km2": 0.0005,
    "osm_walkway_length_density_500m_km_km2": 0.0005,
    "pop_2000m": 0.05,
    "pop_3000m": 0.05,
    "walk_isochrone_area_10min_km2": 0.00005,
    # Expanded64CoordinateExtractor._hull_population rounds to 3 decimals.
    "worldpop_walk_reachable_10min": 0.0005,
}
DEFINITION_VERSION = "expanded64-feature-definitions-v1"


def load_original() -> pd.DataFrame:
    df = pd.read_csv(TRAINING_CSV, encoding="utf-8-sig", low_memory=False)
    keep = ["subject_id", "sample_class", "latitude", "longitude", *TARGETS]
    return df[keep].copy()


def load_checkpoints() -> pd.DataFrame:
    records = {}
    for path in sorted(CHECKPOINTS.glob("extraction_progress*.jsonl")):
        with path.open(encoding="utf-8") as fp:
            for line in fp:
                if not line.strip():
                    continue
                r = json.loads(line)
                records[r["subject_id"]] = r
    if not records:
        raise RuntimeError("No extraction checkpoints found")

    rows = []
    for sid, r in records.items():
        notes = r.get("notes") or {}
        pop_notes = notes.get("population_rings") or {}
        iso_notes = notes.get("isochrone_population") or {}
        road_notes = notes.get("road_geometry") or {}
        statuses = r.get("statuses") or {}
        reasons = r.get("reasons") or {}
        row = {
            "subject_id": sid,
            "sample_class": r.get("sample_class"),
            "latitude": r.get("latitude"),
            "longitude": r.get("longitude"),
            "definition_version": r.get("definition_version", DEFINITION_VERSION),
            "road_geometry_status": statuses.get("road_geometry", ""),
            "population_rings_status": statuses.get("population_rings", ""),
            "isochrone_population_status": statuses.get("isochrone_population", ""),
            "worldpop_valid_pixels_2000m": pop_notes.get("worldpop_valid_pixels_2000m"),
            "worldpop_valid_pixels_3000m": pop_notes.get("worldpop_valid_pixels_3000m"),
            "walk_hull_nodes": iso_notes.get("nodes", iso_notes.get("hull_nodes_10min")),
            "walk_hull_valid": bool(
                iso_notes.get("nodes", iso_notes.get("hull_nodes_10min"))
                and iso_notes.get("nodes", iso_notes.get("hull_nodes_10min")) >= 3
            ),
            "walk_snap_m": iso_notes.get("snap_m"),
            "worldpop_hull_coverage_pct": iso_notes.get("worldpop_hull_coverage_pct"),
            "road_m_500": road_notes.get("road_m_500"),
            "walkway_m_500": road_notes.get("walkway_m_500"),
            "missing_reasons": " | ".join(
                f"{g}: {v}" for g, v in reasons.items()
            ),
        }
        for name in TARGETS:
            row[name] = (r.get("values") or {}).get(name)
            row[f"source_{name}"] = (r.get("sources") or {}).get(name, "")
            row[f"status_{name}"] = statuses.get(GROUP_OF[name], "")
        rows.append(row)
    return pd.DataFrame(rows)


def export_recalculated(df: pd.DataFrame) -> None:
    columns = [
        "subject_id", "latitude", "longitude", *TARGETS, "definition_version",
        "sample_class",
        "road_geometry_status", "population_rings_status",
        "isochrone_population_status",
        "worldpop_valid_pixels_2000m", "worldpop_valid_pixels_3000m",
        "walk_hull_nodes", "walk_hull_valid", "walk_snap_m",
        "worldpop_hull_coverage_pct", "road_m_500", "walkway_m_500",
        "missing_reasons",
        *[f"source_{n}" for n in TARGETS],
        *[f"status_{n}" for n in TARGETS],
    ]
    df[columns].to_csv(
        ROOT / "expanded64_v2_recalculated_features.csv",
        index=False, na_rep="", float_format="%.10g",
    )


def export_subject_comparison(original: pd.DataFrame, recalc: pd.DataFrame) -> None:
    frames = []
    base = original.set_index("subject_id")
    measured = recalc.set_index("subject_id")
    for name in TARGETS:
        part = pd.DataFrame({
            "subject_id": base.index,
            "sample_class": base["sample_class"],
            "feature": name,
            "original_value": base[name].astype("float64"),
            "recalculated_value": measured[name].reindex(base.index).astype("float64"),
        })
        part["difference"] = part["recalculated_value"] - part["original_value"]
        frames.append(part)
    out = pd.concat(frames, ignore_index=True)
    out.to_csv(
        ROOT / "expanded64_v2_subject_comparison.csv",
        index=False, na_rep="", float_format="%.10g",
    )


def _safe_corr(a: np.ndarray, b: np.ndarray, fn):
    mask = np.isfinite(a) & np.isfinite(b)
    if mask.sum() < 3 or np.std(a[mask]) == 0 or np.std(b[mask]) == 0:
        return float("nan"), float("nan")
    r, p = fn(a[mask], b[mask])
    return float(r), float(p)


def export_feature_comparison(original: pd.DataFrame, recalc: pd.DataFrame) -> None:
    measured = recalc.set_index("subject_id")
    rows = []
    for name in TARGETS:
        o = original.set_index("subject_id")[name].astype("float64")
        r = measured[name].reindex(o.index).astype("float64")
        cls = original.set_index("subject_id")["sample_class"]
        paired = o.notna() & r.notna()
        diff = (r - o)[paired]
        tol = TOLERANCE[name]
        pr, pp = _safe_corr(o.to_numpy(dtype=float), r.to_numpy(dtype=float), pearsonr)
        sr, sp = _safe_corr(o.to_numpy(dtype=float), r.to_numpy(dtype=float), spearmanr)
        pos = cls == "P"
        unl = cls == "U"
        rows.append({
            "feature": name,
            "definition_version": DEFINITION_VERSION,
            "sample_count": len(o),
            "original_non_null_count": int(o.notna().sum()),
            "recalculated_non_null_count": int(r.notna().sum()),
            "missing_recalculated_count": int(r.isna().sum()),
            "paired_count": int(paired.sum()),
            "exact_match_count": int((diff == 0).sum()),
            "tolerance_match_count": int((diff.abs() <= tol).sum()),
            "tolerance_definition": f"abs(recalculated-original) <= {tol} (half last reported unit)",
            "mean_absolute_difference": float(diff.abs().mean()) if len(diff) else float("nan"),
            "median_absolute_difference": float(diff.abs().median()) if len(diff) else float("nan"),
            "root_mean_squared_difference": float(np.sqrt((diff ** 2).mean())) if len(diff) else float("nan"),
            "min_original": float(o.min()) if o.notna().any() else float("nan"),
            "max_original": float(o.max()) if o.notna().any() else float("nan"),
            "min_recalculated": float(r.min()) if r.notna().any() else float("nan"),
            "max_recalculated": float(r.max()) if r.notna().any() else float("nan"),
            "mean_original": float(o.mean()) if o.notna().any() else float("nan"),
            "median_original": float(o.median()) if o.notna().any() else float("nan"),
            "std_original": float(o.std()) if o.notna().sum() > 1 else float("nan"),
            "p25_original": float(o.quantile(0.25)) if o.notna().any() else float("nan"),
            "p75_original": float(o.quantile(0.75)) if o.notna().any() else float("nan"),
            "mean_recalculated": float(r.mean()) if r.notna().any() else float("nan"),
            "median_recalculated": float(r.median()) if r.notna().any() else float("nan"),
            "std_recalculated": float(r.std()) if r.notna().sum() > 1 else float("nan"),
            "p25_recalculated": float(r.quantile(0.25)) if r.notna().any() else float("nan"),
            "p75_recalculated": float(r.quantile(0.75)) if r.notna().any() else float("nan"),
            "pearson_r": pr, "pearson_p": pp,
            "spearman_r": sr, "spearman_p": sp,
            "positive_samples": int(pos.sum()),
            "unlabeled_samples": int(unl.sum()),
            "positive_original_non_null": int(o[pos].notna().sum()),
            "positive_recalculated_non_null": int(r[pos].notna().sum()),
            "positive_tolerance_matches": int(((diff.abs() <= tol) & pos.reindex(diff.index)) .sum()),
            "unlabeled_original_non_null": int(o[unl].notna().sum()),
            "unlabeled_recalculated_non_null": int(r[unl].notna().sum()),
            "unlabeled_tolerance_matches": int(((diff.abs() <= tol) & unl.reindex(diff.index)).sum()),
        })
    pd.DataFrame(rows).to_csv(
        ROOT / "expanded64_v2_feature_comparison.csv",
        index=False, na_rep="", float_format="%.10g",
    )
    return rows


def _specific_reason(name: str, row: pd.Series) -> str:
    """Explain a NULL without inventing a value."""
    if name == "osm_walkway_length_density_500m_km_km2":
        return "No walk-class geometry intersected the 500 m buffer; NULL preserved, not zero."
    if name == "road_length_density_500m_km_km2":
        return "No road-class geometry intersected the 500 m buffer; NULL preserved, not zero."
    if name in ("pop_2000m", "pop_3000m"):
        pixels = row.get(f"worldpop_valid_pixels_{name.removeprefix('pop_')}")
        return f"No valid WorldPop pixel in the ring (valid_pixels={pixels}); NULL preserved."
    if name == "walk_isochrone_area_10min_km2":
        return "No polygonal 600-second walk hull (fewer than 3 reachable vertices); NULL preserved."
    if name == "worldpop_walk_reachable_10min":
        return "Walk hull or WorldPop raster coverage unavailable; NULL preserved."
    return "Calculator did not produce a value; NULL preserved."


def export_missing(recalc: pd.DataFrame) -> None:
    frames = []
    for name in TARGETS:
        missing = recalc[recalc[name].isna()]
        if missing.empty:
            continue
        part = missing[[
            "subject_id", "sample_class", "latitude", "longitude",
            "missing_reasons", f"status_{name}", f"source_{name}",
        ]].copy()
        part["feature"] = name
        part["definition_version"] = DEFINITION_VERSION
        part["missing_reason"] = [
            _specific_reason(name, row) if not str(row.get("missing_reasons") or "").strip()
            else str(row["missing_reasons"])
            for _, row in part.iterrows()
        ]
        part = part.rename(columns={f"status_{name}": "group_status", f"source_{name}": "attempted_source"})
        frames.append(part)
    cols = [
        "subject_id", "feature", "sample_class", "latitude", "longitude",
        "group_status", "attempted_source", "missing_reasons", "missing_reason",
        "definition_version",
    ]
    if frames:
        out = pd.concat(frames, ignore_index=True)[cols]
    else:
        out = pd.DataFrame(columns=cols)
    out.to_csv(ROOT / "expanded64_v2_missing_features.csv", index=False, na_rep="")


def export_summary(original: pd.DataFrame, recalc: pd.DataFrame, stats: list[dict]) -> None:
    inventory = json.loads(INVENTORY.read_text(encoding="utf-8"))
    summary = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "definition_version": DEFINITION_VERSION,
        "database": inventory["database"],
        "server": inventory["server"],
        "subjects_expected": 1796,
        "subjects_recalculated": int(len(recalc)),
        "subjects_missing_from_checkpoint": sorted(
            set(original["subject_id"]) - set(recalc["subject_id"])
        )[:50],
        "sample_classes": recalc["sample_class"].value_counts().to_dict(),
        "measurements_expected": 1796 * len(TARGETS),
        "measurements_recalculated": int(recalc[list(TARGETS)].notna().sum().sum()),
        "per_feature": {
            row["feature"]: {
                "recalculated_non_null": row["recalculated_non_null_count"],
                "original_non_null": row["original_non_null_count"],
                "exact_matches": row["exact_match_count"],
                "tolerance_matches": row["tolerance_match_count"],
                "mean_absolute_difference": row["mean_absolute_difference"],
                "pearson_r": row["pearson_r"],
                "spearman_r": row["spearman_r"],
            }
            for row in stats
        },
        "source_issues": [
            "roads_v2: 28 duplicate geometry groups (29 rows); no invalid geometry; not altered.",
            "road_junctions_v2 extent is Peninsular Malaysia only (100.25-104.23E, 1.38-5.54N) while roads_v2 covers 99.66-119.26E; junction density is out of scope for the six features.",
            "worldpop_2025_constrained: 2677 tiles, 100 m, SRID 4326, nodata -99999, extent covers Malaysia.",
            "psense_edges: 1,592,732 edges, all cost fields present; 1,576,859 edges in a walk component; 17,999 motorway/motorway_link edges excluded from walking.",
            "ur_walknode: 326,850 nodes with component ids; psense_verts: 2,317,897 vertices.",
            "Routing connectivity and raster availability are recorded per subject in the recalculated CSV; failures stay NULL with reasons.",
        ],
        "governance": {
            "model_retrained": False,
            "expanded64_v2_activated": False,
            "production_records_modified": False,
            "original_training_dataset_modified": False,
        },
    }
    (ROOT / "expanded64_v2_extraction_summary.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False, allow_nan=False),
        encoding="utf-8",
    )


def main() -> None:
    original = load_original()
    recalc = load_checkpoints()
    if len(recalc) != 1796:
        raise RuntimeError(f"Expected 1796 subject records, got {len(recalc)}")
    export_recalculated(recalc)
    export_subject_comparison(original, recalc)
    stats = export_feature_comparison(original, recalc)
    export_missing(recalc)
    export_summary(original, recalc, stats)
    print(f"Exported {len(recalc)} subjects and {len(stats)} feature comparisons")


if __name__ == "__main__":
    main()
