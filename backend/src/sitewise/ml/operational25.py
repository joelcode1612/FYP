"""Operational25 PU candidate: 25-feature inference from four existing groups.

This module reuses the trained ``no_routing_no_age25`` artifact and the
``Expanded64CoordinateExtractor``. It never retrains, never imputes a
non-residential measurement, and keeps the score research-only: an
uncalibrated P-vs-U association index, not a business success probability.

The feature order comes from the trained artifact's own contract; no caller
may assume 64 features or hardcode positional indices.
"""
from __future__ import annotations

import hashlib
import json
import math
from functools import lru_cache
from pathlib import Path
from typing import Any

from sqlmodel import Session

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.ml.expanded64_network import Expanded64CoordinateExtractor
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.pu_learning import PULearning
from sitewise.services.property_enrichment_service import coordinate_hash

MODEL_NAME = "sitewise_pu_operational25"
ARTIFACT_SHA256 = "6361d0bcff25b23468a2c101df96679c783258ded86e61a34f139bebfef4b262"
REPO_ROOT = Path(__file__).resolve().parents[3]
CONTRACT_PATH = REPO_ROOT / "ml_reference" / "operational25_feature_contracts.json"
SHAP_BACKGROUND_PATH = REPO_ROOT / "ml_reference" / "shap_background_operational25.csv"
FEATURE_VERSION = "operational25-coordinate-v1"

# Groups are the only measurements this candidate is allowed to request.
GROUPS: dict[str, tuple[str, ...]] = {}


@lru_cache(maxsize=1)
def contract() -> dict[str, Any]:
    """Load and validate the trained candidate's declared contract."""
    data = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
    spec = data["no_routing_no_age25"]
    features = list(spec["feature_names"])
    imputable = frozenset(spec["imputable_features"])
    if len(features) != 25 or len(imputable) != 8:
        raise ModelUnavailableError("Operational25 feature contract is incomplete")
    if len(set(features)) != 25:
        raise ModelUnavailableError("Operational25 feature names must be unique")
    if not imputable.issubset(features) or any(
        not name.startswith("residential_") for name in imputable
    ):
        raise ModelUnavailableError("Only residential features may be imputed")
    global GROUPS
    GROUPS = {
        "population_rings": tuple(features[:2]),
        "demand_generator_pois": tuple(features[2:16]),
        "road_geometry": tuple(features[16:17]),
        "residential_density": tuple(features[17:]),
    }
    if any(len(names) != expected for names, expected in
           zip(GROUPS.values(), (2, 14, 1, 8))):
        raise ModelUnavailableError("Operational25 group boundaries changed")
    return spec


@lru_cache(maxsize=1)
def artifact_sha256() -> str:
    path = Path(__file__).resolve().parent / f"{MODEL_NAME}.joblib"
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != ARTIFACT_SHA256:
        raise ModelUnavailableError("Operational25 artifact checksum mismatch")
    return digest


def feature_digest(values: dict[str, float | None]) -> str:
    names = contract()["feature_names"]
    payload = json.dumps(
        {name: None if values.get(name) is None else round(float(values[name]), 6)
         for name in names},
        sort_keys=True, separators=(",", ":"),
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _clean(name: str, value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(number) or number < 0:
        return None
    if name.endswith("_pct") and number > 100:
        return None
    return number


def extract(analytics_session: Session, latitude: float, longitude: float) -> dict[str, Any]:
    """Measure the four allowed groups at one verified coordinate."""
    spec = contract()
    names = list(spec["feature_names"])
    imputable = frozenset(spec["imputable_features"])
    if not (_valid := all(math.isfinite(v) for v in (latitude, longitude))
            and -90 <= latitude <= 90 and -180 <= longitude <= 180):
        raise ModelUnavailableError("Invalid coordinates for Operational25 inference")
    observations = Expanded64CoordinateExtractor(analytics_session).extract(
        float(latitude), float(longitude), selected=set(GROUPS)
    )
    values: dict[str, float | None] = dict.fromkeys(names)
    sources: dict[str, str] = {}
    blockers: list[str] = []
    diagnostics: dict[str, Any] = {}
    for group, group_names in GROUPS.items():
        outcome = observations.get(group)
        if outcome is None:
            blockers.append(f"{group}: no extraction result")
            continue
        diagnostics[group] = {
            "status": outcome.status, "reason": outcome.reason,
            "notes": outcome.notes, "values": len(outcome.values),
        }
        if group == "residential_density" and not all(
            key in outcome.notes for key in ("any_building_count_500m", "any_building_count_1000m")
        ):
            blockers.append("residential_density: both radius queries must return coverage evidence")
        if outcome.status not in ("ready", "partial"):
            if group != "residential_density" or outcome.status != "unavailable":
                blockers.append(f"{group}: {outcome.status}")
            continue
        for name in group_names:
            value = _clean(name, outcome.values.get(name))
            if value is not None and outcome.sources.get(name):
                values[name] = value
                sources[name] = outcome.sources[name]
    missing = [name for name in names if values[name] is None]
    disallowed = [name for name in missing if name not in imputable]
    if disallowed:
        blockers.append("missing required features: " + ", ".join(disallowed))
    return {
        "values": values,
        "sources": sources,
        "missing_features": missing,
        "imputable_missing": [name for name in missing if name in imputable],
        "blockers": blockers,
        "groups": diagnostics,
        "available": not blockers,
        "coordinate_hash": coordinate_hash(float(latitude), float(longitude)),
        "feature_calculation_version": FEATURE_VERSION,
        "feature_digest": feature_digest(values),
    }


def score(values: dict[str, float | None], *, property_id: str) -> dict[str, Any]:
    """Score one validated vector with the trusted bagged artifact."""
    spec = contract()
    names = list(spec["feature_names"])
    imputable = frozenset(spec["imputable_features"])
    missing = [name for name in names if values.get(name) is None]
    if any(name not in imputable for name in missing):
        raise ModelUnavailableError("A required Operational25 measurement is missing")
    loaded = ModelLoader().load_cached(MODEL_NAME)
    if list(loaded.feature_names) != names:
        raise ModelUnavailableError("Operational25 artifact and contract disagree")
    digest = artifact_sha256()
    prediction = PULearning(ModelLoader(), MODEL_NAME).predict_or_report(
        property_id, {name: values.get(name) for name in names},
        allow_model_imputation=True,
    )
    if not prediction.get("available"):
        raise ModelUnavailableError(str(prediction.get("reason") or "scoring failed"))
    score_value = float(prediction["score"])
    return {
        "property_id": str(property_id),
        "available": True,
        "score": score_value,
        "score_0_100": score_value * 100.0,
        "label": prediction.get("label"),
        "model_version": spec["version"],
        "model_name": MODEL_NAME,
        "model_sha256": digest,
        "feature_count": len(names),
        "feature_order": names,
        "feature_values": values,
        "feature_digest": feature_digest(values),
        "research_only": True,
        "production_ready": False,
        "score_meaning": spec["score_meaning"],
    }
