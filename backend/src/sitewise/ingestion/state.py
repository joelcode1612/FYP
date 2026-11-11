"""Refresh state: snapshots, runs, per-property freshness and the lock.

A PostgreSQL session-level advisory lock provides a CROSS-PROCESS mutex: two
`run_data_refresh.py` processes (or a cron job plus a manual run) can never
interleave. The lock is non-blocking — a second run exits with status
``skipped`` instead of queueing behind the first.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any, Self

from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.session import engine

FRESHNESS_STATES = ("current", "stale", "pending", "failed", "unavailable")


def _now() -> datetime:
    return datetime.now(UTC)


class RefreshAlreadyRunning(RuntimeError):
    """Another refresh process holds the advisory lock."""


class RefreshLock:
    """Non-blocking session-level advisory lock on its own connection."""

    def __init__(self, key: int):
        self.key = int(key)
        self._conn = None
        self.acquired = False

    def __enter__(self) -> Self:
        self._conn = engine.connect()
        got = self._conn.execute(
            text("SELECT pg_try_advisory_lock(:key)"), {"key": self.key}
        ).scalar_one()
        if not got:
            self._conn.close()
            self._conn = None
            raise RefreshAlreadyRunning(
                f"refresh lock key {self.key} is held by another process"
            )
        self.acquired = True
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        if self._conn is None:
            return
        try:
            if self.acquired:
                self._conn.execute(
                    text("SELECT pg_advisory_unlock(:key)"), {"key": self.key}
                )
        finally:
            self._conn.close()
            self._conn = None
            self.acquired = False


class RefreshState:
    """Read/write helpers for the additive refresh-state tables."""

    def __init__(self, session: Session):
        self.session = session

    # --- runs ---------------------------------------------------------------

    def start_run(self, kind: str) -> str:
        run_id = str(uuid.uuid4())
        self.session.execute(
            text(
                "INSERT INTO fnb_a.refresh_run (run_id, kind, status) "
                "VALUES (:id, :kind, 'running')"
            ),
            {"id": run_id, "kind": kind},
        )
        self.session.commit()
        return run_id

    def finish_run(
        self, run_id: str, status: str, metrics: dict[str, Any], error: str | None = None
    ) -> None:
        import json

        self.session.execute(
            text(
                "UPDATE fnb_a.refresh_run SET status = :status, "
                "finished_at = now(), metrics = CAST(:metrics AS jsonb), "
                "last_error = :error WHERE run_id = :id"
            ),
            {
                "id": run_id,
                "status": status,
                "metrics": json.dumps(metrics),
                "error": error,
            },
        )
        self.session.commit()

    # --- snapshots ----------------------------------------------------------

    def snapshot_processed(self, source_name: str, release: str) -> bool:
        row = self.session.execute(
            text(
                "SELECT status FROM fnb_a.source_snapshot "
                "WHERE source_name = :name AND source_release = :release"
            ),
            {"name": source_name, "release": release},
        ).mappings().first()
        return row is not None and row["status"] == "current"

    def record_snapshot(
        self,
        *,
        source_name: str,
        release: str,
        snapshot_at: str,
        licence: str,
        checksum: str,
        stats: dict[str, Any],
        status: str = "current",
        error: str | None = None,
    ) -> None:
        self.session.execute(
            text(
                """
                INSERT INTO fnb_a.source_snapshot (
                    source_name, source_release, source_snapshot_at,
                    source_licence, checksum, status, records_downloaded,
                    records_accepted, records_rejected, duplicates_detected,
                    records_inserted, records_updated, records_unchanged,
                    last_error, duration_seconds
                ) VALUES (
                    :name, :release, CAST(:snapshot_at AS timestamptz),
                    :licence, :checksum, :status, :downloaded, :accepted,
                    :rejected, :duplicates, :inserted, :updated, :unchanged,
                    :error, :duration
                )
                ON CONFLICT (source_name, source_release) DO UPDATE SET
                    status = EXCLUDED.status,
                    records_downloaded = EXCLUDED.records_downloaded,
                    records_accepted = EXCLUDED.records_accepted,
                    records_rejected = EXCLUDED.records_rejected,
                    duplicates_detected = EXCLUDED.duplicates_detected,
                    records_inserted = EXCLUDED.records_inserted,
                    records_updated = EXCLUDED.records_updated,
                    records_unchanged = EXCLUDED.records_unchanged,
                    last_error = EXCLUDED.last_error,
                    duration_seconds = EXCLUDED.duration_seconds,
                    created_at = now()
                """
            ),
            {
                "name": source_name,
                "release": release,
                "snapshot_at": snapshot_at,
                "licence": licence,
                "checksum": checksum,
                "status": status,
                "downloaded": stats.get("records_downloaded", 0),
                "accepted": stats.get("records_accepted", 0),
                "rejected": stats.get("records_rejected", 0),
                "duplicates": stats.get("duplicates_detected", 0),
                "inserted": stats.get("records_inserted", 0),
                "updated": stats.get("records_updated", 0),
                "unchanged": stats.get("records_unchanged", 0),
                "error": error,
                "duration": stats.get("duration_seconds", 0.0),
            },
        )
        self.session.commit()

    def last_successful_snapshot(self, source_name: str | None = None) -> dict | None:
        sql = (
            "SELECT source_name, source_release, source_snapshot_at, status, "
            "records_downloaded, records_inserted, records_updated, created_at "
            "FROM fnb_a.source_snapshot WHERE status = 'current' "
        )
        params: dict[str, Any] = {}
        if source_name:
            sql += " AND source_name = :name "
            params["name"] = source_name
        sql += " ORDER BY created_at DESC LIMIT 1"
        row = self.session.execute(text(sql), params).mappings().first()
        if row is None:
            return None
        return {
            key: (value.isoformat() if isinstance(value, datetime) else value)
            for key, value in dict(row).items()
        }

    # --- feature freshness ---------------------------------------------------

    def set_freshness(
        self,
        property_id: int,
        *,
        status: str,
        version: str,
        source_release: str | None = None,
        error: str | None = None,
        success: bool = False,
    ) -> None:
        if status not in FRESHNESS_STATES:
            raise ValueError(f"invalid freshness state: {status}")
        self.session.execute(
            text(
                """
                INSERT INTO fyp.property_feature_freshness (
                    property_id, refresh_status, calculation_version,
                    features_calculated_at, last_refresh_attempt_at,
                    last_successful_refresh_at, source_release, last_error
                ) VALUES (
                    :pid, :status, :version,
                    CASE WHEN :success THEN now() ELSE NULL END,
                    now(),
                    CASE WHEN :success THEN now() ELSE NULL END,
                    :release, :error
                )
                ON CONFLICT (property_id) DO UPDATE SET
                    refresh_status = EXCLUDED.refresh_status,
                    calculation_version = EXCLUDED.calculation_version,
                    features_calculated_at =
                        CASE WHEN :success THEN now()
                             ELSE fyp.property_feature_freshness.features_calculated_at END,
                    last_refresh_attempt_at = now(),
                    last_successful_refresh_at =
                        CASE WHEN :success THEN now()
                             ELSE fyp.property_feature_freshness.last_successful_refresh_at END,
                    source_release = COALESCE(
                        EXCLUDED.source_release,
                        fyp.property_feature_freshness.source_release),
                    last_error = EXCLUDED.last_error,
                    updated_at = now()
                """
            ),
            {
                "pid": property_id,
                "status": status,
                "version": version,
                "success": success,
                "release": source_release,
                "error": error,
            },
        )
        self.session.commit()

    def freshness(self, property_id: int) -> dict | None:
        row = self.session.execute(
            text("SELECT * FROM fyp.property_feature_freshness WHERE property_id = :pid"),
            {"pid": property_id},
        ).mappings().first()
        if row is None:
            return None
        return {
            key: (value.isoformat() if isinstance(value, datetime) else value)
            for key, value in dict(row).items()
        }

    def freshness_payload(self, property_id: int | None) -> dict:
        """The additive API block. Unknown state is explicit — never a zero."""
        if property_id is None:
            return {
                "status": "unavailable",
                "available": False,
                "reason": "no_operational_property_id",
            }
        row = self.freshness(int(property_id))
        if row is None:
            return {
                "status": "unavailable",
                "available": False,
                "reason": "no_calculation_recorded",
            }
        return {
            "status": row["refresh_status"],
            "available": row["refresh_status"] in {"current", "stale"},
            "calculation_version": row["calculation_version"],
            "features_calculated_at": row["features_calculated_at"],
            "last_refresh_attempt_at": row["last_refresh_attempt_at"],
            "last_successful_refresh_at": row["last_successful_refresh_at"],
            "source_release": row["source_release"],
            "competitor_source": row["competitor_source"],
            "last_error": row["last_error"],
        }

    def record_ambiguous(self, decision: Any) -> None:
        self.session.execute(
            text(
                "INSERT INTO fnb_a.duplicate_review ("
                "incoming_source_name, incoming_record_id, candidate_record_id, "
                "decision, evidence, score) "
                "VALUES (:source, :incoming, :candidate, :decision, :evidence, :score)"
            ),
            {
                "source": decision.incoming.source_name,
                "incoming": decision.incoming.source_record_id,
                "candidate": decision.matched_record_id,
                "decision": decision.decision,
                "evidence": decision.evidence[:2000],
                "score": decision.score,
            },
        )
        self.session.commit()

    def provenance_summary(self, source_name: str | None = None) -> dict:
        """Aggregate provenance for the API freshness block."""
        row = self.session.execute(
            text(
                "SELECT source_name, source_licence, count(*) AS snapshots, "
                "max(created_at) AS latest_snapshot "
                "FROM fnb_a.source_snapshot WHERE status = 'current' "
                "GROUP BY source_name, source_licence ORDER BY 1"
            )
        ).mappings().all()
        sources = [
            {
                "source_name": r["source_name"],
                "source_licence": r["source_licence"],
                "snapshots": r["snapshots"],
                "latest_snapshot": (
                    r["latest_snapshot"].isoformat() if r["latest_snapshot"] else None
                ),
            }
            for r in row
            if source_name is None or r["source_name"] == source_name
        ]
        return {"sources": sources, "available": bool(sources)}
