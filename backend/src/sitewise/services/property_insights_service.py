"""Property-scoped location insights: score, SHAP factors and five categories.

This is the read model behind the redesigned Property Detail page. It answers
three questions for one catalogue property, and nothing more:

1. **What is the location score?** The stored/derived output of the *deployed*
   PU artifact, scaled to a 0-100 index. It is a research positive-label
   association, never a probability of business success.
2. **Which features moved that score, and in which direction?** Genuine
   permutation SHAP over the property's own resolved 47-feature vector, against
   a real background matrix. Additivity is verified before anything is
   returned: an explanation that cannot reconstruct the score is withheld.
3. **What does that mean per category?** The same contributions grouped into
   the five categories the page presents, with entrepreneur-facing labels.

Design constraints enforced here
================================
* **No fabrication.** Every number is either resolved from the database, read
  from the deployed artifact, or computed by SHAP. Missing inputs produce
  ``available: false`` with a stable reason code, never a placeholder score.
* **No raw column names reach the UI.** ``FEATURE_LABELS`` maps all 47 model
  features to plain English; the technical name is retained under
  ``technical`` for the optional explanation and for authorised consumers.
* **One artifact, one explanation.** The service loads whichever artifact
  ``SITEWISE_PU_MODEL_VARIANT`` selects and stamps its version into the
  payload. A cached explanation is only reused for the same model version, so
  swapping the artifact can never surface a stale explanation.
* **SHAP is cached, not recomputed per request.** Permutation SHAP costs
  roughly 13 s for 47 features; a page load cannot pay that repeatedly. The
  cache is keyed by ``(model_version, property_id)``.
"""

from __future__ import annotations

import threading
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.exceptions import ModelUnavailableError
from sitewise.ml.model_loader import ModelLoader
from sitewise.ml.property_features import FeatureResolutionError, PropertyFeatureRepository
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
        """The full insight payload. Never raises for an unavailable model.

        ``origin`` is the property's own coordinate, supplied by the caller
        from the catalogue row. It is echoed back so the map centres on the
        same point the score describes, instead of re-deriving it.
        """
        variant = self._variant()
        base: dict[str, Any] = {
            "property_id": property_id,
            "model": variant,
            "origin": origin,
            "map": {
                "layers": _layer_payloads({}, measured=False),
            },
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
                "message": "The trained location model is not available, so no score can be shown.",
                "detail": str(exc),
            }
            return base

        cache_key = (str(variant.get("version") or variant["layer1_model"]), property_id)
        with _EXPLANATION_CACHE_LOCK:
            cached = _EXPLANATION_CACHE.get(cache_key)
        if cached is not None:
            return {**base, **cached}

        repo = PropertyFeatureRepository(self.analytics)
        try:
            bundle = repo.get(property_id, loaded.feature_names, source="catalog")
        except FeatureResolutionError as exc:
            base["reason"] = {
                "code": "features_unresolved",
                "message": "This property has no usable location measurements yet.",
                "detail": str(exc),
            }
            return base

        if bundle.missing_features:
            base["reason"] = {
                "code": "features_missing",
                "message": (
                    f"{len(bundle.missing_features)} of {len(loaded.feature_names)} "
                    "location measurements are missing, so no score can be shown."
                ),
                "missing_features": list(bundle.missing_features),
            }
            return base

        background = repo.background(loaded.feature_names, limit=50)
        if not background:
            base["reason"] = {
                "code": "shap_background_missing",
                "message": "There are no comparable analysed locations to explain this score against.",
            }
            return base

        features: dict[str, float] = {
            name: float(value)  # type: ignore[arg-type]
            for name, value in bundle.values.items()
            if value is not None
        }

        try:
            explained = ShapExplainer(loader=ModelLoader(), model_name=variant["layer1_model"]).explain(
                features, background=background
            )
        except ModelUnavailableError as exc:
            base["reason"] = {
                "code": "shap_unavailable",
                "message": "The score could be computed but its explanation could not be.",
                "detail": str(exc),
            }
            return base

        contributions: dict[str, float] = explained["contributions"]
        base_value = float(explained["baseline_association"])
        output = float(explained["positive_label_association"])
        reconstructed = base_value + sum(contributions.values())

        # Additivity is the guard that the explanation describes THIS score.
        if abs(reconstructed - output) > _ADDITIVITY_TOLERANCE:
            base["reason"] = {
                "code": "shap_inconsistent",
                "message": "The explanation did not reconstruct the score, so it was withheld.",
            }
            return base

        values: dict[str, float | None] = dict(bundle.values)
        score_value = max(0, min(100, round(output * 100)))

        ranked = sorted(contributions.items(), key=lambda kv: kv[1])
        # Most influential first, regardless of direction. Ordering by signed
        # value would put every positive factor ahead of every negative one, so
        # a chart showing "the top N" would never display what pulled the score
        # down — the half of the explanation the page exists to show.
        ordered = sorted(contributions.items(), key=lambda kv: -abs(kv[1]))
        factors = [_factor(name, value, values.get(name)) for name, value in ordered]

        payload: dict[str, Any] = {
            "score": {
                "available": True,
                "label": "Location Fit",
                "value": score_value,
                "scale": 100,
                "raw": round(output, 6),
                "band": score_band(score_value),
                "meaning": SCORE_MEANING,
                "kind": "pu_association",
                "kind_label": "Location similarity to operating F&B sites",
                "research_only": True,
            },
            "explanation": {
                "available": True,
                "explainer": explained.get("explainer"),
                "model": explained.get("model"),
                "model_version": variant.get("version"),
                "feature_count": len(loaded.feature_names),
                "base_value": round(base_value, 6),
                "output": round(output, 6),
                "reconstructed": round(reconstructed, 6),
                "additivity_ok": True,
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
