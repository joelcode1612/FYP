"""Governed question bank: BD-01 reuse and BD-02 no-equivalent as real rules.

Why this module exists
----------------------
``ResearchWorkflow`` calls ``bank.lookup(measurement, packet)`` and
``bank.verify_receipt(lookup, digest, packet)`` (``research.py:176-177``), but
until now the only implementation in the tree was ``tests/project1/lab_bank.py``
-- an in-memory double. A double proves the *rules* are reachable; it proves
nothing about a bank, because it never reads an approval record, never persists a
receipt and cannot refuse on the strength of a schema invariant.

This module is the production implementation. It is a thin decision layer over a
store port, so the decision can be exercised without a database and the storage
can be real when one is available.

The two prohibitions this module is written against
---------------------------------------------------
**BD-01 -- reuse must rest on an approved item.** A generated-question candidate
record is not an approval. ``m2_review_question_versions`` has no approval column
(``migrations/m2/20261114_02_research_objective_sources.sql:35-39``) and the
owner's decision there is ``APPROVE_FOR_REVIEW``, not ``APPROVED``
(``migrations/m2/20261115_01_candidate_owner_review.sql:14-20``). So this module
reads ``project1_qgb.question_item_version_state`` and nothing else. That view
derives ``APPROVED`` only from an independent ``SCIENTIFIC_REVIEWER`` review plus
an ``OWNER_APPROVER`` approval by a *different* actor
(``migrations/m2/20261118_01_question_bank.sql:254-308``).

**BD-02 -- an empty bank cannot prove no-equivalent.** "I searched and found
nothing" and "a complete, reviewed catalogue contained nothing equivalent" are
different claims, and only the second may authorise a new question. An empty
snapshot, an unreviewed item, a partial review set or a single boolean standing
in for a review set are each refused with their own code.

What this module deliberately does not do
-----------------------------------------
* It never issues an approval. Approval is an ``item_lifecycle_event`` row written
  by a named reviewer and a different named approver; this module only reads the
  folded state.
* It never reads a CQ synthetic bank. ``sitewise.cq_successor`` (Q01-Q13) and the
  ``cq_synthetic_*`` tables are a separate, unregistered, synthetic catalogue
  (``cq_successor/contracts.py:1-13``) and are not a QG bank. Every SQL statement
  here names ``project1_qgb`` only.
* It confers no fielding, publication or scientific-acceptance right. The
  receipts it issues carry ``scope='SYNTHETIC_PRIVATE_LAB_ONLY'`` and
  ``measurement_policy.require_drafting`` is what turns a no-equivalent receipt
  into *research-only* drafting authority.
"""
from __future__ import annotations

import copy
from typing import Protocol
from uuid import NAMESPACE_URL, UUID, uuid5

from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlmodel import Session

from sitewise.project1.contracts import WorkflowHeld, digest

#: The only scope a receipt from this module may carry. ``verify_receipt`` refuses
#: anything else, so a bank configured with a broader scope issues receipts that
#: cannot be verified -- fail closed rather than silently widening.
LAB_SCOPE = 'SYNTHETIC_PRIVATE_LAB_ONLY'

EQUIVALENT = 'EQUIVALENT'
NO_EQUIVALENT = 'NO_EQUIVALENT'
#: ``comparison_receipt.decision`` allows this third value. It is used for the
#: *reviewer's* record -- "the human comparison happened, the bank has not derived
#: a decision from it" -- and never for a bank decision.
UNVERIFIED = 'UNVERIFIED'

#: Map a decision to the outcome label ``ResearchWorkflow`` switches on.
OUTCOMES = {EQUIVALENT: 'verified_equivalent', NO_EQUIVALENT: 'verified_no_equivalent'}

#: Registered BD-02 comparison policies. A version absent from this registry is
#: not accepted, so a no-equivalent receipt cannot be issued under it. Lab-scoped
#: on purpose: no real comparison policy has been signed.
BD02_POLICIES = {
    'BD02-EQUIVALENCE-1.0': {
        'version': 'BD02-EQUIVALENCE-1.0',
        'accepted': True,
        'scope': LAB_SCOPE,
    },
}

#: Keys of a receipt body, in the order a reviewer reads them. ``item_version`` and
#: ``approval_receipt`` are bound too (``None`` for no-equivalent): the workflow
#: reuses whichever item version the lookup names, so leaving that field outside
#: the digest would let a caller swap the reused item after issuance.
BODY_KEYS = (
    'measurement_digest', 'bcb_packet_hash', 'snapshot_version',
    'comparison_policy_version', 'issuer_id', 'decision', 'tenant_id',
    'objective_id', 'source_confirmation_id', 'item_version',
    'approval_receipt', 'item_review', 'scope',
)

#: Present on the returned dict but not part of the body: derived from ``decision``
#: and re-derived by ``verify_receipt``, so a tampered label is still caught.
DERIVED_KEYS = ('receipt_id', 'outcome')


def tenant_key(tenant_text) -> str:
    """Stable uuid for a BCB tenant label.

    ``comparison_receipt.tenant_id`` is ``uuid NOT NULL`` and is the RLS key, but
    a BCB packet carries ``identity.tenant_id`` as a label such as
    ``m2-owner:<uuid>`` (``business_context_v1.py:381``). Deriving the key here
    rather than storing the label keeps the column type honest and makes the
    value reproducible for an auditor. The same ``uuid5(NAMESPACE_URL, ...)``
    convention is already used for context ids and candidate versions.
    """
    return str(uuid5(NAMESPACE_URL, 'sitewise:qgb-tenant:' + str(tenant_text)))


def receipt_uuid(receipt_id: str) -> UUID:
    """The uuid primary key for a content-addressed receipt.

    ``receipt_id`` is ``digest(body)`` -- a 64-hex content address, which is what
    makes it verifiable. The schema's PK is a uuid, so the uuid is *derived* from
    the digest and ``receipt_sha256`` stores the authoritative value. Lookups by
    receipt id therefore go through ``receipt_sha256``, never through the PK.
    """
    return uuid5(NAMESPACE_URL, 'sitewise:qgb-receipt:' + receipt_id)


#: Lifecycle status of this module under the V2.0 contract change.
#:
#: The active path (``direct_qg_service``) composes ``ResearchWorkflow`` with
#: ``bank=None``, so BD-01 reuse and BD-02 no-equivalent are **not** gates on a
#: candidate in V2.0. This is a deliberate contract change, not an omission:
#: requiring a verified no-equivalent receipt before drafting made every
#: candidate depend on a bank that has no approved entry and no signed authority
#: (BD-01 unsigned, bank EMPTY). Deferring the gate is the only option that does
#: not fabricate an approval.
#:
#: The module is retained, not deleted, and this constant is what makes its
#: status machine-readable rather than a matter of memory: the code stays
#: testable and re-enablable, and a reader can tell "deferred by contract" from
#: "never implemented". Re-enabling it requires a signed contract change, not a
#: code edit.
STATUS = 'DEFERRED_BY_CONTRACT_CHANGE_P1_WORKFLOW_2_0'


class QuestionBankStore(Protocol):
    """The storage port ``QuestionBank`` requires. Implementations: Postgres, memory.

    Each method is a single fact, so the decision layer owns every rule and an
    adapter cannot smuggle one in. In particular no method can approve an item:
    ``snapshot_items`` returns the folded ``approval_state`` and the bank refuses
    anything that is not ``APPROVED``.
    """

    def accepted_snapshot(self) -> dict | None:
        """The snapshot in force, or ``None``.

        Required keys: ``snapshot_id``, ``snapshot_version``, ``scope_contract``,
        ``comparison_policy_version``, ``state``, ``acceptor_id``. A store that
        returns a non-``ACCEPTED`` row is refused by ``lookup`` rule 1.
        """

    def snapshot_items(self, snapshot_id: str) -> list[dict]:
        """Members of a snapshot with their derived approval state.

        Required keys per item: ``item_version_id``, ``approval_state``,
        ``approval_receipt`` (the approval event's ``receipt_ref``) and
        ``owner_approver_id``.
        """

    def comparison(self, snapshot_id: str, measurement_digest: str) -> dict | None:
        """The human comparison recorded for this measurement and snapshot.

        Required keys: ``issuer_id``, ``issuer_attestation``, ``policy_version``,
        ``reviews`` (``{item_version_id: bool}``). ``None`` means no human has
        compared this measurement against this snapshot -- which is not a
        no-equivalent finding, it is an absent one.
        """

    def issue_receipt(self, receipt: dict) -> None:
        """Persist an issued receipt immutably.

        ``receipt`` carries ``receipt_id``, ``body``, ``reviews``, ``snapshot_id``,
        ``equivalent_item_version_id`` and ``issuer_attestation``. Re-issuing the
        same body must be a no-op, not a duplicate.
        """

    def stored_receipt(self, receipt_id: str) -> dict | None:
        """The stored receipt in the same shape ``issue_receipt`` accepted."""


class QuestionBank:
    """BD-01/BD-02 decisions over an approved catalogue snapshot."""

    def __init__(self, store: QuestionBankStore, *, policy_version: str,
                 scope_contract: str):
        if not policy_version or not scope_contract:
            raise WorkflowHeld('BANK_AUTHORITY_UNVERIFIED')
        self.store = store
        #: The BD-02 comparison policy this bank applies. Bound into every receipt.
        self.policy_version = policy_version
        #: The catalogue scope this bank accepts. A snapshot accepted under a
        #: different scope is not this bank's catalogue.
        self.scope_contract = scope_contract

    # -- P3 §5.1: lookup ------------------------------------------------
    def lookup(self, measurement: dict, packet: dict) -> dict:
        snapshot = self.store.accepted_snapshot()
        # Rule 1. No snapshot, no acceptor, no version label, or a snapshot
        # accepted under another scope: there is no catalogue to compare against,
        # so nothing can be asserted about equivalence either way.
        if (not isinstance(snapshot, dict)
                or snapshot.get('state') != 'ACCEPTED'
                or not snapshot.get('snapshot_id')
                or not snapshot.get('snapshot_version')
                or not snapshot.get('acceptor_id')
                or snapshot.get('scope_contract') != self.scope_contract):
            raise WorkflowHeld('BANK_AUTHORITY_UNVERIFIED')

        items = self.store.snapshot_items(snapshot['snapshot_id'])
        # Rule 2. An empty catalogue proves nothing. This check must precede the
        # review check, otherwise "reviewed zero items" would satisfy "reviewed
        # every item" and an empty bank would authorise a new question.
        if not items:
            raise WorkflowHeld('BD02_EMPTY_BANK_CANNOT_PROVE_NO_EQUIVALENT')
        # Rule 3. Every item must be APPROVED, and must name the approval event's
        # receipt. A CANDIDATE row -- including a QG draft persisted to
        # m2_review_question_versions -- has no approval state at all, so it can
        # never reach this branch.
        if any(item.get('approval_state') != 'APPROVED'
               or not item.get('approval_receipt')
               or not item.get('item_version_id')
               for item in items):
            raise WorkflowHeld('BD01_ITEM_APPROVAL_NOT_VERIFIED')

        measurement_digest = digest(measurement)
        comparison = self.store.comparison(snapshot['snapshot_id'], measurement_digest)
        reviews = (comparison or {}).get('reviews')
        item_ids = {item['item_version_id'] for item in items}
        # Rule 4. The review set must cover every item in the snapshot, exactly,
        # with real booleans. A missing key means that item was skipped; a string
        # "yes" is not a verdict; an extra key is a verdict on something that is
        # not in the catalogue.
        if (not isinstance(reviews, dict)
                or set(reviews) != item_ids
                or any(type(verdict) is not bool for verdict in reviews.values())):
            raise WorkflowHeld('BD02_COMPLETE_HUMAN_COMPARISON_REQUIRED')
        # A comparison that is not attributed and attested is not a comparison.
        # Same code as rule 1 because it is the same failure: an issuer that
        # cannot be named cannot be held to the decision.
        issuer_id = (comparison or {}).get('issuer_id')
        if (not isinstance(issuer_id, str) or not issuer_id.strip()
                or not str((comparison or {}).get('issuer_attestation') or '').strip()):
            raise WorkflowHeld('BANK_AUTHORITY_UNVERIFIED')

        equivalent = [item for item in items if reviews[item['item_version_id']]]
        # Rule 5. Two equivalent items is not "pick one": the catalogue cannot
        # say which approved wording the measurement is, so reuse is ambiguous.
        if len(equivalent) > 1:
            raise WorkflowHeld('BD02_AMBIGUOUS_EQUIVALENCE')

        if equivalent:
            # Rule 6.
            item = equivalent[0]
            decision = EQUIVALENT
            item_version = item['item_version_id']
            approval_receipt = item['approval_receipt']
        else:
            # Rule 7. A negative finding is an authority claim, so it needs an
            # accepted comparison policy *and* an issuer independent of the people
            # who approved the items being ruled out.
            self._require_bd02_authority(snapshot, comparison, items)
            decision = NO_EQUIVALENT
            item_version = None
            approval_receipt = None

        # Rule 8. The body binds the measurement, the context, the catalogue
        # version, the policy, the issuer, the decision, the tenancy and the full
        # per-item review. ``receipt_id`` is the digest of exactly this body.
        body = self._body(measurement_digest, packet, snapshot, issuer_id,
                          decision, item_version, approval_receipt, reviews)
        receipt_id = digest(body)
        self.store.issue_receipt({
            'receipt_id': receipt_id,
            'body': body,
            'reviews': body['item_review'],
            'snapshot_id': snapshot['snapshot_id'],
            'equivalent_item_version_id': item_version,
            'issuer_attestation': comparison['issuer_attestation'],
        })
        return {**body, 'receipt_id': receipt_id, 'outcome': OUTCOMES[decision]}

    # -- BD-01: verify_receipt -----------------------------------------
    def verify_receipt(self, lookup: dict, measurement_digest: str, packet: dict) -> None:
        """Re-derive the receipt from storage. The lookup's own claims are not trusted."""
        receipt_id = lookup.get('receipt_id')
        # Rule 1. A receipt this bank did not issue is not evidence of anything,
        # however well-formed it looks.
        stored = None if not receipt_id else self.store.stored_receipt(receipt_id)
        if not stored:
            raise WorkflowHeld('BD01_RECEIPT_NOT_ISSUED')
        body = stored['body']
        claimed = {key: value for key, value in lookup.items()
                   if key not in DERIVED_KEYS}
        # Rule 2. The caller's copy must equal the stored body, the stored body
        # must still hash to the id, and the derived outcome label must still be
        # the one the stored decision implies. Any of the three is tampering.
        if (claimed != body or digest(body) != receipt_id
                or lookup.get('outcome') != OUTCOMES.get(body.get('decision'))):
            raise WorkflowHeld('BD01_RECEIPT_TAMPERED')
        # Rule 3. A receipt is for one measurement in one context. Replaying it
        # against another measurement or another packet is a context mismatch.
        if (body.get('measurement_digest') != measurement_digest
                or body.get('bcb_packet_hash') != packet.get('packet_hash')):
            raise WorkflowHeld('BD01_RECEIPT_CONTEXT_MISMATCH')
        # Rule 4. The only scope this module may issue is the private lab scope.
        if body.get('scope') != LAB_SCOPE:
            raise WorkflowHeld('BD01_SCOPE_INVALID')

    # -- internals ------------------------------------------------------
    def _body(self, measurement_digest, packet, snapshot, issuer_id, decision,
              item_version, approval_receipt, reviews) -> dict:
        identity = packet.get('identity') or {}
        confirmation = packet.get('confirmation') or {}
        uncertainty = packet.get('confirmed_uncertainty') or {}
        tenant_text = identity.get('tenant_id')
        # A receipt that cannot name the measurement's context is not bound to
        # anything, so it could be replayed across tenants.
        if (not packet.get('packet_hash') or not tenant_text
                or not confirmation.get('id') or not uncertainty.get('id')):
            raise WorkflowHeld('BANK_AUTHORITY_UNVERIFIED')
        return {
            'measurement_digest': measurement_digest,
            'bcb_packet_hash': packet['packet_hash'],
            'snapshot_version': snapshot['snapshot_version'],
            'comparison_policy_version': self.policy_version,
            'issuer_id': issuer_id,
            'decision': decision,
            'tenant_id': tenant_key(tenant_text),
            # The confirmed uncertainty *is* the objective (m2_confirmed_uncertainties
            # rows are the research objectives the workflow walks ancestry over).
            'objective_id': str(uncertainty['id']),
            'source_confirmation_id': str(confirmation['id']),
            'item_version': item_version,
            'approval_receipt': approval_receipt,
            'item_review': {key: reviews[key] for key in sorted(reviews)},
            'scope': self.scope_contract,
        }

    def _require_bd02_authority(self, snapshot, comparison, items) -> None:
        policy = BD02_POLICIES.get(self.policy_version)
        if (policy is None or policy.get('accepted') is not True
                or snapshot.get('comparison_policy_version') != self.policy_version
                or comparison.get('policy_version') != self.policy_version):
            raise WorkflowHeld('BD02_POLICY_OR_ISSUER_UNAUTHORIZED')
        # Independence is a fact about named people, not a flag: the issuer must
        # differ from every owner approver of the items being ruled out. With no
        # approver recorded, independence cannot be proved, so it is not claimed.
        approvers = {item.get('owner_approver_id') for item in items
                     if item.get('owner_approver_id')}
        if not approvers or comparison.get('issuer_id') in approvers:
            raise WorkflowHeld('BD02_POLICY_OR_ISSUER_UNAUTHORIZED')


class PostgresQuestionBankStore:
    """Real SQL against ``project1_qgb``. Reads state views; never approves.

    Privileges, as the migration actually grants them
    (``migrations/m2/20261118_01_question_bank.sql:405-425``) -- this adapter is
    the **issuer-side** reader, because it issues receipts:

    * ``accepted_snapshot`` / ``snapshot_items`` read
      ``bank_snapshot_state`` and ``question_item_version_state`` plus
      ``item_lifecycle_event.receipt_ref``. Those are granted to
      ``p1_qgb_issuer`` only; ``p1_qgb_runtime`` is deliberately denied them and
      gets the filtered ``accepted_bank_snapshot*`` /
      ``approved_question_item_version`` views instead.
    * ``issue_receipt`` inserts ``comparison_receipt`` and
      ``comparison_review_item``, which only ``p1_qgb_issuer`` may do.
    * ``stored_receipt`` is the one read a *runtime* caller needs. Pass
      ``tenant_id`` and the adapter binds ``project1.tenant_id``
      transaction-locally so the ``tenant_select`` RLS policy -- not the caller's
      WHERE clause -- decides visibility.

    Known gap, reported rather than worked around: ``comparison_receipt`` has an
    ``issuer_insert`` policy but no SELECT policy for ``p1_qgb_issuer``, so this
    adapter's own read-back needs ``p1_qgb_admin`` or the runtime path above.
    """

    def __init__(self, engine, *, tenant_id=None):
        self.engine = engine
        self.tenant_id = None if tenant_id is None else UUID(str(tenant_id))

    # -- reads ----------------------------------------------------------
    def accepted_snapshot(self) -> dict | None:
        return self._one(
            'SELECT snapshot_id::text AS snapshot_id, snapshot_version,'
            '       scope_contract, catalogue_sha256, comparison_policy_version,'
            '       state, acceptor_id'
            '  FROM project1_qgb.bank_snapshot_state'
            " WHERE state = 'ACCEPTED'"
            ' ORDER BY accepted_at DESC NULLS LAST, snapshot_version DESC'
            ' LIMIT 1')

    def snapshot_items(self, snapshot_id: str) -> list[dict]:
        # LEFT JOIN, not JOIN: an item with no lifecycle event has a NULL
        # approval_state and must reach rule 3 as "not approved". An inner join
        # would drop it and make the catalogue look smaller than it is.
        return self._all(
            'SELECT si.item_version_id::text AS item_version_id,'
            '       s.approval_state, s.owner_approver_id,'
            '       (SELECT e.receipt_ref'
            '          FROM project1_qgb.item_lifecycle_event e'
            '         WHERE e.item_version_id = si.item_version_id'
            "           AND e.event_type = 'APPROVED'"
            '         ORDER BY e.sequence DESC LIMIT 1) AS approval_receipt'
            '  FROM project1_qgb.bank_snapshot_item si'
            '  LEFT JOIN project1_qgb.question_item_version_state s'
            '    ON s.item_version_id = si.item_version_id'
            ' WHERE si.snapshot_id = CAST(:snapshot AS uuid)'
            ' ORDER BY si.item_version_id',
            {'snapshot': snapshot_id})

    def comparison(self, snapshot_id: str, measurement_digest: str) -> dict | None:
        header = self._one(
            'SELECT receipt_id::text AS receipt_id, issuer_id, issuer_attestation,'
            '       comparison_policy_version'
            '  FROM project1_qgb.comparison_receipt'
            ' WHERE snapshot_id = CAST(:snapshot AS uuid)'
            '   AND measurement_digest = :digest'
            "   AND decision = 'UNVERIFIED'"
            ' ORDER BY issued_at DESC, receipt_id DESC'
            ' LIMIT 1',
            {'snapshot': snapshot_id, 'digest': measurement_digest})
        if header is None:
            return None
        reviews = self._all(
            'SELECT item_version_id::text AS item_version_id, equivalent'
            '  FROM project1_qgb.comparison_review_item'
            ' WHERE receipt_id = CAST(:receipt AS uuid)'
            ' ORDER BY item_version_id',
            {'receipt': header['receipt_id']})
        return {'issuer_id': header['issuer_id'],
                'issuer_attestation': header['issuer_attestation'],
                'policy_version': header['comparison_policy_version'],
                'reviews': {row['item_version_id']: row['equivalent'] for row in reviews}}

    def stored_receipt(self, receipt_id: str) -> dict | None:
        row = self._one(
            'SELECT r.receipt_id::text AS receipt_id, r.snapshot_id::text AS snapshot_id,'
            '       r.tenant_id::text AS tenant_id, r.objective_id::text AS objective_id,'
            '       r.source_confirmation_id::text AS source_confirmation_id,'
            '       r.measurement_digest, r.bcb_packet_hash,'
            '       r.comparison_policy_version, r.issuer_id, r.issuer_attestation,'
            '       r.decision,'
            '       r.equivalent_item_version_id::text AS equivalent_item_version_id,'
            '       r.receipt_sha256, b.snapshot_version, b.scope_contract'
            '  FROM project1_qgb.comparison_receipt r'
            '  JOIN project1_qgb.bank_snapshot b USING (snapshot_id)'
            ' WHERE r.receipt_sha256 = :sha',
            {'sha': receipt_id})
        if row is None:
            return None
        reviews = self._all(
            'SELECT item_version_id::text AS item_version_id, equivalent'
            '  FROM project1_qgb.comparison_review_item'
            ' WHERE receipt_id = CAST(:receipt AS uuid)'
            ' ORDER BY item_version_id',
            {'receipt': row['receipt_id']})
        item_version = row['equivalent_item_version_id']
        # ``approval_receipt`` is bound into the body, so it must be reproducible.
        # It is re-read from the append-only approval event: if a second approval
        # event were appended later, verification would fail closed rather than
        # silently accept a different receipt.
        approval_receipt = (None if item_version is None else self._one(
            'SELECT receipt_ref'
            '  FROM project1_qgb.item_lifecycle_event'
            ' WHERE item_version_id = CAST(:item AS uuid)'
            "   AND event_type = 'APPROVED'"
            ' ORDER BY sequence DESC LIMIT 1',
            {'item': item_version}))
        body = {
            'measurement_digest': row['measurement_digest'],
            'bcb_packet_hash': row['bcb_packet_hash'],
            'snapshot_version': row['snapshot_version'],
            'comparison_policy_version': row['comparison_policy_version'],
            'issuer_id': row['issuer_id'],
            'decision': row['decision'],
            'tenant_id': row['tenant_id'],
            'objective_id': row['objective_id'],
            'source_confirmation_id': row['source_confirmation_id'],
            'item_version': item_version,
            'approval_receipt': (None if approval_receipt is None
                                 else approval_receipt['receipt_ref']),
            'item_review': {review['item_version_id']: review['equivalent']
                            for review in reviews},
            'scope': row['scope_contract'],
        }
        return {'receipt_id': row['receipt_sha256'], 'body': body,
                'reviews': body['item_review'], 'snapshot_id': row['snapshot_id'],
                'equivalent_item_version_id': item_version,
                'issuer_attestation': row['issuer_attestation']}

    # -- writes ---------------------------------------------------------
    def record_comparison(self, *, snapshot_id, measurement_digest, bcb_packet_hash,
                          policy_version, issuer_id, issuer_attestation, tenant_id,
                          objective_id, source_confirmation_id, reviews, rationale):
        """Record a human comparison. This is the reviewer's act, not a decision.

        The row is written with ``decision='UNVERIFIED'``: reviews exist, the bank
        has not derived a decision from them. Nothing here can approve an item or
        authorise a question, and the bank's decision is a separate append-only
        receipt, because the record tables refuse UPDATE.
        """
        if not reviews or any(type(flag) is not bool for flag in reviews.values()):
            raise WorkflowHeld('BD02_COMPLETE_HUMAN_COMPARISON_REQUIRED')
        record = {'snapshot_id': str(snapshot_id),
                  'measurement_digest': measurement_digest,
                  'bcb_packet_hash': bcb_packet_hash,
                  'policy_version': policy_version,
                  'issuer_id': issuer_id,
                  'item_review': sorted(reviews.items())}
        receipt_sha256 = digest(record)
        receipt_id = receipt_uuid(receipt_sha256)
        try:
            with Session(self.engine) as session:
                self._scope(session)
                session.execute(text(
                    'INSERT INTO project1_qgb.comparison_receipt ('
                    ' receipt_id, snapshot_id, tenant_id, objective_id,'
                    ' source_confirmation_id, measurement_digest, bcb_packet_hash,'
                    ' comparison_policy_version, issuer_id, issuer_attestation,'
                    ' decision, equivalent_item_version_id, receipt_sha256) VALUES ('
                    ' :receipt_id, CAST(:snapshot AS uuid), CAST(:tenant AS uuid),'
                    ' CAST(:objective AS uuid), CAST(:confirmation AS uuid),'
                    ' :digest, :packet_hash, :policy, :issuer, :attestation,'
                    " 'UNVERIFIED', NULL, :sha) ON CONFLICT (receipt_id) DO NOTHING"), {
                        'receipt_id': receipt_id, 'snapshot': snapshot_id,
                        'tenant': str(tenant_id), 'objective': str(objective_id),
                        'confirmation': str(source_confirmation_id),
                        'digest': measurement_digest, 'packet_hash': bcb_packet_hash,
                        'policy': policy_version, 'issuer': issuer_id,
                        'attestation': issuer_attestation, 'sha': receipt_sha256})
                for item_version_id, equivalent in reviews.items():
                    session.execute(text(
                        'INSERT INTO project1_qgb.comparison_review_item ('
                        ' receipt_id, item_version_id, reviewer_id,'
                        ' reviewer_attestation, equivalent, rationale) VALUES ('
                        ' :receipt, CAST(:item AS uuid), :reviewer, :attestation,'
                        ' :equivalent, :rationale)'
                        ' ON CONFLICT (receipt_id, item_version_id) DO NOTHING'), {
                            'receipt': receipt_id, 'item': item_version_id,
                            'reviewer': issuer_id, 'attestation': issuer_attestation,
                            'equivalent': equivalent, 'rationale': rationale})
                session.commit()
                return receipt_sha256
        except WorkflowHeld:
            raise
        except SQLAlchemyError:
            raise WorkflowHeld('WORKFLOW_STORAGE_UNAVAILABLE') from None

    def issue_receipt(self, receipt: dict) -> None:
        body = receipt['body']
        receipt_id = receipt['receipt_id']
        receipt_pk = receipt_uuid(receipt_id)
        try:
            with Session(self.engine) as session:
                self._scope(session)
                session.execute(text(
                    'INSERT INTO project1_qgb.comparison_receipt ('
                    ' receipt_id, snapshot_id, tenant_id, objective_id,'
                    ' source_confirmation_id, measurement_digest, bcb_packet_hash,'
                    ' comparison_policy_version, issuer_id, issuer_attestation,'
                    ' decision, equivalent_item_version_id, receipt_sha256) VALUES ('
                    ' :receipt_id, CAST(:snapshot AS uuid), CAST(:tenant AS uuid),'
                    ' CAST(:objective AS uuid), CAST(:confirmation AS uuid),'
                    ' :digest, :packet_hash, :policy, :issuer, :attestation,'
                    ' :decision, CAST(:item AS uuid), :sha)'
                    ' ON CONFLICT (receipt_id) DO NOTHING'), {
                        'receipt_id': receipt_pk,
                        'snapshot': receipt['snapshot_id'],
                        'tenant': body['tenant_id'],
                        'objective': body['objective_id'],
                        'confirmation': body['source_confirmation_id'],
                        'digest': body['measurement_digest'],
                        'packet_hash': body['bcb_packet_hash'],
                        'policy': body['comparison_policy_version'],
                        'issuer': body['issuer_id'],
                        'attestation': receipt['issuer_attestation'],
                        'decision': body['decision'],
                        'item': body['item_version'],
                        'sha': receipt_id})
                for item_version_id, equivalent in receipt['reviews'].items():
                    session.execute(text(
                        'INSERT INTO project1_qgb.comparison_review_item ('
                        ' receipt_id, item_version_id, reviewer_id,'
                        ' reviewer_attestation, equivalent, rationale) VALUES ('
                        ' :receipt, CAST(:item AS uuid), :reviewer, :attestation,'
                        ' :equivalent, :rationale)'
                        ' ON CONFLICT (receipt_id, item_version_id) DO NOTHING'), {
                            'receipt': receipt_pk, 'item': item_version_id,
                            'reviewer': body['issuer_id'],
                            'attestation': receipt['issuer_attestation'],
                            'equivalent': equivalent,
                            'rationale': 'Recorded comparison; decision derived by QuestionBank.'})
                session.commit()
        except WorkflowHeld:
            raise
        except SQLAlchemyError:
            raise WorkflowHeld('WORKFLOW_STORAGE_UNAVAILABLE') from None

    # -- plumbing -------------------------------------------------------
    def _scope(self, session) -> None:
        if self.tenant_id is not None:
            session.execute(
                text("SELECT set_config('project1.tenant_id', :tenant, true)"),
                {'tenant': str(self.tenant_id)})

    def _one(self, statement: str, params: dict | None = None) -> dict | None:
        try:
            with Session(self.engine) as session:
                self._scope(session)
                row = session.execute(text(statement), params or {}).mappings().first()
                session.rollback()
                return None if row is None else dict(row)
        except WorkflowHeld:
            raise
        except SQLAlchemyError:
            raise WorkflowHeld('WORKFLOW_STORAGE_UNAVAILABLE') from None

    def _all(self, statement: str, params: dict | None = None) -> list[dict]:
        try:
            with Session(self.engine) as session:
                self._scope(session)
                rows = session.execute(text(statement), params or {}).mappings().all()
                session.rollback()
                return [dict(row) for row in rows]
        except WorkflowHeld:
            raise
        except SQLAlchemyError:
            raise WorkflowHeld('WORKFLOW_STORAGE_UNAVAILABLE') from None


class InMemoryQuestionBankStore:
    """TEST-ONLY in-memory store. Never compose into production.

    It exists so the decision rules in ``QuestionBank`` can be executed without a
    database, and it is honest about being a double: it holds no signed ledger,
    performs no RLS and validates no uuid. ``PostgresQuestionBankStore`` is the
    implementation that meets the schema; passing the tests here proves the
    *rules*, not the storage.

    ``snapshot``/``items``/``comparisons`` are plain data so a test can state
    exactly one defect at a time. ``comparisons`` is keyed by measurement digest.
    """

    def __init__(self, *, snapshot=None, items=(), comparisons=None):
        self._snapshot = copy.deepcopy(snapshot)
        self._items = copy.deepcopy(list(items))
        self._comparisons = copy.deepcopy(dict(comparisons or {}))
        self._receipts: dict[str, dict] = {}

    def accepted_snapshot(self) -> dict | None:
        return copy.deepcopy(self._snapshot)

    def snapshot_items(self, snapshot_id: str) -> list[dict]:
        if self._snapshot is None or self._snapshot.get('snapshot_id') != snapshot_id:
            return []
        return copy.deepcopy(self._items)

    def comparison(self, snapshot_id: str, measurement_digest: str) -> dict | None:
        value = self._comparisons.get(measurement_digest)
        if value is None:
            return None
        result = copy.deepcopy(value)
        result.setdefault('reviews', {})
        return result

    def record_comparison(self, measurement_digest: str, *, issuer_id,
                          issuer_attestation, policy_version, reviews) -> None:
        self._comparisons[measurement_digest] = {
            'issuer_id': issuer_id,
            'issuer_attestation': issuer_attestation,
            'policy_version': policy_version,
            'reviews': dict(reviews),
        }

    def issue_receipt(self, receipt: dict) -> None:
        # Idempotent, like the Postgres ON CONFLICT: the same body is the same
        # receipt, and re-issuing it must not overwrite a stored one.
        self._receipts.setdefault(receipt['receipt_id'], copy.deepcopy(receipt))

    def stored_receipt(self, receipt_id: str) -> dict | None:
        return copy.deepcopy(self._receipts.get(receipt_id))


__all__ = ['BD02_POLICIES', 'BODY_KEYS', 'EQUIVALENT', 'InMemoryQuestionBankStore',
           'LAB_SCOPE', 'NO_EQUIVALENT', 'OUTCOMES', 'PostgresQuestionBankStore',
           'QuestionBank', 'QuestionBankStore', 'STATUS', 'UNVERIFIED',
           'receipt_uuid', 'tenant_key']
