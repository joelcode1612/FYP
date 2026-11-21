"""CP-01: QG contract 2.0 — generate from confirmed facts, not a measurement.

The V2.0 defect this replaces: ``execute_direct_qg`` required a complete
``Measurement``, which after QJ removal had no producer, so the active path could
only refuse. The fix is a contract change, not a data change — QG is given what
the entrepreneur confirmed and returns a *proposal*.

Each test below pins one of the three rules that make that safe:

1. the model cannot invent a business fact (numbers, prices, offer components);
2. an insufficient objective produces a *justified* abstention, not a guess;
3. everything the model produced is labelled a proposal, never a fact.
"""
from __future__ import annotations

import copy
from types import SimpleNamespace

import pytest
from pydantic import ValidationError

from sitewise.project1.contracts import Measurement, QGOutput, WorkflowHeld, digest
from sitewise.project1.measurement_policy import lab_authority
from sitewise.project1.prompts import PROMPTS
from sitewise.project1.qg_contract import (
    CONFIRMED, CONTRACT_VERSION, MISSING_FACT_CODES, PROPOSED, ConfirmedFacts,
    QGCandidate, facts_from_packet, field_authority, validate_candidate,
)
from sitewise.project1.research import ResearchWorkflow

UNCERTAINTY_ID = 'a1b2c3d4-0000-4000-8000-000000000000'
CONFIRMATION_ID = 'b2c3d4e5-0000-4000-8000-000000000000'
PRICE_TEXT = ('Would eligible customers find RM13 acceptable for a 12 oz takeaway '
              'iced latte?')
NO_PRICE_TEXT = 'Which service format would eligible customers prefer for breakfast?'


def packet(*, exact_text=PRICE_TEXT, status='CURRENT_CONFIRMED', uncertainty=True):
    value = {
        'schema_version': 'business-context-package/1.1',
        'assessment_id': 'SYN-ASSESS-1',
        'confirmation': {'status': status, 'id': CONFIRMATION_ID, 'revision': 1},
        'confirmed_uncertainty': ({
            'id': UNCERTAINTY_ID, 'confirmation_id': CONFIRMATION_ID,
            'actor_user_id': 'c3d4e5f6-0000-4000-8000-000000000000',
            'exact_text': exact_text} if uncertainty else None),
        'geography': None,
        'permissions': {'qj_execution': False},
        'm2_answers': [{'answer_revision_id': 'SYN-A1', 'item_key': 'M2-04',
                        'value': 'takeaway only'}],
        'supporting_sources': [],
    }
    value['packet_hash'] = digest(value)
    return value


def draft(**overrides):
    value = {
        'decision': 'DRAFT',
        'question': 'Would you find a 12 oz takeaway iced latte at RM13 acceptable?',
        'justification': 'One neutral question about the confirmed offer.',
        'construct_interpretation': 'Stated acceptability of the confirmed offer.',
        'response_options': ['Acceptable', 'Not acceptable', "Don't know"],
        'response_codes': ['ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW'],
        'routing': {'ACCEPTABLE': 'END', 'NOT_ACCEPTABLE': 'END', 'DONT_KNOW': 'END'},
        'reference_period': 'At the moment the respondent views the offer.',
        'measurement_description': 'Share describing the offer as acceptable.',
        'denominator_specification': ('ACCEPTABLE and NOT_ACCEPTABLE respondents; '
                                      'DONT_KNOW reported separately.'),
        'limitations': ('Stated acceptability only. Not a purchase, demand or sales '
                        'estimate.'),
        'unresolved_assumptions': [],
        'missing_business_facts': [],
        'used_confirmed_facts': ['RM13', '12'],
    }
    value.update(overrides)
    return value


def abstention(**overrides):
    value = {
        'decision': 'ABSTAIN_NEEDS_REVIEW',
        'question': '',
        'justification': 'The confirmed facts do not state a price.',
        'missing_business_facts': ['PRICE'],
        'used_confirmed_facts': [],
    }
    value.update(overrides)
    return value


def facts(**kwargs):
    return facts_from_packet(packet(**kwargs))


def workflow(*, runner=None, packet_value=None, authority=None):
    measurement_packet = packet() if packet_value is None else packet_value
    calls = []

    def default_runner(stage, payload, output_type):
        calls.append(stage)
        return draft()

    def recording(stage, payload, output_type):
        calls.append(stage)
        return runner(stage, payload, output_type)

    w = ResearchWorkflow(SimpleNamespace(get_context=lambda _: copy.deepcopy(measurement_packet)),
                         authority or lab_authority(), _ForbiddenBank(),
                         recording if runner else default_runner)
    return w, calls


class _ForbiddenBank:
    def lookup(self, *a, **k):
        raise AssertionError('contract 2.0 must not consult a shared bank')

    def verify_receipt(self, *a, **k):
        raise AssertionError('contract 2.0 must not verify a bank receipt')


# ---------------------------------------------------------------------------
# Confirmed facts are assembled from the packet, never inferred
# ---------------------------------------------------------------------------
def test_confirmed_facts_come_from_the_packet_only():
    f = facts()
    assert f.uncertainty_version == UNCERTAINTY_ID
    assert f.confirmed_currency == ['RM13']
    assert set(f.confirmed_numbers) == {'12', '13'}
    assert f.objective_text == PRICE_TEXT
    assert UNCERTAINTY_ID in f.source_refs
    assert f.contract_version == CONTRACT_VERSION


def test_confirmed_facts_refuse_a_packet_without_a_revision():
    value = packet()
    value['m2_answers'] = []
    value['packet_hash'] = digest({k: v for k, v in value.items() if k != 'packet_hash'})
    with pytest.raises(WorkflowHeld, match='QG_CONFIRMED_FACTS_INCOMPLETE'):
        facts_from_packet(value)


def test_confirmed_facts_refuse_an_empty_uncertainty_text():
    with pytest.raises(WorkflowHeld, match='QG_CONFIRMED_UNCERTAINTY_TEXT_MISSING'):
        facts_from_packet(packet(exact_text='   '))


def test_confirmed_facts_refuse_an_unidentified_assessment():
    """A placeholder would be reported as CONFIRMED while being an invention."""
    value = packet()
    del value['assessment_id']
    value['packet_hash'] = digest({k: v for k, v in value.items() if k != 'packet_hash'})
    with pytest.raises(WorkflowHeld, match='QG_CONFIRMED_FACTS_INCOMPLETE'):
        facts_from_packet(value)


def test_confirmed_facts_accept_the_identity_block_form():
    """The real BCB packet carries assessment_id under `identity`."""
    value = packet()
    del value['assessment_id']
    value['identity'] = {'assessment_id': 'SYN-ASSESS-9', 'owner_id': 'SYN-OWNER'}
    value['packet_hash'] = digest({k: v for k, v in value.items() if k != 'packet_hash'})
    assert facts_from_packet(value).assessment_id == 'SYN-ASSESS-9'


def test_an_objective_without_a_price_yields_no_confirmed_currency():
    f = facts(exact_text=NO_PRICE_TEXT)
    assert f.confirmed_currency == []


# ---------------------------------------------------------------------------
# A valid proposal is admitted, and every field is labelled
# ---------------------------------------------------------------------------
def test_a_complete_proposal_is_admitted():
    candidate = validate_candidate(draft(), facts())
    assert candidate.decision == 'DRAFT'
    assert candidate.missing_business_facts == []


def test_every_candidate_field_is_reported_as_a_proposal():
    candidate = validate_candidate(draft(), facts())
    authority = field_authority(candidate)
    assert authority['contract_version'] == CONTRACT_VERSION
    assert 'question' in authority[PROPOSED]
    assert 'response_codes' in authority[PROPOSED]
    assert 'uncertainty_version' in authority[CONFIRMED]
    assert authority['scientifically_adopted'] is False
    assert authority['fielding_authorized'] is False
    # The two lists must not overlap, or a field could be read as both.
    assert not set(authority[CONFIRMED]) & set(authority[PROPOSED])


def test_the_model_cannot_author_the_uncertainty_version():
    """F-01 is preserved by construction: there is no field to author.

    Under contract 1.0 the model had to echo a version it was never shown. Under
    2.0 the version is bound server-side and the candidate schema forbids extras,
    so a model that tries to restate it fails validation instead of overriding it.
    """
    assert 'uncertainty_version' not in QGCandidate.model_fields
    with pytest.raises(ValidationError):
        validate_candidate(draft(uncertainty_version='model-chosen'), facts())


# ---------------------------------------------------------------------------
# No invented business facts
# ---------------------------------------------------------------------------
def test_price_drift_is_refused():
    with pytest.raises(WorkflowHeld, match='QG_UNSOURCED_AMOUNT'):
        validate_candidate(draft(question='Would you find a 12 oz takeaway iced latte '
                                          'at RM12 acceptable?'), facts())


def test_a_number_the_entrepreneur_never_confirmed_is_refused():
    with pytest.raises(WorkflowHeld, match='QG_UNSOURCED_NUMBER'):
        validate_candidate(draft(question='Would you pay RM13 for a 16 oz iced latte?'),
                           facts())


def test_an_invented_size_is_refused_by_the_number_rule_first():
    """A wholly new quantity is caught by the number guard, which is stronger.

    Recorded explicitly so the offer-component test below is not mistaken for
    the only protection: "16 oz" fails on the unsourced number 16 before the
    offer rule is reached.
    """
    with pytest.raises(WorkflowHeld, match='QG_UNSOURCED_NUMBER'):
        validate_candidate(draft(question='Would you find a 16 oz takeaway iced latte '
                                          'acceptable?'), facts())


def test_an_offer_component_is_refused_when_the_number_is_confirmed_but_the_unit_is_not():
    """Isolates the offer rule: 12 is confirmed, "12 ml" is not.

    This is D-01 generalised. The digit 12 is legitimately present in the
    confirmed text, so a number-subset check passes; only comparing the whole
    quantity token catches the substitution.

    Without this case the offer guard would never be the reason for a refusal,
    and a passing suite would only prove the number guard works.
    """
    with pytest.raises(WorkflowHeld, match='QG_UNSOURCED_OFFER_COMPONENT'):
        validate_candidate(draft(question='Would you find a 12 ml takeaway iced latte '
                                          'at RM13 acceptable?'), facts())


def test_a_confirmed_offer_can_be_restated_freely():
    candidate = validate_candidate(
        draft(question='For a 12 oz takeaway iced latte priced at RM13, is this '
                       'acceptable?'), facts())
    assert candidate.decision == 'DRAFT'


# ---------------------------------------------------------------------------
# Insufficient facts produce a justified abstention
# ---------------------------------------------------------------------------
def test_abstention_is_a_valid_outcome_when_a_fact_is_missing():
    candidate = validate_candidate(abstention(), facts(exact_text=NO_PRICE_TEXT))
    assert candidate.decision == 'ABSTAIN_NEEDS_REVIEW'
    assert candidate.question == ''
    assert candidate.missing_business_facts == ['PRICE']


def test_abstention_must_name_what_is_missing():
    with pytest.raises(WorkflowHeld, match='QG_ABSTENTION_WITHOUT_MISSING_FACTS'):
        validate_candidate(abstention(missing_business_facts=[]),
                           facts(exact_text=NO_PRICE_TEXT))


def test_abstention_codes_must_come_from_the_declared_vocabulary():
    with pytest.raises(WorkflowHeld, match='QG_ABSTENTION_CODE_UNRECOGNISED'):
        validate_candidate(abstention(missing_business_facts=['VIBES']),
                           facts(exact_text=NO_PRICE_TEXT))
    assert 'PRICE' in MISSING_FACT_CODES


def test_abstention_cannot_smuggle_a_question():
    with pytest.raises(WorkflowHeld, match='QG_ABSTENTION_CONTAINS_QUESTION'):
        validate_candidate(abstention(question='Would you pay RM13?'),
                           facts(exact_text=NO_PRICE_TEXT))


def test_a_draft_cannot_simultaneously_declare_a_missing_mandatory_fact():
    with pytest.raises(WorkflowHeld, match='QG_DRAFT_DECLARES_MISSING_FACTS'):
        validate_candidate(draft(missing_business_facts=['PRICE']), facts())


# ---------------------------------------------------------------------------
# The deterministic checks that still apply
# ---------------------------------------------------------------------------
@pytest.mark.parametrize('change,code', [
    ({'response_codes': ['ACCEPTABLE']}, 'QG_RESPONSE_CODING_DRIFT'),
    ({'response_codes': ['ACCEPTABLE', 'ACCEPTABLE', 'DONT_KNOW']},
     'QG_RESPONSE_CODING_DRIFT'),
    ({'response_codes': ['accept', 'NOT_ACCEPTABLE', 'DONT_KNOW']},
     'QG_RESPONSE_CODING_DRIFT'),
    ({'routing': {'ACCEPTABLE': 'END'}}, 'QG_ROUTING_DRIFT'),
    ({'denominator_specification': 'All respondents.'}, 'QG_DENOMINATOR_DRIFT'),
    ({'denominator_specification': ''}, 'QG_DENOMINATOR_NOT_PROPOSED'),
    ({'limitations': 'None.'}, 'QG_LIMITATIONS_INCOMPLETE'),
    ({'construct_interpretation': 'The optimal price for this offer.'},
     'PROHIBITED_OPTIMUM_PRICE'),
    ({'used_confirmed_facts': []}, 'QG_CONFIRMED_FACTS_NOT_CITED'),
    ({'used_confirmed_facts': ['RM99']}, 'QG_CITED_FACT_NOT_CONFIRMED'),
    ({'question': '   '}, 'QG_DRAFT_WITHOUT_QUESTION'),
])
def test_proposal_checks(change, code):
    with pytest.raises(WorkflowHeld, match=code):
        validate_candidate(draft(**change), facts())


def test_a_limit_that_names_the_excluded_inference_is_allowed():
    """The prohibited-claim scan must not read the disclaimer as the claim."""
    candidate = validate_candidate(
        draft(limitations='Stated acceptability only. This is not a demand forecast, '
                          'not a willingness-to-pay estimate and not a profitability '
                          'claim.'), facts())
    assert candidate.decision == 'DRAFT'


# ---------------------------------------------------------------------------
# At the workflow boundary
# ---------------------------------------------------------------------------
def test_the_active_path_generates_without_a_measurement_and_without_qj():
    w, calls = workflow()
    result = w.execute_qg_from_facts(None)
    assert calls == ['QG'], 'QJ must not be invoked'
    assert result['qj'] is None
    assert result['contract_version'] == CONTRACT_VERSION
    assert result['bank'] == 'NOT_CONSULTED_DIRECT_QG'
    assert result['qg']['decision'] == 'DRAFT'
    assert result['candidate_authority'] == 'ENTREPRENEUR_REVIEW_ONLY'


def test_the_workflow_returns_confirmed_facts_alongside_the_proposal():
    w, _ = workflow()
    result = w.execute_qg_from_facts(None)
    assert result['confirmed_facts']['confirmed_currency'] == ['RM13']
    assert result['field_authority'][PROPOSED]
    assert result['field_authority']['scientifically_adopted'] is False


def test_the_workflow_grants_no_authority():
    w, _ = workflow()
    result = w.execute_qg_from_facts(None)
    for flag in ('scientific_acceptance', 'owner_authorization',
                 'publication_authorized', 'fielding_authorized',
                 'report_release_authorized'):
        assert result[flag] is False


def test_an_insufficient_objective_returns_an_abstention_not_a_fabrication():
    def runner(stage, payload, output_type):
        assert payload['confirmed_facts']['confirmed_currency'] == []
        return abstention()

    w, calls = workflow(runner=runner, packet_value=packet(exact_text=NO_PRICE_TEXT))
    result = w.execute_qg_from_facts(None)
    assert result['qg']['decision'] == 'ABSTAIN_NEEDS_REVIEW'
    assert result['qg']['missing_business_facts'] == ['PRICE']
    assert calls == ['QG']


def test_the_objective_is_carried_into_the_facts_and_the_result():
    w, _ = workflow()
    result = w.execute_qg_from_facts(
        None, objective={'objective_id': 'SYN-OBJ-1', 'origin': 'ENTREPRENEUR',
                         'text': 'Is RM13 acceptable for the 12 oz takeaway iced latte?'})
    assert result['objective_id'] == 'SYN-OBJ-1'
    assert result['confirmed_facts']['objective_id'] == 'SYN-OBJ-1'


def test_bdj_findings_are_carried_as_context_not_as_requirements():
    """CP-02: zero findings is a valid outcome and blocks nothing."""
    w, _ = workflow()
    result = w.execute_qg_from_facts(None, bdj_findings=())
    assert result['confirmed_facts']['bdj_findings'] == []
    assert result['qg']['decision'] == 'DRAFT'


def test_an_unconfirmed_context_is_refused_before_the_model():
    w, calls = workflow(packet_value=packet(status='SUPERSEDED'))
    with pytest.raises(WorkflowHeld, match='BCB_CONFIRMATION_REQUIRED'):
        w.execute_qg_from_facts(None)
    assert calls == []


def test_a_context_that_changes_after_generation_is_refused():
    w, calls = workflow()
    w.authority.require_current = lambda *a: (_ for _ in ()).throw(
        WorkflowHeld('F01_CONTEXT_CHANGED_SINCE_ADMISSION'))
    with pytest.raises(WorkflowHeld, match='F01_CONTEXT_CHANGED_SINCE_ADMISSION'):
        w.execute_qg_from_facts(None)
    assert calls == ['QG']


def test_previous_attempt_feedback_is_passed_to_the_retry():
    seen = {}

    def runner(stage, payload, output_type):
        seen.update(payload)
        return draft()

    w, _ = workflow(runner=runner)
    w.execute_qg_from_facts(None, revision_feedback={'code': 'QG_UNSOURCED_AMOUNT',
                                                     'attempt': 1})
    assert seen['previous_attempt']['code'] == 'QG_UNSOURCED_AMOUNT'


# ---------------------------------------------------------------------------
# Contract 1.0 stays readable
# ---------------------------------------------------------------------------
def test_the_1_0_contracts_are_unchanged():
    """A versioned successor must not rewrite history."""
    assert 'uncertainty_version' in Measurement.model_fields
    assert 'measurement' in QGOutput.model_fields
    assert PROMPTS['QG'].version == 'QG-FROZEN-2-CAND'
    assert PROMPTS['QG_PROPOSAL'].version == 'QG-PROPOSE-6-CAND'
    assert PROMPTS['QG'].version != PROMPTS['QG_PROPOSAL'].version
