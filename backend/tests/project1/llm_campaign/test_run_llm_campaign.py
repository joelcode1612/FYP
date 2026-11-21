"""Guards on the campaign runner: default is dry-run, and the ceiling holds."""
from __future__ import annotations

import json

import pytest

import run_llm_campaign as runner


def test_budget_comes_from_the_authoritative_module_and_is_not_a_flag():
    """CP-03: one authority. A second constant here would drift from it."""
    from sitewise.project1 import budget

    assert runner.BUDGET == budget.AUTHORIZED_CUMULATIVE_LIMIT == 50
    with pytest.raises(SystemExit):
        runner.main(['--budget', '99'])  # argparse refuses an unknown flag


def test_the_call_after_the_limit_is_refused_before_any_transport(tmp_path):
    from sitewise.project1 import budget

    state = tmp_path / 'budget_state.json'
    # The boundary is exercised at a low ceiling so the test stays fast; the
    # ceiling can be lowered for a test but never raised past the authorized one.
    for n in range(3):
        assert budget.reserve(state, f's{n}', limit=3) == n + 1
    with pytest.raises(budget.BudgetExhausted, match='refusing to open a socket'):
        budget.reserve(state, 'overflow', limit=3)
    assert json.loads(state.read_text(encoding='utf-8'))['spent'] == 3


def test_a_caller_cannot_raise_the_ceiling_past_the_authorized_limit(tmp_path):
    from sitewise.project1 import budget

    state = tmp_path / 'budget_state.json'
    state.write_text(json.dumps({'limit': 50, 'spent': 50, 'attempts': []}),
                     encoding='utf-8')
    with pytest.raises(budget.BudgetExhausted):
        budget.reserve(state, 'greedy', limit=9999)


def test_raising_the_limit_preserves_every_historical_attempt(tmp_path):
    """CP-03: the limit is a ceiling, not a reset."""
    from sitewise.project1 import budget

    state = tmp_path / 'budget_state.json'
    state.write_text(json.dumps({'limit': 6, 'spent': 5, 'attempts': [
        {'n': n, 'scenario': f'historical-{n}'} for n in range(1, 6)]}),
        encoding='utf-8')
    assert budget.remaining(state) == 45
    budget.reserve(state, 'new')
    after = json.loads(state.read_text(encoding='utf-8'))
    assert after['spent'] == 6
    assert after['limit'] == 50
    assert [a['scenario'] for a in after['attempts']][:5] == [
        f'historical-{n}' for n in range(1, 6)]


def test_main_defaults_to_dry_run_and_spends_nothing(tmp_path, capsys):
    state = tmp_path / 'budget_state.json'
    out = tmp_path / 'runs'
    assert runner.main(['--out', str(out), '--state', str(state)]) == 0
    assert not state.exists(), 'a dry run must not consume provider budget'
    run_dir = next(out.iterdir())
    files = sorted(p.name for p in run_dir.glob('*.json'))
    assert files == ['01-consistent-BDJ.json', '02-contradictory-BDJ.json',
                     '03-missing-BDJ.json', '04-confirmed_uncertainty-BDJ.json',
                     '05-requires_clarification-BDJ.json',
                     '06-requires_clarification-QJ.json', 'ledger.json',
                     'summary.json']
    call = json.loads((run_dir / '01-consistent-BDJ.json').read_text(encoding='utf-8'))
    assert call['dry_run'] is True and call['sent'] is False
    assert call['transport'] == 'DryRunTransport'
    assert call['request']['model'] == 'mimo-v2.6-flash:free'
    assert call['request']['max_tokens'] == 4000
    assert call['request']['temperature'] == 0
    assert call['request']['response_format']['type'] == 'json_schema'
    assert call['rule_catalogue'] == []
    assert call['request']['source_item_keys'][:2] == ['M2V1-01', 'M2V1-02']
    assert 'DRY-RUN' in capsys.readouterr().out


def test_confirm_mode_refuses_when_the_provider_flag_is_off(tmp_path, monkeypatch):
    from sitewise.core.config import settings

    monkeypatch.setattr(settings, 'tokenharbor_enabled', False)
    state = tmp_path / 'budget_state.json'
    with pytest.raises(SystemExit, match='tokenharbor_enabled is False'):
        runner.main(['--confirm-calls', '--out', str(tmp_path / 'runs'),
                     '--state', str(state)])
    # The refusal happens before a slot is consumed.
    assert not state.exists()
