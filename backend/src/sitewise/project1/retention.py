"""Retention enforcement for the protected raw-response store.

THE PROBLEM
``project1_ai.bdj_raw_responses.retention_until`` promises a deadline, but the
row is append-only (``deny_mutation()`` refuses UPDATE and DELETE). The promise
therefore has exactly one implementation: destroy the per-record key
(``key_custody.py``) at expiry. The ciphertext, its digest and its byte count
stay in place and stay byte-identical; only the ability to read them is gone.

WHY THE RECEIPT IS A FILE
The audit receipt cannot be a row in ``bdj_raw_responses`` (no UPDATE) and a
new receipt table would be a schema change, which this phase is not authorised
to make. So the receipt is appended to an insert-only JSONL ledger under
``backend/var/audit/`` and returned to the caller. The production-grade option
is a receipt table in ``project1_ai`` -- a table is queryable, RLS-scoped,
truncation-proof and visible to a DBA, none of which a local file is -- and it
is not created here only because ``backend/migrations/`` is off limits. The
ledger is a stop-gap that must be replaced, not a design.

IDENTITY
The runtime principal has INSERT but no SELECT on ``bdj_raw_responses``, so
this job cannot run as ``p1ai_runtime``. ``select_expired`` requires an engine
that already holds SELECT through ``p1ai_audit`` (``technical_audit_read``).
No grant is created here: choosing the retention identity is an Owner/DBA
decision, and inventing one in application code would be a privilege
escalation.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import text

from sitewise.core.config import settings
from sitewise.project1.key_custody import (OUTCOME_ALREADY_DESTROYED,
                                           REASON_RETENTION_EXPIRED, KeyCustody,
                                           KeyCustodyError)

RECEIPT_SCHEMA = 'project1-retention-receipt/1'
ACTOR_RETENTION_JOB = 'project1_ai.retention_job'


@dataclass(frozen=True)
class ExpiredRecord:
    """One raw-response row whose retention deadline has passed."""

    result_id: str
    key_id: str


@dataclass
class ShredReport:
    """Recorded receipts, plus what was skipped and why.

    ``recorded`` holds only the receipts actually appended, so its length is
    the number of audit entries this call created. An idempotent repeat reports
    ``already_destroyed`` instead of writing a second receipt for the same key:
    one destruction, one receipt.
    """

    recorded: list[dict] = field(default_factory=list)
    already_destroyed: list[str] = field(default_factory=list)
    missing: list[str] = field(default_factory=list)


def default_ledger_path() -> Path:
    configured = settings.project1_retention_receipt_path.strip()
    if configured:
        return Path(configured)
    return Path(__file__).resolve().parents[3] / 'var' / 'audit' / \
        'project1_retention_receipts.jsonl'


def _utc(value: datetime | None) -> datetime:
    if value is None:
        return datetime.now(timezone.utc)
    if value.tzinfo is None:
        # A naive deadline compared against a timestamptz is a silent timezone
        # bug in the one place where being early or late changes a legal
        # obligation. Refuse rather than guess.
        raise ValueError('RETENTION_CLOCK_MUST_BE_TIMEZONE_AWARE')
    return value


def select_expired(engine, *, now: datetime | None = None,
                   limit: int = 500) -> list[ExpiredRecord]:
    """Rows at or past their deadline, oldest first.

    ``<= now`` rather than ``< now``: the deadline is inclusive, and a row that
    expires at exactly this instant is expired.
    """
    moment = _utc(now)
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 5000:
        raise ValueError('RETENTION_LIMIT_INVALID')
    with engine.connect() as conn:
        rows = conn.execute(text(
            'SELECT result_id, key_id FROM project1_ai.bdj_raw_responses'
            ' WHERE retention_until <= :now'
            ' ORDER BY retention_until LIMIT :limit'),
            {'now': moment, 'limit': limit}).mappings().all()
    return [ExpiredRecord(result_id=str(row['result_id']), key_id=row['key_id'])
            for row in rows]


def _append_receipt(path: Path, receipt: dict) -> None:
    """One O_APPEND write + fsync. Never rewrites, never truncates."""
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(receipt, sort_keys=True, ensure_ascii=False,
                      separators=(',', ':')) + '\n'
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, line.encode('utf-8'))
        os.fsync(fd)
    finally:
        os.close(fd)


def shred(custody: KeyCustody, records: list[ExpiredRecord], *,
          actor: str = ACTOR_RETENTION_JOB, ledger_path: Path | str | None = None,
          now: datetime | None = None,
          reason_code: str = REASON_RETENTION_EXPIRED) -> ShredReport:
    """Destroy the key of each expired record and append one receipt each.

    Pure with respect to the database: it takes the already-selected records,
    so the destruction path can be exercised without a connection and without a
    grant. Deduplicates by ``key_id`` because two rows sharing a key would
    otherwise produce two receipts for one destruction.
    """
    moment = _utc(now)
    ledger = Path(ledger_path) if ledger_path is not None else default_ledger_path()
    report = ShredReport()
    seen: set[str] = set()
    for record in records:
        if record.key_id in seen:
            continue
        seen.add(record.key_id)
        try:
            receipt = custody.destroy(record.key_id, reason_code=reason_code)
        except KeyCustodyError:
            # No receipt for a destruction that did not happen: an audit entry
            # claiming success would be worse than a loud failure.
            raise
        if receipt.outcome == OUTCOME_ALREADY_DESTROYED:
            report.already_destroyed.append(record.key_id)
            continue
        entry = {
            'schema': RECEIPT_SCHEMA,
            'actor': actor,
            'result_id': record.result_id,
            'key_id': receipt.key_id,
            'timestamp': moment.isoformat(),
            'destroyed_at': receipt.destroyed_at,
            'reason_code': reason_code,
            'outcome': receipt.outcome,
        }
        _append_receipt(ledger, entry)
        report.recorded.append(entry)
        if receipt.outcome == 'KEY_MISSING':
            report.missing.append(record.key_id)
    return report


def run_retention(engine, custody: KeyCustody, *,
                  actor: str = ACTOR_RETENTION_JOB,
                  ledger_path: Path | str | None = None,
                  now: datetime | None = None, limit: int = 500) -> ShredReport:
    """Select expired rows under the audit identity, then shred their keys."""
    return shred(custody, select_expired(engine, now=now, limit=limit),
                 actor=actor, ledger_path=ledger_path, now=now)
