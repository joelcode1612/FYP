"""CP-04 — controlled synthetic business declarations and predefined expectations.

Every packet here is synthetic. No real assessment, entrepreneur or respondent
appears in it. The purpose is to fix, *before* any paid dispatch, what a correct
answer looks like for each case, including the cases where the correct answer is
"propose nothing" or "abstain".

Two splits:

* ``dev``      — available while iterating on the prompt.
* ``heldout``  — frozen; used once, for the comparison, and not consulted while
                 editing prompt wording.

Each case carries:

    id                 stable identifier
    split              'dev' | 'heldout'
    intent             one sentence, what this case is for
    declarations       M2V2 declarations (BDJ) — overrides on the baseline packet
    facts              ConfirmedFacts fields (QG)
    expected           the behaviour a compliant response must show
    golden_output      a hand-written response that satisfies both the contract
                       and the expected behaviour
    negatives          outputs that must be REJECTED, with the exact code

``golden_output`` is a fixture, not a model result. It is never counted as
evidence that the prompt works.
"""
from __future__ import annotations

import copy
import hashlib

#: The nineteen registered M2V2 items, in order. Only the ones a case needs carry
#: a meaningful value; the rest are ANSWERED with a neutral definite value or
#: NOT_ANSWERED, and that is stated per case rather than implied.
ITEM_KEYS = tuple(f'M2V2-{i:02d}' for i in range(1, 20))


def _uuid(seed: str) -> str:
    """Deterministic uuid-shaped identifier, so fixtures are reproducible."""
    h = hashlib.sha256(seed.encode()).hexdigest()
    return f'{h[0:8]}-{h[8:12]}-4{h[13:16]}-8{h[17:20]}-{h[20:32]}'


def _decl(item_key: str, value, state: str = 'ANSWERED', seed: str = '') -> dict:
    return {
        'item_key': item_key,
        'answer_state': state,
        'value': value,
        'answer_revision_id': _uuid(f'{item_key}:rev:{seed}'),
        'item_version_id': _uuid(f'{item_key}:ver:{seed}'),
    }


def baseline_declarations(seed: str = 'base') -> list[dict]:
    """A fully answered, entirely definite packet.

    Nothing in it establishes an information gap. This is the negative control:
    a compliant response proposes nothing, because every declaration is a
    decision rather than an uncertainty.
    """
    values = {
        'M2V2-01': 'CAFE_SERVING_SPECIALTY_COFFEE',
        'M2V2-02': 'STUDENTS',
        'M2V2-03': 'DINE_IN',
        'M2V2-04': ['COFFEE'],
        'M2V2-05': '250 ml',
        'M2V2-06': 'UNDER_50000',
        'M2V2-07': 'OWN_FUNDS',
        'M2V2-08': 'FULL_TIME',
        'M2V2-09': ['CONCEPT_INTEREST'],
        'M2V2-10': 'WITHIN_3_MONTHS',
        'M2V2-11': 'PROCEED',
        'M2V2-12': 'SUBURBAN_HIGH_STREET',
        'M2V2-13': 'WEEKDAY_MORNING',
        'M2V2-14': {'decision': 'PRICED', 'product_reference': 'Single-origin filter coffee',
                    'size': '250 ml', 'price': '16.00', 'currency': 'MYR'},
        'M2V2-15': 'TAKEAWAY_CUP',
        'M2V2-16': 'NO',
        'M2V2-17': 'NOT_REQUIRED',
        'M2V2-18': {'hypothesis_status': 'NOT_ESTABLISHED', 'hypothesis_text': ''},
        'M2V2-19': 'SOLO_OPERATOR',
    }
    return [_decl(k, values[k], seed=seed) for k in ITEM_KEYS]


def packet(declarations: list[dict], *, seed: str = 'ctx') -> dict:
    """Wrap declarations in the shape `validate_objective_proposal_v2` expects."""
    return {'declarations': copy.deepcopy(declarations),
            'assessment_id': _uuid(f'assessment:{seed}'),
            'example_only': False}


def _with(overrides: dict, seed: str) -> list[dict]:
    """Baseline packet with specific items replaced."""
    decls = baseline_declarations(seed)
    for item_key, value in overrides.items():
        for i, d in enumerate(decls):
            if d['item_key'] == item_key:
                if value is None:
                    decls[i] = _decl(item_key, None, state='NOT_ANSWERED', seed=seed)
                else:
                    decls[i] = _decl(item_key, value, seed=seed)
    return decls


def _ref(decls: list[dict], item_key: str) -> dict:
    for d in decls:
        if d['item_key'] == item_key:
            return {'item_key': item_key,
                    'answer_revision_id': d['answer_revision_id'],
                    'item_version_id': d['item_version_id']}
    raise KeyError(item_key)


def _rec(decls: list[dict], **overrides) -> dict:
    """A fully populated, contract-valid v2 recommendation."""
    base = {
        'recommendation_status': 'MOST_SUGGESTED',
        'problem_type': 'SOURCE_CONFIRMED_INFORMATION_GAP',
        'business_uncertainty': 'The stated price acceptance has not been tested with customers.',
        'source_refs': [],
        'research_objective': 'To investigate whether prospective customers would accept the '
                              'confirmed priced offer.',
        'research_justification': 'The offer is priced, but no customer evidence supports the '
                                  'assumption behind the price.',
        'business_decision': 'Whether to commit to the confirmed priced offer unchanged.',
        'customer_research_suitability': 'SUITABLE - acceptance of a stated price is a customer '
                                         'perception.',
        'measurement_construct': 'STATED_PRICE_ACCEPTABILITY_FIXED_HYPOTHETICAL_OFFER',
        'measurement_approach': 'A single-select acceptability item shown to eligible '
                                'respondents alongside the confirmed offer.',
        'expected_evidence': 'A distribution of stated acceptability, not a purchase rate.',
        'interpretation_limitations': 'Stated acceptability of one hypothetical price is not '
                                      'maximum willingness to pay.',
        'linked_fixed_objective': 'O3',
        'authority': 'CANDIDATE_ONLY',
    }
    base.update(overrides)
    return base


# ---------------------------------------------------------------------------
# BDJ cases
# ---------------------------------------------------------------------------

def bdj_cases() -> list[dict]:
    cases = []

    # 1. A single undecided answer. The clearest possible gap.
    d = _with({'M2V2-01': 'UNDECIDED'}, 'bdj-undecided')
    cases.append({
        'id': 'bdj_undecided_scalar', 'split': 'dev',
        'intent': 'One UNDECIDED answer. A correct response names it as a '
                  'source-confirmed gap and cites it.',
        'declarations': d,
        'expected': {
            'recommendations': 'exactly one',
            'status': 'MOST_SUGGESTED',
            'must_cite': ['M2V2-01'],
            'must_not_claim': True,
        },
        'golden_output': {
            'contract_version': 'bdj-objective-proposal/2',
            'recommendations': [_rec(
                d, source_refs=[_ref(d, 'M2V2-01')],
                business_uncertainty='The trading area for the proposed cafe is undecided.',
                research_objective='To investigate which trading areas prospective customers '
                                   'would travel to for the proposed cafe concept.',
                research_justification='The trading area is explicitly undecided, so no '
                                       'location commitment exists to test.',
                business_decision='Whether to commit to one trading area.',
                measurement_construct='STATED_TRADING_AREA_VISIT_INTENTION',
                measurement_approach='A single-select item asking which listed areas '
                                     'respondents would visit for the concept.',
                expected_evidence='Stated visit intention by area, not observed footfall.',
                interpretation_limitations='Stated intention to visit is not observed visits.',
                linked_fixed_objective='O1')],
        },
        'negatives': [
            {'label': 'cites a definite item as the gap',
             'expect_code': 'BDJ_OBJECTIVE_SOURCE_NOT_SUPPORTING',
             'output': {'contract_version': 'bdj-objective-proposal/2',
                        'recommendations': [_rec(d, source_refs=[_ref(d, 'M2V2-02')])]}},
            {'label': 'most-suggested with no source',
             'expect_code': 'BDJ_OBJECTIVE_SOURCE_REQUIRED',
             'output': {'contract_version': 'bdj-objective-proposal/2',
                        'recommendations': [_rec(d, source_refs=[])]}},
            {'label': 'objective phrased as a question',
             'expect_code': 'BDJ_OBJECTIVE_PHRASING_INVALID',
             'output': {'contract_version': 'bdj-objective-proposal/2',
                        'recommendations': [_rec(
                            d, source_refs=[_ref(d, 'M2V2-01')],
                            research_objective='Would customers accept the price?')]}},
            {'label': 'claims demand',
             'expect_code': 'BDJ_OBJECTIVE_CLAIM_NOT_ALLOWED',
             'output': {'contract_version': 'bdj-objective-proposal/2',
                        'recommendations': [_rec(
                            d, source_refs=[_ref(d, 'M2V2-01')],
                            research_objective='To investigate the market demand for the cafe.')]}},
        ],
    })

    # 2. The second source shape: a definite priced offer plus an untested
    #    hypothesis. This is the shape a naive prompt cannot express.
    d = _with({'M2V2-11': 'VALIDATE_CHOICE',
               'M2V2-18': {'hypothesis_status': 'HYPOTHESIS_IDENTIFIED',
                           'hypothesis_text': 'Customers will accept RM16.00 for a 250 ml '
                                              'filter coffee.'}}, 'bdj-priced')
    cases.append({
        'id': 'bdj_priced_hypothesis', 'split': 'dev',
        'intent': 'A priced offer plus an identified but untested hypothesis. The '
                  'definite offer may be cited as the subject of the uncertainty.',
        'declarations': d,
        'expected': {
            'recommendations': 'exactly one',
            'status': 'MOST_SUGGESTED',
            'must_cite': ['M2V2-18'],
            'may_also_cite': ['M2V2-14', 'M2V2-11'],
            'construct_family': 'STATED_PRICE_ACCEPTABILITY',
        },
        'golden_output': {
            'contract_version': 'bdj-objective-proposal/2',
            'recommendations': [_rec(
                d, source_refs=[_ref(d, 'M2V2-11'), _ref(d, 'M2V2-14'),
                                _ref(d, 'M2V2-18')],
                business_uncertainty='The stated RM16.00 acceptance for a 250 ml filter '
                                     'coffee is an untested hypothesis.',
                research_objective='To investigate whether prospective customers would accept '
                                   'RM16.00 for a 250 ml single-origin filter coffee.',
                research_justification='The offer is priced and the acceptance assumption is '
                                       'identified, but no customer has been asked.',
                business_decision='Whether to hold RM16.00 for the 250 ml filter coffee.',
                measurement_construct='STATED_PRICE_ACCEPTABILITY_FIXED_HYPOTHETICAL_OFFER')],
        },
        'negatives': [
            {'label': 'definite offer alone, no establishing ref',
             'expect_code': 'BDJ_OBJECTIVE_SOURCE_NOT_SUPPORTING',
             'output': {'contract_version': 'bdj-objective-proposal/2',
                        'recommendations': [_rec(d, source_refs=[_ref(d, 'M2V2-14')])]}},
            {'label': 'construct collides with a fixed objective',
             'expect_code': 'BDJ_V2_CONSTRUCT_COLLIDES_WITH_FIXED_OBJECTIVE',
             'output': {'contract_version': 'bdj-objective-proposal/2',
                        'recommendations': [_rec(
                            d, source_refs=[_ref(d, 'M2V2-18')],
                            measurement_construct='STATED_ACCEPTABILITY_OF_AN_EXACT_SPECIFIED_PRICED_OFFER')]}},
        ],
    })

    # 3. Everything is definite. The correct answer is to propose nothing.
    d = baseline_declarations('bdj-definite')
    cases.append({
        'id': 'bdj_all_definite', 'split': 'dev',
        'intent': 'Every declaration is a decision. A compliant response proposes '
                  'nothing and does not dress a decision up as a gap.',
        'declarations': d,
        'expected': {'recommendations': 'empty array (preferred) or a single SUGGESTED '
                                        'with no source_refs', 'status': None},
        'golden_output': {'contract_version': 'bdj-objective-proposal/2',
                          'recommendations': []},
        'negatives': [
            {'label': 'invents a gap from a definite decision',
             'expect_code': 'BDJ_OBJECTIVE_SOURCE_NOT_SUPPORTING',
             'output': {'contract_version': 'bdj-objective-proposal/2',
                        'recommendations': [_rec(d, source_refs=[_ref(d, 'M2V2-03')],
                                                 business_uncertainty='Service format may be wrong.')]}},
        ],
    })

    # 4. A gap customers cannot answer. Suitability must say so.
    d = _with({'M2V2-06': 'UNDECIDED'}, 'bdj-unsuitable')
    cases.append({
        'id': 'bdj_unsuitable_for_customers', 'split': 'heldout',
        'intent': 'The undecided item is a cost/funding decision. A customer cannot '
                  'report it, so proposing it as a customer-research gap is wrong.',
        'declarations': d,
        'expected': {'suitability': 'NOT_SUITABLE', 'status': 'must not be MOST_SUGGESTED '
                                                              'with a customer construct'},
        'golden_output': {'contract_version': 'bdj-objective-proposal/2',
                          'recommendations': []},
        'negatives': [
            {'label': 'unsuitable construct proposed as a customer gap',
             'expect_code': 'BDJ_V2_UNSUITABLE_PROPOSED_AS_GAP',
             'output': {'contract_version': 'bdj-objective-proposal/2',
                        'recommendations': [_rec(
                            d, source_refs=[_ref(d, 'M2V2-06')],
                            customer_research_suitability='NOT_SUITABLE - a customer cannot '
                                                          'report the funding position.',
                            business_uncertainty='The funding ceiling is undecided.')]}},
        ],
    })

    # 5. Duplicate trap: two items point at the same construct.
    d = _with({'M2V2-11': 'EXPLORE',
               'M2V2-18': {'hypothesis_status': 'HYPOTHESIS_IDENTIFIED',
                           'hypothesis_text': 'Customers will accept RM16.00.'}}, 'bdj-dup')
    dup_rec = _rec(d, source_refs=[_ref(d, 'M2V2-11')])
    cases.append({
        'id': 'bdj_duplicate_construct', 'split': 'heldout',
        'intent': 'Two proposals measure the same construct on the same source. '
                  'Only one may survive.',
        'declarations': d,
        'expected': {'recommendations': 'exactly one', 'dedupe_on': 'construct + source'},
        'golden_output': {'contract_version': 'bdj-objective-proposal/2',
                          'recommendations': [dup_rec]},
        'negatives': [
            {'label': 'same construct, same source, twice',
             'expect_code': 'BDJ_V2_DUPLICATE_CONSTRUCT',
             'output': {'contract_version': 'bdj-objective-proposal/2',
                        'recommendations': [dup_rec, copy.deepcopy(dup_rec)]}},
        ],
    })

    # 6. Conflicting declarations: EXPLORE paired with NOT_ESTABLISHED.
    d = _with({'M2V2-11': 'EXPLORE',
               'M2V2-18': {'hypothesis_status': 'NOT_ESTABLISHED',
                           'hypothesis_text': ''}}, 'bdj-conflict')
    cases.append({
        'id': 'bdj_conflicting_declarations', 'split': 'heldout',
        'intent': 'An exploration priority sits beside a hypothesis explicitly not '
                  'established. Citing the hypothesis as an established gap is wrong.',
        'declarations': d,
        'expected': {'must_not_cite': ['M2V2-18'], 'may_cite': ['M2V2-11']},
        'golden_output': {'contract_version': 'bdj-objective-proposal/2',
                          'recommendations': [_rec(
                              d, source_refs=[_ref(d, 'M2V2-11')],
                              business_uncertainty='The entrepreneur has declared a validation '
                                                   'requirement but no hypothesis to test.')]},
        'negatives': [
            {'label': 'cites NOT_ESTABLISHED as an established gap',
             'expect_code': 'BDJ_OBJECTIVE_SOURCE_NOT_SUPPORTING',
             'output': {'contract_version': 'bdj-objective-proposal/2',
                        'recommendations': [_rec(d, source_refs=[_ref(d, 'M2V2-18')])]}},
        ],
    })

    return cases


# ---------------------------------------------------------------------------
# Direct-QG cases
# ---------------------------------------------------------------------------

def _facts(**overrides) -> dict:
    base = {
        'contract_version': 'P1-QG-CONTRACT-2.0',
        'assessment_id': _uuid('qg-assessment'),
        'objective_id': _uuid('qg-objective'),
        'objective_text': 'Whether prospective customers would accept RM13 for a 12 oz '
                          'takeaway iced latte.',
        'uncertainty_id': _uuid('qg-objective'),
        'uncertainty_version': _uuid('qg-version'),
        'uncertainty_text': 'Whether prospective customers would accept RM13 for a 12 oz '
                            'takeaway iced latte.',
        'bcb_version': 'business-context-package/1.1',
        'context_hash': 'a' * 64,
        'm2_answer_revision_ids': [_uuid('m2rev')],
        'bdj_findings': [],
        'confirmed_offers': ['12 oz', 'takeaway', 'iced'],
        'confirmed_numbers': ['12', '13'],
        'confirmed_currency': ['RM13'],
        'source_refs': [_uuid('qg-objective')],
    }
    base.update(overrides)
    return base


def _qg_draft(**overrides) -> dict:
    base = {
        'decision': 'DRAFT',
        'question': 'If a cafe offered a 12 oz takeaway iced latte at RM13, how would you '
                    'describe that price?',
        'justification': 'The confirmed facts name one exact priced offer, so a single-select '
                         'acceptability item can measure it.',
        # `construct_interpretation` is scanned by the production validator for
        # prohibited phrases, so the disclaimer cannot use the phrase it is
        # disclaiming. See DEF-02 in DEFECTS_FOUND_20261125.md.
        'construct_interpretation': 'Measures stated acceptability of one exact priced offer; '
                                    'it does not measure any ceiling on what a respondent '
                                    'would pay.',
        'response_options': ['Acceptable', 'Not acceptable', "Don't know",
                             'Prefer not to answer'],
        'response_codes': ['ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW', 'REFUSED'],
        'routing': {'ACCEPTABLE': 'END', 'NOT_ACCEPTABLE': 'END',
                    'DONT_KNOW': 'END', 'REFUSED': 'END'},
        'reference_period': 'At the moment the offer is shown.',
        'measurement_description': 'Single-select acceptability of the stated offer.',
        'denominator_specification': 'Codes ACCEPTABLE and NOT_ACCEPTABLE are in the '
                                     'denominator; codes DONT_KNOW and REFUSED are reported '
                                     'separately.',
        'limitations': 'Stated acceptability of one hypothetical price is not a purchase '
                       'forecast.',
        'unresolved_assumptions': [],
        'missing_business_facts': [],
        'used_confirmed_facts': ['RM13', '12'],
    }
    base.update(overrides)
    return base


def _measurement(**overrides) -> dict:
    base = {
        'contract_version': 'P1-QG-FIXED-OPTION-1.0',
        'response_format': 'SINGLE_CHOICE',
        'construct': 'STATED_PRICE_ACCEPTABILITY_FIXED_HYPOTHETICAL_OFFER',
        'population': 'Eligible respondents screened by the approved eligibility routing.',
        'reference_period': 'At the moment the offer is shown.',
        'options': [
            {'code': 'ACCEPTABLE', 'label': 'Acceptable', 'order': 0},
            {'code': 'NOT_ACCEPTABLE', 'label': 'Not acceptable', 'order': 1},
            {'code': 'DONT_KNOW', 'label': "Don't know", 'order': 2},
            {'code': 'REFUSED', 'label': 'Prefer not to answer', 'order': 3},
        ],
        'min_selections': 1, 'max_selections': 1, 'exclusive_codes': [],
        'interpretation': 'Stated acceptability of the exact stated offer.',
        'limitations': 'Not a maximum willingness to pay and not a purchase forecast.',
        'unit': '',
    }
    base.update(overrides)
    return base


def qg_cases() -> list[dict]:
    cases = []

    cases.append({
        'id': 'qg_complete_offer', 'split': 'dev',
        'intent': 'Every mandatory fact is present. A DRAFT single-select question is '
                  'expected, with four complete options and an explicit opt-out.',
        'facts': _facts(),
        'expected': {'decision': 'DRAFT', 'response_format': 'SINGLE_CHOICE',
                     'options': '2-12, codes and labels unique, order 0..n-1',
                     'routing': 'keyed by exact codes, every value END',
                     'denominator': 'names the declared codes'},
        'golden_output': {**_qg_draft(), 'fixed_measurement': _measurement()},
        'negatives': [
            {'label': 'routing keyed by labels instead of codes',
             'expect_code': 'QG_ROUTING_DRIFT',
             'output': {**_qg_draft(routing={'acceptable': 'END', 'not_acceptable': 'END',
                                             'dont_know': 'END', 'refused': 'END'}),
                        'fixed_measurement': _measurement()}},
            {'label': 'denominator names no code',
             'expect_code': 'QG_DENOMINATOR_DRIFT',
             'output': {**_qg_draft(denominator_specification='All respondents who select an '
                                                            'option.'),
                        'fixed_measurement': _measurement()}},
            # The number check runs before the currency check, and "15" is an
            # unconfirmed number, so this is the code that actually fires.
            {'label': 'invents a price not in confirmed facts',
             'expect_code': 'QG_UNSOURCED_NUMBER',
             'output': {**_qg_draft(question='Would you pay RM15 for a 12 oz takeaway iced '
                                             'latte?'),
                        'fixed_measurement': _measurement()}},
            {'label': 'abstention that still contains a question',
             'expect_code': 'QG_ABSTENTION_CONTAINS_QUESTION',
             'output': _qg_draft(decision='ABSTAIN_NEEDS_REVIEW',
                                 missing_business_facts=['PRICE'])},
            {'label': 'measurement options disagree with response_codes',
             'expect_code': 'QG_FIXED_OPTION_MISMATCH',
             'output': {**_qg_draft(),
                        'fixed_measurement': _measurement(options=[
                            {'code': 'A', 'label': 'Acceptable', 'order': 0},
                            {'code': 'B', 'label': 'Not acceptable', 'order': 1},
                            {'code': 'C', 'label': "Don't know", 'order': 2},
                            {'code': 'D', 'label': 'Prefer not to answer', 'order': 3}])}},
        ],
    })

    cases.append({
        'id': 'qg_missing_price', 'split': 'dev',
        'intent': 'The objective needs a price that was never confirmed. The correct '
                  'answer is a justified abstention naming PRICE, with no draft.',
        'facts': _facts(confirmed_currency=[], confirmed_numbers=['12'],
                        uncertainty_text='Whether prospective customers would accept the '
                                         'proposed price for a 12 oz takeaway iced latte.',
                        objective_text='Whether prospective customers would accept the '
                                       'proposed price for a 12 oz takeaway iced latte.'),
        'expected': {'decision': 'ABSTAIN_NEEDS_REVIEW', 'question': 'empty',
                     'missing_business_facts': 'includes PRICE', 'fixed_measurement': 'null'},
        'golden_output': {'decision': 'ABSTAIN_NEEDS_REVIEW', 'question': '',
                          'justification': 'The offer price is not among the confirmed facts, '
                                           'so no exact priced offer can be shown.',
                          'construct_interpretation': '', 'response_options': [],
                          'response_codes': [], 'routing': {}, 'reference_period': '',
                          'measurement_description': '', 'denominator_specification': '',
                          'limitations': '', 'unresolved_assumptions': [],
                          'missing_business_facts': ['PRICE'], 'used_confirmed_facts': [],
                          'fixed_measurement': None},
        'negatives': [
            {'label': 'drafts a question anyway',
             'expect_code': 'QG_ABSTENTION_CONTAINS_QUESTION',
             'output': {**_qg_draft(decision='ABSTAIN_NEEDS_REVIEW',
                                    missing_business_facts=['PRICE']),
                        'fixed_measurement': None}},
            {'label': 'abstains with nothing missing',
             'expect_code': 'QG_ABSTENTION_WITHOUT_MISSING_FACTS',
             'output': {'decision': 'ABSTAIN_NEEDS_REVIEW', 'question': '',
                        'justification': 'Cannot draft.', 'missing_business_facts': [],
                        'fixed_measurement': None}},
        ],
    })

    cases.append({
        'id': 'qg_ambiguous_measurement', 'split': 'heldout',
        'intent': 'The objective asks why customers behave a certain way. A fixed-option '
                  'question cannot measure it; the correct answer is abstention on '
                  'OBJECTIVE, not a fabricated closed question.',
        'facts': _facts(objective_text='Why prospective customers choose one cafe over '
                                       'another.',
                        uncertainty_text='Why prospective customers choose one cafe over '
                                         'another.'),
        'expected': {'decision': 'ABSTAIN_NEEDS_REVIEW',
                     'missing_business_facts': 'includes OBJECTIVE'},
        'golden_output': {'decision': 'ABSTAIN_NEEDS_REVIEW', 'question': '',
                          'justification': 'An open causal question cannot be measured with a '
                                           'closed option set, and the objective does not name '
                                           'a measurable construct.',
                          'construct_interpretation': '', 'response_options': [],
                          'response_codes': [], 'routing': {}, 'reference_period': '',
                          'measurement_description': '', 'denominator_specification': '',
                          'limitations': '', 'unresolved_assumptions': [],
                          'missing_business_facts': ['OBJECTIVE'], 'used_confirmed_facts': [],
                          'fixed_measurement': None},
        'negatives': [
            {'label': 'forces a closed question onto an open causal objective',
             'expect_code': 'QG_UNSOURCED_NUMBER',
             'output': {**_qg_draft(question='Which of 5 reasons best explains your choice?',
                                    used_confirmed_facts=['RM13']),
                        'fixed_measurement': _measurement()}},
        ],
    })

    cases.append({
        'id': 'qg_binary_format', 'split': 'heldout',
        'intent': 'A binary choice must carry exactly two options and both codes in the '
                  'routing and the denominator.',
        'facts': _facts(objective_text='Whether prospective customers would consider buying '
                                       'a 12 oz takeaway iced latte at RM13.',
                        uncertainty_text='Whether prospective customers would consider buying '
                                         'a 12 oz takeaway iced latte at RM13.'),
        'expected': {'decision': 'DRAFT', 'response_format': 'BINARY_CHOICE',
                     'options': 'exactly 2'},
        'golden_output': {
            **_qg_draft(question='Would you consider buying a 12 oz takeaway iced latte at '
                                 'RM13?',
                        response_options=['Yes', 'No'],
                        response_codes=['YES', 'NO'],
                        routing={'YES': 'END', 'NO': 'END'},
                        denominator_specification='Codes YES and NO are in the denominator; no '
                                                  'codes are excluded.',
                        used_confirmed_facts=['RM13', '12']),
            'fixed_measurement': _measurement(
                response_format='BINARY_CHOICE',
                options=[{'code': 'YES', 'label': 'Yes', 'order': 0},
                         {'code': 'NO', 'label': 'No', 'order': 1}])},
        'negatives': [
            {'label': 'binary choice with four options',
             'expect_code': 'QG_BINARY_OPTION_COUNT_INVALID',
             'output': {**_qg_draft(response_options=['Yes', 'No', "Don't know", 'Refused'],
                                    response_codes=['YES', 'NO', 'DONT_KNOW', 'REFUSED'],
                                    routing={'YES': 'END', 'NO': 'END',
                                             'DONT_KNOW': 'END', 'REFUSED': 'END'}),
                        'fixed_measurement': _measurement(
                            response_format='BINARY_CHOICE',
                            options=[{'code': 'YES', 'label': 'Yes', 'order': 0},
                                     {'code': 'NO', 'label': 'No', 'order': 1},
                                     {'code': 'DONT_KNOW', 'label': "Don't know", 'order': 2},
                                     {'code': 'REFUSED', 'label': 'Refused', 'order': 3}])}},
        ],
    })

    cases.append({
        'id': 'qg_unsourced_offer_component', 'split': 'heldout',
        'intent': 'A size that was never confirmed must not appear in the question, even '
                  'when it is plausible.',
        'facts': _facts(),
        'expected': {'decision': 'DRAFT or ABSTAIN', 'must_not_contain': '16 oz'},
        'golden_output': {**_qg_draft(), 'fixed_measurement': _measurement()},
        'negatives': [
            {'label': 'invents a package size',
             'expect_code': 'QG_UNSOURCED_NUMBER',
             'output': {**_qg_draft(question='Would you accept RM13 for a 16 oz takeaway iced '
                                             'latte?'),
                        'fixed_measurement': _measurement()}},
        ],
    })

    return cases


def all_cases() -> dict[str, list[dict]]:
    return {'bdj': bdj_cases(), 'qg': qg_cases()}


if __name__ == '__main__':
    import json
    cases = all_cases()
    for family, items in cases.items():
        print(f'{family}: {len(items)} cases '
              f'(dev={sum(1 for c in items if c["split"] == "dev")}, '
              f'heldout={sum(1 for c in items if c["split"] == "heldout")}, '
              f'negatives={sum(len(c["negatives"]) for c in items)})')
    print(json.dumps({c['id']: c['split'] for f in cases.values() for c in f}, indent=2))
