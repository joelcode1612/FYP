"""Read-only property report assembly over the ``fyp`` operational schema.

The report joins what the application can actually verify for one
APPROVED + PUBLISHED property: the listing itself, its stored photos and
listing sources, its precomputed geospatial features, and — through the
verified research subject link — the PU feature record and population
intelligence. Every section that has no backing data is reported as
explicitly ``available: false`` with a reason: nothing is fabricated, and
research feature values are never presented as success probabilities.

Pending, unpublished, rejected, or unknown-availability rows are reported
as 404 to consumers (same gating as the Explore endpoints). Catalogue
workbook references (``EP-xxxxx``) are also accepted.
"""

from fastapi import HTTPException
from sqlmodel import Session

from sitewise.repositories.fyp_property_repository import FypPropertyRepository


def _section(data, available: bool, reason: str) -> dict:
    if available:
        return {"available": True, "data": data}
    return {"available": False, "reason": reason}


class ReportService:
    def __init__(self, session: Session):
        self.session = session

    def generate_property_report(self, property_id: int | str) -> dict:
        ref = str(property_id)
        repo = FypPropertyRepository(self.session)

        resolved = repo.resolve_reference(ref)
        if resolved is None:
            raise HTTPException(
                status_code=404,
                detail=f"No published property matches reference '{ref}'.",
            )

        geo = None
        photos: list[dict] = []
        sources: list[dict] = []
        research = None
        population = None
        if resolved["source_schema"] == "fyp":
            fyp_id = int(resolved["property_id"])
            geo = repo.get_geo_features(fyp_id)
            photos = repo.get_photos(fyp_id)
            sources = repo.get_listing_sources(fyp_id)
            research = repo.get_research_evidence(fyp_id)
            population = repo.get_population(fyp_id)

        coords_present = (
            resolved.get("latitude") is not None
            and resolved.get("longitude") is not None
        )
        precomputed_counts = bool(geo and geo.get("competitor_count_500m") is not None)
        live_counts: dict = {}
        if coords_present and not precomputed_counts:
            live_counts = repo.competitor_counts(
                float(resolved["latitude"]), float(resolved["longitude"])
            )

        return {
            "property": {
                "property_id": resolved["property_id"],
                "source_schema": resolved["source_schema"],
                "name": resolved.get("name"),
                "property_type": resolved.get("property_type"),
                "address": resolved.get("address"),
                "city": resolved.get("city"),
                "state": resolved.get("state"),
                "latitude": resolved.get("latitude"),
                "longitude": resolved.get("longitude"),
                "rental_price": (
                    float(resolved["rental_price"])
                    if resolved.get("rental_price") is not None
                    else None
                ),
                "size_sqft": (
                    float(resolved["size_sqft"])
                    if resolved.get("size_sqft") is not None
                    else None
                ),
            },
            "listing_media": _section(
                {"photos": photos, "listing_sources": sources},
                bool(photos or sources),
                "No photos or listing sources are stored for this property.",
            ),
            "geospatial_features": _section(
                geo,
                geo is not None,
                "No precomputed geospatial features exist for this property.",
            ),
            "live_competitor_counts": _section(
                live_counts,
                bool(live_counts) and coords_present,
                (
                    "Precomputed geospatial features already cover this "
                    "property; live counts were not recomputed."
                    if precomputed_counts
                    else "Property coordinates are unavailable; live "
                    "competitor counts cannot be computed."
                ),
            ),
            "research_link": _section(
                research,
                research is not None,
                "This property has no verified research subject link (the "
                "verified-link set covers the unlabeled research candidates).",
            ),
            "population_intelligence": _section(
                population,
                population is not None,
                "Population intelligence resolves through the verified "
                "research subject link; none exists for this property.",
            ),
            "meta": {
                # Honest labeling: all research figures here are dataset
                # features/counts, never verified success probabilities.
                "scores_are_research_indexes": True,
            },
        }

    # -- assessment report --------------------------------------------------

    def generate_assessment_report(
        self,
        *,
        assessment: dict,
        property_report: dict | None,
        explanation: dict | None,
        evidence: dict | None = None,
    ) -> dict:
        """The five-stage report: property + answers + evidence + model + checks.

        ``assessment`` is the serialized record from ``AssessmentService``,
        ``property_report`` the property-level report above, ``explanation`` the
        verified SHAP payload (or None) and ``evidence`` the Stage-3 payload.
        Every section is included with an explicit availability flag; nothing
        is invented to make the document look complete.
        """
        requirements = assessment.get("requirements") or {}
        prop = (property_report or {}).get("property") or {}
        checks = requirement_matching(requirements, prop, evidence)

        return {
            "assessment_id": assessment.get("assessment_id"),
            "property_id": assessment.get("property_id"),
            "status": assessment.get("status"),
            "generated_at": _now_iso(),
            "requirements_version": assessment.get("requirements_version", 0),
            "questionnaire": _section(
                requirements or None,
                bool(requirements),
                "No business preferences have been saved for this assessment.",
            ),
            "property": _section(
                prop or None,
                bool(prop),
                "The listing is no longer present in the catalogue.",
            ),
            "listing_media": (property_report or {}).get("listing_media")
            or _section(None, False, "No photos or listing sources are stored."),
            "geospatial_features": (property_report or {}).get("geospatial_features")
            or _section(None, False, "No precomputed geospatial features exist."),
            "evidence_categories": _section(
                (evidence or {}).get("groups"),
                bool(evidence and evidence.get("available")),
                (evidence or {}).get("reason")
                or "No analysed location evidence exists for this property.",
            ),
            "research_association": _section(
                None
                if not explanation
                else {
                    "score": explanation.get("output"),
                    "base_value": explanation.get("base_value"),
                    "model_version": explanation.get("model_version"),
                    "feature_set": explanation.get("feature_set"),
                    "score_meaning": explanation.get("score_meaning"),
                },
                bool(explanation),
                "The PU research model did not produce a verified score for this "
                "property, so no association figure is reported.",
            ),
            "explanation": _section(
                None
                if not explanation
                else {
                    "explainer": explanation.get("explainer"),
                    "additivity_ok": explanation.get("additivity_ok"),
                    "groups": explanation.get("groups"),
                    "strongest_positive": explanation.get("strongest_positive"),
                    "strongest_negative": explanation.get("strongest_negative"),
                    "background_size": explanation.get("background_size"),
                },
                bool(explanation),
                "No verified SHAP explanation is available for this property.",
            ),
            "requirement_matching": checks,
            "missing_information": _missing_information(
                requirements, prop, evidence, explanation
            ),
            "model_information": {
                "model": "pu_model",
                "feature_set": (explanation or {}).get("feature_set"),
                "explainer": (explanation or {}).get("explainer"),
                "research_only": True,
                "score_meaning": (explanation or {}).get("score_meaning")
                or "research_positive_label_association_NOT_business_success_probability",
            },
            "export": {
                "pdf": False,
                "reason": (
                    "No server-side PDF generator is configured. The report is "
                    "complete and printable from the browser; a PDF is not "
                    "produced."
                ),
            },
            "meta": {"scores_are_research_indexes": True},
        }


def _now_iso() -> str:
    from datetime import UTC, datetime

    return datetime.now(UTC).isoformat()


def requirement_matching(
    requirements: dict, prop: dict, evidence: dict | None = None
) -> dict:
    """Supported constraint checks, each with an explicit verdict.

    Only rules that can be evaluated from stored data are reported. A check
    whose inputs are missing is ``unknown`` — never a silent pass, and never a
    synthesized compatibility percentage, because no scoring methodology for
    one has been approved.
    """
    checks: list[dict] = []

    def number(value):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        return float(value)

    rent_ceiling = number(requirements.get("max_monthly_rent_myr")) or number(
        requirements.get("max_budget_rm")
    )
    asking = number(prop.get("rental_price"))
    if rent_ceiling is None or asking is None:
        checks.append(
            _check(
                "affordability",
                "Affordability (monthly rent)",
                "unknown",
                "A rental ceiling or the listing rent is unavailable.",
            )
        )
    else:
        checks.append(
            _check(
                "affordability",
                "Affordability (monthly rent)",
                "match" if asking <= rent_ceiling else "mismatch",
                f"Asking RM {asking:,.0f} vs ceiling RM {rent_ceiling:,.0f}.",
                {"asking_rm": asking, "ceiling_rm": rent_ceiling},
            )
        )

    min_area = number(requirements.get("min_floor_area_sqft")) or number(
        requirements.get("min_size_sqft")
    )
    area = number(prop.get("size_sqft"))
    if min_area is None or area is None:
        checks.append(
            _check(
                "floor_area",
                "Floor area requirement",
                "unknown",
                "A minimum area or the listing area is unavailable.",
            )
        )
    else:
        checks.append(
            _check(
                "floor_area",
                "Floor area requirement",
                "match" if area >= min_area else "mismatch",
                f"Listing {area:,.0f} sq ft vs minimum {min_area:,.0f} sq ft.",
                {"listing_sqft": area, "minimum_sqft": min_area},
            )
        )

    access_mode = requirements.get("customer_access_mode")
    if access_mode and evidence and evidence.get("available"):
        metrics = {
            m.get("key"): m
            for group in evidence.get("groups") or []
            for m in group.get("metrics") or []
        }

        def measured(*keys: str) -> list[str]:
            return [
                k
                for k in keys
                if (metrics.get(k) or {}).get("status") == "available"
            ]

        wanted = {
            "walking": ("nearest_transit_walk_m", "bus_stops_500m_walk"),
            "public_transportation": (
                "nearest_transit_walk_m",
                "rail_stations_1km_walk",
            ),
            "private_vehicle": ("nearest_major_road_m", "parking_facilities_500m"),
            "mixed_transportation": (
                "nearest_transit_walk_m",
                "nearest_major_road_m",
            ),
        }.get(access_mode, ())
        present = measured(*wanted) if wanted else []
        checks.append(
            _check(
                "accessibility",
                "Customer access mode",
                "match" if present else "unknown",
                (
                    f"{access_mode} supported by measured "
                    f"{', '.join(present)}."
                    if present
                    else f"No measurement supports '{access_mode}' for this "
                    "property; the preference is unverified, not satisfied."
                ),
                {"access_mode": access_mode, "measured": present},
            )
        )

    competitors = None
    if evidence and evidence.get("available"):
        for group in evidence.get("groups") or []:
            if group.get("key") == "competition":
                for metric in group.get("metrics") or []:
                    if metric.get("key") == "competitor_count_500m":
                        competitors = metric.get("value")
    if requirements.get("fnb_concept") and competitors is not None:
        checks.append(
            _check(
                "competition_context",
                "Competitor context for the chosen concept",
                "informational",
                f"{competitors} F&B competitors are measured within 500 m; "
                "same-concept overlap is not separately measured.",
                {"competitor_count_500m": competitors},
            )
        )

    verdicts = [c["verdict"] for c in checks]
    return {
        "checks": checks,
        "matched": verdicts.count("match"),
        "mismatched": verdicts.count("mismatch"),
        "unknown": verdicts.count("unknown"),
        "note": (
            "Constraint checks only. No personalized compatibility percentage "
            "is produced because no scoring methodology has been approved."
        ),
    }


def _check(key, label, verdict, detail, data=None) -> dict:
    return {
        "key": key,
        "label": label,
        "verdict": verdict,
        "detail": detail,
        "data": data or {},
    }


def _missing_information(
    requirements: dict, prop: dict, evidence: dict | None, explanation: dict | None
) -> list[str]:
    gaps: list[str] = []
    if not requirements:
        gaps.append("Business preferences have not been saved.")
    if not prop:
        gaps.append("The property listing is no longer in the catalogue.")
    if not (evidence and evidence.get("available")):
        gaps.append("No analysed location evidence exists for this property.")
    if not explanation:
        gaps.append("No verified SHAP explanation was produced.")
    if explanation and explanation.get("missing_features"):
        gaps.append(
            f"{len(explanation['missing_features'])} model features were missing."
        )
    return gaps
