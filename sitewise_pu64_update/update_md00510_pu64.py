"""Update MD-00510's 64-feature PU research score without overwriting baseline47.

Run from the SiteWise FYP/backend directory using its .venv Python.
Read-only by default; pass --apply to write one JSONB key on exactly one row.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import text

PROPERTY_ID = "MD-00510"
RENTAL_ID = 316
REFERENCE_PU64 = 0.5888606695885784  # checked-in research example; sanity check only
EXPECTED_ORIGINAL_SCORE = 27.255328732372767


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Commit one-row JSONB score update (default: dry-run).")
    parser.add_argument("--allow-reference-drift", action="store_true", help="Permit live score >2 points away from checked-in example; review data provenance first.")
    args = parser.parse_args()

    backend_dir = Path.cwd()
    if not (backend_dir / "src" / "sitewise" / "ml" / "pu_expanded.py").is_file():
        parser.error("Run from C:\\Users\\Lenovo\\AndroidStudioProjects\\FYP\\backend, not the repository root.")
    sys.path.insert(0, str(backend_dir / "src"))

    # Only load trusted local application modules / model files.
    from sitewise.core.config import Settings
    from sitewise.db.analytics_session import analytics_engine
    from sitewise.db.session import engine
    from sitewise.ml.model_loader import ModelLoader
    from sitewise.ml.pu_expanded import EXPANDED_MODEL_NAME, expanded_prediction
    from sqlmodel import Session

    settings = Settings()
    if settings.pu_model_variant != "expanded64":
        raise SystemExit(f"STOP: active SITEWISE_PU_MODEL_VARIANT={settings.pu_model_variant!r}, expected 'expanded64'.")

    artifact = backend_dir / "src" / "sitewise" / "ml" / f"{EXPANDED_MODEL_NAME}.joblib"
    if not artifact.is_file():
        raise SystemExit(f"STOP: missing trusted 64-feature model: {artifact}")
    model_sha256 = hashlib.sha256(artifact.read_bytes()).hexdigest()
    model = ModelLoader().load_cached(EXPANDED_MODEL_NAME)
    if len(model.feature_names) != 64:
        raise SystemExit(f"STOP: expected 64 model inputs; found {len(model.feature_names)}.")
    version = str(model.meta.get("model_variant") or "unknown")

    # Calculate from this machine's configured analytics database and exact
    # fitted 64-feature artifact. No score is copied blindly from examples.
    with Session(analytics_engine) as analytics:
        outcome = expanded_prediction(analytics, PROPERTY_ID)
    if outcome.get("available") is not True:
        print(json.dumps({"property": PROPERTY_ID, "status": "NOT_UPDATED", "reason": outcome.get("reason"),
                          "feature_coverage": outcome.get("feature_coverage")}, indent=2, default=str))
        raise SystemExit("STOP: live expanded64 prediction is unavailable.")

    raw = float(outcome["score"])
    if not math.isfinite(raw) or not 0 <= raw <= 1:
        raise SystemExit(f"STOP: model returned invalid PU score {raw}.")
    coverage = outcome.get("feature_coverage") or {}
    if int(coverage.get("feature_count", 0)) != 64:
        raise SystemExit("STOP: feature coverage does not match 64-feature model.")
    missing = list(coverage.get("missing_features") or [])
    if missing:
        print("WARNING: model accepted these imputed residential inputs:", missing)
    if abs(raw - REFERENCE_PU64) > 0.02 and not args.allow_reference_drift:
        print(json.dumps({"live_score_0_100": 100 * raw, "checked_in_example_0_100": 100 * REFERENCE_PU64,
                          "score_difference_points": 100 * (raw - REFERENCE_PU64)}, indent=2))
        raise SystemExit("STOP: live 64-feature prediction differs by >2 points from the MD-00510 reference. Investigate changed features/model; then use --allow-reference-drift ONLY if verified.")

    score_document = {
        "model_variant": "expanded64",
        "model_name": EXPANDED_MODEL_NAME,
        "model_version": version,
        "artifact_sha256": model_sha256,
        "score_raw_0_1": raw,
        "score_0_100": raw * 100,
        "feature_count": 64,
        "observed_feature_count": int(coverage.get("available_features", 0)),
        "imputed_features": missing,
        "score_semantics": "UNCALIBRATED_PvU_RESEARCH_ASSOCIATION_NOT_BUSINESS_SUCCESS_PROBABILITY",
        "research_only": True,
        "production_ready": False,
        "calculated_at_utc": datetime.now(timezone.utc).isoformat(),
        "source": "sitewise.ml.pu_expanded.expanded_prediction",
    }

    print(json.dumps({"property_id": PROPERTY_ID, "rental_id": RENTAL_ID, "variant": "expanded64",
                      "model_version": version, "artifact_sha256": model_sha256,
                      "computed_pu_score_0_100": raw * 100,
                      "reference_pu_score_0_100": REFERENCE_PU64 * 100,
                      "missing_or_imputed_features": missing, "mode": "APPLY" if args.apply else "DRY RUN"}, indent=2))

    # Lock only the intended record, verify the identifier binding and preserve
    # the 47-feature catalogue_suitability_score and all provenance fields.
    with engine.begin() as conn:
        row = conn.execute(text("""
            SELECT id, listing_id, catalogue_id, catalogue_suitability_score,
                   catalogue_source_data, verification_status, is_published
            FROM fyp.rental_properties
            WHERE id = :id AND listing_id = :ref AND catalogue_id = :ref
            FOR UPDATE
        """), {"id": RENTAL_ID, "ref": PROPERTY_ID}).mappings().first()
        if row is None:
            raise SystemExit("STOP: rental id 316 is not bound to MD-00510 in the writable DATABASE_URL.")
        previous = float(row["catalogue_suitability_score"])
        if not math.isclose(previous, EXPECTED_ORIGINAL_SCORE, rel_tol=0, abs_tol=1e-5):
            raise SystemExit(f"STOP: original baseline47 score changed unexpectedly: {previous}.")
        original = row["catalogue_source_data"] or {}
        if not isinstance(original, dict):
            raise SystemExit("STOP: catalogue_source_data must be a JSON object; update refused.")
        raw47 = original.get("research_p_association_score")
        if raw47 is not None and not math.isclose(float(raw47) * 100, previous, rel_tol=0, abs_tol=1e-5):
            raise SystemExit("STOP: original score and research metadata disagree; update refused.")

        if not args.apply:
            print(f"DRY RUN: record exists; approved={row['verification_status']!r}, published={row['is_published']!r}; original PU score {previous:.4f}/100 preserved.")
            return 0

        result = conn.execute(text("""
            UPDATE fyp.rental_properties
            SET catalogue_source_data = jsonb_set(
                COALESCE(catalogue_source_data, '{}'::jsonb),
                '{pu_expanded64}', CAST(:score_json AS jsonb), true
            )
            WHERE id = :id AND listing_id = :ref AND catalogue_id = :ref
        """), {"id": RENTAL_ID, "ref": PROPERTY_ID, "score_json": json.dumps(score_document, separators=(',', ':'))})
        if result.rowcount != 1:
            raise SystemExit(f"STOP: expected one updated row, got {result.rowcount}.")
        check = conn.execute(text("""
            SELECT catalogue_suitability_score,
                   catalogue_source_data->>'research_p_association_score' AS original_pu,
                   catalogue_source_data->'pu_expanded64'->>'score_0_100' AS expanded_pu,
                   verification_status, is_published
            FROM fyp.rental_properties WHERE id = :id AND listing_id = :ref
        """), {"id": RENTAL_ID, "ref": PROPERTY_ID}).mappings().one()
        if not math.isclose(float(check["catalogue_suitability_score"]), previous, rel_tol=0, abs_tol=1e-5):
            raise SystemExit("STOP: original PU changed unexpectedly; transaction will roll back.")
        if not math.isclose(float(check["expanded_pu"]), raw * 100, rel_tol=0, abs_tol=1e-9):
            raise SystemExit("STOP: saved 64-feature score differs; transaction will roll back.")
        print(f"UPDATED 1 row: original={previous:.4f}/100; expanded64={float(check['expanded_pu']):.4f}/100; verification={check['verification_status']}; published={check['is_published']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
