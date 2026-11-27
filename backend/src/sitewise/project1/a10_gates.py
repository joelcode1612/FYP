"""A10 gate register: which admission gates exist, and whether any is closed.

Derived from ``CUST03`` rather than transcribed, so a gate cannot be omitted from
a report by forgetting to type it. Dispositions are computed from the decision
register in ``a10_decisions``; a gate that no decision would close is reported as
a gap instead of disappearing.

Two defects in the source contract that this module surfaces
------------------------------------------------------------
**1. Two different gate namespaces.** ``report_availability.*.blocking_gates``
lists gate *identifiers* (``G03``, ``G10``), while
``approval_gate_matrix.rows[].gate`` lists gate *names* (``G04 expert-panel
content validity``). Comparing them by string silently matches only three of the
eight identifiers used, so a naive lookup concludes that most sections have no
open gates. This module resolves identifiers against the matrix by their leading
token and reports what it cannot resolve.

**2. Five identifiers are undefined.** ``G01``, ``G03``, ``G07``, ``G08`` and
``G10`` appear in ``blocking_gates`` and in ``items[].gate_dependencies`` but have
**no row in the approval gate matrix at all**: no owner, no status, no closing
decision. They block R03, R04, R06, R07 and R08 — every substantive section. The
earlier reconciliation counted the 19 matrix rows and therefore could not see
them. The true count of distinct gate identities blocking publication is 24, of
which 5 are undefined and 0 are closed.

A naming defect corrected here
------------------------------
The earlier matrix labelled nine gates ``CLOSED_BY_DECISION``. That string reads
as "this gate is closed". It is not: it means *a decision exists that would close
this gate if it were adopted*. ``gates_closed`` was 0 the whole time the label was
in use. The disposition is named ``CLOSING_DECISION_IDENTIFIED`` here, and the
legacy string is kept only as ``disposition_legacy`` so earlier reports stay
traceable.

Nothing in this module can close a gate. A gate closes only when a dated,
attributed act with an evidence hash is recorded against it, and no such act
exists in this checkout.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from sitewise.project1 import a10_decisions

#: ``.../backend/src/sitewise/project1/a10_gates.py`` → ``.../backend``.
BACKEND = Path(__file__).resolve().parents[3]
CUST03 = (BACKEND / 'src' / 'sitewise' / 'customer_contracts' / 'reference'
          / 'CUST_RECOVERY_20261027'
          / 'CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_CONTRACT.json')

CLOSING_DECISION_IDENTIFIED = 'CLOSING_DECISION_IDENTIFIED'
EXTERNAL_APPROVAL_REQUIRED = 'EXTERNAL_APPROVAL_REQUIRED'
NO_CLOSING_DECISION = 'NO_CLOSING_DECISION'
TARGET_UNREACHABLE = 'TARGET_UNREACHABLE'
GATE_ID_UNDEFINED = 'GATE_ID_UNDEFINED'
#: The identifier names a *construct*, not a gate, but appears in a gate field.
#: ``G01`` is ``G01_AREA_ELIGIBILITY`` in ``construct_registry`` — respondent-
#: answered, implemented by Q01/Q02, and measured rather than approved. It has
#: no matrix row because it was never a gate; it is a category error in the
#: source contract, which is a different defect from an undefined gate and calls
#: for a different correction.
CONSTRUCT_ID_IN_GATE_FIELD = 'CONSTRUCT_ID_IN_GATE_FIELD'

_LEGACY = {CLOSING_DECISION_IDENTIFIED: 'CLOSED_BY_DECISION'}

#: Gate names no owner decision in this register can close.
EXTERNAL = {
    'G05 cognitive/bilingual pretest': 'requires the fielding institution',
    'institutional review': 'requires the institutional review board',
    'OD-08 privacy/consent/withdrawal/retention': 'requires DPO and committee sign-off',
}

#: Gates formally open whose target cannot be published at all.
UNREACHABLE = {
    'P-3 demand benchmark for R11': 'R11 is NEVER in report_availability',
}


@dataclass(frozen=True)
class Gate:
    #: The full matrix name, or the bare identifier when the matrix omits it.
    gate: str
    #: The identifier sections reference (``G04``, ``SD-11``, ``ROUTING-02``).
    gate_id: str
    owner: str
    status: str
    closing_decision: str | None
    disposition: str
    note: str | None = None
    defined: bool = True

    @property
    def closed(self) -> bool:
        """A gate is never closed by a disposition. No closure evidence exists."""
        return False

    @property
    def disposition_legacy(self) -> str | None:
        return _LEGACY.get(self.disposition)

    def as_dict(self) -> dict:
        return {
            'gate': self.gate,
            'gate_id': self.gate_id,
            'owner': self.owner,
            'status': self.status,
            'closing_decision': self.closing_decision,
            'disposition': self.disposition,
            'disposition_legacy': self.disposition_legacy,
            'defined': self.defined,
            'closed': self.closed,
            'note': self.note,
        }


@dataclass(frozen=True)
class Section:
    section: str
    state: str
    requires_v: bool | None
    blocking_gate_ids: tuple[str, ...]
    items: tuple[str, ...]
    may_render_a_measurement: bool

    @property
    def reportable_with_valid_evidence(self) -> bool:
        return self.state == 'REPORTABLE_WITH_VALID_EVIDENCE'


@lru_cache(maxsize=1)
def _contract() -> dict:
    return json.loads(CUST03.read_text(encoding='utf-8'))


def _gate_id(name: str) -> str:
    return name.split(' ', 1)[0]


def contract_version() -> str:
    """The instrument contract's own spec version, used as the section version.

    ``report_availability`` carries no per-section version, so the contract's
    ``spec_version`` is the only honest version identity available. Recording it
    is better than leaving the field empty, and it is named as what it is.
    """
    contract = _contract()
    return str(contract.get('spec_version') or 'UNKNOWN')


@lru_cache(maxsize=1)
def _matrix_gates() -> tuple[Gate, ...]:
    rows = _contract()['approval_gate_matrix']['rows']
    out: list[Gate] = []
    for row in rows:
        name = row['gate']
        decision = a10_decisions.gate_decision(name)
        if decision is not None:
            disposition = CLOSING_DECISION_IDENTIFIED
        elif name in EXTERNAL:
            disposition = EXTERNAL_APPROVAL_REQUIRED
        elif name in UNREACHABLE:
            disposition = TARGET_UNREACHABLE
        else:
            disposition = NO_CLOSING_DECISION
        out.append(Gate(
            gate=name, gate_id=_gate_id(name), owner=row['owner'],
            status=row['status'], closing_decision=decision,
            disposition=disposition,
            note=EXTERNAL.get(name) or UNREACHABLE.get(name)))
    return tuple(out)


@lru_cache(maxsize=1)
def referenced_gate_ids() -> tuple[str, ...]:
    """Every gate identifier a section or item depends on, sorted."""
    contract = _contract()
    ids: set[str] = set()
    for state in contract['report_availability'].values():
        if isinstance(state, dict):
            ids.update(state.get('blocking_gates') or ())
    for item in contract.get('items') or ():
        ids.update(item.get('gate_dependencies') or ())
    return tuple(sorted(ids))


@lru_cache(maxsize=1)
def construct_families() -> frozenset[str]:
    """The construct identifier families the contract actually defines.

    ``construct_registry`` keys look like ``G01_AREA_AFFILIATION``; the family
    is the leading token. ``G01`` and ``G02`` are the only G-families defined,
    and both are constructs — one respondent-answered, one a rule-based
    administrative control (``taxonomy_crosswalk.QUALITY_OR_CONTEXT``).
    """
    registry = _contract().get('construct_registry') or {}
    return frozenset(str(key).split('_', 1)[0] for key in registry)


@lru_cache(maxsize=1)
def gate_dependencies() -> dict[str, dict]:
    """Where each referenced identifier is used, resolved to real rows.

    The earlier count of "five undefined gates" was right about the count and
    silent about the usage: ``G01`` is a dependency of 11 of the 13 items and
    ``G10`` of none. A reader cannot judge which of the five matters without
    that difference, so it is computed rather than summarised.
    """
    contract = _contract()
    out: dict[str, dict] = {}
    for gate_id in referenced_gate_ids():
        sections = sorted(
            section_id
            for section_id, state in contract['report_availability'].items()
            if isinstance(state, dict)
            and gate_id in (state.get('blocking_gates') or ()))
        items = sorted(
            str(item.get('id'))
            for item in (contract.get('items') or ())
            if gate_id in (item.get('gate_dependencies') or ()))
        out[gate_id] = {
            'sections': sections,
            'items': items,
            'item_count': len(items),
            'blocks_sections': bool(sections),
        }
    return out


@lru_cache(maxsize=1)
def gates() -> tuple[Gate, ...]:
    """All gate identities: matrix rows first, then the unresolved identifiers."""
    known = {g.gate_id for g in _matrix_gates()}
    families = construct_families()
    undefined: list[Gate] = []
    for gate_id in referenced_gate_ids():
        if gate_id in known:
            continue
        if gate_id in families:
            undefined.append(Gate(
                gate=f'{gate_id} (a construct identifier, not a gate)',
                gate_id=gate_id, owner='UNASSIGNED',
                status='CONSTRUCT_NOT_A_GATE',
                closing_decision=None,
                disposition=CONSTRUCT_ID_IN_GATE_FIELD,
                note=(f'{gate_id} is defined in construct_registry as a '
                      'construct family, not as an approval gate. It appears in '
                      'blocking_gates/gate_dependencies, where a gate identifier '
                      'is expected. A construct is measured, not approved, so no '
                      'decision can close it: the reference has to be corrected '
                      'to the gate that actually governs it.'),
                defined=False))
            continue
        undefined.append(Gate(
            gate=f'{gate_id} (undefined in approval_gate_matrix)',
            gate_id=gate_id, owner='UNASSIGNED', status='UNDEFINED_IN_CONTRACT',
            closing_decision=None, disposition=GATE_ID_UNDEFINED,
            note='Referenced by blocking_gates/gate_dependencies but has no '
                 'approval_gate_matrix row: no owner, no status, no closing '
                 'decision. Cannot be closed until the contract defines it.',
            defined=False))
    return _matrix_gates() + tuple(undefined)


@lru_cache(maxsize=1)
def gate_map() -> dict[str, Gate]:
    """Keyed by identifier, because that is what sections reference."""
    return {g.gate_id: g for g in gates()}


@lru_cache(maxsize=1)
def sections() -> tuple[Section, ...]:
    from sitewise.project1.explanation_registry import load_registry
    availability = _contract()['report_availability']
    reg = load_registry()
    items_by_section: dict[str, list[str]] = {}
    for question_id, entry in reg.questions.items():
        for section in entry.report_sections:
            items_by_section.setdefault(section, []).append(question_id)
    out: list[Section] = []
    for section_id, state in availability.items():
        if not isinstance(state, dict):
            out.append(Section(section=section_id, state=str(state),
                               requires_v=None, blocking_gate_ids=(), items=(),
                               may_render_a_measurement=False))
            continue
        resolved = state.get('state') or state.get('render_state')
        requires_v = state.get('requires_V')
        out.append(Section(
            section=section_id,
            state=resolved,
            requires_v=requires_v,
            blocking_gate_ids=tuple(state.get('blocking_gates') or ()),
            items=tuple(items_by_section.get(section_id, ())),
            may_render_a_measurement=bool(
                requires_v is not False
                and resolved not in ('NEVER', 'NOT_A_CUSTOMER_SECTION',
                                     'SEPARATE_INPUT_PUBLISHER',
                                     'SEPARATE_INPUT_ENTREPRENEUR_PLAN')),
        ))
    return tuple(out)


@lru_cache(maxsize=1)
def section_map() -> dict[str, Section]:
    return {s.section: s for s in sections()}


def open_gates_for_section(section_id: str) -> tuple[Gate, ...]:
    """Every gate blocking ``section_id`` that is not closed.

    All of them, always — because no closure evidence exists. The filter on
    ``closed`` stays so that the day an act is recorded the adapter honours it
    without a code change.
    """
    section = section_map().get(section_id)
    if section is None:
        return ()
    resolved = (gate_map().get(gid) for gid in section.blocking_gate_ids)
    return tuple(g for g in resolved if g is not None and not g.closed)


def undefined_gate_ids() -> tuple[str, ...]:
    return tuple(g.gate_id for g in gates() if not g.defined)


def counts() -> dict[str, object]:
    gs = gates()
    by_disposition: dict[str, int] = {}
    for gate in gs:
        by_disposition[gate.disposition] = by_disposition.get(gate.disposition, 0) + 1
    matrix = [g for g in gs if g.defined]
    return {
        'gate_identities_total': len(gs),
        'matrix_gates': len(matrix),
        'undefined_gate_ids': len(gs) - len(matrix),
        # Split the five into what they actually are. Both counts are needed:
        # one says how many identifiers are unclosable, the other says why.
        'construct_id_references': sorted(
            g.gate_id for g in gs
            if g.disposition == CONSTRUCT_ID_IN_GATE_FIELD),
        'truly_undefined_gate_ids': sorted(
            g.gate_id for g in gs if g.disposition == GATE_ID_UNDEFINED),
        'gates_closed': sum(1 for g in gs if g.closed),
        'gates_with_a_closing_decision': sum(1 for g in gs if g.closing_decision),
        'gates_without_a_closing_decision': sum(1 for g in gs if not g.closing_decision),
        'by_disposition': dict(sorted(by_disposition.items())),
        'dependencies': gate_dependencies(),
        'decisions': a10_decisions.counts(),
    }


__all__ = [
    'CLOSING_DECISION_IDENTIFIED', 'CONSTRUCT_ID_IN_GATE_FIELD', 'EXTERNAL',
    'EXTERNAL_APPROVAL_REQUIRED', 'GATE_ID_UNDEFINED',
    'Gate', 'NO_CLOSING_DECISION', 'Section', 'TARGET_UNREACHABLE', 'UNREACHABLE',
    'construct_families', 'counts', 'gate_dependencies', 'gate_map', 'gates',
    'open_gates_for_section', 'referenced_gate_ids', 'section_map', 'sections',
    'undefined_gate_ids',
]
