"""Persistent validated-explanation cache: identity, lookup and single-flight jobs.

Application-layer seam between the request paths (which only ask "is a valid
explanation stored?"/"schedule one") and the SQLModel table. All identity
decisions live here so the two consumers — the property-insights service and
the recommendation service — cannot drift apart.
"""

from __future__ import annotations

import hashlib
import json
import threading
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

from sqlalchemy import text as sql_text
from sqlmodel import Session, select

from sitewise.db.models.ml_explanation_cache import LEASE_TTL, MlExplanationCache, utcnow


def feature_digest(values: dict[str, Any]) -> str:
    """Stable fingerprint of one property's resolved model-feature vector.

    Canonical across every consumer (property insights, recommendations, the
    precompute CLI): keys sorted, floats rounded to 1e-6, None preserved.
    A re-measured or corrected feature row therefore produces a different
    cache identity, which is what invalidates its stored explanation.
    """
    payload = json.dumps(
        {
            name: (None if value is None else round(float(value), 6))
            for name, value in sorted(values.items())
        },
        separators=(",", ":"),
        sort_keys=True,
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


#: (path, mtime_ns, size) -> sha256. Checksumming the artifact/background on
#: every request is wasted work; a replaced file changes its identity.
_FILE_SHA_CACHE: dict[tuple[str, int, int], str | None] = {}
_FILE_SHA_LOCK = threading.Lock()


def cached_file_sha256(path: Path) -> str | None:
    """SHA-256 of a file, memoised on its exact (path, mtime_ns, size)."""
    try:
        stat = path.stat()
    except OSError:
        return None
    key = (str(path), stat.st_mtime_ns, stat.st_size)
    with _FILE_SHA_LOCK:
        hit = _FILE_SHA_CACHE.get(key)
    if hit is not None:
        return hit
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        value: str | None = digest.hexdigest()
    except OSError:
        return None
    with _FILE_SHA_LOCK:
        _FILE_SHA_CACHE[key] = value
    return value

#: Canonical explanation method + configuration. These belong to the cache
#: identity: a changed background size, tolerance or explainer algorithm must
#: invalidate stored rows. The values MUST match what ``ShapExplainer``
#: actually computes (see the module docstring there — the computation is
#: unchanged by the performance work).
METHOD = "permutation"
METHOD_CONFIG = {
    "algorithm": "permutation",
    "masker": "independent",
    "max_evals_rule": "2*features+1",
    "additivity_tolerance": 1e-6,
}


@dataclass(frozen=True)
class ExplanationIdentity:
    """Everything that must match for a stored explanation to be valid."""

    property_id: str
    model_name: str
    model_version: str | None
    artifact_sha256: str | None
    feature_digest: str
    background_sha256: str | None
    background_size: int
    method_config: dict[str, Any] = field(default_factory=lambda: dict(METHOD_CONFIG))

    def cache_key(self) -> str:
        canonical = json.dumps(
            {
                "property_id": self.property_id,
                "model_name": self.model_name,
                "model_version": self.model_version,
                "artifact_sha256": self.artifact_sha256,
                "feature_digest": self.feature_digest,
                "background_sha256": self.background_sha256,
                "background_size": self.background_size,
                "method": METHOD,
                "config": self.method_config,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class ExplanationJob:
    """The minimum a background worker needs to recompute an explanation.

    ``business_type`` is deliberately absent: the stored payload covers the
    PU score/explanation/categories/map only — the business-type-dependent
    Stage-2 block is rebuilt on every request and never cached here.
    """

    cache_key: str
    property_id: str
    #: Set when the enqueueing request already knows the requested key; the
    #: worker closes this row even if it stores under a newly derived key.
    requested_key: str | None = None


def get_ready(session: Session, cache_key: str) -> dict[str, Any] | None:
    """The stored validated insights payload for an exact identity, or None."""
    payload = get_ready_raw(session, cache_key)
    if payload is None or not payload.get("explanation", {}).get("available"):
        return None
    return payload


def get_ready_raw(session: Session, cache_key: str) -> dict[str, Any] | None:
    """The stored payload for an exact identity, whatever its consumer shape.

    Callers validate the payload against their own contract (the insights
    payload carries ``explanation.available``; the recommendation SHAP payload
    carries ``reconstruction_verified``).
    """
    row = session.exec(
        select(MlExplanationCache).where(MlExplanationCache.cache_key == cache_key)
    ).first()
    if row is None or row.status != "ready" or not row.payload:
        return None
    try:
        payload = json.loads(row.payload)
    except (TypeError, ValueError):
        return None
    return payload if isinstance(payload, dict) else None


def get_status(session: Session, cache_key: str) -> str | None:
    row = session.exec(
        select(MlExplanationCache.status).where(MlExplanationCache.cache_key == cache_key)
    ).first()
    return row if isinstance(row, str) else (getattr(row, "status", None) if row else None)


def failure_reason(session: Session, cache_key: str) -> str | None:
    row = session.exec(
        select(MlExplanationCache.reason).where(MlExplanationCache.cache_key == cache_key)
    ).first()
    return row if isinstance(row, str) else (getattr(row, "reason", None) if row else None)


def schedule(
    session: Session,
    identity: ExplanationIdentity,
) -> tuple[bool, bool]:
    """Create-or-claim a pending row and report whether the caller must compute.

    Returns ``(row_ready_to_compute, newly_scheduled)``:

    * a fresh row was inserted → ``(True, True)``;
    * an existing pending row whose lease expired (or was never claimed) is
      re-claimed → ``(True, False)`` so the worker retries idempotently;
    * a live lease (another worker is on it) or a row at the attempt cap →
      ``(False, False)``;
    * anything else → ``(False, False)``.

    The insert uses the database's unique-PK conflict behaviour rather than a
    read-then-write, so two simultaneous requests for the same identity can
    never schedule duplicate jobs.
    """
    cache_key = identity.cache_key()
    now = utcnow()
    inserted = session.exec(
        sql_text(
            """
            INSERT INTO fyp.ml_explanation_cache
                (cache_key, property_id, model_name, model_version, artifact_sha256,
                 background_sha256, method, status, reason, attempt_count, claimed_at,
                 created_at, updated_at)
            VALUES
                (:cache_key, :property_id, :model_name, :model_version, :artifact_sha256,
                 :background_sha256, :method, 'pending', NULL, 1, :now, :now, :now)
            ON CONFLICT (cache_key) DO NOTHING
            RETURNING cache_key
            """
        ).bindparams(
            cache_key=cache_key,
            property_id=identity.property_id,
            model_name=identity.model_name,
            model_version=identity.model_version,
            artifact_sha256=identity.artifact_sha256,
            background_sha256=identity.background_sha256,
            method=METHOD,
            now=now,
        )
    ).first()
    session.commit()
    if inserted is not None:
        return True, True

    # Existing row: claim it only when its lease is dead, so a concurrent
    # request cannot double-schedule, and a crashed worker's row recovers.
    claimed = session.exec(
        sql_text(
            """
            UPDATE fyp.ml_explanation_cache
               SET claimed_at = :now,
                   attempt_count = attempt_count + 1,
                   updated_at = :now
             WHERE cache_key = :cache_key
               AND status = 'pending'
               AND attempt_count < 5
               AND (claimed_at IS NULL OR claimed_at < :stale)
            RETURNING cache_key
            """
        ).bindparams(cache_key=cache_key, now=now, stale=now - LEASE_TTL)
    ).first()
    session.commit()
    return (claimed is not None), False


def store_ready(
    session: Session,
    identity: ExplanationIdentity,
    payload: dict[str, Any],
) -> None:
    """Persist a validated explanation payload (idempotent upsert)."""
    now = utcnow()
    session.exec(
        sql_text(
            """
            INSERT INTO fyp.ml_explanation_cache
                (cache_key, property_id, model_name, model_version, artifact_sha256,
                 background_sha256, method, status, payload, reason, attempt_count,
                 claimed_at, created_at, updated_at)
            VALUES
                (:cache_key, :property_id, :model_name, :model_version, :artifact_sha256,
                 :background_sha256, :method, 'ready', :payload, NULL, 1, NULL, :now, :now)
            ON CONFLICT (cache_key) DO UPDATE
               SET status = 'ready',
                   payload = EXCLUDED.payload,
                   reason = NULL,
                   updated_at = EXCLUDED.updated_at
            """
        ).bindparams(
            cache_key=identity.cache_key(),
            property_id=identity.property_id,
            model_name=identity.model_name,
            model_version=identity.model_version,
            artifact_sha256=identity.artifact_sha256,
            background_sha256=identity.background_sha256,
            method=METHOD,
            payload=json.dumps(payload, default=str),
            now=now,
        )
    )
    session.commit()


def mark_failed(session: Session, cache_key: str, reason: str) -> None:
    """Record a permanent failure so requests report it without recomputing."""
    now = utcnow()
    session.exec(
        sql_text(
            """
            UPDATE fyp.ml_explanation_cache
               SET status = 'failed', reason = :reason, updated_at = :now
             WHERE cache_key = :cache_key AND status <> 'ready'
            """
        ).bindparams(cache_key=cache_key, reason=reason[:1000], now=now)
    )
    session.commit()


def close_superseded(session: Session, requested_key: str, derived_key: str) -> None:
    """When inputs changed mid-job, close the stale pending row truthfully."""
    if requested_key == derived_key:
        return
    mark_failed(
        session,
        requested_key,
        "Superseded: the property's features, background or model changed while "
        "the explanation was being computed. A fresh explanation is stored "
        "under the new identity.",
    )


def pending_jobs(session: Session, limit: int = 100) -> list[ExplanationJob]:
    """Unclaimed or lease-expired jobs, for resume-after-restart."""
    now = utcnow()
    rows = session.exec(
        select(MlExplanationCache)
        .where(MlExplanationCache.status == "pending")
        .where(MlExplanationCache.attempt_count < 5)
        .where(
            (MlExplanationCache.claimed_at.is_(None))  # type: ignore[operator]
            | (MlExplanationCache.claimed_at < now - LEASE_TTL)
        )
        .order_by(MlExplanationCache.created_at.asc())  # type: ignore[union-attr]
        .limit(limit)
    ).all()
    return [
        ExplanationJob(
            cache_key=row.cache_key,
            property_id=row.property_id,
            requested_key=row.cache_key,
        )
        for row in rows
    ]
