"""Two-phase geospatial enrichment for an owner-submitted property.

The workflow the product needs
-----------------------------
Adding a property must not block on slow data. Enrichment is therefore split
into two phases that are started independently and can fail independently:

* **Phase 1 — ``postgis``**: F&B competitors, demand generators, roads and
  transportation, parking. Every one of these is a PostGIS aggregate over a
  table that already exists in this deployment. Fast enough to run while the
  owner is still on the page.
* **Phase 2 — ``population``**: raster work, deliberately separate. It is the
  only category that depends on raster machinery, and the only one that is
  legitimately *unavailable* for some coordinates.

Each category has its own lifecycle (``pending``, ``running``, ``current``,
``unavailable``, ``failed``, ``stale``). A failure in one never writes a zero
for another, and never deletes a previously valid measurement.

What the database can actually support (measured, not assumed)
-------------------------------------------------------------
Validated against the live database before any query was written:

===========================  ============================================  =======
Category                     Source                                        Rows
===========================  ============================================  =======
``fnb_competitors``          ``fnb_a.fnb_outlet``                          19,419
``demand_generators``        ``demand_gen.subjects``                        1,849
``roads_transport``          ``fnb_a.major_roads`` + ``transit_pois``     217,204 / 18,470
``parking``                  ``public.psense_parking``                      17,520
``population``               ``public.landscan_2024`` raster + the         6,539 tiles
                             pre-computed WorldPop per-property rows          955
===========================  ============================================  =======

``demand_gen.pois_master`` (59,928 rows) was checked and rejected as a
competitor source: it carries no F&B category (its categories are RETAIL,
OFFICE, SCHOOL, SUPERMARKET, OFFICE_BUILDING, UNIVERSITY_COLLEGE, HOSPITAL,
MALL). The canonical F&B contract in this product is ``fnb_a.fnb_outlet`` and
this service reuses it rather than inventing a second definition.

Population honesty
------------------
No WorldPop/LandScan GeoTIFF exists on this machine and ``rasterio`` is not
installed, so the brief's literal "read the local raster with Rasterio" path
cannot run here. Rather than fabricate a number, the service resolves
population through an ordered chain and reports which link answered:

1. the pre-computed WorldPop 100 m per-property row (existing catalogue);
2. the live LandScan 2024 PostGIS raster, sampled with ``ST_SummaryStats``;
3. a Rasterio GeoTIFF *if* ``SITEWISE_POPULATION_RASTER`` is configured and
   ``rasterio`` is importable (the brief's method, wired and ready);
4. otherwise ``unavailable`` with the precise reason.

A population value is therefore never printed as ``0`` because the data was
missing — it is either a measured number with a named source, or it is
``unavailable``.
"""

from __future__ import annotations

import hashlib
import logging
import math
import os
from collections.abc import Iterable, Sequence
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

from sitewise.services.enrichment_schema import (
    CATEGORIES,
    CATEGORY_PHASE,
    PHASE_POPULATION,
    PHASE_POSTGIS,
    ensure_schema,
)

logger = logging.getLogger("sitewise.property_enrichment")

#: Bumped when a measurement definition changes; part of the coordinate hash so
#: a definition change invalidates previously stored values.
CALCULATION_VERSION = "property-enrichment-v1"

#: A ``running`` row older than this is treated as an abandoned job and may be
#: reclaimed. Without it a crashed process would block its property forever.
RUNNING_STALE_MINUTES = 10

#: The canonical F&B competitor predicate, identical to
#: ``FypPropertyRepository._COMPETITOR_PREDICATE``. Reused deliberately: two
#: definitions of "competitor" would produce two different numbers for the same
#: property.
FNB_PREDICATE = "o.geom IS NOT NULL AND o.in_target_region AND o.in_main_scope"

_M_PER_DEGREE = 111_320.0

SOURCE_LICENCES = {
    "fnb_a.fnb_outlet": "OpenStreetMap ODbL 1.0 (attribution required)",
    "demand_gen.subjects": "SiteWise curated demand-generator register",
    "fnb_a.major_roads": "OpenStreetMap ODbL 1.0 (attribution required)",
    "fnb_a.transit_pois": "OpenStreetMap ODbL 1.0 (attribution required)",
    "public.psense_parking": "OpenStreetMap ODbL 1.0 (attribution required)",
    "public.landscan_2024": "LandScan 2024 (Oak Ridge National Laboratory)",
    "fyp_features.property_population_spatial": (
        "WorldPop R2025A v1 MYS 2025 constrained 100m (CC-BY-4.0)"
    ),
}


def coordinate_hash(lat: float, lon: float) -> str:
    """Stable identity of the calculation input.

    Six decimal places is ~0.11 m — finer than any source's own positional
    accuracy, so a cosmetic re-save never invalidates a measurement, while a
    genuine relocation always does.
    """
    material = f"{float(lat):.6f},{float(lon):.6f},{CALCULATION_VERSION}"
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def _radius_args(lat: float, lon: float, radius_m: int) -> dict[str, Any]:
    """Bind values for a geodesic radius with a padded degree pre-filter."""
    pad = radius_m * 1.02 / _M_PER_DEGREE
    cos_lat = max(0.02, abs(math.cos(math.radians(lat))))
    return {
        "lat": float(lat),
        "lon": float(lon),
        "pad": pad,
        "lonpad": radius_m * 1.02 / (_M_PER_DEGREE * cos_lat),
        "radius_m": float(radius_m),
    }


def _now() -> datetime:
    return datetime.now(UTC)


class _Outcome:
    """What one category produced: a state, its values and where they came from."""

    __slots__ = ("error", "measurement", "provenance", "status")

    def __init__(
        self,
        status: str,
        measurement: dict[str, Any] | None = None,
        provenance: dict[str, Any] | None = None,
        error: str | None = None,
    ) -> None:
        self.status = status
        # ``None`` (not ``{}``) for a category that produced no measurement, so
        # the API and the UI can distinguish "no value" from "empty object".
        self.measurement = measurement or None
        self.provenance = provenance or {}
        self.error = error

    @classmethod
    def current(
        cls, measurement: dict[str, Any], provenance: dict[str, Any]
    ) -> _Outcome:
        return cls("current", measurement, provenance)

    @classmethod
    def unavailable(cls, reason: str, provenance: dict[str, Any] | None = None) -> _Outcome:
        return cls(
            "unavailable",
            provenance={**(provenance or {}), "reason": reason},
        )

    @classmethod
    def failed(cls, error: str) -> _Outcome:
        return cls("failed", error=error[:2000])


#: Set once the additive DDL has run in this process.
_SCHEMA_READY = False


class PropertyEnrichmentService:
    """Owns the enrichment lifecycle for owner-submitted listings."""

    def __init__(self, session: Session) -> None:
        self.session = session

    # ------------------------------------------------------------------
    # Lifecycle plumbing
    # ------------------------------------------------------------------

    def ensure_schema(self) -> None:
        """Create the additive tables once per process.

        ``ensure_schema`` is idempotent, but it is 11 DDL statements and the
        admin review payload calls it on every read. The flag keeps that to a
        single round trip for the lifetime of the worker.
        """
        global _SCHEMA_READY
        if _SCHEMA_READY:
            return
        ensure_schema(self.session)
        _SCHEMA_READY = True

    def _property_row(self, property_id: int) -> dict[str, Any] | None:
        row = self.session.execute(
            text(
                """
                SELECT id, latitude, longitude, listing_id, owner_user_id
                FROM fyp.rental_properties
                WHERE id = :pid
                """
            ),
            {"pid": property_id},
        ).mappings().first()
        return dict(row) if row else None

    def states(self, property_id: int) -> dict[str, dict[str, Any]]:
        """Every category's stored state, with the missing ones as ``pending``."""
        rows = self.session.execute(
            text(
                """
                SELECT category, phase, status, measurement, provenance,
                       coordinate_hash, calculation_version, attempt_count,
                       started_at, completed_at, last_error, updated_at
                FROM fyp.property_enrichment_category
                WHERE property_id = :pid
                """
            ),
            {"pid": property_id},
        ).mappings().all()
        stored = {r["category"]: dict(r) for r in rows}
        out: dict[str, dict[str, Any]] = {}
        for category in CATEGORIES:
            row = stored.get(category)
            if row is None:
                out[category] = {
                    "category": category,
                    "phase": CATEGORY_PHASE[category],
                    "status": "pending",
                    "measurement": None,
                    "provenance": None,
                    "attempt_count": 0,
                    "started_at": None,
                    "completed_at": None,
                    "last_error": None,
                    "updated_at": None,
                }
            else:
                out[category] = _serialise(row)
        return out

    def summary(self, property_id: int) -> dict[str, Any]:
        """Progress payload for the Add Property UI and the admin view."""
        states = self.states(property_id)
        phase1 = [c for c in CATEGORIES if CATEGORY_PHASE[c] == PHASE_POSTGIS]
        phase2 = [c for c in CATEGORIES if CATEGORY_PHASE[c] == PHASE_POPULATION]
        population = states["population"]

        def _phase_block(names: Sequence[str]) -> dict[str, Any]:
            settled = [n for n in names if states[n]["status"] in (
                "current", "unavailable", "failed")]
            running = [n for n in names if states[n]["status"] == "running"]
            return {
                "categories": {n: states[n] for n in names},
                "total": len(names),
                "settled": len(settled),
                "running": len(running),
                "complete": len(settled) == len(names),
            }

        return {
            "property_id": property_id,
            "calculation_version": CALCULATION_VERSION,
            "phase1": _phase_block(phase1),
            "phase2": _phase_block(phase2),
            "categories": states,
            "population_unavailable": population["status"] == "unavailable",
            "ready_to_submit": all(
                states[c]["status"] in ("current", "unavailable") for c in CATEGORIES
            ),
        }

    def _claim(self, property_id: int, category: str, hash_value: str) -> bool:
        """Take ownership of a category, or report that someone else has it.

        The conditional UPDATE *is* the mutex: a row already ``running`` and
        fresh yields ``rowcount = 0``, so a duplicate request cannot start a
        second computation. A ``running`` row older than
        :data:`RUNNING_STALE_MINUTES` is reclaimable, so a crashed worker never
        wedges a property.
        """
        now = _now()
        stale_before = now - timedelta(minutes=RUNNING_STALE_MINUTES)
        self.session.execute(
            text(
                """
                INSERT INTO fyp.property_enrichment_category
                    (property_id, category, phase, status, coordinate_hash,
                     calculation_version, attempt_count, started_at, updated_at)
                VALUES (:pid, :category, :phase, 'pending', :hash, :version, 0, NULL, :now)
                ON CONFLICT (property_id, category) DO NOTHING
                """
            ),
            {
                "pid": property_id,
                "category": category,
                "phase": CATEGORY_PHASE[category],
                "hash": hash_value,
                "version": CALCULATION_VERSION,
                "now": now,
            },
        )
        claimed = self.session.execute(
            text(
                """
                UPDATE fyp.property_enrichment_category
                SET status = 'running',
                    phase = :phase,
                    coordinate_hash = :hash,
                    calculation_version = :version,
                    attempt_count = attempt_count + 1,
                    started_at = :now,
                    last_error = NULL,
                    updated_at = :now
                WHERE property_id = :pid
                  AND category = :category
                  AND (
                        status <> 'running'
                     OR started_at IS NULL
                     OR started_at < :stale_before
                  )
                RETURNING property_id
                """
            ),
            {
                "pid": property_id,
                "category": category,
                "phase": CATEGORY_PHASE[category],
                "hash": hash_value,
                "version": CALCULATION_VERSION,
                "now": now,
                "stale_before": stale_before,
            },
        ).first()
        self.session.commit()
        return claimed is not None

    def _settle(
        self,
        property_id: int,
        category: str,
        hash_value: str,
        outcome: _Outcome,
    ) -> dict[str, Any]:
        """Persist a settled state. Values are written only for ``current``."""
        now = _now()
        self.session.execute(
            text(
                """
                UPDATE fyp.property_enrichment_category
                SET status = :status,
                    measurement = CAST(:measurement AS jsonb),
                    provenance = CAST(:provenance AS jsonb),
                    coordinate_hash = :hash,
                    calculation_version = :version,
                    completed_at = :now,
                    last_error = :error,
                    updated_at = :now
                WHERE property_id = :pid AND category = :category
                """
            ),
            {
                "pid": property_id,
                "category": category,
                "status": outcome.status,
                "measurement": _json(outcome.measurement),
                "provenance": _json(outcome.provenance),
                "hash": hash_value,
                "version": CALCULATION_VERSION,
                "now": now,
                "error": outcome.error,
            },
        )
        self.session.commit()
        row = self.session.execute(
            text(
                """
                SELECT category, phase, status, measurement, provenance,
                       coordinate_hash, calculation_version, attempt_count,
                       started_at, completed_at, last_error, updated_at
                FROM fyp.property_enrichment_category
                WHERE property_id = :pid AND category = :category
                """
            ),
            {"pid": property_id, "category": category},
        ).mappings().first()
        return _serialise(dict(row)) if row else {}

    # ------------------------------------------------------------------
    # Public entry points
    # ------------------------------------------------------------------

    def run(
        self,
        property_id: int,
        *,
        phase: str = "all",
        categories: Iterable[str] | None = None,
        force: bool = False,
    ) -> dict[str, Any]:
        """Run one phase (or both) and return the settled per-category states.

        ``phase`` is ``postgis``, ``population`` or ``all``. Phase 2 is never
        started as a side effect of Phase 1 — the caller has to ask for it,
        which is what makes the two phases genuinely independent.
        """
        self.ensure_schema()
        row = self._property_row(property_id)
        if row is None:
            raise LookupError("Property not found.")

        lat, lon = row.get("latitude"), row.get("longitude")
        if not _valid_coordinates(lat, lon):
            # A property without usable coordinates cannot be enriched at all.
            # Record that honestly instead of inventing a location.
            hash_value = "no-coordinates"
            for category in CATEGORIES:
                self._claim(property_id, category, hash_value)
                self._settle(
                    property_id,
                    category,
                    hash_value,
                    _Outcome.unavailable("property_has_no_coordinates"),
                )
            return self.summary(property_id)

        hash_value = coordinate_hash(float(lat), float(lon))
        wanted = self._wanted_categories(phase, categories)

        for category in wanted:
            self._run_one(property_id, category, float(lat), float(lon),
                          hash_value, row, force)
        return self.summary(property_id)

    def retry(self, property_id: int, category: str) -> dict[str, Any]:
        """Re-run exactly one category, ignoring a previously settled state.

        Retry is scoped to one category on purpose: a failed population raster
        must never force the four PostGIS categories to be recalculated.
        """
        if category not in CATEGORIES:
            raise ValueError(f"Unknown enrichment category: {category}")
        self.ensure_schema()
        row = self._property_row(property_id)
        if row is None:
            raise LookupError("Property not found.")
        lat, lon = row.get("latitude"), row.get("longitude")
        if not _valid_coordinates(lat, lon):
            hash_value = "no-coordinates"
            self._claim(property_id, category, hash_value)
            self._settle(
                property_id, category, hash_value,
                _Outcome.unavailable("property_has_no_coordinates"),
            )
            return self.summary(property_id)
        hash_value = coordinate_hash(float(lat), float(lon))
        self._run_one(property_id, category, float(lat), float(lon),
                      hash_value, row, force=True)
        return self.summary(property_id)

    def mark_stale(self, property_id: int, categories: Iterable[str] | None = None) -> int:
        """Flag measurements whose input changed, without deleting values.

        ``stale`` is a prompt to recalculate, not a reason to lose data: the
        wide feature row keeps the previous numbers until a new computation
        succeeds.
        """
        wanted = list(categories or CATEGORIES)
        result = self.session.execute(
            text(
                """
                UPDATE fyp.property_enrichment_category
                SET status = 'stale', updated_at = :now
                WHERE property_id = :pid
                  AND category = ANY(:categories)
                  AND status IN ('current', 'unavailable', 'failed')
                """
            ),
            {"pid": property_id, "categories": wanted, "now": _now()},
        )
        self.session.commit()
        return int(result.rowcount or 0)

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    @staticmethod
    def _wanted_categories(phase: str, categories: Iterable[str] | None) -> list[str]:
        if categories is not None:
            chosen = [c for c in categories if c in CATEGORIES]
            return chosen or list(CATEGORIES)
        if phase == PHASE_POSTGIS:
            return [c for c in CATEGORIES if CATEGORY_PHASE[c] == PHASE_POSTGIS]
        if phase == PHASE_POPULATION:
            return [c for c in CATEGORIES if CATEGORY_PHASE[c] == PHASE_POPULATION]
        return list(CATEGORIES)

    def _run_one(
        self,
        property_id: int,
        category: str,
        lat: float,
        lon: float,
        hash_value: str,
        row: dict[str, Any],
        force: bool,
    ) -> None:
        existing = self.session.execute(
            text(
                """
                SELECT status, coordinate_hash
                FROM fyp.property_enrichment_category
                WHERE property_id = :pid AND category = :category
                """
            ),
            {"pid": property_id, "category": category},
        ).mappings().first()

        # Idempotency: a settled measurement for the same coordinates is not
        # recalculated. This is what stops every page visit from re-running
        # PostGIS aggregates over the whole catchment.
        if (
            not force
            and existing is not None
            and existing["status"] == "current"
            and existing["coordinate_hash"] == hash_value
        ):
            return

        if not self._claim(property_id, category, hash_value):
            # Another request owns this category right now; leave its state be.
            logger.info(
                "enrichment.skip_running property=%s category=%s",
                property_id, category,
            )
            return

        try:
            outcome = self._compute(category, lat, lon, row)
        except Exception as exc:  # noqa: BLE001 - one category must not kill the rest
            logger.warning(
                "enrichment.failed property=%s category=%s error=%s",
                property_id, category, exc,
            )
            self.session.rollback()
            self._settle(property_id, category, hash_value, _Outcome.failed(str(exc)))
            return

        if outcome.status == "current":
            self._write_measurements(property_id, category, outcome, hash_value)
        self._settle(property_id, category, hash_value, outcome)

    def _compute(
        self, category: str, lat: float, lon: float, row: dict[str, Any]
    ) -> _Outcome:
        handler = {
            "fnb_competitors": self._fnb_competitors,
            "demand_generators": self._demand_generators,
            "roads_transport": self._roads_transport,
            "parking": self._parking,
            "population": self._population,
        }[category]
        return handler(lat, lon, row)

    # -- Phase 1: PostGIS -------------------------------------------------

    def _fnb_competitors(self, lat: float, lon: float, row: dict[str, Any]) -> _Outcome:
        counts: dict[str, int] = {}
        for label, radius in (("500m", 500), ("1km", 1000)):
            counts[f"competitor_count_{label}"] = int(
                self.session.execute(
                    text(
                        "SELECT count(*) FROM fnb_a.fnb_outlet o "
                        f"WHERE {FNB_PREDICATE} "
                        "AND o.geom && ST_Expand("
                        "ST_SetSRID(ST_MakePoint(:lon, :lat), 4326), :pad) "
                        "AND ST_DWithin(o.geom::geography, "
                        "ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography, :radius_m)"
                    ),
                    _radius_args(lat, lon, radius),
                ).scalar_one()
            )
        return _Outcome.current(
            counts,
            {
                "source": "fnb_a.fnb_outlet",
                "definition": "in_target_region AND in_main_scope (OSM F&B contract)",
                "radii_m": [500, 1000],
                "licence": SOURCE_LICENCES["fnb_a.fnb_outlet"],
                "method": "ST_DWithin(geography)",
            },
        )

    def _demand_generators(self, lat: float, lon: float, row: dict[str, Any]) -> _Outcome:
        counts: dict[str, int] = {}
        for label, radius in (("500m", 500), ("1km", 1000)):
            counts[f"demand_generator_count_{label}"] = int(
                self.session.execute(
                    text(
                        """
                        SELECT count(*) FROM demand_gen.subjects s
                        WHERE s.geom IS NOT NULL
                          AND s.geom && ST_Expand(
                              ST_SetSRID(ST_MakePoint(:lon, :lat), 4326), :pad)
                          AND ST_DWithin(s.geom::geography,
                              ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                              :radius_m)
                        """
                    ),
                    _radius_args(lat, lon, radius),
                ).scalar_one()
            )
        return _Outcome.current(
            counts,
            {
                "source": "demand_gen.subjects",
                "definition": "curated demand-generator register (malls, offices, institutions)",
                "radii_m": [500, 1000],
                "licence": SOURCE_LICENCES["demand_gen.subjects"],
                "method": "ST_DWithin(geography)",
            },
        )

    def _roads_transport(self, lat: float, lon: float, row: dict[str, Any]) -> _Outcome:
        roads = self.session.execute(
            text(
                """
                SELECT
                  coalesce(sum(ST_Length(ST_Intersection(
                      r.geom,
                      ST_Buffer(ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                                :radius_m)::geometry)::geography)), 0) / 1000.0
                      AS road_km_1km,
                  min(ST_DistanceSphere(r.geom,
                      ST_SetSRID(ST_MakePoint(:lon, :lat), 4326))) AS nearest_road_m
                FROM fnb_a.major_roads r
                WHERE r.geom IS NOT NULL
                  AND r.geom && ST_Expand(
                      ST_SetSRID(ST_MakePoint(:lon, :lat), 4326), :pad)
                  AND ST_DWithin(r.geom::geography,
                      ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                      :radius_m)
                """
            ),
            _radius_args(lat, lon, 1000),
        ).mappings().one()

        transit: dict[str, int] = {}
        for label, radius in (("500m", 500), ("1km", 1000)):
            transit[f"transit_stops_{label}"] = int(
                self.session.execute(
                    text(
                        """
                        SELECT count(*) FROM fnb_a.transit_pois t
                        WHERE t.way IS NOT NULL
                          AND t.way && ST_Expand(
                              ST_SetSRID(ST_MakePoint(:lon, :lat), 4326), :pad)
                          AND ST_DWithin(t.way::geography,
                              ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                              :radius_m)
                        """
                    ),
                    _radius_args(lat, lon, radius),
                ).scalar_one()
            )

        nearest = roads["nearest_road_m"]
        measurement = {
            "accessibility_road_km_1km": float(roads["road_km_1km"] or 0.0),
            "nearest_major_road_m": float(nearest) if nearest is not None else None,
            **transit,
        }
        # Road length is genuinely 0 when no major road is inside 1 km — that is
        # a measured absence, not a missing value. A missing *distance* stays
        # null and is labelled by the UI.
        return _Outcome.current(
            measurement,
            {
                "source": "fnb_a.major_roads + fnb_a.transit_pois",
                "definition": "major-road length inside 1 km; transit stops (bus/rail) inside 500 m and 1 km",
                "radii_m": [500, 1000],
                "licence": SOURCE_LICENCES["fnb_a.major_roads"],
                "method": "ST_Length(ST_Intersection) + ST_DWithin(geography)",
            },
        )

    def _parking(self, lat: float, lon: float, row: dict[str, Any]) -> _Outcome:
        counts: dict[str, int] = {}
        for label, radius in (("500m", 500), ("1km", 1000)):
            counts[f"parking_facilities_{label}"] = int(
                self.session.execute(
                    text(
                        """
                        SELECT count(*) FROM public.psense_parking p
                        WHERE p.geom IS NOT NULL
                          AND p.kept IS TRUE
                          AND p.geom && ST_Expand(
                              ST_SetSRID(ST_MakePoint(:lon, :lat), 4326), :pad)
                          AND ST_DWithin(p.geom::geography,
                              ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                              :radius_m)
                        """
                    ),
                    _radius_args(lat, lon, radius),
                ).scalar_one()
            )

        nearest = self.session.execute(
            text(
                """
                SELECT min(ST_DistanceSphere(p.geom,
                    ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)))
                FROM public.psense_parking p
                WHERE p.geom IS NOT NULL
                  AND p.kept IS TRUE
                  AND p.geom && ST_Expand(
                      ST_SetSRID(ST_MakePoint(:lon, :lat), 4326), :pad)
                """
            ),
            _radius_args(lat, lon, 1000),
        ).scalar()

        return _Outcome.current(
            {
                **counts,
                "nearest_parking_m": float(nearest) if nearest is not None else None,
            },
            {
                "source": "public.psense_parking",
                "definition": "deduplicated parking facilities (kept = true) inside 500 m and 1 km",
                "radii_m": [500, 1000],
                "licence": SOURCE_LICENCES["public.psense_parking"],
                "method": "ST_DWithin(geography)",
            },
        )

    # -- Phase 2: population ----------------------------------------------

    def _population(self, lat: float, lon: float, row: dict[str, Any]) -> _Outcome:
        """Resolve population through an ordered chain of real providers."""
        stored = self._stored_population(row.get("listing_id"))
        if stored is not None:
            return _Outcome.current(
                stored["measurement"],
                {
                    **stored["provenance"],
                    "provider": "worldpop_precomputed",
                },
            )

        raster = self._landscan_population(lat, lon)
        if raster is not None:
            return _Outcome.current(
                raster["measurement"],
                {**raster["provenance"], "provider": "landscan_postgis_raster"},
            )

        geotiff = self._geotiff_population(lat, lon)
        if geotiff is not None:
            return _Outcome.current(
                geotiff["measurement"],
                {**geotiff["provenance"], "provider": "rasterio_geotiff"},
            )

        return _Outcome.unavailable(
            "no_population_raster_coverage",
            {
                "provider": "none",
                "attempted": [
                    "worldpop_precomputed",
                    "landscan_postgis_raster",
                    "rasterio_geotiff",
                ],
                "explanation": (
                    "No WorldPop row exists for this property and no population "
                    "raster covers these coordinates. Population is reported as "
                    "unavailable rather than estimated."
                ),
            },
        )

    def _stored_population(self, listing_id: Any) -> dict[str, Any] | None:
        """The pre-computed WorldPop row for an existing catalogue property."""
        if not listing_id:
            return None
        row = self.session.execute(
            text(
                """
                SELECT pop_ring_0_500m, pop_total_1km, population_quality_flag,
                       population_source, population_source_year,
                       population_raster_coverage_pct
                FROM fyp_features.property_population_spatial
                WHERE source_record_id = :record
                ORDER BY CASE source_record_type
                           WHEN 'SITEWISE_U_PROPERTY' THEN 0
                           WHEN 'PROPERTY_UNLABELED' THEN 1
                           ELSE 2
                         END
                LIMIT 1
                """
            ),
            {"record": str(listing_id)},
        ).mappings().first()
        if row is None or row["pop_total_1km"] is None:
            return None
        return {
            "measurement": {
                "population_500m": _num(row["pop_ring_0_500m"]),
                "population_1km": _num(row["pop_total_1km"]),
            },
            "provenance": {
                "source": "fyp_features.property_population_spatial",
                "source_dataset": row["population_source"],
                "source_year": row["population_source_year"],
                "quality_flag": row["population_quality_flag"],
                "raster_coverage_pct": _num(row["population_raster_coverage_pct"]),
                "radii_m": [500, 1000],
                "licence": SOURCE_LICENCES["fyp_features.property_population_spatial"],
                "method": "pre-computed WorldPop 100 m ring totals",
            },
        }

    def _landscan_population(self, lat: float, lon: float) -> dict[str, Any] | None:
        """Sample the live LandScan 2024 PostGIS raster.

        ``ST_SummaryStats`` over ``ST_Clip`` returns ``NULL`` when the buffer
        does not intersect any tile — that is the honest "no coverage" signal,
        and it is why this returns ``None`` instead of 0.
        """
        try:
            row = self.session.execute(
                text(
                    """
                    WITH buf AS (
                      SELECT ST_Buffer(
                        ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                        :radius_m)::geometry AS g
                    )
                    SELECT
                      sum(s.sum) AS pop,
                      sum(s.count) AS cells,
                      count(*) AS tiles
                    FROM public.landscan_2024 l
                    CROSS JOIN buf
                    CROSS JOIN LATERAL (
                      SELECT * FROM ST_SummaryStats(ST_Clip(l.rast, buf.g), 1, true)
                    ) s
                    WHERE ST_Intersects(l.rast, buf.g)
                    """
                ),
                {"lat": lat, "lon": lon, "radius_m": 1000},
            ).mappings().first()
        except Exception as exc:  # noqa: BLE001 - raster extension may be absent
            logger.info("enrichment.landscan_unavailable error=%s", exc)
            self.session.rollback()
            return None

        if row is None or row["pop"] is None:
            return None

        pop_1km = float(row["pop"])
        pop_500 = self._landscan_sum(lat, lon, 500)
        measurement = {
            "population_500m": pop_500,
            "population_1km": pop_1km,
        }
        # A radius whose pixels are all nodata is unmeasurable, not zero. The
        # UI needs to know WHICH radius is missing so it can label that figure
        # instead of printing 0.
        radii_unavailable = [] if pop_500 is not None else ["500m"]
        return {
            "measurement": measurement,
            "provenance": {
                "source": "public.landscan_2024",
                "source_year": 2024,
                "radii_m": [500, 1000],
                "radii_unavailable": radii_unavailable,
                "raster_cells_1km": int(row["cells"] or 0),
                "raster_tiles": int(row["tiles"] or 0),
                "resolution_m": 1000,
                "quality_flag": "COARSE_1KM",
                "licence": SOURCE_LICENCES["public.landscan_2024"],
                "method": "PostGIS raster ST_SummaryStats over ST_Clip",
            },
        }

    def _landscan_sum(self, lat: float, lon: float, radius_m: int) -> float | None:
        try:
            value = self.session.execute(
                text(
                    """
                    WITH buf AS (
                      SELECT ST_Buffer(
                        ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                        :radius_m)::geometry AS g
                    )
                    SELECT sum(s.sum)
                    FROM public.landscan_2024 l
                    CROSS JOIN buf
                    CROSS JOIN LATERAL (
                      SELECT * FROM ST_SummaryStats(ST_Clip(l.rast, buf.g), 1, true)
                    ) s
                    WHERE ST_Intersects(l.rast, buf.g)
                    """
                ),
                {"lat": lat, "lon": lon, "radius_m": radius_m},
            ).scalar()
        except Exception:  # noqa: BLE001
            self.session.rollback()
            return None
        return float(value) if value is not None else None

    def _geotiff_population(self, lat: float, lon: float) -> dict[str, Any] | None:
        """The brief's Rasterio path, wired but only used when configured.

        ``SITEWISE_POPULATION_RASTER`` must point at a population-per-pixel
        GeoTIFF and ``rasterio`` must be importable. Neither is true on this
        machine, so this returns ``None`` and the chain falls through to
        ``unavailable`` — never to a guessed number.
        """
        path = os.environ.get("SITEWISE_POPULATION_RASTER", "").strip()
        if not path or not os.path.exists(path):
            return None
        try:
            import numpy as np
            import rasterio
            from pyproj import Geod
        except ImportError:
            logger.info("enrichment.rasterio_not_installed")
            return None

        try:
            with rasterio.open(path) as dataset:
                if dataset.crs is None:
                    return None
                # Sample the same geodesic rings the PostGIS path uses.
                geod = Geod(ellps="WGS84")
                values: dict[str, float | None] = {}
                for label, radius in (("500m", 500), ("1km", 1000)):
                    lats, lons = _ring_points(lat, lon, radius, geod)
                    rows, cols = rasterio.transform.rowcol(
                        dataset.transform, lons, lats
                    )
                    rows = np.clip(np.asarray(rows), 0, dataset.height - 1)
                    cols = np.clip(np.asarray(cols), 0, dataset.width - 1)
                    window = dataset.read(1, window=(
                        (int(rows.min()), int(rows.max()) + 1),
                        (int(cols.min()), int(cols.max()) + 1),
                    ))
                    if window.size == 0:
                        values[f"population_{label}"] = None
                        continue
                    nodata = dataset.nodata
                    data = window.astype("float64")
                    if nodata is not None:
                        data = data[data != nodata]
                    values[f"population_{label}"] = (
                        float(np.nansum(data)) if data.size else None
                    )
        except Exception as exc:  # noqa: BLE001
            logger.info("enrichment.geotiff_failed error=%s", exc)
            return None

        if values.get("population_1km") is None:
            return None
        return {
            "measurement": values,
            "provenance": {
                "source": path,
                "radii_m": [500, 1000],
                "licence": "configured by SITEWISE_POPULATION_RASTER",
                "method": "Rasterio window sum over geodesic ring extents",
            },
        }

    # ------------------------------------------------------------------
    # Persistence of measurements
    # ------------------------------------------------------------------

    def _write_measurements(
        self,
        property_id: int,
        category: str,
        outcome: _Outcome,
        hash_value: str,
    ) -> None:
        """Write the measured values into the wide feature table.

        Only the columns the category owns are touched, so a population retry
        cannot overwrite a competitor count and a failed category cannot null a
        previous good value.
        """
        columns = _MEASUREMENT_COLUMNS[category]
        assignments = ", ".join(f"{col} = :{col}" for col, _ in columns)
        params: dict[str, Any] = {
            "pid": property_id,
            "hash": hash_value,
            "now": _now(),
        }
        for column, _ in columns:
            params[column] = outcome.measurement.get(column)

        updated = self.session.execute(
            text(
                f"UPDATE fyp.property_geospatial_features SET {assignments}, "
                "coordinate_hash = :hash, last_calculated_at = :now "
                "WHERE property_id = :pid"
            ),
            params,
        ).rowcount
        if not updated:
            names = ", ".join(col for col, _ in columns)
            binds = ", ".join(f":{col}" for col, _ in columns)
            self.session.execute(
                text(
                    "INSERT INTO fyp.property_geospatial_features "
                    f"(property_id, {names}, coordinate_hash, last_calculated_at) "
                    f"VALUES (:pid, {binds}, :hash, :now)"
                ),
                params,
            )
        self.session.commit()


#: Which wide-table columns each category owns. A category may only write its
#: own columns — that is what keeps the five lifecycles independent.
_MEASUREMENT_COLUMNS: dict[str, tuple[tuple[str, str], ...]] = {
    "fnb_competitors": (
        ("competitor_count_500m", "int"),
        ("competitor_count_1km", "int"),
    ),
    "demand_generators": (
        ("demand_generator_count_500m", "int"),
        ("demand_generator_count_1km", "int"),
    ),
    "roads_transport": (
        ("accessibility_road_km_1km", "float"),
        ("nearest_major_road_m", "float"),
        ("transit_stops_500m", "int"),
        ("transit_stops_1km", "int"),
    ),
    "parking": (
        ("parking_facilities_500m", "int"),
        ("parking_facilities_1km", "int"),
        ("nearest_parking_m", "float"),
    ),
    "population": (
        ("population_500m", "float"),
        ("population_1km", "float"),
    ),
}


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------


def _valid_coordinates(lat: Any, lon: Any) -> bool:
    try:
        flat, flon = float(lat), float(lon)
    except (TypeError, ValueError):
        return False
    if not (math.isfinite(flat) and math.isfinite(flon)):
        return False
    return -90 <= flat <= 90 and -180 <= flon <= 180


def _num(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _json(payload: dict[str, Any] | None) -> str | None:
    """Serialise to JSON, or ``None`` so the column stores a SQL NULL."""
    if payload is None:
        return None
    import json

    return json.dumps(payload, default=str, ensure_ascii=False)


def _serialise(row: dict[str, Any]) -> dict[str, Any]:
    """Make a category row JSON-safe for the API and the UI."""
    import json

    out = dict(row)
    for key in ("measurement", "provenance"):
        value = out.get(key)
        if isinstance(value, str):
            try:
                out[key] = json.loads(value)
            except json.JSONDecodeError:
                out[key] = None
    for key in ("started_at", "completed_at", "updated_at"):
        value = out.get(key)
        if isinstance(value, datetime):
            out[key] = value.isoformat()
    return out


def _ring_points(lat: float, lon: float, radius_m: int, geod: Any) -> tuple[list[float], list[float]]:
    """Vertices of a geodesic circle, used to bound a GeoTIFF window."""
    lats: list[float] = []
    lons: list[float] = []
    for bearing in range(0, 360, 15):
        plon, plat, _ = geod.fwd(lon, lat, bearing, radius_m)
        lons.append(plon)
        lats.append(plat)
    return lats, lons
