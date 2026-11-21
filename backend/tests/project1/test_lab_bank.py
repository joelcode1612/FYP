"""BD-01 and BD-02 as executable rules, in isolation from any database.

BD-01 (reuse): an equivalent must rest on an approved item with a retained,
verifiable, context-bound receipt. "It is equivalent" is not evidence.

BD-02 (no-equivalent): an empty or partially reviewed bank cannot authorise a new
question. A search that found nothing and a complete review that concluded
nothing are different claims, and only the second is a receipt.

These tests use the test-only ``lab_bank`` double. Passing them proves the *rules*
are implemented and reachable; it proves nothing about a production bank, which
is BD-01 Option B and remains unapplied.
"""
from __future__ import annotations

import copy

import pytest

from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.measurement_policy import LAB_PRICE_RM13_POLICY, lab_authority

from lab_bank import LabBank, approved_item, snapshot

UNCERTAINTY_ID = 'a1b2c3d4-0000-4000-8000-000000000000'
CONFIRMATION_ID = 'b2c3d4e5-0000-4000-8000-000000000000'


def packet():
    value = {'confirmation': {'status': 'CURRENT_CONFIRMED', 'id': CONFIRMATION_ID,
                              'revision': 1},
             'confirmed_uncertainty': {
                 'id': UNCERTAINTY_ID, 'confirmation_id': CONFIRMATION_ID,
                 'exact_text': ('Would eligible customers find RM13 acceptable for a '
                                '12 oz takeaway iced latte?')},
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


def held(code: str, function) -> None:
    with pytest.raises(WorkflowHeld) as caught:
        function()
    assert str(caught.value) == code


def comparison(verdict=True, items=('LAB-APPROVED-V1',)):
    return {digest(measurement()): {item: verdict for item in items}}


# ---------------------------------------------------------------------------
# BD-01 — reuse needs an approved, receipted, context-bound item
# ---------------------------------------------------------------------------
def test_bd01_verified_equivalent_reuse():
    bank = LabBank(catalogue=snapshot(items=[approved_item()]),
                   comparisons=comparison(True))
    lookup = bank.lookup(measurement(), packet())
    assert lookup['outcome'] == 'verified_equivalent'
    assert lookup['item_version'] == 'LAB-APPROVED-V1'
    assert lookup['approval_receipt'] == 'LAB-APPROVAL-NOT-REAL'
    bank.verify_receipt(lookup, digest(measurement()), packet())


def test_bd01_an_unapproved_item_cannot_be_reused():
    item = approved_item()
    item['test_approved'] = False
    held('BD01_ITEM_APPROVAL_NOT_VERIFIED',
         lambda: LabBank(catalogue=snapshot(items=[item]),
                         comparisons=comparison(True)).lookup(measurement(), packet()))


def test_bd01_an_item_without_an_approval_receipt_cannot_be_reused():
    item = approved_item()
    item['approval_receipt'] = ''
    held('BD01_ITEM_APPROVAL_NOT_VERIFIED',
         lambda: LabBank(catalogue=snapshot(items=[item]),
                         comparisons=comparison(True)).lookup(measurement(), packet()))


def test_bd01_a_tampered_receipt_is_refused():
    bank = LabBank(catalogue=snapshot(items=[approved_item()]),
                   comparisons=comparison(True))
    lookup = bank.lookup(measurement(), packet())
    lookup['packet_hash'] = 'tampered'
    held('BD01_RECEIPT_TAMPERED',
         lambda: bank.verify_receipt(lookup, digest(measurement()), packet()))


def test_bd01_a_replayed_receipt_for_another_context_is_refused():
    bank = LabBank(catalogue=snapshot(items=[approved_item()]),
                   comparisons=comparison(True))
    lookup = bank.lookup(measurement(), packet())
    other = copy.deepcopy(packet())
    other['m2_answers'][0]['item_key'] = 'M2-05'
    other.pop('packet_hash')
    other['packet_hash'] = digest(other)
    held('BD01_RECEIPT_CONTEXT_MISMATCH',
         lambda: bank.verify_receipt(lookup, digest(measurement()), other))


def test_bd01_a_receipt_for_another_measurement_is_refused():
    bank = LabBank(catalogue=snapshot(items=[approved_item()]),
                   comparisons=comparison(True))
    lookup = bank.lookup(measurement(), packet())
    held('BD01_RECEIPT_CONTEXT_MISMATCH',
         lambda: bank.verify_receipt(lookup, digest(measurement(stimulus='other')),
                                     packet()))


def test_bd01_a_receipt_this_bank_never_issued_is_refused():
    bank = LabBank(catalogue=snapshot(items=[approved_item()]),
                   comparisons=comparison(True))
    lookup = bank.lookup(measurement(), packet())
    forged = dict(lookup, receipt_id=digest({'forged': True}))
    held('BD01_RECEIPT_NOT_ISSUED',
         lambda: bank.verify_receipt(forged, digest(measurement()), packet()))


def test_bd01_no_bank_at_all_is_unverified():
    held('BANK_AUTHORITY_UNVERIFIED',
         lambda: LabBank(catalogue=None).lookup(measurement(), packet()))


def test_bd01_a_draft_snapshot_is_not_an_accepted_catalogue():
    held('BANK_AUTHORITY_UNVERIFIED',
         lambda: LabBank(catalogue=snapshot(items=[approved_item()], status='DRAFT'),
                         comparisons=comparison(True)).lookup(measurement(), packet()))


# ---------------------------------------------------------------------------
# BD-02 — an empty bank cannot prove no-equivalent
# ---------------------------------------------------------------------------
def test_bd02_an_empty_bank_cannot_issue_no_equivalent():
    held('BD02_EMPTY_BANK_CANNOT_PROVE_NO_EQUIVALENT',
         lambda: LabBank(catalogue=snapshot(items=[], bd02_policy_accepted=True),
                         comparisons={digest(measurement()): {}})
         .lookup(measurement(), packet()))


def test_bd02_verified_no_equivalent_requires_a_complete_comparison():
    held('BD02_COMPLETE_HUMAN_COMPARISON_REQUIRED',
         lambda: LabBank(catalogue=snapshot(items=[approved_item()],
                                            bd02_policy_accepted=True),
                         comparisons={}).lookup(measurement(), packet()))


def test_bd02_a_partial_comparison_is_not_a_complete_one():
    two_items = [approved_item(item_version='LAB-APPROVED-V1'),
                 approved_item(item_version='LAB-APPROVED-V2')]
    held('BD02_COMPLETE_HUMAN_COMPARISON_REQUIRED',
         lambda: LabBank(catalogue=snapshot(items=two_items, bd02_policy_accepted=True),
                         comparisons=comparison(False, ('LAB-APPROVED-V1',)))
         .lookup(measurement(), packet()))


def test_bd02_a_non_boolean_verdict_is_refused():
    held('BD02_COMPLETE_HUMAN_COMPARISON_REQUIRED',
         lambda: LabBank(catalogue=snapshot(items=[approved_item()],
                                            bd02_policy_accepted=True),
                         comparisons={digest(measurement()): {'LAB-APPROVED-V1': 'yes'}})
         .lookup(measurement(), packet()))


def test_bd02_no_equivalent_needs_an_accepted_policy_and_issuer():
    held('BD02_POLICY_OR_ISSUER_UNAUTHORIZED',
         lambda: LabBank(catalogue=snapshot(items=[approved_item()],
                                            bd02_policy_accepted=False),
                         comparisons=comparison(False)).lookup(measurement(), packet()))


def test_bd02_verified_no_equivalent_receipt():
    bank = LabBank(catalogue=snapshot(items=[approved_item()],
                                      bd02_policy_accepted=True,
                                      independent_comparison_issuer='TEST-REVIEWER'),
                   comparisons=comparison(False))
    lookup = bank.lookup(measurement(), packet())
    assert lookup['outcome'] == 'verified_no_equivalent'
    assert 'item_version' not in lookup
    bank.verify_receipt(lookup, digest(measurement()), packet())


def test_bd02_two_equivalents_are_ambiguous_not_reusable():
    two_items = [approved_item(item_version='LAB-APPROVED-V1'),
                 approved_item(item_version='LAB-APPROVED-V2')]
    held('BD02_AMBIGUOUS_EQUIVALENCE',
         lambda: LabBank(catalogue=snapshot(items=two_items, bd02_policy_accepted=True),
                         comparisons=comparison(True, ('LAB-APPROVED-V1', 'LAB-APPROVED-V2')))
         .lookup(measurement(), packet()))


# ---------------------------------------------------------------------------
# The two rules composed: a no-equivalent receipt is what admits a QG draft
# ---------------------------------------------------------------------------
def test_a_no_equivalent_receipt_admits_drafting_but_never_fielding():
    authority = lab_authority(LAB_PRICE_RM13_POLICY)
    task = authority.admit_qj(packet())
    receipt = authority.validate_measurement(packet(), task, measurement())
    bank = LabBank(catalogue=snapshot(items=[approved_item()],
                                      bd02_policy_accepted=True,
                                      independent_comparison_issuer='TEST-REVIEWER'),
                   comparisons=comparison(False))
    lookup = bank.lookup(measurement(), packet())
    drafting = authority.require_drafting(packet(), task, lookup)
    assert drafting['status'] == 'DRAFTING_RESEARCH_ONLY'
    assert drafting['fielding_authorized'] is False
    assert receipt['production_eligible'] is False


def test_an_equivalent_receipt_does_not_admit_drafting():
    authority = lab_authority(LAB_PRICE_RM13_POLICY)
    task = authority.admit_qj(packet())
    bank = LabBank(catalogue=snapshot(items=[approved_item()]),
                   comparisons=comparison(True))
    lookup = bank.lookup(measurement(), packet())
    held('QG_NO_EQUIVALENT_RECEIPT_REQUIRED',
         lambda: authority.require_drafting(packet(), task, lookup))
