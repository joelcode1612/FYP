"""Additive, idempotent schema for refresh state.

``ensure_schema()`` only issues CREATE ... IF NOT EXISTS / ADD ... IF NOT
EXISTS. No existing table, column or row is modified, and no research data is
replaced. The DDL is shared by the Alembic revision, the refresh CLI
(``--ensure-schema``) and the tests, so all three see the same contract.
"""

from __future__ import annotations

from sqlalchemy import text
from sqlmodel import Session

DDL_STATEMENTS: tuple[str, ...] = (
    # Last successfully processed snapshot per open-data provider.
    """
    CREATE TABLE IF NOT EXISTS fnb_a.source_snapshot (
        snapshot_id BIGSERIAL PRIMARY KEY,
        source_name TEXT NOT NULL,
        source_release TEXT NOT NULL,
        source_snapshot_at TIMESTAMPTZ NOT NULL,
        source_licence TEXT,
        checksum TEXT,
        status TEXT NOT NULL DEFAULT 'current',
        records_downloaded INTEGER NOT NULL DEFAULT 0,
        records_accepted INTEGER NOT NULL DEFAULT 0,
        records_rejected INTEGER NOT NULL DEFAULT 0,
        duplicates_detected INTEGER NOT NULL DEFAULT 0,
        records_inserted INTEGER NOT NULL DEFAULT 0,
        records_updated INTEGER NOT NULL DEFAULT 0,
        records_unchanged INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        duration_seconds DOUBLE PRECISION,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (source_name, source_release),
        CONSTRAINT ck_source_snapshot_status CHECK (
            status IN ('current','pending','failed','superseded'))
    )
    """,
    # One row per refresh attempt, with the measured metrics as jsonb.
    """
    CREATE TABLE IF NOT EXISTS fnb_a.refresh_run (
        run_id UUID PRIMARY KEY,
        kind TEXT NOT NULL,
        status TEXT NOT NULL,
        started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        finished_at TIMESTAMPTZ,
        metrics JSONB NOT NULL DEFAULT '{}'::jsonb,
        last_error TEXT,
        CONSTRAINT ck_refresh_run_status CHECK (
            status IN ('running','success','partial','failed','skipped'))
    )
    """,
    # Ambiguous cross-provider matches are recorded, never auto-merged.
    """
    CREATE TABLE IF NOT EXISTS fnb_a.duplicate_review (
        review_id BIGSERIAL PRIMARY KEY,
        incoming_source_name TEXT NOT NULL,
        incoming_record_id TEXT NOT NULL,
        candidate_record_id TEXT,
        decision TEXT NOT NULL,
        evidence TEXT,
        score DOUBLE PRECISION,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        resolution TEXT,
        resolved_at TIMESTAMPTZ
    )
    """,
    (
        "CREATE INDEX IF NOT EXISTS idx_duplicate_review_incoming "
        "ON fnb_a.duplicate_review (incoming_source_name, incoming_record_id)"
    ),
    # Absence from a snapshot is evidence of ABSENCE, not of closure.
    """
    CREATE TABLE IF NOT EXISTS fnb_a.source_absence (
        source_name TEXT NOT NULL,
        source_record_id TEXT NOT NULL,
        source_release TEXT NOT NULL,
        observed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        evidence TEXT NOT NULL DEFAULT 'absent_from_full_snapshot',
        closure_confirmed BOOLEAN NOT NULL DEFAULT false,
        PRIMARY KEY (source_name, source_record_id, source_release)
    )
    """,
    # Controlled staging table: emptied only while holding the refresh lock.
    # UNIQUE here is safe because this table is owned by the pipeline.
    """
    CREATE TABLE IF NOT EXISTS fnb_a.fnb_outlet_stage (
        source_name TEXT NOT NULL,
        source_record_id TEXT NOT NULL,
        name TEXT NOT NULL,
        category TEXT NOT NULL,
        category_raw TEXT,
        latitude DOUBLE PRECISION NOT NULL,
        longitude DOUBLE PRECISION NOT NULL,
        operating_status TEXT,
        address TEXT,
        postcode TEXT,
        city TEXT,
        phone TEXT,
        website TEXT,
        source_release TEXT NOT NULL,
        source_snapshot_at TIMESTAMPTZ NOT NULL,
        source_updated_at TEXT,
        source_licence TEXT,
        payload JSONB NOT NULL DEFAULT '{}'::jsonb,
        PRIMARY KEY (source_name, source_record_id)
    )
    """,
    (
        "CREATE INDEX IF NOT EXISTS idx_fnb_outlet_stage_coords "
        "ON fnb_a.fnb_outlet_stage (latitude, longitude)"
    ),
    # Per-property calculation freshness. Previous valid FEATURE values stay
    # in fyp.property_geospatial_features; this row only labels their state.
    """
    CREATE TABLE IF NOT EXISTS fyp.property_feature_freshness (
        property_id BIGINT PRIMARY KEY,
        refresh_status TEXT NOT NULL DEFAULT 'pending',
        calculation_version TEXT,
        features_calculated_at TIMESTAMPTZ,
        last_refresh_attempt_at TIMESTAMPTZ,
        last_successful_refresh_at TIMESTAMPTZ,
        source_release TEXT,
        competitor_source TEXT NOT NULL DEFAULT 'osm',
        last_error TEXT,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        CONSTRAINT ck_property_freshness_status CHECK (
            refresh_status IN ('current','stale','pending','failed','unavailable'))
    )
    """,
    # Non-unique lookup index: the live table has 3 pre-existing duplicate
    # natural keys, so a UNIQUE index would fail. New inserts are deduplicated
    # by the synchronizer's existence check under the cross-process lock.
    (
        "CREATE INDEX IF NOT EXISTS idx_fnb_outlet_natural_key "
        "ON fnb_a.fnb_outlet (source_provider, source_record_id)"
    ),
    # Dedicated sequence for new outlet_key values, started above the current
    # maximum so no existing key can ever be reused.
    "CREATE SEQUENCE IF NOT EXISTS fnb_a.fnb_outlet_refresh_key_seq",
    (
        "SELECT setval('fnb_a.fnb_outlet_refresh_key_seq', "
        "COALESCE((SELECT max(outlet_key) FROM fnb_a.fnb_outlet), 0) + 1, false)"
    ),
    (
        "CREATE INDEX IF NOT EXISTS idx_refresh_run_started "
        "ON fnb_a.refresh_run (started_at DESC)"
    ),
)


def ensure_schema(session: Session) -> None:
    """Create the refresh-state tables if they do not exist.

    Caller controls the transaction; this is deliberately NOT committed here
    so the CLI can wrap the whole refresh in one unit where needed.
    """
    for ddl in DDL_STATEMENTS:
        session.execute(text(ddl))
    session.commit()
