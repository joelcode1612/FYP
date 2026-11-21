"""BD-01 reuse and BD-02 no-equivalent as executable rules of the real bank.

These tests drive ``sitewise.project1.question_bank.QuestionBank`` -- the
production decision layer -- through ``InMemoryQuestionBankStore``. The store is a
test double and says so; the *rules* under test are the production ones, which is
the difference between this module and ``test_lab_bank.py`` (which tests a double
against itself).

Every negative case asserts the exact refusal code, because a test that only
asserts "it raised" cannot tell ``BD02_EMPTY_BANK_CANNOT_PROVE_NO_EQUIVALENT``
from ``BD02_COMPLETE_HUMAN_COMPARISON_REQUIRED`` -- and those two codes are the
whole distinction between "nothing found" and "nothing exists".
"""
from __future__ import annotations

import ast
import copy
import re
from pathlib import Path

import pytest

from sitewise.project1 import question_bank
from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.measurement_policy import lab_authority
from sitewise.project1.question_bank import (BD02_POLICIES, LAB_SCOPE, QuestionBank,
                                             InMemoryQuestionBankStore)

POLICY = 'BD02-EQUIVALENCE-1.0'
SNAPSHOT_ID = '11111111-1111-4111-8111-111111111111'
UNCERTAINTY_ID = 'a1b2c3d4-0000-4000-8000-000000000000'
CONFIRMATION_ID = 'b2c3d4e5-0000-4000-8000-000000000000'
OWNER = 'c3d4e5f6-0000-4000-8000-000000000000'


def packet():
    value = {'confirmation': {'status': 'CURRENT_CONFIRMED', 'id': CONFIRMATION_ID,
                              'revision': 1},
             'confirmed_uncertainty': {
                 'id': UNCERTAINTY_ID, 'confirmation_id': CONFIRMATION_ID,
                 'exact_text': ('Would eligible customers find RM13 acceptable for a '
                                '12 oz takeaway iced latte?')},
             'identity': {'assessment_id': 'd4e5f6a7-0000-4000-8000-000000000000',
                          'tenant_id': 'm2-owner:' + OWNER, 'owner_id': OWNER},
             'geography': None, 'permissions': {'qj_execution': False},
             'm2_answers': [{'answer_revision_id': 'SYN-A1', 'item_key': 'M2-04'}],
             'supporting_sources': []}
    value['packet_hash'] = digest(value)
    return value


def measurement(**overrides):
    value = dict(
        uncertainty_version=UNCERTAINTY_ID,
        construct=('Hypothetical stated acceptability of RM13 for an exactly described '
                   '12 oz takeaway iced latte'),
        population=('Synthetic eligible respondents flagged synthetic_eligibility=true in '
                    'a disposable test cluster; no real sampling frame is authorized'),
        timeframe=('Judgment at the moment the respondent views the hypothetical offer; '
                   'no future purchase window is inferred'),
        stimulus='Hypothetical offer: a 12 oz takeaway iced latte priced at RM13.',
        response_options=['Acceptable', 'Not acceptable', "Don't know",
                          'Prefer not to answer'],
        response_codes=['ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW', 'REFUSED'],
        routing={code: 'END' for code in
                 ('ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW', 'REFUSED')},
        denominator=('Count of eligible in-scope respondents answering ACCEPTABLE or '
                     'NOT_ACCEPTABLE; DONT_KNOW, REFUSED, SKIPPED, NOT_APPLICABLE, MISSING '
                     'and INVALID excluded and reported separately'),
        source_refs=[UNCERTAINTY_ID],
        limitations=('Sample-descriptive only. Not a demand, willingness-to-pay, sales, '
                     'profitability or GEO estimate.'))
    value.update(overrides)
    return value


def snapshot(**overrides):
    value = {'snapshot_id': SNAPSHOT_ID, 'snapshot_version': 'LAB-SNAP-1',
             'scope_contract': LAB_SCOPE, 'comparison_policy_version': POLICY,
             'catalogue_sha256': 'a' * 64, 'state': 'ACCEPTED',
             'acceptor_id': 'LAB-ACCEPTOR'}
    value.update(overrides)
    return value


def item(item_version='LAB-APPROVED-V1', approval_state='APPROVED',
         approval_receipt='LAB-APPROVAL-1', owner_approver_id='LAB-OWNER'):
    return {'item_version_id': item_version, 'approval_state': approval_state,
            'approval_receipt': approval_receipt,
            'owner_approver_id': owner_approver_id}


def comparison(reviews, *, issuer_id='LAB-REVIEWER',
               attestation='I compared every item and attest to this verdict.',
               policy=POLICY):
    return {'issuer_id': issuer_id, 'issuer_attestation': attestation,
            'policy_version': policy, 'reviews': reviews}


_UNSET = object()


def bank(*, snapshot_value=_UNSET, items=None, comparisons=None, policy=POLICY,
         scope=LAB_SCOPE):
    """A QuestionBank over the in-memory store, with a passing default catalogue."""
    if items is None:
        items = [item()]
    if comparisons is None:
        comparisons = {digest(measurement()): comparison({'LAB-APPROVED-V1': True})}
    store = InMemoryQuestionBankStore(
        snapshot=snapshot() if snapshot_value is _UNSET else snapshot_value,
        items=items, comparisons=comparisons)
    return QuestionBank(store, policy_version=policy, scope_contract=scope)


def held(code: str, function) -> None:
    with pytest.raises(WorkflowHeld) as caught:
        function()
    assert str(caught.value) == code


# ---------------------------------------------------------------------------
# Rule 6 -- exactly one equivalent item: reuse, bound to its approval
# ---------------------------------------------------------------------------
def test_rule6_equivalent_reuse_returns_item_version_and_approval_receipt():
    lookup = bank().lookup(measurement(), packet())
    assert lookup['outcome'] == 'verified_equivalent'
    assert lookup['decision'] == 'EQUIVALENT'
    assert lookup['item_version'] == 'LAB-APPROVED-V1'
    assert lookup['approval_receipt'] == 'LAB-APPROVAL-1'
    assert lookup['scope'] == LAB_SCOPE


def test_rule6_equivalent_receipt_is_bound_to_the_packet_and_measurement():
    lookup = bank().lookup(measurement(), packet())
    assert lookup['measurement_digest'] == digest(measurement())
    assert lookup['bcb_packet_hash'] == packet()['packet_hash']
    assert lookup['objective_id'] == UNCERTAINTY_ID
    assert lookup['source_confirmation_id'] == CONFIRMATION_ID
    assert lookup['snapshot_version'] == 'LAB-SNAP-1'
    assert lookup['comparison_policy_version'] == POLICY
    assert lookup['receipt_id'] == digest(
        {key: lookup[key] for key in question_bank.BODY_KEYS})


# ---------------------------------------------------------------------------
# Rule 7 -- zero equivalents needs an accepted policy and an independent issuer
# ---------------------------------------------------------------------------
def test_rule7_no_equivalent_with_accepted_policy_and_independent_issuer():
    lookup = bank(comparisons={digest(measurement()): comparison(
        {'LAB-APPROVED-V1': False})}).lookup(measurement(), packet())
    assert lookup['outcome'] == 'verified_no_equivalent'
    assert lookup['decision'] == 'NO_EQUIVALENT'
    assert lookup['item_version'] is None and lookup['approval_receipt'] is None
    assert lookup['scope'] == LAB_SCOPE


def test_rule7_no_equivalent_without_an_accepted_policy_is_refused():
    held('BD02_POLICY_OR_ISSUER_UNAUTHORIZED',
         lambda: bank(snapshot_value=snapshot(comparison_policy_version='UNACCEPTED-0.1'),
                      policy='UNACCEPTED-0.1',
                      comparisons={digest(measurement()): comparison(
                          {'LAB-APPROVED-V1': False}, policy='UNACCEPTED-0.1')})
         .lookup(measurement(), packet()))


def test_rule7_no_equivalent_issuer_must_be_independent_of_the_item_approver():
    # The person who approved the item cannot also be the person who rules that
    # the catalogue contains nothing equivalent to it.
    held('BD02_POLICY_OR_ISSUER_UNAUTHORIZED',
         lambda: bank(comparisons={digest(measurement()): comparison(
             {'LAB-APPROVED-V1': False}, issuer_id='LAB-OWNER')})
         .lookup(measurement(), packet()))


def test_rule7_no_equivalent_without_an_attested_issuer_is_refused():
    held('BANK_AUTHORITY_UNVERIFIED',
         lambda: bank(comparisons={digest(measurement()): comparison(
             {'LAB-APPROVED-V1': False}, attestation='  ')})
         .lookup(measurement(), packet()))


# ---------------------------------------------------------------------------
# Rule 1 -- no accepted snapshot / no issuer / no version
# ---------------------------------------------------------------------------
def test_rule1_no_accepted_snapshot_is_unverified():
    held('BANK_AUTHORITY_UNVERIFIED',
         lambda: bank(snapshot_value=None).lookup(measurement(), packet()))


def test_rule1_a_draft_snapshot_is_unverified():
    held('BANK_AUTHORITY_UNVERIFIED',
         lambda: bank(snapshot_value=snapshot(state='DRAFT')).lookup(measurement(),
                                                                    packet()))


def test_rule1_a_snapshot_without_an_acceptor_is_unverified():
    held('BANK_AUTHORITY_UNVERIFIED',
         lambda: bank(snapshot_value=snapshot(acceptor_id='')).lookup(measurement(),
                                                                     packet()))


def test_rule1_a_snapshot_accepted_under_another_scope_is_unverified():
    held('BANK_AUTHORITY_UNVERIFIED',
         lambda: bank(snapshot_value=snapshot(scope_contract='PRODUCTION')).lookup(
             measurement(), packet()))


# ---------------------------------------------------------------------------
# Rule 2 -- an empty bank cannot prove no-equivalent
# ---------------------------------------------------------------------------
def test_rule2_an_empty_bank_cannot_issue_no_equivalent():
    held('BD02_EMPTY_BANK_CANNOT_PROVE_NO_EQUIVALENT',
         lambda: bank(items=[], comparisons={digest(measurement()): comparison({})})
         .lookup(measurement(), packet()))


# ---------------------------------------------------------------------------
# Rule 3 -- every item must be approved, with its approval receipt
# ---------------------------------------------------------------------------
def test_rule3_a_candidate_item_is_refused():
    # A QG draft has no approval state at all; the view reports CANDIDATE.
    held('BD01_ITEM_APPROVAL_NOT_VERIFIED',
         lambda: bank(items=[item(approval_state='CANDIDATE')]).lookup(measurement(),
                                                                      packet()))


def test_rule3_an_item_without_an_approval_receipt_is_refused():
    held('BD01_ITEM_APPROVAL_NOT_VERIFIED',
         lambda: bank(items=[item(approval_receipt='')]).lookup(measurement(), packet()))


def test_rule3_one_unapproved_item_poisons_the_whole_snapshot():
    held('BD01_ITEM_APPROVAL_NOT_VERIFIED',
         lambda: bank(items=[item('LAB-APPROVED-V1'),
                             item('LAB-APPROVED-V2', approval_state='INDEPENDENTLY_REVIEWED')],
                      comparisons={digest(measurement()): comparison(
                          {'LAB-APPROVED-V1': True, 'LAB-APPROVED-V2': False})})
         .lookup(measurement(), packet()))


# ---------------------------------------------------------------------------
# Rule 4 -- the review set must cover every item with real booleans
# ---------------------------------------------------------------------------
def test_rule4_no_comparison_at_all_is_refused():
    held('BD02_COMPLETE_HUMAN_COMPARISON_REQUIRED',
         lambda: bank(comparisons={}).lookup(measurement(), packet()))


def test_rule4_a_partial_comparison_is_refused():
    held('BD02_COMPLETE_HUMAN_COMPARISON_REQUIRED',
         lambda: bank(items=[item('LAB-APPROVED-V1'), item('LAB-APPROVED-V2')],
                      comparisons={digest(measurement()): comparison(
                          {'LAB-APPROVED-V1': False})})
         .lookup(measurement(), packet()))


def test_rule4_a_non_boolean_verdict_is_refused():
    held('BD02_COMPLETE_HUMAN_COMPARISON_REQUIRED',
         lambda: bank(comparisons={digest(measurement()): comparison(
             {'LAB-APPROVED-V1': 'yes'})}).lookup(measurement(), packet()))


def test_rule4_a_verdict_on_an_item_outside_the_snapshot_is_refused():
    held('BD02_COMPLETE_HUMAN_COMPARISON_REQUIRED',
         lambda: bank(comparisons={digest(measurement()): comparison(
             {'LAB-APPROVED-V1': False, 'NOT-IN-CATALOGUE': False})})
         .lookup(measurement(), packet()))


# ---------------------------------------------------------------------------
# Rule 5 -- two equivalents are ambiguous, not reusable
# ---------------------------------------------------------------------------
def test_rule5_two_equivalents_are_ambiguous():
    held('BD02_AMBIGUOUS_EQUIVALENCE',
         lambda: bank(items=[item('LAB-APPROVED-V1'), item('LAB-APPROVED-V2')],
                      comparisons={digest(measurement()): comparison(
                          {'LAB-APPROVED-V1': True, 'LAB-APPROVED-V2': True})})
         .lookup(measurement(), packet()))


# ---------------------------------------------------------------------------
# BD-01 verify_receipt
# ---------------------------------------------------------------------------
def test_receipt_verifies_against_the_measurement_and_packet_it_was_issued_for():
    current = bank()
    lookup = current.lookup(measurement(), packet())
    assert current.verify_receipt(lookup, digest(measurement()), packet()) is None


def test_verify_a_tampered_receipt_is_refused():
    current = bank()
    lookup = current.lookup(measurement(), packet())
    lookup['packet_hash'] = 'tampered'
    held('BD01_RECEIPT_TAMPERED',
         lambda: current.verify_receipt(lookup, digest(measurement()), packet()))


def test_verify_a_tampered_derived_outcome_is_refused():
    current = bank()
    lookup = current.lookup(measurement(), packet())
    lookup['outcome'] = 'verified_no_equivalent'
    held('BD01_RECEIPT_TAMPERED',
         lambda: current.verify_receipt(lookup, digest(measurement()), packet()))


def test_verify_a_receipt_replayed_into_another_packet_is_refused():
    current = bank()
    lookup = current.lookup(measurement(), packet())
    other = copy.deepcopy(packet())
    other['m2_answers'][0]['item_key'] = 'M2-05'
    other.pop('packet_hash')
    other['packet_hash'] = digest(other)
    held('BD01_RECEIPT_CONTEXT_MISMATCH',
         lambda: current.verify_receipt(lookup, digest(measurement()), other))


def test_verify_a_receipt_for_another_measurement_is_refused():
    current = bank()
    lookup = current.lookup(measurement(), packet())
    held('BD01_RECEIPT_CONTEXT_MISMATCH',
         lambda: current.verify_receipt(lookup, digest(measurement(stimulus='other')),
                                        packet()))


def test_verify_a_receipt_never_issued_is_refused():
    current = bank()
    lookup = current.lookup(measurement(), packet())
    forged = dict(lookup, receipt_id=digest({'forged': True}))
    held('BD01_RECEIPT_NOT_ISSUED',
         lambda: current.verify_receipt(forged, digest(measurement()), packet()))


def test_verify_a_receipt_without_an_id_is_refused():
    current = bank()
    lookup = current.lookup(measurement(), packet())
    lookup.pop('receipt_id')
    held('BD01_RECEIPT_NOT_ISSUED',
         lambda: current.verify_receipt(lookup, digest(measurement()), packet()))


def test_verify_a_receipt_from_another_bank_instance_is_refused():
    # Storage, not the lookup dict, is what makes a receipt evidence.
    issued = bank().lookup(measurement(), packet())
    held('BD01_RECEIPT_NOT_ISSUED',
         lambda: bank().verify_receipt(issued, digest(measurement()), packet()))


def test_verify_a_receipt_carrying_another_scope_is_refused():
    current = bank(snapshot_value=snapshot(scope_contract='PRODUCTION'),
                   scope='PRODUCTION')
    lookup = current.lookup(measurement(), packet())
    assert lookup['scope'] == 'PRODUCTION'
    held('BD01_SCOPE_INVALID',
         lambda: current.verify_receipt(lookup, digest(measurement()), packet()))


# ---------------------------------------------------------------------------
# The port is drop-in compatible with what research.py calls
# ---------------------------------------------------------------------------
class _Builder:
    def __init__(self, value):
        self.value = value

    def get_context(self, _request=None):
        return self.value


def _workflow(bank_instance, calls):
    """The real ResearchWorkflow, the real measurement authority, this bank."""
    from sitewise.project1.research import ResearchWorkflow

    authority = lab_authority()

    def runner(stage, _input, _output_type):
        calls.append(stage)
        if stage == 'QJ':
            return {'route': 'CUSTOMER_SURVEY_CANDIDATE',
                    'justification': 'SYNTHETIC lab fixture; not a research decision.',
                    'measurement': measurement()}
        assert stage == 'QG'
        frozen = measurement()
        return {'decision': 'DRAFT',
                'question': ' '.join((frozen['stimulus'], frozen['population'],
                                      frozen['timeframe'])),
                'measurement': frozen,
                'justification': 'Draft research question; no fielding authority.'}

    return ResearchWorkflow(_Builder(packet()), authority, bank_instance, runner)


def test_equivalent_reuse_short_circuits_qg_in_the_real_workflow():
    calls = []
    result = _workflow(bank(), calls).execute(None)
    assert calls == ['QJ']  # no QG dispatch on reuse
    assert result['bank'] == 'verified_equivalent'
    assert result['qg'] == {'decision': 'REUSE_CANDIDATE', 'item_version': 'LAB-APPROVED-V1'}
    assert result['fielding_authorized'] is False
    assert result['scientific_acceptance'] is False


def test_a_no_equivalent_receipt_is_what_dispatches_qg():
    calls = []
    result = _workflow(bank(comparisons={digest(measurement()): comparison(
        {'LAB-APPROVED-V1': False})}), calls).execute(None)
    assert calls == ['QJ', 'QG']
    assert result['bank'] == 'verified_no_equivalent'
    assert result['qg']['decision'] == 'DRAFT'
    assert result['fielding_authorized'] is False


def test_no_equivalent_receipt_admits_research_only_drafting():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    lookup = bank(comparisons={digest(measurement()): comparison(
        {'LAB-APPROVED-V1': False})}).lookup(measurement(), packet())
    drafting = authority.require_drafting(packet(), task, lookup)
    assert drafting['status'] == 'DRAFTING_RESEARCH_ONLY'
    assert drafting['candidate_only'] is True
    assert drafting['fielding_authorized'] is False
    assert drafting['scientific_acceptance'] is False


def test_equivalent_receipt_does_not_admit_drafting():
    authority = lab_authority()
    task = authority.admit_qj(packet())
    lookup = bank().lookup(measurement(), packet())
    held('QG_NO_EQUIVALENT_RECEIPT_REQUIRED',
         lambda: authority.require_drafting(packet(), task, lookup))


# ---------------------------------------------------------------------------
# The prohibitions, checked rather than asserted
# ---------------------------------------------------------------------------
def test_the_bank_reads_only_the_governed_schema():
    """Every table named in this module's SQL is in ``project1_qgb``.

    The QG candidate record (``m2_review_question_versions``) and the CQ Q01-Q13
    synthetic catalogue (``cq_successor`` / ``cq_synthetic_*``) must never be a
    source of approved items, so no statement here may name them.
    """
    source = Path(question_bank.__file__).read_text(encoding='utf-8')
    tables = set(re.findall(r'(?:FROM|JOIN|INSERT INTO)\s+([A-Za-z0-9_.]+)', source))
    assert tables, 'no SQL found: this test would pass vacuously'
    assert all(table.startswith('project1_qgb.') for table in tables), tables


def test_the_bank_does_not_import_another_question_source():
    tree = ast.parse(Path(question_bank.__file__).read_text(encoding='utf-8'))
    modules = {node.module or '' for node in ast.walk(tree)
               if isinstance(node, ast.ImportFrom)}
    modules |= {alias.name for node in ast.walk(tree)
                if isinstance(node, ast.Import) for alias in node.names}
    assert not any('cq_successor' in module or 'cq_repository' in module
                   or 'm2_repository' in module for module in modules), modules
