"""Pure unit tests for CP-08 QG retry slots. No database is opened.

A recording fake Session stands in for SQLModel's Session so the SQL branch,
bind parameters and commit behaviour can be proved without touching Dss or a
private cluster. The real restricted-role path is exercised by
run_qg_retry_isolated.py.
"""
from __future__ import annotations

from uuid import uuid4

import pytest

from sitewise.project1 import ledger as ledger_mod
from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.ledger import PostgresAttemptLedger


_HEX = 'a' * 64


class _Result:
    """Just enough of a SQLAlchemy Result for the ledger's read patterns."""

    def __init__(self, rows=(), scalar=None):
        self._rows = list(rows)
        self._scalar = scalar

    def one_or_none(self):
        return self._rows[0] if self._rows else None

    def scalar(self):
        return self._scalar

    def all(self):
        return list(self._rows)


class RecordingSession:
    def __init__(self, *, has_slot=True, run_exists=True, rows=()):
        self.has_slot = has_slot
        self.run_exists = run_exists
        self.rows = list(rows)
        self.calls = []  # (sql, params)
        self.committed = False

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def execute(self, statement, params=None):
        sql = str(statement)
        self.calls.append((sql, dict(params or {})))
        if 'information_schema.columns' in sql:
            return _Result(scalar=self.has_slot)
        if 'FROM project1_ai.runs' in sql:
            return _Result(rows=[object()] if self.run_exists else [])
        if 'FROM project1_ai.attempts' in sql:
            return _Result(rows=self.rows)
        return _Result()

    def commit(self):
        self.committed = True

    @property
    def inserts(self):
        return [(sql, p) for sql, p in self.calls
                if sql.lstrip().upper().startswith('INSERT')]

    @property
    def schema_probes(self):
        return [sql for sql, _ in self.calls if 'information_schema.columns' in sql]

    @property
    def attempt_reads(self):
        return [sql for sql, _ in self.calls if 'FROM project1_ai.attempts' in sql]


def _install(monkeypatch, session):
    scopes = []
    monkeypatch.setattr(ledger_mod, 'Session', lambda engine: session)
    monkeypatch.setattr(PostgresAttemptLedger, '_scope',
                        lambda self, s: scopes.append(s))
    return scopes


def _ledger():
    return PostgresAttemptLedger(object(), uuid4(), uuid4())


# -- stage / slot validation ------------------------------------------------

def test_unregistered_stage_is_refused_before_any_sql(monkeypatch):
    session = RecordingSession()
    _install(monkeypatch, session)
    with pytest.raises(WorkflowHeld, match='MODEL_STAGE_UNREGISTERED'):
        _ledger().reserve('BDX', 'v', _HEX, _HEX, attempt_slot=0)
    assert session.calls == []


@pytest.mark.parametrize('bad', [
    0, 4, -1, 99, 1.0, 2.5, '2', '', None, True, False, object(),
])
def test_invalid_attempt_slot_refused_before_any_sql(monkeypatch, bad):
    session = RecordingSession()
    _install(monkeypatch, session)
    with pytest.raises(WorkflowHeld) as exc:
        _ledger().reserve('QG', 'v', _HEX, _HEX, attempt_slot=bad)
    assert exc.value.args[0] == 'MODEL_STAGE_INVALID_ATTEMPT_SLOT'
    assert session.calls == []
    assert session.committed is False


@pytest.mark.parametrize('slot', [1, 2, 3])
def test_valid_slots_are_accepted(monkeypatch, slot):
    session = RecordingSession(has_slot=True)
    scopes = _install(monkeypatch, session)
    assert _ledger().reserve('QG', 'v', _HEX, _HEX, attempt_slot=slot) == 1
    assert len(session.inserts) == 1
    assert session.committed is True
    assert scopes == [session]
    assert len(session.schema_probes) == 1  # exactly one probe per call


# -- legacy vs slot INSERT branch -------------------------------------------

def test_default_slot_one_uses_legacy_insert_on_migrated_schema(monkeypatch):
    session = RecordingSession(has_slot=True)
    _install(monkeypatch, session)
    assert _ledger().reserve('QG', 'v', _HEX, _HEX) == 1
    sql, params = session.inserts[0]
    assert 'attempt_slot' not in sql
    assert 'slot' not in params
    assert params['n'] == 1
    assert 'attempt_slot' in session.attempt_reads[0]


def test_slot_two_uses_slot_insert(monkeypatch):
    session = RecordingSession(has_slot=True)
    _install(monkeypatch, session)
    assert _ledger().reserve('QG', 'v', _HEX, _HEX, attempt_slot=2) == 1
    sql, params = session.inserts[0]
    assert 'attempt_slot' in sql
    assert params['slot'] == 2
    assert params['n'] == 1


def test_slot_one_uses_legacy_insert_on_unmigrated_schema(monkeypatch):
    """The old Dss must keep accepting the original slot-1 statement."""
    session = RecordingSession(has_slot=False)
    _install(monkeypatch, session)
    assert _ledger().reserve('QG', 'v', _HEX, _HEX, attempt_slot=1) == 1
    sql, params = session.inserts[0]
    assert 'attempt_slot' not in sql
    assert 'slot' not in params
    assert 'attempt_slot' not in session.attempt_reads[0]


# -- attempt_no from max, duplicates, cap ------------------------------------

def test_attempt_no_comes_from_max_not_row_count(monkeypatch):
    rows = [(1, 'QG', 1), (2, 'BDJ', 1), (4, 'QJ', 1)]  # len 3, max 4
    session = RecordingSession(has_slot=True, rows=rows)
    _install(monkeypatch, session)
    assert _ledger().reserve('QG', 'v', _HEX, _HEX, attempt_slot=2) == 5
    assert session.inserts[0][1]['n'] == 5


def test_duplicate_stage_slot_refused(monkeypatch):
    session = RecordingSession(has_slot=True, rows=[(1, 'QG', 1), (2, 'QG', 2)])
    _install(monkeypatch, session)
    with pytest.raises(WorkflowHeld, match='MODEL_STAGE_ALREADY_RESERVED'):
        _ledger().reserve('QG', 'v', _HEX, _HEX, attempt_slot=2)
    assert session.inserts == []
    assert session.committed is False


def test_same_stage_new_slot_is_allowed(monkeypatch):
    session = RecordingSession(has_slot=True, rows=[(1, 'QG', 1)])
    _install(monkeypatch, session)
    assert _ledger().reserve('QG', 'v', _HEX, _HEX, attempt_slot=2) == 2
    assert len(session.inserts) == 1


def test_same_slot_different_stage_is_allowed(monkeypatch):
    session = RecordingSession(has_slot=True, rows=[(1, 'QG', 1)])
    _install(monkeypatch, session)
    assert _ledger().reserve('BDJ', 'v', _HEX, _HEX, attempt_slot=1) == 2


def test_unmigrated_schema_still_refuses_second_stage_attempt(monkeypatch):
    session = RecordingSession(has_slot=False, rows=[(1, 'QG')])
    _install(monkeypatch, session)
    with pytest.raises(WorkflowHeld, match='MODEL_STAGE_ALREADY_RESERVED'):
        _ledger().reserve('QG', 'v', _HEX, _HEX)
    assert session.inserts == []


def test_per_run_cap_still_enforced(monkeypatch):
    rows = [(i, 'QJ', 1) for i in range(1, 7)]
    session = RecordingSession(has_slot=True, rows=rows)
    _install(monkeypatch, session)
    with pytest.raises(WorkflowHeld, match='MODEL_ATTEMPT_BUDGET_EXHAUSTED'):
        _ledger().reserve('QG', 'v', _HEX, _HEX, attempt_slot=2)
    assert session.inserts == []


def test_gap_cannot_push_attempt_no_beyond_cap(monkeypatch):
    session = RecordingSession(has_slot=True, rows=[(6, 'QJ', 1)])
    _install(monkeypatch, session)
    with pytest.raises(WorkflowHeld, match='MODEL_ATTEMPT_BUDGET_EXHAUSTED'):
        _ledger().reserve('QG', 'v', _HEX, _HEX, attempt_slot=2)
    assert session.inserts == []


# -- version guard and unchanged paths --------------------------------------

def test_slot_above_one_refused_before_insert_on_old_schema(monkeypatch):
    """An un-migrated ledger never silently loses a retry attempt."""
    session = RecordingSession(has_slot=False, rows=[(1, 'QG')])
    _install(monkeypatch, session)
    with pytest.raises(WorkflowHeld) as exc:
        _ledger().reserve('QG', 'v', _HEX, _HEX, attempt_slot=2)
    assert exc.value.args[0] == 'WORKFLOW_LEDGER_VERSION_UNSUPPORTED'
    assert session.inserts == []
    assert session.attempt_reads == []
    assert session.committed is False
    assert len(session.schema_probes) == 1


def test_missing_run_refused(monkeypatch):
    session = RecordingSession(run_exists=False)
    _install(monkeypatch, session)
    with pytest.raises(WorkflowHeld, match='WORKFLOW_RUN_NOT_FOUND'):
        _ledger().reserve('QG', 'v', _HEX, _HEX, attempt_slot=2)
    assert session.inserts == []


def test_finish_outcome_validation_unchanged(monkeypatch):
    session = RecordingSession()
    _install(monkeypatch, session)
    with pytest.raises(WorkflowHeld, match='MODEL_RECEIPT_OUTCOME_INVALID'):
        _ledger().finish(1, 'bogus', None)
    assert session.calls == []


# -- DD-055: the receipt records which model answered -----------------------

def _receipt_insert(session):
    rows = [(sql, p) for sql, p in session.inserts
            if 'attempt_receipts' in sql]
    assert len(rows) == 1, rows
    return rows[0]


def test_finish_records_model_and_status_when_supplied(monkeypatch):
    """The two existing receipt columns must actually be written (DD-055)."""
    session = RecordingSession()
    _install(monkeypatch, session)
    _ledger().finish(1, 'rejected', None,
                     model_returned='deepseek-v4.1-flash-1017',
                     provider_response_status=200)
    sql, params = _receipt_insert(session)
    assert 'model_returned' in sql and 'provider_response_status' in sql
    assert params['model'] == 'deepseek-v4.1-flash-1017'
    assert params['status'] == 200


def test_finish_without_metadata_still_writes_nulls(monkeypatch):
    """Three-argument callers keep working and record "not recorded"."""
    session = RecordingSession()
    _install(monkeypatch, session)
    _ledger().finish(1, 'returned', _HEX)
    _, params = _receipt_insert(session)
    assert params['model'] is None and params['status'] is None


@pytest.mark.parametrize('bad', [0, 99, 600, -1, True, '200', 200.0, object()])
def test_implausible_status_is_not_stored(monkeypatch, bad):
    session = RecordingSession()
    _install(monkeypatch, session)
    _ledger().finish(1, 'rejected', None, provider_response_status=bad)
    _, params = _receipt_insert(session)
    assert params['status'] is None


@pytest.mark.parametrize('bad', ['x' * 129, 123, object()])
def test_implausible_model_label_is_not_stored(monkeypatch, bad):
    session = RecordingSession()
    _install(monkeypatch, session)
    _ledger().finish(1, 'rejected', None, model_returned=bad)
    _, params = _receipt_insert(session)
    assert params['model'] is None
