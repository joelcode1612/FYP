"""Experimental V5 candidates, dispatchable without touching the production registry.

The brief requires the working prompts to be preserved. So the candidates are
NOT added to `sitewise.project1.prompts.PROMPTS`: they are constructed here from
their versioned instruction files and reuse the production `Prompt` dataclass.
That gives byte-identical message construction (same invariant suffix, same
`canonical()` serialisation) and a fingerprint computed by the same function, so
a V5 run can be compared with a V4 run without either one being privileged.

Nothing in the production code path imports this module.
"""
from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend' / 'src'))

from sitewise.project1.prompts import Prompt  # noqa: E402

PROMPT_DIR = ROOT / 'prompt_eval' / 'prompts'


def _instruction(stem: str) -> str:
    path = PROMPT_DIR / f'{stem}.instruction.txt'
    return path.read_text(encoding='utf-8').strip()


BDJ_V5 = Prompt(
    'BDJ-OBJECTIVE-5-M2V2-CAND',
    'You are a bounded research-objective proposer for a cafe business plan.',
    _instruction('bdj_objective_v5'),
)

QG_V5 = Prompt(
    'QG-FIXED-OPTION-5-CAND',
    'Draft an unfieldable fixed-option research question for owner review.',
    _instruction('qg_fixed_option_v5'),
)

CANDIDATES: dict[str, Prompt] = {
    'BDJ_OBJECTIVE_V5': BDJ_V5,
    'QG_FIXED_V5': QG_V5,
}

#: Pairs the comparison uses. Each entry is (baseline stage key, candidate key).
COMPARISON_PAIRS = {
    'bdj': ('BDJ_OBJECTIVE_M2V2', 'BDJ_OBJECTIVE_V5'),
    'qg': ('QG_FIXED_OPTION', 'QG_FIXED_V5'),
}


def baseline(stage_key: str) -> Prompt:
    from sitewise.project1.prompts import PROMPTS
    return PROMPTS[stage_key]


def describe() -> dict:
    out = {}
    for key, prompt in CANDIDATES.items():
        out[key] = {
            'version': prompt.version,
            'fingerprint': prompt.fingerprint,
            'role_chars': len(prompt.role),
            'instruction_chars': len(prompt.instruction),
            'examples': len(prompt.examples),
        }
    return out


if __name__ == '__main__':
    import json
    print(json.dumps(describe(), indent=2))
