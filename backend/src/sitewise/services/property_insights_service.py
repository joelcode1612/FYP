"""Property-scoped location insights: score, SHAP factors and five categories.

This is the read model behind the redesigned Property Detail page. It answers
three questions for one catalogue property, and nothing more:

1. **What is the location score?** The original variant uses the stored
   `research_p_association_score` that drives legacy ranking and compares it
   with live inference when the complete exact feature vector resolves. The
   experimental variant uses live inference only. Either is a 0-100 research
   association index, never a probability of business success.
2. **Which features moved that score, and in which direction?** Permutation
   SHAP is computed over the same selected PU artifact and exact 47-feature
   vector as the displayed score, against a verified real background. Additivity
   and score identity are checked; an explanation that cannot reconstruct that
   score is withheld without hiding an otherwise valid score.
3. **What does that mean per category?** The same contributions grouped into
   the five categories the page presents, with entrepreneur-facing labels.

Design constraints enforced here
================================
* **No fabrication.** Every number is either resolved from the database,
  reproduced from the deployed artifact, or computed by SHAP. Missing inputs
  produce an explicit reason; they never create a live score or placeholder.
  A separately valid stored legacy score remains visible when SHAP is unavailable.
* **No raw column names reach the UI.** ``FEATURE_LABELS`` maps all 47 model
  features to plain English; the technical name is retained under
  ``technical`` for the optional explanation and for authorised consumers.
* **One artifact, one explanation.** The service loads whichever artifact
  ``SITEWISE_PU_MODEL_VARIANT`` selects and stamps its version and checksum into
  the score/explanation payload. Cache keys include model version, artifact
  SHA-256, property id and stored legacy score, so artifact or score changes
  cannot surface stale explanations.
* **SHAP is cached, not recomputed per request.** The cache is keyed by
  ``(model_version, property_id)``. Measured latency is recorded separately in
  ``ml_reference/recommender_eval/shap_latency.json``; a single local measurement
  is not treated as a general latency guarantee.
"""

from __future__ import annotations

import csv
import hashlib
import math
import threading
from pathlib import Path
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.ml.feature_bridge import merge_bridge_features
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.property_features import FeatureResolutionError, PropertyFeatureRepository
from sitewise.ml.pu_learning import PULearning
from sitewise.ml.pu_variant import LEGACY_MODEL_NAME, resolve_variant
from sitewise.ml.shap_explainer import ShapExplainer
from sitewise.services.explanation_service import (
    _ADDITIVITY_TOLERANCE,
    category_of,
    group_contributions,
)

#: Plain-English labels for every one of the 47 deployed model features. The
#: UI never shows the key on the left; it is kept as ``technical`` only so the
#: optional "show technical detail" view and authorised services can audit it.
FEATURE_LABELS: dict[str, str] = {
    "pop_500m": "People living within 500 m",
    "pop_1000m": "People living within 1 km",
    "pop_2000m": "People living within 2 km",
    "pop_3000m": "People living within 3 km",
    "office_pois_500m": "Offices within 500 m",
    "office_pois_1000m": "Offices within 1 km",
    "schools_count_500m": "Schools within 500 m",
    "schools_count_1000m": "Schools within 1 km",
    "universities_colleges_count_500m": "Universities and colleges within 500 m",
    "universities_colleges_count_1000m": "Universities and colleges within 1 km",
    "retail_pois_500m": "Retail shops within 500 m",
    "retail_pois_1000m": "Retail shops within 1 km",
    "malls_count_500m": "Shopping malls within 500 m",
    "malls_count_1000m": "Shopping malls within 1 km",
    "hospitals_count_500m": "Hospitals and clinics within 500 m",
    "hospitals_count_1000m": "Hospitals and clinics within 1 km",
    "supermarkets_count_500m": "Supermarkets within 500 m",
    "supermarkets_count_1000m": "Supermarkets within 1 km",
    "nearest_transit_walk_m": "Distance to the nearest public transport",
    "nearest_major_road_m": "Distance to the nearest major road",
    "road_intersection_density_500m_km2": "Road junctions nearby",
    "road_length_density_500m_km_km2": "Road coverage within 500 m",
    "osm_walkway_length_density_500m_km_km2": "Walking paths within 500 m",
    "landscan_ambient_pop_1000m": "Ambient population within 1 km",
    "landscan_ambient_pop_2000m": "Ambient population within 2 km",
    "landscan_ambient_pop_3000m": "Ambient population within 3 km",
    "transit_stops_500m_walk": "Public transport stops within a 500 m walk",
    "transit_stops_1km_walk": "Public transport stops within a 1 km walk",
    "weekday_transit_routes_1km_walk": "Transit routes within a 1 km walk",
    "weekday_departures_500m_walk_am": "Morning departures within a 500 m walk",
    "road_length_density_1km_km_km2": "Road coverage within 1 km",
    "walk_isochrone_area_10min_km2": "Area reachable on foot in 10 minutes",
    "worldpop_walk_reachable_10min": "People reachable on foot in 10 minutes",
    "drive_isochrone_area_10min_km2": "Area reachable by car in 10 minutes",
    "parking_facilities_500m": "Parking facilities within 500 m",
    "parking_facilities_1km": "Parking facilities within 1 km",
    "nearest_parking_distance_m": "Distance to the nearest parking",
    "fnb_competitors_500m": "Other F&B outlets within 500 m",
    "fnb_competitors_1000m": "Other F&B outlets within 1 km",
    "cafe_count_500m": "Cafés within 500 m",
    "cafe_count_1000m": "Cafés within 1 km",
    "restaurant_count_500m": "Restaurants within 500 m",
    "restaurant_count_1000m": "Restaurants within 1 km",
    "fast_food_count_500m": "Fast-food outlets within 500 m",
    "fast_food_count_1000m": "Fast-food outlets within 1 km",
    "bakery_dessert_beverage_count_500m": "Bakeries and drink shops within 500 m",
    "bakery_dessert_beverage_count_1000m": "Bakeries and drink shops within 1 km",
}

#: Unit suffix per feature, used only for the value shown beside a factor.
_FEATURE_UNITS: dict[str, str] = {}
for _name in FEATURE_LABELS:
    # Order matters: ``*_km_km2`` also ends with ``_km2``, and ``*_am`` must be
    # tested before the generic distance suffix.
    if _name.endswith("_km_km2"):
        _FEATURE_UNITS[_name] = "km/km²"
    elif _name.endswith("_km2"):
        _FEATURE_UNITS[_name] = "km²"
    elif _name.endswith("_am"):
        _FEATURE_UNITS[_name] = "departures"
    elif _name.endswith("_m"):
        _FEATURE_UNITS[_name] = "m"
    elif _name.startswith("pop_") or "ambient_pop" in _name or "reachable" in _name:
        _FEATURE_UNITS[_name] = "people"
    else:
        _FEATURE_UNITS[_name] = ""
# Distances and densities read badly with a bare number; give them a direction.
_IS_DISTANCE = {n for n in FEATURE_LABELS if n.endswith("_m")}

#: The five categories in the order the page presents them, with the question
#: each one answers. Keys match ``explanation_service.category_of``.
CATEGORY_SPECS: tuple[dict[str, str], ...] = (
    {
        "key": "population",
        "label": "People Nearby",
        "question": "How many people live within reach of this shop?",
        "why": (
            "A larger nearby population means more potential customers passing "
            "through the area. It is one signal among several, not a forecast."
        ),
    },
    {
        "key": "competitors",
        "label": "Other Food Businesses",
        "question": "How many other F&B outlets are already here?",
        "why": (
            "Nearby competitors can mean proven demand, but they also split the "
            "same customers. The model learns the balance from operating sites."
        ),
    },
    {
        "key": "demand_generators",
        "label": "Nearby Places",
        "question": "What brings people to this area?",
        "why": (
            "Offices, schools, malls, hospitals and supermarkets create repeat "
            "footfall at predictable times of day."
        ),
    },
    {
        "key": "accessibility",
        "label": "Getting There",
        "question": "How easy is this location to reach?",
        "why": (
            "Roads, public transport and walkability decide how far customers "
            "will travel, and whether they can reach you without a car."
        ),
    },
    {
        "key": "parking",
        "label": "Parking Nearby",
        "question": "Can customers park near this shop?",
        "why": (
            "Parking availability matters most where customers drive. A shortage "
            "can put a ceiling on how many people visit."
        ),
    },
)

_CATEGORY_BY_KEY = {spec["key"]: spec for spec in CATEGORY_SPECS}

#: The five map layers the page offers, in display order. Only ``properties``
#: has stored coordinates in this deployment; the other four are recorded on
#: the property's feature vector as *counts within a radius*, with no
#: individual outlet positions. They are therefore reported with their true
#: totals and an explicit ``mapped: false`` flag rather than invented markers —
#: the map draws no pin it cannot place.
MAP_LAYER_SPECS: tuple[dict[str, Any], ...] = (
    {
        "key": "properties",
        "label": "Properties",
        "color": "#1d4ed8",
        "description": "Analysed commercial properties from the research catalogue.",
        "mapped": True,
    },
    {
        "key": "competitors",
        "label": "Food Businesses",
        "color": "#d97706",
        "description": "Other food and beverage outlets already trading nearby.",
        "mapped": False,
    },
    {
        "key": "demand_generators",
        "label": "Nearby Places",
        "color": "#0f9d86",
        "description": "Shops, malls, offices, schools and clinics that bring people in.",
        "mapped": False,
    },
    {
        "key": "accessibility",
        "label": "Transport",
        "color": "#7c3aed",
        "description": "Public transport stops and routes within walking distance.",
        "mapped": False,
    },
    {
        "key": "parking",
        "label": "Parking",
        "color": "#475569",
        "description": "Parking facilities recorded around the property.",
        "mapped": False,
    },
)

#: Which stored feature counts feed each layer. A layer's 500 m and 1 km totals
#: are the sum of these features; ``nearest`` is a distance, not a count.
_LAYER_FEATURES: dict[str, dict[str, Any]] = {
    "competitors": {
        "count_500m": ("fnb_competitors_500m",),
        "count_1000m": ("fnb_competitors_1000m",),
        "nearest": None,
    },
    "demand_generators": {
        "count_500m": (
            "retail_pois_500m",
            "malls_count_500m",
            "supermarkets_count_500m",
            "office_pois_500m",
            "schools_count_500m",
            "universities_colleges_count_500m",
            "hospitals_count_500m",
        ),
        "count_1000m": (
            "retail_pois_1000m",
            "malls_count_1000m",
            "supermarkets_count_1000m",
            "office_pois_1000m",
            "schools_count_1000m",
            "universities_colleges_count_1000m",
            "hospitals_count_1000m",
        ),
        "nearest": None,
    },
    "accessibility": {
        "count_500m": ("transit_stops_500m_walk",),
        "count_1000m": ("transit_stops_1km_walk",),
        "nearest": "nearest_transit_walk_m",
    },
    "parking": {
        "count_500m": ("parking_facilities_500m",),
        "count_1000m": ("parking_facilities_1km",),
        "nearest": "nearest_parking_distance_m",
    },
}

#: Statuses that mean a stitched panorama finished successfully. Anything else
#: (``pending``, ``processing``, ``failed``) must not be presented as a tour.
PANORAMA_COMPLETE_STATUSES = frozenset({"complete", "completed", "ready", "succeeded"})

#: Score bands. Wording is deliberately hedged: the index ranks locations
#: against each other, it does not predict commercial success.
_SCORE_BANDS: tuple[tuple[int, str], ...] = (
    (75, "This location has many characteristics that may suit an F&B business."),
    (60, "This location has several characteristics that may suit an F&B business."),
    (40, "This location has a mixed profile for an F&B business."),
    (0, "This location has few characteristics that favour an F&B business."),
)

SCORE_MEANING = (
    "A research association index: how closely this location's measured "
    "characteristics resemble the operating F&B sites the model learned from, "
    "compared with other commercial properties. It is NOT a probability of "
    "business success and it does not guarantee revenue."
)

_SHAP_BACKGROUND_CSV = Path(__file__).resolve().parents[3] / "ml_reference" / "shap_background_47.csv"
_STORED_PU_SCORE_TYPE = "UNCALIBRATED_PvU_RESEARCH_ASSOCIATION_NOT_SUCCESS_PROBABILITY"

#: Cache of computed explanations, keyed by (model_version, property_id) so a
#: replaced artifact can never serve a previous model's explanation.
_EXPLANATION_CACHE: dict[tuple[str, str], dict[str, Any]] = {}
_EXPLANATION_CACHE_LOCK = threading.Lock()


def clear_insights_cache() -> int:
    """Test/admin hook: drop cached explanations. Returns the number dropped."""
    with _EXPLANATION_CACHE_LOCK:
        count = len(_EXPLANATION_CACHE)
        _EXPLANATION_CACHE.clear()
        return count


def format_feature_value(feature: str, value: float | None) -> str:
    """A short, human-readable value for a factor row (``"13,656 people"``).

    Precision is chosen per unit: counts are integers, densities and areas keep
    one decimal, and genuinely small areas keep enough digits to stay truthful
    (``0.0006 km²`` must not collapse to ``0``).
    """
    if value is None:
        return "not measured"
    unit = _FEATURE_UNITS.get(feature, "")
    count_like = unit in {"people", "departures"} or unit == ""

    if count_like:
        rendered = f"{int(round(value)):,}"
    elif value == 0:
        rendered = "0"
    elif abs(value) < 0.01:
        rendered = f"{value:.4f}".rstrip("0").rstrip(".")
    elif abs(value) < 1:
        rendered = f"{value:.3f}".rstrip("0").rstrip(".")
    else:
        rendered = f"{value:,.1f}".rstrip("0").rstrip(".")

    return f"{rendered} {unit}".strip()


def score_band(score: int) -> str:
    for threshold, sentence in _SCORE_BANDS:
        if score >= threshold:
            return sentence
    return _SCORE_BANDS[-1][1]


def _factor(feature: str, contribution: float, value: float | None) -> dict[str, Any]:
    """One contribution row, with the label the UI shows and the raw key kept."""
    category = category_of(feature)
    spec = _CATEGORY_BY_KEY.get(category)
    return {
        "technical": feature,
        "label": FEATURE_LABELS.get(feature, feature.replace("_", " ")),
        "contribution": round(float(contribution), 10),
        "direction": "increases" if contribution > 0 else ("decreases" if contribution < 0 else "neutral"),
        "value": value,
        "value_display": format_feature_value(feature, value),
        "unit": _FEATURE_UNITS.get(feature, ""),
        "is_distance": feature in _IS_DISTANCE,
        "category": category,
        "category_label": spec["label"] if spec else "Other",
    }


def _category_payloads(contributions: dict[str, float], values: dict[str, float | None]) -> list[dict]:
    """The five categories, always present so the UI can show honest empties."""
    grouped = {group["key"]: group for group in group_contributions(contributions)}
    payloads: list[dict[str, Any]] = []

    for spec in CATEGORY_SPECS:
        key = spec["key"]
        group = grouped.get(key)
        members = sorted(
            ((name, value) for name, value in contributions.items() if category_of(name) == key),
            key=lambda kv: -abs(kv[1]),
        )
        factors = [_factor(name, value, values.get(name)) for name, value in members]
        available = bool(factors)
        payload: dict[str, Any] = {
            "key": key,
            "label": spec["label"],
            "question": spec["question"],
            "why": spec["why"],
            "available": available,
            "contribution": round(float(group["contribution"]), 10) if group else 0.0,
            "direction": (
                "increases"
                if group and group["contribution"] > 0
                else ("decreases" if group and group["contribution"] < 0 else "neutral")
            ),
            "feature_count": len(factors),
            "factors": factors,
            # Totals are only meaningful when every member mapped to this
            # category; an empty list means no model feature belongs here.
            "note": None
            if available
            else "No model features are grouped under this category for this property.",
        }
        payloads.append(payload)

    # Features the category rules do not recognise are surfaced rather than
    # silently dropped from the totals.
    other = grouped.get("other")
    if other:
        payloads.append(
            {
                "key": "other",
                "label": "Other factors",
                "question": "Other measured characteristics.",
                "why": "Model features that are not part of the five main categories.",
                "available": True,
                "contribution": round(float(other["contribution"]), 10),
                "direction": "increases" if other["contribution"] > 0 else "decreases",
                "feature_count": other["feature_count"],
                "factors": [
                    _factor(name, contributions[name], values.get(name))
                    for name in other["features"]
                ],
                "note": None,
            }
        )
    return payloads


def _sum_counts(values: dict[str, float | None], names: tuple[str, ...]) -> int | None:
    """Sum a layer's counts, or ``None`` if any input is unmeasured.

    Returning ``None`` rather than treating a missing measurement as zero keeps
    "we never measured this" distinct from "we measured none".
    """
    total = 0.0
    for name in names:
        value = values.get(name)
        if value is None:
            return None
        total += float(value)
    return int(round(total))


def _layer_payloads(values: dict[str, float | None], measured: bool = True) -> list[dict[str, Any]]:
    """The five map layers with their true counts and mapping status."""
    layers: list[dict[str, Any]] = []

    for spec in MAP_LAYER_SPECS:
        key = spec["key"]
        layer: dict[str, Any] = {
            "key": key,
            "label": spec["label"],
            "color": spec["color"],
            "description": spec["description"],
            "mapped": spec["mapped"],
            "count_500m": None,
            "count_1000m": None,
            "nearest_m": None,
            "metrics": [],
            "note": None,
        }

        if key == "properties":
            # Counts here depend on the radius the viewer selects and are
            # computed by the map from the catalogue itself, so the API does
            # not pretend to know them.
            layer["note"] = (
                "Reference properties with a known location. The map counts "
                "those inside the radius you select."
            )
            layers.append(layer)
            continue

        cfg = _LAYER_FEATURES[key]
        if not measured:
            layer["note"] = "Location measurements were not available, so this layer has no counts."
            layers.append(layer)
            continue
        layer["count_500m"] = _sum_counts(values, cfg["count_500m"])
        layer["count_1000m"] = _sum_counts(values, cfg["count_1000m"])
        if cfg["nearest"]:
            nearest = values.get(cfg["nearest"])
            layer["nearest_m"] = round(float(nearest), 1) if nearest is not None else None

        # Every contributing measurement, so the panel can show real detail
        # rather than a single opaque total.
        for name in (*cfg["count_500m"], *cfg["count_1000m"]):
            value = values.get(name)
            if value is None:
                continue
            layer["metrics"].append(
                {
                    "technical": name,
                    "label": FEATURE_LABELS.get(name, name.replace("_", " ")),
                    "value_display": format_feature_value(name, value),
                }
            )

        if layer["count_500m"] is None and layer["count_1000m"] is None:
            layer["note"] = "No counts were recorded for this property."
        else:
            layer["note"] = (
                "Recorded as counts within each radius. Individual locations are "
                "not stored, so no pins are drawn for this layer."
            )
        layers.append(layer)

    return layers


class PropertyInsightsService:
    """Compose score + SHAP + categories for one catalogue property."""

    def __init__(self, session: Session, analytics_session: Session | None = None):
        self.session = session
        self.analytics = analytics_session

    # -- public -------------------------------------------------------------

    def insights(self, property_id: str, origin: dict[str, float] | None = None) -> dict[str, Any]:
        """Return the active PU score independently of optional SHAP.

        The score and its explanation are separate products: a missing feature,
        missing SHAP background or SHAP failure must not hide a valid stored or
        live PU score. The catalogue ranking's legacy score remains
        authoritative when the active variant is ``legacy``; any available
        live inference is compared with it rather than silently substituted.
        """
        variant = self._variant()
        base: dict[str, Any] = {
            "property_id": property_id,
            "model": variant,
            "origin": origin,
            "map": {"layers": _layer_payloads({}, measured=False)},
            "panorama": self._panorama(property_id),
            "score": {"available": False, "label": "Location Fit", "meaning": SCORE_MEANING},
            "explanation": {"available": False},
            "categories": [
                {
                    **{k: spec[k] for k in ("key", "label", "question", "why")},
                    "available": False,
                    "contribution": 0.0,
                    "direction": "neutral",
                    "feature_count": 0,
                    "factors": [],
                    "note": None,
                }
                for spec in CATEGORY_SPECS
            ],
            "availability": {
                "score": False,
                "explanation": False,
                "factors": False,
                "categories": False,
            },
        }

        if self.analytics is None:
            base["reason"] = {
                "code": "analytics_unavailable",
                "message": "Location analysis is not configured for this deployment.",
            }
            return base

        try:
            loaded = ModelLoader().load(variant["layer1_model"])
        except ModelUnavailableError as exc:
            base["reason"] = {
                "code": "model_unavailable",
                "message": "The configured PU artifact could not be loaded.",
                "detail": str(exc),
            }
            return base

        stored = self._stored_legacy_score(property_id) if variant.get("key") == "legacy" else None
        artifact_digest = self._artifact_sha256(loaded.meta.get("artifact_filename")) or "unhashed"
        cache_version = (
            f"{variant.get('layer1_model') or variant['name']}:{variant.get('version') or 'unknown'}:"
            f"{artifact_digest}:{stored['score'] if stored is not None else 'no-stored-score'}"
        )
        cache_key = (cache_version, property_id)
        with _EXPLANATION_CACHE_LOCK:
            cached = _EXPLANATION_CACHE.get(cache_key)
        if cached is not None:
            return {**base, **cached}

        repo = PropertyFeatureRepository(self.analytics)
        bundle = None
        coverage = None
        resolution_error: str | None = None
        try:
            bundle = repo.get(property_id, loaded.feature_names, source="catalog")
            coverage = merge_bridge_features(bundle, expected_features=loaded.feature_names)
            values = dict(coverage.values)
            base["feature_coverage"] = {
                "available_features": coverage.available_count,
                "feature_count": len(loaded.feature_names),
                "missing_features": list(coverage.missing_features),
                "unrecoverable_features": list(coverage.unrecoverable_features),
                "value_sources": dict(coverage.sources),
                "flags": list(coverage.flags),
            }
            base["map"] = {"layers": _layer_payloads(values)}
        except FeatureResolutionError as exc:
            values = {}
            resolution_error = str(exc)
        except Exception as exc:  # noqa: BLE001 - score fallback remains possible
            values = {}
            resolution_error = f"{type(exc).__name__}: {exc}"

        features = {
            name: float(value)
            for name, value in values.items()
            if value is not None
        }
        live_prediction: dict[str, Any] | None = None
        if coverage is not None and not coverage.missing_features:
            live_prediction = PULearning(model_name=variant["layer1_model"]).predict_or_report(
                property_id, features, allow_model_imputation=False
            )

        pu_score: float | None = None
        score_source = ""
        source_label = ""
        stored_comparison: dict[str, Any] | None = None
        if stored is not None:
            # The legacy recommender ranks on this exact stored catalogue value.
            # Keep the property-detail score aligned with ranking, even when the
            # current feature resolver or optional explanation is unavailable.
            pu_score = float(stored["score"])
            score_source = "stored_catalogue_prediction"
            source_label = "Stored original PU prediction"
            if live_prediction and live_prediction.get("available"):
                difference = abs(float(live_prediction["score"]) - pu_score)
                stored_comparison = {
                    "stored_score": pu_score,
                    "live_inference_score": float(live_prediction["score"]),
                    "absolute_difference": difference,
                    "tolerance": 1e-6,
                    "verified": difference <= 1e-6,
                }
                if difference <= 1e-6:
                    source_label = "Stored score · verified by live inference"
                else:
                    source_label = "Stored score · live inference differs"
        elif live_prediction and live_prediction.get("available"):
            pu_score = float(live_prediction["score"])
            score_source = "live_model_inference"
            source_label = "Live PU artifact inference"

        if pu_score is not None and math.isfinite(pu_score) and 0.0 <= pu_score <= 1.0:
            score_value = max(0, min(100, round(pu_score * 100)))
            score_payload = {
                "available": True,
                "label": "Location Fit",
                "value": score_value,
                "scale": 100,
                "raw": pu_score,
                "band": score_band(score_value),
                "meaning": SCORE_MEANING,
                "kind": "pu_association",
                "kind_label": "Location similarity to operating F&B sites",
                "source": score_source,
                "source_label": source_label,
                "stored_score_comparison": stored_comparison,
                "research_only": True,
            }
            base["score"] = score_payload
            base["availability"]["score"] = True
            base["model"] = {
                **variant,
                "artifact_sha256": artifact_digest,
                "score_source": score_source,
                "score_source_label": source_label,
            }
        else:
            base["reason"] = {
                "code": "features_missing" if resolution_error is None else "features_unresolved",
                "message": (
                    "No valid stored or live PU score is available for this property."
                ),
                "detail": resolution_error,
                "missing_features": (
                    list(coverage.missing_features) if coverage is not None else []
                ),
            }
            return base

        if coverage is None:
            base["reason"] = {
                "code": "features_unresolved",
                "message": "The score is available, but its feature vector could not be resolved for SHAP.",
                "detail": resolution_error,
            }
            return base

        if coverage.missing_features:
            base["reason"] = {
                "code": "shap_features_missing",
                "message": "The PU score is available, but SHAP is unavailable until all model features resolve.",
                "missing_features": list(coverage.missing_features),
                "source": score_source,
            }
            return base

        # The experimental model card has no separately verified matching SHAP
        # background/license lineage. Never explain it with the original
        # baseline model's background merely because the column count matches.
        if variant.get("key") == "experimental47":
            base["reason"] = {
                "code": "shap_background_unverified",
                "message": "The live experimental PU score is available; a matching licensed SHAP background is not verified.",
                "source": score_source,
                "research_only": True,
            }
            return base

        background = self._reference_background(loaded.feature_names)
        background_sha256 = self._reference_background_sha256()
        if not background or background_sha256 is None:
            base["reason"] = {
                "code": "shap_background_missing",
                "message": "The PU score is available, but no exact-feature real SHAP background could be loaded.",
                "source": score_source,
            }
            return base

        try:
            explained = ShapExplainer(
                loader=ModelLoader(), model_name=variant["layer1_model"]
            ).explain(features, background=background)
        except ModelUnavailableError as exc:
            base["reason"] = {
                "code": "shap_unavailable",
                "message": "The PU score is available, but its explanation could not be computed.",
                "detail": str(exc),
                "source": score_source,
            }
            return base

        contributions: dict[str, float] = explained["contributions"]
        base_value = float(explained["baseline_association"])
        output = float(explained["positive_label_association"])
        reconstructed = base_value + math.fsum(contributions.values())
        additivity_error = abs(reconstructed - output)
        if additivity_error > _ADDITIVITY_TOLERANCE:
            base["reason"] = {
                "code": "shap_inconsistent",
                "message": "The PU score is available, but SHAP failed its additivity check and was withheld.",
                "additivity_error": additivity_error,
                "source": score_source,
            }
            return base

        score_difference = abs(output - pu_score)
        if score_difference > _ADDITIVITY_TOLERANCE:
            base["reason"] = {
                "code": "shap_score_mismatch",
                "message": "The PU score remains available, but this SHAP output does not match it and was withheld.",
                "score_difference": score_difference,
                "source": score_source,
            }
            return base

        values = dict(coverage.values)
        ranked = sorted(contributions.items(), key=lambda kv: kv[1])
        ordered = sorted(contributions.items(), key=lambda kv: -abs(kv[1]))
        factors = [_factor(name, value, values.get(name)) for name, value in ordered]
        payload: dict[str, Any] = {
            "score": base["score"],
            "explanation": {
                "available": True,
                "explainer": explained.get("explainer"),
                "model": explained.get("model"),
                "artifact": str(loaded.meta.get("artifact_filename") or ""),
                "artifact_sha256": self._artifact_sha256(loaded.meta.get("artifact_filename")),
                "model_version": variant.get("version"),
                "background_sha256": background_sha256,
                "feature_count": len(loaded.feature_names),
                "base_value": round(base_value, 6),
                "output": round(output, 6),
                "reconstructed": round(reconstructed, 6),
                "additivity_error": additivity_error,
                "additivity_ok": True,
                "score_matches_displayed_value": True,
                "background_size": explained.get("background_size"),
                "score_meaning": explained.get("score_meaning") or SCORE_MEANING,
                "research_only": True,
                "factors": factors,
                "strongest_supporting": [
                    _factor(n, v, values.get(n)) for n, v in list(reversed(ranked))[:4] if v > 0
                ],
                "strongest_lowering": [
                    _factor(n, v, values.get(n)) for n, v in ranked[:4] if v < 0
                ],
            },
            "categories": _category_payloads(contributions, values),
            "map": {"layers": _layer_payloads(values)},
            "availability": {
                "score": True,
                "explanation": True,
                "factors": True,
                "categories": True,
            },
        }
        with _EXPLANATION_CACHE_LOCK:
            _EXPLANATION_CACHE[cache_key] = payload
        return {**base, **payload}

    def _stored_legacy_score(self, property_id: str) -> dict[str, Any] | None:
        """Read a validated original ranking score; never use it for experimental47."""
        if self.analytics is None:
            return None
        try:
            row = self.analytics.execute(
                text(
                    """
                    SELECT source_data->>'research_p_association_score' AS score,
                           source_data->>'score_type' AS score_type,
                           source_data->>'model_method' AS model_method,
                           source_data->>'model_feature_set' AS feature_set,
                           source_data->>'model_version' AS model_version
                    FROM sitewise_app.properties
                    WHERE id = :property_id
                    """
                ),
                {"property_id": property_id},
            ).mappings().first()
        except Exception:  # noqa: BLE001 - an unavailable score source stays unavailable
            return None
        if row is None or row.get("score_type") != _STORED_PU_SCORE_TYPE:
            return None
        try:
            score = float(row["score"])
        except (TypeError, ValueError):
            return None
        if not math.isfinite(score) or not 0.0 <= score <= 1.0:
            return None
        return {**dict(row), "score": score}

    @staticmethod
    def _reference_background_sha256() -> str | None:
        try:
            digest = hashlib.sha256()
            with _SHAP_BACKGROUND_CSV.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            return digest.hexdigest()
        except OSError:
            return None

    @staticmethod
    def _artifact_sha256(filename: Any) -> str | None:
        if not isinstance(filename, str) or not filename:
            return None
        path = (Path(__file__).resolve().parent.parent / "ml" / filename).resolve()
        allowed = (Path(__file__).resolve().parent.parent / "ml").resolve()
        if allowed not in path.parents or not path.is_file():
            return None
        try:
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            return digest.hexdigest()
        except OSError:
            return None

    @staticmethod
    def _reference_background(feature_names: list[str]) -> list[dict[str, float]]:
        """Load only complete, finite rows from the tracked real PU background."""
        try:
            with _SHAP_BACKGROUND_CSV.open(encoding="utf-8-sig", newline="") as stream:
                reader = csv.DictReader(stream)
                if not reader.fieldnames or not set(feature_names).issubset(reader.fieldnames):
                    return []
                rows = []
                for row in reader:
                    try:
                        values = {name: float(row[name]) for name in feature_names}
                    except (TypeError, ValueError):
                        continue
                    if all(math.isfinite(value) for value in values.values()):
                        rows.append(values)
                return rows[:100]
        except OSError:
            return []

    # -- internals ----------------------------------------------------------

    def _panorama(self, property_id: str) -> dict[str, Any]:
        """The property's completed 360° panorama, or an honest refusal.

        ``virtual_tour.property_id`` is the legacy integer key, while this
        service is keyed by the catalogue id (``MD-xxxxx``). The two are never
        compared numerically: the join goes through
        ``fyp.property_subject_links``, which carries the catalogue id and a
        ``match_verified`` flag. Without a verified link there is no panorama,
        because a numeric guess could attach another property's tour.

        A row is only reported when its status is a completed one *and* it has
        a URL. A ``pending`` or failed stitching job is reported as processing
        so the gallery can say so instead of showing a broken viewer.
        """
        unavailable = {
            "available": False,
            "status": "unavailable",
            "url": None,
            "reason": "No completed 360° panorama is linked to this property.",
        }
        if self.analytics is None:
            return unavailable

        try:
            rows = self.analytics.execute(
                text(
                    """
                    SELECT vt.url, vt.status
                    FROM fyp.property_subject_links AS l
                    JOIN public.virtual_tour AS vt ON vt.property_id = l.property_id
                    WHERE l.sitewise_property_id = :pid
                      AND l.match_verified IS TRUE
                    ORDER BY vt.updated_at DESC NULLS LAST
                    LIMIT 1
                    """
                ),
                {"pid": property_id},
            ).fetchall()
        except Exception:  # noqa: BLE001 - a missing table must not fail the page
            # The tour table is not part of every deployment; the gallery then
            # falls back to its photos-only state.
            return unavailable

        if not rows:
            return unavailable

        url, status = rows[0][0], (rows[0][1] or "").strip().lower()
        if url and status in PANORAMA_COMPLETE_STATUSES:
            return {
                "available": True,
                "status": "ready",
                "url": url,
                "reason": None,
            }
        return {
            "available": False,
            "status": "processing",
            "url": None,
            "reason": (
                "A 360° panorama for this property is still being processed, "
                "so it is not shown yet."
            ),
        }

    def _variant(self) -> dict[str, Any]:
        """The active Layer-1 variant, without ever failing the request."""
        try:
            return resolve_variant().as_dict()
        except Exception:  # noqa: BLE001 - the page must still render
            return {
                "key": "unknown",
                "layer1_model": LEGACY_MODEL_NAME,
                "name": LEGACY_MODEL_NAME,
                "version": None,
                "feature_count": None,
                "research_only": True,
                "production_ready": None,
                "score_source": "unavailable",
                "score_meaning": SCORE_MEANING,
                "notes": ["The active model variant could not be resolved."],
            }
