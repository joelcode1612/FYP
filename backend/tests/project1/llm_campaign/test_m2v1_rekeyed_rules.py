"""Evidence and retirement record for BDJ-RULESET-0.3-M2V1-CAND.

The ruleset was authored on 2026-11-17 to re-key the 0.2 catalogue onto M2V1
item keys, and retired the same day before any provider call when the Owner
re-affirmed D02 ("M2V1 BDJ is contradiction-free by design").

The firing tests are kept on purpose, mirroring ``test_bdj_m2v1_rules.py``: they
prove the rule *would* fire, which is what makes the retirement a decision
rather than an omission. The retirement tests prove it cannot be activated.
"""
from __future__ import annotations

import hashlib
from pathlib import Path

import pytest

from sitewise.domain import bdj_candidate_rules as legacy
from sitewise.domain import bdj_candidate_rules_m2v1 as retired
from sitewise.project1.bdj import BDJEngine, load_rules, validate_candidates
from sitewise.project1.contracts import WorkflowHeld

from campaign import authorization, build_case, expected_item_keys

LEGACY_SHA256 = '42f7fef3bf2bb48255ab8eac406dfb8232923b76789dd065d693732e8bf2a061'
CONFLICT = 'SERVICE_FORMAT_EXPLICIT_CONFLICT'


def as_answers(packet: dict) -> dict:
    return {d['item_key']: {'id': d['answer_revision_id'],
                            'answer_state': d['answer_state'],
                            'value_json': d['value']}
            for d in packet['declarations']}


def pairs(service, occasion):
    return {'M2V1-02': {'id': 'a', 'answer_state': 'ANSWERED', 'value_json': service},
            'M2V1-07': {'id': 'b', 'answer_state': 'ANSWERED', 'value_json': occasion}}


# --- the considered mapping, preserved -------------------------------------
def test_catalogue_is_the_legacy_catalogue_rekeyed():
    old = {row['rule_id']: row for row in legacy.RULE_CATALOGUE}
    new = {row['rule_id']: row for row in retired.RULE_CATALOGUE}
    assert set(old) == set(new), 'a rule was added or removed'
    for rule_id, row in old.items():
        assert new[rule_id]['class'] == row['class'], rule_id
        assert new[rule_id]['status'] == row['status'], rule_id
        assert new[rule_id]['mapping_basis'], rule_id


def test_every_mapped_key_exists_in_the_registered_instrument():
    known = set(expected_item_keys())
    for row in retired.RULE_CATALOGUE:
        assert set(row['source_keys']) <= known, row['rule_id']


# --- it would have fired (evidence, not activation) -------------------------
def test_the_rejected_rule_would_fire_on_takeaway_and_study_work():
    proposals = retired.evaluate_candidate_issues(pairs('TAKEAWAY', 'STUDY_WORK'))
    assert [p['rule_id'] for p in proposals] == [CONFLICT]
    assert proposals[0]['issue_type'] == 'POTENTIAL_DECLARATION_CONFLICT'
    assert len(proposals[0]['source_answer_ids']) == 2


@pytest.mark.parametrize('service,occasion', [
    ('DELIVERY', 'STUDY_WORK'), ('TAKEAWAY', 'SOCIAL'), ('TAKEAWAY', 'LEISURE'),
    ('TAKEAWAY', 'QUICK_PURCHASE'), ('TAKEAWAY', 'MEAL_SNACK'),
    ('DINE_IN', 'STUDY_WORK'), ('HYBRID', 'STUDY_WORK'), ('TAKEAWAY', 'UNDECIDED')])
def test_it_abstained_outside_its_narrow_trigger(service, occasion):
    assert retired.evaluate_candidate_issues(pairs(service, occasion)) == []


def test_it_would_have_survived_full_admission():
    """Evidence that the rejection was a decision, not a validation failure."""
    case = build_case('contradictory')
    by_key = {d['item_key']: d for d in case.packet['declarations']}
    refs = [{'item_key': key,
             'answer_revision_id': by_key[key]['answer_revision_id'],
             'item_version_id': by_key[key]['item_version_id'],
             'quote': by_key[key]['value']} for key in ('M2V1-02', 'M2V1-07')]
    raw = {'issues': [{'rule_id': CONFLICT, 'kind': 'SOURCE_CONFLICT',
                       'source_refs': refs, 'observed_condition': 'x',
                       'counterargument': 'x', 'justification': 'x',
                       'next_action': 'x'}],
           'overall_note': 'Synthetic evidence only.'}
    result = BDJEngine(rules=retired, model_runner=lambda s, p, t: raw).review(
        case.packet, recheck_current=lambda: case.packet['source_fingerprint'])
    assert result['outcome'] == 'reviewed'
    assert [f['rule_id'] for f in result['findings']] == [CONFLICT]


# --- retirement (D02 re-affirmed) ------------------------------------------
def test_retired_ruleset_is_not_registered():
    from sitewise.project1.bdj import RULE_MODULES

    assert retired.RULE_VERSION not in RULE_MODULES
    assert set(RULE_MODULES) == {'BDJ-EXPLICIT-FORMAT-0.1-CANDIDATE',
                                 'BDJ-RULESET-0.2-CAND'}


def test_adoption_receipt_cannot_revive_the_retired_ruleset():
    """A correct sha256 plus a valid test receipt is still refused."""
    real_sha = hashlib.sha256(Path(retired.__file__).read_bytes()).hexdigest()
    with pytest.raises(WorkflowHeld) as exc:
        load_rules(retired.RULE_VERSION, real_sha,
                   authorization()['adoption_receipt'])
    assert 'BDJ_RULE_ADOPTION_REQUIRED' in str(exc.value)


def test_retirement_status_is_recorded_in_the_module():
    assert retired.ADOPTED is False
    assert retired.STATUS == 'RETIRED_NOT_ADOPTED'
    assert retired.RULE_VERSION == 'BDJ-RULESET-0.3-M2V1-CAND'
    # The mapping record survives: twelve entries, one previously executable.
    assert len(retired.RULE_CATALOGUE) == 12
    assert [r['rule_id'] for r in retired.RULE_CATALOGUE
            if r['m2v1_coverage'] == 'IMPLEMENTED'] == [CONFLICT]


def test_empty_vocabulary_causes_bdj_rule_not_registered():
    """The closed loop: with no allowed rule, any model candidate is refused."""
    case = build_case('contradictory')
    by_key = {d['item_key']: d for d in case.packet['declarations']}
    raw = {'issues': [{'rule_id': CONFLICT, 'kind': 'SOURCE_CONFLICT',
                       'source_refs': [{'item_key': key,
                                        'answer_revision_id': by_key[key]['answer_revision_id'],
                                        'item_version_id': by_key[key]['item_version_id'],
                                        'quote': by_key[key]['value']}
                                       for key in ('M2V1-02', 'M2V1-07')],
                       'observed_condition': 'x', 'counterargument': 'x',
                       'justification': 'x', 'next_action': 'x'}],
           'overall_note': 'Synthetic retirement test.'}
    with pytest.raises(WorkflowHeld) as exc:
        validate_candidates(raw, case.packet, set())
    assert 'BDJ_RULE_NOT_REGISTERED' in str(exc.value)


def test_legacy_ruleset_remains_byte_identical_and_loadable():
    assert hashlib.sha256(Path(legacy.__file__).read_bytes()).hexdigest() == LEGACY_SHA256
    loaded = load_rules('BDJ-RULESET-0.2-CAND', LEGACY_SHA256,
                        authorization()['adoption_receipt'])
    assert loaded.RULE_VERSION == 'BDJ-RULESET-0.2-CAND'
