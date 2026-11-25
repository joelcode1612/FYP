"""CP-06 — measure what each prompt version actually costs to send.

`max_tokens` is an output cap and says nothing about input. This measures the
input: the composed message list, serialised exactly as `Prompt.messages()`
serialises it, against a fixed source packet.

Both versions are measured against the *same* source, so the difference is the
prompt and the schema, not the data. A character count is not a token count and
is not reported as one; the ratio is what transfers.

Usage (from repo root):
    backend/.venv/Scripts/python.exe prompt_eval/scripts/measure_prompt_cost.py
"""
from __future__ import annotations

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'backend' / 'src'))
sys.path.insert(0, str(ROOT / 'prompt_eval'))

import fixtures  # noqa: E402
from candidates import BDJ_V5, QG_V5  # noqa: E402
from contracts_v5 import ObjectiveProposalV2  # noqa: E402
from sitewise.project1.objective_proposal import ObjectiveProposal  # noqa: E402
from sitewise.project1.prompts import PROMPTS  # noqa: E402
from sitewise.project1.qg_contract import ConfirmedFacts  # noqa: E402
from sitewise.project1.qg_fixed_options import FixedOptionCandidate  # noqa: E402

OUT_DIR = ROOT / 'prompt_eval' / 'results'


def message_bytes(prompt, source: dict, schema: dict) -> dict:
    messages = prompt.messages(source, schema)
    serialised = json.dumps(messages, ensure_ascii=False)
    system = messages[0]['content']
    examples = messages[1:-1]
    return {
        'messages': len(messages),
        'system_chars': len(system),
        'instruction_chars': len(prompt.instruction),
        'example_messages': len(examples),
        'example_chars': sum(len(m['content']) for m in examples),
        'total_chars': len(serialised),
        'total_bytes_utf8': len(serialised.encode('utf-8')),
    }


def main() -> int:
    bdj_case = next(c for c in fixtures.bdj_cases() if c['id'] == 'bdj_priced_hypothesis')
    bdj_source = fixtures.packet(bdj_case['declarations'], seed='cost-bdj')

    qg_case = next(c for c in fixtures.qg_cases() if c['id'] == 'qg_complete_offer')
    qg_source = {
        'contract_version': 'P1-QG-FIXED-OPTION-1.0',
        'schema_version': 'project1-qg-confirmed-facts/2-candidate',
        'source_fingerprint': 'b' * 64,
        'confirmed_facts': ConfirmedFacts(**qg_case['facts']).model_dump(),
        'policy_version': 'COST-MEASUREMENT-ONLY',
    }

    rows = []
    for family, baseline_prompt, candidate_prompt, source, base_schema, cand_schema in (
        ('bdj', PROMPTS['BDJ_OBJECTIVE_M2V2'], BDJ_V5, bdj_source,
         ObjectiveProposal.model_json_schema(), ObjectiveProposalV2.model_json_schema()),
        ('qg', PROMPTS['QG_FIXED_OPTION'], QG_V5, qg_source,
         FixedOptionCandidate.model_json_schema(), FixedOptionCandidate.model_json_schema()),
    ):
        base = message_bytes(baseline_prompt, source, base_schema)
        cand = message_bytes(candidate_prompt, source, cand_schema)
        rows.append({
            'family': family,
            'baseline_version': baseline_prompt.version,
            'candidate_version': candidate_prompt.version,
            'baseline': base,
            'candidate': cand,
            'delta_total_chars': cand['total_chars'] - base['total_chars'],
            'delta_pct': round(100 * (cand['total_chars'] - base['total_chars'])
                               / base['total_chars'], 1),
        })

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    payload = {'checkpoint': 'CP-06-INPUT-COST', 'generated_at': '2026-11-25',
               'network_calls': 0,
               'note': ('Character counts, not token counts. The ratio transfers; '
                        'the absolute number does not.'),
               'measurements': rows}
    (OUT_DIR / 'PROMPT_INPUT_COST_20261125.json').write_text(
        json.dumps(payload, indent=2) + '\n', encoding='utf-8')

    for row in rows:
        b, c = row['baseline'], row['candidate']
        print(f"{row['family'].upper()}")
        print(f"  {row['baseline_version']:32s} instr={b['instruction_chars']:5d} "
              f"examples={b['example_messages']:2d} ({b['example_chars']:6d} chars) "
              f"total={b['total_chars']:6d}")
        print(f"  {row['candidate_version']:32s} instr={c['instruction_chars']:5d} "
              f"examples={c['example_messages']:2d} ({c['example_chars']:6d} chars) "
              f"total={c['total_chars']:6d}")
        print(f"  delta = {row['delta_total_chars']:+7d} chars ({row['delta_pct']:+.1f}%)")
        print()
    print(f"wrote -> {OUT_DIR / 'PROMPT_INPUT_COST_20261125.json'}")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
