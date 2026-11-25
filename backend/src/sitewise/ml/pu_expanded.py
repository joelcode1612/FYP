"""Expanded 64-feature PU model: bridge, policy and live inference.

The 2026-11-15 expanded package adds 12 WorldPop Malaysia 2025
population-age counts and 8 OSM residential density/coverage measurements to
the 44-feature baseline (the original 47 minus the three LandScan fields,
excluded for licence-provenance reasons). Verified 2026-11-15 against this
deployment:

* The analytics database holds NO population-age values at all (the
  ``pop_age_*`` columns of ``fyp_features.property_population_spatial`` are
  unpopulated and ``local_age_raster_status`` records
  ``SOURCE_NOT_AVAILABLE``).
* The residential columns the database does hold were produced with a
  DIFFERENT method than the model's training values (e.g. MD-00510: DB
  ``residential_building_count_500m``=323 vs training 340.0; MD-04816: 468 vs
  241.0). Silently substituting them would score the model on measurements it
  never learned from, so they are never mapped.
* Four of the six database age bands use different definitions than the
  model's bands (DB ``35_54``/``55_64``/``65plus`` vs model
  ``35_49``/``50_64``/``65_plus``). Different bands are NOT equivalents.

Catalogue inference retains the committed training-data bridge for historical
research. Operational inference collects measurements from current coordinates
and admits only definitions whose live implementation has been validated.
The frozen preprocessor may impute the eight residential inputs; every other
feature must be observed.

Everything here is research-only: the score is an uncalibrated P-vs-U
association index (mean spatial-holdout ROC-AUC 0.699824 on the 1,796-row
research sample), NOT a probability of commercial success.
"""
from __future__ import annotations

import csv
import math
import threading
from time import monotonic
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any

from sqlalchemy import text as sql_text
from sqlalchemy.exc import SQLAlchemyError
from sqlmodel import Session

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.core.logging import logger
from sitewise.ml.expanded64_feature_definitions import DEFINITIONS_VERSION as DEFINITION_VERSION
from sitewise.ml.feature_bridge import FeatureCoverage, bridge_row_for, merge_bridge_features
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.property_features import (
    FeatureResolutionError,
    PropertyFeatureBundle,
    PropertyFeatureRepository,
)
from sitewise.ml.pu_learning import PULearning

EXPANDED_MODEL_NAME = "sitewise_pu_64_expanded"
EXPANDED64_V2_MODEL_NAME = "Expanded64_v2"
EXPANDED_COORDINATE_VERSION = "expanded64-coordinate-v2"

#: The six inputs standardised for the independent Expanded64_v2 retraining.
#: They are measured for every property today, but are admitted to the scoring
#: vector only when the validated v2 artifact is active. The original artifact
#: was trained on the older definitions and must never receive them.
STANDARDIZED_V2_FEATURES = (
    "road_length_density_500m_km_km2",
    "osm_walkway_length_density_500m_km_km2",
    "pop_2000m",
    "pop_3000m",
    "walk_isochrone_area_10min_km2",
    "worldpop_walk_reachable_10min",
)

EXPANDED_BRIDGE_CSV = (
    Path(__file__).resolve().parents[3] / "ml_reference" / "training_expanded_bridge_1796.csv"
)

#: The 20 features the expanded package adds (12 age + 8 residential). The
#: model contract is 64 = 44 baseline + these 20 - 0... minus nothing: the
#: three LandScan fields were REMOVED from the baseline, so 44 + 20 = 64.
EXPANDED_BRIDGE_FEATURES: tuple[str, ...] = (
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

#: The artifact's own prediction utility (predict_expanded_pu.py) allows ONLY
#: these features to be missing (handled by the saved median imputer with
#: missingness indicators). Everything else must be observed.
IMPUTABLE_FEATURES = frozenset(n for n in EXPANDED_BRIDGE_FEATURES if n.startswith("residential_"))


@dataclass(frozen=True)
class ExpandedBridgeRow:
    subject_id: str
    canonical_property_id: str
    sample_class: str
    values: dict[str, float]
    age_data_status: str
    age_data_source_year: str


@lru_cache(maxsize=1)
def _load_expanded_bridge() -> dict[str, ExpandedBridgeRow]:
    if not EXPANDED_BRIDGE_CSV.is_file():
        raise FileNotFoundError(
            f"Expanded training bridge is missing: {EXPANDED_BRIDGE_CSV}"
        )
    by_key: dict[str, ExpandedBridgeRow] = {}
    with EXPANDED_BRIDGE_CSV.open(encoding="utf-8", newline="") as fp:
        for row in csv.DictReader(fp):
            subject = (row.get("subject_id") or "").strip()
            canonical = (row.get("canonical_property_id") or "").strip()
            values: dict[str, float] = {}
            for name in EXPANDED_BRIDGE_FEATURES:
                raw = (row.get(name) or "").strip()
                if raw:
                    values[name] = float(raw)
            bridge = ExpandedBridgeRow(
                subject_id=subject,
                canonical_property_id=canonical,
                sample_class=(row.get("sample_class") or "").strip().upper(),
                values=values,
                age_data_status=(row.get("age_data_status") or "").strip(),
                age_data_source_year=(row.get("age_data_source_year") or "").strip(),
            )
            if canonical:
                by_key.setdefault(f"catalog:{canonical}", bridge)
            if subject:
                by_key.setdefault(f"subject:{subject}", bridge)
    return by_key


def expanded_bridge_row_for(property_id: str, subject_id: str | None) -> ExpandedBridgeRow | None:
    """Look up one expanded training record by catalogue id, then subject id."""
    index = _load_expanded_bridge()
    hit = index.get(f"catalog:{property_id}")
    if hit is None and subject_id:
        hit = index.get(f"subject:{subject_id}")
    return hit


def merge_expanded_bridge_features(
    coverage: FeatureCoverage,
    *,
    expected_features: list[str],
) -> FeatureCoverage:
    """Add the 16 DB-absent measurements from the committed training data.

    The database (and the 47-feature bridge) result wins for features it
    resolved; the expanded bridge supplies only the new columns. Population-age
    coverage flags from the training export are preserved as data-quality
    flags — the age raster is incomplete for some locations and the UI must be
    able to say so.
    """
    row = expanded_bridge_row_for(coverage.property_id, coverage.subject_id)
    values: dict[str, float | None] = dict(coverage.values)
    sources: dict[str, str] = dict(coverage.sources)
    flags: list[str] = list(coverage.flags)

    if row is None:
        missing_new = [
            name for name in expected_features
            if name in EXPANDED_BRIDGE_FEATURES and values.get(name) is None
        ]
        if missing_new:
            flags.append(
                "No expanded-training record for this property; the 2026-11-15 "
                "population-age and residential measurements stay unresolved "
                f"({len(missing_new)} of {len(EXPANDED_BRIDGE_FEATURES)} new features)"
            )
    else:
        for name in EXPANDED_BRIDGE_FEATURES:
            if name in expected_features and values.get(name) is None and name in row.values:
                values[name] = row.values[name]
                sources[name] = (
                    "ml_reference/training_expanded_bridge_1796.csv (original "
                    f"training record, subject {row.subject_id})"
                )
        if row.age_data_status and row.age_data_status != "COMPLETED":
            flags.append(
                f"WorldPop age raster coverage for this location: {row.age_data_status}"
            )
        if row.age_data_source_year:
            flags.append(f"Population-age source year: {row.age_data_source_year}")

    missing = [name for name in expected_features if values.get(name) is None]
    return FeatureCoverage(
        property_id=coverage.property_id,
        subject_id=coverage.subject_id,
        values=values,
        sources=sources,
        missing_features=missing,
        unrecoverable_features=list(coverage.unrecoverable_features),
        flags=sorted(set(flags)),
    )


def expanded_policy_split(missing: list[str]) -> tuple[list[str], list[str]]:
    """Split unresolved features into (imputable, required-missing).

    The saved imputer supports ONLY the residential measurements (that is the
    exact contract of the training package's prediction utility). Population,
    accessibility and competition features can never be imputed.
    """
    imputable = [name for name in missing if name in IMPUTABLE_FEATURES]
    required = [name for name in missing if name not in IMPUTABLE_FEATURES]
    return imputable, required


def _expanded_policy_check(missing: list[str]) -> None:
    """Fail closed when anything other than a residential value is missing."""
    _, required = expanded_policy_split(missing)
    if required:
        raise ModelUnavailableError(
            "Observed non-residential features are required by the expanded "
            f"model contract: {required}"
        )


#: Cache of per-property expanded results, keyed by (model_version, property_id).
_SCORE_CACHE: dict[tuple[str, str], tuple[float, dict[str, Any]]] = {}
_SCORE_CACHE_TTL = 30.0


def _cached_score(key: tuple[str, str]) -> dict[str, Any] | None:
    """Read a score while holding the score-cache lock."""
    entry = _SCORE_CACHE.get(key)
    if entry is None:
        return None
    expires_at, score = entry
    if monotonic() >= expires_at:
        _SCORE_CACHE.pop(key, None)
        return None
    return score
_SCORE_CACHE_LOCK = threading.Lock()

#: The RESOLVED vector behind each cached score. Stage 2 needs it: a cached
#: score must still be able to refill ``coverage_sink``, otherwise a second
#: ranking with different criteria loses its category evidence entirely.
_COVERAGE_CACHE: dict[tuple[str, str], dict[str, Any]] = {}
_COVERAGE_CACHE_LOCK = threading.Lock()


def clear_expanded_cache() -> int:
    """Test/admin hook: drop the expanded64 score cache."""
    with _SCORE_CACHE_LOCK:
        count = len(_SCORE_CACHE)
        _SCORE_CACHE.clear()
    with _COVERAGE_CACHE_LOCK:
        _COVERAGE_CACHE.clear()
    return count


def _score_property(
    property_id: str,
    features: dict[str, float | None],
    *,
    missing: list[str],
    model_name: str = EXPANDED_MODEL_NAME,
) -> dict[str, Any]:
    """Run the active expanded artifact over one resolved vector (shared by 1 and N)."""
    _expanded_policy_check(missing)
    observed = {name: value for name, value in features.items() if value is not None}
    result = PULearning(model_name=model_name).predict_or_report(
        property_id, observed, allow_model_imputation=True
    )
    result["feature_coverage"] = {
        "feature_count": 64,
        "available_features": len(observed),
        "complete": not missing,
        "missing_features": list(missing),
        "imputed_features": list(missing),
    }
    result["inference_state"] = "ready" if result.get("available") else "expanded64_inference_unavailable"
    result["layer1_model"] = model_name
    result["gating"] = {
        "production_ready": False,
        "research_only": True,
        "expanded_bridge_only": True,
    }
    return result


# None denotes a group whose names are all eligible under its coverage rules.
# This is the ORIGINAL Expanded64 contract; it stays unchanged while that
# artifact is the active model.
VALIDATED_COORDINATE_INPUTS = {
    "population_rings": {"pop_500m", "pop_1000m"},
    "road_geometry": {"road_length_density_1km_km_km2"},
    "transit_accessibility": {"transit_stops_500m_walk", "transit_stops_1km_walk"},
    "drive_isochrone": {"drive_isochrone_area_10min_km2"},
    "demand_generator_pois": None,
    "residential_density": None,
}

#: The v2 contract adds the six standardised inputs. ChatGPT must recalculate
#: the historical training features with the same definitions (see
#: deliverables/expanded64_v2_runtime_feature_handoff.md) before these become
#: safe to score against Expanded64_v2.
VALIDATED_COORDINATE_INPUTS_V2 = {
    **VALIDATED_COORDINATE_INPUTS,
    "population_rings": {"pop_500m", "pop_1000m", "pop_2000m", "pop_3000m"},
    "road_geometry": {
        "road_length_density_1km_km_km2",
        "road_length_density_500m_km_km2",
        "osm_walkway_length_density_500m_km_km2",
    },
    "isochrone_population": {
        "walk_isochrone_area_10min_km2", "worldpop_walk_reachable_10min",
    },
}


def active_expanded_model_name() -> str:
    """Return the artifact the single existing Expanded64 engine must load.

    The original production artifact remains active by default. The v2 name
    is used only when explicitly configured and its validated artifact is on
    disk, so a partially delivered retraining cannot change live scoring.
    """
    from sitewise.core.config import settings

    configured = str(
        getattr(settings, "sitewise_expanded64_v2_model_name", "") or ""
    ).strip()
    if not configured:
        return EXPANDED_MODEL_NAME
    if configured != EXPANDED64_V2_MODEL_NAME:
        raise ModelUnavailableError(
            "SITEWISE_EXPANDED64_V2_MODEL_NAME may only name the validated "
            f"artifact {EXPANDED64_V2_MODEL_NAME!r}, got {configured!r}"
        )
    try:
        ModelLoader()._find_artifact(configured)
    except ModelUnavailableError:
        logger.warning(
            "Expanded64_v2 is configured but its artifact is not present; "
            "keeping the original Expanded64 artifact active"
        )
        return EXPANDED_MODEL_NAME
    return configured


def uses_v2_feature_definitions(model_name: str | None = None) -> bool:
    """Whether the named artifact was trained on the standardised definitions."""
    return (model_name or active_expanded_model_name()) == EXPANDED64_V2_MODEL_NAME


def _v2_coverage_guard(group: str, name: str, notes: dict) -> bool:
    """Explicit source-coverage check for the six recovered v2 inputs.

    A missing raster, an empty buffer or a non-polygonal hull leaves the value
    unvalidated; it is never replaced with zero.
    """
    from sitewise.ml.expanded64_feature_definitions import DEFINITIONS_VERSION

    if notes.get("definition_version") not in (None, DEFINITIONS_VERSION):
        return False
    if group == "population_rings" and name in ("pop_2000m", "pop_3000m"):
        pixels = notes.get(f"worldpop_valid_pixels_{name.removeprefix('pop_')}")
        return isinstance(pixels, int) and pixels > 0
    if group == "road_geometry" and name in STANDARDIZED_V2_FEATURES:
        measured = {
            "road_length_density_500m_km_km2": "road_m_500",
            "osm_walkway_length_density_500m_km_km2": "walkway_m_500",
        }.get(name)
        return bool(
            measured
            and notes.get("definition_version") == DEFINITIONS_VERSION
            and isinstance(notes.get(measured), (int, float))
        )
    if group == "isochrone_population" and name in STANDARDIZED_V2_FEATURES:
        nodes = notes.get("hull_nodes_10min", notes.get("nodes"))
        if not isinstance(nodes, int) or nodes < 3:
            return False
        if name == "worldpop_walk_reachable_10min":
            coverage = notes.get("worldpop_hull_coverage_pct")
            return isinstance(coverage, (int, float)) and coverage > 0
        return True
    return True


def coordinate_input_validated(
    group: str, name: str, notes: dict, *, model_name: str | None = None
) -> bool:
    """Admit a measured input to a scoring vector.

    ``model_name=None`` deliberately keeps the original Expand64 allowlist so
    existing callers and tests never silently receive newly standardised
    values. Runtime paths pass the active artifact explicitly.
    """
    active = model_name or EXPANDED_MODEL_NAME
    v2 = uses_v2_feature_definitions(active)
    allowed = VALIDATED_COORDINATE_INPUTS_V2 if v2 else VALIDATED_COORDINATE_INPUTS
    if group not in allowed:
        return False
    eligible = allowed[group]
    if not (eligible is None or name in eligible):
        return False
    if group == "transit_accessibility" and not bool(notes.get("gtfs_coordinate_covered")):
        return False
    if v2 and not _v2_coverage_guard(group, name, notes):
        return False
    return True


def collect_expanded_coordinates(
    session: Session,
    latitude: float,
    longitude: float,
    *,
    property_id: str = "coordinates",
    diagnostics: bool = False,
    age_raster_dir: str | None = None,
    explain: bool = False,
) -> dict[str, Any]:
    """Collect model inputs from current coordinates and report rejected candidates."""
    from sitewise.ml.coordinate_features import (
        GROUP_ISO, STATUS_PARTIAL, STATUS_READY,
    )
    from sitewise.ml.expanded64_network import Expanded64CoordinateExtractor
    from sitewise.services.age_band_raster_service import (
        COVERAGE_STATUSES, SOURCE_NAME, SOURCE_YEAR, AgeBandRasterService,
    )
    from sitewise.services.property_enrichment_service import (
        _age_band_service, _valid_coordinates, coordinate_hash,
    )

    if not _valid_coordinates(latitude, longitude):
        raise FeatureResolutionError("Property needs finite latitude and longitude in range")
    latitude, longitude = float(latitude), float(longitude)
    model_name = active_expanded_model_name()
    loaded = ModelLoader().load_cached(model_name)
    values = dict.fromkeys(loaded.feature_names)
    sources = {}
    candidates = {}
    eligible_groups = set(
        VALIDATED_COORDINATE_INPUTS_V2
        if uses_v2_feature_definitions(model_name)
        else VALIDATED_COORDINATE_INPUTS
    ) | ({GROUP_ISO} if uses_v2_feature_definitions(model_name) else set())
    groups = Expanded64CoordinateExtractor(session).extract(
        latitude, longitude, selected=None if diagnostics else eligible_groups
    )
    for group, observation in groups.items():
        for name, value in observation.values.items():
            if name not in values or value is None or not math.isfinite(value) or value < 0:
                continue
            if name.endswith("_pct") and value > 100:
                continue
            if observation.status not in {STATUS_READY, STATUS_PARTIAL}:
                continue
            if (
                not coordinate_input_validated(
                    group, name, observation.notes, model_name=model_name
                )
            ):
                candidates[name] = value
                continue
            if source := observation.sources.get(name):
                values[name] = value
                sources[name] = source

    age_service = (
        AgeBandRasterService(age_raster_dir) if age_raster_dir is not None else _age_band_service()
    )
    age_result = {"status": "unavailable", "reason": "", "source": SOURCE_NAME, "source_year": SOURCE_YEAR}
    try:
        available, reason = age_service.availability()
        age_result["reason"] = "" if available else reason
        if available:
            observation = age_service.extract(latitude, longitude)
            age_result.update(observation)
            for radius, radius_result in observation.get("radii", {}).items():
                if radius_result["status"] not in COVERAGE_STATUSES:
                    continue
                for group, value in radius_result.get("groups", {}).items():
                    name = f"{group}_{radius}"
                    if name in values and value is not None and math.isfinite(value) and value >= 0:
                        values[name] = float(round(value))
                        sources[name] = SOURCE_NAME
    except Exception as exc:
        age_result.update(status="failed", reason=f"WorldPop age extraction failed: {type(exc).__name__}")
    finally:
        if age_raster_dir is not None:
            age_service.close()

    missing = [name for name, value in values.items() if value is None]
    imputable, required = expanded_policy_split(missing)
    result = {
        "property_id": property_id,
        "available": False,
        "score": None,
        "model_version": loaded.meta.get("model_variant") or model_name,
        "layer1_model": model_name,
        "uses_v2_feature_definitions": uses_v2_feature_definitions(model_name),
        "standardized_features": STANDARDIZED_V2_FEATURES,
        "definition_version": DEFINITION_VERSION,
        "research_only": True,
        "feature_count": len(values),
        "available_features": len(sources),
        "missing_features": missing,
        "missing_required_features": required,
        "imputable_features": imputable,
        "unvalidated_features": list(candidates),
        "unvalidated_values": candidates,
        "values": values,
        "value_sources": sources,
        "coordinates": {"latitude": latitude, "longitude": longitude},
        "coordinate_hash": coordinate_hash(latitude, longitude),
        "calculation_version": EXPANDED_COORDINATE_VERSION,
        "groups": {name: group.as_dict() for name, group in groups.items()},
        "age": age_result,
    }
    if required:
        result["reason"] = (
            f"Expanded64 requires {len(required)} additional validated current-coordinate inputs."
        )
        return result

    result.update(_score_property(property_id, values, missing=missing, model_name=model_name))
    result["gating"]["expanded_bridge_only"] = False
    if explain and result["available"]:
        from sitewise.ml.shap_explainer import ShapExplainer
        from sitewise.services.property_insights_service import (
            _background_path, _reference_background_rows,
        )

        background = _reference_background_rows(
            loaded.feature_names, _background_path("expanded64")
        )
        try:
            explanation = ShapExplainer(model_name=model_name).explain(
                values, background=background, allowed_missing=frozenset(imputable)
            )
            reconstructed = explanation["baseline_association"] + math.fsum(
                explanation["contributions"].values()
            )
            if not (
                math.isclose(reconstructed, result["score"], abs_tol=1e-6)
                and math.isclose(explanation["positive_label_association"], result["score"], abs_tol=1e-9)
            ):
                raise ModelUnavailableError("SHAP did not reconcile with the expanded64 score")
        except ModelUnavailableError as exc:
            result["explanation_unavailable_reason"] = str(exc)
        else:
            result["explanation"] = explanation
    return result


def expanded_rental_prediction(
    session: Session, property_id: int, **collection_options: Any
) -> dict[str, Any]:
    """Resolve the current listing location without using the historical bridge."""
    row = session.execute(sql_text(
        "SELECT latitude, longitude FROM fyp.rental_properties WHERE id = :property_id"
    ), {"property_id": property_id}).one_or_none()
    if row is None:
        raise FeatureResolutionError("Rental property does not exist")
    return collect_expanded_coordinates(
        session, row.latitude, row.longitude, property_id=str(property_id), **collection_options
    )


def expanded_prediction(analytics_session: Session, property_id: str) -> dict[str, Any]:
    """Score ONE catalogue property with the expanded 64-feature model.

    Same contract as :func:`sitewise.ml.pu_variant.experimental_prediction`:
    failures are explicit (``available: false`` names the exact missing
    features) and successful results are cached per (model version, property).
    """
    model_name = active_expanded_model_name()
    loaded = ModelLoader().load_cached(model_name)
    model_version = str(loaded.meta.get("model_variant") or "unknown")
    cache_key = (model_version, str(property_id))
    with _SCORE_CACHE_LOCK:
        cached = _cached_score(cache_key)
    if cached is not None:
        return cached

    try:
        bundle: PropertyFeatureBundle = PropertyFeatureRepository(analytics_session).get(
            str(property_id), loaded.feature_names, source="catalog"
        )
        coverage = merge_bridge_features(bundle, expected_features=loaded.feature_names)
        coverage = merge_expanded_bridge_features(coverage, expected_features=loaded.feature_names)
    except FeatureResolutionError as exc:
        result = {
            "property_id": str(property_id),
            "available": False,
            "score": None,
            "reason": f"feature_resolution_failed: {exc}",
            "score_meaning": "research_positive_label_association_NOT_business_success_probability",
            "research_only": True,
            "inference_state": "expanded64_inference_unavailable",
            "layer1_model": model_name,
            "feature_coverage": {
                "feature_count": 64,
                "available_features": 0,
                "complete": False,
                "missing_features": [f"feature_resolution_failed: {exc}"],
            },
            "gating": {"production_ready": False, "research_only": True, "expanded_bridge_only": True},
        }
        return result
    except Exception as exc:  # noqa: BLE001 - fail closed, never fabricate
        result = {
            "property_id": str(property_id),
            "available": False,
            "score": None,
            "reason": f"feature_resolution_failed: {type(exc).__name__}: {exc}",
            "score_meaning": "research_positive_label_association_NOT_business_success_probability",
            "research_only": True,
            "inference_state": "expanded64_inference_unavailable",
            "layer1_model": model_name,
            "feature_coverage": {
                "feature_count": 64,
                "available_features": 0,
                "complete": False,
                "missing_features": [f"feature_resolution_failed: {type(exc).__name__}: {exc}"],
            },
            "gating": {"production_ready": False, "research_only": True, "expanded_bridge_only": True},
        }
        return result

    missing = list(coverage.missing_features)
    try:
        result = _score_property(
            str(property_id), dict(coverage.values), missing=missing, model_name=model_name
        )
        result["feature_coverage"].update({
            "value_sources": dict(coverage.sources),
            "flags": list(coverage.flags),
        })
    except ModelUnavailableError as exc:
        result = {
            "property_id": str(property_id),
            "available": False,
            "score": None,
            "reason": str(exc),
            "score_meaning": "research_positive_label_association_NOT_business_success_probability",
            "research_only": True,
            "inference_state": "expanded64_inference_unavailable",
            "layer1_model": model_name,
            "feature_coverage": {
                "feature_count": 64,
                "available_features": sum(v is not None for v in coverage.values.values()),
                "complete": False,
                "missing_features": missing,
                "value_sources": dict(coverage.sources),
                "flags": list(coverage.flags),
            },
            "gating": {"production_ready": False, "research_only": True, "expanded_bridge_only": True},
        }
    if result.get("available"):
        with _SCORE_CACHE_LOCK:
            _SCORE_CACHE[cache_key] = (monotonic() + _SCORE_CACHE_TTL, result)
    return result


def expanded_display_scores(
    analytics_session: Session, property_ids: list[str]
) -> dict[str, float]:
    """Return available expanded64 scores on the 0–100 display scale."""
    if not property_ids:
        return {}
    try:
        with analytics_session.begin_nested():
            scores = expanded_scores_many(analytics_session, property_ids)
    except (ModelUnavailableError, SQLAlchemyError):
        logger.warning("Expanded64 property scores are unavailable", exc_info=True)
        return {}
    return {
        property_id: float(result["score"]) * 100.0
        for property_id, result in scores.items()
        if result.get("available")
    }


def expanded_scores_many(
    analytics_session: Session,
    property_ids: list[str],
    *,
    coverage_sink: dict[str, dict[str, Any]] | None = None,
    refresh: bool = False,
) -> dict[str, dict[str, Any]]:
    """Score MANY catalogue properties with the expanded model.

    Batched feature resolution (one query per source table for the whole
    candidate set) so a ranking never issues per-property round-trips. The
    per-property merge, policy check and inference are identical to
    :func:`expanded_prediction`, and the model version is identical for every
    candidate in one call — legacy stored scores are never mixed in.

    ``coverage_sink`` (optional) receives ``{property_id: {values, sources,
    flags}}`` for every candidate whose feature vector resolved. The Stage-2
    category model consumes it directly (its 54 features are a subset of the
    64 resolved here), so a two-stage ranking never resolves features twice.
    """
    if not property_ids:
        return {}
    model_name = active_expanded_model_name()
    loaded = ModelLoader().load_cached(model_name)
    expected = loaded.feature_names

    # Reuse previously resolved predictions AND feature vectors; the
    # category model must receive the same features as the PU model.
    # If a vector is missing, fall back to the original batch query.
    ids = [str(p) for p in property_ids]
    model_version = str(loaded.meta.get("model_variant") or "unknown")
    with _SCORE_CACHE_LOCK:
        cached_scores = {pid: None if refresh else _cached_score((model_version, pid)) for pid in ids}
    if all(result is not None for result in cached_scores.values()):
        if coverage_sink is None:
            return {pid: cached_scores[pid] for pid in ids}
        with _COVERAGE_CACHE_LOCK:
            cached_vectors = {
                pid: _COVERAGE_CACHE.get((model_version, pid)) for pid in ids
            }
        if all(
            not cached_scores[pid].get("available") or cached_vectors[pid] is not None
            for pid in ids
        ):
            coverage_sink.update({
                pid: vector for pid, vector in cached_vectors.items()
                if vector is not None
            })
            return {pid: cached_scores[pid] for pid in ids}

    # --- batched resolution (mirrors PropertyFeatureRepository._resolve/get) ---
    rows = [dict(r) for r in analytics_session.execute(
        sql_text("""
            SELECT p.catalogue_id AS catalogue_id, l.subject_id
            FROM fyp.rental_properties p
            LEFT JOIN fyp.property_subject_links l
              ON l.sitewise_property_id = p.catalogue_id AND l.match_verified IS TRUE
            WHERE p.catalogue_id = ANY(:ids)
        """),
        {"ids": ids},
    ).mappings().all()]
    subject_of: dict[str, str] = {}
    found: set[str] = set()
    for row in rows:
        found.add(str(row["catalogue_id"]))
        if row["subject_id"]:
            subject_of[str(row["catalogue_id"])] = str(row["subject_id"])
    # Fallback for imported U rows without a verified rental link.
    unmapped = [pid for pid in ids if pid not in subject_of]
    if unmapped:
        for row in analytics_session.execute(
            sql_text("""
                SELECT f.canonical_property_id AS catalogue_id, f.subject_id
                FROM fyp.property_inference_features f
                WHERE f.canonical_property_id = ANY(:ids)

            """),
            {"ids": unmapped},
        ).mappings().all():
            cid = str(row["catalogue_id"])
            if cid not in subject_of:
                subject_of[cid] = str(row["subject_id"])

    subjects = sorted({sid for sid in subject_of.values()})
    sf_docs: dict[str, dict] = {}
    demand_docs: dict[str, dict] = {}
    if subjects:
        for row in analytics_session.execute(
            sql_text(
                "SELECT subject_id, to_jsonb(f) AS doc FROM fyp.property_inference_features f "
                "WHERE subject_id = ANY(:ids)"
            ),
            {"ids": subjects},
        ).mappings().all():
            sf_docs[str(row["subject_id"])] = dict(row["doc"] or {})
        for row in analytics_session.execute(
            sql_text(
                "SELECT subject_id, to_jsonb(f) AS doc FROM demand_gen.features f "
                "WHERE subject_id = ANY(:ids)"
            ),
            {"ids": subjects},
        ).mappings().all():
            demand_docs[str(row["subject_id"])] = dict(row["doc"] or {})

    worldpop_docs: dict[str, dict] = {}
    if ids:
        # Two rows per catalogue id may exist; prefer the SITEWISE_U_PROPERTY
        # extract with the same deterministic tie-break as the single getter.
        for row in analytics_session.execute(
            sql_text("""
                SELECT source_record_id, to_jsonb(t) AS doc
                FROM fyp_features.property_population_spatial t
                WHERE source_record_id = ANY(:ids)
                ORDER BY (source_record_type <> 'SITEWISE_U_PROPERTY'), source_record_type
            """),
            {"ids": ids},
        ).mappings().all():
            worldpop_docs.setdefault(str(row["source_record_id"]), dict(row["doc"] or {}))

    from sitewise.ml.property_features import WORLDPOP_EQUIVALENTS, _numeric

    def _resolve_one(catalogue_id: str) -> tuple[dict[str, float | None], dict[str, str], list[str]] | None:
        subject_id = subject_of.get(catalogue_id)
        if not subject_id:
            return None
        sf = sf_docs.get(subject_id)
        if not sf:
            return None
        extra = sf.get("other_features") or {}
        if not isinstance(extra, dict):
            extra = {}
        demand = demand_docs.get(subject_id) or {}
        worldpop = worldpop_docs.get(catalogue_id) or {}
        flags: list[str] = []
        if sf.get("analysis_status") != "COMPLETED":
            flags.append("Analysis status: " + str(sf.get("analysis_status")))
        candidates: tuple[tuple[str, Any], ...] = (
            ("fyp.property_inference_features", sf),
            ("fyp.property_inference_features.other_features", extra),
            ("demand_gen.features", demand),
            ("fyp_features.property_population_spatial", worldpop),
        )
        values: dict[str, float | None] = {}
        sources: dict[str, str] = {}
        for name in expected:
            value = None
            for label, data in candidates:
                if name in data:
                    v = _numeric(data[name])
                    if v is not None:
                        value = v
                        sources[name] = label + "." + name
                        break
            if value is None and name in WORLDPOP_EQUIVALENTS:
                alias = WORLDPOP_EQUIVALENTS[name]
                value = _numeric(worldpop.get(alias))
                if value is not None:
                    sources[name] = "fyp_features.property_population_spatial." + alias
            values[name] = value

        # Bridges: the 47-feature bridge (pop_2000m, walk-reachable) and the
        # expanded bridge (16 new measurements) are in-memory lookups.
        base_bundle = PropertyFeatureBundle(
            property_id=catalogue_id,
            source="catalog",
            subject_id=subject_id,
            values=values,
            value_sources=sources,
            missing_features=[n for n, v in values.items() if v is None],
            analysis_status=sf.get("analysis_status"),
            flags=flags,
        )
        coverage = merge_bridge_features(base_bundle, expected_features=expected)
        coverage = merge_expanded_bridge_features(coverage, expected_features=expected)
        return dict(coverage.values), dict(coverage.sources), list(coverage.flags)

    results: dict[str, dict[str, Any]] = {}
    model_version = str(loaded.meta.get("model_variant") or "unknown")

    # Phase 1 — resolve every candidate once, then split into cached /
    # unmapped / policy-refused / scoreable. Nothing is scored one-by-one:
    # sklearn's per-call overhead dominates at 955 candidates (~37 ms each),
    # so Phase 2 runs ONE matrix prediction for the whole set.
    pending: list[tuple[str, dict[str, float | None], list[str], dict[str, str], list[str]]] = []
    for catalogue_id in ids:
        cache_key = (model_version, catalogue_id)
        with _SCORE_CACHE_LOCK:
            cached = None if refresh else _cached_score(cache_key)
        if cached is not None:
            results[catalogue_id] = cached
            # Refill the Stage-2 sink from the resolved vector that produced
            # this score. Without this, a cached score silently drops the
            # category evidence for every subsequent ranking.
            if coverage_sink is not None:
                with _COVERAGE_CACHE_LOCK:
                    stored = _COVERAGE_CACHE.get(cache_key)
                if stored is None:
                    # The score may have been cached by the single-property
                    # path, which does not record the vector. Resolve it once
                    # so Stage 2 keeps its evidence; never guess the values.
                    resolved = _resolve_one(catalogue_id)
                    if resolved is not None:
                        values, sources, flags = resolved
                        stored = {
                            "values": dict(values),
                            "sources": dict(sources),
                            "flags": list(flags),
                        }
                        with _COVERAGE_CACHE_LOCK:
                            _COVERAGE_CACHE[cache_key] = stored
                if stored is not None:
                    coverage_sink[catalogue_id] = {
                        "values": dict(stored["values"]),
                        "sources": dict(stored["sources"]),
                        "flags": list(stored["flags"]),
                    }
            continue
        resolved = _resolve_one(catalogue_id)
        if resolved is None:
            results[catalogue_id] = {
                "property_id": catalogue_id,
                "available": False,
                "score": None,
                "reason": "No verified analytical mapping for this catalogue property",
                "score_meaning": "research_positive_label_association_NOT_business_success_probability",
                "research_only": True,
                "inference_state": "expanded64_inference_unavailable",
                "layer1_model": model_name,
                "gating": {"production_ready": False, "research_only": True, "expanded_bridge_only": True},
            }
            continue
        values, sources, flags = resolved
        with _COVERAGE_CACHE_LOCK:
            _COVERAGE_CACHE[cache_key] = {
                "values": dict(values),
                "sources": dict(sources),
                "flags": list(flags),
            }
        if coverage_sink is not None:
            coverage_sink[catalogue_id] = {
                "values": dict(values),
                "sources": dict(sources),
                "flags": list(flags),
            }
        missing = [name for name in expected if values.get(name) is None]
        try:
            _expanded_policy_check(missing)
        except ModelUnavailableError as exc:
            results[catalogue_id] = {
                "property_id": catalogue_id,
                "available": False,
                "score": None,
                "reason": str(exc),
                "score_meaning": "research_positive_label_association_NOT_business_success_probability",
                "research_only": True,
                "inference_state": "expanded64_inference_unavailable",
                "layer1_model": model_name,
                "feature_coverage": {
                    "feature_count": 64,
                    "available_features": sum(v is not None for v in values.values()),
                    "complete": False,
                    "missing_features": missing,
                    "value_sources": sources,
                    "flags": flags,
                },
                "gating": {"production_ready": False, "research_only": True, "expanded_bridge_only": True},
            }
            continue
        pending.append((catalogue_id, values, missing, sources, flags))

    # Phase 2 — one prediction matrix for every scoreable property.
    if pending:
        import numpy as np

        X = np.asarray(
            [
                [
                    float(values[name]) if values.get(name) is not None else float("nan")
                    for name in expected
                ]
                for _, values, _, _, _ in pending
            ],
            dtype=float,
        )
        try:
            probs = np.asarray(loaded.model.predict_proba(X), dtype=float)
            if probs.shape != (len(pending), 2):
                raise ValueError(f"Unexpected predict_proba shape {probs.shape}")
            scores_arr = probs[:, 1]
            if not np.all(np.isfinite(scores_arr)) or np.any((scores_arr < 0) | (scores_arr > 1)):
                raise ValueError("Positive-association score is out of bounds")
            labels = (
                np.asarray(loaded.model.predict(X)).astype(int)
                if hasattr(loaded.model, "predict")
                else None
            )
        except (ValueError, TypeError, IndexError) as exc:
            for catalogue_id, values, missing, sources, flags in pending:
                results[catalogue_id] = {
                    "property_id": catalogue_id,
                    "available": False,
                    "score": None,
                    "reason": f"PU inference failed: {exc}",
                    "score_meaning": "research_positive_label_association_NOT_business_success_probability",
                    "research_only": True,
                    "inference_state": "expanded64_inference_unavailable",
                    "layer1_model": model_name,
                    "feature_coverage": {
                        "feature_count": 64,
                        "available_features": sum(v is not None for v in values.values()),
                        "complete": False,
                        "missing_features": missing,
                        "value_sources": sources,
                        "flags": flags,
                    },
                    "gating": {"production_ready": False, "research_only": True, "expanded_bridge_only": True},
                }
        else:
            for index, (catalogue_id, values, missing, sources, flags) in enumerate(pending):
                result = {
                    "property_id": catalogue_id,
                    "available": True,
                    "score": float(scores_arr[index]),
                    "label": int(labels[index]) if labels is not None else None,
                    "model_version": model_version,
                    "score_meaning": str(
                        loaded.meta.get("score_meaning")
                        or "research_positive_label_association_NOT_business_success_probability"
                    ),
                    "research_only": True,
                    "missing_features": list(missing),
                    "feature_coverage": {
                        "feature_count": 64,
                        "available_features": sum(v is not None for v in values.values()),
                        "complete": not missing,
                        "missing_features": list(missing),
                        "imputed_features": list(missing),
                        "value_sources": sources,
                        "flags": flags,
                    },
                    "inference_state": "ready",
                    "layer1_model": model_name,
                    "gating": {"production_ready": False, "research_only": True, "expanded_bridge_only": True},
                }
                with _SCORE_CACHE_LOCK:
                    _SCORE_CACHE[(model_version, catalogue_id)] = (
                        monotonic() + _SCORE_CACHE_TTL, result
                    )
                results[catalogue_id] = result
    return results
