"""Offline fail-closed tests for the live QG runner. No DB, no socket, no budget spend."""
from __future__ import annotations

import json
from uuid import uuid4

import pytest

from sitewise.project1 import qg_live
from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.disclosure import QG_PURPOSE, QG_SCHEMA_VERSION
from sitewise.project1.qg_contract import QGCandidate

SOURCE = 'a' * 64
AUTH = {
    'purpose': QG_PURPOSE,
    'source_fingerprint': SOURCE,
    'assessment_id': '22222222-2222-4222-8222-222222222222',
    'actor_id': '11111111-1111-4111-8111-111111111111',
    'operator_receipt': 'OFFLINE-TEST-RECEIPT',
    'max_attempts': 1,
}
PACKET = {'schema_version': QG_SCHEMA_VERSION, 'source_fingerprint': SOURCE}


def refusal(runner, stage='QG', packet=None, prompt_key='QG_PROPOSAL'):
    try:
        runner(stage, packet if packet is not None else PACKET, QGCandidate,
               prompt_key=prompt_key)
    except WorkflowHeld as exc:
        return str(exc)
    return None


class NoCallProvider:
    def __init__(self):
        self.calls = 0

    def complete(self, *args, **kwargs):
        self.calls += 1
        raise AssertionError('provider must not be called on a refusal')


def _runner(tmp_path, **overrides):
    payload = {**AUTH, **overrides}
    path = tmp_path / 'authorization.json'
    path.write_text(json.dumps(payload), encoding='utf-8')
    provider = NoCallProvider()
    runner = qg_live.QgLiveRunner(engine=object(), authorization=payload,
                                  provider=provider, budget_path=tmp_path / 'budget.json')
    return runner, provider


def test_missing_authorization_fails_closed(tmp_path):
    runner = qg_live.QgLiveRunner(engine=object(),
                                  authorization_path=tmp_path / 'absent.json')
    assert refusal(runner) == 'QG_LIVE_AUTHORIZATION_MISSING'


def test_invalid_purpose_fails_at_load(tmp_path):
    path = tmp_path / 'bad.json'
    path.write_text(json.dumps({**AUTH, 'purpose': 'MARKETING'}), encoding='utf-8')
    with pytest.raises(WorkflowHeld, match='QG_LIVE_AUTHORIZATION_INVALID'):
        qg_live.load_authorization(path)


def test_missing_engine_fails_before_anything_else(tmp_path):
    runner = qg_live.QgLiveRunner(engine=None, authorization=AUTH)
    assert refusal(runner) == 'WORKFLOW_STORAGE_UNAVAILABLE'


def test_bdj_stage_is_refused(tmp_path):
    runner, provider = _runner(tmp_path)
    assert refusal(runner, stage='BDJ') == 'DISCLOSURE_STAGE_NOT_AUTHORIZED'
    assert provider.calls == 0


def test_other_prompt_key_is_refused(tmp_path):
    runner, provider = _runner(tmp_path)
    assert refusal(runner, prompt_key='BDJ') == 'PROVIDER_PROMPT_NOT_AUTHORIZED'
    assert provider.calls == 0


def test_other_packet_schema_is_refused(tmp_path):
    runner, provider = _runner(tmp_path)
    packet = {**PACKET, 'schema_version': 'project1-m2-projection/1-candidate'}
    assert refusal(runner, packet=packet) == 'DISCLOSURE_SOURCE_CLASS_INVALID'
    assert provider.calls == 0


def test_a_changed_fact_is_refused_before_provisioning(tmp_path, monkeypatch):
    runner, provider = _runner(tmp_path)
    called = []

    def forbidden(*args, **kwargs):
        called.append(True)
        return uuid4()

    monkeypatch.setattr(qg_live, 'ensure_qg_run', forbidden)
    assert refusal(runner, packet={**PACKET, 'source_fingerprint': '0' * 64}) == \
        'DISCLOSURE_SOURCE_MISMATCH'
    assert not called
    assert provider.calls == 0


def test_a_second_dispatch_does_not_consume_a_global_slot(tmp_path, monkeypatch):
    runner, provider = _runner(tmp_path)
    monkeypatch.setattr(qg_live, 'ensure_qg_run', lambda *a, **k: uuid4())
    monkeypatch.setattr(qg_live, 'attempt_count', lambda *a, **k: 1)
    reserved = []
    monkeypatch.setattr(qg_live.budget, 'reserve', lambda *a, **k: reserved.append(a))
    assert refusal(runner) == 'MODEL_ATTEMPT_BUDGET_EXHAUSTED'
    assert not reserved
    assert provider.calls == 0


# --------------------------------------------------------------------------
# N04-C §4A — the fixed-option prompt is authorised, and only it may be bound
# --------------------------------------------------------------------------
def test_the_fixed_option_prompt_is_an_authorised_key():
    """Owner-authorised 2026-11-23; the key gate must admit it."""
    assert 'QG_FIXED_OPTION' in qg_live.AUTHORIZED_PROMPT_KEYS
    assert 'QG_PROPOSAL' in qg_live.AUTHORIZED_PROMPT_KEYS


def test_a_matching_bound_prompt_passes_the_gate(tmp_path, monkeypatch):
    """Proves the gate admits the fixed-option key and both bindings agree.

    The stop is the attempt ceiling, which is reached only after the prompt key,
    the bound version and the bound hash have all been accepted — and still
    before any budget slot or socket.
    """
    monkeypatch.setattr(qg_live, 'ensure_qg_run', lambda *a, **k: uuid4())
    monkeypatch.setattr(qg_live, 'attempt_count', lambda *a, **k: 99)
    prompt = qg_live.PROMPTS['QG_FIXED_OPTION']
    runner, provider = _runner(tmp_path, prompt_version=prompt.version,
                               prompt_sha256=prompt.fingerprint)
    assert refusal(runner, prompt_key='QG_FIXED_OPTION') == \
        'MODEL_ATTEMPT_BUDGET_EXHAUSTED'
    assert provider.calls == 0


def test_a_bound_prompt_version_that_does_not_match_is_refused(tmp_path):
    """Authorising one prompt and dispatching another must fail closed."""
    runner, provider = _runner(tmp_path, prompt_version='QG-PROPOSE-6-CAND')
    assert refusal(runner, prompt_key='QG_FIXED_OPTION') == \
        'QG_LIVE_PROMPT_VERSION_MISMATCH'
    assert provider.calls == 0


def test_a_bound_prompt_hash_that_does_not_match_is_refused(tmp_path):
    runner, provider = _runner(tmp_path, prompt_sha256='0' * 64)
    assert refusal(runner, prompt_key='QG_FIXED_OPTION') == \
        'QG_LIVE_PROMPT_HASH_MISMATCH'
    assert provider.calls == 0


def test_an_absent_prompt_binding_leaves_the_key_free(tmp_path, monkeypatch):
    """An artifact that binds no prompt does not accidentally bind one."""
    monkeypatch.setattr(qg_live, 'ensure_qg_run', lambda *a, **k: uuid4())
    monkeypatch.setattr(qg_live, 'attempt_count', lambda *a, **k: 99)
    runner, _ = _runner(tmp_path)
    assert refusal(runner, prompt_key='QG_FIXED_OPTION') == \
        'MODEL_ATTEMPT_BUDGET_EXHAUSTED'


def test_an_unnamed_key_dispatches_the_adopted_pathway(tmp_path, monkeypatch):
    """An unnamed dispatch uses the fixed-option prompt, not the held one.

    The default was ``QG_PROPOSAL`` while the proposal prompt was the only
    authorised key. It is now the fixed-option prompt, because the only consumer
    of a QG answer on this runner is ``validate_fixed_candidate`` and a
    proposal-shaped answer cannot satisfy it: the attempt is reserved and the
    dispatch billed before the refusal. The key is asserted where it is actually
    chosen — the run provisioning call — rather than inferred from a refusal
    code, so a future default cannot drift unnoticed.
    """
    seen: list[str] = []

    def capture(*_a, **kwargs):
        seen.append(kwargs.get('prompt_key'))
        return uuid4()

    monkeypatch.setattr(qg_live, 'ensure_qg_run', capture)
    monkeypatch.setattr(qg_live, 'attempt_count', lambda *a, **k: 99)
    runner, _ = _runner(tmp_path)

    assert qg_live.DEFAULT_PROMPT_KEY == 'QG_FIXED_OPTION'
    assert refusal(runner, prompt_key=None) == 'MODEL_ATTEMPT_BUDGET_EXHAUSTED'
    assert seen == ['QG_FIXED_OPTION'], seen

    # The held key is still dispatchable when it is named, so the legacy
    # evaluation service can be re-enabled by a separately authorised act.
    assert refusal(runner, prompt_key='QG_PROPOSAL') == \
        'MODEL_ATTEMPT_BUDGET_EXHAUSTED'
    assert seen == ['QG_FIXED_OPTION', 'QG_PROPOSAL'], seen


def test_a_consumed_unknown_outcome_is_not_retried(tmp_path, monkeypatch):
    """Run fc290198 spent its single slot and never learned the outcome.

    Re-dispatching it would be a second POST for an attempt whose first POST may
    already have reached the provider. The authorization permits one attempt, so
    the refusal must happen before the budget is reserved or a socket is opened.
    """
    monkeypatch.setattr(qg_live, 'ensure_qg_run', lambda *a, **k: uuid4())
    monkeypatch.setattr(qg_live, 'attempt_count', lambda *a, **k: 1)
    runner, provider = _runner(tmp_path, max_attempts=1)
    assert refusal(runner) == 'MODEL_ATTEMPT_BUDGET_EXHAUSTED'
    assert provider.calls == 0
