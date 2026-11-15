"""Build the committed reference data for the 64-feature expanded PU model.

Run from backend/ with its project virtual environment:
    .venv/Scripts/python.exe scripts/ml/build_expanded_reference_data.py

Produces two read-only reference files under ``ml_reference/``:

1. ``training_expanded_bridge_1796.csv``
   The 16 new features (12 WorldPop Malaysia 2025 population-age counts +
   8 OSM residential density/coverage measures) for the 1,796 complete-case
   research subjects, keyed by ``subject_id`` and ``canonical_property_id``
   exactly like the existing ``training_population_bridge_1849.csv`` bridge.
   The live analytics database holds NO values for these measurements (the
   age columns are unpopulated and ``local_age_raster_status`` records
   ``SOURCE_NOT_AVAILABLE``), and the residential columns it does hold were
   measured with a different method than the model's training values (verified
   2026-11-15: DB ``residential_building_count_500m`` disagrees with the
   training values on every sampled subject). The bridge therefore reproduces
   the model artifact's OWN training inputs for in-sample research use, the
   same policy as the 47-feature bridge. Nothing is written to any database.

2. ``shap_background_64.csv``
   A deterministic, class-stratified sample of 50 P + 50 U complete training
   observations (all 64 features observed) used as the real SHAP background.
   Rows are drawn from the training package's own observed-only dataset, so
   the background is the model's genuine training distribution - never
   synthetic, never zero-filled.

Both outputs keep the original training package files untouched.
"""
from __future__ import annotations

import csv
import hashlib
import random
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[2]
ML_REFERENCE = BACKEND_DIR / "ml_reference"
PACKAGE = ML_REFERENCE / "expanded_pu_64_2026_11_15"

SOURCE_CSV = PACKAGE / "SiteWise_PU_1796_Expanded_Observed.csv"
ID_BRIDGE_CSV = ML_REFERENCE / "training_population_bridge_1849.csv"
OUT_BRIDGE = ML_REFERENCE / "training_expanded_bridge_1796.csv"
OUT_SHAP = ML_REFERENCE / "shap_background_64.csv"

#: The 16 features the expanded model adds to the 44-feature baseline.
EXPANDED_FEATURES: tuple[str, ...] = (
    "pop_age_0_14_500m",
    "pop_age_15_24_500m",
    "pop_age_25_34_500m",
    "pop_age_35_49_500m",
    "pop_age_50_64_500m",
    "pop_age_65_plus_500m",
    "pop_age_0_14_1km",
    "pop_age_15_24_1km",
    "pop_age_25_34_1km",
    "pop_age_35_49_1km",
    "pop_age_50_64_1km",
    "pop_age_65_plus_1km",
    "residential_building_count_500m",
    "residential_building_count_1000m",
    "residential_building_density_500m_km2",
    "residential_building_density_1000m_km2",
    "residential_footprint_coverage_500m_pct",
    "residential_footprint_coverage_1000m_pct",
    "residential_landuse_coverage_500m_pct",
    "residential_landuse_coverage_1000m_pct",
)
assert len(EXPANDED_FEATURES) == 20  # 12 age + 8 residential


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    with SOURCE_CSV.open(encoding="utf-8-sig", newline="") as stream:
        source_rows = {row["subject_id"]: row for row in csv.DictReader(stream)}
    with ID_BRIDGE_CSV.open(encoding="utf-8-sig", newline="") as stream:
        ids = {
            (row.get("subject_id") or "").strip(): {
                "canonical_property_id": (row.get("canonical_property_id") or "").strip(),
                "sample_class": (row.get("sample_class") or "").strip().upper(),
            }
            for row in csv.DictReader(stream)
        }

    missing_ids = sorted(set(source_rows) - set(ids))
    if missing_ids:
        raise SystemExit(
            f"{len(missing_ids)} training subjects are absent from the 1,849-row "
            f"identity bridge (e.g. {missing_ids[:3]}); refusing to invent ids."
        )

    bridge_fields = ["subject_id", "canonical_property_id", "sample_class", *EXPANDED_FEATURES,
                     "age_data_status", "age_data_source_year"]
    complete: dict[str, dict[str, str]] = {}
    with OUT_BRIDGE.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=bridge_fields)
        writer.writeheader()
        for subject in sorted(source_rows):
            source = source_rows[subject]
            identity = ids[subject]
            row = {
                "subject_id": subject,
                "canonical_property_id": identity["canonical_property_id"],
                "sample_class": identity["sample_class"],
                "age_data_status": (source.get("age_data_status") or "").strip(),
                "age_data_source_year": (source.get("age_data_source_year") or "").strip(),
            }
            for name in EXPANDED_FEATURES:
                row[name] = (source.get(name) or "").strip()
            writer.writerow(row)
            if all(row[name] != "" for name in EXPANDED_FEATURES):
                complete[subject] = row

    with SOURCE_CSV.open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.reader(stream)
        source_header = next(reader)
    feature_columns = [name for name in source_header
                       if name not in {"subject_id", "sample_class", "latitude", "longitude",
                                       "state_dosm", "age_data_status", "age_data_source_year"}]
    # The model's 64 inputs are the observed columns minus the 3 LandScan fields.
    feature_columns = [name for name in feature_columns
                       if not name.startswith("landscan_ambient_pop_")]
    if len(feature_columns) != 64:
        raise SystemExit(f"Expected 64 model columns, derived {len(feature_columns)}")

    # --- SHAP background: 50 P + 50 U complete training rows, seeded ------
    # Completeness is judged on the FULL 64-feature vector from the source
    # dataset itself, not only the 20 bridged columns.
    complete_observations: dict[str, dict[str, str]] = {}
    for subject, source in source_rows.items():
        if all((source.get(name) or "").strip() != "" for name in feature_columns):
            complete_observations[subject] = source
    by_class: dict[str, list[str]] = {"P": [], "U": []}
    for subject in sorted(complete_observations):
        label = (complete_observations[subject].get("sample_class") or "").strip().upper()
        if label in by_class:
            by_class[label].append(subject)
    rng = random.Random(20261115)  # same seed family as the training package
    picked: list[str] = []
    for label in ("P", "U"):
        pool = by_class[label][:]
        rng.shuffle(pool)
        picked.extend(sorted(pool[:50]))
    picked = sorted(picked)

    shap_fields = ["subject_id", "sample_class", *feature_columns]
    with OUT_SHAP.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=shap_fields)
        writer.writeheader()
        for subject in picked:
            row = {"subject_id": subject, "sample_class": complete_observations[subject]["sample_class"]}
            for name in feature_columns:
                row[name] = (complete_observations[subject].get(name) or "").strip()
            writer.writerow(row)

    print(f"bridge rows: {len(source_rows)} (complete on expanded features: {len(complete)})")
    print(f"complete 64-feature training rows: {len(complete_observations)} "
          f"(P={len(by_class['P'])}, U={len(by_class['U'])})")
    print(f"shap background rows: {len(picked)}")
    print("sha256 bridge:", _sha256(OUT_BRIDGE))
    print("sha256 shap:  ", _sha256(OUT_SHAP))


if __name__ == "__main__":
    main()
