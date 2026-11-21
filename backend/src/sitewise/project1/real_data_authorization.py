"""Real-data BDJ authorisation lookup (production counterpart of the trial authority).

A row in ``project1_ai.bdj_real_data_authorizations`` is the only thing that lets
a non-synthetic worksheet through ``validate_synthetic``. The row is bound to one
source fingerprint, one ruleset hash and one prompt hash, so it cannot be reused
for a different worksheet, a different ruleset or a re-worded prompt.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass
from uuid import UUID

from sqlalchemy import text

REAL_DATA_CLASS = 'ENTREPRENEUR_DECLARED'


@dataclass(frozen=True)
class RealDataAuthorization:
    """A matched, unexpired, unconsumed authorisation for this exact run."""
    id: UUID
    assessment_id: UUID
    assessment_revision: int
    source_fingerprint: str
    ruleset_version: str
    rules_sha256: str
    prompt_sha256: str
    authorized_by: UUID
    receipt: str


def prompt_sha256(prompt_text: str) -> str:
    return hashlib.sha256(prompt_text.encode('utf-8')).hexdigest()


def load(*, engine, assessment_id: UUID, revision: int, source_fingerprint: str,
         ruleset_version: str, rules_sha256: str, prompt_digest: str,
         data_class: str | None = None) -> RealDataAuthorization | None:
    """Return the matching live authorisation, or None. Never raises on absence."""
    # The disclosure guard has already established that data_class is NOT
    # SYNTHETIC_NONHUMAN. The security boundary is the row match below (exact
    # fingerprint + ruleset hash + prompt hash + unexpired + unconsumed), not the
    # spelling of the class label, so the label is recorded but not gated here.
    with engine.begin() as conn:
        conn.exec_driver_sql('SET LOCAL ROLE p1ai_runtime')
        row = conn.execute(text(
            'SELECT id, assessment_id, assessment_revision, source_fingerprint,'
            '       ruleset_version, rules_sha256, prompt_sha256, authorized_by, receipt'
            '  FROM project1_ai.bdj_real_data_authorizations'
            ' WHERE assessment_id=:a AND assessment_revision=:r'
            '   AND source_fingerprint=:f AND ruleset_version=:v'
            '   AND rules_sha256=:rh AND prompt_sha256=:ph'
            '   AND consumed_at IS NULL AND expires_at > now()'),
            {'a': assessment_id, 'r': revision, 'f': source_fingerprint,
             'v': ruleset_version, 'rh': rules_sha256, 'ph': prompt_digest}).mappings().first()
    if row is None:
        return None
    return RealDataAuthorization(**dict(row))


def consume(*, engine, authorization_id: UUID, run_id: UUID) -> None:
    """Mark single-use, in the caller's transaction window."""
    with engine.begin() as conn:
        conn.exec_driver_sql('SET LOCAL ROLE p1ai_runtime')
        conn.execute(text(
            'UPDATE project1_ai.bdj_real_data_authorizations'
            '   SET consumed_at = now(), consumed_run_id = :run'
            ' WHERE id=:id AND consumed_at IS NULL'),
            {'id': authorization_id, 'run': run_id})
