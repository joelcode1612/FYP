"""Affected-property feature calculation.

Reuses :class:`FypPropertyRepository.enrichment_snapshot` (the canonical
500 m / 1 km competitor contract) and ``upsert_geospatial_features``. The
service adds three things the live repository does not own:

1. **Affected-property detection** — only properties inside the configured
   influence radius of a CHANGED outlet (both old and new coordinates) are
   recalculated. No database-wide recomputation.
2. **Reliable calculation state** — ``pending`` before, ``current`` after a
   confirmed computation, ``failed``/``unavailable`` on error. A failure
   NEVER writes zero counts and NEVER deletes previous valid features.
3. **Retryability** — every attempt is idempotent (upsert) and stamped with a
   calculation version, so a retry can be distinguished from a new change.
"""

from __future__ import annotations

import logging
from collections.abc import Iterable, Sequence
from datetime import UTC, datetime

from sqlalchemy import text
from sqlmodel import Session

from sitewise.ingestion.config import RefreshConfig
from sitewise.ingestion.state import RefreshState
from sitewise.repositories.fyp_property_repository import FypPropertyRepository

logger = logging.getLogger("sitewise.feature_refresh")


class FeatureRefreshService:
    def __init__(self, session: Session, config: RefreshConfig | None = None):
        self.session = session
        self.config = config or RefreshConfig()
        self.repo = FypPropertyRepository(session)
        self.state = RefreshState(session)

    # --- affected detection -------------------------------------------------

    def affected_property_ids(
        self, points: Sequence[tuple[float, float]], radius_m: int | None = None
    ) -> list[int]:
        """Properties whose 1 km (max research radius) catchment contains a
        changed point. Uses a padded ``&&`` GIST pre-filter followed by
        ``ST_DWithin(geography)`` — never degree-difference metre math.
        """
        radius = int(radius_m or self.config.influence_radius_m)
        unique = list({(round(lat, 7), round(lon, 7)) for lat, lon in points})
        if not unique:
            return []
        found: set[int] = set()
        # Bounded batches keep the unnest cross-join small enough for the
        # planner to use idx_rp_geom.
        for start in range(0, len(unique), 400):
            chunk = unique[start : start + 400]
            rows = self.session.execute(
                text(
                    """
                    SELECT DISTINCT p.id
                    FROM fyp.rental_properties p
                    JOIN unnest(CAST(:lats AS double precision[]),
                                CAST(:lons AS double precision[])) AS c(lat, lon)
                      ON true
                    WHERE p.geom IS NOT NULL
                      AND p.geom && ST_Expand(
                          ST_SetSRID(ST_MakePoint(c.lon, c.lat), 4326), :pad)
                      AND ST_DWithin(
                          p.geom::geography,
                          ST_SetSRID(ST_MakePoint(c.lon, c.lat), 4326)::geography,
                          :radius)
                    """
                ),
                {
                    "lats": [p[0] for p in chunk],
                    "lons": [p[1] for p in chunk],
                    "pad": radius * 1.02 / 111_320.0,
                    "radius": float(radius),
                },
            ).scalars().all()
            found.update(int(r) for r in rows)
        return sorted(found)

    # --- calculation ---------------------------------------------------------

    def recalculate(
        self,
        property_ids: Iterable[int],
        *,
        reason: str = "source_change",
        source_release: str | None = None,
    ) -> dict:
        """Recalculate a bounded set of properties. Returns measured metrics."""
        ids = list(dict.fromkeys(int(i) for i in property_ids))
        result = {
            "properties_affected": len(ids),
            "properties_recalculated": 0,
            "successful_computations": 0,
            "failed_computations": 0,
            "errors": [],
        }
        for property_id in ids:
            self.state.set_freshness(
                property_id,
                status="pending",
                version=self.config.calculation_version,
                source_release=source_release,
            )
            row = self.session.execute(
                text(
                    "SELECT id, latitude, longitude FROM fyp.rental_properties "
                    "WHERE id = :pid"
                ),
                {"pid": property_id},
            ).mappings().first()
            if row is None or row["latitude"] is None or row["longitude"] is None:
                self.state.set_freshness(
                    property_id,
                    status="unavailable",
                    version=self.config.calculation_version,
                    error="property_or_coordinates_missing",
                )
                result["failed_computations"] += 1
                result["errors"].append(f"{property_id}: coordinates unavailable")
                continue
            try:
                snapshot = self.repo.enrichment_snapshot(
                    float(row["latitude"]), float(row["longitude"])
                )
                if snapshot.get("competitor_status") != "ok":
                    raise RuntimeError("competitor computation reported unavailable")
                # Population is per-property research data (WorldPop/LandScan
                # rows), not a per-coordinate raster value. A competitor
                # refresh must never null it: keep the existing measured
                # values when the coordinate snapshot reports unavailable.
                previous = self.session.execute(
                    text(
                        "SELECT population_500m, population_1km "
                        "FROM fyp.property_geospatial_features "
                        "WHERE property_id = :pid ORDER BY id DESC LIMIT 1"
                    ),
                    {"pid": property_id},
                ).first()
                if previous is not None:
                    if snapshot.get("population_500m") is None and previous[0] is not None:
                        snapshot["population_500m"] = previous[0]
                        snapshot["population_status"] = "preserved"
                    if snapshot.get("population_1km") is None and previous[1] is not None:
                        snapshot["population_1km"] = previous[1]
                        snapshot["population_status"] = "preserved"
                # Only reached on a real calculation: a failed attempt never
                # writes values, so previous valid features remain readable.
                self.repo.upsert_geospatial_features(property_id, snapshot)
                self.state.set_freshness(
                    property_id,
                    status="current",
                    version=self.config.calculation_version,
                    source_release=source_release,
                    success=True,
                )
                result["properties_recalculated"] += 1
                result["successful_computations"] += 1
            except Exception as exc:
                logger.exception("feature calculation failed for property %s", property_id)
                message = f"{property_id}: {type(exc).__name__}: {str(exc)[:200]}"
                self.state.set_freshness(
                    property_id,
                    status="failed",
                    version=self.config.calculation_version,
                    error=message,
                )
                result["failed_computations"] += 1
                result["errors"].append(message)
        logger.info(
            "feature refresh (%s): %s recalculated, %s failed",
            reason, result["properties_recalculated"], result["failed_computations"],
        )
        return result

    def recalculate_new_property(self, property_id: int, source_release: str | None = None) -> dict:
        """Phase 8: initial features for a newly created Entrepreneur listing.

        Local PostGIS only — no external download is triggered, so property
        creation is never blocked by a slow provider.
        """
        return self.recalculate(
            [property_id], reason="new_property", source_release=source_release
        )

    def refresh_for_changed_outlets(
        self, points: Sequence[tuple[float, float]], source_release: str | None = None
    ) -> dict:
        affected = self.affected_property_ids(points)
        result = self.recalculate(
            affected, reason="outlet_change", source_release=source_release
        )
        result["properties_affected"] = len(affected)
        return result

    def refresh_population_only(self, property_ids: Iterable[int]) -> dict:
        """A new population dataset updates freshness/provenance WITHOUT
        unnecessarily recomputing unrelated competitor features."""
        ids = list(dict.fromkeys(int(i) for i in property_ids))
        for property_id in ids:
            self.session.execute(
                text(
                    "UPDATE fyp.property_feature_freshness SET "
                    "source_release = COALESCE(:release, source_release), "
                    "refresh_status = CASE WHEN refresh_status = 'failed' "
                    "THEN 'failed' ELSE 'stale' END, updated_at = now() "
                    "WHERE property_id = :pid"
                ),
                {"pid": property_id, "release": "population-dataset"},
            )
        self.session.commit()
        return {"population_properties_flagged": len(ids), "competitor_recomputations": 0}

    def stale_property_ids(self, older_than_hours: int = 24 * 7) -> list[int]:
        """Catch-up list for a scheduled run (failed/pending/stale first)."""
        rows = self.session.execute(
            text(
                "SELECT property_id FROM fyp.property_feature_freshness "
                "WHERE refresh_status IN ('pending','failed') "
                "OR (refresh_status = 'stale' AND updated_at < now() "
                "    - (:hours || ' hours')::interval) "
                "ORDER BY updated_at ASC LIMIT 500"
            ),
            {"hours": str(int(older_than_hours))},
        ).scalars().all()
        return [int(r) for r in rows]

    def mark_stale_for_source_change(self, points: Sequence[tuple[float, float]]) -> int:
        """Label affected but not-yet-recalculated properties as stale."""
        affected = self.affected_property_ids(points)
        for property_id in affected:
            self.session.execute(
                text(
                    "INSERT INTO fyp.property_feature_freshness "
                    "(property_id, refresh_status, calculation_version, "
                    "last_refresh_attempt_at) VALUES (:pid, 'stale', :version, now()) "
                    "ON CONFLICT (property_id) DO UPDATE SET "
                    "refresh_status = CASE "
                    "WHEN fyp.property_feature_freshness.refresh_status IN "
                    "('failed','unavailable') "
                    "THEN fyp.property_feature_freshness.refresh_status "
                    "ELSE 'stale' END, updated_at = now()"
                ),
                {"pid": property_id, "version": self.config.calculation_version},
            )
        self.session.commit()
        return len(affected)

    @staticmethod
    def attempted_at() -> str:
        return datetime.now(UTC).isoformat()
