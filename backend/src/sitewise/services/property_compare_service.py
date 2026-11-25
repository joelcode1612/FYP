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

import re
from typing import Any

from sqlmodel import Session

from sitewise.domain.recommendation_scoring import (
    PreferenceProfile,
    preference_profile_from,
)
from sitewise.ml.pu_expanded import expanded_display_scores
from sitewise.repositories.catalog_repository import CatalogRepository
from sitewise.repositories.recommendation_candidate_repository import (
    _EXPLICITLY_UNAVAILABLE,
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
        "fyp.property_inference_features.nearest_transit_walk_m",
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
        "saved property inference snapshot competitor count, 500 m radius",
    ),
    "fnb_competitors_1000m": (
        "Recorded F&B competitors",
        "outlets",
        1000,
        "competition",
        "saved property inference snapshot competitor count, 1 km radius",
    ),
    "nearest_competitor_distance_m": (
        "Nearest recorded competitor",
        "m",
        None,
        "competition",
        "saved property inference snapshot competitor distance",
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


#: SiteWise property id conventions. Catalogue ids carry an EP-/MD- prefix;
#: operational commercial listings are plain integers (fyp.rental_properties).
_CATALOGUE_ID = re.compile(r"^(EP|MD)-\S+$", re.IGNORECASE)
_NUMERIC_ID = re.compile(r"^\d+$")


#: Why a selected id could not be resolved — shown verbatim by both clients.
_UNRESOLVED_REASONS = {
    "catalogue": "No research-catalogue property exists with this id.",
    "operational": (
        "No published, administrator-approved commercial listing exists with "
        "this id."
    ),
    "invalid": "This is not a recognised SiteWise property id.",
}


def _classify(property_id: str) -> str:
    """``catalogue`` | ``operational`` | ``invalid`` — never a guess."""
    if _CATALOGUE_ID.match(property_id):
        return "catalogue"
    if _NUMERIC_ID.match(property_id):
        return "operational"
    return "invalid"


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


def _rm(value: float) -> str:
    return f"RM {value:,.0f}"


def _area(value: float) -> str:
    return f"{value:,.0f} sq ft"


def _joined(values: list[str | None]) -> str:
    """Readably join the parts that exist, so an unset bound never prints."""
    parts = [text for value in values if (text := _text(value))]
    if not parts:
        return ""
    if len(parts) == 1:
        return parts[0]
    return f"{', '.join(parts[:-1])} and {parts[-1]}"


#: Status vocabulary for the preference-fit rows. No row carries a number that
#: could be read as a score: each states one recorded measurement against one
#: requirement the caller saved, and names the missing side when it cannot.
_FIT_MEETS = "meets"
_FIT_OUTSIDE = "outside"
_FIT_DIFFERS = "differs"
_FIT_NOT_STATED = "not_stated"
_FIT_NOT_RECORDED = "not_recorded"
_FIT_NOT_CAPTURABLE = "not_capturable"


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

    def _resolve(
        self, ids: list[str]
    ) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        """Resolve catalogue and operational ids from their own sources.

        Catalogue ids are resolved WITHOUT the search eligibility pre-filters:
        a shortlisted property whose recorded status later became RENTED is
        reported with that status (the UI shows it), never silently dropped —
        while Recommendations keeps its eligibility untouched. Operational ids
        resolve approved+published rows only; anything else stays unresolved
        with the access reason.
        """
        catalogue_ids = [pid for pid in ids if _classify(pid) == "catalogue"]
        operational_ids = [pid for pid in ids if _classify(pid) == "operational"]
        repo = RecommendationCandidateRepository(self.analytics)
        candidates = (
            repo.list_candidates(
                property_ids=catalogue_ids, skip_eligibility=True
            )
            if catalogue_ids
            else []
        )
        operational = (
            repo.list_operational_candidates(
                operational_ids, operational_session=self.operational
            )
            if operational_ids
            else []
        )
        return candidates, operational

    @staticmethod
    def _operational_details(candidate: dict[str, Any]) -> dict[str, Any]:
        """Listing-fact details for an operational property.

        These are the ROW's own recorded attributes (approved + published by
        an administrator), not research annotations. Availability confirmation
        follows the same rule as catalogue listings: a verified listing whose
        recorded availability says available.
        """
        availability = (candidate.get("availability_status") or "").upper()
        return {
            "floor_level": candidate.get("floor_level_text"),
            "has_parking": candidate.get("recorded_has_parking"),
            "availability": availability,
            "verified_listing": True,
            "provenance": "operational_verified_listing",
            "data_notice": None,
        }

    def compare(
        self,
        property_ids: list[str],
        *,
        preferences: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Compare the selected properties against each other and the caller.

        ``preferences`` is the requester's OWN stored business-requirements
        payload (decoded, not validated). It is used only to state whether a
        recorded measurement sits inside a requirement they wrote down — never
        to weight, rank or score anything, so the recommendation methodology
        stays untouched here.
        """
        ids = list(dict.fromkeys(_text(value) for value in property_ids if _text(value)))
        if not MIN_PROPERTIES <= len(ids) <= MAX_PROPERTIES:
            raise ValueError(
                "Select between two and three properties to compare."
            )

        candidates, operational_candidates = self._resolve(ids)
        by_id: dict[str, dict[str, Any]] = {}
        for item in (*candidates, *operational_candidates):
            by_id[item["property_id"]] = item
        # Preserve the entrepreneur's selection order, but never invent a row
        # for an id the authoritative query did not resolve.
        resolved = [by_id[pid] for pid in ids if pid in by_id]

        unresolved_ids: list[str] = []
        unresolved_details: list[dict[str, str]] = []
        for pid in ids:
            if pid in by_id:
                continue
            unresolved_ids.append(pid)
            unresolved_details.append({"id": pid, "reason": _UNRESOLVED_REASONS[_classify(pid)]})

        catalog = CatalogRepository(self.analytics)
        details_service = CatalogListingDetailsService(
            self.analytics, self.operational
        )
        # Panorama lookups are keyed by CATALOGUE id; operational listings use
        # their verified catalogue reference so both universes share one chain.
        catalogue_refs = [
            item["property_id"] if not item.get("operational_listing")
            else item.get("operational_catalogue_ref")
            for item in resolved
        ]
        panoramas = panoramas_by_catalogue_ids(
            self.operational, [ref for ref in catalogue_refs if ref]
        )
        scores = expanded_display_scores(
            self.analytics, list(dict.fromkeys(ref for ref in catalogue_refs if ref))
        )

        properties: list[dict[str, Any]] = []
        for candidate in resolved:
            pid = candidate["property_id"]
            if candidate.get("operational_listing"):
                row: dict[str, Any] = {}
                details = self._operational_details(candidate)
                panorama_ref = candidate.get("operational_catalogue_ref") or ""
            else:
                row = catalog.get_property(pid) or {}
                details = details_service.get_details(pid)
                panorama_ref = pid
            panorama = panoramas.get(panorama_ref) or dict(PANORAMA_UNAVAILABLE)
            properties.append(
                self._property(candidate, row, details, panorama, scores.get(panorama_ref))
            )

        differences = self._differences(properties)
        insights = _superlatives(properties)
        tradeoffs = self._tradeoffs(properties, differences)
        profile = preference_profile_from(preferences)
        saved = bool(preferences)
        if saved:
            for prop in properties:
                prop["preference_fit"] = self._preference_fit(prop, profile)
        return {
            "selected_count": len(ids),
            "resolved_count": len(properties),
            "unresolved_ids": unresolved_ids,
            "unresolved_details": unresolved_details,
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
            "preference_fit_basis": {
                "saved": saved,
                "statement": (
                    "Each fit row states one recorded property fact against a "
                    "requirement you saved. These are not scores, they carry no "
                    "weighting, and they are separate from the research index."
                    if saved
                    else "No saved business requirements were found for this "
                    "account, so fit against your requirements is not "
                    "available. Save them under Preferences to compare the "
                    "properties against your own budget, floor area, property "
                    "type and parking requirement."
                ),
                "not_compared": [
                    (
                        "Saved location preferences are not re-applied here; "
                        "this page shows the recorded address and the measured "
                        "surroundings instead."
                    ),
                    (
                        "Accessibility features are not recorded in either the "
                        "research catalogue or the verified listing data, so a "
                        "saved accessibility requirement cannot be checked here."
                    ),
                ],
            },
            "notes": [
                (
                    "Fewer recorded competitors may reflect a quieter area or an "
                    "established commercial district. No claim about demand, "
                    "profit or success is implied."
                ),
                (
                    "A missing measurement is shown as unavailable. It is never "
                    "treated as zero and never penalises a property."
                ),
                (
                    "Population figures are counts within the stated radius, not "
                    "population density. Nearby public parking is not parking "
                    "provided by the property."
                ),
            ],
        }

    @staticmethod
    def _property(
        candidate: dict[str, Any],
        row: dict[str, Any],
        details: dict[str, Any],
        panorama: dict[str, Any],
        expanded_score: float | None = None,
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
        # Radius provenance: these two demand metrics may have been recorded
        # at 1 km when no 500 m key exists. The displayed radius must match
        # the measurement, never assume the field name.
        radius_provenance = {
            "universities_count_500m": candidate.get("universities_count_500m_radius_m"),
            "malls_count_500m": candidate.get("malls_count_500m_radius_m"),
        }
        for key, (label, unit, radius, group, source) in _METRICS.items():
            value = raw_metrics.get(key)
            available = value is not None and not (
                isinstance(value, str) and not value
            )
            proven_radius = radius_provenance.get(key)
            # `value` is the NUMERIC measurement channel (the Dart entity
            # casts it to num?). Booleans and text facts ride `display`
            # instead — a recorded parking flag or floor level must never
            # crash the client parse.
            numeric_value = (
                value
                if available and isinstance(value, (int, float))
                and not isinstance(value, bool)
                else None
            )
            # The display channel is chosen by the RECORDED TYPE, in this order:
            # a boolean fact is a Yes/No ("has_parking"), never "1" — `bool` is a
            # subclass of `int`, so it must be tested first; a number is
            # unit-formatted; text is shown as recorded.
            if not available:
                display = "Data not available"
            elif isinstance(value, bool):
                display = "Yes" if value else "No"
            elif isinstance(value, (int, float)):
                display = _fmt(value, unit)
            elif isinstance(value, str):
                display = value
            else:
                display = "Data not available"
            metrics[key] = {
                "value": numeric_value,
                "available": available,
                "label": label,
                "unit": unit,
                "radius_m": int(proven_radius) if available and proven_radius else radius,
                "group": group,
                "source": source,
                "display": display,
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
        if research_status.upper() in _EXPLICITLY_UNAVAILABLE:
            unavailable_notice = (
                f"Recorded research status: {research_status.upper()} — this "
                "property is no longer available for rental."
            )
        else:
            unavailable_notice = None
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
                "notice": unavailable_notice or details.get("data_notice"),
            },
            "verification": {
                "verified_listing": verified,
                "provenance": details.get("provenance", "research_unverified"),
            },
            "research_index": {
                "value": expanded_score,
                "available": expanded_score is not None,
                "meaning": (
                    "Expanded64 uncalibrated P-vs-U research association index (0-100), "
                    "supporting context only — not used to rank this comparison."
                ),
            },
            "metrics": metrics,
            "data_gaps": gaps,
            # Stable key: compare() fills it in only when the caller has saved
            # requirements, and the clients render "not available" otherwise.
            "preference_fit": [],
        }

    @staticmethod
    def _preference_fit(
        prop: dict[str, Any], profile: PreferenceProfile
    ) -> list[dict[str, str]]:
        """How ONE property sits against the bounds the caller saved.

        Deliberately not the recommendation scorer: no weights, tolerances or
        partial-credit type matching are used here. Property type is reported
        as recorded-text equality and nothing more, and a requirement this
        project has no measurement for is stated as unchecked rather than
        silently passed.
        """
        metrics = prop["metrics"]
        rows: list[dict[str, str]] = []

        def add(key: str, label: str, status: str, detail: str) -> None:
            rows.append(
                {"key": key, "label": label, "status": status, "detail": detail}
            )

        rent = _num(metrics["monthly_rent_rm"]["value"])
        size = _num(metrics["size_sqft"]["value"])

        # --- monthly rent against the saved budget ---
        budget = _joined(
            [
                f"{_rm(profile.max_rent_myr)} maximum"
                if profile.max_rent_myr is not None
                else None,
                f"{_rm(profile.min_rent_myr)} minimum"
                if profile.min_rent_myr is not None
                else None,
            ]
        )
        if not budget:
            add("budget", "Monthly rent", _FIT_NOT_STATED,
                "Your saved requirements do not state a monthly budget.")
        elif rent is None:
            add("budget", "Monthly rent", _FIT_NOT_RECORDED,
                f"No monthly rent is recorded for this property, so your saved "
                f"budget of {budget} is shown as not verifiable here.")
        elif profile.max_rent_myr is not None and rent > profile.max_rent_myr:
            add("budget", "Monthly rent", _FIT_OUTSIDE,
                f"{_rm(rent)} per month is {_rm(rent - profile.max_rent_myr)} "
                f"above the {_rm(profile.max_rent_myr)} maximum you saved.")
        elif profile.min_rent_myr is not None and rent < profile.min_rent_myr:
            add("budget", "Monthly rent", _FIT_OUTSIDE,
                f"{_rm(rent)} per month is below the "
                f"{_rm(profile.min_rent_myr)} minimum you saved.")
        else:
            add("budget", "Monthly rent", _FIT_MEETS,
                f"{_rm(rent)} per month is within your saved budget of {budget}.")

        # --- floor area against the saved range ---
        area = _joined(
            [
                f"{_area(profile.min_floor_area_sqft)} minimum"
                if profile.min_floor_area_sqft is not None
                else None,
                f"{_area(profile.max_floor_area_sqft)} maximum"
                if profile.max_floor_area_sqft is not None
                else None,
            ]
        )
        if not area:
            add("floor_area", "Floor area", _FIT_NOT_STATED,
                "Your saved requirements do not state a floor area.")
        elif size is None:
            add("floor_area", "Floor area", _FIT_NOT_RECORDED,
                f"No floor area is recorded for this property, so your saved "
                f"range of {area} is shown as not verifiable here.")
        elif profile.min_floor_area_sqft is not None and size < profile.min_floor_area_sqft:
            add("floor_area", "Floor area", _FIT_OUTSIDE,
                f"{_area(size)} is below the "
                f"{_area(profile.min_floor_area_sqft)} minimum you saved.")
        elif profile.max_floor_area_sqft is not None and size > profile.max_floor_area_sqft:
            add("floor_area", "Floor area", _FIT_OUTSIDE,
                f"{_area(size)} exceeds the "
                f"{_area(profile.max_floor_area_sqft)} maximum you saved.")
        else:
            add("floor_area", "Floor area", _FIT_MEETS,
                f"{_area(size)} is within your saved range of {area}.")

        # --- recorded type text against the saved type list ---
        wanted = [t for t in profile.preferred_property_types if t]
        actual = _text(prop["property_type"])
        if not wanted:
            add("property_type", "Property type", _FIT_NOT_STATED,
                "Your saved requirements do not state a property type.")
        elif not actual:
            add("property_type", "Property type", _FIT_NOT_RECORDED,
                "No property type is recorded for this property.")
        elif any(actual.lower() == wanted_type.lower() for wanted_type in wanted):
            add("property_type", "Property type", _FIT_MEETS,
                f"The recorded type \u2018{actual}\u2019 is one of the types you saved.")
        else:
            add("property_type", "Property type", _FIT_DIFFERS,
                f"The recorded type \u2018{actual}\u2019 is not one of the types you "
                f"saved ({_joined(wanted)}). The recorded text is compared "
                "exactly; similar types are not treated as matches.")

        # --- saved parking requirement against the verified listing flag ---
        parking = [t for t in profile.parking_requirements if t]
        parking_metric = metrics["has_parking"]
        if not parking:
            add("parking", "Parking", _FIT_NOT_STATED,
                "Your saved requirements do not mention parking.")
        elif not parking_metric["available"]:
            add("parking", "Parking", _FIT_NOT_RECORDED,
                f"Your requirements mention {_joined(parking)}. No on-site "
                "parking value is recorded for this property, so it reads as "
                "unavailable rather than as no parking.")
        elif parking_metric["display"] == "Yes":
            add("parking", "Parking", _FIT_MEETS,
                f"Your requirements mention {_joined(parking)} and the verified "
                "listing records on-site parking.")
        else:
            add("parking", "Parking", _FIT_DIFFERS,
                f"Your requirements mention {_joined(parking)}; the verified "
                "listing records no on-site parking. Public parking nearby is "
                "a separate measurement, not parking provided by the property.")

        # --- requirements no source can answer ---
        accessibility = [t for t in profile.accessibility_requirements if t]
        if accessibility:
            add("accessibility", "Accessibility", _FIT_NOT_CAPTURABLE,
                f"Your requirements mention {_joined(accessibility)}. No "
                "accessibility attribute is recorded for any property in "
                "either source, so this cannot be checked here.")
        return rows

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
