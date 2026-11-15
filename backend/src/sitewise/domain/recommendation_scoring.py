"""Layer 2 - transparent, versioned, rule-based preference scoring.

This module is NOT a trained recommender. It is a deterministic scoring engine
whose weights, thresholds and formula are versioned in :data:`SCORING_CONFIG`
and reported with every API result. It consumes the Layer 1 PU *research
association score* (never a success probability) plus the entrepreneur's saved
business preferences and the property's verified characteristics.

Design rules
============

* Every sub-score is normalised to ``[0, 1]`` or is ``None``. ``None`` means
  "the required input is unknown", which is materially different from 0
  ("known to be a bad fit"). Unknown components are EXCLUDED from the weighted
  mean and the remaining weights are renormalised, so a listing is never
  penalised for data the product does not hold.
* Nothing is invented: no fabricated ``recommender.joblib``, no synthetic
  labels, no zero-filling of missing frontage, parking or accessibility.
* Ranking is deterministic: an explicit total-order key ending in the
  catalogue id makes ties stable regardless of database row order.
* The 70/30 combination is a configurable *research baseline*. It has not
  been fitted or validated against business outcomes.

Clean Architecture: this module has no framework, ORM or HTTP dependencies.
"""
from __future__ import annotations

import math
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any

SCORING_CONFIG_VERSION = "sitewise_rule_based_preference_v1"
#: Five-question Recommender V3 (2026-11-11). Version string and calibration
#: constants are the serialized snapshot's own values (see
#: ``sitewise.ml.sitewise_recommender_v3``), not invented here.
SCORING_CONFIG_V3_VERSION = "sitewise_rule_based_5q_dosm_v3_2026_11_11"
SCORE_MEANING = (
    "Rule-based preference match combined with an uncalibrated P-vs-U research "
    "association index. NOT a success probability, NOT a trained recommender."
)

COMPONENT_NAMES: tuple[str, ...] = (
    "budget_fit",
    "size_fit",
    "property_type_fit",
    "target_market_fit",
    "accessibility_fit",
    "parking_fit",
    "competition_fit",
    "physical_fit",
)


@dataclass(frozen=True)
class ScoringWeights:
    """Research baseline from the integration specification (section 5)."""

    budget_fit: float = 0.20
    size_fit: float = 0.15
    property_type_fit: float = 0.10
    target_market_fit: float = 0.20
    accessibility_fit: float = 0.10
    parking_fit: float = 0.10
    competition_fit: float = 0.10
    physical_fit: float = 0.05

    def as_dict(self) -> dict[str, float]:
        return {name: float(getattr(self, name)) for name in COMPONENT_NAMES}


@dataclass(frozen=True)
class ScoringConfig:
    """Immutable, versioned scoring configuration.

    Changing ANY field requires a new ``version`` string, because clients cache
    and display the version alongside the score.
    """

    version: str = SCORING_CONFIG_VERSION
    weights: ScoringWeights = field(default_factory=ScoringWeights)
    pu_weight: float = 0.70
    preference_weight: float = 0.30
    # rent <= max -> 1.0; rent >= max * (1 + tolerance) -> 0.0
    budget_overshoot_tolerance: float = 0.50
    # A stated MINIMUM floor area is a floor, not a target: larger units are
    # only penalised when the entrepreneur also states an explicit MAXIMUM.
    # Saturating scales for count/density style signals (0 -> 1 asymptotically).
    population_scale: float = 25_000.0
    office_scale: float = 12.0
    education_scale: float = 8.0
    transit_stop_scale: float = 6.0
    parking_scale: float = 8.0
    walk_isochrone_scale: float = 1.5
    # Physical attributes (verified columns only; saturating scales in feet).
    frontage_scale: float = 20.0
    depth_scale: float = 60.0
    # Competition: <= low -> 1.0, >= high -> 0.0.
    competition_low: float = 10.0
    competition_high: float = 60.0
    # Distance fits: <= near -> 1.0, >= far -> 0.0.
    transit_near_m: float = 200.0
    transit_far_m: float = 1_500.0
    parking_near_m: float = 100.0
    parking_far_m: float = 1_000.0
    # A component at/above this is described as a strength, at/below the other
    # as a concern; everything between is neutral.
    strength_threshold: float = 0.65
    concern_threshold: float = 0.35

    def __post_init__(self) -> None:
        total = sum(self.weights.as_dict().values())
        if not math.isclose(total, 1.0, abs_tol=1e-9):
            raise ValueError(f"Component weights must sum to 1.0, got {total}")
        if not math.isclose(self.pu_weight + self.preference_weight, 1.0, abs_tol=1e-9):
            raise ValueError("PU and preference weights must sum to 1.0")
        for name, weight in self.weights.as_dict().items():
            if not 0.0 <= weight <= 1.0:
                raise ValueError(f"Weight {name} is out of range")
        if not 0.0 <= self.pu_weight <= 1.0:
            raise ValueError("PU weight is out of range")

    def as_dict(self) -> dict[str, Any]:
        return {
            "version": self.version,
            "engine": "rule_based",
            "trained_recommender": False,
            "weights": self.weights.as_dict(),
            "final_score_formula": (
                "final = pu_weight * pu_association_score + "
                "preference_weight * preference_match_score"
            ),
            "pu_weight": self.pu_weight,
            "preference_weight": self.preference_weight,
            "preference_score_formula": (
                "preference = sum(w_i * component_i) / sum(w_i) over components "
                "with known values (unknown components are excluded, never zero-filled)"
            ),
            "missing_data_policy": "exclude_and_renormalise",
            "score_meaning": SCORE_MEANING,
            "validated_optimal": False,
            "note": (
                "Configurable research baseline. The 70/30 split and component "
                "weights have NOT been fitted to, or validated against, business "
                "outcomes."
            ),
        }


SCORING_CONFIG = ScoringConfig()


# ---------------------------------------------------------------------------
# Input contracts
# ---------------------------------------------------------------------------


def _text(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    cleaned = value.strip()
    return cleaned or None


def _num(value: Any) -> float | None:
    """Strict numeric coercion; unknown / non-finite becomes None, never 0."""
    if value is None or isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _tokens(value: Any) -> tuple[str, ...]:
    if isinstance(value, str):
        items = [value]
    elif isinstance(value, (list, tuple, set)):
        items = [x for x in value if isinstance(x, str)]
    else:
        return ()
    out: list[str] = []
    for item in items:
        token = item.strip().lower()
        if token and token not in out:
            out.append(token)
    return tuple(out)


#: v2 fnb_concept tokens -> business-language labels used in explanations.
CONCEPT_LABELS: dict[str, str] = {
    "cafe_coffee_shop": "cafe / coffee shop",
    "restaurant": "restaurant",
    "bakery_dessert_shop": "bakery / dessert shop",
    "fast_food_quick_service": "fast food / quick service",
    "beverage_shop_kiosk": "beverage shop / kiosk",
    "other_fnb": "F&B",
}

#: v2 recommendation_priority -> competition tolerance. Documented mapping,
#: not a learned parameter.
PRIORITY_TO_COMPETITION_TOLERANCE: dict[str, str] = {
    "favorable_competition": "low",
    "balanced_suitability": "moderate",
    "high_customer_demand": "high",
    "affordable_operating_location": "moderate",
    "easy_customer_accessibility": "moderate",
}


@dataclass(frozen=True)
class PreferenceProfile:
    """Normalised view over the stored v1/v2 business preferences."""

    preferences_version: int
    business_category: str | None = None
    fnb_concept: str | None = None
    service_model: str | None = None
    recommendation_priority: str | None = None
    target_price_segment: str | None = None
    customer_access_mode: str | None = None
    target_customers: tuple[str, ...] = ()
    max_rent_myr: float | None = None
    min_rent_myr: float | None = None
    min_floor_area_sqft: float | None = None
    max_floor_area_sqft: float | None = None
    preferred_property_types: tuple[str, ...] = ()
    preferred_states: tuple[str, ...] = ()
    preferred_districts: tuple[str, ...] = ()
    physical_requirements: tuple[str, ...] = ()
    parking_requirements: tuple[str, ...] = ()
    accessibility_requirements: tuple[str, ...] = ()
    competition_tolerance: str | None = None
    #: Q5 of the five-question V3 questionnaire. One of
    #: :data:`SPACE_SIZE_PREFERENCE_V3` (``None`` = not stated / pre-V3 record).
    space_size_preference: str | None = None
    raw: dict = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "preferences_version": self.preferences_version,
            "business_category": self.business_category,
            "fnb_concept": self.fnb_concept,
            "service_model": self.service_model,
            "recommendation_priority": self.recommendation_priority,
            "target_price_segment": self.target_price_segment,
            "customer_access_mode": self.customer_access_mode,
            "target_customers": list(self.target_customers),
            "max_rent_myr": self.max_rent_myr,
            "min_rent_myr": self.min_rent_myr,
            "min_floor_area_sqft": self.min_floor_area_sqft,
            "max_floor_area_sqft": self.max_floor_area_sqft,
            "preferred_property_types": list(self.preferred_property_types),
            "preferred_states": list(self.preferred_states),
            "preferred_districts": list(self.preferred_districts),
            "physical_requirements": list(self.physical_requirements),
            "parking_requirements": list(self.parking_requirements),
            "accessibility_requirements": list(self.accessibility_requirements),
            "competition_tolerance": self.competition_tolerance,
            "space_size_preference": self.space_size_preference,
        }


def preference_profile_from(stored: Mapping[str, Any] | None) -> PreferenceProfile:
    """Map the ONE stored preference vocabulary (v1/v2/v3) to a profile.

    The assessment workspace and ``/preferences/me`` already share
    ``validate_requirements``; this mapper reads that validated payload and
    does not introduce a second vocabulary. v3 numeric keys take precedence;
    v2/v1 equivalents are used only when the v3 key is absent.
    """
    raw = dict(stored or {})
    version = raw.get("requirements_version")
    if version not in (1, 2, 3):
        version = (
            3 if "space_size_preference" in raw
            else 2 if any(k in raw for k in ("fnb_concept", "max_monthly_rent_myr", "target_customers"))
            else 1
        )

    max_rent = _num(raw.get("max_monthly_rent_myr"))
    if max_rent is None:
        max_rent = _num(raw.get("max_budget_rm"))
    min_rent = _num(raw.get("min_budget_rm"))
    min_size = _num(raw.get("min_floor_area_sqft"))
    if min_size is None:
        min_size = _num(raw.get("min_size_sqft"))
    max_size = _num(raw.get("max_size_sqft"))

    requirements = _tokens(raw.get("requirements"))
    areas = _tokens(raw.get("preferred_areas"))
    target_market = _text(raw.get("target_market"))

    # Free-text requirement tokens are classified by explicit keywords only;
    # an unrecognised token is kept as a physical requirement and reported as
    # unverifiable rather than silently treated as a match.
    parking_tokens = tuple(t for t in requirements if "parking" in t or "car park" in t)
    access_tokens = tuple(
        t for t in requirements
        if any(k in t for k in ("access", "walk", "transit", "transport", "lift", "wheelchair"))
    )
    physical_tokens = tuple(
        t for t in requirements
        if t not in parking_tokens and t not in access_tokens
    )

    concept = _text(raw.get("fnb_concept"))
    business_category = CONCEPT_LABELS.get(concept or "", None) or _text(raw.get("business_type"))
    priority = _text(raw.get("recommendation_priority"))

    target_customers = list(_tokens(raw.get("target_customers")))
    if target_market:
        lowered = target_market.lower()
        for token, keywords in (
            ("office_workers", ("office", "worker", "corporate")),
            ("students", ("student", "campus", "college", "universit")),
            ("commuters", ("commuter", "transit", "travel")),
            ("nearby_residents", ("resident", "neighbour", "neighbor", "local")),
        ):
            if any(k in lowered for k in keywords) and token not in target_customers:
                target_customers.append(token)

    preferred_states = list(_tokens(raw.get("preferred_states")))
    preferred_districts = list(areas)
    state = _text(raw.get("preferred_state"))
    if state and state.lower() not in preferred_states:
        preferred_states.append(state.lower())

    return PreferenceProfile(
        preferences_version=version,
        business_category=business_category,
        fnb_concept=concept,
        service_model=_text(raw.get("service_model")),
        recommendation_priority=priority,
        target_price_segment=_text(raw.get("target_price_segment")),
        customer_access_mode=_text(raw.get("customer_access_mode")),
        target_customers=tuple(target_customers),
        max_rent_myr=max_rent,
        min_rent_myr=min_rent,
        min_floor_area_sqft=min_size,
        max_floor_area_sqft=max_size,
        preferred_property_types=_tokens(raw.get("property_type")),
        preferred_states=tuple(preferred_states),
        preferred_districts=tuple(preferred_districts),
        physical_requirements=physical_tokens,
        parking_requirements=parking_tokens,
        accessibility_requirements=access_tokens,
        competition_tolerance=PRIORITY_TO_COMPETITION_TOLERANCE.get(priority or "", None),
        space_size_preference=_text(raw.get("space_size_preference")),
        raw=raw,
    )


@dataclass(frozen=True)
class PropertyCandidate:
    """Verified property + geospatial characteristics in canonical names.

    ``None`` is an explicitly unknown value. Field-name provenance is
    documented in ``RecommendationCandidateRepository``; production DB column
    names differ from the research workbook names and are mapped there.
    """

    property_id: str
    title: str = ""
    address: str = ""
    city: str = ""
    state: str = ""
    district: str = ""
    postcode: str = ""
    property_type: str | None = None
    monthly_rental_myr: float | None = None
    built_up_sqft: float | None = None
    floor_level: float | None = None
    floor_level_text: str | None = None
    unit_position: str | None = None
    frontage_ft: float | None = None
    depth_ft: float | None = None
    latitude: float | None = None
    longitude: float | None = None
    image_url: str | None = None
    population_500m: float | None = None
    population_1000m: float | None = None
    office_pois_500m: float | None = None
    schools_count_500m: float | None = None
    universities_count_500m: float | None = None
    malls_count_500m: float | None = None
    fnb_competitors_500m: float | None = None
    fnb_competitors_1000m: float | None = None
    cafe_count_500m: float | None = None
    restaurant_count_500m: float | None = None
    fast_food_count_500m: float | None = None
    bakery_count_500m: float | None = None
    bus_stops_500m_walk: float | None = None
    rail_stations_1km_walk: float | None = None
    nearest_transit_walk_m: float | None = None
    walk_isochrone_area_10min_km2: float | None = None
    nearest_major_road_m: float | None = None
    parking_facilities_500m: float | None = None
    nearest_parking_distance_m: float | None = None
    parking_status: str | None = None
    building_footprint_density_500m: float | None = None
    pu_association_score: float | None = None
    pu_model_method: str | None = None
    pu_feature_set: str | None = None
    pu_score_type: str | None = None
    pu_score_source: str | None = None
    sample_class: str | None = None
    availability_status: str | None = None
    analysis_status: str | None = None
    data_completeness_pct: float | None = None
    coordinate_quality: str | None = None
    reference_coverage: str | None = None
    #: Verified mapping to the commercial listing entity (bigint) the
    # explore/detail routes navigate with; ``None`` = research-only row.
    listing_ref: dict | None = None
    verification: dict = field(default_factory=dict)

    @classmethod
    def from_row(cls, row: Mapping[str, Any]) -> PropertyCandidate:
        known = cls.__dataclass_fields__.keys()
        payload = {k: row[k] for k in known if k in row and k != "verification"}
        # Numeric columns are coerced strictly; everything else passes as text.
        numeric = {
            "monthly_rental_myr", "built_up_sqft", "floor_level", "frontage_ft", "depth_ft",
            "latitude", "longitude", "population_500m", "population_1000m",
            "office_pois_500m", "schools_count_500m", "universities_count_500m",
            "malls_count_500m", "fnb_competitors_500m", "fnb_competitors_1000m",
            "cafe_count_500m", "restaurant_count_500m", "fast_food_count_500m",
            "bakery_count_500m", "bus_stops_500m_walk", "rail_stations_1km_walk",
            "nearest_transit_walk_m", "walk_isochrone_area_10min_km2",
            "nearest_major_road_m", "parking_facilities_500m",
            "nearest_parking_distance_m", "building_footprint_density_500m",
            "pu_association_score", "data_completeness_pct",
        }
        for name in numeric:
            if name in payload:
                payload[name] = _num(payload[name])
        payload["property_id"] = str(row.get("property_id") or "")
        payload["verification"] = dict(row.get("verification") or {})
        return cls(**payload)


# ---------------------------------------------------------------------------
# Eligibility (hard filters)
# ---------------------------------------------------------------------------

#: Explicitly unavailable listings are excluded. ``UNKNOWN_NOT_VERIFIED`` is
#: NOT treated as available: it is allowed into the research ranking but every
#: result carries ``confirmed_available: false`` plus a caution.
_UNAVAILABLE_STATUSES = frozenset({
    "unavailable", "not_available", "rented", "let", "taken", "closed",
    "withdrawn", "expired", "sold",
})


def eligibility_failures(
    candidate: PropertyCandidate, profile: PreferenceProfile
) -> list[str]:
    """Reasons this property MUST NOT enter the personalised ranking.

    Applied before scoring, so an ineligible property can never be presented
    as a recommendation. Unknown data that is *required* (rent, size, PU
    score) is a rejection, not a zero-valued score.
    """
    failures: list[str] = []

    rent = candidate.monthly_rental_myr
    size = candidate.built_up_sqft
    if rent is None or rent <= 0:
        failures.append("monthly_rent_missing_or_invalid")
    if size is None or size <= 0:
        failures.append("built_up_sqft_missing_or_invalid")
    score = candidate.pu_association_score
    if score is None or not 0.0 <= score <= 1.0:
        failures.append("pu_association_score_missing_or_invalid")

    status = (candidate.availability_status or "").strip().lower()
    if status in _UNAVAILABLE_STATUSES:
        failures.append("listing_explicitly_unavailable")
    if (candidate.sample_class or "").strip().upper() not in {"", "U"}:
        failures.append("not_an_unlabeled_commercial_property")
    if candidate.analysis_status and candidate.analysis_status.strip().upper() != "COMPLETED":
        failures.append("analysis_not_completed")
    if candidate.verification.get("verified") is False:
        failures.append("listing_verification_rejected")

    if profile.max_rent_myr is not None and rent is not None and rent > profile.max_rent_myr:
        failures.append("over_maximum_rental_budget")
    if profile.min_rent_myr is not None and rent is not None and rent < profile.min_rent_myr:
        failures.append("under_minimum_rental_budget")
    if (
        profile.min_floor_area_sqft is not None
        and size is not None
        and size < profile.min_floor_area_sqft
    ):
        failures.append("below_minimum_floor_area")
    if (
        profile.max_floor_area_sqft is not None
        and size is not None
        and size > profile.max_floor_area_sqft
    ):
        failures.append("above_maximum_floor_area")

    if profile.preferred_states:
        state = (candidate.state or "").strip().lower()
        if not state or not any(s in state or state in s for s in profile.preferred_states):
            failures.append("outside_preferred_state")
    if profile.preferred_districts:
        haystacks = [
            (candidate.district or "").lower(),
            (candidate.city or "").lower(),
            (candidate.address or "").lower(),
        ]
        if not any(
            any(token in text for text in haystacks) for token in profile.preferred_districts
        ):
            failures.append("outside_preferred_area")
    return failures


# ---------------------------------------------------------------------------
# Component scoring
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ComponentResult:
    name: str
    value: float | None
    status: str  # "scored" | "unknown"
    reason: str
    caution: str | None = None
    evidence: dict = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "value": self.value,
            "status": self.status,
            "reason": self.reason,
            "caution": self.caution,
            "evidence": self.evidence,
        }


def _clamp01(value: float) -> float:
    return max(0.0, min(1.0, float(value)))


def _saturating(value: float | None, scale: float) -> float | None:
    if value is None or scale <= 0:
        return None
    return _clamp01(1.0 - math.exp(-max(0.0, value) / scale))


def _distance_fit(value: float | None, near: float, far: float) -> float | None:
    if value is None or far <= near:
        return None
    return _clamp01((far - max(0.0, value)) / (far - near))


def _unknown(name: str, reason: str, caution: str) -> ComponentResult:
    return ComponentResult(name, None, "unknown", reason, caution)


def _scored(
    name: str, value: float | None, reason: str, evidence: dict, caution: str | None = None
) -> ComponentResult:
    if value is None:
        return _unknown(name, reason, caution or "Required inputs are unavailable.")
    if not 0.0 <= value <= 1.0:
        raise ValueError(f"Component {name} produced an out-of-range value {value}")
    return ComponentResult(name, _clamp01(value), "scored", reason, caution, evidence)


def _budget_fit(c: PropertyCandidate, p: PreferenceProfile, cfg: ScoringConfig) -> ComponentResult:
    rent, maximum = c.monthly_rental_myr, p.max_rent_myr
    if rent is None or maximum is None or maximum <= 0:
        return _unknown(
            "budget_fit",
            "Budget fit was not scored.",
            "Monthly rent or maximum budget is unknown; budget fit is not treated as zero.",
        )
    if rent <= maximum:
        minimum = p.min_rent_myr
        if minimum and minimum > 0 and rent < minimum:
            value = _clamp01(0.5 + 0.5 * (rent / minimum))
            reason = f"RM{rent:,.0f}/month is below your stated minimum of RM{minimum:,.0f}."
        else:
            value = 1.0
            reason = (
                f"RM{rent:,.0f}/month is within your RM{maximum:,.0f} maximum budget "
                f"(RM{maximum - rent:,.0f} headroom)."
            )
    else:
        overshoot = (rent - maximum) / (maximum * cfg.budget_overshoot_tolerance)
        value = _clamp01(1.0 - overshoot)
        reason = f"RM{rent:,.0f}/month exceeds your RM{maximum:,.0f} maximum budget."
    return _scored(
        "budget_fit", value, reason,
        {"monthly_rental_myr": rent, "max_budget_myr": maximum, "min_budget_myr": p.min_rent_myr},
    )


def _size_fit(c: PropertyCandidate, p: PreferenceProfile, _cfg: ScoringConfig) -> ComponentResult:
    size, minimum = c.built_up_sqft, p.min_floor_area_sqft
    if size is None or minimum is None or minimum <= 0:
        return _unknown(
            "size_fit",
            "Floor-area fit was not scored.",
            "Built-up area or minimum floor area is unknown; size fit is not treated as zero.",
        )
    if size < minimum:
        value = _clamp01(size / minimum)
        reason = f"{size:,.0f} sq ft is below the {minimum:,.0f} sq ft minimum."
    elif p.max_floor_area_sqft and size > p.max_floor_area_sqft:
        excess = (size - p.max_floor_area_sqft) / max(1.0, p.max_floor_area_sqft)
        value = _clamp01(1.0 - excess)
        reason = f"{size:,.0f} sq ft exceeds the {p.max_floor_area_sqft:,.0f} sq ft maximum."
    else:
        value = 1.0
        reason = (
            f"{size:,.0f} sq ft meets the {minimum:,.0f} sq ft minimum floor area"
            + (" and the stated maximum." if p.max_floor_area_sqft else ".")
        )
    return _scored(
        "size_fit", value, reason,
        {"built_up_sqft": size, "min_floor_area_sqft": minimum,
         "max_floor_area_sqft": p.max_floor_area_sqft},
    )


#: Common tokens shared between the questionnaire's free text and the three
#: catalogue property_type values, so a "Shop lot" preference can match
#: "Shophouse / Shop-office". This is a documented lexical mapping, not a
#: learned similarity.
_TYPE_TOKENS = {
    "shop": {"shop", "lot", "retail", "shophouse", "shoplot", "store"},
    "office": {"office", "shop-office", "soho", "commercial"},
    "ground": {"ground", "ground floor"},
}


def _property_type_fit(c: PropertyCandidate, p: PreferenceProfile, _cfg: ScoringConfig) -> ComponentResult:
    actual = (c.property_type or "").strip().lower()
    requested = p.preferred_property_types
    if not actual or not requested:
        return _unknown(
            "property_type_fit",
            "Property-type fit was not scored.",
            "Preferred property type or the listing's property type is unknown; "
            "property-type fit is not treated as zero.",
        )
    actual_tokens = {t.strip() for t in actual.replace("/", " ").replace("-", " ").split()}
    best = 0.0
    for wanted in requested:
        wanted = wanted.strip().lower()
        if not wanted:
            continue
        if wanted in actual or actual in wanted:
            best = 1.0
            break
        expanded = set(wanted.replace("-", " ").split()) | {
            token for key, tokens in _TYPE_TOKENS.items() if key in wanted for token in tokens
        }
        overlap = len(expanded & actual_tokens)
        if overlap:
            # Partial credit is the share of the ACTUAL type's tokens explained
            # by the preference, capped below an exact match. Dividing by the
            # overlap itself (an earlier mistake) always returned a constant.
            partial = _clamp01(overlap / max(1, len(actual_tokens))) * 0.8
            best = max(best, partial)
    reason = (
        f"Property type '{c.property_type}' matches your '{', '.join(requested)}' preference."
        if best >= 0.65
        else f"Property type '{c.property_type}' only partially matches your "
             f"'{', '.join(requested)}' preference."
    )
    return _scored(
        "property_type_fit", best, reason,
        {"property_type": c.property_type, "preferred": list(requested)},
    )


def _target_market_fit(c: PropertyCandidate, p: PreferenceProfile, cfg: ScoringConfig) -> ComponentResult:
    """Business-concept + target-customer fit against demand generators."""
    signals: list[tuple[float, str]] = []

    def add(value: float | None, scale: float, label: str) -> None:
        fit = _saturating(value, scale)
        if fit is not None:
            signals.append((fit, f"{label}={value:,.0f}"))

    customers = set(p.target_customers)
    concept = p.fnb_concept or ""

    # Nearby residents / general public -> resident population.
    if customers & {"nearby_residents", "general_public"} or concept in {
        "cafe_coffee_shop", "restaurant", "bakery_dessert_shop", ""
    }:
        add(c.population_500m, cfg.population_scale, "population_500m")
        add(c.population_1000m, cfg.population_scale * 3, "population_1000m")
    # Office workers -> office POIs.
    if "office_workers" in customers or concept in {"cafe_coffee_shop", "fast_food_quick_service"}:
        add(c.office_pois_500m, cfg.office_scale, "office_pois_500m")
    # Students -> schools, colleges, universities.
    if "students" in customers or concept in {"bakery_dessert_shop", "beverage_shop_kiosk"}:
        add(c.schools_count_500m, cfg.education_scale, "schools_500m")
        add(c.universities_count_500m, cfg.education_scale, "universities_500m")
    # Commuters -> transit + malls.
    if "commuters" in customers or concept in {"fast_food_quick_service", "beverage_shop_kiosk"}:
        add(c.bus_stops_500m_walk, cfg.transit_stop_scale, "bus_stops_500m")
        add(c.malls_count_500m, cfg.education_scale, "malls_500m")
    # Concept-specific same-category competitors are a demand signal of a
    # proven F&B market (distinct from the competition_fit penalty).
    same_category = {
        "cafe_coffee_shop": c.cafe_count_500m,
        "restaurant": c.restaurant_count_500m,
        "fast_food_quick_service": c.fast_food_count_500m,
        "bakery_dessert_shop": c.bakery_count_500m,
    }.get(concept)
    if same_category is not None:
        add(same_category, cfg.office_scale, "same_category_outlets_500m")

    if not signals:
        return _unknown(
            "target_market_fit",
            "Target-market fit was not scored.",
            "No verified demand-generator measurements are available for this "
            "listing and your target customers; absence is not treated as zero demand.",
        )
    value = math.fsum(s[0] for s in signals) / len(signals)
    label = CONCEPT_LABELS.get(concept, p.business_category or "your F&B concept")
    audience = ', '.join(sorted(customers)) or 'not specified'
    if value <= cfg.concern_threshold:
        reason = (
            f"Nearby demand-generator measurements are weak for {label} and your "
            f"target customers ({audience})."
        )
    elif value >= cfg.strength_threshold:
        reason = (
            f"Nearby demand generators are consistent with {label} and your "
            f"target customers ({audience})."
        )
    else:
        reason = (
            f"Nearby demand generators were measured for {label} and your "
            f"target customers ({audience}) with mixed results."
        )
    return _scored(
        "target_market_fit", value, reason,
        {"signals": [label for _, label in signals], "target_customers": sorted(customers),
         "fnb_concept": concept or None},
    )


def _accessibility_fit(c: PropertyCandidate, p: PreferenceProfile, cfg: ScoringConfig) -> ComponentResult:
    mode = (p.customer_access_mode or "").lower()
    signals: list[tuple[float, str]] = []

    transit_distance = _distance_fit(
        c.nearest_transit_walk_m, cfg.transit_near_m, cfg.transit_far_m
    )
    stops = _saturating(c.bus_stops_500m_walk, cfg.transit_stop_scale)
    rail = _saturating(c.rail_stations_1km_walk, cfg.transit_stop_scale / 2)
    walk = _saturating(c.walk_isochrone_area_10min_km2, cfg.walk_isochrone_scale)
    road = _distance_fit(c.nearest_major_road_m, 50.0, 1_000.0)

    if mode in {"walking", "mixed_transportation", ""}:
        for value, label in ((walk, "walk_10min_area"), (transit_distance, "nearest_transit")):
            if value is not None:
                signals.append((value, label))
    if mode in {"public_transportation", "mixed_transportation", ""}:
        for value, label in ((stops, "bus_stops_500m"), (rail, "rail_1km"),
                            (transit_distance, "nearest_transit")):
            if value is not None:
                signals.append((value, label))
    if mode in {"private_vehicle", "mixed_transportation", ""} and road is not None:
        signals.append((road, "nearest_major_road"))

    if not signals:
        return _unknown(
            "accessibility_fit",
            "Accessibility fit was not scored.",
            "Walkability / transit measurements are unavailable for this listing; "
            "unknown access is not treated as zero access.",
        )
    value = math.fsum(s[0] for s in signals) / len(signals)
    reason = (
        f"Transport and walkability indicators support "
        f"{mode.replace('_', ' ') if mode else 'general customer'} access."
    )
    return _scored(
        "accessibility_fit", value, reason,
        {"signals": [label for _, label in signals], "customer_access_mode": mode or None},
    )


def _parking_fit(c: PropertyCandidate, p: PreferenceProfile, cfg: ScoringConfig) -> ComponentResult:
    facilities = _saturating(c.parking_facilities_500m, cfg.parking_scale)
    distance = _distance_fit(
        c.nearest_parking_distance_m, cfg.parking_near_m, cfg.parking_far_m
    )
    signals = [(v, label) for v, label in ((facilities, "parking_facilities_500m"),
                                           (distance, "nearest_parking_distance_m"))
               if v is not None]
    if not signals:
        return _unknown(
            "parking_fit",
            "Parking fit was not scored.",
            "Parking provision is unverified for this listing; unknown parking "
            "is NOT treated as zero parking.",
        )
    value = math.fsum(s[0] for s in signals) / len(signals)
    reason = (
        "Nearby parking facilities support your parking requirement."
        if p.parking_requirements and value >= cfg.strength_threshold
        else "Nearby parking provision was measured from the research feature set."
    )
    caution = None
    if c.parking_status and c.parking_status.strip().lower() not in {"ok", "complete", "completed"}:
        caution = f"Parking feature status is '{c.parking_status}'; verify before relying on it."
    return _scored("parking_fit", value, reason,
                   {"signals": [label for _, label in signals], "parking_status": c.parking_status},
                   caution)


def _competition_fit(c: PropertyCandidate, p: PreferenceProfile, cfg: ScoringConfig) -> ComponentResult:
    competitors = c.fnb_competitors_500m
    if competitors is None:
        competitors = c.fnb_competitors_1000m
    if competitors is None or p.competition_tolerance is None:
        caution = (
            "No nearby-competitor measurement is available for this listing; "
            "unknown competition is not treated as zero competition."
            if competitors is None else
            "No competition tolerance was expressed in the saved preferences; "
            "competition fit is excluded rather than assumed."
        )
        return _unknown("competition_fit", "Competition fit was not scored.", caution)

    tolerance = p.competition_tolerance
    low = cfg.competition_low * {"low": 0.6, "moderate": 1.0, "high": 1.8}[tolerance]
    high = cfg.competition_high * {"low": 0.7, "moderate": 1.0, "high": 1.5}[tolerance]
    value = _clamp01((high - max(0.0, competitors)) / max(1e-9, high - low))
    reason = (
        f"{competitors:,.0f} nearby F&B outlets within 500 m against a "
        f"'{tolerance}' competition tolerance."
    )
    return _scored(
        "competition_fit", value, reason,
        {"fnb_competitors_500m": competitors, "tolerance": tolerance},
    )


def _physical_fit(c: PropertyCandidate, p: PreferenceProfile, cfg: ScoringConfig) -> ComponentResult:
    """Physical suitability from VERIFIED physical columns only.

    The imported catalogue's typed columns carry no physical attributes, but
    ``subject_features.other_features`` does for a subset of rows
    (``property_frontage_ft``, ``property_depth_ft``, ``property_floor_level``,
    ``property_unit_position``). Only those recorded values are used. Rows
    without them return ``unknown`` (weight excluded), NEVER 0, and are called
    out in a caution. Free-text physical requirements are checked against the
    recorded labels by explicit keywords; anything unmatched stays UNVERIFIED.
    """
    signals: list[tuple[float, str]] = []

    frontage = _saturating(c.frontage_ft, cfg.frontage_scale)
    depth = _saturating(c.depth_ft, cfg.depth_scale)
    if frontage is not None:
        signals.append((frontage, f"frontage {c.frontage_ft:,.0f} ft"))
    if depth is not None:
        signals.append((depth, f"depth {c.depth_ft:,.0f} ft"))

    floor = (c.floor_level_text or "").strip().lower()
    if floor:
        if "ground" in floor:
            signals.append((1.0, "ground floor"))
        elif "basement" in floor:
            signals.append((0.2, "basement level"))
        else:
            signals.append((0.4, f"{floor} floor level"))
    position = (c.unit_position or "").strip().lower()
    if position:
        if "corner" in position or "end" in position:
            signals.append((1.0, f"{position} unit position"))
        else:
            signals.append((0.6, f"{position} unit position"))

    if not signals:
        return _unknown(
            "physical_fit",
            "Physical suitability was not scored.",
            "Frontage, depth, floor level and unit position are not recorded for "
            "this catalogue listing. Physical requirements "
            f"({', '.join(p.physical_requirements) or 'none stated'}) remain "
            "UNVERIFIED - they are not treated as failed or satisfied.",
        )

    value = math.fsum(v for v, _ in signals) / len(signals)
    measured = [label for _, label in signals]
    # Plain English, never the underlying column names: this string is shown
    # verbatim to entrepreneurs on the recommendation explanation surfaces.
    reason = "Verified physical attributes: " + ", ".join(measured) + "."

    caution: str | None = None
    requirements = list(p.physical_requirements)
    if requirements:
        haystack = " ".join(measured).lower()
        matched = [r for r in requirements if any(t in haystack for t in r.split())]
        unmatched = [r for r in requirements if r not in matched]
        if matched:
            reason += " Matched requirement(s): " + ", ".join(matched) + "."
        if unmatched:
            caution = (
                "Physical requirement(s) could not be verified against the "
                "recorded attributes and remain UNVERIFIED, not failed: "
                + ", ".join(unmatched)
                + "."
            )
    return _scored(
        "physical_fit", _clamp01(value), reason,
        {"measured": measured, "physical_requirements": requirements},
        caution,
    )


_COMPONENT_FUNCTIONS = {
    "budget_fit": _budget_fit,
    "size_fit": _size_fit,
    "property_type_fit": _property_type_fit,
    "target_market_fit": _target_market_fit,
    "accessibility_fit": _accessibility_fit,
    "parking_fit": _parking_fit,
    "competition_fit": _competition_fit,
    "physical_fit": _physical_fit,
}


@dataclass(frozen=True)
class ScoredCandidate:
    property_id: str
    candidate: PropertyCandidate
    pu_association_score: float
    preference_match_score: float | None
    final_score: float
    final_score_basis: str
    components: dict[str, ComponentResult]
    reasons: tuple[str, ...]
    cautions: tuple[str, ...]
    coverage: dict[str, Any]
    #: Which Layer-1 artifact produced ``pu_association_score``. Never mixed
    #: inside one ranking batch: every row of a batch carries the same name.
    layer1_model: str = "pu_model"
    rank: int | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "property_id": self.property_id,
            "property": {
                "property_id": self.candidate.property_id,
                "canonical_property_id": self.candidate.property_id,
                "title": self.candidate.title,
                "address": self.candidate.address,
                "city": self.candidate.city,
                "state": self.candidate.state,
                "district": self.candidate.district,
                "postcode": self.candidate.postcode,
                "property_type": self.candidate.property_type,
                "monthly_rental_myr": self.candidate.monthly_rental_myr,
                "built_up_sqft": self.candidate.built_up_sqft,
                "floor_level": self.candidate.floor_level,
                "floor_level_text": self.candidate.floor_level_text,
                "unit_position": self.candidate.unit_position,
                "frontage_ft": self.candidate.frontage_ft,
                "depth_ft": self.candidate.depth_ft,
                "latitude": self.candidate.latitude,
                "longitude": self.candidate.longitude,
                "image_url": self.candidate.image_url,
                "listing_ref": self.candidate.listing_ref,
                "verification": self.candidate.verification,
            },
            "model": {
                "name": self.layer1_model,
                "research_only": True,
                "association_score": round(self.pu_association_score, 6),
                "association_score_0_100": round(self.pu_association_score * 100.0, 1),
                "score_source": self.candidate.pu_score_source,
                "model_method": self.candidate.pu_model_method,
                "feature_set": self.candidate.pu_feature_set,
                "score_type": self.candidate.pu_score_type,
                "score_meaning": (
                    "Uncalibrated association with the observed-positive F&B "
                    "sample class; NOT a probability of commercial success."
                ),
            },
            "personalisation": {
                "preference_match_score": (
                    None if self.preference_match_score is None
                    else round(self.preference_match_score, 6)
                ),
                "preference_match_score_0_100": (
                    None if self.preference_match_score is None
                    else round(self.preference_match_score * 100.0, 1)
                ),
                "engine": "rule_based",
                "trained_recommender": False,
                "config_version": SCORING_CONFIG.version,
                "components": {name: c.value for name, c in self.components.items()},
                "component_status": {name: c.status for name, c in self.components.items()},
                "component_details": {name: c.as_dict() for name, c in self.components.items()},
                "coverage": self.coverage,
            },
            "final_recommendation": {
                "score": round(self.final_score, 6),
                "score_0_100": round(self.final_score * 100.0, 1),
                "rank": self.rank,
                "basis": self.final_score_basis,
                "score_meaning": SCORE_MEANING,
            },
            "explanation": {
                "preference_reasons": list(self.reasons),
                "cautions": list(self.cautions),
                "shap": None,
            },
        }


def score_candidate(
    candidate: PropertyCandidate,
    profile: PreferenceProfile,
    *,
    config: ScoringConfig = SCORING_CONFIG,
) -> ScoredCandidate:
    """Compute one deterministic, explainable Layer 2 + final score."""
    pu = candidate.pu_association_score
    if pu is None or not 0.0 <= pu <= 1.0:
        raise ValueError("A valid Layer 1 PU association score in [0, 1] is required")

    components = {
        name: fn(candidate, profile, config) for name, fn in _COMPONENT_FUNCTIONS.items()
    }
    weights = config.weights.as_dict()
    known = [(name, c) for name, c in components.items() if c.value is not None]
    weight_sum = math.fsum(weights[name] for name, _ in known)
    preference = (
        math.fsum(weights[name] * float(c.value) for name, c in known) / weight_sum
        if weight_sum > 0 else None
    )

    if preference is None:
        final = pu
        basis = "pu_only_no_scorable_preference_components"
    else:
        final = config.pu_weight * pu + config.preference_weight * preference
        basis = f"pu_{config.pu_weight:.2f}_preference_{config.preference_weight:.2f}"
    if not 0.0 <= final <= 1.0:
        raise ValueError(f"Final score out of range: {final}")

    reasons: list[str] = []
    cautions: list[str] = []
    for name, component in components.items():
        # A data-quality caution belongs in the response whether the component
        # was scored or unknown (e.g. PARTIAL_COVERAGE parking, unverified
        # physical requirements). Dropping it here previously hid real caveats.
        if component.caution:
            cautions.append(component.caution)
        if component.status == "unknown":
            continue
        value = float(component.value or 0.0)
        if value >= config.strength_threshold:
            reasons.append(component.reason)
        elif value <= config.concern_threshold:
            label = name.replace("_", " ")
            cautions.append(
                f"{label} is low ({value:.2f}): {component.reason}"
            )
    # Listing-verification cautions are always surfaced, never hidden.
    verification = candidate.verification or {}
    if not verification.get("confirmed_available", False):
        cautions.append(
            "Listing availability is UNKNOWN_NOT_VERIFIED in the research catalogue. "
            "This is NOT confirmed availability; verify with the listing source "
            "before acting on a recommendation."
        )
    if verification.get("pending_verification"):
        cautions.append(
            "Pending verification listings are excluded; no pending row is "
            "presented as confirmed availability."
        )
    if candidate.data_completeness_pct is not None and candidate.data_completeness_pct < 90:
        cautions.append(
            f"Research feature completeness is {candidate.data_completeness_pct:.1f}%; "
            "some geospatial measurements may be missing."
        )
    if candidate.coordinate_quality and "NOT" in candidate.coordinate_quality.upper():
        cautions.append(
            f"Coordinate quality: {candidate.coordinate_quality}."
        )

    unknown_names = [name for name, c in components.items() if c.status == "unknown"]
    coverage = {
        "scored_components": len(known),
        "total_components": len(components),
        "unknown_components": unknown_names,
        "effective_weight": round(weight_sum, 6),
        "missing_data_policy": config.as_dict()["missing_data_policy"],
    }
    return ScoredCandidate(
        property_id=candidate.property_id,
        candidate=candidate,
        pu_association_score=pu,
        preference_match_score=preference,
        final_score=final,
        final_score_basis=basis,
        components=components,
        reasons=tuple(reasons),
        cautions=tuple(dict.fromkeys(cautions)),
        coverage=coverage,
    )


def rank_candidates(scores: list[ScoredCandidate]) -> list[ScoredCandidate]:
    """Deterministic total ordering; the id tie-break makes it stable."""

    def key(item: ScoredCandidate) -> tuple:
        return (
            -round(item.final_score, 12),
            -round(item.preference_match_score or 0.0, 12),
            -round(item.pu_association_score, 12),
            item.property_id,
        )

    ordered = sorted(scores, key=key)
    return [
        ScoredCandidate(
            **{**item.__dict__, "rank": index + 1}
        )
        for index, item in enumerate(ordered)
    ]


# ---------------------------------------------------------------------------
# Five-question Recommender V3 (requirements schema v3, 2026-11-11)
# ---------------------------------------------------------------------------
#
# The scoring rules below are a documented reconstruction of the supplied
# five-question recommender, anchored on the calibration snapshot the user
# supplied as ``RECOMMENDER_V3.joblib`` (module ``sitewise_recommender_v3``,
# classes ``FiveQuestionRecommender``/``Calibration``). The original .py source
# of that package was NOT delivered, so:
#   * every constant here equals the snapshot's own serialized values
#     (verified at load time by ``sitewise.ml.sitewise_recommender_v3``), and
#   * every rule is deterministic, versioned and reported with each result.
# Nothing is presented as a trained model output.

#: Q4 "Business Location Priority" — the three new V3 tokens (the two v2
#: tokens ``high_customer_demand`` / ``favorable_competition`` remain accepted
#: for backward compatibility with pre-V3 records).
RECOMMENDATION_PRIORITY_V3: tuple[str, ...] = (
    "high_nearby_population",
    "affordable_operating_location",
    "easy_customer_accessibility",
    "active_commercial_surroundings",
    "balanced_suitability",
)

#: Q5 "Preferred Business Space".
SPACE_SIZE_PREFERENCE_V3: tuple[str, ...] = (
    "compact_business_space",
    "standard_business_space",
    "spacious_business_space",
    "flexible_no_preference",
)

#: Q3 "Target Customers" (multi-select) — identical to the v2 vocabulary.
TARGET_CUSTOMERS_V3: tuple[str, ...] = (
    "nearby_residents",
    "office_workers",
    "students",
    "commuters",
    "general_public",
)


@dataclass(frozen=True)
class CalibrationV3:
    """Catalogue-calibrated constants for the V3 rule engine.

    Defaults are the values serialized inside ``RECOMMENDER_V3.joblib``;
    ``sitewise.ml.sitewise_recommender_v3`` verifies the artifact against
    them. ``catalogue_fingerprint`` pins the 955-row eligible research
    catalogue the scales were calibrated on.
    """

    version: str = SCORING_CONFIG_V3_VERSION
    rent_p10: float = 1600.0
    rent_p90: float = 12000.0
    sqft_p10: float = 1138.8
    sqft_p33: float = 1540.0
    sqft_p67: float = 1760.0
    sqft_p90: float = 2865.8
    count_scales: Mapping[str, float] = field(default_factory=lambda: {
        "population_500m": 5126.7,
        "population_1000m": 19218.0,
        "office_pois_500m": 3.0,
        "schools_count_500m": 2.0,
        "universities_count_500m": 1.0,
        "retail_pois_500m": 8.0,
        "retail_pois_1000m": 21.0,
        "malls_count_500m": 1.0,
        "malls_count_1000m": 1.0,
        "bus_stops_500m_walk": 2.0,
        "rail_stations_1km_walk": 1.0,
        "parking_facilities_500m": 4.0,
        "walk_isochrone_area_10min_km2": 0.2688,
        "frontage_ft": 22.0,
        "depth_ft": 75.0,
    })
    population_count: int = 955
    catalogue_fingerprint: str = (
        "e5b1c7d2926c47e0a7b688920580b1f9858c0d14e1d1582d4397f118522b3e3b"
    )
    pu_weight: float = 0.70
    preference_weight: float = 0.30
    low_pu_caution_bound: float = 0.20
    #: DOSM national average household size — a CONTEXTUAL statistical factor
    #: for the estimated-households evidence line only. It is NOT a measured
    #: household count for any property's catchment.
    avg_household_size: float = 3.9

    def as_dict(self) -> dict[str, Any]:
        return {
            "version": self.version,
            "rent_p10": self.rent_p10,
            "rent_p90": self.rent_p90,
            "sqft_p10": self.sqft_p10,
            "sqft_p33": self.sqft_p33,
            "sqft_p67": self.sqft_p67,
            "sqft_p90": self.sqft_p90,
            "count_scales": dict(self.count_scales),
            "population_count": self.population_count,
            "catalogue_fingerprint": self.catalogue_fingerprint,
            "pu_weight": self.pu_weight,
            "preference_weight": self.preference_weight,
            "low_pu_caution_bound": self.low_pu_caution_bound,
            "avg_household_size_context": self.avg_household_size,
            "household_note": (
                "Estimated households = population / DOSM national average "
                "household size. Contextual statistical evidence, NOT a "
                "measured household count for the property's catchment."
            ),
        }


CALIBRATION_V3 = CalibrationV3()


def _scale(calibration: CalibrationV3, name: str) -> float:
    return float(calibration.count_scales.get(name, 1.0)) or 1.0


#: Q4 -> dynamic component weights. Documented research mapping, NOT learned:
#: each priority redistributes the baseline weights towards the components
#: that priority names. Every row sums to 1.0 (asserted in tests).
_Q4_WEIGHTS_V3: dict[str, ScoringWeights] = {
    "high_nearby_population": ScoringWeights(
        budget_fit=0.15, size_fit=0.10, property_type_fit=0.05,
        target_market_fit=0.35, accessibility_fit=0.10, parking_fit=0.05,
        competition_fit=0.10, physical_fit=0.10,
    ),
    "affordable_operating_location": ScoringWeights(
        budget_fit=0.35, size_fit=0.15, property_type_fit=0.05,
        target_market_fit=0.15, accessibility_fit=0.05, parking_fit=0.10,
        competition_fit=0.10, physical_fit=0.05,
    ),
    "easy_customer_accessibility": ScoringWeights(
        budget_fit=0.15, size_fit=0.10, property_type_fit=0.05,
        target_market_fit=0.15, accessibility_fit=0.30, parking_fit=0.15,
        competition_fit=0.05, physical_fit=0.05,
    ),
    "active_commercial_surroundings": ScoringWeights(
        budget_fit=0.10, size_fit=0.10, property_type_fit=0.10,
        target_market_fit=0.30, accessibility_fit=0.10, parking_fit=0.05,
        competition_fit=0.15, physical_fit=0.10,
    ),
    "balanced_suitability": ScoringWeights(),
    # Backward-compatible v2 tokens keep their documented semantics.
    "high_customer_demand": ScoringWeights(
        budget_fit=0.15, size_fit=0.10, property_type_fit=0.05,
        target_market_fit=0.35, accessibility_fit=0.10, parking_fit=0.05,
        competition_fit=0.10, physical_fit=0.10,
    ),
    "favorable_competition": ScoringWeights(
        budget_fit=0.15, size_fit=0.10, property_type_fit=0.05,
        target_market_fit=0.15, accessibility_fit=0.10, parking_fit=0.10,
        competition_fit=0.25, physical_fit=0.10,
    ),
}


def effective_weights_v3(priority: str | None) -> ScoringWeights:
    """Q4 dynamically adjusts the component weights (V3 requirement)."""
    key = (priority or "").strip().lower()
    weights = _Q4_WEIGHTS_V3.get(key)
    if weights is None:
        weights = ScoringWeights()  # balanced baseline for unstated priorities
    total = sum(weights.as_dict().values())
    if not math.isclose(total, 1.0, abs_tol=1e-9):
        raise ValueError(f"V3 weights for priority '{key}' sum to {total}, expected 1.0")
    return weights


def _size_band_v3(
    preference: str | None, calibration: CalibrationV3
) -> tuple[float, float] | None:
    """Q5 categorical preference -> calibrated sqft band (p10/p33/p67/p90)."""
    key = (preference or "").strip().lower()
    if key == "compact_business_space":
        return calibration.sqft_p10, calibration.sqft_p33
    if key == "standard_business_space":
        return calibration.sqft_p33, calibration.sqft_p67
    if key == "spacious_business_space":
        return calibration.sqft_p67, calibration.sqft_p90
    return None  # flexible / unstated: no band, component excluded


def _budget_fit_v3(
    c: PropertyCandidate, p: PreferenceProfile, cfg: ScoringConfig,
    calibration: CalibrationV3,
) -> ComponentResult:
    """V3 rental affordability.

    A stated maximum budget stays authoritative (v1 rule). Without one, the
    calibrated catalogue distribution decides: rent at/below the 10th
    percentile scores 1.0, linearly decaying to 0.0 at/above the 90th
    percentile.
    """
    rent = c.monthly_rental_myr
    if rent is None:
        return _unknown(
            "budget_fit",
            "Budget fit was not scored.",
            "Monthly rent is unknown; affordability is not treated as zero.",
        )
    if p.max_rent_myr is not None and p.max_rent_myr > 0:
        return _budget_fit(c, p, cfg)
    p10, p90 = calibration.rent_p10, calibration.rent_p90
    if rent <= p10:
        value, reason = 1.0, (
            f"RM{rent:,.0f}/month is at or below the catalogue's 10th-percentile "
            f"rent (RM{p10:,.0f}) — highly affordable for the research catalogue."
        )
    elif rent >= p90:
        value, reason = 0.0, (
            f"RM{rent:,.0f}/month is at or above the catalogue's 90th-percentile "
            f"rent (RM{p90:,.0f}) — the most expensive decile of the catalogue."
        )
    else:
        value = _clamp01((p90 - rent) / (p90 - p10))
        reason = (
            f"RM{rent:,.0f}/month sits between the catalogue's 10th (RM{p10:,.0f}) "
            f"and 90th (RM{p90:,.0f}) percentile rents."
        )
    return _scored(
        "budget_fit", value, reason,
        {"monthly_rental_myr": rent, "catalogue_rent_p10": p10,
         "catalogue_rent_p90": p90, "stated_budget": p.max_rent_myr},
    )


def _size_fit_v3(
    c: PropertyCandidate, p: PreferenceProfile, _cfg: ScoringConfig,
    calibration: CalibrationV3,
) -> ComponentResult:
    """V5/V3 categorical size calibration (Q5).

    The preference names a band from the catalogue's sqft percentiles; the
    listing scores 1.0 inside its band and decays linearly with distance from
    the band edges over one band-width tolerance. ``flexible_no_preference``
    is excluded (unknown), never zero.
    """
    size = c.built_up_sqft
    preference = p.space_size_preference
    band = _size_band_v3(preference, calibration)
    if size is None:
        return _unknown(
            "size_fit",
            "Floor-area fit was not scored.",
            "Built-up area is unknown; size fit is not treated as zero.",
        )
    if band is None:
        return _unknown(
            "size_fit",
            "Floor-area fit was not scored.",
            "No categorical size preference was stated (flexible / unstated); "
            "size fit is excluded from the weighted mean rather than assumed.",
        )
    low, high = band
    tolerance = max(high - low, calibration.sqft_p33 - calibration.sqft_p10)
    if low <= size <= high:
        value = 1.0
        reason = (
            f"{size:,.0f} sq ft is inside your '{preference}' band "
            f"({low:,.0f}–{high:,.0f} sq ft, catalogue percentiles)."
        )
    else:
        distance = low - size if size < low else size - high
        value = _clamp01(1.0 - distance / tolerance)
        reason = (
            f"{size:,.0f} sq ft is {distance:,.0f} sq ft outside your "
            f"'{preference}' band ({low:,.0f}–{high:,.0f} sq ft)."
        )
    return _scored(
        "size_fit", value, reason,
        {"built_up_sqft": size, "space_size_preference": preference,
         "band_sqft": [low, high]},
    )


def _target_market_fit_v3(
    c: PropertyCandidate, p: PreferenceProfile, _cfg: ScoringConfig,
    calibration: CalibrationV3,
) -> ComponentResult:
    """V3 demand fit using the calibration's own count scales.

    Adds the estimated-households evidence line (population / DOSM average
    household size — contextual statistical evidence, NOT a measured
    household count) and the commercial-surroundings signals that
    ``active_commercial_surroundings`` prioritises.
    """
    signals: list[tuple[float, str]] = []

    def add(value: float | None, scale_name: str, label: str) -> None:
        fit = _saturating(value, _scale(calibration, scale_name))
        if fit is not None:
            signals.append((fit, f"{label}={value:,.0f}"))

    customers = set(p.target_customers)
    concept = p.fnb_concept or ""

    # Residential population + estimated households (Q4=high_nearby_population,
    # Q3 nearby_residents/general_public).
    if customers & {"nearby_residents", "general_public"} or concept in {
        "cafe_coffee_shop", "restaurant", "bakery_dessert_shop", ""
    }:
        add(c.population_500m, "population_500m", "population_500m")
        add(c.population_1000m, "population_1000m", "population_1000m")

    # Office workers / commercial surroundings.
    if (
        "office_workers" in customers
        or concept in {"cafe_coffee_shop", "fast_food_quick_service"}
        or p.recommendation_priority == "active_commercial_surroundings"
    ):
        add(c.office_pois_500m, "office_pois_500m", "office_pois_500m")

    # Students.
    if "students" in customers or concept in {"bakery_dessert_shop", "beverage_shop_kiosk"}:
        add(c.schools_count_500m, "schools_count_500m", "schools_500m")
        add(c.universities_count_500m, "universities_count_500m", "universities_500m")

    # Commuters.
    if "commuters" in customers or concept in {"fast_food_quick_service", "beverage_shop_kiosk"}:
        add(c.bus_stops_500m_walk, "bus_stops_500m_walk", "bus_stops_500m")
        add(c.rail_stations_1km_walk, "rail_stations_1km_walk", "rail_1km")

    # Commercial surroundings (retail + malls).
    if (
        customers & {"general_public", "nearby_residents"}
        or concept in {"restaurant", "bakery_dessert_shop", "other_fnb"}
        or p.recommendation_priority == "active_commercial_surroundings"
    ):
        add(c.malls_count_500m, "malls_count_500m", "malls_500m")

    # Concept-specific same-category demand signal (as v1).
    same_category = {
        "cafe_coffee_shop": c.cafe_count_500m,
        "restaurant": c.restaurant_count_500m,
        "fast_food_quick_service": c.fast_food_count_500m,
        "bakery_dessert_shop": c.bakery_count_500m,
    }.get(concept)
    if same_category is not None:
        add(same_category, "office_pois_500m", "same_category_outlets_500m")

    if not signals:
        return _unknown(
            "target_market_fit",
            "Target-market fit was not scored.",
            "No verified demand-generator measurements are available for this "
            "listing and your target customers; absence is not treated as zero demand.",
        )
    value = math.fsum(s[0] for s in signals) / len(signals)
    label = CONCEPT_LABELS.get(concept, p.business_category or "your F&B concept")
    audience = ', '.join(sorted(customers)) or 'not specified'
    if value <= _cfg_concern(_cfg):
        reason = (
            f"Nearby demand-generator measurements are weak for {label} and your "
            f"target customers ({audience})."
        )
    elif value >= _cfg_strength(_cfg):
        reason = (
            f"Nearby demand generators are consistent with {label} and your "
            f"target customers ({audience})."
        )
    else:
        reason = (
            f"Nearby demand generators were measured for {label} and your "
            f"target customers ({audience}) with mixed results."
        )
    household_estimate = (
        round(c.population_500m / calibration.avg_household_size, 1)
        if c.population_500m is not None else None
    )
    return _scored(
        "target_market_fit", value, reason,
        {
            "signals": [label for _, label in signals],
            "target_customers": sorted(customers),
            "fnb_concept": concept or None,
            "estimated_households_500m_context": household_estimate,
            "household_note": (
                "Estimated from population / DOSM national average household "
                "size. Contextual statistical evidence, NOT a measured "
                "household count for the property's catchment."
            ) if household_estimate is not None else None,
        },
    )


def _cfg_strength(cfg: ScoringConfig) -> float:
    return cfg.strength_threshold


def _cfg_concern(cfg: ScoringConfig) -> float:
    return cfg.concern_threshold


#: V3 config: same 70/30 final combination (verified against the snapshot),
#: versioned under the snapshot's own version string.
SCORING_CONFIG_V3 = ScoringConfig(
    version=SCORING_CONFIG_V3_VERSION,
    weights=ScoringWeights(),  # placeholder; V3 weights are Q4-dynamic
    pu_weight=CALIBRATION_V3.pu_weight,
    preference_weight=CALIBRATION_V3.preference_weight,
)

_SCORING_CONFIG_V3 = SCORING_CONFIG_V3  # alias used below


def score_candidate_v3(
    candidate: PropertyCandidate,
    profile: PreferenceProfile,
    *,
    calibration: CalibrationV3 = CALIBRATION_V3,
    config: ScoringConfig = SCORING_CONFIG_V3,
    layer1_model: str = "pu_model",
) -> ScoredCandidate:
    """Compute one deterministic V3 five-question score.

    Same contract as :func:`score_candidate` (components, coverage,
    explanations) with three V3 differences: the component weights follow the
    Q4 priority, ``size_fit`` uses the Q5 categorical calibration bands, and
    affordability uses the calibrated rent percentiles when no budget is
    stated. Every sub-score stays on the same 0–1 scale (exposed as 0–100 in
    the payload), and the final score remains ``0.70 * pu + 0.30 * preference``.
    """
    pu = candidate.pu_association_score
    if pu is None or not 0.0 <= pu <= 1.0:
        raise ValueError("A valid Layer 1 PU association score in [0, 1] is required")

    weights = effective_weights_v3(profile.recommendation_priority)
    components: dict[str, ComponentResult] = {
        "budget_fit": _budget_fit_v3(candidate, profile, config, calibration),
        "size_fit": _size_fit_v3(candidate, profile, config, calibration),
        "property_type_fit": _property_type_fit(candidate, profile, config),
        "target_market_fit": _target_market_fit_v3(candidate, profile, config, calibration),
        "accessibility_fit": _accessibility_fit(candidate, profile, config),
        "parking_fit": _parking_fit(candidate, profile, config),
        "competition_fit": _competition_fit(candidate, profile, config),
        "physical_fit": _physical_fit(candidate, profile, config),
    }
    known = [(name, c) for name, c in components.items() if c.value is not None]
    weight_sum = math.fsum(weights.as_dict()[name] for name, _ in known)
    preference = (
        math.fsum(weights.as_dict()[name] * float(c.value) for name, c in known) / weight_sum
        if weight_sum > 0 else None
    )

    if preference is None:
        final = pu
        basis = "pu_only_no_scorable_preference_components"
    else:
        final = config.pu_weight * pu + config.preference_weight * preference
        basis = (
            f"pu_{config.pu_weight:.2f}_preference_{config.preference_weight:.2f}"
            f"_q4_{(profile.recommendation_priority or 'balanced')}"
        )
    if not 0.0 <= final <= 1.0:
        raise ValueError(f"Final score out of range: {final}")

    reasons: list[str] = []
    cautions: list[str] = []
    for name, component in components.items():
        if component.caution:
            cautions.append(component.caution)
        if component.status == "unknown":
            continue
        value = float(component.value or 0.0)
        if value >= config.strength_threshold:
            reasons.append(component.reason)
        elif value <= config.concern_threshold:
            label = name.replace("_", " ")
            cautions.append(f"{label} is low ({value:.2f}): {component.reason}")
    if pu < calibration.low_pu_caution_bound:
        cautions.append(
            f"PU research association score is low ({pu * 100:.1f}/100, below the "
            f"calibration's low-score bound of "
            f"{calibration.low_pu_caution_bound * 100:.0f}/100): the location shows "
            "weak association with the observed F&B sample in this research "
            "dataset. This is NOT a prediction of business failure."
        )
    verification = candidate.verification or {}
    if not verification.get("confirmed_available", False):
        cautions.append(
            "Listing availability is UNKNOWN_NOT_VERIFIED in the research catalogue. "
            "This is NOT confirmed availability; verify with the listing source "
            "before acting on a recommendation."
        )
    if candidate.data_completeness_pct is not None and candidate.data_completeness_pct < 90:
        cautions.append(
            f"Research feature completeness is {candidate.data_completeness_pct:.1f}%; "
            "some geospatial measurements may be missing."
        )
    if candidate.coordinate_quality and "NOT" in candidate.coordinate_quality.upper():
        cautions.append(f"Coordinate quality: {candidate.coordinate_quality}.")

    unknown_names = [name for name, c in components.items() if c.status == "unknown"]
    coverage = {
        "scored_components": len(known),
        "total_components": len(components),
        "unknown_components": unknown_names,
        "effective_weight": round(weight_sum, 6),
        "effective_weights_v3": weights.as_dict(),
        "q4_priority": profile.recommendation_priority,
        "q5_size_preference": profile.space_size_preference,
        "missing_data_policy": "exclude_and_renormalise",
    }
    return ScoredCandidate(
        property_id=candidate.property_id,
        candidate=candidate,
        pu_association_score=pu,
        preference_match_score=preference,
        final_score=final,
        final_score_basis=basis,
        components=components,
        reasons=tuple(reasons),
        cautions=tuple(dict.fromkeys(cautions)),
        coverage=coverage,
        layer1_model=layer1_model,
    )
