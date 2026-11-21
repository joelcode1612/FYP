"""BDJ-RULE-COVERAGE-01: M2V1 candidate rules, structural prevention, admission.

These tests are the deterministic evidence required before any live provider call.
They prove three separate things:

  1. each M2V1 rule fires on data the instrument actually permits, and abstains otherwise;
  2. the legacy M2 contradiction classes are *structurally prevented* by
     validate_m2_answer, so implementing them would be a false claim of coverage;
  3. a correctly sourced candidate passes the FULL admission path (validate_candidates
     inside BDJEngine.review), and a question-text quote is still rejected.
"""
import pytest

from sitewise.domain import bdj_m2v1_candidate_rules as m2v1
from sitewise.domain.bdj_candidate_rules import RULE_VERSION as LEGACY_VERSION
from sitewise.domain.bdj_candidate_rules import evaluate_candidate_issues as legacy_evaluate
from sitewise.modules.decision_engine.domain.m2_rules import M2ValidationError
from sitewise.project1.bdj import BDJEngine, validate_candidates
from sitewise.project1.contracts import BDJOutput, WorkflowHeld, digest

INSTRUMENT = 'M2V1-20261114-1'

# A minimal but self-consistent M2V1 declaration set.
BASELINE = {
    'M2V1-02': 'DINE_IN',
    'M2V1-03': ['COFFEE', 'BAKED_GOODS'],
    'M2V1-04': ['STUDENTS', 'OFFICE_WORKERS'],
    'M2V1-05': 'STUDENTS',
    'M2V1-06': 'CONVENIENCE',
    'M2V1-07': 'QUICK_PURCHASE',
    'M2V1-08': ['INFORMAL_FEEDBACK'],
    'M2V1-09': ['CONCEPT_INTEREST', 'PRICE_ACCEPTABILITY'],
    'M2V1-10': 'CONCEPT_INTEREST',
    'M2V1-11': 'VALIDATE_CHOICE',
}


def make_packet(values: dict) -> dict:
    declarations = [{
        'item_key': key, 'answer_state': 'ANSWERED', 'value': value,
        'answer_revision_id': f'rev-{key}', 'item_version_id': f'ver-{key}',
        'question': f'Question for {key}',
    } for key, value in sorted(values.items())]
    body = {'schema_version': 'project1-m2-projection/1-candidate',
            'instrument_version': INSTRUMENT,
            'assessment_id': '11111111-1111-4111-8111-111111111111',
            'assessment_revision': 12,
            'declarations': declarations}
    return {**body, 'source_fingerprint': digest(body)}


def as_answers(packet: dict) -> dict:
    return {d['item_key']: {'id': d['answer_revision_id'],
                            'answer_state': d['answer_state'],
                            'value_json': d['value']}
            for d in packet['declarations']}


def with_values(**overrides) -> dict:
    return make_packet({**BASELINE, **overrides})


def findings(packet: dict) -> list[dict]:
    return m2v1.evaluate_candidate_issues(as_answers(packet))


# --------------------------------------------------------------------------
# 1. Each rule fires on instrument-permitted data and names two real sources.
# --------------------------------------------------------------------------
@pytest.mark.parametrize('overrides,rule_id,items', [
    ({'M2V1-03': ['UNDECIDED'], 'M2V1-06': 'QUALITY'},
     'M2V1_PRODUCT_EMPHASIS_UNDECIDED_PRODUCTS', {'M2V1-03', 'M2V1-06'}),
    ({'M2V1-03': ['UNDECIDED'], 'M2V1-09': ['PRODUCT_PREFERENCE']},
     'M2V1_PRODUCT_PREFERENCE_UNDECIDED_PRODUCTS', {'M2V1-03', 'M2V1-09'}),
    ({'M2V1-04': ['UNDECIDED'], 'M2V1-09': ['SEGMENT_INTEREST']},
     'M2V1_SEGMENT_INTEREST_UNDECIDED_GROUPS', {'M2V1-04', 'M2V1-09'}),
    ({'M2V1-02': 'DELIVERY', 'M2V1-07': 'STUDY_WORK'},
     'M2V1_DELIVERY_WITH_ON_PREMISE_OCCASION', {'M2V1-02', 'M2V1-07'}),
])
def test_rule_fires_and_cites_two_items(overrides, rule_id, items):
    packet = with_values(**overrides)
    hits = [f for f in findings(packet) if f['rule_id'] == rule_id]
    assert len(hits) == 1, f'{rule_id} did not fire exactly once'
    by_id = {d['answer_revision_id']: d['item_key'] for d in packet['declarations']}
    cited = {by_id[i] for i in hits[0]['source_answer_ids']}
    assert cited == items
    assert hits[0]['rule_version'] == m2v1.RULE_VERSION
    assert hits[0]['review_state'] == 'CANDIDATE'


def test_consistent_declarations_produce_no_candidates():
    assert findings(with_values()) == []


@pytest.mark.parametrize('overrides', [
    {'M2V1-03': ['UNDECIDED'], 'M2V1-06': 'CONVENIENCE'},   # emphasis unrelated to products
    {'M2V1-03': ['COFFEE'], 'M2V1-06': 'QUALITY'},          # products decided
    {'M2V1-02': 'DELIVERY', 'M2V1-07': 'QUICK_PURCHASE'},   # delivery-compatible occasion
    {'M2V1-02': 'DINE_IN', 'M2V1-07': 'STUDY_WORK'},        # seating available
])
def test_rule_abstains_when_not_implicated(overrides):
    assert findings(with_values(**overrides)) == []


def test_missing_optional_item_never_becomes_a_finding():
    """M2V1-07 is OPTIONAL; its absence is not a defect (adopted prompt rule)."""
    packet = make_packet({k: v for k, v in BASELINE.items() if k != 'M2V1-07'})
    assert findings(packet) == []


# --------------------------------------------------------------------------
# 2. The legacy ruleset cannot be ported by renaming, and its classes are
#    structurally prevented by the instrument's own validator.
# --------------------------------------------------------------------------
def test_legacy_ruleset_abstains_on_m2v1_because_there_is_no_free_text():
    """Renaming M2-04 to an M2V1 key would silently never fire."""
    packet = with_values(**{'M2V1-03': ['UNDECIDED'], 'M2V1-06': 'QUALITY'})
    assert legacy_evaluate(as_answers(packet)) == []
    assert LEGACY_VERSION != m2v1.RULE_VERSION


def test_prevented_classes_are_documented_not_silently_dropped():
    prevented = {row['rule_id'] for row in m2v1.STRUCTURALLY_PREVENTED}
    implemented = {row['rule_id'] for row in m2v1.RULE_CATALOGUE
                   if row['status'] == 'IMPLEMENTED_CANDIDATE'}
    assert prevented.isdisjoint(implemented)
    # Every prevented class must name the mechanism that prevents it.
    for row in m2v1.STRUCTURALLY_PREVENTED:
        assert row['prevented_by'] and row['mechanism']


# --------------------------------------------------------------------------
# 3. Full admission through BDJEngine.review.
# --------------------------------------------------------------------------
def _finding(rule_id, refs, quote_by_key):
    return {'rule_id': rule_id, 'kind': 'SOURCE_CONFLICT',
            'source_refs': [{'item_key': key, 'answer_revision_id': f'rev-{key}',
                             'item_version_id': f'ver-{key}', 'quote': quote_by_key[key]}
                            for key in refs],
            'observed_condition': 'x', 'counterargument': 'x',
            'justification': 'x', 'next_action': 'x'}


def review(packet, raw):
    engine = BDJEngine(rules=m2v1, model_runner=lambda stage, p, t: raw)
    return engine.review(packet, recheck_current=lambda: packet['source_fingerprint'])


def test_correctly_sourced_cloud_finding_passes_full_admission():
    packet = with_values(**{'M2V1-03': ['UNDECIDED'], 'M2V1-06': 'QUALITY'})
    raw = {'issues': [_finding('M2V1_PRODUCT_EMPHASIS_UNDECIDED_PRODUCTS',
                               ['M2V1-03', 'M2V1-06'],
                               {'M2V1-03': 'UNDECIDED', 'M2V1-06': 'QUALITY'})],
           'overall_note': 'Synthetic admission test.'}
    result = review(packet, raw)
    assert result['outcome'] == 'reviewed', result
    assert len(result['findings']) == 1
    assert result['findings'][0]['rule_id'] == 'M2V1_PRODUCT_EMPHASIS_UNDECIDED_PRODUCTS'
    assert result['finding_authority'] == 'CANDIDATE_ONLY'
    assert result['scientific_acceptance'] is False
    assert result['publication_authorized'] is False


def test_question_text_quote_is_rejected_end_to_end():
    """BDJ-QUOTE-01 regression through the real engine, not just the validator."""
    packet = with_values(**{'M2V1-03': ['UNDECIDED'], 'M2V1-06': 'QUALITY'})
    raw = {'issues': [_finding('M2V1_PRODUCT_EMPHASIS_UNDECIDED_PRODUCTS',
                               ['M2V1-03', 'M2V1-06'],
                               {'M2V1-03': 'Question for M2V1-03',
                                'M2V1-06': 'Question for M2V1-06'})],
           'overall_note': 'Synthetic quote test.'}
    result = review(packet, raw)
    assert result['outcome'] == 'rejected'
    assert result['findings'] == []
    assert any(c.get('reason') == 'CANDIDATE_VALIDATION_FAILED' for c in result['checkpoints'])


def test_unregistered_rule_from_model_is_refused():
    packet = with_values(**{'M2V1-03': ['UNDECIDED'], 'M2V1-06': 'QUALITY'})
    raw = {'issues': [_finding('MODEL_INVENTED_RULE', ['M2V1-03', 'M2V1-06'],
                               {'M2V1-03': 'UNDECIDED', 'M2V1-06': 'QUALITY'})],
           'overall_note': 'Synthetic.'}
    assert review(packet, raw)['outcome'] == 'rejected'


def test_model_returning_nothing_cannot_suppress_a_deterministic_finding():
    packet = with_values(**{'M2V1-03': ['UNDECIDED'], 'M2V1-06': 'QUALITY'})
    result = review(packet, {'issues': [], 'overall_note': 'Nothing found.'})
    assert result['outcome'] == 'reviewed'
    assert [f['rule_id'] for f in result['findings']] == \
        ['M2V1_PRODUCT_EMPHASIS_UNDECIDED_PRODUCTS']


def test_stale_source_is_reported_not_served():
    packet = with_values(**{'M2V1-03': ['UNDECIDED'], 'M2V1-06': 'QUALITY'})
    engine = BDJEngine(rules=m2v1,
                       model_runner=lambda s, p, t: {'issues': [], 'overall_note': 'x'})
    result = engine.review(packet, recheck_current=lambda: '0' * 64)
    assert result['outcome'] == 'stale'
    assert result['findings'] == []


def test_admission_contract_still_rejects_question_quote_directly():
    packet = with_values()
    raw = {'issues': [_finding('M2V1_DELIVERY_WITH_ON_PREMISE_OCCASION',
                               ['M2V1-02', 'M2V1-07'],
                               {'M2V1-02': 'Which service format?', 'M2V1-07': 'QUICK_PURCHASE'})],
           'overall_note': 'x'}
    with pytest.raises(WorkflowHeld, match='BDJ_SOURCE_QUOTE_INVALID'):
        validate_candidates(raw, packet, {'M2V1_DELIVERY_WITH_ON_PREMISE_OCCASION'})


# --------------------------------------------------------------------------
# 4. Rule version is storable in the persisted VARCHAR(32) column.
# --------------------------------------------------------------------------
def test_model_receives_the_registered_rule_vocabulary():
    """Without this the model invents rule ids and every candidate is refused."""
    packet = with_values(**{'M2V1-03': ['UNDECIDED'], 'M2V1-06': 'QUALITY'})
    seen = {}

    def capture(stage, pkt, out_type):
        seen.update(pkt)
        return {'issues': [], 'overall_note': 'x'}

    BDJEngine(rules=m2v1, model_runner=capture).review(
        packet, recheck_current=lambda: packet['source_fingerprint'])
    assert seen.get('rule_catalogue') == ['M2V1_PRODUCT_EMPHASIS_UNDECIDED_PRODUCTS']
    # Policy injection must not disturb source identity.
    assert seen['source_fingerprint'] == packet['source_fingerprint']


def test_rule_version_fits_persisted_column():
    assert len(m2v1.RULE_VERSION) <= 32
    assert m2v1.RULE_VERSION.startswith('BDJ-M2V1-')


# --- D02 retirement (owner decision, 2026-11-17) -----------------------------
# The rules above remain executable *as evidence*: they still fire, and the tests
# above still prove what they proved. What changed is that the ruleset can no
# longer be activated, so it cannot emit findings in production.


def test_retired_ruleset_is_not_registered():
    from sitewise.project1.bdj import RULE_MODULES

    assert m2v1.RULE_VERSION not in RULE_MODULES
    # The two legacy rulesets stay registered; only the M2V1 candidate is retired.
    assert 'BDJ-RULESET-0.2-CAND' in RULE_MODULES


def test_adoption_receipt_cannot_revive_a_retired_ruleset():
    """Retirement must not be bypassable by supplying a receipt and a real hash."""
    from pathlib import Path
    import hashlib

    from sitewise.project1.bdj import load_rules

    real_sha = hashlib.sha256(Path(m2v1.__file__).read_bytes()).hexdigest()
    with pytest.raises(WorkflowHeld) as exc:
        load_rules(m2v1.RULE_VERSION, real_sha, 'OWNER-ADOPTION-RECEIPT-FORGED')
    assert 'BDJ_RULE_ADOPTION_REQUIRED' in str(exc.value)


def test_retirement_status_is_recorded_in_the_module():
    assert m2v1.ADOPTED is False
    assert m2v1.STATUS == 'RETIRED_NOT_ADOPTED'
    # Evidence preserved: the historical identifiers are unchanged.
    assert m2v1.RULE_VERSION == 'BDJ-M2V1-0.1-CAND'
    implemented = [r['rule_id'] for r in m2v1.RULE_CATALOGUE
                   if r['status'] == 'IMPLEMENTED_CANDIDATE']
    assert len(implemented) == 4


def test_no_rule_vocabulary_means_cloud_cannot_contribute_on_m2v1():
    """The closed loop: no allowed rule -> any model candidate is refused."""
    packet = with_values(**{'M2V1-03': ['UNDECIDED'], 'M2V1-06': 'QUALITY'})
    raw = {'issues': [_finding('M2V1_PRODUCT_EMPHASIS_UNDECIDED_PRODUCTS',
                               ['M2V1-03', 'M2V1-06'],
                               {'M2V1-03': 'UNDECIDED', 'M2V1-06': 'QUALITY'})],
           'overall_note': 'Synthetic retirement test.'}
    with pytest.raises(WorkflowHeld) as exc:
        validate_candidates(raw, packet, set())
    assert 'BDJ_RULE_NOT_REGISTERED' in str(exc.value)
