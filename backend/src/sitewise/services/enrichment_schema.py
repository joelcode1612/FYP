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

import re

from sqlalchemy import text
from sqlmodel import Session

#: The six enrichment categories, in the order the UI presents them.
#: ``age_population`` joins Phase 2 on 2026-11-15: WorldPop age-sex band
#: extraction for newly added listings (validated single-point port of the
#: 2026-11-15 gap-recovery pipeline). It has its OWN lifecycle because it can
#: succeed while the total-population chain fails and vice versa.
CATEGORIES: tuple[str, ...] = (
    "fnb_competitors",
    "demand_generators",
    "roads_transport",
    "parking",
    "population",
    "age_population",
)

#: Phase 1 runs on PostGIS alone and never touches the raster machinery.
PHASE_POSTGIS = "postgis"
#: Phase 2 is raster work (population + age bands) and runs separately from
#: Phase 1.
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
    "age_population": PHASE_POPULATION,
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
    # WorldPop age-sex band counts (model band definitions, partial-pixel
    # weighted sums — see age_band_raster_service). DOUBLE PRECISION because
    # partial-pixel weighting makes fractional counts correct, not dirty.
    ("pop_age_0_14_500m", "DOUBLE PRECISION"),
    ("pop_age_15_24_500m", "DOUBLE PRECISION"),
    ("pop_age_25_34_500m", "DOUBLE PRECISION"),
    ("pop_age_35_49_500m", "DOUBLE PRECISION"),
    ("pop_age_50_64_500m", "DOUBLE PRECISION"),
    ("pop_age_65_plus_500m", "DOUBLE PRECISION"),
    ("pop_age_0_14_1km", "DOUBLE PRECISION"),
    ("pop_age_15_24_1km", "DOUBLE PRECISION"),
    ("pop_age_25_34_1km", "DOUBLE PRECISION"),
    ("pop_age_35_49_1km", "DOUBLE PRECISION"),
    ("pop_age_50_64_1km", "DOUBLE PRECISION"),
    ("pop_age_65_plus_1km", "DOUBLE PRECISION"),
    ("share_age_15_34_500m", "DOUBLE PRECISION"),
    ("share_age_15_34_1km", "DOUBLE PRECISION"),
    ("age_coverage_500m", "DOUBLE PRECISION"),
    ("age_coverage_1km", "DOUBLE PRECISION"),
    ("age_data_source", "TEXT"),
    ("age_data_year", "INTEGER"),
    ("age_data_status", "TEXT"),
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
                         'roads_transport','parking','population',
                         'age_population')),
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

#: The pre-age deployments carry CHECK constraints limited to the five
#: original categories. This migration widens them; it runs ONLY when the
#: live constraint definition does not already include ``age_population``, so
#: repeated ``ensure_schema`` calls never churn the catalog.
CONSTRAINT_MIGRATIONS: tuple[tuple[str, str, str], ...] = (
    (
        "ck_pec_category",
        "age_population",
        """
        ALTER TABLE fyp.property_enrichment_category
            DROP CONSTRAINT IF EXISTS ck_pec_category,
            ADD CONSTRAINT ck_pec_category CHECK (
                category IN ('fnb_competitors','demand_generators',
                             'roads_transport','parking','population',
                             'age_population'))
        """,
    ),
    (
        "ck_pec_phase",
        "('postgis','population')",
        """
        ALTER TABLE fyp.property_enrichment_category
            DROP CONSTRAINT IF EXISTS ck_pec_phase,
            ADD CONSTRAINT ck_pec_phase CHECK (phase IN ('postgis','population'))
        """,
    ),
    (
        "ck_pec_status",
        "('pending','running','current','unavailable','failed','stale')",
        """
        ALTER TABLE fyp.property_enrichment_category
            DROP CONSTRAINT IF EXISTS ck_pec_status,
            ADD CONSTRAINT ck_pec_status CHECK (
                status IN ('pending','running','current','unavailable','failed','stale'))
        """,
    ),
)


def feature_column_ddl() -> tuple[str, ...]:
    return tuple(
        f"ALTER TABLE fyp.property_geospatial_features "
        f"ADD COLUMN IF NOT EXISTS {name} {sql_type}"
        for name, sql_type in FEATURE_COLUMNS
    )


def _covers_constraint(definition: str | None, expected_fragment: str) -> bool:
    """Allow PostgreSQL's normalized CHECK representation and explicit casts."""
    if definition is None:
        return False
    expected_values = re.findall(r"'([^']+)'", expected_fragment)
    if not expected_values:
        expected_values = [expected_fragment]
    actual_values = set(re.findall(r"'([^']+)'", definition))
    return all(value in actual_values for value in expected_values)


def schema_gaps(session: Session) -> list[str]:
    """Check the enrichment prerequisite without taking DDL locks."""
    columns = session.execute(text("""
        SELECT table_name, column_name
        FROM information_schema.columns
        WHERE table_schema = 'fyp'
          AND table_name IN ('property_geospatial_features', 'property_enrichment_category')
    """)).all()
    wide = {column for table, column in columns if table == "property_geospatial_features"}
    missing = [f"property_geospatial_features.{name}" for name, _ in FEATURE_COLUMNS if name not in wide]
    if not any(table == "property_enrichment_category" for table, _ in columns):
        missing.append("property_enrichment_category")
    else:
        for name, fragment, _ in CONSTRAINT_MIGRATIONS:
            definition = session.execute(text("""
                SELECT pg_get_constraintdef(oid)
                FROM pg_constraint
                WHERE conname = :name
                  AND conrelid = to_regclass('fyp.property_enrichment_category')
            """), {"name": name}).scalar()
            if not _covers_constraint(definition, fragment):
                missing.append(name)
    return missing


def ensure_schema(session: Session) -> None:
    """Create the enrichment state table and add the measurement columns.

    Safe to call on every request path that needs the table: every statement is
    idempotent, and the whole thing is one transaction.
    """
    for statement in DDL_STATEMENTS:
        session.execute(text(statement))
    _migrate_constraints(session)
    for statement in feature_column_ddl():
        session.execute(text(statement))
    session.commit()


def _migrate_constraints(session: Session) -> None:
    """Widen the CHECK constraints on pre-age deployments, only when needed."""
    for name, expected_fragment, statement in CONSTRAINT_MIGRATIONS:
        current = session.execute(
            text(
                """
                SELECT pg_get_constraintdef(oid) AS defn
                FROM pg_constraint
                WHERE conname = :name
                  AND conrelid = 'fyp.property_enrichment_category'::regclass
                """
            ),
            {"name": name},
        ).scalar()
        if _covers_constraint(current, expected_fragment):
            continue
        session.execute(text(statement))
