"""Durable, idempotent Operational25 feature scoring for canonical properties.

Queue state reuses ``fyp.property_enrichment_category`` (category
``operational25``); feature vectors and predictions reuse the existing JSONB
columns of ``fyp.property_geospatial_features`` under a model-specific key.
No new table or column is introduced. Expanded64 snapshots are never touched.

Shadow mode is the default: scores are persisted but the deployed
``expanded64`` recommendation scores and ranking are unchanged until an
operator explicitly selects ``operational25`` via the model variant setting.
"""
from __future__ import annotations

import json
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import bindparam, text
from sqlmodel import Session

from sitewise.core.config import settings
from sitewise.db.analytics_session import analytics_engine
from sitewise.ml import operational25 as op25
from sitewise.services.property_enrichment_service import coordinate_hash, _valid_coordinates

CATEGORY = "operational25"
VERSION = op25.FEATURE_VERSION + "-persisted-1"


def enqueue(session: Session, property_id: int, *, force: bool = False) -> bool:
    """Queue one property for async scoring if coordinates/version changed."""
    row = session.execute(text(
        "SELECT latitude, longitude FROM fyp.rental_properties WHERE id=:id FOR UPDATE"
    ), {"id": property_id}).first()
    if row is None:
        raise LookupError("Property not found")
    if not _valid_coordinates(row.latitude, row.longitude):
        return False
    hashed = coordinate_hash(float(row.latitude), float(row.longitude))
    result = session.execute(text("""
        INSERT INTO fyp.property_enrichment_category
            (property_id, category, phase, status, coordinate_hash, calculation_version)
        VALUES (:id, :category, 'postgis', 'pending', :hash, :version)
        ON CONFLICT (property_id, category) DO UPDATE SET
            status='pending', coordinate_hash=EXCLUDED.coordinate_hash,
            calculation_version=EXCLUDED.calculation_version, last_error=NULL,
            attempt_count=0, updated_at=now()
        WHERE (fyp.property_enrichment_category.status <> 'running'
               OR fyp.property_enrichment_category.started_at < now() - interval '5 minutes')
          AND (fyp.property_enrichment_category.coordinate_hash IS DISTINCT FROM :hash
               OR fyp.property_enrichment_category.calculation_version IS DISTINCT FROM :version
               OR (:force AND fyp.property_enrichment_category.status NOT IN ('pending','running')))
    """), {"id": property_id, "category": CATEGORY, "hash": hashed,
           "version": VERSION, "force": force})
    return bool(result.rowcount)


def run_next(session: Session) -> bool:
    """Claim, calculate and persist at most one queued job. Returns worked flag."""
    job = session.execute(text("""
        SELECT q.property_id, q.coordinate_hash, p.latitude, p.longitude
          FROM fyp.property_enrichment_category q
          JOIN fyp.rental_properties p ON p.id=q.property_id
         WHERE q.category=:category
           AND (q.status='pending' OR (q.status='running' AND q.started_at < now()-interval '5 minutes'))
           AND NOT EXISTS (
             SELECT 1 FROM fyp.property_enrichment_category r WHERE r.property_id=q.property_id
                AND (r.category LIKE 'expanded64_%' OR r.category=:category)
                AND r.status='running' AND r.started_at>=now()-interval '5 minutes'
           )
         ORDER BY q.updated_at, q.property_id
         LIMIT 1 FOR UPDATE OF p SKIP LOCKED
    """), {"category": CATEGORY}).mappings().first()
    if job is None:
        session.rollback()
        return False
    job = dict(job)
    pid = int(job["property_id"])
    if session.execute(text("""
        SELECT 1 FROM fyp.property_enrichment_category WHERE property_id=:id
        AND (category LIKE 'expanded64_%' OR category=:category)
        AND status='running' AND started_at>=now()-interval '5 minutes' LIMIT 1
    """), {"id": pid, "category": CATEGORY}).first():
        session.rollback()
        return False
    attempt = session.execute(text("""
        UPDATE fyp.property_enrichment_category
           SET status='running', attempt_count=attempt_count+1, started_at=now(), updated_at=now()
         WHERE property_id=:id AND category=:category
        RETURNING attempt_count
    """), {"id": pid, "category": CATEGORY}).scalar_one()
    session.commit()

    status, reason, measurements, prediction = "failed", None, {}, {}
    try:
        latitude, longitude = job["latitude"], job["longitude"]
        if (not _valid_coordinates(latitude, longitude)
                or coordinate_hash(float(latitude), float(longitude)) != job["coordinate_hash"]):
            status, reason = "stale", "Property coordinates changed during calculation"
        else:
            with Session(analytics_engine) as analytics:
                analytics.connection().exec_driver_sql("SET TRANSACTION READ ONLY")
                analytics.connection().exec_driver_sql("SET LOCAL statement_timeout = '30s'")
                measurements = op25.extract(analytics, float(latitude), float(longitude))
            if not measurements["available"]:
                status, reason = "unavailable", "; ".join(measurements["blockers"])[:500]
            else:
                status = "current"
                if settings.pu_model_variant == "operational25":
                    prediction = op25.score(measurements["values"], property_id=str(pid))
                    from sitewise.services.expanded64_enrichment import explain_prediction
                    try:
                        prediction["explanation"] = explain_prediction(
                            op25.MODEL_NAME, "operational25", measurements["values"],
                            measurements["imputable_missing"], prediction["score"],
                        )
                    except Exception as exc:
                        prediction["explanation_unavailable_reason"] = f"SHAP unavailable ({type(exc).__name__})"
    except Exception as exc:  # noqa: BLE001 - queue row records the failure reason
        session.rollback()
        status, reason = "failed", f"Calculation failed ({type(exc).__name__})"

    current = session.execute(text(
        "SELECT latitude, longitude FROM fyp.rental_properties WHERE id=:id FOR UPDATE"
    ), {"id": pid}).first()
    still_valid = current is not None and _valid_coordinates(current.latitude, current.longitude)
    if not still_valid or coordinate_hash(float(current.latitude), float(current.longitude)) != job["coordinate_hash"]:
        status, reason = "stale", "Property coordinates changed during calculation"
    owned = session.execute(text("""
        UPDATE fyp.property_enrichment_category
           SET status=:status, last_error=:reason, completed_at=now(), updated_at=now()
         WHERE property_id=:id AND category=:category AND coordinate_hash=:hash
           AND status='running' AND attempt_count=:token
    """), {"id": pid, "category": CATEGORY, "hash": job["coordinate_hash"],
           "status": status, "reason": reason, "token": attempt}).rowcount

    if owned and status in ("current", "unavailable") and measurements and any(
        value is not None for value in measurements["values"].values()
    ):
        calculated_at = datetime.now(UTC).isoformat()
        feature_payload = {
            "canonical_property_id": str(pid),
            "coordinate_hash": measurements["coordinate_hash"],
            "feature_calculation_version": VERSION,
            "measurement_version": measurements["feature_calculation_version"],
            "feature_digest": measurements["feature_digest"],
            "feature_order": op25.contract()["feature_names"],
            "validated_features": {
                name: value for name, value in measurements["values"].items()
                if value is not None
            },
            "imputable_missing": measurements["imputable_missing"],
            "sources": measurements["sources"],
            "groups": measurements["groups"],
            "model_version": prediction.get("model_version"),
            "model_name": prediction.get("model_name"),
            "model_sha256": prediction.get("model_sha256"),
            "prediction_status": "scored_shadow" if prediction else "inputs_only",
            "pu_score": prediction.get("score"),
            "calculated_at": calculated_at,
        }
        score_payload = {
            "canonical_property_id": str(pid),
            "model_version": prediction.get("model_version"),
            "model_sha256": prediction.get("model_sha256"),
            "feature_digest": prediction.get("feature_digest"),
            "coordinate_hash": measurements["coordinate_hash"],
            "pu_score": prediction.get("score"),
            "score_0_100": prediction.get("score_0_100"),
            "explanation": prediction.get("explanation"),
            "explanation_unavailable_reason": prediction.get("explanation_unavailable_reason"),
            "prediction_status": "scored_shadow" if prediction else "inputs_only",
            "research_only": True,
            "production_ready": False,
            "calculated_at": calculated_at,
        }
        session.execute(text("""
            INSERT INTO fyp.property_geospatial_features
                (property_id, expanded64_measurements, pu_inference_snapshot, last_calculated_at)
            VALUES (:id, jsonb_build_object(:key, CAST(:features AS jsonb)),
                    CASE WHEN :scored THEN jsonb_build_object(:key, CAST(:prediction AS jsonb)) END, now())
            ON CONFLICT (property_id) DO UPDATE SET
                expanded64_measurements = jsonb_set(
                    COALESCE(fyp.property_geospatial_features.expanded64_measurements, '{}'::jsonb),
                    ARRAY[:key], CAST(:features AS jsonb)),
                pu_inference_snapshot = CASE WHEN :scored THEN jsonb_set(
                    COALESCE(fyp.property_geospatial_features.pu_inference_snapshot, '{}'::jsonb),
                    ARRAY[:key], CAST(:prediction AS jsonb))
                    ELSE fyp.property_geospatial_features.pu_inference_snapshot END,
                last_calculated_at = now()
        """), {"id": pid, "key": CATEGORY, "scored": bool(prediction),
               "features": json.dumps(feature_payload, allow_nan=False),
               "prediction": json.dumps(score_payload, allow_nan=False)})
    if owned and status == "stale":
        enqueue(session, pid)
    session.commit()
    return True


def score_for_catalogue_id(session: Session, property_id: str) -> dict[str, Any]:
    """Resolve an Operational25 snapshot for a research/catalogue property id.

    The canonical id is resolved through verified subject links or the
    rental_properties catalogue id — never guessed from a numeric prefix.
    """
    unavailable: dict[str, Any] = {"available": False, "coordinate_hash": None}
    row = session.execute(text("""
        SELECT p.id, p.latitude, p.longitude
          FROM fyp.rental_properties p
         WHERE p.catalogue_id = :pid
            OR EXISTS (
                SELECT 1 FROM fyp.property_subject_links l
                 WHERE l.property_id = p.id AND l.sitewise_property_id = :pid
                   AND l.match_verified IS TRUE
            )
         ORDER BY (p.catalogue_id = :pid) DESC, p.id
         LIMIT 1
    """), {"pid": str(property_id)}).mappings().first()
    if row is None:
        return unavailable
    snapshot = persisted(session, int(row["id"]), row["latitude"], row["longitude"])
    if not snapshot.get("available"):
        return unavailable
    features = session.execute(text("""
        SELECT expanded64_measurements -> :key AS features
          FROM fyp.property_geospatial_features WHERE property_id=:id
    """), {"id": int(row["id"]), "key": CATEGORY}).scalar()
    return {
        **snapshot,
        # Both names are used by existing consumers: recommendations read
        # "score", the property detail reads "pu_score".
        "score": snapshot.get("pu_score"),
        "canonical_property_id": str(row["id"]),
        "features": dict(features or {}).get("validated_features", {}),
        "feature_order": dict(features or {}).get("feature_order", []),
    }


def scores_many(session: Session, rows: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """Read persisted shadow scores for candidate rows keyed by canonical id.

    A research row without a canonical ``listing_id`` is never borrowed from
    another property: it reports unavailable with its own id.
    """
    result: dict[str, dict[str, Any]] = {}
    canonical: dict[int, list[str]] = {}
    for row in rows:
        key = str(row.get("property_id") or "")
        try:
            listing_id = int(row["listing_id"]) if row.get("listing_id") is not None else None
        except (TypeError, ValueError):
            listing_id = None
        if listing_id is not None:
            canonical.setdefault(listing_id, []).append(key)
        else:
            result[key] = {"available": False, "feature_coverage": {},
                           "inference_state": "operational25_no_canonical_property"}
    if not canonical:
        return result
    ids = list(canonical)
    stored = session.execute(text("""
        SELECT property_id, pu_inference_snapshot -> :key AS prediction,
               expanded64_measurements -> :key AS features
          FROM fyp.property_geospatial_features
         WHERE property_id IN :ids
    """).bindparams(bindparam("ids", expanding=True)),
        {"key": CATEGORY, "ids": ids}).mappings().all()
    by_id = {int(row["property_id"]): row for row in stored}
    for listing_id, keys in canonical.items():
        row = by_id.get(listing_id)
        prediction = dict(row["prediction"]) if row and row["prediction"] else {}
        features = dict(row["features"] or {}) if row else {}
        score = prediction.get("pu_score")
        available = (
            score is not None
            and prediction.get("model_sha256") == op25.ARTIFACT_SHA256
            and features.get("feature_calculation_version") == VERSION
            and prediction.get("coordinate_hash") == features.get("coordinate_hash")
        )
        payload = {
            "available": bool(available),
            "score": float(score) if available else None,
            "inference_state": "ready" if available else "operational25_inference_unavailable",
            "feature_coverage": {
                "validated": len(features.get("validated_features", {})),
                "feature_count": len(op25.contract()["feature_names"]),
                "imputable_missing": features.get("imputable_missing", []),
                "sources": features.get("sources", {}),
                "prediction_status": prediction.get("prediction_status"),
            },
        }
        for key in keys:
            result[key] = payload
    return result


def persisted(session: Session, property_id: int, latitude: Any, longitude: Any) -> dict[str, Any]:
    """Read the cached Operational25 result; never fabricate a score."""
    base: dict[str, Any] = {
        "available": False, "model_name": op25.MODEL_NAME,
        "model_version": op25.contract()["version"], "research_only": True,
        "prediction_status": "not_calculated", "pu_score": None,
    }
    if not _valid_coordinates(latitude, longitude):
        return {**base, "prediction_status": "no_coordinates"}
    hashed = coordinate_hash(float(latitude), float(longitude))
    row = session.execute(text("""
        SELECT expanded64_measurements -> :key AS features,
               pu_inference_snapshot -> :key AS prediction,
               (SELECT status FROM fyp.property_enrichment_category
                 WHERE property_id=:id AND category=:key) AS queue_status
          FROM fyp.property_geospatial_features WHERE property_id=:id
    """), {"id": property_id, "key": CATEGORY}).mappings().first()
    if row is None or not row["prediction"]:
        return base
    prediction = dict(row["prediction"])
    features = dict(row["features"] or {})
    current = (prediction.get("coordinate_hash") == hashed
               and features.get("feature_calculation_version") == VERSION
               and prediction.get("model_sha256") == op25.ARTIFACT_SHA256
               and prediction.get("feature_digest") == features.get("feature_digest")
               and features.get("prediction_status") == "scored_shadow")
    if not current:
        return {**base, **prediction, "prediction_status": "stale", "pu_score": None}
    return {**base, **prediction,
            "feature_coverage": {
                "validated": len(features.get("validated_features", {})),
                "feature_count": len(op25.contract()["feature_names"]),
                "imputable_missing": features.get("imputable_missing", []),
                "sources": features.get("sources", {}),
            },
            "queue_status": row["queue_status"],
            "available": row["queue_status"] == "current" and prediction.get("pu_score") is not None}
