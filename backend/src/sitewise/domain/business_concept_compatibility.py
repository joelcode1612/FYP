"""Five F&B concept comparison over measured property/location signals.

Experimental MCDA policy, not an ML probability or validated feasibility claim.
The deployed PU model and four-class category research classifier NEVER enter
these weights: their outputs are shown separately by the service layer.
"""
from __future__ import annotations

import math
from typing import Any, Mapping

POLICY_VERSION = "business_concepts_exploratory_v1"
WEIGHTS = {"demand": 0.50, "accessibility": 0.30, "competition": 0.20}
# Heuristic normalisation caps, NOT learned or empirically validated.
CAPS = {
    "pop_1000m": 15000.0,
    "office_pois_1000m": 20.0,
    "retail_pois_1000m": 40.0,
    "schools_count_1000m": 10.0,
    "malls_count_1000m": 3.0,
}
PROFILES = (
    {"key": "restaurant", "name": "Restaurant",
     "demand": ("pop_1000m", "retail_pois_1000m", "malls_count_1000m"),
     "competition": "restaurant_count_1000m", "transit_share": 0.30,
     "premises": ("F&B operating approval", "Cooking and extraction facilities",
                  "Grease-trap and food-handling compliance", "Usable dining floor area"),
     "research_class": "Restaurant"},
    {"key": "cafe", "name": "Café / Coffee Shop",
     "demand": ("office_pois_1000m", "retail_pois_1000m", "malls_count_1000m"),
     "competition": "cafe_count_1000m", "transit_share": 0.60,
     "premises": ("F&B operating approval", "Preparation and water facilities",
                  "Usable seating or service area"),
     "research_class": "Cafe / Coffee"},
    {"key": "bakery_dessert", "name": "Bakery / Dessert Shop",
     "demand": ("pop_1000m", "retail_pois_1000m", "office_pois_1000m"),
     "competition": "bakery_dessert_beverage_count_1000m", "transit_share": 0.40,
     "premises": ("F&B operating approval", "Suitable preparation and extraction facilities",
                  "Production and customer-service space"),
     "research_class": "Bakery / Dessert / Beverage"},
    {"key": "fast_food", "name": "Fast Food / Quick Service",
     "demand": ("pop_1000m", "office_pois_1000m", "schools_count_1000m"),
     "competition": "fast_food_count_1000m", "transit_share": 0.65,
     "premises": ("F&B operating approval", "Cooking and extraction facilities",
                  "Safe customer and pickup access"),
     "research_class": "Fast Food / Takeaway"},
    {"key": "beverage", "name": "Beverage Shop / Kiosk",
     "demand": ("office_pois_1000m", "schools_count_1000m", "retail_pois_1000m"),
     "competition": "bakery_dessert_beverage_count_1000m", "transit_share": 0.70,
     "premises": ("F&B operating approval", "Water and preparation facilities",
                  "Suitable kiosk or shop layout"),
     "research_class": "Bakery / Dessert / Beverage"},
)
FEATURES = tuple(dict.fromkeys(
    [k for p in PROFILES for k in p["demand"]]
    + ["nearest_transit_walk_m", "nearest_major_road_m", "fnb_competitors_1000m"]
    + [p["competition"] for p in PROFILES]
))
LABELS = {
    "pop_1000m": "Estimated population within 1 km",
    "office_pois_1000m": "Office POIs within 1 km",
    "retail_pois_1000m": "Retail POIs within 1 km",
    "schools_count_1000m": "Schools within 1 km",
    "malls_count_1000m": "Shopping malls within 1 km",
    "nearest_transit_walk_m": "Walk to nearest transit",
    "nearest_major_road_m": "Distance to nearest major road",
    "fnb_competitors_1000m": "All F&B competitors within 1 km",
    "restaurant_count_1000m": "Restaurants within 1 km",
    "cafe_count_1000m": "Cafés within 1 km",
    "fast_food_count_1000m": "Fast-food outlets within 1 km",
    "bakery_dessert_beverage_count_1000m": "Bakery/dessert/beverage outlets combined within 1 km",
}


def _number(v: Any) -> float | None:
    if v is None or isinstance(v, bool):
        return None
    try:
        value = float(v)
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) and value >= 0 else None


def evaluate_concepts(
    features: Mapping[str, Any], *, sources: Mapping[str, str] | None = None,
    property_details: Mapping[str, Any] | None = None,
    monthly_rental: Any = None, monthly_budget: float | None = None,
    coordinate_present: bool = True,
) -> dict[str, Any]:
    """Five comparable provisional indices, or no ranks if evidence is incomplete.

    Provisional index = 50% demand + 30% access + 20% category exposure.
    Separate concepts have distinct demand features, transit importance and
    competition counts; identical weights and thresholds protect comparisons.
    The market meaning of each proxy and all weights require later validation.
    """
    details = property_details or {}
    sources = sources or {}
    rent, budget = _number(monthly_rental), _number(monthly_budget)
    budget_check = (
        "not_specified" if budget is None else
        "rental_unknown" if rent is None else
        "advertised_within_budget" if rent <= budget else "advertised_above_budget"
    )
    results: list[dict[str, Any]] = []
    for profile in PROFILES:
        keys = tuple(dict.fromkeys((*profile["demand"],
            "nearest_transit_walk_m", "nearest_major_road_m",
            "fnb_competitors_1000m", profile["competition"])))
        values = {key: _number(features.get(key)) for key in keys}
        missing = [key for key, value in values.items() if value is None]
        total, same = values["fnb_competitors_1000m"], values[profile["competition"]]
        if total is not None and same is not None and same > total:
            missing.append("inconsistent_competitor_inventory")
        if not coordinate_present:
            missing.append("property_coordinates")
        evidence = [
            {"key": key, "label": LABELS[key], "value": values[key],
             "unit": "m" if key.endswith("_m") else "people" if key.startswith("pop_") else "count",
             "source": sources.get(key), "available": values[key] is not None}
            for key in keys
        ]
        parts = None
        if not missing:
            demand = sum(min(values[k] / CAPS[k], 1.0) for k in profile["demand"]) / len(profile["demand"])
            transit = max(0.0, 1.0 - values["nearest_transit_walk_m"] / 2000.0)
            road = max(0.0, 1.0 - values["nearest_major_road_m"] / 500.0)
            access = profile["transit_share"] * transit + (1 - profile["transit_share"]) * road
            # No other outlets is ambiguous (not proof of an opportunity).
            competition = 0.5 if total == 0 else 1 - same / total
            parts = {"demand": round(demand * 100, 1),
                     "accessibility": round(access * 100, 1),
                     "competition": round(competition * 100, 1)}
        score = round(sum(parts[k] * WEIGHTS[k] for k in WEIGHTS), 1) if parts else None
        strengths, weaknesses = [], []
        if parts:
            top = max(parts, key=parts.get)
            low = min(parts, key=parts.get)
            strengths.append(f"The {top} proxy is the strongest component of this heuristic comparison ({parts[top]:g}/100).")
            weaknesses.append(f"The {low} proxy is the weakest component ({parts[low]:g}/100); this is not a revenue forecast.")
        requirements = [
            {"requirement": req, "status": "unknown", "note": "Verify with owner and local authority"}
            for req in profile["premises"]
        ]
        floor = details.get("floor_level")
        requirements.append({
            "requirement": "Ground-floor accessibility (preferred)",
            "status": "recorded" if details.get("verified_listing") and floor else "unknown",
            "note": f"Approved listing records floor: {floor}" if details.get("verified_listing") and floor
                    else "Floor/access requires verification; listing advertising alone is insufficient",
        })
        cautions = [
            "Scores are unvalidated decision-support indices, not a probability of business success.",
            "F&B licensing and operational premises requirements are not established.",
        ]
        if profile["competition"] == "bakery_dessert_beverage_count_1000m":
            cautions.append("Bakery and beverage share a combined competitor bucket; no separate count is established.")
        if budget_check == "advertised_above_budget":
            cautions.append("The advertised rent exceeds the budget. Confirm the current asking rent.")
        results.append({
            "key": profile["key"], "name": profile["name"],
            "status": "provisional" if score is not None else "insufficient_evidence",
            "score": score, "component_scores": parts,
            "missing_features": missing, "evidence": evidence,
            "premises_requirements": requirements,
            "strengths": strengths, "limitations": weaknesses,
            "research_class": profile["research_class"], "cautions": cautions,
        })
    # Do not rank partial rows against more complete rows.
    comparable = all(result["score"] is not None for result in results)
    if comparable:
        results.sort(key=lambda item: (-item["score"], item["name"]))
        for rank, result in enumerate(results, 1):
            result["rank"] = rank
    else:
        for result in results:
            result.update(rank=None, score=None, component_scores=None,
                          status="insufficient_evidence", strengths=[], limitations=[])
    return {
        "available": comparable, "status": "provisional" if comparable else "insufficient_evidence",
        "policy_version": POLICY_VERSION, "policy_kind": "unvalidated_explainable_heuristic",
        "weights": WEIGHTS, "normalisation_caps": CAPS,
        "formula": "0.50*demand + 0.30*accessibility + 0.20*competition (0–100)",
        "monthly_rental_myr": rent, "monthly_budget_myr": budget,
        "budget_check": budget_check,
        "final_feasibility": "unverified_premises_and_licensing",
        "rankings": results,
        "note": "Experimental comparison. The weights and caps are policy assumptions, not trained accuracy. Final business feasibility is never established by these indices.",
    }
