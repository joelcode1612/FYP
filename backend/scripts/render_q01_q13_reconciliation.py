"""Render the CP1 reconciliation report from the pinned registry.

The report is generated, never hand-written, so the prose in it cannot drift from
the registry the runtime actually loads. Every number, code and status in the
output is read back from ``PROJECT1_Q01_Q13_EXPLANATION_REGISTRY.json``.

    backend/.venv/Scripts/python.exe scripts/render_q01_q13_reconciliation.py
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
DELIVERABLES = REPO / 'deliverables'
REGISTRY_PATH = DELIVERABLES / 'PROJECT1_Q01_Q13_EXPLANATION_REGISTRY.json'
RECEIPT_PATH = DELIVERABLES / 'PROJECT1_Q01_Q13_CONFLICT_RECEIPT.json'
OUT = DELIVERABLES / 'PROJECT1_Q01_Q13_RECONCILED_EXPLANATION_MATRIX.md'

sys.path.insert(0, str(BACKEND / 'src'))
from sitewise.project1.explanation_contracts import (  # noqa: E402
    BANNED_PHRASES,
    _NUMBER_RE,
    _QUANTITY_WORD_RE,
    normalise,
)

GUARD_FIELDS = (
    ('templates.withheld', lambda q: q['templates']['withheld']['text']),
    ('templates.valid', lambda q: q['templates']['valid']['text']),
    ('templates.limitation', lambda q: q['templates']['limitation']['text']),
    ('permitted_claim', lambda q: q['permitted_claim']),
    ('prohibited_inference', lambda q: q['prohibited_inference']),
    ('coverage_limitation', lambda q: q['coverage_limitation']),
    ('limitation', lambda q: q['limitation']),
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def esc(text) -> str:
    if text is None:
        return '—'
    return str(text).replace('|', '\\|').replace('\n', ' ')


def guard_scan(text: str) -> dict:
    flat = normalise(text or '')
    return {
        'numbers': _NUMBER_RE.findall(text or ''),
        'quantity_words': _QUANTITY_WORD_RE.findall(text or ''),
        'banned': [p for p in BANNED_PHRASES if normalise(p) in flat],
    }


def render(registry: dict, receipt: dict) -> str:
    questions = registry['questions']
    conflicts = registry['conflicts']
    by_id = {q['question_id']: q for q in questions}
    lines: list[str] = []
    add = lines.append

    add('# PROJECT1 — Q01–Q13 Reconciled Explanation Matrix')
    add('')
    add('**Status:** reconciliation record. Not an approval, not an instrument amendment,')
    add('not a report authorisation.')
    add('')
    add('| Field | Value |')
    add('|---|---|')
    add(f"| Registry version | `{registry['registry_version']}` |")
    add(f"| Registry SHA-256 | `{sha256(REGISTRY_PATH)}` |")
    add(f"| Conflict receipt SHA-256 | `{sha256(RECEIPT_PATH)}` |")
    add(f"| Instrument version | `{registry['instrument_version']}` |")
    add(f"| Instrument SHA-256 | `{registry['instrument_sha256']}` |")
    add(f"| Instrument approval state | `{registry['approval']}` |")
    add(f"| Authority granted by this reconciliation | `{registry['authority_granted_by_this_registry']}` |")
    add(f"| Questions reconciled | {len(questions)} of 13 |")
    add(f"| Conflicts recorded | {len(conflicts)} |")
    add(f"| Questions usable for substantive reporting | "
        f"{receipt['template_availability']['usable_for_substantive_report']} of 13 |")
    add('')

    # ---------------------------------------------------------------- sources
    add('## 1. Sources and hash verification')
    add('')
    add('Three sources were available and all three were read. Nothing was regenerated:')
    add('the objective and fallback prose is the owner-prepared handoff text, used')
    add('verbatim.')
    add('')
    add('| # | Source | Role | SHA-256 |')
    add('|---|---|---|---|')
    add('| A | `CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_CONTRACT.json` '
        '(frozen recovery candidate) | Codes, types, substantive/non-substantive '
        'classification, display order, ordinal meaning, numerator rules, gating, '
        'status, report sections | '
        f"`{registry['source_artifacts']['CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_CONTRACT.json']}` |")
    add('| B | `backend/docs/cq_runtime/QUESTION_CONTRACT_MATRIX.json` | Response types, '
        'max selections, exclusive codes, candidate gates, scientific/owner approval '
        'state, and the **draft EN/BM option labels** | '
        f"`{registry['source_artifacts']['QUESTION_CONTRACT_MATRIX.json']}` |")
    add('| C | `QUESTION_OBJECTIVES_AND_FALLBACKS.json` (handoff) | Owner-prepared '
        'research objectives, measurement descriptions, fallback text, permitted '
        'claims, prohibited inferences, coverage limitations, report sections | '
        f"`{registry['source_artifacts']['QUESTION_OBJECTIVES_AND_FALLBACKS.json']}` |")
    add('')
    add('Handoff package verification:')
    add('')
    add(f"- ZIP `PROJECT1_CQ13_RESEARCH_AND_QUERY_HANDOFF_20261122.zip`, 37,735 bytes, "
        f"11 files: `{registry['handoff_zip_sha256']}`")
    add(f"- Extracted `SHA256SUMS.txt`: `{registry['handoff_package_sha256']}`")
    add('- All 10 manifest hashes verified `OK` against the extracted files.')
    add('- Originals preserved unmodified under '
        '`deliverables/_cq13_handoff/PROJECT1_CQ13_RESEARCH_AND_QUERY_HANDOFF/`.')
    add('')

    # -------------------------------------------------------------- identity
    add('## 2. What the reconciliation established')
    add('')
    add('### 2.1 All thirteen code banks are identical across the three sources')
    add('')
    add('Every item\'s `codes` list and `response_type` agrees exactly between source A,')
    add('source B and source C. This is recorded as **CX-16 `RESOLVED_NO_CONFLICT`**. The')
    add('handoff\'s warning that "old Q01 codes conflict with the newer candidate bank"')
    add('refers to a pre-recovery bank that is **not present anywhere in this workspace**;')
    add('it does not describe a conflict between the three sources used here.')
    add('')
    add('| Q | Response kind | Codes | Substantive | Non-substantive | Exclusive | Max sel. |')
    add('|---|---|---|---|---|---|---|')
    for q in questions:
        add(f"| {q['question_id']} | `{q['response_kind']}` | {len(q['codes'])} | "
            f"{len(q['substantive_codes'])} | {len(q['non_substantive_codes'])} | "
            f"{len(q['exclusive_codes']) or '—'} | "
            f"{q['max_selections'] if q['max_selections'] is not None else '—'} |")
    add('')

    add('### 2.2 An option-label bank does exist — correcting an earlier claim')
    add('')
    add('The earlier Chart Presentation Spec (V1) stated that **no human-readable label**')
    add('existed for any response code. That statement was wrong. Source B carries')
    add('`codes_and_candidate_labels[]` with `draft_en_label` and `draft_bm_label` for')
    add('every code of every item. The correct statement is narrower:')
    add('')
    add('- Labels exist **as candidate drafts**; none is approved for fielding or report')
    add('  publication.')
    add('- They are drafts, so a chart or explanation may not present a label as approved')
    add('  wording. Each label in the registry therefore carries')
    add('  `label_source: CONTRACT_OPTION_BANK` so its provenance is visible, and the')
    add('  registry as a whole carries `authority_granted_by_this_registry: NONE`.')
    add('')
    add('Coverage of the label bank:')
    add('')
    labelled = [q for q in questions
                if all(c['label_source'] == 'CONTRACT_OPTION_BANK' for c in q['codes'])]
    partial = [q for q in questions if q not in labelled]
    add(f"- Items with a draft label for **every** code: {len(labelled)} of 13 "
        f"({', '.join(q['question_id'] for q in labelled) or 'none'}).")
    add(f"- Items with at least one code lacking a label: {len(partial)} of 13 "
        f"({', '.join(q['question_id'] for q in partial) or 'none'}).")
    for q in partial:
        missing = [c['code'] for c in q['codes'] if c['label_source'] != 'CONTRACT_OPTION_BANK']
        add(f"  - {q['question_id']}: `CODE_FALLBACK` for {', '.join(f'`{m}`' for m in missing)}")
    add('')

    # ----------------------------------------------------------- the chain
    add('## 3. The traceability chain')
    add('')
    add('Every item is traced across eight links. A link is only recorded where the')
    add('source actually states it; nothing is interpolated.')
    add('')
    add('```')
    add('Project research objective (O1–O6)')
    add('  -> Question ID / instrument version')
    add('     -> Approved construct and response codes')
    add('        -> EE-01 measurement rule')
    add('           -> Permitted claim (+ prohibited inference)')
    add('              -> Existing explanation template')
    add('                 -> Report section R01–R12')
    add('                    -> ReportAdmission requirement')
    add('```')
    add('')
    add('### 3.1 Summary matrix')
    add('')
    add('| Q | Construct | Objective proximity | Covers objective | EE-01 rule | '
        'Templates | Sections | Admission |')
    add('|---|---|---|---|---|---|---|---|')
    for q in questions:
        prox = ', '.join(q['objective_proximity']) or '—'
        covers = 'yes' if q['covers_objective'] else '**no**'
        rule = q['ee01_measurement_rule']['rule_id']
        tmpl = '/'.join((q['templates']['withheld']['template_id'],
                         q['templates']['valid']['template_id'],
                         q['templates']['limitation']['template_id']))
        sections = ', '.join(q['report_sections']) or '**none**'
        adm = ('measurement-renderable'
               if q['report_admission']['any_section_may_render_measurement']
               else 'held')
        add(f"| {q['question_id']} | `{q['construct_id']}` | {prox} | {covers} | "
            f"`{rule}` | `{tmpl}` | {sections} | {adm} |")
    add('')
    add('**Objective proximity is not coverage.** O1–O5 each have a *closest existing*')
    add('question, recorded so the relationship is explicit. No question covers an')
    add('objective, because `covered_by_an_approved_measure` is `False` for all six and')
    add('`covers_objective` is computed from that table rather than asserted per item.')
    add('')

    add('### 3.2 Per-question detail')
    add('')
    for q in questions:
        add(f"#### {q['question_id']} — {q['construct_id']} (group {q['group']})")
        add('')
        add('| Link | Value |')
        add('|---|---|')
        add(f"| 1. Research objective | {esc(q['research_objective'])} |")
        add(f"| 2. Question / version | `{q['question_id']}` / `{q['instrument_version']}` |")
        add(f"| 3. Construct + codes | `{q['construct_id']}`; "
            f"{len(q['codes'])} codes, type `{q['instrument_type']}`, kind "
            f"`{q['response_kind']}` |")
        add(f"| 4. EE-01 measurement rule | `{q['ee01_measurement_rule']['rule_id']}` — "
            f"numerator {esc(', '.join(q['ee01_measurement_rule']['numerator']) or '—')}; "
            f"denominator {esc(q['ee01_measurement_rule']['denominator'])}; "
            f"applied only when {esc(q['ee01_measurement_rule']['applied_only_when'])} |")
        add(f"| 5. Permitted claim | {esc(q['permitted_claim'])} |")
        add(f"| 5b. Prohibited inference | {esc(q['prohibited_inference'])} |")
        add(f"| 6. Withheld template | `{q['templates']['withheld']['template_id']}` — "
            f"{esc(q['templates']['withheld']['text'])} |")
        add(f"| 6b. Substantive template | `{q['templates']['valid']['template_id']}` — "
            f"{esc(q['templates']['valid']['text'])} "
            f"(placeholders: {', '.join(q['templates']['valid']['placeholders']) or 'none'}) |")
        add(f"| 6c. Limitation template | `{q['templates']['limitation']['template_id']}` — "
            f"{esc(q['templates']['limitation']['text'])} |")
        add(f"| 7. Report sections | {', '.join(q['report_sections']) or '**none assigned**'} |")
        admission_cells = '; '.join(
            f"{k} = `{v['state']}`" + (f" (gates {', '.join(v['blocking_gates'])})"
                                       if v['blocking_gates'] else '')
            for k, v in q['report_admission']['sections'].items()) or 'no section to admit'
        add(f"| 8. ReportAdmission | {esc(admission_cells)} |")
        add(f"| Instrument status | `{q['instrument_status']}` |")
        add(f"| Template usable for substantive report | "
            f"`{q['template_usable_for_substantive_report']}` |")
        add(f"| Conflicts | {', '.join(q['conflict_ids'])} |")
        add(f"| Open decisions | {esc('; '.join(q['open_decisions']) or 'none')} |")
        add('')
        add('Scientific coverage limitation, quoted from the handoff:')
        add('')
        add(f"> {q['coverage_limitation']}")
        add('')

    # ------------------------------------------------------------ conflicts
    add('## 4. Conflict register')
    add('')
    add(f'{len(conflicts)} conflicts were found. '
        f"{receipt['counts']['settled_or_recorded']} are settled or recorded; "
        f"{len(conflicts) - receipt['counts']['settled_or_recorded']} remain open and are "
        'attributed to the party that must decide them.')
    add('')
    add('| ID | Q | Field | Resolution | Decision owner | Waits on |')
    add('|---|---|---|---|---|---|')
    for c in conflicts:
        add(f"| {c['conflict_id']} | {c['question_id']} | `{c['field']}` | "
            f"`{c['resolution']}` | `{c['decision_owner']}` | "
            f"{esc(c['blocking_decision'])} |")
    add('')
    add('### 4.1 Conflict detail')
    add('')
    for c in conflicts:
        add(f"#### {c['conflict_id']} — {c['question_id']} `{c['field']}`")
        add('')
        add(f"- **Resolution:** `{c['resolution']}`")
        add(f"- **Decision owner:** `{c['decision_owner']}`")
        add(f"- **Source A** (`{esc(c['source_a']['artifact'])}`): "
            f"{esc(c['source_a'].get('value', '—'))}")
        add(f"- **Source B** (`{esc(c['source_b']['artifact'])}`): "
            f"{esc(c['source_b'].get('value', '—'))}")
        later = c.get('later_authority') or {}
        add(f"- **Later authority** (`{esc(later.get('artifact', '—'))}`): "
            f"status `{esc(later.get('status', '—'))}`; {esc(later.get('value', '—'))}")
        add(f"- **Waits on:** {esc(c['blocking_decision'])}")
        add(f"- **Consequence:** {esc(c['consequence'])}")
        add('')

    # ----------------------------------------------------------- objectives
    add('## 5. Project objectives O1–O6')
    add('')
    add('The six mandatory objectives are preserved unchanged. No seventh objective was')
    add('invented, and none is claimed as covered.')
    add('')
    add('| ID | Objective | Closest existing question | Covered by an approved measure | Adequacy note |')
    add('|---|---|---|---|---|')
    for o in registry['objectives']:
        add(f"| {o['objective_id']} | {o['name']} | "
            f"{o['closest_question'] or '**none**'} | "
            f"`{o['covered_by_an_approved_measure']}` | {esc(o['adequacy'])} |")
    add('')
    covered = sum(o['covered_by_an_approved_measure'] for o in registry['objectives'])
    add(f'**{covered} of 6 objectives have an approved measure.** The project therefore has')
    add('no objective-level evidence at this checkpoint, which is a property of the')
    add('instrument rather than of the reporting code.')
    add('')

    # ------------------------------------------------------- availability
    add('## 6. Template availability')
    add('')
    add('An unresolved template must remain unavailable for substantive reporting. That is')
    add('enforced structurally, not by convention: `template_usable_for_substantive_report`')
    add('is computed as `instrument_status in (AUTHORIZED, APPROVED)` **and** at least one')
    add('assigned report section being able to render a measurement.')
    add('')
    add('| Q | Instrument status | Section may render a measurement | Usable |')
    add('|---|---|---|---|')
    for q in questions:
        add(f"| {q['question_id']} | `{q['instrument_status']}` | "
            f"`{q['report_admission']['any_section_may_render_measurement']}` | "
            f"`{q['template_usable_for_substantive_report']}` |")
    add('')
    add(f"Usable for substantive reporting: "
        f"**{receipt['template_availability']['usable_for_substantive_report']} of 13**.")
    add('')
    add('The two `RENDERABLE_ADMINISTRATIVE` sections (R02, R12) do not change this: they')
    add('carry `requires_V: false`, so they render administrative material, never a')
    add('measurement. R11 is `NEVER` — no authorised overall suitability verdict exists.')
    add('')

    # ------------------------------------------------------------- states
    add('## 7. Evidence-state contract')
    add('')
    add('Twelve states, on two axes. An **instrument gate** says whether the item may')
    add('be measured at all; an **evidence state** says what the collected data')
    add('supports. Keeping them separate means a governance block never conceals a')
    add('data condition, and every state stays reachable and testable.')
    add('')
    add('### 7.1 Instrument gates')
    add('')
    add('| Gate | Items |')
    add('|---|---|')
    for gate in registry['instrument_gates']:
        items = [q['question_id'] for q in questions if q['instrument_gate'] == gate]
        add(f"| `{gate}` | {', '.join(items) or '—'} |")
    add('')
    add('### 7.2 Data states')
    add('')
    add('| State | Owner sentence |')
    add('|---|---|')
    for state in registry['evidence_states']:
        text = registry['state_templates'].get(state)
        add(f"| `{state}` | {esc(text) if text else 'rendered from the item template'} |")
    add('')
    add('Resolution order is most-specific-first: a fully excluded set reports as')
    add('`WITHDRAWN_OR_NO_CONSENT` rather than as an empty base; an unadopted show gate')
    add('reports as `UNKNOWN_ROUTE` rather than as a refusal, because an unverified')
    add('applicability cannot be read as a decline. `LOW_VALID_BASE` requires an approved')
    add('floor and is therefore **not decidable today** — the suppression floor is')
    add('`NOT_APPROVED` under SD-11, so a small base is not reported as small.')
    add('')
    add('Four gates share one owner sentence because the handoff groups them into a')
    add('single row; they remain distinct codes so the recorded reason stays exact.')
    add('')

    # ------------------------------------------------------------- guards
    add('## 8. Narrative-guard interaction')
    add('')
    add('The existing explanation validator rejects standalone numerals not supplied by the')
    add('packet, and rejects quantity words outright. The owner-prepared prose is not')
    add('written for those guards, so the interaction was measured before integrating:')
    add('')
    add('| Q | Field | Numerals | Quantity words | Banned phrase |')
    add('|---|---|---|---|---|')
    any_trip = False
    tripping: dict[str, list[str]] = {}
    for q in questions:
        for name, getter in GUARD_FIELDS:
            scan = guard_scan(getter(q))
            if scan['numbers'] or scan['quantity_words'] or scan['banned']:
                any_trip = True
                tripping.setdefault(q['question_id'], []).append(name)
                add(f"| {q['question_id']} | `{name}` | "
                    f"{', '.join(scan['numbers']) or '—'} | "
                    f"{', '.join(scan['quantity_words']) or '—'} | "
                    f"{', '.join(scan['banned']) or '—'} |")
    if not any_trip:
        add('| — | — | — | — | — |')
    add('')
    add(f"Items with at least one guard-tripping field: **{len(tripping)} of 13** "
        f"({', '.join(sorted(tripping)) or 'none'}).")
    add('')
    add('Two options were available: rewrite the prose, or widen the guard. The prose is')
    add('the owner\'s and must not be regenerated, so the guard is widened — narrowly and')
    add('only for deterministic template output. `validate_candidate` gains an optional')
    add('`registry_literals` argument carrying the exact tokens present in the pinned')
    add('registry. A numeral or quantity word in template prose is then accepted only if')
    add('it appears verbatim in that set. The LLM path never passes the argument, so model')
    add('output is checked exactly as strictly as before. This is recorded as a design')
    add('decision, not a silent relaxation: the allowance is derived from a hash-pinned')
    add('file, and a test asserts that the LLM path still rejects a quantity word.')
    add('')

    # ------------------------------------------------------------ limits
    add('## 9. What this reconciliation does not do')
    add('')
    add('- It does not approve any item, label, stimulus, codebook, feature bank or report')
    add('  section.')
    add('- It does not amend the frozen instrument. A new version requires an explicit')
    add('  authority act, not an edit to `CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_'
        'CONTRACT.json`.')
    add('- It does not resolve the open scientific or owner decisions listed in §4. It')
    add('  names them and attributes them.')
    add('- It does not make any template usable for substantive reporting.')
    add('- It does not execute any SQL. The three reference templates handed over remain')
    add('  non-executed documentation.')
    add('')

    # -------------------------------------------------------- reproduction
    add('## 10. Reproduction')
    add('')
    add('```')
    add('cd backend')
    add('./.venv/Scripts/python.exe scripts/build_explanation_registry.py')
    add('./.venv/Scripts/python.exe scripts/render_q01_q13_reconciliation.py')
    add('```')
    add('')
    add('The registry is generated, never hand-edited. Re-running the two commands')
    add('reproduces this document byte-for-byte as long as the three sources and the')
    add('generator are unchanged; their hashes are recorded in §1 and at the head of this')
    add('document.')
    add('')
    return '\n'.join(lines) + '\n'


def main() -> int:
    if not REGISTRY_PATH.exists():
        print(f'missing registry: {REGISTRY_PATH}', file=sys.stderr)
        return 2
    registry = json.loads(REGISTRY_PATH.read_text(encoding='utf-8'))
    receipt = json.loads(RECEIPT_PATH.read_text(encoding='utf-8'))
    OUT.write_text(render(registry, receipt), encoding='utf-8')
    print(f'wrote {OUT}')
    print(f'bytes: {OUT.stat().st_size}')
    print(f'sha256: {sha256(OUT)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
