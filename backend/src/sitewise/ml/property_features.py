"""Read-only extraction of exact saved PU features for a SiteWise property.

This module targets the EXISTING ERD and creates no tables. A catalogue ID
(e.g. MD-00510) is text. A rental listing ID is bigint; they are joined only
through fyp.property_subject_links where match_verified is TRUE.

Use separate data-source provenance for each candidate feature. The 47-feature
baseline depends on measurements absent from typed columns; such values must
exist under their exact names in other_features or be supplied through a
reviewed, explicit mapping. No missing value is silently set to zero.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Mapping

from sqlalchemy import text


class FeatureResolutionError(Exception):
    pass


@dataclass(frozen=True)
class PropertyFeatureBundle:
    property_id: str
    source: str
    subject_id: str | None
    values: dict[str, float | None]
    value_sources: dict[str, str]
    missing_features: list[str]
    analysis_status: str | None
    flags: list[str]

    @property
    def available_features(self) -> int:
        return sum(v is not None for v in self.values.values())

    def as_coverage(self) -> dict:
        return {
            "property_id": self.property_id,
            "source": self.source,
            "subject_id": self.subject_id,
            "feature_count": len(self.values),
            "available_features": self.available_features,
            "missing_features": self.missing_features,
            "value_sources": self.value_sources,
            "analysis_status": self.analysis_status,
            "flags": self.flags,
        }


# Some WorldPop population names are direct, documented measurement equivalents.
# Only these are mapped automatically; don't derive a 2 km population from a
# 1–3 km ring because its area does not correspond to the required catchment.
WORLDPOP_EQUIVALENTS: dict[str, str] = {
    "pop_500m": "pop_ring_0_500m",
    "pop_1000m": "pop_total_1km",
    "pop_3000m": "pop_total_3km",
}

# Require explicit opt-in because these may be measured from DIFFERENT F&B
# inventories or methods than the model's training feature definitions.
UNVERIFIED_ALIASES: dict[str, tuple[str, str]] = {
    "fnb_competitors_500m": ("subject", "competitor_count_500m"),
    "fnb_competitors_1000m": ("subject", "competitor_count_1000m"),
}


def _numeric(v: Any) -> float | None:
    from math import isfinite
    if v is None or isinstance(v, bool) or isinstance(v, (dict, list)):
        return None
    try:
        num = float(v)
    except (ValueError, TypeError):
        return None
    return num if isfinite(num) else None


def _rows(session: Any, sql: str, params: dict) -> list[dict]:
    return [dict(row) for row in session.execute(text(sql), params).mappings().all()]


def _one(rows: list[dict], context: str) -> dict | None:
    if len(rows) > 1:
        raise FeatureResolutionError(f"Ambiguous {context}: {len(rows)} records matched")
    return rows[0] if rows else None


def _doc(session: Any, table: str, col: str, val: Any) -> dict:
    # table and column are internal literals only, never request-provided SQL.
    sql = f"SELECT to_jsonb(t) AS doc FROM {table} AS t WHERE t.{col} = :id LIMIT 2"
    row = _one(_rows(session, sql, {"id": val}), table)
    return dict(row["doc"] or {}) if row else {}


class PropertyFeatureRepository:
    def __init__(self, analytics_session: Any):
        self.session = analytics_session

    def _resolve(self, property_id: str, source: str) -> tuple[str, str | None]:
        if source not in {"catalog", "rental"}:
            raise FeatureResolutionError("source must be 'catalog' or 'rental'")
        if source == "rental":
            try:
                rental_id = int(property_id)
            except ValueError as exc:
                raise FeatureResolutionError("Rental property ID must be a bigint") from exc
            match = _one(_rows(self.session, """
                SELECT l.subject_id, l.sitewise_property_id
                FROM fyp.property_subject_links l
                WHERE l.property_id = :id AND l.match_verified IS TRUE LIMIT 2
            """, {"id": rental_id}), "verified rental-to-subject mapping")
            if match is None:
                raise FeatureResolutionError("No verified analytical mapping for rental property")
            return str(match["subject_id"]), match.get("sitewise_property_id")

        # Do not attempt to cast a catalogue ID into a rental BIGINT.
        present = _rows(self.session, """
            SELECT id FROM sitewise_app.properties WHERE id = :id LIMIT 1
        """, {"id": property_id})
        if not present:
            raise FeatureResolutionError("The catalogue property does not exist")
        mapped = _one(_rows(self.session, """
            SELECT l.subject_id FROM fyp.property_subject_links l
            WHERE l.sitewise_property_id = :id AND l.match_verified IS TRUE LIMIT 2
        """, {"id": property_id}), "verified catalogue-to-subject mapping")
        if mapped is not None:
            return str(mapped["subject_id"]), property_id
        # Some imported U properties may lack a verified rental link. In that
        # case only the exact canonical_property_id + U label is acceptable.
        match = _one(_rows(self.session, """
            SELECT f.subject_id FROM sitewise_analytics.subject_features f
            WHERE f.canonical_property_id = :id AND btrim(f.sample_class) = 'U'
            LIMIT 2
        """, {"id": property_id}), "canonical U feature mapping")
        if match is None:
            raise FeatureResolutionError("No U analytical subject for this catalogue property")
        return str(match["subject_id"]), property_id

    def get(
        self,
        property_id: str | int,
        required_features: list[str],
        *,
        source: str = "catalog",
        use_unverified_competitor_aliases: bool = False,
    ) -> PropertyFeatureBundle:
        identifier = str(property_id).strip()
        if not identifier:
            raise FeatureResolutionError("Property ID is required")
        subject_id, catalogue_id = self._resolve(identifier, source)
        sf = _doc(self.session, "sitewise_analytics.subject_features", "subject_id", subject_id)
        if not sf:
            raise FeatureResolutionError("Subject mapping exists but its analysis row is missing")
        if str(sf.get("sample_class") or "").strip() != "U":
            raise FeatureResolutionError("Only unlabeled commercial property subjects may be scored")
        demand = _doc(self.session, "demand_gen.features", "subject_id", subject_id)
        worldpop: dict = {}
        flags: list[str] = []
        if catalogue_id:
            worldpop = _doc(
                self.session, "fyp_features.property_population_spatial",
                "source_record_id", catalogue_id,
            )
            if worldpop:
                type_value = str(worldpop.get("source_record_type") or "").lower()
                if type_value not in {"u", "property", "unlabelled", "unlabeled", "commercial_property"}:
                    flags.append(
                        f"Population source_record_type '{type_value}' requires manual verification"
                    )
                    worldpop = {}
                if worldpop.get("population_quality_flag") not in {None, "", "OK", "COMPLETE"}:
                    flags.append("Population quality flag: " + str(worldpop["population_quality_flag"]))
        extra = sf.get("other_features") or {}
        if not isinstance(extra, dict):
            extra = {}
        if sf.get("analysis_status") != "COMPLETED":
            flags.append("Analysis status: " + str(sf.get("analysis_status")))
        # LandScan provenance/permission is not asserted by the ERD. Warn if
        # flagged and avoid treating licensed data as freely reusable.
        for k, v in extra.items():
            if "landscan" in k.lower() and isinstance(v, dict):
                for q in ("license_status", "licence_status", "ml_use_status"):
                    status = v.get(q)
                    if status and status != "ALLOWED":
                        flags.append(f"{k}.{q}={status}: check licence before ML use")

        candidates: tuple[tuple[str, Mapping], ...] = (
            ("sitewise_analytics.subject_features", sf),
            ("sitewise_analytics.subject_features.other_features", extra),
            ("demand_gen.features", demand),
            ("fyp_features.property_population_spatial", worldpop),
        )
        values: dict[str, float | None] = {}
        sources: dict[str, str] = {}
        for name in required_features:
            value = None
            for label, data in candidates:
                if name in data:
                    v = _numeric(data[name])
                    if v is not None:
                        value = v
                        sources[name] = label + "." + name
                        break
            if value is None and name in WORLDPOP_EQUIVALENTS:
                alias = WORLDPOP_EQUIVALENTS[name]
                value = _numeric(worldpop.get(alias))
                if value is not None:
                    sources[name] = "fyp_features.property_population_spatial." + alias
            if value is None and use_unverified_competitor_aliases and name in UNVERIFIED_ALIASES:
                _, alias = UNVERIFIED_ALIASES[name]
                value = _numeric(sf.get(alias))
                if value is not None:
                    sources[name] = "UNVERIFIED_ALIAS:sitewise_analytics.subject_features." + alias
                    flags.append(f"Check competitor source/method equivalence for {name}")
            values[name] = value
        missing = [name for name, value in values.items() if value is None]
        return PropertyFeatureBundle(
            property_id=identifier,
            source=source,
            subject_id=subject_id,
            values=values,
            value_sources=sources,
            missing_features=missing,
            analysis_status=sf.get("analysis_status"),
            flags=sorted(set(flags)),
        )

    def background(
        self, required_features: list[str], *, limit: int = 50
    ) -> list[dict[str, float]]:
        """Real reference rows for SHAP, with the exact training features.

        Only analysed unlabeled subjects whose every required feature resolves
        numerically are returned. Rows with a gap are skipped rather than
        zero-filled, because a synthetic background changes the baseline and
        would make the explanation describe a property that does not exist.
        """
        if not required_features:
            return []
        cap = max(1, min(int(limit), 100))
        rows = _rows(
            self.session,
            """
            SELECT to_jsonb(f) AS doc
            FROM sitewise_analytics.subject_features f
            WHERE btrim(f.sample_class) = 'U'
              AND f.analysis_status = 'COMPLETED'
            ORDER BY f.imported_at DESC NULLS LAST
            LIMIT :scan
            """,
            # Over-scan: many rows are incomplete, so read more than we keep.
            {"scan": cap * 6},
        )
        out: list[dict[str, float]] = []
        for row in rows:
            doc = dict(row["doc"] or {})
            extra = doc.get("other_features") or {}
            if not isinstance(extra, dict):
                extra = {}
            merged: dict[str, Any] = {**doc, **extra}
            values: dict[str, float] = {}
            for name in required_features:
                number = _numeric(merged.get(name))
                if number is None:
                    values = {}
                    break
                values[name] = number
            if values:
                out.append(values)
            if len(out) >= cap:
                break
        return out
