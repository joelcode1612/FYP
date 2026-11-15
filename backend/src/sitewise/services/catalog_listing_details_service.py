"""Safe physical listing details for the research catalogue.

A research property is NOT a published/approved operational listing.
Research values come from the recorded U-class subject features; operational
values are used only for a precisely linked, approved AND published listing.
No schema migrations, inserts, AI score changes or fuzzy record matching.
"""
from __future__ import annotations

import math
from datetime import date, datetime
from decimal import Decimal
from typing import Any

from sqlalchemy import text
from sqlmodel import Session


_LISTING_SQL = text("""
SELECT p.id, p.description, p.floor_level, p.floor_description,
       p.bathrooms, p.furnishing, p.tenure, p.frontage_ft, p.depth_ft,
       p.land_area_sqft, p.built_up_sqft, p.unit_position, p.facing_direction,
       p.availability, p.availability_verified_at, p.updated_at,
       p.has_parking, p.is_corner_lot, p.is_freehold
FROM fyp.property_subject_links AS l
JOIN fyp.rental_properties AS p ON p.id = l.property_id
WHERE l.sitewise_property_id = :pid
  AND l.match_verified IS TRUE
  AND p.is_published IS TRUE
  AND p.verification_status = 'approved'
LIMIT 2
""")

_RESEARCH_SQL = text("""
SELECT p.source_data,
       f.other_features
FROM fyp.catalogue_properties AS p
LEFT JOIN LATERAL (
    SELECT s.other_features
    FROM sitewise_analytics.subject_features AS s
    WHERE s.canonical_property_id = p.id
      AND btrim(s.sample_class) = 'U'
    ORDER BY s.imported_at DESC NULLS LAST
    LIMIT 1
) AS f ON TRUE
WHERE p.id = :pid
""")


def _text(data: dict, *keys: str) -> str | None:
    for key in keys:
        value = data.get(key)
        if value is not None and not isinstance(value, bool):
            v = str(value).strip()
            if v and v.lower() not in {"null", "nan", "n/a", "unknown", "not provided"}:
                return v
    return None


def _number(data: dict, *keys: str) -> float | None:
    for key in keys:
        value = data.get(key)
        if value is None or isinstance(value, bool):
            continue
        try:
            n = float(value)
            if math.isfinite(n) and n >= 0:
                return n
        except (TypeError, ValueError):
            pass
    return None


def _integer(data: dict, *keys: str) -> int | None:
    n = _number(data, *keys)
    return int(n) if n is not None and n.is_integer() else None


def _flag(data: dict, *keys: str) -> bool | None:
    for key in keys:
        value = data.get(key)
        if isinstance(value, bool):
            return value
        if isinstance(value, (str, int)):
            item = str(value).strip().lower()
            if item in {"yes", "true", "1"}:
                return True
            if item in {"no", "false", "0"}:
                return False
    return None


def _date(value: Any) -> str | None:
    return value.isoformat() if isinstance(value, (date, datetime)) else None


class CatalogListingDetailsService:
    def __init__(self, analytics_session: Session, operational_session: Session):
        self.analytics = analytics_session
        self.operational = operational_session

    def get_details(self, catalogue_id: str) -> dict[str, Any]:
        """Return optional fields for one existing research catalogue property.

        Never treats unknown values as false or zero. A verified research
        subject match is NOT the same as verified premises or availability.
        """
        row = self.analytics.execute(
            _RESEARCH_SQL, {"pid": catalogue_id}
        ).mappings().first()
        if row is None:
            return {"available": False, "reason": "No catalogue record"}
        raw = dict(row)
        extra = raw.get("other_features")
        extra = extra if isinstance(extra, dict) else {}
        source = raw.get("source_data")
        source = source if isinstance(source, dict) else {}

        # Only features genuinely recorded for this U-class research subject.
        # A missing property attribute remains None, never invented from title.
        fields: dict[str, Any] = {
            "description": _text(extra, "property_description", "description"),
            "floor_level": _text(extra, "property_floor_level", "floor_level"),
            "bathrooms": _integer(extra, "property_bathrooms", "bathrooms"),
            "furnishing": _text(extra, "property_furnishing", "furnishing"),
            "tenure": _text(extra, "property_tenure", "tenure"),
            "frontage_ft": _number(extra, "property_frontage_ft", "frontage_ft"),
            "depth_ft": _number(extra, "property_depth_ft", "depth_ft"),
            "land_area_sqft": _number(extra, "property_land_area_sqft", "land_area_sqft"),
            "built_up_sqft": _number(extra, "property_built_up_sqft", "built_up_sqft"),
            "unit_position": _text(extra, "property_unit_position", "unit_position"),
            "facing_direction": _text(extra, "property_facing_direction", "facing_direction"),
            "has_parking": _flag(extra, "property_has_parking", "has_parking"),
            "is_corner_lot": _flag(extra, "property_is_corner_lot", "is_corner_lot"),
            "is_freehold": _flag(extra, "property_is_freehold", "is_freehold"),
            "availability": None,
            "availability_verified_at": None,
            # Not the same as regulatory permission to operate F&B.
            "is_fnb_suitable": None,
        }
        provenance = "research_unverified"
        verified_listing = False

        # A matching operational row can enrich this response only when the
        # public listing has already passed verification and publication.
        published_rows = self.operational.execute(
            _LISTING_SQL, {"pid": catalogue_id}
        ).mappings().all()
        if len(published_rows) == 1:
            p = dict(published_rows[0])
            published: dict[str, Any] = {
                "description": _text(p, "description"),
                "floor_level": _text(p, "floor_description") or (
                    _text(p, "floor_level")
                ),
                "bathrooms": _integer(p, "bathrooms"),
                "furnishing": _text(p, "furnishing"),
                "tenure": _text(p, "tenure"),
                "frontage_ft": _number(p, "frontage_ft"),
                "depth_ft": _number(p, "depth_ft"),
                "land_area_sqft": _number(p, "land_area_sqft"),
                "built_up_sqft": _number(p, "built_up_sqft"),
                "unit_position": _text(p, "unit_position"),
                "facing_direction": _text(p, "facing_direction"),
                "availability": _text(p, "availability"),
                "availability_verified_at": _date(p.get("availability_verified_at")),
            }
            # fyp flags have legacy 0 defaults. Only 1 is explicit support;
            # a default 0 is not conclusive evidence of absence.
            for key in ("has_parking", "is_corner_lot", "is_freehold"):
                published[key] = True if p.get(key) in (1, True) else None
            for key, val in published.items():
                if val is not None:
                    fields[key] = val
            provenance = "approved_published_listing_with_research_fallback"
            verified_listing = True

        return {
            **fields,
            "provenance": provenance,
            "verified_listing": verified_listing,
            "research_availability_status": _text(source, "property_availability_status")
            or "UNKNOWN_NOT_VERIFIED",
            "data_notice": (
                "Research data is not proof of current availability or permission "
                "to operate a food business. Confirm with the owner and local council."
            ),
        }
