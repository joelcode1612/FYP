"""Read-only orchestration for property -> five F&B concept compatibility.

The established expanded64 PU model stays untouched. The 54-feature,
four-class category research model is displayed only as EXPLORATORY context
and is never included in the compatibility score or sorted category ranks.
"""
from __future__ import annotations

from typing import Any

from sqlmodel import Session
from sqlalchemy import text

from sitewise.domain.business_concept_compatibility import FEATURES, evaluate_concepts
from sitewise.ml.fnb_category import category_prediction
from sitewise.ml.property_features import FeatureResolutionError, PropertyFeatureRepository
from sitewise.ml.pu_expanded import (
    active_expanded_model_name,
    expanded_display_scores,
)
from sitewise.repositories.catalog_repository import CatalogRepository
from sitewise.services.catalog_listing_details_service import CatalogListingDetailsService


class BusinessConceptService:
    def __init__(self, analytics_session: Session, operational_session: Session):
        self.analytics = analytics_session
        self.operational = operational_session

    def assess(self, property_id: str, *, monthly_budget_myr: float | None = None) -> dict[str, Any]:
        requested_id = property_id
        # Explore pages may carry an operational numeric ID. Only a verified
        # mapping is allowed; never guess which catalogue property it means.
        if property_id.isdecimal():
            matches = self.analytics.execute(text(
                "SELECT DISTINCT sitewise_property_id FROM fyp.property_subject_links "
                "WHERE property_id = :id AND match_verified IS TRUE "
                "AND sitewise_property_id IS NOT NULL LIMIT 2"
            ), {"id": int(property_id)}).scalars().all()
            if len(matches) == 1:
                property_id = str(matches[0])
        record = CatalogRepository(self.analytics).get_property(property_id)
        if record is None:
            raise LookupError("Property is not present in the research catalogue")
        details = CatalogListingDetailsService(self.analytics, self.operational).get_details(property_id)
        latitude, longitude = record.get("latitude"), record.get("longitude")
        try:
            lat = float(latitude)
            lon = float(longitude)
            coordinate_present = -90 <= lat <= 90 and -180 <= lon <= 180 and (lat, lon) != (0, 0)
        except (ValueError, TypeError):
            coordinate_present = False

        feature_flags: list[str] = []
        feature_sources: dict[str, str] = {}
        data = {key: None for key in FEATURES}
        try:
            bundle = PropertyFeatureRepository(self.analytics).get(property_id, list(FEATURES), source="catalog")
            data.update(bundle.values)
            feature_sources.update(bundle.value_sources)
            feature_flags.extend(bundle.flags)
            if bundle.analysis_status != "COMPLETED":
                feature_flags.append(f"Analysis status: {bundle.analysis_status or 'unknown'}")
        except FeatureResolutionError as exc:
            feature_flags.append(f"Location feature resolution unavailable: {exc}")
        # IMPORTANT: this comparison does not silently borrow training-only
        # age or population values from the expanded64 historical bridge.
        # If new listings lack comparable measurements, their ranks are withheld.
        compatibility = evaluate_concepts(
            data, sources=feature_sources, property_details=details,
            monthly_rental=record.get("rental_rm"), monthly_budget=monthly_budget_myr,
            coordinate_present=coordinate_present,
        )

        # Reuse the live deployed 64-input PU association index, NOT a new
        # category-specific score, and never interpret it as success odds.
        general_score: float | None = None
        general_error: str | None = None
        try:
            general_score = expanded_display_scores(self.analytics, [property_id]).get(property_id)
        except Exception as exc:  # model/library missing must not hide comparison
            general_error = f"{type(exc).__name__}: general PU score unavailable"
        general_pu = {
            "available": general_score is not None,
            # Name the artifact that actually produced the score: the display
            # index follows the active artifact, so a fixed name would
            # misattribute a v2 score to the original model.
            "model": active_expanded_model_name(),
            "association_index_0_100": general_score,
            "score_meaning": "research_P_vs_U_association_NOT_business_success_probability",
            "note": general_error or "Shared property-wide context only; identical for all five concepts and excluded from their ranking.",
        }

        # This is the existing ONE fitted 54-feature four-class research
        # classifier, not the four independent P-vs-U models in a separate
        # research ZIP. Its numbers are NOT compatible with the PU index.
        research: dict[str, Any]
        try:
            raw = category_prediction(self.analytics, property_id)
            research = {
                "available": raw.get("available") is True,
                "model_version": raw.get("model_version"),
                "model_kind": "54_feature_four_class_research_only",
                "rankings": raw.get("rankings", []) if raw.get("available") else [],
                "reason": raw.get("reason") if not raw.get("available") else None,
                "note": "Exploratory resemblance to observed outlet classes. Weak geographic validation; not an input to five-concept compatibility. Bakery and beverage share one class.",
            }
        except Exception as exc:
            research = {"available": False, "model_kind": "research_only",
                        "rankings": [], "reason": "Category research model unavailable",
                        "detail": type(exc).__name__}

        warnings = ["Property coordinates are not available; a location comparison cannot be ranked"] if not coordinate_present else [
            "Property coordinates are recorded but rooftop or field verification is not established by this endpoint"
        ]
        warnings.extend(feature_flags)
        if not details.get("verified_listing"):
            warnings.append("Physical attributes and current availability are research-listing data, not independently verified")
        warnings.append("Actual footfall, sales, profitability, licensing and cooking facilities have not been established")
        return {
            "requested_property_id": requested_id,
            "property_id": property_id,
            "property_title": record.get("title"),
            "available": compatibility["available"],
            "status": compatibility["status"],
            "general_pu": general_pu,
            "category_research": research,
            "concept_assessment": compatibility,
            "coordinate_available": coordinate_present,
            "evidence_flags": sorted(set(warnings)),
            "data_provenance": {
                "feature_sources": feature_sources,
                "premises": details.get("provenance"),
                "research_only": True,
            },
        }
