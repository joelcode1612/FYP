"""Pure tests for QG run provisioning (CP-08).

No database is opened. The identity helpers are exercised directly, and the
DB path is driven through a fake session that records the SQL text and bound
parameters so the binding-mismatch branch can be proved without Dss access.
The live INSERT/SELECT/commit path remains to be verified by the live script.
"""
from __future__ import annotations

from uuid import uuid4

import pytest
from sqlalchemy.exc import SQLAlchemyError

from sitewise.project1 import runs
from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.runs import (
    effective_policy_fingerprint,
    ensure_qg_run,
    qg_policy_fingerprint,
    qg_work_identity,
    work_identity_for,
)


_HEX64 = 'a' * 64
_UUID = '11111111-2222-4333-8444-555555555555'


# -- identity helpers -------------------------------------------------------

def test_qg_policy_fingerprint_is_deterministic_hex():
    first = qg_policy_fingerprint()
    assert qg_policy_fingerprint() == first
    assert len(first) == 64 and all(c in '0123456789abcdef' for c in first)


def test_qg_work_identity_is_deterministic_hex():
    policy = qg_policy_fingerprint()
    first = qg_work_identity(_UUID, _HEX64, policy)
    assert qg_work_identity(_UUID, _HEX64, policy) == first
    assert len(first) == 64 and all(c in '0123456789abcdef' for c in first)


def test_qg_identity_is_distinct_from_bdj_work_identity():
    """Same inputs must not collide with a BDJ run row."""
    policy = qg_policy_fingerprint()
    assert qg_work_identity(_UUID, _HEX64, policy) != \
        work_identity_for(_UUID, 0, policy)
    # BDJ's own policy fingerprint is a different derivation too.
    assert policy != effective_policy_fingerprint()


def test_qg_work_identity_changes_with_source_or_policy():
    policy = qg_policy_fingerprint()
    baseline = qg_work_identity(_UUID, _HEX64, policy)
    assert qg_work_identity(_UUID, 'b' * 64, policy) != baseline
    assert qg_work_identity(_UUID, _HEX64, policy[::-1]) != baseline
    assert qg_work_identity('22222222-3333-4444-8555-666666666666',
                            _HEX64, policy) != baseline


def test_evaluation_id_starts_a_new_run_without_changing_the_policy():
    """A timed-out one-attempt run is replaced by a new run, not a second QG row."""
    policy = qg_policy_fingerprint()
    default = qg_work_identity(_UUID, _HEX64, policy)
    second = qg_work_identity(_UUID, _HEX64, policy, 'CP08-EVAL-2')
    assert second != default
    assert qg_work_identity(_UUID, _HEX64, policy, 'CP08-EVAL-2') == second


def test_qg_policy_fingerprint_tracks_the_prompt_version(monkeypatch):
    """A prompt change is new work, not a reuse of an old run."""
    from sitewise.project1.prompts import Prompt

    before = qg_policy_fingerprint()
    before_identity = qg_work_identity(_UUID, _HEX64, before)
    copied = dict(runs.PROMPTS)
    prompt = copied['QG_PROPOSAL']
    copied['QG_PROPOSAL'] = Prompt(prompt.version + '-NEXT', prompt.role,
                                   prompt.instruction, prompt.examples)
    monkeypatch.setattr(runs, 'PROMPTS', copied)

    after = qg_policy_fingerprint()
    assert after != before
    assert qg_work_identity(_UUID, _HEX64, after) != before_identity


# -- input validation -------------------------------------------------------

@pytest.mark.parametrize('bad', [
    'A' * 64, 'a' * 63, 'g' * 64, 'a' * 66, 'a' * 64 + '\n', None, 123,
])
def test_bad_source_fingerprint_is_refused(bad):
    with pytest.raises(WorkflowHeld) as exc:
        ensure_qg_run(object(), uuid4(), _UUID, bad)
    assert exc.value.args[0] == 'WORKFLOW_RUN_FINGERPRINT_INVALID'


@pytest.mark.parametrize('bad', ['not-a-uuid', '', None, 123, object()])
def test_bad_assessment_id_is_refused(bad):
    with pytest.raises(WorkflowHeld) as exc:
        ensure_qg_run(object(), uuid4(), bad, _HEX64)
    assert exc.value.args[0] == 'WORKFLOW_RUN_ASSESSMENT_INVALID'


# -- fake session for the DB path ------------------------------------------

class _Row:
    def __init__(self, id, source_fingerprint, policy_fingerprint):
        self.id = id
        self.source_fingerprint = source_fingerprint
        self.policy_fingerprint = policy_fingerprint


class _Result:
    def __init__(self, row):
        self._row = row

    def one_or_none(self):
        return self._row


class _FakeSession:
    def __init__(self, row=None, sql_error=None):
        self.row = row
        self.sql_error = sql_error
        self.calls = []  # (sql, params)
        self.committed = False

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def execute(self, statement, params=None):
        sql = str(statement)
        self.calls.append((sql, params))
        if self.sql_error is not None:
            raise self.sql_error
        if sql.lstrip().upper().startswith('SELECT'):
            return _Result(self.row)
        return None

    def commit(self):
        self.committed = True


def _install_fake(monkeypatch, session):
    monkeypatch.setattr(runs, 'Session', lambda engine: session)
    scopes = []
    monkeypatch.setattr(runs, 'restricted_scope',
                        lambda s, actor: scopes.append((s, actor)))
    return scopes


def test_ensure_qg_run_success_binds_revision_zero_and_commits(monkeypatch):
    run_id = uuid4()
    actor = uuid4()
    session = _FakeSession(_Row(run_id, _HEX64, qg_policy_fingerprint()))
    scopes = _install_fake(monkeypatch, session)

    assert ensure_qg_run(object(), actor, _UUID, _HEX64) == run_id
    assert session.committed is True
    assert scopes == [(session, actor)]
    inserts = [p for sql, p in session.calls if sql.lstrip().upper().startswith('INSERT')]
    selects = [p for sql, p in session.calls if sql.lstrip().upper().startswith('SELECT')]
    assert len(inserts) == 1 and len(selects) == 1
    assert inserts[0]['revision'] == 0
    assert str(inserts[0]['assessment']) == _UUID
    assert inserts[0]['source'] == _HEX64
    assert selects[0]['work'] == qg_work_identity(_UUID, _HEX64,
                                                  qg_policy_fingerprint())


def test_ensure_qg_run_binding_mismatch_on_source_is_fail_closed(monkeypatch):
    session = _FakeSession(_Row(uuid4(), 'b' * 64, qg_policy_fingerprint()))
    _install_fake(monkeypatch, session)
    with pytest.raises(WorkflowHeld) as exc:
        ensure_qg_run(object(), uuid4(), _UUID, _HEX64)
    assert exc.value.args[0] == 'WORKFLOW_RUN_BINDING_MISMATCH'
    assert session.committed is False


def test_ensure_qg_run_binding_mismatch_on_policy_is_fail_closed(monkeypatch):
    session = _FakeSession(_Row(uuid4(), _HEX64, 'f' * 64))
    _install_fake(monkeypatch, session)
    with pytest.raises(WorkflowHeld) as exc:
        ensure_qg_run(object(), uuid4(), _UUID, _HEX64)
    assert exc.value.args[0] == 'WORKFLOW_RUN_BINDING_MISMATCH'
    assert session.committed is False


def test_ensure_qg_run_not_found(monkeypatch):
    session = _FakeSession(None)
    _install_fake(monkeypatch, session)
    with pytest.raises(WorkflowHeld) as exc:
        ensure_qg_run(object(), uuid4(), _UUID, _HEX64)
    assert exc.value.args[0] == 'WORKFLOW_RUN_NOT_FOUND'
    assert session.committed is False


def test_ensure_qg_run_maps_storage_error_and_propagates_workflow_held(monkeypatch):
    # A storage failure becomes a named hold, not a 500.
    _install_fake(monkeypatch, _FakeSession(sql_error=SQLAlchemyError('down')))
    with pytest.raises(WorkflowHeld) as exc:
        ensure_qg_run(object(), uuid4(), _UUID, _HEX64)
    assert exc.value.args[0] == 'WORKFLOW_STORAGE_UNAVAILABLE'

    # A WorkflowHeld raised by scope setup is never swallowed or remapped.
    def refuse(session, actor):
        raise WorkflowHeld('RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED')

    monkeypatch.setattr(runs, 'restricted_scope', refuse)
    with pytest.raises(WorkflowHeld) as exc:
        ensure_qg_run(object(), uuid4(), _UUID, _HEX64)
    assert exc.value.args[0] == 'RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED'
