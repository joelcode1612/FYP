"""Read-only location analysis supporting administrator verification review.

Assembles the verification-support report from state the existing pipelines
have already persisted — enrichment category rows, the wide geospatial feature
row, the verified-link population snapshot, research subject features, feature
freshness and source provenance. Every measurement carries its source and
method; a measurement that does not exist is reported as unavailable with its
reason, never as zero.

The service NEVER writes, never verifies a listing or ownership dimension,
never sets ``publication_eligible`` or ``is_published``, and never auto-approves
anything: those remain administrator decisions (§9 policy separation).
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

from sitewise.repositories.fyp_property_repository import FypPropertyRepository
from sitewise.services.property_verification_service import (
    rental_listing,
    verification_row,
)

ANALYSIS_VERSION = "2026.11-1"

STATE_READY = "ready_for_admin_review"
STATE_ADDITIONAL_INFO = "additional_information_required"
STATE_INCOMPLETE = "analysis_incomplete"
STATE_VALIDATION_FAILED = "validation_failed"
STATE_NOT_SUBMITTED = "not_submitted"

_CHECK_OK = "ok"
_CHECK_WARNING = "warning"
_CHECK_MISSING = "missing"
_CHECK_FAILED = "failed"

_RESOLUTION_NOTES = [
    "Population figures are modelled raster estimates; the ambient "
    "(LandScan) figure is a different measurement concept and is reported "
    "separately — the two are never added or averaged.",
    "Income figures are DOSM district-level medians, not property-level "
    "measurements; the district is labelled whenever one is shown.",
    "All radii and distances are straight-line (geodesic) measurements, "
    "not walking or driving distances.",
    "Competitor counts come from the fnb_a research outlet datasets within "
    "the study area; they describe the surroundings, not the likelihood "
    "that a specific business succeeds.",
]


def _now_iso() -> str:
    return datetime.now(UTC).isoformat()


def _num(value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _block(available: bool, method: str, source: str, **values: Any) -> dict[str, Any]:
    out: dict[str, Any] = {
        "available": available,
        "method": method,
        "source": source,
    }
    out.update(values)
    return out


class LocationAnalysisService:
    """Assembles Parts A/B/C and the recommendation for one rental listing."""

    def __init__(self, session: Session):
        self.session = session
        self._repo = FypPropertyRepository(session)

    def analyze(self, property_id: int) -> dict[str, Any]:
        listing = rental_listing(self.session, property_id)
        if listing is None:
            return {
                "analysis_version": ANALYSIS_VERSION,
                "generated_at": _now_iso(),
                "available": False,
                "error": "Property not found.",
            }

        geo = self._repo.get_geo_features(property_id)
        population = self._repo.get_population(property_id)
        research = self._repo.get_research_evidence(property_id)
        population_extra = self._population_extra(property_id)
        enrichment = self._enrichment_states(property_id)
        photos_count = self._photos_count(property_id)
        ownership_docs = self._ownership_documents_count(property_id)
        verification = verification_row(self.session, property_id)

        from sitewise.ingestion.state import RefreshState

        refresh = RefreshState(self.session)
        freshness = refresh.freshness_payload(property_id)
        provenance = refresh.provenance_summary()

        research_association = self._research_association(property_id, listing)

        part_a = self._part_a(
            listing, verification, photos_count, ownership_docs, enrichment, geo
        )
        part_b = self._part_b(
            listing, geo, population, population_extra, research, enrichment,
            research_association,
        )
        part_c = self._part_c(part_b, enrichment, freshness, provenance)
        recommendation = self._recommendation(part_a, part_c, verification, listing)

        return {
            "analysis_version": ANALYSIS_VERSION,
            "generated_at": _now_iso(),
            "available": True,
            "part_a": part_a,
            "part_b": part_b,
            "part_c": part_c,
            "recommendation": recommendation,
        }

    # ------------------------------------------------------------------
    # persisted-state reads
    # ------------------------------------------------------------------

    def _population_extra(self, property_id: int) -> dict[str, Any] | None:
        """LandScan ambient figures, raster coverage and the DOSM district key
        from the same verified-link population snapshot."""
        row = self.session.execute(
            text(
                """
                SELECT p.ambient_population_1km,
                       p.ambient_to_resident_ratio_1km,
                       p.landscan_source_year,
                       p.population_raster_coverage_pct,
                       p.dosm_district_key
                FROM fyp.property_subject_links l
                JOIN fyp_features.property_population_spatial p
                    ON p.source_record_id = l.subject_id
                    AND p.source_record_type IN
                        ('PROPERTY_UNLABELED', 'SITEWISE_U_PROPERTY')
                WHERE l.property_id = :pid AND l.match_verified
                ORDER BY p.source_record_type
                LIMIT 1
                """
            ),
            {"pid": property_id},
        ).mappings().first()
        return dict(row) if row else None

    def _enrichment_states(self, property_id: int) -> dict[str, str]:
        rows = self.session.execute(
            text(
                "SELECT category, status FROM fyp.property_enrichment_category "
                "WHERE property_id = :pid AND left(category, 11) <> 'expanded64_'"
            ),
            {"pid": property_id},
        ).all()
        return {row[0]: row[1] for row in rows}

    def _photos_count(self, property_id: int) -> int:
        row = self.session.execute(
            text(
                "SELECT count(*) FROM fyp.property_photos WHERE property_id = :pid"
            ),
            {"pid": property_id},
        ).scalar()
        return int(row or 0)

    def _ownership_documents_count(self, property_id: int) -> int:
        row = self.session.execute(
            text(
                "SELECT count(*) FROM fyp.verification_document "
                "WHERE property_id = :pid AND verification_type = 'ownership'"
            ),
            {"pid": property_id},
        ).scalar()
        return int(row or 0)

    def _research_association(self, property_id: int, listing: dict[str, Any]) -> dict[str, Any]:
        from sitewise.services.expanded64_enrichment import persisted_association

        return persisted_association(
            self.session, property_id, listing.get("latitude"), listing.get("longitude"),
        )

    # ------------------------------------------------------------------
    # Part A — listing verification readiness
    # ------------------------------------------------------------------

    def _part_a(
        self,
        listing: dict[str, Any],
        verification: Any,
        photos_count: int,
        ownership_docs: int,
        enrichment: dict[str, str],
        geo: dict[str, Any] | None,
    ) -> dict[str, Any]:
        latitude = _num(listing.get("latitude"))
        longitude = _num(listing.get("longitude"))
        coords_ok = latitude is not None and longitude is not None
        coords_in_range = coords_ok and -90 <= latitude <= 90 and -180 <= longitude <= 180
        address = (listing.get("address") or "").strip()
        listing_status = (
            verification.listing_status if verification is not None else "not_submitted"
        )
        ownership_status = (
            verification.ownership_status if verification is not None else "not_submitted"
        )

        running = sorted(c for c, s in enrichment.items() if s == "running")
        failed = sorted(c for c, s in enrichment.items() if s == "failed")
        stale = sorted(c for c, s in enrichment.items() if s == "stale")
        enrichment_state = "running" if running else (
            "failed" if failed else ("measured" if enrichment else "not_run")
        )

        ownership_doc_state = _CHECK_OK
        ownership_doc_detail = "Ownership evidence on file."
        if ownership_status == "not_submitted":
            ownership_doc_state = _CHECK_OK
            ownership_doc_detail = (
                "Listing-scope submission — ownership was not submitted."
            )
        elif ownership_docs == 0:
            ownership_doc_state = _CHECK_MISSING
            ownership_doc_detail = (
                "Ownership review is in progress but no ownership document "
                "is on file."
            )

        checks = [
            {
                "id": "coordinates",
                "label": "Location coordinates",
                "status": _CHECK_OK if coords_in_range
                else (_CHECK_FAILED if coords_ok else _CHECK_MISSING),
                "detail": "Coordinates are present and within valid ranges."
                if coords_in_range
                else ("Coordinates are outside valid ranges."
                      if coords_ok else "No coordinates were provided."),
            },
            {
                "id": "address",
                "label": "Address",
                "status": _CHECK_OK if address else _CHECK_MISSING,
                "detail": (
                    f"Address on file: {address[:160]}"
                    if address
                    else "No address was provided."
                ),
            },
            {
                "id": "photos",
                "label": "Listing photographs",
                "status": _CHECK_OK if photos_count > 0 else _CHECK_MISSING,
                "detail": f"{photos_count} photograph(s) uploaded."
                if photos_count > 0
                else "No photographs have been uploaded.",
            },
            {
                "id": "location_measurements",
                "label": "Location measurements",
                "status": _CHECK_OK if enrichment_state == "measured"
                else (_CHECK_WARNING if enrichment_state in ("running", "not_run")
                      else _CHECK_FAILED),
                "detail": {
                    "measured": "All measurement categories have settled.",
                    "running": "Measurements are still running: "
                    + ", ".join(running) + ".",
                    "not_run": "No location measurement has been run yet.",
                    "failed": "Measurement failed for: " + ", ".join(failed) + ".",
                }[enrichment_state],
            },
            {
                "id": "ownership_documents",
                "label": "Ownership evidence",
                "status": ownership_doc_state,
                "detail": ownership_doc_detail,
            },
            {
                "id": "review_state",
                "label": "Review state",
                "status": _CHECK_OK if listing_status in ("pending", "under_review")
                else (_CHECK_WARNING
                      if listing_status in ("information_requested", "rejected")
                      else _CHECK_OK),
                "detail": f"Listing review status: {listing_status}.",
            },
        ]

        state = self._part_a_state(
            coords_in_range, listing_status, enrichment_state, geo, checks
        )

        return {
            "state": state,
            "listing_status": listing_status,
            "ownership_status": ownership_status,
            "checks": checks,
        }

    @staticmethod
    def _part_a_state(
        coords_in_range: bool,
        listing_status: str,
        enrichment_state: str,
        geo: dict[str, Any] | None,
        checks: list[dict[str, Any]],
    ) -> str:
        if not coords_in_range:
            return STATE_VALIDATION_FAILED
        if listing_status == "not_submitted":
            return STATE_NOT_SUBMITTED
        if enrichment_state in ("running", "failed") or (
            enrichment_state == "not_run" and geo is None
        ):
            return STATE_INCOMPLETE
        blocking = {
            "photos",
            "address",
            "ownership_documents",
        }
        if any(c["status"] in (_CHECK_MISSING, _CHECK_FAILED) for c in checks
               if c["id"] in blocking) or listing_status == "information_requested":
            return STATE_ADDITIONAL_INFO
        return STATE_READY

    # ------------------------------------------------------------------
    # Part B — F&B location intelligence
    # ------------------------------------------------------------------

    def _part_b(
        self,
        listing: dict[str, Any],
        geo: dict[str, Any] | None,
        population: dict[str, Any] | None,
        population_extra: dict[str, Any] | None,
        research: dict[str, Any] | None,
        enrichment: dict[str, str],
        research_association: dict[str, Any],
    ) -> dict[str, Any]:
        return {
            "population": self._population_family(
                population, population_extra, geo
            ),
            "socioeconomic": self._socioeconomic_family(
                population_extra, research, geo
            ),
            "fnb_environment": self._fnb_environment_family(
                listing, geo, research, population
            ),
            "accessibility": self._accessibility_family(
                listing, geo, research, enrichment
            ),
            "research_association": research_association,
        }

    @staticmethod
    def _population_family(
        population: dict[str, Any] | None,
        population_extra: dict[str, Any] | None,
        geo: dict[str, Any] | None,
    ) -> dict[str, Any]:
        method = (
            "Modelled raster population counts inside fixed rings around the "
            "listing. The ambient (LandScan) figure is a separate concept and "
            "is reported on its own row — the two are never combined."
        )
        if population:
            source = str(population.get("population_source") or "unknown source")
            year = population.get("population_source_year")
            extra = population_extra or {}
            ambient = _num(extra.get("ambient_population_1km"))
            return _block(
                True,
                method,
                f"{source}"
                + (f" ({year})" if year else ""),
                pop_500m=_num(population.get("pop_ring_0_500m")),
                pop_1km=_num(population.get("pop_total_1km")),
                pop_3km=_num(population.get("pop_total_3km")),
                pop_ring_500_1km=_num(population.get("pop_ring_500_1km")),
                density_1km=_num(population.get("pop_density_km2")),
                density_500m=_num(population.get("pop_density_500m_km2")),
                estimated_households_1km=_num(
                    population.get("estimated_households_1km")
                ),
                pct_age_20_34_1km=_num(population.get("pct_age_20_34_1km")),
                pct_age_15_64_1km=_num(population.get("pct_age_15_64_1km")),
                quality_flag=population.get("population_quality_flag"),
                raster_coverage_pct=_num(extra.get("population_raster_coverage_pct")),
                district_key=extra.get("dosm_district_key"),
                landscan_ambient_1km=ambient,
                landscan_ambient_ratio_1km=_num(
                    extra.get("ambient_to_resident_ratio_1km")
                ),
                landscan_source_year=extra.get("landscan_source_year"),
                unavailable_reason=None,
            )
        geo_pop_500 = _num(geo.get("population_500m")) if geo else None
        geo_pop_1km = _num(geo.get("population_1km")) if geo else None
        if geo_pop_500 is not None or geo_pop_1km is not None:
            return _block(
                True,
                "Precomputed catchment estimates from the geospatial feature "
                "snapshot (no verified research link for a ring-level snapshot).",
                "fyp.property_geospatial_features",
                pop_500m=geo_pop_500,
                pop_1km=geo_pop_1km,
                density_1km=None,
                density_500m=None,
                estimated_households_1km=None,
                pct_age_20_34_1km=None,
                pct_age_15_64_1km=None,
                quality_flag=None,
                raster_coverage_pct=None,
                district_key=None,
                landscan_ambient_1km=None,
                landscan_ambient_ratio_1km=None,
                landscan_source_year=None,
                unavailable_reason=None,
            )
        return _block(
            False,
            method,
            "worldpop / landscan",
            unavailable_reason=(
                "No population measurement exists for these coordinates — "
                "the figure is reported as unavailable, never estimated."
            ),
        )

    @staticmethod
    def _socioeconomic_family(
        population_extra: dict[str, Any] | None,
        research: dict[str, Any] | None,
        geo: dict[str, Any] | None,
    ) -> dict[str, Any]:
        method = (
            "DOSM household-income statistics aggregated to the district that "
            "contains the listing — a district-wide median, not a "
            "property-level income measurement."
        )
        district_key = (population_extra or {}).get("dosm_district_key")
        income = None
        if research is not None:
            income = _num(research.get("district_income_median_myr"))
        if income is None and geo is not None:
            income = _num(geo.get("income_median"))
        if income is None:
            return _block(
                False,
                method,
                "DOSM district income",
                unavailable_reason=(
                    "No district income figure is available for this area; "
                    "none is estimated."
                ),
            )
        return _block(
            True,
            method,
            "DOSM district income (district-level aggregation)",
            income_median=income,
            district_key=district_key,
            unavailable_reason=None,
        )

    @staticmethod
    def _fnb_environment_family(
        listing: dict[str, Any],
        geo: dict[str, Any] | None,
        research: dict[str, Any] | None,
        population: dict[str, Any] | None,
    ) -> dict[str, Any]:
        method = (
            "F&B competitors are research-outlet records inside the study "
            "area within straight-line radii (canonical contract: fnb_outlet "
            "in_target_region AND in_main_scope). Competition is context — "
            "an active surround can also mean demand; the report never "
            "reduces it to a good/bad verdict."
        )
        comp_500 = _num(geo.get("competitor_count_500m")) if geo else None
        comp_1km = _num(geo.get("competitor_count_1km")) if geo else None
        demand_500 = _num(geo.get("demand_generator_count_500m")) if geo else None
        demand_1km = _num(geo.get("demand_generator_count_1km")) if geo else None
        if comp_500 is None and comp_1km is None:
            return _block(
                False,
                method,
                "fnb_a research outlets / Overture places",
                unavailable_reason=(
                    "No F&B surrounding measurement has been calculated for "
                    "these coordinates."
                ),
            )
        breakdown = None
        nearest = None
        analysis_status = None
        if research is not None:
            breakdown = {
                "cafes_500m": _num(research.get("cafe_count_500m")),
                "restaurants_500m": _num(research.get("restaurant_count_500m")),
                "fast_food_500m": _num(research.get("fast_food_count_500m")),
            }
            nearest = _num(research.get("nearest_competitor_distance_m"))
            analysis_status = research.get("analysis_status")
        anchors = None
        if population is not None:
            anchors = {
                "malls_1km": _num(population.get("malls_count_1km")),
                "schools_1km": _num(population.get("schools_count_1km")),
                "universities_1km": _num(population.get("universities_count_1km")),
                "hospitals_1km": _num(population.get("hospitals_count_1km")),
                "office_poi_500m": _num(population.get("office_poi_count_500m")),
            }
        return _block(
            True,
            method,
            "fnb_a research outlets (competitors) · Overture places "
            "(demand generators) · research anchors",
            competitor_count_500m=comp_500,
            competitor_count_1km=comp_1km,
            competitor_status=geo.get("competitor_status") if geo else None,
            competitor_breakdown_500m=breakdown,
            nearest_competitor_m=nearest,
            research_analysis_status=analysis_status,
            demand_generator_count_500m=demand_500,
            demand_generator_count_1km=demand_1km,
            demand_status=geo.get("demand_status") if geo else None,
            nearby_anchors=anchors,
            owner_declared_fnb_suitable=listing.get("is_fnb_suitable"),
            unavailable_reason=None,
        )

    @staticmethod
    def _accessibility_family(
        listing: dict[str, Any],
        geo: dict[str, Any] | None,
        research: dict[str, Any] | None,
        enrichment: dict[str, str],
    ) -> dict[str, Any]:
        method = (
            "Accessibility combines the backend-calculated index and "
            "straight-line road metrics from the geospatial snapshot, with "
            "walking-distance transit and parking figures only when a "
            "verified research link exists."
        )
        if geo is None:
            return _block(
                False,
                method,
                "OSM roads · GTFS transit · parking facilities",
                unavailable_reason=(
                    "No accessibility measurement has been calculated for "
                    "these coordinates."
                ),
            )
        transit = None
        parking = None
        if research is not None:
            transit = {
                "bus_stops_500m_walk": _num(research.get("bus_stops_500m_walk")),
                "rail_stations_1km_walk": _num(research.get("rail_stations_1km_walk")),
                "nearest_transit_walk_m": _num(research.get("nearest_transit_walk_m")),
            }
            parking = {
                "facilities_500m": _num(research.get("parking_facilities_500m")),
                "nearest_parking_m": _num(research.get("nearest_parking_distance_m")),
                "status": research.get("parking_status"),
            }
        return _block(
            True,
            method,
            "OSM roads · GTFS transit (via verified link) · parking facilities",
            accessibility_score=_num(geo.get("accessibility_score")),
            accessibility_status=geo.get("accessibility_status"),
            road_km_1km=_num(geo.get("accessibility_road_km_1km")),
            nearest_major_road_m=_num(geo.get("nearest_major_road_m")),
            transit=transit,
            parking=parking,
            owner_declared_parking=listing.get("has_parking"),
            roads_transport_state=enrichment.get("roads_transport"),
            parking_state=enrichment.get("parking"),
            unavailable_reason=None,
        )

    # ------------------------------------------------------------------
    # Part C — data confidence
    # ------------------------------------------------------------------

    def _part_c(
        self,
        part_b: dict[str, dict[str, Any]],
        enrichment: dict[str, str],
        freshness: dict[str, Any] | None,
        provenance: dict[str, Any],
    ) -> dict[str, Any]:
        families = ["population", "socioeconomic", "fnb_environment",
                    "accessibility", "research_association"]
        available = [name for name in families if part_b[name].get("available")]
        missing = [
            {
                "family": name,
                "reason": part_b[name].get("unavailable_reason")
                or "Not measured for this listing.",
            }
            for name in families
            if name not in available
        ]
        outdated = []
        if freshness and freshness.get("status") in ("stale", "failed"):
            outdated.append(
                {
                    "what": "feature snapshot",
                    "status": freshness.get("status"),
                    "detail": freshness.get("last_error")
                    or "The last feature refresh did not fully succeed.",
                }
            )
        for category, status in sorted(enrichment.items()):
            if status in ("stale", "failed"):
                outdated.append(
                    {"what": f"measurement: {category}", "status": status,
                     "detail": None}
                )
        licences = [
            {
                "source": entry.get("source_name"),
                "licence": entry.get("source_licence"),
            }
            for entry in (provenance or {}).get("sources", [])
            if isinstance(entry, dict)
        ]
        return {
            "families_total": len(families),
            "families_available": len(available),
            "families_available_names": available,
            "missing": missing,
            "outdated": outdated,
            "resolution_notes": _RESOLUTION_NOTES,
            "licences": licences,
        }

    # ------------------------------------------------------------------
    # Recommendation (§9 — decision support, never a decision)
    # ------------------------------------------------------------------

    def _recommendation(
        self,
        part_a: dict[str, Any],
        part_c: dict[str, Any],
        verification: Any,
        listing: dict[str, Any],
    ) -> dict[str, Any]:
        focus: list[str] = [c["detail"] for c in part_a["checks"]
                            if c["status"] in (_CHECK_MISSING, _CHECK_FAILED,
                                               _CHECK_WARNING)]
        for gap in part_c["missing"]:
            focus.append(
                f"{gap['family'].replace('_', ' ')}: {gap['reason']}"
            )

        state = part_a["state"]
        if state == STATE_VALIDATION_FAILED:
            text = (
                "The listing's coordinates could not be used for location "
                "analysis, so no location intelligence can support this "
                "review yet. Ask the owner to correct the location before "
                "deciding."
            )
        elif state == STATE_INCOMPLETE:
            text = (
                "Location measurements have not settled for this listing. "
                "Any figures shown are partial; wait for the measurement to "
                "finish or use the retry action before reviewing."
            )
        elif state == STATE_ADDITIONAL_INFO:
            text = (
                "The listing is with the administrator but is missing "
                "evidence listed below. Consider requesting the missing "
                "items from the owner before deciding."
            )
        elif state == STATE_READY:
            text = (
                f"The listing looks ready for review: "
                f"{part_c['families_available']} of "
                f"{part_c['families_total']} location measurement families "
                "are available."
                + (
                    " The unavailable families are reported below — treat "
                    "them as unknown, not as zero."
                    if part_c["missing"]
                    else ""
                )
            )
        else:
            text = (
                "The owner has not submitted this listing for verification "
                "yet; the analysis below reflects the current state only."
            )

        return {
            "text": text,
            "policy_separation": [
                {
                    "domain": "listing_accuracy",
                    "current_status": part_a["listing_status"],
                    "note": "Administrator decision — the analysis never "
                    "sets or changes this status.",
                },
                {
                    "domain": "ownership",
                    "current_status": part_a["ownership_status"],
                    "note": "Administrator decision on the evidence documents "
                    "— the analysis never sets or changes this status.",
                },
                {
                    "domain": "location_suitability",
                    "current_status": None,
                    "note": "The measurements describe the surroundings; "
                    "whether the location suits the owner's business is the "
                    "owner's and administrator's judgement, not a score here.",
                },
                {
                    "domain": "publication_eligibility",
                    "current_status": bool(verification.publication_eligible)
                    if verification is not None
                    else False,
                    "is_published": bool(listing.get("is_published")),
                    "note": "Recomputed by the decision workflow after both "
                    "dimensions are decided — never by this analysis.",
                },
            ],
            "suggested_focus": focus,
        }
