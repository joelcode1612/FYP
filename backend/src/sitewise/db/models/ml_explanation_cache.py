"""Persistent, validated SHAP-explanation cache for catalogue properties.

Why this table exists (the brief forbids new tables unless existing storage
cannot safely support property-level explanation caching — it cannot):

* ``ai_explanation`` is USER-scoped audit content: a JSON blob with a legacy
  integer property FK and no cache-identity columns, uniqueness or lease
  primitives. System-level, per-property, per-model-version explanation rows
  cannot be upserted, single-flighted or enumerated there.
* ``recommendation_result.shap`` is scoped to ONE user's recommendation
  result row, not to a property's model identity.

Identity and invalidation are enforced by the cache KEY, a SHA-256 over the
canonical identity tuple (property, model name + version, artifact SHA-256,
ordered feature-vector digest, background SHA-256, method + configuration).
Any change to the artifact, the background or the property's feature values
produces a different key, so a stale explanation is unreachable by
construction. Created automatically by ``create_db_and_tables`` (not
externally managed).
"""

import uuid
from datetime import datetime, timedelta, timezone
from typing import Optional

from sqlmodel import Field, SQLModel


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class MlExplanationCache(SQLModel, table=True):
    __tablename__ = "ml_explanation_cache"
    # ``public``, not ``fyp``: the table is ``public.ml_explanation_cache`` in
    # both databases. Declaring ``fyp`` made every cache read and write target a
    # table that exists in neither, so the cache silently never persisted.
    __table_args__ = {"schema": "public", "info": {"externally_managed": True}}

    #: SHA-256 hex digest of the canonical identity tuple.
    cache_key: str = Field(primary_key=True, max_length=64)
    property_id: str = Field(index=True, max_length=40)
    model_name: str = Field(max_length=120)
    model_version: Optional[str] = Field(default=None, max_length=160)
    artifact_sha256: Optional[str] = Field(default=None, max_length=64)
    background_sha256: Optional[str] = Field(default=None, max_length=64)
    #: "permutation" — the only method this deployment computes.
    method: str = Field(default="permutation", max_length=40)
    #: "pending" | "ready" | "failed"
    status: str = Field(default="pending", max_length=16, index=True)
    #: JSON-serialised validated explanation payload (status="ready" only).
    payload: Optional[str] = Field(default=None)
    #: Truthful failure/pending reason for status in {pending, failed}.
    reason: Optional[str] = Field(default=None)
    attempt_count: int = Field(default=0)
    #: Single-flight lease: the worker that claimed the job. A lease older
    #: than LEASE_TTL is stealable, so a crashed process cannot wedge a row.
    claimed_at: Optional[datetime] = Field(default=None, index=True)
    created_at: datetime = Field(default_factory=_utcnow)
    updated_at: datetime = Field(default_factory=_utcnow)


#: How long a claimed-but-unfinished job stays exclusive. Generous: one
#: uncached explanation measured at 0.1-35 s even cold, so 15 minutes covers
#: a contended worker many times over while still recovering from crashes.
LEASE_TTL = timedelta(minutes=15)


def utcnow() -> datetime:
    return _utcnow()
