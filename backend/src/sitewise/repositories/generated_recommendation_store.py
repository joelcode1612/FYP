"""Persistence for generated recommendation results.

Two interchangeable stores with one surface
===========================================

``GeneratedRecommendationStore``
    Thread-safe, process-local store (5,000 entries, 24 h TTL). Kept for
    isolated unit tests and as the historical fallback; it does NOT survive a
    restart and does not cross a uvicorn worker boundary.

``DatabaseRecommendationStore``
    PostgreSQL-backed store on the ``recommendation_result`` table. This is
    the production store: batches survive backend restarts and are visible to
    every worker.

Why the legacy table is reused (Phase 5 decision)
=================================================
``recommendation_result`` existed with an INTEGER ``property_id`` that was a
foreign key into ``public.property`` - a table retired by migration 0005. The
recommendation pipeline's property ids are TEXT (``MD-00510``, ``EP-01051``)
and must never be forced through an integer key. The table was EMPTY, so
migration 0008 (``scripts/apply_recommendation_persistence_migration.py``)
retypes the column to TEXT - the same precedent as migration
``0002_saved_property_refs`` - and adds ``batch_id``, typed score columns,
``payload`` (the full result contract as JSONB) and ``shap``. No parallel
table was created; no data was lost.

Contract (both stores)
======================
* Every read is scoped by ``user_id`` taken from the authenticated identity.
  A result owned by another user is indistinguishable from a missing one
  (``None`` -> 404), so the endpoint cannot be used to enumerate results.
* Nothing here fabricates scores. It only stores the results the scoring
  engine actually produced.
* ``DatabaseRecommendationStore`` has no TTL and no bulk wipe: generated
  history is durable. Rows are removed with their owner (``users`` ON DELETE
  CASCADE).
"""
from __future__ import annotations

import copy
import threading
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:  # avoids an import cycle at module load in tests
    from sqlmodel import Session

    from sitewise.db.models.recommendation_result import RecommendationResult


def _now() -> datetime:
    return datetime.now(UTC)


@dataclass
class _Entry:
    result_id: uuid.UUID
    batch_id: uuid.UUID
    user_id: uuid.UUID
    property_id: str
    created_at: datetime
    payload: dict[str, Any]
    shap: dict[str, Any] | None = None


@dataclass
class GeneratedRecommendationStore:
    """Thread-safe in-memory store. One instance is shared per process."""

    max_entries: int = 5_000
    ttl_hours: float = 24.0
    _entries: dict[uuid.UUID, _Entry] = field(default_factory=dict)
    _latest_batch: dict[uuid.UUID, uuid.UUID] = field(default_factory=dict)
    _lock: threading.RLock = field(default_factory=threading.RLock)

    # ---------------------------------------------------------------- writes
    def save_batch(
        self, user_id: uuid.UUID, payloads: list[dict[str, Any]]
    ) -> dict[str, Any]:
        """Persist one ranked batch and return it with stable result ids."""
        batch_id = uuid.uuid4()
        created_at = _now()
        results: list[dict[str, Any]] = []
        entries: list[_Entry] = []

        for payload in payloads:
            result_id = uuid.uuid4()
            stored = copy.deepcopy(payload)
            stored["result_id"] = str(result_id)
            stored["batch_id"] = str(batch_id)
            stored["generated_at"] = created_at.isoformat()
            results.append(stored)
            entries.append(
                _Entry(
                    result_id=result_id,
                    batch_id=batch_id,
                    user_id=user_id,
                    property_id=str(stored.get("property_id") or ""),
                    created_at=created_at,
                    payload=stored,
                )
            )

        with self._lock:
            self._purge(created_at)
            for entry in entries:
                self._entries[entry.result_id] = entry
            if entries:
                self._latest_batch[user_id] = batch_id
        return {
            "batch_id": str(batch_id),
            "generated_at": created_at.isoformat(),
            "result_count": len(results),
            "results": results,
        }

    def attach_shap(
        self,
        result_id: uuid.UUID,
        user_id: uuid.UUID,
        shap_payload: dict[str, Any],
        status: dict[str, Any],
    ) -> dict[str, Any] | None:
        """Cache a resolved SHAP explanation on an owned result."""
        with self._lock:
            entry = self._owned(result_id, user_id)
            if entry is None:
                return None
            entry.shap = copy.deepcopy(shap_payload)
            explanation = entry.payload.setdefault("explanation", {})
            explanation["shap"] = copy.deepcopy(shap_payload)
            explanation["shap_status"] = copy.deepcopy(status)
            return copy.deepcopy(entry.payload)

    # ----------------------------------------------------------------- reads
    def get(self, result_id: uuid.UUID, user_id: uuid.UUID) -> dict[str, Any] | None:
        with self._lock:
            entry = self._owned(result_id, user_id)
            return copy.deepcopy(entry.payload) if entry else None

    def shap_of(
        self, result_id: uuid.UUID, user_id: uuid.UUID
    ) -> dict[str, Any] | None:
        with self._lock:
            entry = self._owned(result_id, user_id)
            return copy.deepcopy(entry.shap) if entry and entry.shap else None

    def latest(self, user_id: uuid.UUID) -> dict[str, Any] | None:
        """The authenticated user's most recent batch, newest ranks first."""
        with self._lock:
            self._purge(_now())
            batch_id = self._latest_batch.get(user_id)
            if batch_id is None:
                return None
            rows = [
                e for e in self._entries.values()
                if e.user_id == user_id and e.batch_id == batch_id
            ]
            if not rows:
                return None
            rows.sort(key=lambda e: int(e.payload.get("final_recommendation", {}).get("rank") or 0))
            return {
                "batch_id": str(batch_id),
                "generated_at": rows[0].created_at.isoformat(),
                "result_count": len(rows),
                "results": [copy.deepcopy(e.payload) for e in rows],
            }

    def clear(self) -> None:
        """Test seam; never called by production request paths."""
        with self._lock:
            self._entries.clear()
            self._latest_batch.clear()

    # --------------------------------------------------------------- internals
    def _owned(self, result_id: uuid.UUID, user_id: uuid.UUID) -> _Entry | None:
        entry = self._entries.get(result_id)
        if entry is None or entry.user_id != user_id:
            return None
        if _now() - entry.created_at > timedelta(hours=self.ttl_hours):
            self._entries.pop(result_id, None)
            return None
        return entry

    def _purge(self, now: datetime) -> None:
        cutoff = timedelta(hours=self.ttl_hours)
        expired = [
            key for key, entry in self._entries.items() if now - entry.created_at > cutoff
        ]
        for key in expired:
            self._entries.pop(key, None)
        if len(self._entries) > self.max_entries:
            overflow = sorted(
                self._entries.values(), key=lambda e: (e.created_at, str(e.result_id))
            )[: len(self._entries) - self.max_entries]
            for entry in overflow:
                self._entries.pop(entry.result_id, None)
        stale_batches = {
            user: batch
            for user, batch in self._latest_batch.items()
            if not any(e.batch_id == batch for e in self._entries.values())
        }
        for user, batch in stale_batches.items():
            if self._latest_batch.get(user) == batch:
                self._latest_batch.pop(user, None)


#: Shared per-process instance. Injectable into the service for tests.
generated_recommendation_store = GeneratedRecommendationStore()


# ---------------------------------------------------------------------------
# Durable PostgreSQL store (Phase 5)
# ---------------------------------------------------------------------------


class DatabaseRecommendationStore:
    """PostgreSQL-backed store with the same surface as the in-memory one.

    Replaces the process-local store on the request path: batches survive
    backend restarts and are visible to every uvicorn worker. Ownership
    semantics are identical - every read is scoped by ``user_id``, so a
    foreign result is indistinguishable from a missing one.
    """

    def __init__(self, session: "Session"):
        self.session = session

    # ---------------------------------------------------------------- writes
    def save_batch(
        self, user_id: uuid.UUID, payloads: list[dict[str, Any]]
    ) -> dict[str, Any]:
        """Insert one ranked batch in a single transaction."""
        from sitewise.db.models.recommendation_result import RecommendationResult

        batch_id = uuid.uuid4()
        created_at = _now()
        results: list[dict[str, Any]] = []
        rows: list["RecommendationResult"] = []

        for payload in payloads:
            result_id = uuid.uuid4()
            stored = copy.deepcopy(payload)
            stored["result_id"] = str(result_id)
            stored["batch_id"] = str(batch_id)
            stored["generated_at"] = created_at.isoformat()
            results.append(stored)

            personalisation = stored.get("personalisation") or {}
            model = stored.get("model") or {}
            final = stored.get("final_recommendation") or {}
            preference = personalisation.get("preference_match_score")
            rows.append(
                RecommendationResult(
                    result_id=result_id,
                    user_id=user_id,
                    property_id=str(stored.get("property_id") or ""),
                    score=Decimal(str(final.get("score", "0"))),
                    ranking=final.get("rank"),
                    created_at=created_at,
                    batch_id=batch_id,
                    pu_association_score=Decimal(str(model.get("association_score", "0"))),
                    preference_match_score=(
                        None if preference is None else Decimal(str(preference))
                    ),
                    scoring_version=personalisation.get("config_version"),
                    model_name=model.get("name"),
                    payload=stored,
                    shap=None,
                )
            )

        self.session.add_all(rows)
        self.session.commit()
        return {
            "batch_id": str(batch_id),
            "generated_at": created_at.isoformat(),
            "result_count": len(results),
            "results": results,
        }

    def attach_shap(
        self,
        result_id: uuid.UUID,
        user_id: uuid.UUID,
        shap_payload: dict[str, Any],
        status: dict[str, Any],
    ) -> dict[str, Any] | None:
        """Persist a resolved SHAP explanation on an owned result."""
        from sqlalchemy import select

        from sitewise.db.models.recommendation_result import RecommendationResult

        row = self.session.execute(
            select(RecommendationResult).where(
                RecommendationResult.result_id == result_id,
                RecommendationResult.user_id == user_id,
            )
        ).scalars().first()
        if row is None:
            return None
        row.shap = {
            "shap": copy.deepcopy(shap_payload),
            "shap_status": copy.deepcopy(status),
        }
        payload = dict(row.payload or {})
        explanation = dict(payload.get("explanation") or {})
        explanation["shap"] = copy.deepcopy(shap_payload)
        explanation["shap_status"] = copy.deepcopy(status)
        row.payload = {**payload, "explanation": explanation}
        self.session.add(row)
        self.session.commit()
        return copy.deepcopy(row.payload)

    # ----------------------------------------------------------------- reads
    def _owned_row(self, result_id: uuid.UUID, user_id: uuid.UUID):
        from sqlalchemy import select

        from sitewise.db.models.recommendation_result import RecommendationResult

        return self.session.execute(
            select(RecommendationResult).where(
                RecommendationResult.result_id == result_id,
                RecommendationResult.user_id == user_id,
            )
        ).scalars().first()

    def get(self, result_id: uuid.UUID, user_id: uuid.UUID) -> dict[str, Any] | None:
        row = self._owned_row(result_id, user_id)
        return copy.deepcopy(row.payload) if row and row.payload else None

    def shap_of(
        self, result_id: uuid.UUID, user_id: uuid.UUID
    ) -> dict[str, Any] | None:
        row = self._owned_row(result_id, user_id)
        if row is None or not row.shap:
            return None
        return copy.deepcopy(row.shap.get("shap"))

    def latest(self, user_id: uuid.UUID) -> dict[str, Any] | None:
        """The user's most recent batch, ranked first - durable across restarts."""
        from sqlalchemy import select

        from sitewise.db.models.recommendation_result import RecommendationResult

        latest_batch = self.session.execute(
            select(RecommendationResult.batch_id)
            .where(RecommendationResult.user_id == user_id)
            .order_by(
                RecommendationResult.created_at.desc(), RecommendationResult.result_id
            )
            .limit(1)
        ).scalars().first()
        if latest_batch is None:
            return None
        rows = self.session.execute(
            select(RecommendationResult)
            .where(
                RecommendationResult.user_id == user_id,
                RecommendationResult.batch_id == latest_batch,
            )
            .order_by(
                RecommendationResult.ranking.nulls_last(), RecommendationResult.result_id
            )
        ).scalars().all()
        payloads = [copy.deepcopy(row.payload) for row in rows if row.payload]
        if not payloads:
            return None
        return {
            "batch_id": str(latest_batch),
            "generated_at": payloads[0].get("generated_at"),
            "result_count": len(payloads),
            "results": payloads,
        }

    def clear(self) -> None:
        """Durable store: never bulk-deletes history.

        The in-memory store's ``clear`` is a test seam. Tests using the
        database store clean up per user via the ``users`` ON DELETE CASCADE.
        """
        return None
