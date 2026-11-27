"""M2V1 proposal tests; no ruleset or cloud execution is adopted here."""
import importlib.util
from pathlib import Path

import pytest

from sitewise.core.exceptions import ConflictError
from sitewise.project1.bdj import BDJEngine, RULE_MODULES
from sitewise.project1.contracts import digest
from sitewise.project1.projection import verify_projection


def packet(key='M2V1-11', value='UNSURE'):
    data = {
        'schema_version': 'project1-m2-projection/1-candidate',
        'instrument_version': 'M2V1-20261114-1',
        'assessment_id': '00000000-0000-4000-8000-000000000001',
        'assessment_revision': 1, 'confirmed': True,
        'declarations': [{'item_key': key, 'answer_state': 'ANSWERED',
                          'value': value, 'answer_revision_id': 'answer-1',
                          'item_version_id': 'item-1'}],
    }
    return {**data, 'source_fingerprint': digest(data)}


def proposed_rules():
    path = Path(__file__).resolve().parents[2] / 'tools/cp13_verification/v2/bdj_m2v1_information_gap_proposal.py'
    spec = importlib.util.spec_from_file_location('private_m2v1_proposal', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_current_source_refuses_legacy_answer_keys():
    with pytest.raises(ConflictError, match='unsupported item'):
        verify_projection(packet('M2-04', 'legacy'))


def test_information_gap_proposal_reuses_engine_without_adoption():
    rules = proposed_rules()
    assert rules.ADOPTED is False
    # This used to assert ``rules.RULE_VERSION not in RULE_MODULES``, i.e. "the
    # version string is not adopted". That premise stopped being true on
    # 2026-11-21, when ``BDJ-M2V1-IG-0.1-PROP`` was adopted — but as a *different
    # file* (``sitewise.project1.rules.bdj_m2v1_ig_proposal``). Two artefacts now
    # share one version string, so the version alone no longer identifies which
    # one the registry resolves. The claim this test needs is about the artefact:
    # the CP13 proposal module is not the registered implementation.
    assert RULE_MODULES.get(rules.RULE_VERSION) != rules.__name__, (
        'the registry resolves this version to the CP13 proposal artefact '
        'itself; it must resolve to the adopted module of the same name')
    source = packet()
    result = BDJEngine(rules).review(source, recheck_current=lambda: source['source_fingerprint'])
    assert result['outcome'] == 'reviewed'
    assert len(result['findings']) == 1
    assert result['findings'][0]['kind'] == 'INFORMATION_GAP'
    assert result['findings'][0]['source_refs'][0]['quote'] == 'UNSURE'
    assert result['fielding_authorized'] is False


def test_empty_findings_remain_valid_for_test_proposal():
    rules = proposed_rules()
    source = packet(value='EXPLORE')
    result = BDJEngine(rules).review(source, recheck_current=lambda: source['source_fingerprint'])
    assert result['outcome'] == 'reviewed'
    assert result['findings'] == []


@pytest.mark.parametrize('name', ['sitewise.domain.bdj_rules', 'sitewise.domain.bdj_candidate_rules'])
def test_legacy_rules_hold_m2v1_without_calling_model(name):
    import importlib
    source = packet()
    calls = []
    result = BDJEngine(importlib.import_module(name), lambda *args: calls.append(args)).review(
        source, recheck_current=lambda: source['source_fingerprint'])
    assert result['outcome'] == 'held'
    assert result['findings'] == []
    assert any(event.get('reason') == 'BDJ_M2V1_RULESET_ADOPTION_REQUIRED'
               for event in result['checkpoints'])
    assert not calls
