"""Generate PROJECT1_A10_GATE_DEPENDENCY_MATRIX.json from the frozen contract.

The matrix is derived, not transcribed: gates, owners and statuses come from
``CUST03.approval_gate_matrix.rows``, section states from ``report_availability``,
and the gate→decision mapping is declared here once. Gates that no decision closes
are **computed** as a set difference, so the gap cannot be hidden by an omission in
prose.

Run from ``backend``:

    ./.venv/Scripts/python.exe scripts/build_a10_gate_matrix.py
"""
from __future__ import annotations

import json
from pathlib import Path

from sitewise.project1.explanation_registry import load_registry

BACKEND = Path(__file__).resolve().parents[1]
CUST03 = (BACKEND / 'src' / 'sitewise' / 'customer_contracts' / 'reference'
          / 'CUST_RECOVERY_20261027'
          / 'CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_CONTRACT.json')
OUT = BACKEND.parent / 'deliverables' / 'PROJECT1_A10_GATE_DEPENDENCY_MATRIX.json'

#: Which decision closes which gate. A gate absent from this mapping is open even
#: after every decision is taken — that is the point of computing the difference.
GATE_TO_DECISION = {
    'P-1/SD-03 report scope R03-R08': 'D-03',
    'SD-01 descriptive-only': 'D-01',
    'SD-09 Q / denominators': 'D-04',
    'SD-11 minimum publishable cell': 'D-02',
    'G06 F and feature bank': 'D-08',
    'M2 exact offer and R05': 'D-10',
    'ROUTING-01 Q09 route (Q04-gated vs independent)': 'D-06',
    'ROUTING-02 Q10 route (no gate declared)': 'D-07',
    'ROUTING-03 unapproved concept card on Q05/Q10': 'D-11',
}

#: Gates that cannot be closed by an owner decision in this register at all, and
#: why. Separated so the remaining difference is a genuine gap, not a category
#: mistake.
EXTERNAL = {
    'G05 cognitive/bilingual pretest': 'requires the fielding institution',
    'institutional review': 'requires the institutional review board',
    'OD-08 privacy/consent/withdrawal/retention': 'requires DPO and committee sign-off',
}

#: Gates that are formally open but whose target is unreachable anyway.
MOOT = {
    'P-3 demand benchmark for R11': 'R11 is NEVER in report_availability',
}

#: Gates with no closing decision that are not external and not moot. These need
#: new decisions; the readiness report proposes D-15..D-18 for them.
GAP = {
    'SD-02 formal geography': 'no decision defines the formal geography construct',
    'SD-05 area catalogue': 'no decision adopts the named-area catalogue',
    'OD-07 unique-response rule': 'no decision settles what counts as one response',
    'B-17 canonical-spine choice': 'no decision picks the canonical spine',
    'ROUTING-04 Q03 hypothetical stem under ESSENTIAL class':
        'no decision rules on Q03 stem class',
    'G04 expert-panel content validity': 'D-11 covers the concept card, not panel validity',
}

#: Section → the items that feed it, from the registry, so the matrix can say
#: which items are stuck behind which gate.
SECTION_ITEMS: dict[str, list[str]] = {}


def main() -> None:
    cust = json.loads(CUST03.read_text(encoding='utf-8'))
    rows = cust['approval_gate_matrix']['rows']
    availability = cust['report_availability']
    suppression = cust['suppression_policy']
    reg = load_registry()

    for question_id, entry in reg.questions.items():
        for section in entry.report_sections:
            SECTION_ITEMS.setdefault(section, []).append(question_id)

    gates = []
    for row in rows:
        name = row['gate']
        decision = GATE_TO_DECISION.get(name)
        if decision:
            disposition = 'CLOSED_BY_DECISION'
        elif name in EXTERNAL:
            disposition = 'EXTERNAL_APPROVAL_REQUIRED'
        elif name in MOOT:
            disposition = 'OPEN_BUT_TARGET_UNREACHABLE'
        elif name in GAP:
            disposition = 'NO_CLOSING_DECISION'
        else:
            disposition = 'UNCLASSIFIED'
        gates.append({
            'gate': name,
            'owner': row['owner'],
            'status': row['status'],
            'closing_decision': decision,
            'disposition': disposition,
            'note': (EXTERNAL.get(name) or MOOT.get(name) or GAP.get(name)),
        })

    by_disposition: dict[str, list[str]] = {}
    for gate in gates:
        by_disposition.setdefault(gate['disposition'], []).append(gate['gate'])

    sections = []
    for section_id, state in availability.items():
        if not isinstance(state, dict):
            sections.append({'section': section_id, 'state': state})
            continue
        sections.append({
            'section': section_id,
            'state': state.get('state') or state.get('render_state'),
            'requires_V': state.get('requires_V'),
            'blocking_gates': state.get('blocking_gates') or [],
            'items': SECTION_ITEMS.get(section_id, []),
            'may_render_a_measurement': bool(
                state.get('requires_V') is not False
                and (state.get('state') or state.get('render_state'))
                not in ('NEVER', 'NOT_A_CUSTOMER_SECTION',
                        'SEPARATE_INPUT_PUBLISHER', 'SEPARATE_INPUT_ENTREPRENEUR_PLAN')),
        })

    payload = {
        '_note': ('Derived from CUST03 approval_gate_matrix.rows and report_availability. '
                  'The gate-to-decision mapping is declared in '
                  'scripts/build_a10_gate_matrix.py; gates no decision closes are '
                  'computed as a set difference rather than omitted.'),
        'source': {
            'contract': 'P3-01C-VNEXT-0.6.1-CUST-REC',
            'path': str(CUST03.relative_to(BACKEND.parent)).replace('\\', '/'),
            'approval_gate_grants': cust['approval_gate_matrix']['grants'],
            'fielding': cust['approval_gate_matrix']['fielding'],
            'engine': cust['approval_gate_matrix']['engine'],
            'registry_version': reg.registry_version,
            'registry_sha256': reg.sha256,
        },
        'counts': {
            'gates_total': len(gates),
            'gates_closed': 0,
            'decisions_total': 14,
            'gates_with_a_closing_decision': sum(
                1 for g in gates if g['closing_decision']),
            'gates_without_a_closing_decision': sum(
                1 for g in gates if not g['closing_decision']),
            'by_disposition': {k: len(v) for k, v in sorted(by_disposition.items())},
        },
        'suppression_policy': {
            'status': suppression['status'],
            'floor_symbol': suppression['primary_suppression']['floor_symbol'],
            'floor_value': suppression['primary_suppression']['floor_value'],
            'floor_status': suppression['primary_suppression']['floor_status'],
            'binding_structural_controls':
                suppression['binding_structural_controls'],
        },
        'gates': gates,
        'gates_by_disposition': by_disposition,
        'report_sections': sections,
        'proposed_new_decisions': [
            {'id': 'D-15', 'gate': 'SD-02 formal geography',
             'owner': 'Owner', 'why': 'no decision defines the formal geography construct'},
            {'id': 'D-16', 'gate': 'SD-05 area catalogue',
             'owner': 'Owner', 'why': 'no decision adopts the named-area catalogue'},
            {'id': 'D-17', 'gate': 'OD-07 unique-response rule',
             'owner': 'Owner', 'why': 'no decision settles what counts as one response'},
            {'id': 'D-18', 'gate': 'B-17 canonical-spine choice',
             'owner': 'Owner', 'why': 'no decision picks the canonical spine'},
            {'id': 'D-19', 'gate': 'ROUTING-04 Q03 hypothetical stem under ESSENTIAL class',
             'owner': 'WS2 scientific + Owner', 'why': 'no decision rules on Q03 stem class'},
            {'id': 'D-20', 'gate': 'G04 expert-panel content validity',
             'owner': 'scientific panel',
             'why': 'D-11 approves the concept card, not panel content validity'},
        ],
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + '\n',
                   encoding='utf-8')
    import hashlib
    raw = OUT.read_bytes()
    print(f'{OUT.name}  {len(raw)} bytes  {hashlib.sha256(raw).hexdigest()}')
    print(json.dumps(payload['counts'], indent=1))
    for gate in gates:
        print(f"  {gate['disposition']:<30} {gate['gate'][:52]:<54} {gate['closing_decision'] or '-'}")


if __name__ == '__main__':
    main()
