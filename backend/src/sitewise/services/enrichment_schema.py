"""Additive, idempotent schema for the two-phase property enrichment workflow.

Everything here is ``CREATE ... IF NOT EXISTS`` / ``ADD COLUMN IF NOT EXISTS``.
No existing table, column or row is rewritten, and the 482 already-calculated
feature rows keep their values.

Why a companion table instead of more columns
---------------------------------------------
``fyp.property_geospatial_features`` is one wide row per property and carries
the measured values the rest of the app already reads. It has no place for a
*per-category* lifecycle (each of the five categories fails, is retried and
goes stale independently of the others). ``fyp.property_enrichment_category``
holds that lifecycle — one row per (property, category) — while the wide table
remains the single measurement contract for existing readers.

The category rows are the authority for *state*; the wide table is the
authority for *values*. A category is only ``current`` when its measurement was
written in the same transaction that marked it current.
"""

from __future__ import annotations

from sqlalchemy import text
from sqlmodel import Session

#: The five enrichment categories, in the order the UI presents them.
CATEGORIES: tuple[str, ...] = (
    "fnb_competitors",
    "demand_generators",
    "roads_transport",
    "parking",
    "population",
)

#: Phase 1 runs on PostGIS alone and never touches the raster machinery.
PHASE_POSTGIS = "postgis"
#: Phase 2 is population only and runs separately from Phase 1.
PHASE_POPULATION = "population"
PHASES: tuple[str, ...] = (PHASE_POSTGIS, PHASE_POPULATION)

#: ``running`` is the only non-terminal state; the rest are settled.
STATUSES: tuple[str, ...] = (
    "pending",
    "running",
    "current",
    "unavailable",
    "failed",
    "stale",
)

CATEGORY_PHASE: dict[str, str] = {
    "fnb_competitors": PHASE_POSTGIS,
    "demand_generators": PHASE_POSTGIS,
    "roads_transport": PHASE_POSTGIS,
    "parking": PHASE_POSTGIS,
    "population": PHASE_POPULATION,
}

#: Extra measurement columns added to the wide feature table. Existing readers
#: ignore them; the enrichment service writes them when the category is current.
FEATURE_COLUMNS: tuple[tuple[str, str], ...] = (
    ("parking_facilities_500m", "INTEGER"),
    ("parking_facilities_1km", "INTEGER"),
    ("nearest_parking_m", "DOUBLE PRECISION"),
    ("transit_stops_500m", "INTEGER"),
    ("transit_stops_1km", "INTEGER"),
    ("coordinate_hash", "TEXT"),
    ("enrichment_status", "TEXT"),
    ("enrichment_provenance", "JSONB"),
)

DDL_STATEMENTS: tuple[str, ...] = (
    """
    CREATE TABLE IF NOT EXISTS fyp.property_enrichment_category (
        property_id BIGINT NOT NULL,
        category TEXT NOT NULL,
        phase TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        measurement JSONB,
        provenance JSONB,
        coordinate_hash TEXT,
        calculation_version TEXT,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        started_at TIMESTAMPTZ,
        completed_at TIMESTAMPTZ,
        last_error TEXT,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (property_id, category),
        CONSTRAINT ck_pec_category CHECK (
            category IN ('fnb_competitors','demand_generators',
                         'roads_transport','parking','population')),
        CONSTRAINT ck_pec_phase CHECK (phase IN ('postgis','population')),
        CONSTRAINT ck_pec_status CHECK (
            status IN ('pending','running','current','unavailable','failed','stale'))
    )
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_pec_property
        ON fyp.property_enrichment_category (property_id)
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_pec_status
        ON fyp.property_enrichment_category (status)
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_pec_category_status
        ON fyp.property_enrichment_category (category, status)
    """,
)


def feature_column_ddl() -> tuple[str, ...]:
    return tuple(
        f"ALTER TABLE fyp.property_geospatial_features "
        f"ADD COLUMN IF NOT EXISTS {name} {sql_type}"
        for name, sql_type in FEATURE_COLUMNS
    )


def ensure_schema(session: Session) -> None:
    """Create the enrichment state table and add the measurement columns.

    Safe to call on every request path that needs the table: every statement is
    idempotent, and the whole thing is one transaction.
    """
    for statement in DDL_STATEMENTS:
        session.execute(text(statement))
    for statement in feature_column_ddl():
        session.execute(text(statement))
    session.commit()
