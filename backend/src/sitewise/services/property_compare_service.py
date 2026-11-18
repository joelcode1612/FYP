"""Direct comparison of two or three shortlisted catalogue properties.

This is deliberately NOT a recommendation engine. It reads the same canonical
property identity and geospatial measurements as Recommendations and Property
Detail, then reports objective differences and deterministic trade-off wording.
It never invents a score, a winner, or a business outcome.

All measurements are read in targeted/batched queries:
  * one ID-filtered candidate query (catalogue + subject features + population);
  * at most three detail reads, only for verified physical attributes;
  * one batched panorama lookup.
"""

from __future__ import annotations

from typing import Any

from sqlmodel import Session

from sitewise.repositories.catalog_repository import CatalogRepository
from sitewise.repositories.recommendation_candidate_repository import (
    RecommendationCandidateRepository,
)
from sitewise.services.catalog_listing_details_service import CatalogListingDetailsService
from sitewise.services.property_insights_service import (
    PANORAMA_UNAVAILABLE,
    panoramas_by_catalogue_ids,
)

MIN_PROPERTIES = 2
MAX_PROPERTIES = 3

#: key -> (customer label, unit, geographic radius in metres, group, source)
_METRICS: dict[str, tuple[str, str, int | None, str, str]] = {
    "monthly_rent_rm": (
        "Monthly rental",
        "RM / month",
        None,
        "cost_space",
        "fyp.catalogue_properties.rental_rm",
    ),
    "size_sqft": (
        "Floor area",
        "sq ft",
        None,
        "cost_space",
        "fyp.catalogue_properties.size_sqft",
    ),
    "rent_per_sqft": (
        "Rental per sq ft",
        "RM / sq ft",
        None,
        "cost_space",
        "monthly rental ÷ recorded floor area",
    ),
    "floor_level_text": (
        "Floor level",
        "",
        None,
        "cost_space",
        "recorded research or verified listing attribute",
    ),
    "has_parking": (
        "On-site parking",
        "",
        None,
        "cost_space",
        "verified listing attribute (research value is not proof)",
    ),
    "population_500m": (
        "Resident population",
        "people",
        500,
        "location",
        "fyp_features.property_population_spatial.pop_ring_0_500m",
    ),
    "population_1000m": (
        "Resident population",
        "people",
        1000,
        "location",
        "fyp_features.property_population_spatial.pop_total_1km",
    ),
    "nearest_transit_walk_m": (
        "Nearest public transport",
        "m walk",
        None,
        "location",
        "sitewise_analytics.subject_features.nearest_transit_walk_m",
    ),
    "bus_stops_500m_walk": (
        "Transit stops within walk",
        "stops",
        500,
        "location",
        "mapped public transport stops",
    ),
    "walk_isochrone_area_10min_km2": (
        "Area walkable in 10 minutes",
        "km²",
        None,
        "location",
        "mapped walking isochrone",
    ),
    "parking_facilities_500m": (
        "Nearby public parking facilities",
        "facilities",
        500,
        "location",
        "mapped parking facilities — NOT property parking spaces",
    ),
    "office_pois_500m": (
        "Nearby offices",
        "offices",
        500,
        "location",
        "mapped office POIs",
    ),
    "universities_count_500m": (
        "Nearby universities / colleges",
        "institutions",
        500,
        "location",
        "mapped education POIs",
    ),
    "malls_count_500m": (
        "Nearby shopping malls",
        "malls",
        500,
        "location",
        "mapped retail POIs",
    ),
    "fnb_competitors_500m": (
        "Recorded F&B competitors",
        "outlets",
        500,
        "competition",
        "sitewise_analytics competitor count, 500 m radius",
    ),
    "fnb_competitors_1000m": (
        "Recorded F&B competitors",
        "outlets",
        1000,
        "competition",
        "sitewise_analytics competitor count, 1 km radius",
    ),
    "nearest_competitor_distance_m": (
        "Nearest recorded competitor",
        "m",
        None,
        "competition",
        "sitewise_analytics competitor distance",
    ),
    "cafe_count_500m": (
        "Cafés",
        "outlets",
        500,
        "competition",
        "mapped F&B subtype, 500 m radius",
    ),
    "restaurant_count_500m": (
        "Restaurants",
        "outlets",
        500,
        "competition",
        "mapped F&B subtype, 500 m radius",
    ),
    "fast_food_count_500m": (
        "Fast-food outlets",
        "outlets",
        500,
        "competition",
        "mapped F&B subtype, 500 m radius",
    ),
}

#: Metrics used for pairwise differences and factual superlatives.
_COMPARABLE = (
    "monthly_rent_rm",
    "size_sqft",
    "rent_per_sqft",
    "nearest_transit_walk_m",
    "population_1000m",
    "fnb_competitors_500m",
)


def _num(value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if result >= 0 else None


def _text(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def _fmt(value: float, unit: str) -> str:
    decimals = 2 if unit in {"RM / sq ft", "km²"} else 0
    number = f"{value:,.{decimals}f}"
    return f"{number} {unit}".strip()


def _sentence(
    a: dict[str, Any],
    b: dict[str, Any],
    key: str,
    delta: float,
) -> str:
    """One factual sentence; never a judgement about business success."""
    label, unit, radius, _, _ = _METRICS[key]
    first, second = a["title"], b["title"]
    place = f" within {radius} m" if radius else ""
    if key == "monthly_rent_rm":
        if delta > 0:
            return f"{second} costs RM {delta:,.0f} less per month than {first}."
        if delta < 0:
            return f"{first} costs RM {-delta:,.0f} less per month than {second}."
    if key == "size_sqft":
        if delta > 0:
            return f"{second} provides {delta:,.0f} sq ft more floor area than {first}."
        if delta < 0:
            return f"{first} provides {-delta:,.0f} sq ft more floor area than {second}."
    if key == "rent_per_sqft":
        cheaper = first if delta > 0 else second
        other = second if delta > 0 else first
        return f"{cheaper} has the lower rental per sq ft than {other}."
    higher_or_closer = {
        "nearest_transit_walk_m": ("closer to recorded public transport", True),
        "population_1000m": ("higher recorded resident population within 1 km", False),
        "fnb_competitors_500m": ("more recorded F&B competitors", False),
    }
    if key in higher_or_closer:
        phrase, lower_wins = higher_or_closer[key]
        winner = first if (delta > 0) == lower_wins else second
        return f"{winner} has the {phrase}{place} ({_fmt(abs(delta), unit)} difference)."
    return f"{label} differs by {_fmt(abs(delta), unit)} between {first} and {second}."


def _superlatives(properties: list[dict[str, Any]]) -> dict[str, list[str]]:
    """Factual labels only: 'lowest rent', never 'best property'."""
    rules = {
        "monthly_rent_rm": ("Lowest monthly rental", min),
        "size_sqft": ("Largest floor area", max),
        "rent_per_sqft": ("Lowest rental per sq ft", min),
        "nearest_transit_walk_m": ("Closest recorded public transport", min),
        "population_1000m": ("Highest recorded population within 1 km", max),
        "fnb_competitors_500m": ("Fewest recorded F&B competitors within 500 m", min),
    }
    result: dict[str, list[str]] = {}
    for key, (label, fn) in rules.items():
        eligible = [
            item
            for item in properties
            if item["metrics"][key]["available"]
        ]
        if len(eligible) < 2:
            continue
        target = fn(item["metrics"][key]["value"] for item in eligible)
        winners = [
            item["title"]
            for item in eligible
            if abs(item["metrics"][key]["value"] - target) < 1e-9
        ]
        if len(winners) == len(eligible):
            continue
        prefix = "Joint " if len(winners) > 1 else ""
        for title in winners:
            result.setdefault(title, []).append(f"{prefix}{label}")
    return result


class PropertyCompareService:
    """Read-only, deterministic comparison over verified catalogue evidence."""

    def __init__(
        self,
        analytics_session: Session,
        operational_session: Session,
    ):
        self.analytics = analytics_session
        self.operational = operational_session

    def compare(self, property_ids: list[str]) -> dict[str, Any]:
        ids = list(dict.fromkeys(_text(value) for value in property_ids if _text(value)))
        if not MIN_PROPERTIES <= len(ids) <= MAX_PROPERTIES:
            raise ValueError(
                "Select between two and three properties to compare."
            )

        candidates = RecommendationCandidateRepository(self.analytics).list_candidates(
            property_ids=ids
        )
        by_id = {item["property_id"]: item for item in candidates}
        # Preserve the entrepreneur's selection order, but never invent a row
        # for an id the authoritative query did not resolve.
        resolved = [by_id[pid] for pid in ids if pid in by_id]
        missing_ids = [pid for pid in ids if pid not in by_id]

        catalog = CatalogRepository(self.analytics)
        details_service = CatalogListingDetailsService(
            self.analytics, self.operational
        )
        panoramas = panoramas_by_catalogue_ids(self.operational, ids)

        properties: list[dict[str, Any]] = []
        for candidate in resolved:
            pid = candidate["property_id"]
            row = catalog.get_property(pid) or {}
            details = details_service.get_details(pid)
            panorama = panoramas.get(pid) or dict(PANORAMA_UNAVAILABLE)
            properties.append(
                self._property(candidate, row, details, panorama)
            )

        differences = self._differences(properties)
        insights = _superlatives(properties)
        tradeoffs = self._tradeoffs(properties, differences)
        return {
            "selected_count": len(ids),
            "resolved_count": len(properties),
            "unresolved_ids": missing_ids,
            "properties": properties,
            "differences": differences,
            "insights": [
                {
                    "property_id": item["property_id"],
                    "title": item["title"],
                    "points": insights.get(item["title"], []),
                }
                for item in properties
                if insights.get(item["title"])
            ],
            "tradeoffs": tradeoffs,
            "notes": [
                "Fewer recorded competitors may reflect a quieter area or an "
                "established commercial district. No claim about demand, "
                "profit or success is implied.",
                "A missing measurement is shown as unavailable. It is never "
                "treated as zero and never penalises a property.",
                "Population figures are counts within the stated radius, not "
                "population density. Nearby public parking is not parking "
                "provided by the property.",
            ],
        }

    @staticmethod
    def _property(
        candidate: dict[str, Any],
        row: dict[str, Any],
        details: dict[str, Any],
        panorama: dict[str, Any],
    ) -> dict[str, Any]:
        pid = candidate["property_id"]
        rent = _num(candidate.get("monthly_rental_myr"))
        size = _num(candidate.get("built_up_sqft"))
        psf = rent / size if rent is not None and size not in (None, 0) else None
        raw_metrics: dict[str, Any] = {
            "monthly_rent_rm": rent,
            "size_sqft": size,
            "rent_per_sqft": psf,
            "floor_level_text": (
                _text(details.get("floor_level"))
                or _text(candidate.get("floor_level_text"))
            ),
            "has_parking": (
                details.get("has_parking")
                if isinstance(details.get("has_parking"), bool)
                else None
            ),
            "population_500m": _num(candidate.get("population_500m_exact")),
            "population_1000m": _num(candidate.get("population_1000m")),
            "nearest_transit_walk_m": _num(candidate.get("nearest_transit_walk_m")),
            "bus_stops_500m_walk": _num(candidate.get("bus_stops_500m_walk")),
            "walk_isochrone_area_10min_km2": _num(
                candidate.get("walk_isochrone_area_10min_km2")
            ),
            "parking_facilities_500m": _num(candidate.get("parking_facilities_500m")),
            "office_pois_500m": _num(candidate.get("office_pois_500m")),
            "universities_count_500m": _num(candidate.get("universities_count_500m")),
            "malls_count_500m": _num(candidate.get("malls_count_500m")),
            "fnb_competitors_500m": _num(candidate.get("fnb_competitors_500m")),
            "fnb_competitors_1000m": _num(candidate.get("fnb_competitors_1000m")),
            "nearest_competitor_distance_m": _num(
                candidate.get("nearest_competitor_distance_m")
            ),
            "cafe_count_500m": _num(candidate.get("cafe_count_500m")),
            "restaurant_count_500m": _num(candidate.get("restaurant_count_500m")),
            "fast_food_count_500m": _num(candidate.get("fast_food_count_500m")),
        }
        metrics: dict[str, dict[str, Any]] = {}
        gaps: list[dict[str, str]] = []
        for key, (label, unit, radius, group, source) in _METRICS.items():
            value = raw_metrics.get(key)
            available = value is not None and not (
                isinstance(value, str) and not value
            )
            metrics[key] = {
                "value": value if available else None,
                "available": available,
                "label": label,
                "unit": unit,
                "radius_m": radius,
                "group": group,
                "source": source,
                "display": _fmt(value, unit) if available and isinstance(value, (int, float)) else (
                    ("Yes" if value else "No") if key == "has_parking" and available else (
                        value if available and isinstance(value, str) else "Data not available"
                    )
                ),
            }
            if not available:
                gaps.append(
                    {
                        "metric": key,
                        "label": label,
                        "reason": "No verified measurement is recorded for this property.",
                    }
                )

        # Only an approved + published linked listing confirms current
        # availability. A research status is context, never a confirmation.
        verified = details.get("verified_listing") is True
        availability_text = _text(details.get("availability")).upper()
        confirmed = verified and availability_text in {
            "AVAILABLE",
            "VERIFIED_AVAILABLE",
            "CONFIRMED",
        }
        research_status = _text(candidate.get("availability_status"))
        pu_raw = _num(candidate.get("pu_association_score"))
        return {
            "property_id": pid,
            "title": _text(candidate.get("title")) or _text(row.get("title")),
            "address": _text(candidate.get("address")),
            "city": _text(candidate.get("city")),
            "state": _text(candidate.get("state")),
            "postcode": _text(candidate.get("postcode")),
            "property_type": _text(candidate.get("property_type")),
            "image_url": candidate.get("image_url") or row.get("image_url"),
            "panorama": {
                "available": panorama.get("available") is True
                and panorama.get("status") == "ready"
                and bool(_text(panorama.get("url"))),
                "status": panorama.get("status"),
                "url": panorama.get("url") if panorama.get("available") is True
                and panorama.get("status") == "ready" else None,
            },
            "availability": {
                "confirmed": confirmed,
                "status": availability_text if confirmed else "Not confirmed",
                "research_status": research_status or "UNKNOWN_NOT_VERIFIED",
                "notice": details.get("data_notice"),
            },
            "verification": {
                "verified_listing": verified,
                "provenance": details.get("provenance", "research_unverified"),
            },
            "research_index": {
                "value": pu_raw * 100 if pu_raw is not None else None,
                "available": pu_raw is not None,
                "meaning": (
                    "Uncalibrated P-vs-U research association index (0–100), "
                    "supporting context only — not used to rank this comparison."
                ),
            },
            "metrics": metrics,
            "data_gaps": gaps,
        }

    @staticmethod
    def _differences(properties: list[dict[str, Any]]) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        for index, a in enumerate(properties):
            for b in properties[index + 1 :]:
                for key in _COMPARABLE:
                    first, second = a["metrics"][key], b["metrics"][key]
                    if not first["available"] or not second["available"]:
                        continue
                    delta = second["value"] - first["value"]
                    if abs(delta) < 1e-9:
                        continue
                    result.append(
                        {
                            "metric": key,
                            "from_id": a["property_id"],
                            "to_id": b["property_id"],
                            "from_title": a["title"],
                            "to_title": b["title"],
                            "value": delta,
                            "unit": first["unit"],
                            "radius_m": first["radius_m"],
                            "sentence": _sentence(a, b, key, delta),
                        }
                    )
        return result

    @staticmethod
    def _tradeoffs(
        properties: list[dict[str, Any]],
        differences: list[dict[str, Any]],
    ) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        by_pair: dict[tuple[str, str], dict[str, dict[str, Any]]] = {}
        for item in differences:
            pair = (item["from_id"], item["to_id"])
            by_pair.setdefault(pair, {})[item["metric"]] = item
        for (from_id, to_id), values in by_pair.items():
            rent = values.get("monthly_rent_rm")
            size = values.get("size_sqft")
            if rent and size and (rent["value"] > 0) == (size["value"] > 0):
                bigger = rent["to_title"] if size["value"] > 0 else rent["from_title"]
                cheaper = rent["from_title"] if rent["value"] > 0 else rent["to_title"]
                result.append(
                    {
                        "property_ids": [from_id, to_id],
                        "text": (
                            f"{bigger} offers {abs(size['value']):,.0f} sq ft more "
                            f"space, but costs RM {abs(rent['value']):,.0f} more "
                            f"per month. {cheaper} has the lower monthly commitment."
                        ),
                    }
                )
            transit = values.get("nearest_transit_walk_m")
            if rent and transit and (rent["value"] > 0) != (transit["value"] > 0):
                closer = transit["from_title"] if transit["value"] > 0 else transit["to_title"]
                cheaper = rent["from_title"] if rent["value"] > 0 else rent["to_title"]
                result.append(
                    {
                        "property_ids": [from_id, to_id],
                        "text": (
                            f"{closer} is closer to recorded public transport, "
                            f"while {cheaper} has the lower monthly rental."
                        ),
                    }
                )
        if not result:
            result.append(
                {
                    "property_ids": [item["property_id"] for item in properties],
                    "text": (
                        "The selected properties do not have enough comparable "
                        "measurements to state a reliable trade-off."
                    ),
                }
            )
        return result
