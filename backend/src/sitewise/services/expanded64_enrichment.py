"""Persist and serve current-coordinate measurements for the Expanded64 contract."""
from __future__ import annotations

import hashlib
import json
import math
import logging
from functools import lru_cache

from sqlalchemy import bindparam, text
from sqlalchemy.exc import SQLAlchemyError
from sqlmodel import Session

from sitewise.core.config import settings
from sitewise.db.analytics_session import analytics_engine
from sitewise.ml.expanded64_feature_definitions import DEFINITIONS_VERSION, definition_versions
from sitewise.ml.expanded64_network import Expanded64CoordinateExtractor
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.pu_expanded import (
    EXPANDED_COORDINATE_VERSION, STANDARDIZED_V2_FEATURES,
    active_expanded_model_name, coordinate_input_validated,
    expanded_policy_split, uses_v2_feature_definitions, _score_property,
)
from sitewise.services.age_band_raster_service import COVERAGE_STATUSES
from sitewise.services.property_enrichment_service import (
    PropertyEnrichmentService, coordinate_hash, _valid_coordinates,
)

logger = logging.getLogger(__name__)

VERSION = EXPANDED_COORDINATE_VERSION + "-persisted-2"
CATEGORIES = {
    "population": ("population_rings",),
    "age": (),
    "residential": ("residential_density",),
    "demand": ("demand_generator_pois",),
    "competition": ("competitor_counts",),
    "transit": ("transit_accessibility",),
    "network": ("road_geometry", "isochrone_population", "drive_isochrone"),
    "parking": ("parking_facilities",),
}
JOB_KEYS = tuple(f"expanded64_{key}" for key in CATEGORIES)
#: Address verdicts whose coordinates were written by the SERVER from the
#: provider response (``FypPropertyRepository.set_address_validation``).
#: ``validated`` is a precise premise-level match; ``partially_validated`` is a
#: user-confirmed approximate or ambiguous match. Both carry real, server-
#: derived coordinates, so both may drive coordinate measurements. Requiring
#: strictly ``validated`` silently blocked every listing whose confirmed match
#: was not premise-level, which is the common case for terrace/floor units.
VERIFIED_ADDRESS_STATUSES = ("validated", "partially_validated")

#: Per-category statement bound for the analytics transaction.
#:
#: Measured on the live catalogue: ``population``/``age``/``residential``/
#: ``demand``/``competition``/``parking``/``transit`` complete in well under a
#: second, so a tight bound still catches a runaway query. ``network`` runs
#: pgRouting pedestrian reach, a concave hull and a WorldPop pixel overlay, and
#: needs 20-45 s alone and more under concurrent load; bounding it at 25 s
#: produced ``QueryCanceled`` failures that were reported as calculation
#: failures even though nothing was wrong with the data.
DEFAULT_STATEMENT_TIMEOUT = "25s"
STATEMENT_TIMEOUTS = {"network": "180s"}

MEASUREMENT_METHODS = {
    "population_rings": "Whole WorldPop pixels selected by centroid distance from the property",
    "residential_density": "Count and clip OSM residential footprints and land use inside the radius",
    "demand_generator_pois": "Geodesic radius counts of active demand-generator POIs by class",
    "competitor_counts": "Geodesic radius counts of classified outlet records",
    "transit_accessibility": "OSM pedestrian network distance including access stubs; distinct GTFS facilities",
    "road_geometry": "PostGIS road and pedestrian geometry within distance buffers",
    "isochrone_population": "600-second pedestrian reach polygon; area-weighted WorldPop pixels",
    "drive_isochrone": "600-second free-flow drive reach polygon; geodesic area",
    "parking_facilities": "Distance to distinct kept parking facility geometries",
}



def _category(name: str) -> str:
    for prefix, group in (
        ("pop_age_", "age"), ("pop_", "population"), ("residential_", "residential"),
        ("office_", "demand"), ("schools_", "demand"), ("universities_", "demand"),
        ("retail_", "demand"), ("malls_", "demand"), ("hospitals_", "demand"),
        ("supermarkets_", "demand"), ("fnb_", "competition"), ("cafe_", "competition"),
        ("restaurant_", "competition"), ("fast_food_", "competition"),
        ("bakery_", "competition"), ("parking_", "parking"), ("nearest_parking", "parking"),
        ("transit_", "transit"), ("nearest_transit", "transit"), ("weekday_", "transit"),
        ("road_", "network"), ("nearest_major_", "network"), ("osm_walkway_", "network"),
        ("walk_isochrone_", "network"), ("drive_isochrone_", "network"),
        ("worldpop_walk_", "network"),
    ):
        if name.startswith(prefix):
            return group
    raise ValueError(f"Unmapped Expanded64 input: {name}")


@lru_cache(maxsize=1)
def contract() -> dict[str, str]:
    result = {
        name: _category(name)
        for name in ModelLoader().load_cached(active_expanded_model_name()).feature_names
    }
    expected = dict(zip(CATEGORIES, (4, 12, 8, 14, 10, 5, 8, 3)))
    if any(sum(value == category for value in result.values()) != count
           for category, count in expected.items()):
        raise ValueError("Expanded64 artifact category counts do not match the measurement contract")
    return result


def enqueue(session: Session, property_id: int, *, category: str | None = None,
            force: bool = False, verified_only: bool = False) -> bool:
    listing = session.execute(text("""
        SELECT latitude, longitude, address_validation_status
        FROM fyp.rental_properties WHERE id=:id FOR UPDATE
        """), {"id": property_id}).first()
    if listing is None:
        raise LookupError("Property not found")
    if verified_only and listing.address_validation_status not in VERIFIED_ADDRESS_STATUSES:
        return False
    if not _valid_coordinates(*listing[:2]):
        return False
    hash_value = coordinate_hash(*map(float, listing[:2]))
    # The targets are what this call is about. Scoping the in-flight check to
    # them matters: with the whole category set, a property that already had one
    # category pending refused to queue a DIFFERENT category that had failed, so
    # "retry this category" and "run the missing measurements" both silently did
    # nothing while the property had any work in flight.
    targets = CATEGORIES if category is None else (category,)
    target_keys = [f"expanded64_{key}" for key in targets]
    if force and session.execute(text("""
        SELECT 1 FROM fyp.property_enrichment_category
         WHERE property_id=:id AND category IN :categories
           AND coordinate_hash=:hash AND calculation_version=:version
           AND (status='pending' OR (status='running' AND started_at >= now()-interval '5 minutes'))
         LIMIT 1
        """).bindparams(bindparam("categories", expanding=True)),
        {"id": property_id, "categories": target_keys,
         "hash": hash_value, "version": VERSION}).first():
        return False
    queued = False
    for key in targets:
        count = session.execute(text("""
            INSERT INTO fyp.property_enrichment_category
                (property_id, category, phase, status, coordinate_hash, calculation_version)
            VALUES (:id, :category, :phase, 'pending', :hash, :version)
            ON CONFLICT (property_id, category) DO UPDATE
               SET status='pending', coordinate_hash=EXCLUDED.coordinate_hash,
                   calculation_version=EXCLUDED.calculation_version, last_error=NULL,
                   updated_at=now()
             WHERE (fyp.property_enrichment_category.status <> 'running'
                   OR fyp.property_enrichment_category.started_at < now()-interval '5 minutes')
               AND (fyp.property_enrichment_category.coordinate_hash IS DISTINCT FROM :hash
                 OR fyp.property_enrichment_category.calculation_version IS DISTINCT FROM :version
                 OR (:force AND fyp.property_enrichment_category.status <> 'pending'))
            """), {"id": property_id, "category": f"expanded64_{key}",
                  "phase": "population" if key in ("age", "population") else "postgis",
                  "hash": hash_value, "version": VERSION, "force": force}).rowcount
        queued = queued or bool(count)
    if category is None and settings.pu_model_variant == "operational25":
        from sitewise.services.operational25_enrichment import enqueue as enqueue_operational25

        queued = enqueue_operational25(session, property_id, force=force) or queued
    return queued


def outstanding_categories(session: Session, property_id: int, latitude, longitude) -> list[str]:
    """Categories whose stored measurements are not current for these coordinates.

    A category is outstanding when its queue row is missing, failed, stale or
    unavailable, or when it stores fewer values than the model contract
    requires. A stored row alone never counts as complete: the snapshot must be
    fenced by the current coordinate hash and calculation version.
    """
    state = persisted_association(session, property_id, latitude, longitude, read_score=False)
    return [
        name for name, item in state["categories"].items()
        if item["status"] != "current" or item["calculated"] < item["total"]
    ]


def enqueue_outstanding(session: Session, property_id: int, *, full: bool = False) -> dict:
    """Queue only what is missing unless a full recalculation is requested.

    Recovery entry point for listings that already exist. Opening the admin
    review never calls this; an administrator presses the action explicitly.
    """
    row = session.execute(text("""
        SELECT latitude, longitude FROM fyp.rental_properties WHERE id=:id
        """), {"id": property_id}).first()
    if row is None:
        raise LookupError("Property not found")
    if not _valid_coordinates(*row):
        return {"queued": [], "reason": "Property has no valid coordinates to measure."}
    targets = list(CATEGORIES) if full else outstanding_categories(session, property_id, *row)
    if not targets:
        return {"queued": [], "reason": "Every category is already current for these coordinates."}
    queued = [name for name in targets if enqueue(session, property_id, category=name, force=True)]
    if full and settings.pu_model_variant == "operational25":
        from sitewise.services.operational25_enrichment import enqueue as enqueue_operational25

        enqueue_operational25(session, property_id, force=True)
    if queued:
        return {"queued": queued, "reason": None}
    in_flight = any(
        state in ("pending", "running")
        for state in session.execute(text("""
            SELECT status FROM fyp.property_enrichment_category
             WHERE property_id=:id AND category IN :categories
            """).bindparams(bindparam("categories", expanding=True)),
            {"id": property_id, "categories": [f"expanded64_{name}" for name in targets]}).scalars()
    )
    return {
        "queued": [],
        "reason": ("These categories are already queued; results appear when the "
                   "worker finishes." if in_flight
                   else "No category could be queued for these coordinates."),
    }


#: GADM spells some states and districts differently from the DOSM household
#: income survey. Without these aliases the join silently finds no income row
#: and the whole socio-economic block disappears for those areas — 19 of the
#: 144 GADM districts were affected, including every Terengganu district and all
#: three federal territories. The aliases translate the GADM name to the DOSM
#: name; they never invent a district.
_STATE_ALIASES = {
    "trengganu": "Terengganu",
    "kuala lumpur": "W.P. Kuala Lumpur",
    "labuan": "W.P. Labuan",
    "putrajaya": "W.P. Putrajaya",
}
_DISTRICT_ALIASES = {
    "johor baharu": "Johor Bahru",
    "keluang": "Kluang",
    "kulaijaya": "Kulai",
    "ledang": "Tangkak",
    "pasir putih": "Pasir Puteh",
    "larut and matang": "Larut dan Matang",
    "meradong": "Maradong",
    "hulu langat": "Ulu Langat",
    "hulu selangor": "Ulu Selangor",
    # DOSM names a federal territory's district after the territory itself.
    "kuala lumpur": "W.P. Kuala Lumpur",
    "labuan": "W.P. Labuan",
    "putrajaya": "W.P. Putrajaya",
}


def _district_context(analytics: Session, latitude: float, longitude: float) -> dict:
    """DOSM district context for the point: income, expenditure, inequality.

    District-level, not property-level. Every figure is returned only when the
    district could be resolved unambiguously (exactly one containing district);
    an ambiguous district yields an empty block rather than a guess, and a
    district with no income survey row yields the district name with no figures
    rather than a borrowed one. Decimals are converted to float so the block
    survives ``json.dumps`` when it is persisted.
    """
    containing = analytics.execute(text("""
        SELECT DISTINCT name_1 AS state, name_2 AS district
        FROM public.gadm_districts
        WHERE ST_Covers(geom, ST_SetSRID(ST_MakePoint(:lon, :lat), 4326))
        LIMIT 2
    """), {"lat": latitude, "lon": longitude}).mappings().all()
    if len(containing) != 1:
        return {}

    state = _STATE_ALIASES.get(containing[0]["state"].strip().lower(), containing[0]["state"])
    gadm_district = containing[0]["district"]
    names = {gadm_district.lower()}
    if alias := _DISTRICT_ALIASES.get(gadm_district.strip().lower()):
        names.add(alias.lower())

    row = analytics.execute(
        text("""
            SELECT district, income_median, income_mean, expenditure_mean,
                   gini, poverty, date
            FROM public.hh_income_district
            WHERE lower(state)=lower(:state) AND lower(district) IN :names
            ORDER BY date DESC LIMIT 1
        """).bindparams(bindparam("names", expanding=True)),
        {"state": state, "names": sorted(names)},
    ).mappings().first()

    result: dict = {"state": state, "district": (row or {}).get("district") or gadm_district}
    if row is None:
        return result
    numeric = {"income_median", "income_mean", "expenditure_mean", "gini", "poverty"}
    for key, value in dict(row).items():
        if key in ("district",) or value is None:
            continue
        result[key] = str(value) if key == "date" else float(value) if key in numeric else value

    return result


def _calculate(session: Session, category: str, latitude: float, longitude: float) -> dict:
    names = {name for name, group in contract().items() if group == category}
    values, sources, methods, validated, reasons, failures = {}, {}, {}, [], [], []
    context = {}
    model_name = active_expanded_model_name()
    v2 = uses_v2_feature_definitions(model_name)
    if category == "age":
        outcome = PropertyEnrichmentService(session)._age_population(latitude, longitude, {})
        provenance = outcome.provenance or {}
        for name in names:
            value = (outcome.measurement or {}).get(name)
            radius = "500m" if name.endswith("_500m") else "1km"
            if (value is not None and math.isfinite(value) and value >= 0
                    and provenance.get("per_radius", {}).get(radius, {}).get("status") in COVERAGE_STATUSES):
                values[name] = round(value)
                sources[name] = provenance.get("source", "WorldPop age-sex GeoTIFFs")
                methods[name] = provenance.get("method", "Area-weighted age band sums")
                validated.append(name)
        if reason := outcome.error or provenance.get("reason"):
            reasons.append(reason)
    else:
        with Session(analytics_engine) as analytics:
            analytics.connection().exec_driver_sql("SET TRANSACTION READ ONLY")
            # Bound every statement in this transaction. The routing-heavy
            # network category (pgRouting reach + hull + WorldPop overlay)
            # routinely needs 20-45 s on its own and materially longer when
            # several workers share the database; a single 25 s bound for every
            # category cancelled it under normal backfill load and recorded a
            # spurious failure. The light categories keep the tight bound so a
            # runaway query still cannot hold a worker.
            # ``exec_driver_sql`` sends the statement straight to psycopg2, so
            # the placeholder is positional (``%s``) — a named ``:value`` bind
            # is a syntax error there. The value comes from a module constant,
            # never from a request.
            analytics.connection().exec_driver_sql(
                "SELECT set_config('statement_timeout', %s, true)",
                (STATEMENT_TIMEOUTS.get(category, DEFAULT_STATEMENT_TIMEOUT),),
            )
            for key, result in Expanded64CoordinateExtractor(analytics).extract(
                latitude, longitude, selected=set(CATEGORIES[category]),
            ).items():
                if result.reason:
                    # SQL errors can include parameters and query text. Persist a short type only.
                    reason = result.reason.splitlines()[0][:200]
                    reasons.append(reason)
                if result.status == "failed":
                    failures.append(key)
                if result.status not in {"ready", "partial"}:
                    continue
                for name, value in result.values.items():
                    source = result.sources.get(name)
                    if (name not in names or value is None or not math.isfinite(value) or value < 0
                            or (name.endswith("_pct") and value > 100) or not source):
                        continue
                    values[name], sources[name], methods[name] = value, source, MEASUREMENT_METHODS[key]
                    if coordinate_input_validated(
                        key, name, result.notes, model_name=model_name
                    ):
                        validated.append(name)
            if category == "population":
                try:
                    with analytics.begin_nested():
                        context = _district_context(analytics, latitude, longitude)
                except SQLAlchemyError:
                    reasons.append("District income data could not be resolved.")
    return {
        "values": values, "sources": sources, "methods": methods, "validated": validated,
        "district_context": context,
        "model_name": model_name,
        "definition_version": DEFINITIONS_VERSION,
        "feature_definition_versions": {
            name: version for name, version in definition_versions().items() if name in names
        },
        "standardized_features": [
            name for name in STANDARDIZED_V2_FEATURES if name in names
        ],
        "uses_v2_feature_definitions": v2,
        "status": "failed" if failures else "current" if values or context else "unavailable",
        "reason": "; ".join(reasons) or (None if len(values) == len(names) else "Some source measurements were unavailable"),
    }


def run_next(session: Session) -> bool:
    """Claim one category, run it and fence writes with the attempt token."""
    row = session.execute(text("""
        SELECT q.property_id, q.category, q.coordinate_hash, q.calculation_version,
               p.latitude, p.longitude
        FROM fyp.property_enrichment_category q
        JOIN fyp.rental_properties p ON p.id=q.property_id
        WHERE q.category IN :categories
          AND (q.status='pending' OR (q.status='running' AND q.started_at < now()-interval '5 minutes'))
          AND NOT EXISTS (
              SELECT 1 FROM fyp.property_enrichment_category r
              WHERE r.property_id=q.property_id AND (r.category IN :categories OR r.category='operational25')
                AND r.status='running' AND r.started_at >= now()-interval '5 minutes'
          )
        ORDER BY q.updated_at, q.property_id, q.category
        LIMIT 1 FOR UPDATE OF p SKIP LOCKED
        """).bindparams(bindparam("categories", expanding=True)),
        {"categories": JOB_KEYS}).mappings().first()
    if row is None:
        session.rollback()
        return False
    job = dict(row)
    params = {"id": job["property_id"], "category": job["category"], "hash": job["coordinate_hash"]}
    # Another worker may have committed its claim after this SELECT's snapshot.
    active = session.execute(text("""
        SELECT 1 FROM fyp.property_enrichment_category
        WHERE property_id=:id AND (category IN :categories OR category='operational25')
          AND status='running' AND started_at >= now()-interval '5 minutes' LIMIT 1
        """).bindparams(bindparam("categories", expanding=True)),
        params | {"categories": JOB_KEYS}).first()
    if active:
        session.rollback()
        return False
    token = session.execute(text("""
        UPDATE fyp.property_enrichment_category
           SET status='running', attempt_count=attempt_count+1, started_at=now(), updated_at=now()
         WHERE property_id=:id AND category=:category
        RETURNING attempt_count
        """), params).scalar_one()
    session.commit()

    latitude, longitude = job["latitude"], job["longitude"]
    try:
        if not _valid_coordinates(latitude, longitude) or coordinate_hash(
            float(latitude), float(longitude)
        ) != job["coordinate_hash"]:
            result = {"values": {}, "status": "stale", "reason": "Property coordinates changed"}
        else:
            result = _calculate(session, job["category"].removeprefix("expanded64_"),
                                float(latitude), float(longitude))
    except Exception as exc:
        session.rollback()
        result = {"values": {}, "status": "failed", "reason": f"Collection failed ({type(exc).__name__})"}

    listing = session.execute(text("""
        SELECT latitude, longitude FROM fyp.rental_properties WHERE id=:id FOR UPDATE
        """), params).first()
    if listing is None:
        session.rollback()
        return True
    valid = _valid_coordinates(*listing)
    matches = valid and coordinate_hash(*map(float, listing)) == params["hash"]
    if not matches:
        result = {"values": {}, "status": "stale", "reason": "Property coordinates changed"}
    owned = session.execute(text("""
        UPDATE fyp.property_enrichment_category
           SET status=:status, last_error=:reason, completed_at=now(), updated_at=now()
         WHERE property_id=:id AND category=:category AND coordinate_hash=:hash
           AND status='running' AND attempt_count=:token
        """), params | {"token": token, "status": result["status"], "reason": result["reason"]}).rowcount
    if owned and (result["values"] or result.get("district_context")):
        result.update(coordinate_hash=params["hash"], calculation_version=job["calculation_version"])
        session.execute(text("""
            INSERT INTO fyp.property_geospatial_features (property_id, expanded64_measurements, last_calculated_at)
            VALUES (:id, jsonb_build_object(:category, CAST(:payload AS jsonb) ||
                    jsonb_build_object('calculated_at', now())), now())
            ON CONFLICT (property_id) DO UPDATE SET
                expanded64_measurements = jsonb_set(
                    coalesce(fyp.property_geospatial_features.expanded64_measurements, '{}'::jsonb),
                    ARRAY[CAST(:category AS text)],
                    CASE WHEN fyp.property_geospatial_features.expanded64_measurements -> :category ->> 'coordinate_hash' = :hash
                         AND fyp.property_geospatial_features.expanded64_measurements -> :category ->> 'calculation_version' = :version
                    THEN CAST(:payload AS jsonb) || jsonb_build_object(
                        'values', (fyp.property_geospatial_features.expanded64_measurements -> :category -> 'values')
                             || (CAST(:payload AS jsonb) -> 'values'),
                        'sources', (fyp.property_geospatial_features.expanded64_measurements -> :category -> 'sources')
                             || (CAST(:payload AS jsonb) -> 'sources'),
                        'methods', (fyp.property_geospatial_features.expanded64_measurements -> :category -> 'methods')
                             || (CAST(:payload AS jsonb) -> 'methods'),
                        'district_context', COALESCE(NULLIF(CAST(:payload AS jsonb) -> 'district_context', '{}'::jsonb),
                            fyp.property_geospatial_features.expanded64_measurements -> :category -> 'district_context'),
                        'calculated_at', now())
                    ELSE CAST(:payload AS jsonb) || jsonb_build_object('calculated_at', now()) END),
                last_calculated_at=now()
            """), params | {"payload": json.dumps(result, allow_nan=False), "version": job["calculation_version"]})
    if owned and valid and not matches:
        enqueue(session, job["property_id"])
    session.commit()
    if owned and matches and settings.pu_model_variant == "expanded64":
        try:
            _save_expanded_prediction(session, job["property_id"], *listing)
        except Exception as exc:
            session.rollback()
            logger.warning("Expanded64 prediction failed (%s)", type(exc).__name__)
    return True


@lru_cache(maxsize=4)
def _artifact_digest(path, mtime_ns, size):
    with open(path, "rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def _model_digest() -> str:
    path = ModelLoader()._find_artifact(active_expanded_model_name())
    stat = path.stat()
    return _artifact_digest(path, stat.st_mtime_ns, stat.st_size)


def _vector_digest(vector: dict) -> str:
    return hashlib.sha256(json.dumps(vector, sort_keys=True, allow_nan=False).encode()).hexdigest()


def explain_prediction(model, variant, vector, imputable, score):
    from sitewise.ml.shap_explainer import ShapExplainer
    from sitewise.services.property_insights_service import _background_path, _reference_background_rows

    background = _reference_background_rows(list(vector), _background_path(variant))
    explanation = ShapExplainer(model_name=model).explain(
        vector, background=background, allowed_missing=frozenset(imputable),
    )
    reconstructed = explanation["baseline_association"] + math.fsum(explanation["contributions"].values())
    if not (math.isclose(reconstructed, score, abs_tol=1e-6)
            and math.isclose(explanation["positive_label_association"], score, abs_tol=1e-9)):
        raise ValueError("Explanation does not reconcile with the persisted score")
    return explanation


def _save_expanded_prediction(session: Session, property_id: int, latitude, longitude) -> None:
    current = persisted_association(session, property_id, latitude, longitude, read_score=False)
    vector = current.pop("_validated_vector")
    if current["calculation_status"] in ("running", "pending") or current["_required_missing"]:
        return
    digest = _vector_digest(vector)
    model_name = active_expanded_model_name()
    hashed = coordinate_hash(float(latitude), float(longitude))
    # Release the read transaction before running inference and SHAP.
    session.rollback()
    try:
        prediction = _score_property(
            str(property_id), vector, missing=current["missing_features"], model_name=model_name
        )
    except Exception as exc:
        prediction = {"available": False, "reason": f"Model unavailable ({type(exc).__name__})"}
    payload = {key: prediction.get(key) for key in ("score", "label", "score_meaning", "model_version")}
    payload.update(available=bool(prediction.get("available")), variant="expanded64",
                   model_name=model_name, definition_version=DEFINITIONS_VERSION,
                   coordinate_hash=hashed, calculation_version=VERSION,
                   feature_digest=digest, model_sha256=_model_digest())
    if payload["available"]:
        try:
            payload["explanation"] = explain_prediction(model_name, "expanded64", vector,
                                                        current["imputable_features"], prediction["score"])
        except Exception as exc:
            payload["explanation_unavailable_reason"] = f"SHAP unavailable ({type(exc).__name__})"
    else:
        payload["unavailable_reason"] = prediction.get("reason") or "The configured model could not score this vector."
    coordinates = session.execute(text("""
        SELECT latitude, longitude FROM fyp.rental_properties WHERE id=:id FOR UPDATE
    """), {"id": property_id}).first()
    if not coordinates or not _valid_coordinates(*coordinates) or coordinate_hash(*map(float, coordinates)) != hashed:
        session.rollback()
        return
    latest = persisted_association(session, property_id, *coordinates, read_score=False)
    if latest["calculation_status"] not in ("running", "pending") and _vector_digest(latest["_validated_vector"]) == digest:
        session.execute(text("""
            UPDATE fyp.property_geospatial_features
            SET pu_inference_snapshot=jsonb_set(COALESCE(pu_inference_snapshot, '{}'::jsonb),
                '{expanded64}', CAST(:payload AS jsonb) || jsonb_build_object('calculated_at', now()))
            WHERE property_id=:id
        """), {"id": property_id, "payload": json.dumps(payload, allow_nan=False)})
    session.commit()


def persisted_association(session: Session, property_id: int, latitude, longitude, *, read_score: bool = True) -> dict:
    features = contract()
    hash_value = coordinate_hash(float(latitude), float(longitude)) if _valid_coordinates(latitude, longitude) else None
    schema_unavailable = False
    predictions = {}
    try:
        with session.begin_nested():
            row = session.execute(text("""
                SELECT expanded64_measurements, pu_inference_snapshot
                FROM fyp.property_geospatial_features WHERE property_id=:id
                """), {"id": property_id}).first()
            stored = (row[0] or {}) if row else {}
            predictions = (row[1] or {}) if row else {}
            jobs = {r["category"]: dict(r) for r in session.execute(text("""
                SELECT category, status, coordinate_hash, calculation_version, last_error
                FROM fyp.property_enrichment_category WHERE property_id=:id
                """), {"id": property_id}).mappings()}
    except SQLAlchemyError:
        stored, jobs, schema_unavailable = {}, {}, True

    values, sources, methods, validated, categories, feature_states = {}, {}, {}, {}, {}, {}
    for category in CATEGORIES:
        key = f"expanded64_{category}"
        names = [name for name, group in features.items() if group == category]
        snapshot, job = stored.get(key, {}), jobs.get(key, {})
        current = bool(hash_value and snapshot.get("coordinate_hash") == hash_value
                       and snapshot.get("calculation_version") == VERSION)
        # A stored row alone never counts as complete: the snapshot must be
        # fenced by the current coordinate hash and calculation version.
        status = job.get("status") if job else ("current" if current else "not_calculated")
        if hash_value is None or schema_unavailable:
            status = "unavailable"
        elif job and (job["coordinate_hash"] != hash_value or job["calculation_version"] != VERSION):
            status = "stale"
        measured = {name: snapshot["values"][name] for name in names
                    if current and name in snapshot.get("values", {})}
        permitted = {name: val for name, val in measured.items()
                     if status == "current" and name in snapshot.get("validated", ())}
        values.update(measured)
        validated.update(permitted)
        sources.update({n: snapshot["sources"][n] for n in measured})
        methods.update({
            name: MEASUREMENT_METHODS.get(method, method)
            for name in measured if (method := snapshot.get("methods", {}).get(name))
        })
        feature_states.update({
            name: ("validated" if name in permitted else "calculated_unvalidated" if name in measured
                   else "unavailable" if status == "current" else status)
            for name in names
        })
        categories[category] = {
            "status": status, "calculated": len(measured), "validated": len(permitted),
            "total": len(names), "last_success_at": snapshot.get("calculated_at"),
            "reason": ("Property has no valid coordinates" if hash_value is None else
                       "Apply the Expanded64 enrichment migration" if schema_unavailable else
                       "Property coordinates or calculation version changed" if status == "stale" else
                       job.get("last_error") or (snapshot.get("reason") if current else None)
                       or ("Not calculated yet. Run location analysis to measure this category."
                           if status == "not_calculated" else None)),
        }
    missing = [name for name in features if name not in validated]
    imputable, required = expanded_policy_split(missing)
    statuses = {item["status"] for item in categories.values()}
    overall = next((state for state in ("running", "pending", "failed", "stale", "unavailable", "not_calculated")
                    if state in statuses), "current")
    active_model = active_expanded_model_name()
    result = {"available": False, "score": None, "model_version": active_model,
              "model_name": active_model,
              "definition_version": DEFINITIONS_VERSION,
              "feature_definition_versions": definition_versions(),
              "standardized_features": STANDARDIZED_V2_FEATURES,
              "uses_v2_feature_definitions": uses_v2_feature_definitions(active_model),
              "feature_count": len(features), "available_features": len(validated),
              "calculated_features": len(values), "feature_values": values, "feature_sources": sources,
              "feature_methods": methods, "feature_states": feature_states,
              "feature_order": list(features), "categories": categories, "calculation_status": overall,
              "has_coordinates": hash_value is not None, "missing_features": missing,
              "unvalidated_features": [name for name in values if name not in validated],
              "imputable_features": imputable, "unavailable_reason": f"{len(required)} required inputs await validation.",
              "research_only": True}
    vector = {name: validated.get(name) for name in features}
    context = stored.get("expanded64_population") or {}
    if context.get("coordinate_hash") == hash_value and context.get("calculation_version") == VERSION:
        result["district_context"] = context.get("district_context") or {}
    if not read_score:
        return result | {"_validated_vector": vector, "_required_missing": required}
    variant = settings.pu_model_variant
    result["model_variant"] = variant
    result["model_feature_count"] = len(features) if variant == "expanded64" else None
    result["model_available_features"] = len(validated) if variant == "expanded64" else None
    if variant == "expanded64":
        score = predictions.get("expanded64") or {}
        if (not required and overall not in ("pending", "running")
                and score.get("coordinate_hash") == hash_value
                and score.get("calculation_version") == VERSION
                and score.get("model_sha256") == _model_digest()
                and score.get("feature_digest") == _vector_digest(vector)):
            result.update(score)
        elif not required:
            result["unavailable_reason"] = "The current vector has no persisted prediction yet."
            if not score and overall not in ("pending", "running"):
                result["prediction_pending"] = True
    elif variant == "operational25":
        from sitewise.services.operational25_enrichment import persisted

        if not schema_unavailable:
            try:
                with session.begin_nested():
                    prediction = persisted(session, property_id, latitude, longitude)
            except SQLAlchemyError:
                prediction = {}
            if prediction.get("queue_status") in ("pending", "running"):
                result["calculation_status"] = prediction["queue_status"]
            coverage = prediction.get("feature_coverage") or {}
            result["model_feature_count"] = 25
            result["model_available_features"] = coverage.get("validated")
            if prediction.get("available"):
                result.update(available=True, score=prediction["pu_score"],
                              model_version=prediction["model_version"],
                              score_meaning="Association with positive examples in the PU training data.",
                              explanation=prediction.get("explanation"),
                              explanation_unavailable_reason=prediction.get("explanation_unavailable_reason"))
            else:
                result["unavailable_reason"] = "A current Operational25 prediction is unavailable."
    else:
        result["unavailable_reason"] = "The configured model has no verified current-coordinate contract for this property."
    return result


#: Keys of :func:`persisted_association` that describe *measurements only*.
#: Deliberately excludes ``score``, ``label``, ``explanation`` and every other
#: inference field: informational availability must never be able to leak a
#: machine-learning result, and a machine-learning outage must never be able to
#: hide a measurement that was successfully calculated.
INFORMATIONAL_KEYS = (
    "feature_values", "feature_sources", "feature_methods", "feature_states",
    "feature_order", "categories", "feature_count", "calculated_features",
    "available_features", "unvalidated_features", "missing_features",
    "calculation_status", "has_coordinates", "district_context",
    "definition_version", "feature_definition_versions", "standardized_features",
    "uses_v2_feature_definitions", "model_name", "research_only",
)


def informational_measurements(
    session: Session, property_id: int, latitude, longitude, *,
    address_validation_status: str | None = None,
) -> dict:
    """Measured surroundings for one property, with no inference payload.

    This is the projection Location Intelligence renders. It returns every
    value that was successfully calculated — including the categories whose
    definitions are not yet approved as model inputs, which appear as
    ``calculated_unvalidated``. A category that could not be measured is
    reported with its own state and reason; it never becomes a zero and never
    suppresses the categories that did succeed.

    ``available`` is true when at least one measurement exists, not when the
    full 64-feature contract is satisfied.
    """
    state = persisted_association(session, property_id, latitude, longitude, read_score=False)
    payload = {key: state[key] for key in INFORMATIONAL_KEYS if key in state}
    payload["property_id"] = property_id
    payload["available"] = bool(state.get("calculated_features"))
    payload["address_validation_status"] = address_validation_status
    return payload


def enqueue_all_missing(session: Session, *, limit: int | None = None) -> dict:
    """Queue the measurement categories that are not current for every listing.

    Recovery entry point for the properties that already existed before the
    informational pipeline was reachable. Only valid coordinates are required;
    the address verdict is not consulted, for the same reason it is not
    consulted when a listing is created. A listing whose categories are already
    current for these coordinates is skipped by the existing conflict clause,
    so running this twice is harmless.
    """
    rows = session.execute(text("""
        SELECT id, latitude, longitude FROM fyp.rental_properties
        WHERE latitude IS NOT NULL AND longitude IS NOT NULL
          AND latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180
        ORDER BY id
        """ + (" LIMIT :limit" if limit is not None else "")),
        ({"limit": limit} if limit is not None else {}),
    ).all()
    queued, unchanged, failed = [], 0, []
    for property_id, latitude, longitude in rows:
        try:
            with session.begin_nested():
                if enqueue(session, int(property_id)):
                    queued.append(int(property_id))
                else:
                    unchanged += 1
        except Exception as exc:  # one bad listing must not stop the sweep
            failed.append({"property_id": int(property_id), "error": type(exc).__name__})
    return {
        "candidates": len(rows), "queued": queued, "queued_count": len(queued),
        "already_current": unchanged, "failed": failed,
        "calculation_version": VERSION,
    }
