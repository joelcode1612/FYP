from copy import deepcopy
import pytest
from sitewise.core.exceptions import ConflictError
from pydantic import ValidationError
from sitewise.project1.bdj_discovery_candidate import (DiscoveryOutputCandidate,
    project_declared_signals, validate_supported_discovery)
from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.projection import M2V1_VERSION


def sample(values):
    codes = {'M2V1-02': ['DINE_IN', 'DELIVERY', 'UNDECIDED'],
             'M2V1-06': ['AFFORDABILITY', 'UNDECIDED'],
             'M2V1-07': ['STUDY_WORK', 'UNDECIDED'],
             'M2V1-08': ['NONE', 'UNKNOWN', 'CUSTOMER_SURVEY'],
             'M2V1-09': ['NONE', 'CONCEPT_INTEREST'],
             'M2V1-10': [], 'M2V1-11': ['UNDECIDED', 'UNSURE', 'EXPLORE']}
    items, declarations = [], []
    for key, value in values.items():
        rules = {'exclusive': ['NONE', 'UNKNOWN']} if key == 'M2V1-08' else {}
        if key == 'M2V1-10': rules = {'source_item': 'M2V1-09', 'exclude': ['NONE']}
        item = {'id': 'item-' + key, 'instrument_id': 'instrument', 'item_key': key,
                'option_values': {'options': [{'code': c} for c in codes[key]], 'rules': rules}}
        items.append(item)
        declarations.append({'item_key': key, 'item_version_id': item['id'],
            'answer_revision_id': 'answer-' + key, 'definition_digest': digest(item),
            'answer_state': 'ANSWERED', 'value': value})
    packet = {'instrument_id': 'instrument', 'instrument_version': M2V1_VERSION,
              'confirmed': True, 'declarations': declarations}
    packet['source_fingerprint'] = digest(packet)
    return packet, items


def test_valid_sources_emit_distinct_signals_without_answers():
    packet, items = sample({'M2V1-02': 'UNDECIDED', 'M2V1-08': ['NONE'],
        'M2V1-09': ['CONCEPT_INTEREST'], 'M2V1-10': 'CONCEPT_INTEREST', 'M2V1-11': 'UNSURE'})
    result = project_declared_signals(packet, items)
    by_meaning = {s['meaning']: s for s in result['signals']}
    assert {'DECLARED_UNDECIDED', 'NO_INFORMATION_DECLARED',
            'DECLARED_RESEARCH_INTEREST', 'RESEARCH_PRIORITY_AND_POSITION_ONLY'} <= set(by_meaning)
    assert by_meaning['NO_INFORMATION_DECLARED']['source_refs'][0]['item_key'] == 'M2V1-08'
    assert 'CONCEPT_INTEREST' not in str(result)
    assert not {'DECLARED_ASSUMPTION', 'POTENTIAL_INCONSISTENCY'} & {s['classification'] for s in result['signals']}


@pytest.mark.parametrize(('value','meaning'), [(['NONE'],'NO_INFORMATION_DECLARED'),
    (['UNKNOWN'],'INFORMATION_AVAILABILITY_UNKNOWN'), (['CUSTOMER_SURVEY'],'DECLARED_SOURCE_NOT_INDEPENDENTLY_VERIFIED')])
def test_evidence_declaration_states_are_distinct(value, meaning):
    packet, items = sample({'M2V1-08': value})
    assert project_declared_signals(packet, items)['signals'][0]['meaning'] == meaning


def test_zero_finding_and_no_inferred_assumption():
    packet, items = sample({'M2V1-06': 'AFFORDABILITY'})
    assert project_declared_signals(packet, items)['signals'] == []


def test_refuses_unconfirmed_tampered_and_invalid_codebook():
    packet, items = sample({'M2V1-08': ['NONE']})
    altered = deepcopy(packet); altered['declarations'][0]['value'] = ['UNKNOWN']
    with pytest.raises(ConflictError): project_declared_signals(altered, items)
    changed = deepcopy(items); changed[0]['id'] = 'foreign'
    with pytest.raises(WorkflowHeld, match='BDJ_CODEBOOK_ITEM_MISMATCH'): project_declared_signals(packet, changed)
    packet, items = sample({'M2V1-08': ['NONE', 'UNKNOWN']})
    with pytest.raises(WorkflowHeld, match='BDJ_CODEBOOK_VALUE_INVALID'): project_declared_signals(packet, items)
    packet, items = sample({'M2V1-08': ['NONE']}); packet['confirmed'] = False
    packet['source_fingerprint'] = digest({k:v for k,v in packet.items() if k != 'source_fingerprint'})
    with pytest.raises(WorkflowHeld, match='BDJ_CONFIRMED_M2V1_REQUIRED'): project_declared_signals(packet, items)


def test_rejects_unregistered_code_and_inapplicable_occasion():
    packet, items = sample({'M2V1-08': ['MADE_UP']})
    with pytest.raises(WorkflowHeld, match='BDJ_CODEBOOK_VALUE_INVALID'): project_declared_signals(packet, items)
    packet, items = sample({'M2V1-02': 'DELIVERY', 'M2V1-07': 'UNDECIDED'})
    with pytest.raises(WorkflowHeld, match='BDJ_SOURCE_NOT_APPLICABLE'): project_declared_signals(packet, items)


@pytest.mark.parametrize('signal', ['INFORMATION_INTEREST', 'EXPLICIT_UNCERTAINTY',
    'DECLARED_ASSUMPTION', 'EVIDENCE_LIMITATION', 'POTENTIAL_INCONSISTENCY', 'DECISION_NEED'])
def test_candidate_schema_recognizes_six_names_not_semantic_authority(signal):
    output = {'contract_version': 'bdj-discovery-output/1-candidate', 'overall_note': 'candidate',
        'issues': [{'rule_id': 'synthetic', 'kind': 'INFORMATION_GAP', 'discovery_signal': signal,
            'source_refs': [{'item_key': 'M2V1-06', 'answer_revision_id': 'a', 'item_version_id': 'i', 'quote': 'test'}],
            'observed_condition': 'candidate', 'counterargument': 'candidate', 'justification': 'candidate', 'next_action': 'candidate'}]}
    assert DiscoveryOutputCandidate.model_validate(output).issues[0].discovery_signal == signal
    output['issues'][0]['discovery_signal'] = 'INVENTED'
    with pytest.raises(ValidationError): DiscoveryOutputCandidate.model_validate(output)


def candidate(packet, label, keys):
    refs = []
    for row in packet['declarations']:
        if row['item_key'] in keys:
            value = row['value'][0] if isinstance(row['value'], list) else row['value']
            refs.append({'item_key': row['item_key'], 'answer_revision_id': row['answer_revision_id'],
                         'item_version_id': row['item_version_id'], 'quote': value})
    return {'contract_version': 'bdj-discovery-output/1-candidate', 'overall_note': 'synthetic',
        'issues': [{'rule_id': 'TEST-RULE', 'kind': 'INFORMATION_GAP',
            'discovery_signal': label, 'source_refs': refs, 'observed_condition': 'synthetic',
            'counterargument': 'not established', 'justification': 'synthetic', 'next_action': 'review'}]}


@pytest.mark.parametrize(('label','keys'), [
    ('INFORMATION_INTEREST', ['M2V1-09']), ('EXPLICIT_UNCERTAINTY', ['M2V1-11']),
    ('EVIDENCE_LIMITATION', ['M2V1-08']), ('DECISION_NEED', ['M2V1-10', 'M2V1-11'])])
def test_existing_bdj_validator_and_discovery_source_agree(label, keys):
    packet, items = sample({'M2V1-08': ['UNKNOWN'], 'M2V1-09': ['CONCEPT_INTEREST'],
                            'M2V1-10': 'CONCEPT_INTEREST', 'M2V1-11': 'UNSURE'})
    assert validate_supported_discovery(candidate(packet, label, keys), packet, items, {'TEST-RULE'}).issues


@pytest.mark.parametrize('label', ['DECLARED_ASSUMPTION', 'POTENTIAL_INCONSISTENCY'])
def test_abstains_without_authoritative_support_for_other_signals(label):
    packet, items = sample({'M2V1-06': 'AFFORDABILITY'})
    with pytest.raises(WorkflowHeld, match='BDJ_DISCOVERY_SOURCE_UNSUPPORTED'):
        validate_supported_discovery(candidate(packet, label, ['M2V1-06']), packet, items, {'TEST-RULE'})


def test_rejects_wrong_rule_wrong_quote_and_unlinked_classification():
    packet, items = sample({'M2V1-08': ['UNKNOWN']})
    raw = candidate(packet, 'EVIDENCE_LIMITATION', ['M2V1-08'])
    with pytest.raises(WorkflowHeld, match='BDJ_RULE_NOT_REGISTERED'):
        validate_supported_discovery(raw, packet, items, set())
    raw['issues'][0]['source_refs'][0]['quote'] = 'fabricated'
    with pytest.raises(WorkflowHeld, match='BDJ_SOURCE_QUOTE_INVALID'):
        validate_supported_discovery(raw, packet, items, {'TEST-RULE'})


def test_existing_result_adapter_does_not_yet_project_discovery_classification():
    from sitewise.project1.bdj import validate_candidates
    from sitewise.project1.result_store import _project_payload, redact_payload
    packet, items = sample({'M2V1-08': ['UNKNOWN']})
    raw = candidate(packet, 'EVIDENCE_LIMITATION', ['M2V1-08'])
    # Existing strict contract cannot accept the additive versioned field.
    with pytest.raises(ValidationError):
        validate_candidates({'issues': raw['issues'], 'overall_note': raw['overall_note']}, packet, {'TEST-RULE'})
    payload = redact_payload({'findings': raw['issues']})
    assert payload['findings'][0]['discovery_signal'] == 'EVIDENCE_LIMITATION'
    assert 'quote' not in payload['findings'][0]['source_refs'][0]
    projected, _ = _project_payload(payload)
    assert 'discovery_signal' not in projected[0]
