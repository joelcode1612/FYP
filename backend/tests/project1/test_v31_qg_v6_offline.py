"""V3.1 CP-07: offline regression fixtures for the preserved QG-PROPOSE-6-CAND baseline.

OFFLINE ONLY. Every case calls ``validate_candidate`` on a hand-written
``QGCandidate`` payload against a hand-built ``ConfirmedFacts``. There is no
provider, ledger, network, model or database access anywhere in this module.

Purpose: decide whether a reproducible, relevant failure justifies a V7 prompt.
These fixtures are a *stand-in* for model output: a fixture that conforms to the
baseline prompt must be admitted; a fixture that violates a stated constraint
must be refused with the exact rule code the baseline contract declares. The
tests never relax a validator and never touch ``prompts.py``.
"""
from __future__ import annotations

import pytest

from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.qg_contract import CONTRACT_VERSION, ConfirmedFacts, validate_candidate

PRICE_OBJECTIVE = ('Would eligible customers find RM13 acceptable for a 12 oz '
                   'takeaway iced latte?')


def mkfacts(*, objective_text, numbers=(), currency=(), offers=(), src='V31-SRC-01',
            uncertainty_text=None):
    """Build ConfirmedFacts directly -- no packet assembly, no runner, no provider."""
    return ConfirmedFacts(
        contract_version=CONTRACT_VERSION,
        assessment_id='V31-OFFLINE-1',
        objective_id='V31-OBJ-1',
        objective_text=objective_text,
        uncertainty_id='V31-U-1',
        uncertainty_version='V31-U-1@1',
        uncertainty_text=uncertainty_text or objective_text,
        bcb_version='business-context-package/1.1',
        context_hash='v31-offline-fixture',
        m2_answer_revision_ids=['V31-A1'],
        bdj_findings=[],
        confirmed_offers=list(offers),
        confirmed_numbers=list(numbers),
        confirmed_currency=list(currency),
        source_refs=[src, 'V31-U-1'],
    )


def mkdraft(question, *, codes, labels, used, denominator=None,
            construct='Stated preference among the confirmed options.', **overrides):
    """A prompt-conforming DRAFT: routing is keyed by exactly the declared codes."""
    codes, labels = list(codes), list(labels)
    value = {
        'decision': 'DRAFT',
        'question': question,
        'justification': 'One neutral single-construct question proposed for review.',
        'construct_interpretation': construct,
        'response_options': labels,
        'response_codes': codes,
        'routing': {code: 'RECORD_RESPONSE_CONTINUE' for code in codes},
        'reference_period': 'At the moment the question is shown.',
        'measurement_description': 'Proposed share by response code; not an adopted measurement.',
        'denominator_specification': denominator or (
            'codes ' + ', '.join(codes) +
            ' are in the denominator; no other response code is included.'),
        'limitations': 'Stated preference only; not a purchase estimate.',
        'unresolved_assumptions': [],
        'missing_business_facts': [],
        'used_confirmed_facts': list(used),
    }
    value.update(overrides)
    return value


def price_fixture():
    """The baseline price/product/size offer, with a valid prompt-conforming DRAFT."""
    facts = mkfacts(objective_text=PRICE_OBJECTIVE, numbers=['12', '13'],
                    currency=['RM13'], offers=['12 oz', 'takeaway', 'iced'],
                    src='SRC-PRICE-01')
    candidate = mkdraft(
        'Would you find a 12 oz takeaway iced latte at RM13 acceptable?',
        codes=['DA', 'PA', 'ND'],
        labels=['Definitely acceptable', 'Probably acceptable', 'Not decided'],
        used=['RM13', '12', 'SRC-PRICE-01'],
        denominator='codes DA and PA are in the denominator; ND is excluded.',
        construct='Stated acceptability of the confirmed offer; not a sales estimate.',
    )
    return facts, candidate


def refused(code, candidate, facts):
    """Assert the exact deterministic rule; documented code is never widened."""
    with pytest.raises(WorkflowHeld) as exc:
        validate_candidate(candidate, facts)
    assert str(exc.value) == code


def test_01_price_objective_valid_draft():
    """Confirmed objective = price: the full constraint set is satisfiable."""
    facts, candidate = price_fixture()
    result = validate_candidate(candidate, facts)
    assert result.decision == 'DRAFT'
    assert set(result.routing) == {'DA', 'PA', 'ND'}
    assert result.missing_business_facts == []


def test_02_product_and_service_format_objectives_valid_drafts():
    """Confirmed objective = product, then service format (no numbers to borrow)."""
    product_facts = mkfacts(
        objective_text='Which of the confirmed drinks, flat white or cold brew, '
                       'would eligible customers choose?', src='SRC-PROD-01')
    product = mkdraft(
        'Would you choose the flat white or the cold brew?',
        codes=['FW', 'CB', 'NO_PREF'], labels=['Flat white', 'Cold brew', 'No preference'],
        used=['SRC-PROD-01'],
        denominator='codes FW and CB are in the denominator; NO_PREF is excluded.')
    assert validate_candidate(product, product_facts).decision == 'DRAFT'

    service_facts = mkfacts(
        objective_text='Which service format would eligible customers prefer for breakfast?',
        src='SRC-SVC-01')
    service = mkdraft(
        'Would you prefer takeaway or dine-in for breakfast?',
        codes=['TAKE', 'DINE', 'EITHER'], labels=['Takeaway', 'Dine-in', 'Either'],
        used=['SRC-SVC-01'],
        denominator='codes TAKE and DINE are in the denominator; EITHER is excluded.')
    assert validate_candidate(service, service_facts).decision == 'DRAFT'


def test_03_package_size_and_reference_period_objectives_valid_drafts():
    """Confirmed objective = package size (unit token), then reference period."""
    size_facts = mkfacts(
        objective_text='Would a 500 ml bottle be acceptable to eligible customers?',
        numbers=['500'], offers=['500 ml', 'bottle'], src='SRC-SIZE-01')
    size = mkdraft(
        'Would you find a 500 ml bottle acceptable?',
        codes=['ACC', 'NOT', 'DK'], labels=['Acceptable', 'Not acceptable', "Don't know"],
        used=['500', 'SRC-SIZE-01'],
        denominator='codes ACC and NOT are in the denominator; DK is excluded.')
    assert validate_candidate(size, size_facts).decision == 'DRAFT'

    period_facts = mkfacts(
        objective_text='How often would eligible customers visit in a typical month?',
        src='SRC-PER-01')
    period = mkdraft(
        'In a typical month, how often would you visit?',
        codes=['WEEKLY', 'MONTHLY', 'RARELY', 'NS'],
        labels=['Weekly', 'Monthly', 'Rarely', 'Not sure'], used=['SRC-PER-01'],
        denominator='codes WEEKLY and MONTHLY are in the denominator; '
                    'RARELY and NS are excluded.')
    assert validate_candidate(period, period_facts).decision == 'DRAFT'


def test_04_population_and_location_objectives_valid_drafts():
    """Confirmed objective = population (confirmed ages), then location."""
    pop_facts = mkfacts(
        objective_text='Would eligible customers aged 18 to 24 find the offer relevant?',
        numbers=['18', '24'], src='SRC-POP-01')
    pop = mkdraft(
        'Among adults aged 18 to 24, is this offer relevant to you?',
        codes=['REL', 'NOT_REL', 'DK'], labels=['Relevant', 'Not relevant', "Don't know"],
        used=['18', '24', 'SRC-POP-01'],
        denominator='codes REL and NOT_REL are in the denominator; DK is excluded.')
    assert validate_candidate(pop, pop_facts).decision == 'DRAFT'

    loc_facts = mkfacts(
        objective_text='Would customers in the city centre prefer a nearby outlet?',
        src='SRC-LOC-01')
    loc = mkdraft(
        'Would you prefer an outlet in the city centre?',
        codes=['CITY', 'SUBURB', 'NO_PREF'],
        labels=['City centre', 'Suburb', 'No preference'], used=['SRC-LOC-01'],
        denominator='codes CITY and SUBURB are in the denominator; NO_PREF is excluded.')
    assert validate_candidate(loc, loc_facts).decision == 'DRAFT'


def test_05_routing_must_be_keyed_by_declared_response_codes():
    """CP08-EVAL-6/7 regression: label keys and missing keys are refused."""
    facts, base = price_fixture()

    by_label = dict(base, routing={'definitely_acceptable': 'END',
                                   'probably_acceptable': 'END',
                                   'not_decided': 'END'})
    refused('QG_ROUTING_DRIFT', by_label, facts)

    partial = dict(base, routing={'DA': 'END', 'PA': 'END'})
    refused('QG_ROUTING_DRIFT', partial, facts)

    exact = dict(base, routing={'DA': 'END', 'PA': 'END', 'ND': 'END'})
    assert validate_candidate(exact, facts).decision == 'DRAFT'


def test_06_denominator_must_name_declared_response_codes():
    """CP08-EVAL-8 regression: a generic denominator is not a denominator."""
    facts, base = price_fixture()

    generic = dict(base, denominator_specification='all respondents who select an option')
    refused('QG_DENOMINATOR_DRIFT', generic, facts)

    empty = dict(base, denominator_specification='')
    refused('QG_DENOMINATOR_NOT_PROPOSED', empty, facts)

    other_codes = dict(base, response_codes=['VU', 'U', 'NU'],
                       response_options=['Very useful', 'Useful', 'Not useful'],
                       routing={c: 'END' for c in ('VU', 'U', 'NU')},
                       denominator_specification='codes VU, U and NU are in the '
                                                 'denominator; no other codes are included.')
    assert validate_candidate(other_codes, facts).decision == 'DRAFT'


def test_07_unsourced_numbers_amounts_and_citations_are_refused():
    """D-01 price drift, invented quantity, unit swap and v6 citation regression."""
    facts, base = price_fixture()

    # The digit 12 is confirmed by '12 oz'; changing only the currency token
    # must still be refused (this is exactly the D-01 case).
    refused('QG_UNSOURCED_AMOUNT',
            dict(base, question='Would you find a 12 oz takeaway iced latte at '
                                'RM12 acceptable?'), facts)

    refused('QG_UNSOURCED_NUMBER',
            dict(base, question='Would you find a 16 oz takeaway iced latte at '
                                'RM13 acceptable?'), facts)

    refused('QG_UNSOURCED_OFFER_COMPONENT',
            dict(base, question='Would you find a 12 ml takeaway iced latte at '
                                'RM13 acceptable?'), facts)

    refused('QG_CITED_FACT_NOT_CONFIRMED',
            dict(base, used_confirmed_facts=['RM13', 'iced', 'takeaway']), facts)

    refused('QG_CONFIRMED_FACTS_NOT_CITED',
            dict(base, used_confirmed_facts=[]), facts)


def test_08_abstention_is_valid_only_when_essential_facts_are_missing():
    """A justified multi-code ABSTAIN is an outcome, not a validation failure."""
    facts = mkfacts(
        objective_text='Would customers find the latte acceptable at a price and '
                       'location the entrepreneur has not confirmed?',
        src='SRC-ABST-01')
    abstain = {
        'decision': 'ABSTAIN_NEEDS_REVIEW',
        'question': '',
        'justification': 'Neither a price nor a location is confirmed; both are '
                         'mandatory for the stated objective.',
        'missing_business_facts': ['PRICE', 'LOCATION'],
        'used_confirmed_facts': [],
    }
    result = validate_candidate(abstain, facts)
    assert result.decision == 'ABSTAIN_NEEDS_REVIEW'
    assert result.question == ''
    assert result.missing_business_facts == ['PRICE', 'LOCATION']

    refused('QG_ABSTENTION_CONTAINS_QUESTION',
            dict(abstain, question='Would you pay RM13?'), facts)
    refused('QG_ABSTENTION_WITHOUT_MISSING_FACTS',
            dict(abstain, missing_business_facts=[]), facts)
    refused('QG_ABSTENTION_CODE_UNRECOGNISED',
            dict(abstain, missing_business_facts=['VIBES']), facts)

    _, draft = price_fixture()
    refused('QG_DRAFT_DECLARES_MISSING_FACTS',
            dict(draft, missing_business_facts=['PRICE']), _)
