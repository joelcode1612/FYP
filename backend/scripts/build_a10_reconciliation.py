"""Generate the A10 reconciliation and claim-mapping artifacts.

Both artifacts are derived from the same registers the adapter uses, so a number
in a report and a number in the runtime cannot disagree. Nothing here is typed by
hand except the prose in ``NOTES``.

Run from ``backend``::

    ./.venv/Scripts/python.exe scripts/build_a10_reconciliation.py
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

from sitewise.project1 import a10_decisions, a10_gates
from sitewise.project1.a10 import REFUSAL_CODES
from sitewise.project1.a10_claims import PROPOSED_CLAIMS
from sitewise.project1.explanation_registry import load_registry

BACKEND = Path(__file__).resolve().parents[1]
OUT_DIR = BACKEND.parent / 'deliverables'
RECON = OUT_DIR / 'PROJECT1_A10_GATE_RECONCILIATION.json'
CLAIMS = OUT_DIR / 'PROJECT1_A10_CLAIM_REPORT_MAPPING.json'


def _dump(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(payload, indent=2, ensure_ascii=False) + '\n'
    path.write_text(text, encoding='utf-8')
    print(f'{path.name}  {len(text.encode("utf-8"))} bytes  '
          f'{hashlib.sha256(text.encode("utf-8")).hexdigest()}')


def reconciliation() -> dict:
    reg = load_registry()
    counts = a10_gates.counts()
    gates = [g.as_dict() for g in a10_gates.gates()]
    matrix = [g for g in gates if g['defined']]
    undefined = [g for g in gates if not g['defined']]
    sections = [{
        'section': s.section,
        'state': s.state,
        'requires_V': s.requires_v,
        'blocking_gate_ids': list(s.blocking_gate_ids),
        'items': list(s.items),
        'may_render_a_measurement': s.may_render_a_measurement,
        'open_gates': [g.gate_id for g in a10_gates.open_gates_for_section(s.section)],
        'reportable_with_valid_evidence': s.reportable_with_valid_evidence,
    } for s in a10_gates.sections()]

    # A gate whose closing decision already existed before this assignment is in
    # a different state from one that only acquired a proposal now. Neither is
    # closed; conflating them is how "9 gates" became "19 gates".
    pre_existing = {d.id for d in a10_decisions.DECISIONS.values() if d.pre_existing}
    newly = {d.id for d in a10_decisions.DECISIONS.values() if not d.pre_existing}
    by_decision_age = {
        'closing_decision_already_registered': sum(
            1 for g in matrix if g['closing_decision'] in pre_existing),
        'closing_decision_drafted_in_this_assignment': sum(
            1 for g in matrix if g['closing_decision'] in newly),
        'no_closing_decision': sum(1 for g in matrix if not g['closing_decision']),
    }

    return {
        '_note': ('Derived from CUST03, the decision register in '
                  'sitewise/project1/a10_decisions.py and the gate register in '
                  'a10_gates.py. Every count is computed; none is transcribed.'),
        'register_version': 'a10-gate-reconciliation/1',
        'source': {
            'contract': 'P3-01C-VNEXT-0.6.1-CUST-REC',
            'registry_version': reg.registry_version,
            'registry_sha256': reg.sha256,
            'decision_register_version': a10_decisions.REGISTER_VERSION,
        },
        'corrections_to_prior_reporting': [
            {
                'claim': 'There are 19 admission gates.',
                'finding': ('19 is the number of rows in '
                            'approval_gate_matrix. report_availability references '
                            'five further gate identifiers that have no matrix '
                            'row, so 24 distinct gate identities block publication.'),
                'evidence': 'a10_gates.undefined_gate_ids()',
            },
            {
                'claim': 'Nine gates are CLOSED_BY_DECISION.',
                'finding': ('The label meant "a decision exists that would close '
                            'this gate if adopted". gates_closed was 0 throughout. '
                            'The disposition is now CLOSING_DECISION_IDENTIFIED and '
                            'the legacy string survives only as an alias.'),
                'evidence': 'Gate.closed is False for all 24 identities',
            },
            {
                'claim': 'Section blocking gates can be matched to matrix gates by name.',
                'finding': ('They cannot: blocking_gates holds identifiers (G04) '
                            'and the matrix holds names (G04 expert-panel content '
                            'validity). A name comparison resolves 3 of 8.'),
                'evidence': 'a10_gates._gate_id / gate_map keyed by identifier',
            },
        ],
        'counts': {
            **counts,
            'matrix_gates_by_decision_age': by_decision_age,
        },
        'gates': gates,
        'undefined_gate_ids': [g['gate_id'] for g in undefined],
        'report_sections': sections,
        'refusal_codes': REFUSAL_CODES,
        'decisions': [{
            'id': d.id,
            'title': d.title,
            'owner': d.owner,
            'status': d.status,
            'gates': list(d.gates),
            'components': list(d.components),
            'pre_existing': d.pre_existing,
            'superseded_by': d.superseded_by or None,
            'meanwhile': d.meanwhile,
            'note': d.note or None,
        } for d in a10_decisions.DECISIONS.values()],
    }


def claim_mapping() -> dict:
    reg = load_registry()
    claims = []
    for claim in PROPOSED_CLAIMS:
        entry = reg.questions[claim.question_id]
        claims.append({
            'claim_id': claim.claim_id,
            'question_id': claim.question_id,
            'construct_id': claim.construct_id,
            'section_id': claim.section_id,
            'response_kind': claim.response_kind,
            'permitted_claim': claim.permitted_claim,
            'prohibited_inference': list(claim.prohibited_inference),
            'approved': claim.approved,
            'status': 'PROPOSED_NOT_ADOPTED',
            'blocked_by': 'D-01 (no claim register adopted)',
            'instrument_gate': entry.instrument_gate,
            'template_usable_for_substantive_report':
                entry.template_usable_for_substantive_report,
            'report_sections': list(entry.report_sections),
        })
    unmapped = [qid for qid, entry in reg.questions.items()
                if not entry.report_sections]
    return {
        '_note': ('A proposal for the claim register required by D-01. Derived '
                  'from the hash-pinned explanation registry; every '
                  'permitted_claim and prohibited_inference is copied verbatim '
                  'from the instrument. Nothing here is adopted: '
                  'authority_granted_by_this_document is NONE.'),
        'register_version': 'a10-claim-register-proposal/1',
        'authority_granted_by_this_document': 'NONE',
        'source_registry_version': reg.registry_version,
        'source_registry_sha256': reg.sha256,
        'counts': {
            'claims_proposed': len(claims),
            'claims_approved': sum(1 for c in claims if c['approved']),
            'items_with_a_section': len({c['question_id'] for c in claims}),
            'items_without_a_section': len(unmapped),
        },
        'items_without_a_section': unmapped,
        'claims': claims,
        'adoption_requirement': (
            'Each claim needs a dated, attributed act naming the section, the '
            'permitted sentence and an evidence hash. '
            'AdoptedClaimRegister.from_adoption refuses a claim without all three.'),
    }


def main() -> None:
    _dump(RECON, reconciliation())
    _dump(CLAIMS, claim_mapping())


if __name__ == '__main__':
    main()
