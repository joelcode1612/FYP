"""Reproduce real PU artifact predictions for trusted research properties.

Run from backend/ with its project virtual environment:
    .venv/Scripts/python.exe scripts/ml/verify_pu_artifacts.py

The script only reads trusted, repository-tracked joblib files and opens the
analytics database in a read-only transaction. It never trains, writes scores,
changes database records, or fills missing feature values. For each property it
resolves the exact artifact feature order from the analytics DB and committed
training bridge, then calls the same PULearning.predict_or_report() inference
path used by the application. MD-00510 additionally checks parity against the
committed original 47-feature reference vector. Pass --include-shap to reproduce
SHAP against the tracked 25-row background for original/selected PU artifacts;
experimental SHAP is explicitly skipped until its own background/license
provenance is verified.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

BACKEND_DIR = Path(__file__).resolve().parents[2]
REPO_ROOT = BACKEND_DIR.parent
if str(BACKEND_DIR / "src") not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR / "src"))

from sqlalchemy import text

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.db.analytics_session import analytics_engine
from sitewise.ml.feature_bridge import merge_bridge_features
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.property_features import FeatureResolutionError, PropertyFeatureRepository
from sitewise.ml.pu_learning import PULearning
from sitewise.ml.pu_variant import EXPERIMENTAL_MODEL_NAME
from sitewise.ml.selected_pu_integration import SELECTED_MODEL_NAME
from sitewise.ml.shap_explainer import ShapExplainer
from sitewise.ml.sitewise_recommender_v3 import load_snapshot

ARTIFACT_DIR = BACKEND_DIR / "src" / "sitewise" / "ml"
REFERENCE_VECTOR = BACKEND_DIR / "ml_reference" / "example_property_47.json"
SHAP_BACKGROUND = BACKEND_DIR / "ml_reference" / "shap_background_47.csv"
PROPERTY_IDS = ("MD-00510", "MD-01755")
PU_MODELS = ("pu_model", SELECTED_MODEL_NAME, EXPERIMENTAL_MODEL_NAME)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _repository_head() -> str | None:
    try:
        return subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def _artifact_path(name: str) -> Path:
    return ARTIFACT_DIR / {
        "pu_model": "PU_model.joblib",
        SELECTED_MODEL_NAME: "sitewise_selected_pu_model.joblib",
        EXPERIMENTAL_MODEL_NAME: "sitewise_pu_47_experimental.joblib",
    }[name]


def _estimator_details(model: object) -> list[dict[str, str]]:
    estimators = getattr(model, "estimators_", None)
    if estimators is None:
        estimators = getattr(model, "estimators", None)
    details: list[dict[str, str]] = []
    for estimator in estimators or ():
        final = estimator
        steps = getattr(estimator, "steps", None)
        if steps:
            final = steps[-1][1]
        details.append(
            {
                "pipeline_type": f"{type(estimator).__module__}.{type(estimator).__qualname__}",
                "final_estimator_type": f"{type(final).__module__}.{type(final).__qualname__}",
            }
        )
    return details


def _stored_score(connection: Any, property_id: str) -> dict[str, Any] | None:
    row = connection.execute(
        text(
            """
            SELECT source_data->>'research_p_association_score' AS score,
                   source_data->>'score_type' AS score_type,
                   source_data->>'model_method' AS model_method,
                   source_data->>'model_version' AS model_version,
                   source_data->>'feature_set' AS feature_set
            FROM sitewise_app.properties
            WHERE id = :property_id
            """
        ),
        {"property_id": property_id},
    ).mappings().first()
    if row is None:
        return None
    result = dict(row)
    if result.get("score") is not None:
        result["score"] = float(result["score"])
    return result


def _reference_parity(property_id: str, vector: dict[str, float], order: list[str]) -> dict[str, Any] | None:
    if property_id != "MD-00510" or not REFERENCE_VECTOR.is_file():
        return None
    reference = json.loads(REFERENCE_VECTOR.read_text(encoding="utf-8"))
    reference_values = reference.get("features", {})
    missing = [name for name in order if name not in reference_values]
    if missing:
        return {
            "reference_file": str(REFERENCE_VECTOR.relative_to(REPO_ROOT)),
            "reference_property_id": reference.get("property_id"),
            "matches_resolved_vector": False,
            "missing_reference_features": missing,
        }
    differences = {
        name: {
            "reference": float(reference_values[name]),
            "resolved": float(vector[name]),
            "absolute_difference": abs(float(reference_values[name]) - float(vector[name])),
        }
        for name in order
        if float(reference_values[name]) != float(vector[name])
    }
    return {
        "reference_file": str(REFERENCE_VECTOR.relative_to(REPO_ROOT)),
        "reference_property_id": reference.get("property_id"),
        "feature_count": len(order),
        "matches_resolved_vector": not differences,
        "differences": differences,
    }


def _load_artifact_report(name: str) -> tuple[dict[str, Any], Any]:
    path = _artifact_path(name)
    loaded = ModelLoader().load(name)
    model = loaded.model
    report = {
        "name": name,
        "path": str(path.relative_to(REPO_ROOT)),
        "exists": path.is_file(),
        "size_bytes": path.stat().st_size,
        "sha256": _sha256(path),
        "deserialization": "success via production ModelLoader.load()",
        "python_type": f"{type(model).__module__}.{type(model).__qualname__}",
        "nested_fitted_estimators": _estimator_details(model),
        "version": loaded.meta.get("version") or loaded.meta.get("model_version") or loaded.meta.get("feature_set"),
        "feature_set": loaded.meta.get("feature_set"),
        "feature_count": len(loaded.feature_names),
        "feature_names_in_exact_model_order": loaded.feature_names,
        "n_features_in": getattr(model, "n_features_in_", None),
        "has_predict": callable(getattr(model, "predict", None)),
        "has_predict_proba": callable(getattr(model, "predict_proba", None)),
        "metadata": loaded.meta,
    }
    return report, loaded


def _load_shap_background(feature_names: list[str]) -> list[dict[str, float]]:
    import csv

    with SHAP_BACKGROUND.open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        if not reader.fieldnames or not set(feature_names).issubset(reader.fieldnames):
            return []
        rows: list[dict[str, float]] = []
        for row in reader:
            try:
                values = {name: float(row[name]) for name in feature_names}
            except (KeyError, TypeError, ValueError):
                continue
            if all(math.isfinite(value) for value in values.values()):
                rows.append(values)
        return rows[:100]


def _shap_evidence(name: str, loaded: Any, features: dict[str, float], model_score: float) -> dict[str, Any]:
    """Explain only models with a checked compatible real reference sample."""
    if name == EXPERIMENTAL_MODEL_NAME:
        return {
            "available": False,
            "reason": (
                "Skipped: experimental model card/license provenance does not verify "
                "that the original baseline SHAP background is a compatible reference."
            ),
        }
    try:
        background = _load_shap_background(loaded.feature_names)
        if not background:
            return {"available": False, "reason": "No complete real background rows for this feature contract."}
        started = time.perf_counter()
        explained = ShapExplainer(model_name=name).explain(features, background=background)
        shap_seconds = time.perf_counter() - started
        baseline = float(explained["baseline_association"])
        output = float(explained["positive_label_association"])
        contributions = {k: float(v) for k, v in explained["contributions"].items()}
        reconstructed = baseline + sum(contributions.values())
        additivity_error = abs(reconstructed - output)
        model_difference = abs(output - model_score)
        return {
            "available": True,
            "artifact": _artifact_path(name).relative_to(REPO_ROOT).as_posix(),
            "artifact_sha256": _sha256(_artifact_path(name)),
            "explainer": explained.get("explainer"),
            "feature_count": len(loaded.feature_names),
            "background_path": SHAP_BACKGROUND.relative_to(REPO_ROOT).as_posix(),
            "background_size": explained.get("background_size"),
            "shap_runtime_seconds": shap_seconds,
            "baseline": baseline,
            "contributions": contributions,
            "sum_contributions": sum(contributions.values()),
            "model_output": output,
            "baseline_plus_contributions": reconstructed,
            "additivity_absolute_error": additivity_error,
            "additivity_tolerance": 1e-6,
            "additivity_verified": additivity_error < 1e-6,
            "prediction_score": model_score,
            "prediction_score_absolute_difference": model_difference,
            "explained_output_matches_prediction": model_difference < 1e-6,
        }
    except (ModelUnavailableError, OSError, ImportError, KeyError, TypeError, ValueError) as exc:
        return {
            "available": False,
            "reason": f"{type(exc).__name__}: {exc}",
        }


def verify_property(
    connection: Any,
    property_id: str,
    loaded_models: dict[str, Any],
    *,
    include_shap: bool = False,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "property_id": property_id,
        "stored_score_record": _stored_score(connection, property_id),
        "artifact_predictions": {},
    }
    repo = PropertyFeatureRepository(connection)
    for name, loaded in loaded_models.items():
        try:
            bundle = repo.get(property_id, loaded.feature_names, source="catalog")
            coverage = merge_bridge_features(bundle, expected_features=loaded.feature_names)
        except FeatureResolutionError as exc:
            result["artifact_predictions"][name] = {
                "available": False,
                "score": None,
                "reason": f"Feature resolution failed: {exc}",
                "missing_features": [],
                "feature_sources": {},
            }
            continue

        ordered_values = [coverage.values.get(feature) for feature in loaded.feature_names]
        feature_evidence = [
            {
                "name": feature,
                "value": coverage.values.get(feature),
                "source": coverage.sources.get(feature),
            }
            for feature in loaded.feature_names
        ]
        features = {
            feature: coverage.values[feature]
            for feature in loaded.feature_names
            if coverage.values.get(feature) is not None
        }
        prediction = PULearning(model_name=name).predict_or_report(
            property_id,
            features,
            allow_model_imputation=False,
        )
        prediction_record: dict[str, Any] = {
            **prediction,
            "feature_count": len(loaded.feature_names),
            "available_feature_count": coverage.available_count,
            "missing_features": coverage.missing_features,
            "unrecoverable_features": coverage.unrecoverable_features,
            "input_feature_names_in_exact_model_order": loaded.feature_names,
            "input_values_in_exact_model_order": ordered_values,
            "input_feature_sources_in_exact_model_order": feature_evidence,
            "coverage_flags": coverage.flags,
        }
        stored = result["stored_score_record"]
        if (
            name == "pu_model"
            and prediction.get("available")
            and stored is not None
            and stored.get("score") is not None
        ):
            difference = abs(float(prediction["score"]) - float(stored["score"]))
            prediction_record["comparison_to_stored_score"] = {
                "stored_score": stored["score"],
                "absolute_difference": difference,
                "tolerance": 1e-6,
                "reproduces_within_tolerance": difference <= 1e-6,
                "basis": "Original PU_model.joblib with its corresponding exact training feature vector",
            }
        else:
            prediction_record["comparison_to_stored_score"] = {
                "performed": False,
                "reason": (
                    "Stored source_data.research_p_association_score is the original "
                    "legacy model score and cannot validate a different artifact, "
                    "or one of the score/feature vectors is unavailable."
                ),
            }
        prediction_record["md00510_reference_parity"] = _reference_parity(
            property_id, coverage.values, loaded.feature_names
        )
        if include_shap:
            prediction_record["shap_verification"] = (
                _shap_evidence(name, loaded, features, float(prediction["score"]))
                if prediction.get("available")
                else {"available": False, "reason": "Inference unavailable; SHAP was not run."}
            )
        result["artifact_predictions"][name] = prediction_record
    return result


def verify_v3_snapshot() -> dict[str, Any]:
    """Verify V3 identity/weights without treating it as a predictor."""
    path = ARTIFACT_DIR / "recommender_v3.joblib"
    snapshot = load_snapshot()
    return {
        "name": "recommender_v3",
        "path": str(path.relative_to(REPO_ROOT)),
        "exists": path.is_file(),
        "size_bytes": path.stat().st_size,
        "sha256": _sha256(path),
        "python_type": f"{type(snapshot).__module__}.{type(snapshot).__qualname__}",
        "has_predict": callable(getattr(snapshot, "predict", None)),
        "has_predict_proba": callable(getattr(snapshot, "predict_proba", None)),
        "description": snapshot.describe(),
        "classification": "calibration snapshot only; scoring is deterministic rules",
    }


def verify_recommendation_scoring() -> dict[str, Any]:
    """Reproduce generation for one existing saved-V3 test principal, read-only.

    This exercises the application service, not the HTTP authentication layer.
    It selects no personal identifier into the report, makes both DB sessions
    read-only, and injects the process-local result store so no batch is written
    to ``recommendation_result``.
    """
    from uuid import UUID

    from sqlmodel import Session

    from sitewise.core.config import Settings
    from sitewise.db.session import engine
    from sitewise.domain.recommendation_scoring import (
        SCORING_CONFIG,
        SCORING_CONFIG_V3,
        PropertyCandidate,
        eligibility_failures,
        preference_profile_from,
        rank_candidates,
    )
    from sitewise.ml.sitewise_recommender_v3 import load_snapshot
    from sitewise.repositories.generated_recommendation_store import GeneratedRecommendationStore
    from sitewise.repositories.recommendation_candidate_repository import (
        RecommendationCandidateRepository,
    )
    from sitewise.services.preferences_service import PreferencesService
    from sitewise.services.recommendation_generation_service import RecommendationGenerationService

    active_variant = Settings().pu_model_variant
    if active_variant != "legacy":
        return {
            "verified": False,
            "reason": (
                "Recommendation re-scoring helper currently records the default legacy path only; "
                f"active variant is {active_variant!r}."
            ),
        }

    with engine.connect() as connection:
        connection.execute(text("SET TRANSACTION READ ONLY"))
        chosen = connection.execute(
            text(
                """
                SELECT u.user_id, ep.preferences::jsonb AS preferences
                FROM users u
                JOIN entrepreneur_preferences ep ON ep.user_id = u.user_id
                WHERE u.role = 'entrepreneur'
                  AND u.account_status = 'active'
                  AND u.email LIKE '%@jwks-test.example'
                  AND ep.preferences::jsonb->>'requirements_version' = '3'
                ORDER BY ep.updated_at DESC, u.user_id
                LIMIT 1
                """
            )
        ).mappings().first()
    if chosen is None:
        return {
            "verified": False,
            "reason": "No existing active V3 Entrepreneur test profile with saved preferences was found.",
        }

    user_id = UUID(str(chosen["user_id"]))
    stored_profile = dict(chosen["preferences"])
    with Session(engine) as app_session, Session(analytics_engine) as analytics_session:
        app_session.execute(text("SET TRANSACTION READ ONLY"))
        analytics_session.execute(text("SET TRANSACTION READ ONLY"))
        service = RecommendationGenerationService(
            app_session,
            analytics_session,
            store=GeneratedRecommendationStore(),
        )
        generated = service.generate(user_id, limit=100)
        if generated.get("status") != "ok":
            return {
                "verified": False,
                "reason": "Service generation returned no eligible rows.",
                "candidate_summary": generated.get("candidate_summary"),
            }

        profile = preference_profile_from(PreferencesService(app_session).payload(user_id).get("preferences"))
        recommender = load_snapshot()
        candidate_rows = RecommendationCandidateRepository(analytics_session).list_candidates(
            max_rent=profile.max_rent_myr,
            min_size=profile.min_floor_area_sqft,
            state=None,
        )
        independent_scores = []
        for row in candidate_rows:
            candidate = PropertyCandidate.from_row(row)
            if eligibility_failures(candidate, profile):
                continue
            independent_scores.append(
                recommender.score_preference(
                    profile,
                    candidate,
                    config=SCORING_CONFIG_V3,
                    layer1_model="pu_model",
                )
            )
        independent_ranked = rank_candidates(independent_scores)
        independent_top = independent_ranked[: min(100, len(independent_ranked))]

        config = SCORING_CONFIG_V3 if profile.preferences_version == 3 else SCORING_CONFIG
        result_by_id = {str(row["property_id"]): row for row in generated["results"]}
        first_three: list[dict[str, Any]] = []
        for ranked in independent_top[:3]:
            row = result_by_id[ranked.property_id]
            personalization = row["personalisation"]
            components = personalization["components"]
            weights = ranked.coverage.get("effective_weights_v3") or config.weights.as_dict()
            known = [name for name, value in components.items() if value is not None]
            known_weight_sum = math.fsum(float(weights[name]) for name in known)
            preference_score = (
                math.fsum(float(weights[name]) * float(components[name]) for name in known)
                / known_weight_sum
                if known_weight_sum > 0 else None
            )
            preference_component_difference = (
                None
                if ranked.preference_match_score is None or preference_score is None
                else abs(float(ranked.preference_match_score) - preference_score)
            )
            pu_score = float(ranked.pu_association_score)
            final_score = (
                pu_score
                if preference_score is None
                else config.pu_weight * pu_score + config.preference_weight * preference_score
            )
            first_three.append(
                {
                    "property_id": ranked.property_id,
                    "result_id_ephemeral": row["result_id"],
                    "active_pu_model": generated["model"]["layer1_model"],
                    "model_version": generated["model"]["version"],
                    "pu_score": pu_score,
                    "pu_score_source": row["model"]["score_source"],
                    "pu_is_stored_or_live": "stored legacy catalogue model output",
                    "preference_match_score_recomputed_from_components": preference_score,
                    "preference_score_absolute_difference_vs_scorer": preference_component_difference,
                    "components": components,
                    "component_status": personalization["component_status"],
                    "applied_weights": weights,
                    "known_component_weight_sum": known_weight_sum,
                    "final_score_recomputed": final_score,
                    "final_score_rounded_six_decimals": round(final_score, 6),
                    "final_score_from_service": row["final_recommendation"]["score"],
                    "final_score_absolute_difference": abs(
                        final_score - float(row["final_recommendation"]["score"])
                    ),
                    "final_score_matches_within_1e-6": abs(
                        final_score - float(row["final_recommendation"]["score"])
                    ) <= 1e-6,
                    "independent_rank": ranked.rank,
                    "service_rank": row["final_recommendation"]["rank"],
                    "component_evidence": personalization["component_details"],
                }
            )

        independent_top_ids = [item.property_id for item in independent_top]
        service_top_ids = [str(row["property_id"]) for row in generated["results"]]
        return {
            "verified": bool(first_three)
            and independent_top_ids == service_top_ids
            and all(
                item["final_score_matches_within_1e-6"]
                and (item["preference_score_absolute_difference_vs_scorer"] or 0.0) <= 1e-9
                for item in first_three
            ),
            "verification_mode": (
                "direct application-service call; read-only PostgreSQL sessions; "
                "in-memory result store; no FastAPI HTTP authentication or persistent batch write"
            ),
            "existing_profile_kind": "active local Entrepreneur test profile with saved V3 preferences",
            "profile_identifier_disclosed": False,
            "preference_schema": stored_profile.get("requirements_version"),
            "preferences_summary": {
                key: stored_profile.get(key)
                for key in (
                    "fnb_concept", "service_model", "target_customers",
                    "recommendation_priority", "space_size_preference",
                )
            },
            "active_variant": active_variant,
            "layer2_engine": generated["layer2"]["engine"],
            "trained_recommender": generated["layer2"]["trained_recommender"],
            "scoring": generated["scoring"],
            "candidate_summary": generated["candidate_summary"],
            "candidate_count_independently_rescored": len(independent_scores),
            "first_three": first_three,
            "independent_rank_order_first_three": independent_top_ids[:3],
            "service_rank_order_first_three": service_top_ids[:3],
            "full_returned_rank_order_matches": independent_top_ids == service_top_ids,
            "batch_id_ephemeral": generated["batch_id"],
            "result_ids_persisted": False,
            "reused_existing_batch": generated["reused_existing_batch"],
        }


def verify_property_detail_insights() -> dict[str, Any]:
    """Capture the actual catalog insight read-model payload for UI parsing.

    The catalog route calls PropertyInsightsService.insights() after its own
    SELECT. Calling the same service here with a read-only analytics session
    verifies the deployed score/source/SHAP contract without bearer credentials
    or database writes. It does not substitute for testing the HTTP auth layer.
    """
    from sqlmodel import Session

    from sitewise.services.property_insights_service import PropertyInsightsService

    payloads = {}
    with Session(analytics_engine) as session:
        session.execute(text("SET TRANSACTION READ ONLY"))
        for property_id in PROPERTY_IDS:
            payloads[property_id] = PropertyInsightsService(
                session=session,
                analytics_session=session,
            ).insights(property_id)
    return {
        "verification_mode": "actual service payload called by GET /api/v1/catalog/properties/{id}/insights; DB read-only",
        "http_authentication_verified": False,
        "http_authentication_note": (
            "No authorized Supabase browser bearer token was available to this script; "
            "the running HTTP route responds 401 without one. Service output is live; "
            "the signed-in HTTP hop remains unverified."
        ),
        "properties": payloads,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--models",
        nargs="+",
        choices=PU_MODELS,
        default=list(PU_MODELS),
        help="PU artifacts to compare (default: all three trusted PU artifacts)",
    )
    parser.add_argument(
        "--properties",
        nargs="+",
        default=list(PROPERTY_IDS),
        help="Canonical property ids to score (default: MD-00510 MD-01755)",
    )
    parser.add_argument(
        "--no-database",
        action="store_true",
        help="Only describe model artifacts; skip property inference and database reads",
    )
    parser.add_argument(
        "--include-shap",
        action="store_true",
        help=(
            "Run verified Permutation SHAP for original/selected PU on the same "
            "property vectors; experimental47 is skipped without a matching "
            "licensed background provenance"
        ),
    )
    parser.add_argument(
        "--include-recommendations",
        action="store_true",
        help=(
            "Reproduce the top three from an existing saved-V3 test Entrepreneur "
            "using read-only DB sessions and an in-memory store (no HTTP auth proof)"
        ),
    )
    parser.add_argument(
        "--include-property-detail",
        action="store_true",
        help=(
            "Capture actual catalog insight service payloads for MD-00510 and MD-01755 "
            "so the Jaspr decoder/component test can consume live-contract responses"
        ),
    )
    args = parser.parse_args()

    reports: list[dict[str, Any]] = []
    loaded_models: dict[str, Any] = {}
    for name in args.models:
        try:
            report, loaded = _load_artifact_report(name)
            reports.append(report)
            loaded_models[name] = loaded
        except (ModelUnavailableError, OSError, ImportError, ValueError, TypeError) as exc:
            reports.append(
                {
                    "name": name,
                    "path": str(_artifact_path(name).relative_to(REPO_ROOT)),
                    "exists": _artifact_path(name).is_file(),
                    "deserialization": "failed",
                    "error": f"{type(exc).__name__}: {exc}",
                }
            )

    output: dict[str, Any] = {
        "repository_head": _repository_head(),
        "active_variant": None,
        "artifacts": reports,
        "v3_calibration_snapshot": verify_v3_snapshot(),
        "properties": [],
    }
    if not args.no_database and loaded_models:
        from sitewise.core.config import Settings

        output["active_variant"] = Settings().pu_model_variant
        with analytics_engine.connect() as connection:
            connection.execute(text("SET TRANSACTION READ ONLY"))
            output["analytics_database"] = connection.execute(
                text("SELECT current_database()")
            ).scalar_one()
            output["properties"] = [
                verify_property(
                    connection, property_id, loaded_models, include_shap=args.include_shap
                )
                for property_id in args.properties
            ]

    if args.include_recommendations and not args.no_database:
        output["recommendation_reproduction"] = verify_recommendation_scoring()
    if args.include_property_detail and not args.no_database:
        output["property_detail_insights"] = verify_property_detail_insights()

    print(json.dumps(output, indent=2, ensure_ascii=False, default=str))
    return 0 if all(r.get("deserialization") != "failed" for r in reports) else 1


if __name__ == "__main__":
    raise SystemExit(main())
