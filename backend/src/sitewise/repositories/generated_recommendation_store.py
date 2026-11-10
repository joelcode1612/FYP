"""Process-local, ownership-scoped store for generated recommendation results.

Why no migration
================
The existing persistence model ``RecommendationResult`` is inspected before
proposing any schema change. It has:

* ``property_id: int`` - a legacy FK to ``public.property``, retired by
  migration 0005. The recommendation catalogue IDs are TEXT (``MD-00510``,
  ``EP-01051``) and cannot be stored there without redefining the column.
* ``score: Decimal(8,5)`` and ``ranking: int`` only - no room for the
  component breakdown, cautions, verification status or SHAP provenance the
  new response contract requires.

Creating a new table (or widening that one) is NOT necessary to make the
pipeline work and would touch unrelated database functionality, which this
integration was explicitly told not to do. Generated results are therefore
kept in this store instead. No DB table, column, migration or ORM model is
added or changed.

Contract and limitations
========================
* Every read is scoped by ``user_id`` taken from the authenticated identity.
  A result owned by another user is indistinguishable from a missing one
  (``None`` -> 404), so the endpoint cannot be used to enumerate results.
* Entries expire after ``ttl_hours`` and the total is capped. This is
  deliberately EPHEMERAL: a process restart, or a different uvicorn worker,
  will not see another worker's results. ``POST /generate`` is cheap and the
  full ranked payload is returned immediately, so a client can always
  regenerate. If durable, cross-worker history is required, that is a
  separate product decision needing a real schema migration.
* Nothing here fabricates scores. It only stores the results the scoring
  engine actually produced.
"""
from __future__ import annotations

import copy
import threading
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any


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
