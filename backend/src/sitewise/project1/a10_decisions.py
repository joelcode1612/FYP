"""A10 decision register: the authoritative status of every admission decision.

This module exists so that "is this decision taken?" has exactly one answer that
code, tests and generated artifacts all read from the same place. It is a
*register*, not a source of authority: the only status it can report without an
owner act is a status that says no authority has been granted.

Status vocabulary
-----------------
``ADOPTED``
    An owner or scientific act exists, dated and attributed, with an evidence
    reference. **No decision in this register holds this status.** Nothing in
    this module may set it; ``a10_registers`` refuses an adopted-looking gate
    without an evidence hash, so an adoption cannot be faked by editing a dict.
``PROPOSED``
    A concrete recommendation with a recommended option, justification,
    consequences, owner and acceptance criteria has been written. A proposal is
    not an adoption and grants nothing.
``CLOSED_ENGINEERING``
    The requirement was a defect rather than a choice, and the defect is repaired
    and provably absent. Closing a defect is not approving the content it
    touched; where approval is still required it is tracked under the decision
    that owns the content.
``SUPERSEDED``
    The decision's premise was shown to be wrong by later evidence. The decision
    is retained rather than deleted so the record of the wrong premise survives.

Why ``SUPERSEDED`` matters
--------------------------
``D-09`` asserted that EE-01 could not express a per-feature denominator and that
a ``V_feature`` column was required. That premise was wrong: ``cq_runtime.route``
already expands Q10 into one slot per feature and EE-01 measures one slot, so
each feature already has its own ``V``. Recording D-09 as superseded — instead of
quietly deleting it — is what keeps the earlier engineering conclusion auditable.
"""
from __future__ import annotations

from dataclasses import dataclass, field

ADOPTED = 'ADOPTED'
PROPOSED = 'PROPOSED'
CLOSED_ENGINEERING = 'CLOSED_ENGINEERING'
SUPERSEDED = 'SUPERSEDED'

#: Statuses that assert an authority exists. Deliberately empty as a literal so a
#: grep for an adopted decision returns nothing to copy.
AUTHORITY_BEARING_STATUSES = frozenset({ADOPTED})

REGISTER_VERSION = 'a10-decisions/2'


@dataclass(frozen=True)
class Decision:
    """One decision, its owner, and what it blocks."""

    id: str
    title: str
    owner: str
    status: str
    #: Gates this decision would close. Empty for a decision that is not about a
    #: gate (for example a defect repair).
    gates: tuple[str, ...] = ()
    #: Components of the A10 contract this decision unblocks (C1..C10).
    components: tuple[str, ...] = ()
    #: What the system does while the decision is not adopted.
    meanwhile: str = ''
    #: For a superseded decision: the finding that replaced it.
    superseded_by: str = ''
    note: str = ''
    #: False for a decision drafted during the A10 completion work. The
    #: distinction matters for reconciliation: a gate whose closing decision
    #: already existed (D-01..D-14) is in a different state from one that only
    #: acquired a proposal during this assignment (D-15..D-21), even though
    #: neither is closed.
    pre_existing: bool = True


_DECISIONS: tuple[Decision, ...] = (
    Decision(
        id='D-01', title='Adopt a claim register', owner='Owner + scientific panel',
        status=PROPOSED, gates=('SD-01 descriptive-only',), components=('C2',),
        meanwhile='every item renders withheld',
        note='The claim register is the binding constraint: without it no adapter '
             'can produce ADMITTED honestly, because C2 has nothing to authorise '
             'against.'),
    Decision(
        id='D-02', title='Set the suppression floor k (SD-11)',
        owner='Owner + DPO', status=PROPOSED,
        gates=('SD-11 minimum publishable cell',), components=('C6',),
        meanwhile='three structural controls enforced; publication refused',
        note='floor_value is null. No threshold may be invented or defaulted.'),
    Decision(
        id='D-03', title='Confirm report scope R03-R08 (P-1/SD-03)',
        owner='Owner', status=PROPOSED,
        gates=('P-1/SD-03 report scope R03-R08',), components=('C4',),
        meanwhile='all substantive sections held',
        note='Whether R03-R08 exist in a customer report at all has not been decided.'),
    Decision(
        id='D-04', title='Settle the Q and denominator definitions (SD-09)',
        owner='Owner', status=PROPOSED,
        gates=('SD-09 Q / denominators',), components=('C3',),
        meanwhile='Q stored as measured; no gate depending on it is applied',
        note='Q_pre/Q_post are candidate names, not adopted fields.'),
    Decision(
        id='D-05', title='Adopt the screening architecture (SD-09 / CX-01)',
        owner='Owner', status=PROPOSED, components=('C3',),
        meanwhile='no respondent is declared ineligible from Q01',
        note='Owner direction recorded 2026-10-27 but formal approval is pending.'),
    Decision(
        id='D-06', title='Rule on the Q09 routing (ROUTING-01 / CX-08)',
        owner='WS2 scientific + Owner', status=PROPOSED,
        gates=('ROUTING-01 Q09 route (Q04-gated vs independent)',), components=('C4',),
        meanwhile='Q09 is UNKNOWN_ROUTE and withheld'),
    Decision(
        id='D-07', title='Rule on the Q10 routing (ROUTING-02 / CX-09)',
        owner='WS2 scientific + Owner', status=PROPOSED,
        gates=('ROUTING-02 Q10 route (no gate declared)',), components=('C4',),
        meanwhile='Q10 is UNKNOWN_ROUTE and withheld'),
    Decision(
        id='D-08', title='Approve the feature bank and F (G06 / CX-10)',
        owner='Task C + Owner', status=PROPOSED,
        gates=('G06 F and feature bank',), components=('C3',),
        meanwhile='Q10 and Q06 withheld',
        note='feature_bank.approved_bank is null; the v0.3:344 example list is not '
             'an approved ceiling and F <= 6 is an author burden proposal.'),
    Decision(
        id='D-09', title='Provide a per-feature denominator (engineering, CX-11)',
        owner='Engineering', status=SUPERSEDED, components=('C7',),
        superseded_by='P3.1 finding: per-feature V already exists',
        note='Premise was false. cq_runtime.route expands Q10 to one slot per '
             'feature and EE-01 measures one slot, so each feature slot already '
             'carries its own V. No V_feature column and no migration are needed. '
             'CX-11 splits into CX-11a (no approved bank, D-08) and CX-11b '
             '(presentation refusal PER_FEATURE_SLOT_UNSUPPORTED).'),
    Decision(
        id='D-10', title='Approve one exact offer and price (M2 / CX-06)',
        owner='Owner + scientific', status=PROPOSED,
        gates=('M2 exact offer and R05',), components=('C4',),
        meanwhile='Q07 is UNAVAILABLE_MISSING_APPROVED_STIMULUS, never zero '
                  'acceptability and never a WTP band'),
    Decision(
        id='D-11', title='Approve the concept card (G03-G06 / CX-04)',
        owner='scientific panel', status=PROPOSED,
        gates=('ROUTING-03 unapproved concept card on Q05/Q10',), components=('C3',),
        meanwhile='Q05 held'),
    Decision(
        id='D-12', title='Approve the menu codebook (CX-05)',
        owner='scientific panel', status=PROPOSED, components=('C3',),
        meanwhile='Q06 held',
        note='UNLISTED_CATEGORY_REPORTED is a presence flag, not an interest '
             'category, and must never be presented as one.'),
    Decision(
        id='D-13', title='Register Q11 and Q13 (owner registration)',
        owner='Owner', status=PROPOSED, components=('C4',),
        meanwhile='both refused at the section check and held in the explanation path',
        note='Q13 is a separate construct and is not a Q07 substitute.'),
    Decision(
        id='D-14', title='Correct the label bank encoding (CX-17)',
        owner='Owner (source custodian)', status=CLOSED_ENGINEERING,
        components=('presentation',),
        meanwhile='labels remain draft; approval tracked under D-08',
        note='Repaired at source 2026-11-22 with the original preserved and both '
             'hashes recorded. Repair is not approval.'),
    Decision(
        id='D-15', title='Define the formal geography construct (SD-02)',
        owner='Owner', status=PROPOSED,
        gates=('SD-02 formal geography',), components=('C4',),
        meanwhile='no formal geography claim may be admitted',
        pre_existing=False),
    Decision(
        id='D-16', title='Adopt the named-area catalogue (SD-05)',
        owner='Owner', status=PROPOSED,
        gates=('SD-05 area catalogue',), components=('C4',),
        meanwhile='no named-area claim may be admitted',
        note='Also gates the [named area] slot in the Q05 stem.',
        pre_existing=False),
    Decision(
        id='D-17', title='Define the unique-response rule (OD-07)',
        owner='Owner', status=PROPOSED,
        gates=('OD-07 unique-response rule',), components=('C3',),
        meanwhile='V counts measured rows; no de-duplication is applied',
        note='Without it V has no adopted unit of "one response", so a denominator '
             'cannot be defended even when the arithmetic is right.',
        pre_existing=False),
    Decision(
        id='D-18', title='Choose the canonical spine (B-17)',
        owner='Owner', status=PROPOSED,
        gates=('B-17 canonical-spine choice',), components=('C8',),
        meanwhile='binding hashes are recorded per snapshot; no spine is asserted',
        pre_existing=False),
    Decision(
        id='D-19', title='Rule on the Q03 hypothetical stem class (ROUTING-04)',
        owner='WS2 scientific + Owner', status=PROPOSED,
        gates=('ROUTING-04 Q03 hypothetical stem under ESSENTIAL class',),
        components=('C4',),
        meanwhile='Q03 withheld from R08',
        pre_existing=False),
    Decision(
        id='D-20', title='Obtain expert-panel content validity (G04)',
        owner='scientific panel', status=PROPOSED,
        gates=('G04 expert-panel content validity',), components=('C5',),
        meanwhile='R03 and R06 stay held',
        note='D-11 approves the concept card; it does not establish panel validity '
             'of the instrument.',
        pre_existing=False),
    Decision(
        id='D-21', title='Declare display order for the 11 undeclared items',
        owner='Owner', status=PROPOSED, components=('presentation',),
        meanwhile='the code array is used and recorded as '
                  'CODE_ARRAY_FALLBACK_UNDECLARED',
        note='display_order is declared for only Q01 and Q05. The other 11 fall '
             'back silently to the code array; the fallback is now recorded per '
             'item so it is visible rather than inferred.',
        pre_existing=False),
    Decision(
        id='D-22', title='Define the five undefined gate identifiers in the contract',
        owner='Owner (contract custodian)', status=PROPOSED, components=('C5',),
        meanwhile='the five identifiers stay unclosable and R04/R07/R08 stay held',
        note='G01, G03, G07, G08 and G10 appear in blocking_gates and '
             'items[].gate_dependencies but have no approval_gate_matrix row, so '
             'they have no owner, no status and no closing decision. No decision '
             'can close a gate that does not exist. This is the only decision '
             'whose absence makes the other twenty-one insufficient.',
        pre_existing=False),
)

DECISIONS: dict[str, Decision] = {d.id: d for d in _DECISIONS}


def by_status(*statuses: str) -> tuple[Decision, ...]:
    return tuple(d for d in _DECISIONS if d.status in statuses)


def adopted() -> tuple[Decision, ...]:
    """Decisions carrying an authority act. Empty by construction."""
    return by_status(ADOPTED)


def open_decisions() -> tuple[Decision, ...]:
    """Decisions that still require an owner or scientific act."""
    return by_status(PROPOSED)


def counts() -> dict[str, int]:
    result: dict[str, int] = {}
    for decision in _DECISIONS:
        result[decision.status] = result.get(decision.status, 0) + 1
    result['total'] = len(_DECISIONS)
    return result


def gate_owner(gate: str) -> str | None:
    """The owner of the decision that would close ``gate``, if one is proposed."""
    for decision in _DECISIONS:
        if gate in decision.gates:
            return decision.owner
    return None


def gate_decision(gate: str) -> str | None:
    for decision in _DECISIONS:
        if gate in decision.gates:
            return decision.id
    return None


__all__ = [
    'ADOPTED', 'AUTHORITY_BEARING_STATUSES', 'CLOSED_ENGINEERING', 'DECISIONS',
    'Decision', 'PROPOSED', 'REGISTER_VERSION', 'SUPERSEDED', 'adopted',
    'by_status', 'counts', 'gate_decision', 'gate_owner', 'open_decisions',
]
