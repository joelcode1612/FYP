"""Non-network contract checks for the unadopted synthetic BDJ trial."""
from copy import deepcopy
import json
from pathlib import Path

import pytest

from sitewise.core.exceptions import ConflictError
from sitewise.project1.bdj_discovery_candidate import validate_information_gap_trial_v101
from sitewise.project1.contracts import WorkflowHeld, digest
from test_bdj_discovery_candidate import candidate, sample as base_sample


def test_owner_selected_artifact_is_accepted_only_by_synthetic_trial():
    import importlib.util
    from sitewise.project1.bdj import BDJEngine, RULE_MODULES, SYNTHETIC_M2V1_RULESET
    path = Path(__file__).resolve().parents[2] / 'tools/cp13_verification/v2/bdj_m2v1_information_gap_proposal.py'
    spec = importlib.util.spec_from_file_location('owner_selected_trial_rules', path)
    rules = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rules)
    packet, items = sample({'M2V1-02': 'UNDECIDED', 'M2V1-08': ['UNKNOWN']})
    packet['data_class'] = 'SYNTHETIC_NONHUMAN'
    packet['source_fingerprint'] = digest({k: v for k, v in packet.items() if k != 'source_fingerprint'})
    model_packet, triggered = BDJEngine(rules).prepare_discovery_trial(
        packet, item_definitions=items, recheck_current=lambda: packet['source_fingerprint'])
    assert SYNTHETIC_M2V1_RULESET not in RULE_MODULES
    assert triggered == {'M2V1_EXPLICIT_PLANNING_UNDECIDED', 'M2V1_EVIDENCE_INVENTORY_UNKNOWN'}
    assert {row['rule_id'] for row in model_packet['rule_catalogue']} == triggered


def test_owner_selected_artifact_wrong_bytes_are_refused(tmp_path):
    from types import SimpleNamespace
    from sitewise.project1.bdj import BDJEngine, SYNTHETIC_M2V1_RULESET
    artifact = tmp_path / 'wrong_rules.py'
    artifact.write_text('different', encoding='utf-8')
    packet, items = sample({'M2V1-02': 'UNDECIDED'})
    packet['data_class'] = 'SYNTHETIC_NONHUMAN'
    rules = SimpleNamespace(RULE_VERSION=SYNTHETIC_M2V1_RULESET, __file__=str(artifact))
    with pytest.raises(WorkflowHeld, match='BDJ_TRIAL_RULE_ARTIFACT_MISMATCH'):
        BDJEngine(rules).prepare_discovery_trial(packet, item_definitions=items,
                                                  recheck_current=lambda: packet['source_fingerprint'])


def test_approved_rule_does_not_admit_excluded_item_when_another_item_triggered():
    import importlib.util
    from sitewise.project1.bdj import BDJEngine
    path = Path(__file__).resolve().parents[2] / 'tools/cp13_verification/v2/bdj_m2v1_information_gap_proposal.py'
    spec = importlib.util.spec_from_file_location('scope_recheck_rules', path)
    rules = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rules)
    packet, items = sample({'M2V1-02':'UNDECIDED', 'M2V1-07':'UNDECIDED'})
    packet['data_class'] = 'SYNTHETIC_NONHUMAN'
    packet['source_fingerprint'] = digest({k:v for k,v in packet.items() if k != 'source_fingerprint'})
    raw = candidate(packet, 'EXPLICIT_UNCERTAINTY', ['M2V1-07'])
    raw['issues'][0]['rule_id'] = 'M2V1_EXPLICIT_PLANNING_UNDECIDED'
    with pytest.raises(WorkflowHeld, match='BDJ_TRIAL_RULE_SOURCE_NOT_TRIGGERED'):
        BDJEngine(rules, lambda *args: raw).review_discovery_trial(
            packet, item_definitions=items, recheck_current=lambda:packet['source_fingerprint'])


@pytest.mark.parametrize(('key', 'value', 'expected'), [
    ('M2V1-01', 'UNDECIDED', 'M2V1_EXPLICIT_PLANNING_UNDECIDED'),
    ('M2V1-08', ['UNKNOWN'], 'M2V1_EVIDENCE_INVENTORY_UNKNOWN'),
    ('M2V1-11', 'UNSURE', 'M2V1_RESEARCH_PURPOSE_UNSURE'),
])
def test_owner_selected_artifact_three_literal_triggers(key, value, expected):
    import importlib.util
    path = Path(__file__).resolve().parents[2] / 'tools/cp13_verification/v2/bdj_m2v1_information_gap_proposal.py'
    spec = importlib.util.spec_from_file_location('synthetic_baseline_rules', path)
    rules = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rules)
    findings = rules.evaluate_candidate_issues({key: {'id': 'synthetic-revision',
        'answer_state': 'ANSWERED', 'value_json': value}})
    assert [row['rule_id'] for row in findings] == [expected]
    assert findings[0]['issue_type'] == 'INFORMATION_GAP'
    assert findings[0]['source_answer_ids'] == ['synthetic-revision']
    assert rules.evaluate_candidate_issues({key: {'id':'synthetic-revision',
        'answer_state':'SKIPPED_OPTIONAL', 'value_json':None}}) == []
    for excluded in ('M2V1-05', 'M2V1-07'):
        assert rules.evaluate_candidate_issues({excluded: {'id':'synthetic-revision',
            'answer_state':'ANSWERED', 'value_json':'UNDECIDED'}}) == []


def sample(values):
    packet, items = base_sample(values)
    packet['confirmation'] = {'confirmation_id': 'synthetic-confirmation', 'snapshot_digest': 'a' * 64}
    packet['source_fingerprint'] = digest({k:v for k,v in packet.items() if k != 'source_fingerprint'})
    return packet, items


def run(raw, packet, items, fingerprint=None):
    return validate_information_gap_trial_v101(raw, packet, items,
        current_source_fingerprint=packet['source_fingerprint'] if fingerprint is None else fingerprint)


@pytest.mark.parametrize(('key', 'value', 'rule', 'signal'), [
    ('M2V1-02', 'UNDECIDED', 'M2V1_EXPLICIT_PLANNING_UNDECIDED', 'EXPLICIT_UNCERTAINTY'),
    ('M2V1-08', ['UNKNOWN'], 'M2V1_EVIDENCE_INVENTORY_UNKNOWN', 'EVIDENCE_LIMITATION'),
    ('M2V1-11', 'UNSURE', 'M2V1_RESEARCH_PURPOSE_UNSURE', 'EXPLICIT_UNCERTAINTY'),
    ('M2V1-11', 'UNDECIDED', 'M2V1_RESEARCH_PURPOSE_UNSURE', 'EXPLICIT_UNCERTAINTY'),
])
def test_valid_rules(key, value, rule, signal):
    values = {'M2V1-09': ['CONCEPT_INTEREST'], 'M2V1-10': 'CONCEPT_INTEREST'} if key == 'M2V1-11' else {}
    values[key] = value
    packet, items = sample(values)
    raw = candidate(packet, signal, [key]); raw['issues'][0]['rule_id'] = rule
    assert run(raw, packet, items).issues[0].rule_id == rule


@pytest.mark.parametrize('kind', ['SOURCE_CONFLICT', 'UNSUPPORTED_ASSERTION'])
def test_rejects_other_finding_kinds(kind):
    packet, items = sample({'M2V1-08': ['UNKNOWN']})
    raw = candidate(packet, 'EVIDENCE_LIMITATION', ['M2V1-08'])
    raw['issues'][0].update(rule_id='M2V1_EVIDENCE_INVENTORY_UNKNOWN', kind=kind)
    with pytest.raises(WorkflowHeld): run(raw, packet, items)


@pytest.mark.parametrize('signal', ['INFORMATION_INTEREST', 'EXPLICIT_UNCERTAINTY',
    'DECLARED_ASSUMPTION', 'POTENTIAL_INCONSISTENCY', 'DECISION_NEED'])
def test_rejects_wrong_signal(signal):
    packet, items = sample({'M2V1-08': ['UNKNOWN']})
    raw = candidate(packet, signal, ['M2V1-08']); raw['issues'][0]['rule_id'] = 'M2V1_EVIDENCE_INVENTORY_UNKNOWN'
    with pytest.raises(WorkflowHeld): run(raw, packet, items)


def test_rule_source_and_exact_quote_enforced():
    packet, items = sample({'M2V1-08': ['UNKNOWN']})
    raw = candidate(packet, 'EVIDENCE_LIMITATION', ['M2V1-08'])
    raw['issues'][0]['rule_id'] = 'M2V1_EVIDENCE_INVENTORY_UNKNOWN'
    for field, bad in [('quote', 'UNKNOWN EXTRA'), ('quote', 'KNOWN'),
                       ('answer_revision_id', 'different'), ('item_version_id', 'different'),
                       ('item_key', 'M2V1-02')]:
        broken = deepcopy(raw); broken['issues'][0]['source_refs'][0][field] = bad
        with pytest.raises(WorkflowHeld): run(broken, packet, items)


def test_rejects_missing_stale_unconfirmed_and_invalid_values():
    packet, items = sample({'M2V1-08': ['UNKNOWN']})
    raw = candidate(packet, 'EVIDENCE_LIMITATION', ['M2V1-08'])
    raw['issues'][0]['rule_id'] = 'M2V1_EVIDENCE_INVENTORY_UNKNOWN'
    with pytest.raises(WorkflowHeld): run(raw, packet, items, fingerprint='stale')
    missing = deepcopy(packet); missing.pop('confirmation')
    missing['source_fingerprint'] = digest({k:v for k,v in missing.items() if k != 'source_fingerprint'})
    with pytest.raises(WorkflowHeld): run(raw, missing, items)
    altered = deepcopy(packet); altered['confirmed'] = False
    altered['source_fingerprint'] = digest({k:v for k,v in altered.items() if k != 'source_fingerprint'})
    with pytest.raises(WorkflowHeld): run(raw, altered, items)
    altered = deepcopy(packet); altered['declarations'][0]['value'] = ['NOT_A_CODE']
    altered['source_fingerprint'] = digest({k:v for k,v in altered.items() if k != 'source_fingerprint'})
    with pytest.raises(WorkflowHeld): run(raw, altered, items)
    altered = deepcopy(packet); altered['declarations'][0]['answer_revision_id'] = ''
    altered['source_fingerprint'] = digest({k:v for k,v in altered.items() if k != 'source_fingerprint'})
    with pytest.raises(WorkflowHeld): run(raw, altered, items)


def test_empty_and_multiple_issues():
    packet, items = sample({'M2V1-02': 'UNDECIDED', 'M2V1-08': ['UNKNOWN']})
    first = candidate(packet, 'EXPLICIT_UNCERTAINTY', ['M2V1-02'])
    first['issues'][0]['rule_id'] = 'M2V1_EXPLICIT_PLANNING_UNDECIDED'
    second = candidate(packet, 'EVIDENCE_LIMITATION', ['M2V1-08'])
    second['issues'][0]['rule_id'] = 'M2V1_EVIDENCE_INVENTORY_UNKNOWN'
    assert len(run({'contract_version': first['contract_version'], 'overall_note': 'none', 'issues': []}, packet, items).issues) == 0
    first['issues'].extend(second['issues'])
    assert len(run(first, packet, items).issues) == 2


@pytest.mark.parametrize('key', [f'M2V1-{n:02d}' for n in range(1, 8)])
def test_each_planning_rule_against_registered_codebook(key):
    from sitewise.project1.projection import M2V1_VERSION
    codebook = json.loads((Path(__file__).resolve().parents[2] /
        'src/sitewise/instruments/m2v1_20261114/definition.json').read_text(encoding='utf-8'))
    definitions = {row['item_key']: row for row in codebook['items']}
    chosen = {key: ['UNDECIDED'] if key in {'M2V1-03', 'M2V1-04'} else 'UNDECIDED'}
    if key == 'M2V1-05': chosen['M2V1-04'] = ['STUDENTS']
    if key == 'M2V1-07': chosen['M2V1-02'] = 'HYBRID'
    items, declarations = [], []
    for item_key, value in chosen.items():
        definition = deepcopy(definitions[item_key])
        definition.update(id='item-' + item_key, instrument_id='synthetic-instrument')
        items.append(definition)
        declarations.append({'item_key': item_key, 'item_version_id': definition['id'],
            'answer_revision_id': 'answer-' + item_key, 'definition_digest': digest(definition),
            'answer_state': 'ANSWERED', 'value': value})
    packet = {'instrument_id':'synthetic-instrument', 'instrument_version':M2V1_VERSION,
              'confirmed':True, 'declarations':declarations,
              'confirmation': {'confirmation_id':'synthetic-confirmation', 'snapshot_digest':'a' * 64}}
    packet['source_fingerprint'] = digest(packet)
    raw = candidate(packet, 'EXPLICIT_UNCERTAINTY', [key])
    raw['issues'][0]['rule_id'] = 'M2V1_EXPLICIT_PLANNING_UNDECIDED'
    assert run(raw, packet, items).issues


@pytest.mark.parametrize(('rule','key','value','correct'), [
    ('M2V1_EXPLICIT_PLANNING_UNDECIDED','M2V1-02','UNDECIDED','EXPLICIT_UNCERTAINTY'),
    ('M2V1_EVIDENCE_INVENTORY_UNKNOWN','M2V1-08',['UNKNOWN'],'EVIDENCE_LIMITATION'),
    ('M2V1_RESEARCH_PURPOSE_UNSURE','M2V1-11','UNSURE','EXPLICIT_UNCERTAINTY'),
])
@pytest.mark.parametrize('signal', ['INFORMATION_INTEREST','EXPLICIT_UNCERTAINTY',
    'DECLARED_ASSUMPTION','EVIDENCE_LIMITATION','POTENTIAL_INCONSISTENCY','DECISION_NEED'])
@pytest.mark.parametrize('kind', ['INFORMATION_GAP','SOURCE_CONFLICT','UNSUPPORTED_ASSERTION'])
def test_exhaustive_rule_kind_signal_matrix(rule,key,value,correct,signal,kind):
    values = {'M2V1-09':['CONCEPT_INTEREST'], 'M2V1-10':'CONCEPT_INTEREST'} if key == 'M2V1-11' else {}
    values[key] = value
    packet, items = sample(values)
    raw = candidate(packet, signal, [key]); raw['issues'][0].update(rule_id=rule, kind=kind)
    if kind == 'INFORMATION_GAP' and signal == correct:
        assert run(raw, packet, items).issues
    else:
        with pytest.raises(WorkflowHeld): run(raw, packet, items)


def test_trial_engine_holds_before_dispatch_on_stale_or_unmarked_source():
    from types import SimpleNamespace
    from sitewise.project1.bdj import BDJEngine
    packet, items = sample({'M2V1-08':['UNKNOWN']})
    rules = SimpleNamespace(RULE_VERSION='BDJ-M2V1-IG-TEST-1.0.1')
    calls = []
    engine = BDJEngine(rules, lambda *args: calls.append(args))
    with pytest.raises(WorkflowHeld, match='BDJ_TRIAL_SCOPE_REQUIRED'):
        engine.review_discovery_trial(packet, item_definitions=items, recheck_current=lambda:packet['source_fingerprint'])
    packet['data_class'] = 'SYNTHETIC_NONHUMAN'
    packet['source_fingerprint'] = digest({k:v for k,v in packet.items() if k != 'source_fingerprint'})
    with pytest.raises(WorkflowHeld, match='BDJ_TRIAL_CONFIRMATION_SOURCE_MISMATCH'):
        engine.review_discovery_trial(packet, item_definitions=items, recheck_current=lambda:'stale')
    assert calls == []
