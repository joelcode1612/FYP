"""TEST-ONLY bank double for BD-01 and BD-02.

Why this exists
---------------
The QJ workflow calls ``bank.lookup(measurement, packet)`` and
``bank.verify_receipt(lookup, digest, packet)``, but no bank implementation
existed outside a throwaway harness. So the two rules the review raised could not
be executed, only described:

* **BD-01** — an "equivalent" reuse must rest on an *approved* item with a
  retained receipt, and the receipt must be verifiable, context-bound and
  replay-resistant. A reuse that merely asserts equivalence is a bank granting
  authority it does not have.
* **BD-02** — an empty bank cannot prove no-equivalent. "I found nothing" and
  "I searched a complete, reviewed catalogue and found nothing" are different
  claims, and only the second can authorise a new question.

This module is a test double and says so in every receipt it issues
(``scope='SYNTHETIC_PRIVATE_LAB_ONLY'``). It is not a bank, holds no signed
ledger and must never be composed into production. The production bank is
BD-01 Option B, which is prepared and NOT APPLIED.
"""
from __future__ import annotations

from sitewise.project1.contracts import WorkflowHeld, digest

LAB_SCOPE = 'SYNTHETIC_PRIVATE_LAB_ONLY'
ACCEPTED_SNAPSHOT = 'ACCEPTED_TEST_SNAPSHOT'


def snapshot(*, version='LAB-SNAP-1', items=None, bd02_policy_accepted=False,
             comparison_policy_version='LAB-EQUIVALENCE-0.1',
             issuer_id='TEST-HUMAN-ISSUER-NOT-REAL',
             independent_comparison_issuer=None, status=ACCEPTED_SNAPSHOT):
    """An accepted catalogue snapshot. ``items=[]`` is an empty bank."""
    return {'status': status, 'issuer_id': issuer_id, 'version': version,
            'items': [] if items is None else list(items),
            'bd02_policy_accepted': bd02_policy_accepted,
            'comparison_policy_version': comparison_policy_version,
            'independent_comparison_issuer': independent_comparison_issuer}


def approved_item(*, item_version='LAB-APPROVED-V1', receipt='LAB-APPROVAL-NOT-REAL'):
    return {'item_version': item_version, 'test_approved': True,
            'approval_receipt': receipt}


class LabBank:
    """A bank double that refuses more than it accepts, on purpose."""

    def __init__(self, *, catalogue, comparisons=None):
        self.catalogue = catalogue
        self.comparisons = comparisons or {}
        self._issued: dict[str, dict] = {}

    def lookup(self, measurement: dict, packet: dict) -> dict:
        snap = self.catalogue
        if (not snap or snap.get('status') != ACCEPTED_SNAPSHOT
                or not snap.get('issuer_id') or not snap.get('version')):
            raise WorkflowHeld('BANK_AUTHORITY_UNVERIFIED')
        items = snap.get('items') or []
        if not items:
            # The whole point of BD-02: absence of evidence is not evidence of absence.
            raise WorkflowHeld('BD02_EMPTY_BANK_CANNOT_PROVE_NO_EQUIVALENT')
        if not all(i.get('test_approved') and i.get('approval_receipt')
                   and i.get('item_version') for i in items):
            raise WorkflowHeld('BD01_ITEM_APPROVAL_NOT_VERIFIED')

        measurement_digest = digest(measurement)
        review = self.comparisons.get(measurement_digest)
        # A no-equivalent receipt needs a human comparison of *every* item in the
        # snapshot. A partial comparison proves only that some items were skipped.
        if (not review
                or set(review) != {i['item_version'] for i in items}
                or any(type(flag) is not bool for flag in review.values())):
            raise WorkflowHeld('BD02_COMPLETE_HUMAN_COMPARISON_REQUIRED')

        equivalent = [i for i in items if review[i['item_version']]]
        if len(equivalent) > 1:
            raise WorkflowHeld('BD02_AMBIGUOUS_EQUIVALENCE')
        if equivalent:
            item = equivalent[0]
            outcome = 'verified_equivalent'
            extra = {'item_version': item['item_version'],
                     'approval_receipt': item['approval_receipt']}
        else:
            if not snap.get('bd02_policy_accepted') or not snap.get('independent_comparison_issuer'):
                raise WorkflowHeld('BD02_POLICY_OR_ISSUER_UNAUTHORIZED')
            outcome = 'verified_no_equivalent'
            extra = {}

        receipt = {'outcome': outcome, 'bank_version': snap['version'],
                   'measurement_digest': measurement_digest,
                   'packet_hash': packet['packet_hash'],
                   'issuer_id': snap['issuer_id'],
                   'policy_version': snap.get('comparison_policy_version'),
                   'scope': LAB_SCOPE, 'item_review': review, **extra}
        receipt_id = digest(receipt)
        self._issued[receipt_id] = receipt
        return {**receipt, 'receipt_id': receipt_id}

    def verify_receipt(self, lookup: dict, measurement_digest: str, packet: dict) -> None:
        receipt_id = lookup.get('receipt_id')
        if not receipt_id or receipt_id not in self._issued:
            raise WorkflowHeld('BD01_RECEIPT_NOT_ISSUED')
        stored = self._issued[receipt_id]
        if (stored != {k: v for k, v in lookup.items() if k != 'receipt_id'}
                or digest(stored) != receipt_id):
            raise WorkflowHeld('BD01_RECEIPT_TAMPERED')
        if (stored['measurement_digest'] != measurement_digest
                or stored['packet_hash'] != packet.get('packet_hash')):
            raise WorkflowHeld('BD01_RECEIPT_CONTEXT_MISMATCH')
        if stored['scope'] != LAB_SCOPE:
            raise WorkflowHeld('BD01_SCOPE_INVALID')
