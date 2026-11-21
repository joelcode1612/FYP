"""Build a human-readable run report from the BDJ evidence artefacts.

Reads only the delivered JSON. Writes RUN_11Q_BDJ.md next to them.

The report deliberately does NOT invent a research objective. The system cannot
produce one yet (confirm_objective returns 409), and the findings themselves say
"do not confirm a research objective automatically". Inventing one here would be
the exact fabrication the whole chain is guarded against.

Run:
    backend/.venv/Scripts/python.exe -B tools/bdj_output_verification/build_run_report.py \
        [evidence_dir]
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFINITION = ROOT / 'src/sitewise/instruments/m2v1_20261114/definition.json'


def load(path: Path):
    return json.loads(path.read_text(encoding='utf-8'))


def main(argv: list[str]) -> int:
    default = ROOT.parent / 'artifacts/stage34_integration_20261121/g5_runfile'
    ev = Path(argv[1]).resolve() if len(argv) > 1 else default
    packet = load(ev / '01_input_packet.json')
    output = load(ev / '02_evaluated_output.json')
    db = load(ev / '03_database_evidence.json')
    evid = load(ev / 'g2_output_evidence.json')

    questions = {}
    if DEFINITION.is_file():
        for item in load(DEFINITION)['items']:
            questions[item['item_key']] = item.get('question_text') or item.get('title') or ''

    decls = packet['declarations']
    findings = output['issues']
    admission = db.get('admission') or {}
    cls = db.get('classification') or {}
    persisted = evid.get('persisted') or {}

    L = []
    L.append('# BDJ run — 11 M2V1 answers → 3 findings → objective NOT produced\n')
    L.append('**Generated from the evidence artefacts, not retyped.** '
             '`tools/bdj_output_verification/build_run_report.py`\n')
    L.append('| | |')
    L.append('|---|---|')
    L.append(f'| Assessment / revision | `{evid.get("assessment_id")}` / {evid.get("revision")} |')
    L.append(f'| Confirmation | `{evid.get("confirmation_id")}` |')
    L.append(f'| Result | `{evid.get("result_id")}` |')
    L.append(f'| Source fingerprint | `{evid.get("source_fingerprint")}` |')
    L.append(f'| Ruleset | `{evid.get("ruleset_version")}` (PROPOSED, not adopted) |')
    L.append(f'| Provider | `{cls.get("transport")}` — **no model called** |')
    L.append(f'| Output provenance | `{cls.get("output_provenance")}` |')
    L.append('')

    L.append('## 1. The 11 questions and the answers sent\n')
    L.append('| # | Item | Question | Answer | Answer revision |')
    L.append('|---|---|---|---|---|')
    for n, d in enumerate(decls, 1):
        value = d.get('value')
        value = ', '.join(value) if isinstance(value, list) else value
        L.append(f"| {n} | `{d['item_key']}` | {questions.get(d['item_key'], '')} "
                 f"| `{value}` | `{d['answer_revision_id']}` |")
    L.append('')
    L.append(f'All {len(decls)} answer revisions and all item keys are asserted to be '
             'present in the request body the transport received '
             f'(`request_carries_all_11_answers: {evid.get("request_carries_all_11_answers")}`).\n')

    L.append('## 2. What the model would receive\n')
    req = ev / '06_bdj_request.json'
    if req.is_file():
        body = load(req)
        messages = body.get('messages') or []
        L.append(f'Exact request body: `06_bdj_request.json` — model `{body.get("model")}`, '
                 f'{len(messages)} message(s), {req.stat().st_size} bytes.\n')
        for m in messages:
            content = m.get('content')
            size = len(content) if isinstance(content, str) else 0
            L.append(f'- role `{m.get("role")}` — {size} chars')
        L.append('')
        L.append('The packet above (all 11 declarations with their exact answer revision '
                 'ids) is serialised into that request. No prompt text, completion or '
                 'provider payload is reproduced here.\n')
    else:
        L.append('_Request body artefact not found._\n')

    L.append('## 3. The three findings produced\n')
    L.append('| Rule | Signal | Source | Quote | Observed condition |')
    L.append('|---|---|---|---|---|')
    for f in findings:
        r = f['source_refs'][0]
        L.append(f"| `{f['rule_id']}` | `{f['discovery_signal']}` | `{r['item_key']}` "
                 f"| `{r['quote']}` | {f['observed_condition']} |")
    L.append('')
    L.append(f"Each finding is a **`INFORMATION_GAP`** — a restatement of a declared "
             f"uncertainty, not a defect, contradiction or business fact.\n")

    L.append('## 4. Findings → research objective: NOT PRODUCED\n')
    L.append('The chain stops here, by design. Two separate facts:\n')
    L.append('1. **The findings do not contain an objective.** Their own `next_action` '
             'reads: *"do not alter the answer or confirm a research objective '
             'automatically."*')
    L.append('2. **The system refuses to create one.** `POST '
             '/confirmations/{id}/research-objectives` with `origin="BDJ"` returns '
             '`409 M2_UNCERTAINTY_LINK_REQUIRED`, because no finding-approval table '
             'exists yet.\n')
    L.append('So no objective text is shown, because none was produced. Writing one '
             'here would be fabrication.\n')
    L.append('**What would change this** (authorised by decision S1/A1/P1, not yet built):\n')
    L.append('| Step | State |')
    L.append('|---|---|')
    L.append(f'| Finding has a durable id | **done** — {len(admission.get("finding_ids") or [])} ids |')
    L.append(f'| Finding linked to the result | **done** — {persisted.get("bdj_result_findings")} links |')
    L.append('| Owner approves it (S1 review event) | **not built** — no table exists |')
    L.append('| Finding becomes objective-eligible | blocked behind approval |')
    L.append('| Objective text authored | by the owner, not by the system (P1) |')
    L.append('| BCB packet | blocked independently |')
    L.append('| Questionnaire | blocked independently |')
    L.append('')
    L.append('The finding ids available to approve:\n')
    for fid in admission.get('finding_ids') or []:
        L.append(f'- `{fid}`')
    L.append('')

    L.append('## 5. Evidence\n')
    L.append('| File | Contents |')
    L.append('|---|---|')
    for name, what in (
            ('01_input_packet.json', 'the confirmed 11-item projection sent to BDJ'),
            ('02_evaluated_output.json', 'the three findings'),
            ('03_database_evidence.json', 'result row, 11 sources, links, attempt, classification'),
            ('04_readback_comparison.json', 'HTTP vs restricted-connection readback'),
            ('05_queries.sql', 'read-only queries for this run'),
            ('06_bdj_request.json', 'the exact request body a model would receive'),
    ):
        L.append(f'| `{name}` | {what} |')
    L.append('')
    L.append('---\n')
    L.append('> No model was called. No cloud request left the process. Original `Dss` '
             'was not read or written. This is a synthetic fixture evaluation under a '
             'scoped synthetic-only decision, not production verification.')

    out = ev / 'RUN_11Q_BDJ.md'
    out.write_text('\n'.join(L) + '\n', encoding='utf-8')
    print(f'wrote {out}')
    print(f'{len(decls)} answers, {len(findings)} findings, '
          f'{len(admission.get("finding_ids") or [])} finding ids')
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
