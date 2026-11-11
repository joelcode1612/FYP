"""Pure candidate response validation; no scientific or fielding authority."""
from __future__ import annotations

import hashlib
import json


def digest(value: object) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=True,
                                     separators=(',', ':')).encode()).hexdigest()


def classify_answer(item: dict, value: object, q01_map: dict) -> tuple[str, str | None]:
    """Preserve raw payload separately; derive states from exact source codes.

    Q01 strict mutual exclusion is a successor proposal, not the frozen
    terminal-wins policy. Empty displayed responses are SKIPPED, not refusals.
    Matrix calls validate one feature cell at a time.
    """
    if value is None or value == []:
        return 'SKIPPED', None
    multi = item['type'] in {'multi_select', 'multi_select_with_exclusive_terminals'}
    codes = value if multi else [value]
    if not isinstance(codes, list) or not codes:
        return 'INVALID', 'E_RESPONSE_SHAPE'
    if any(not isinstance(c, str) or c not in item['codes'] for c in codes):
        return 'INVALID', 'E_UNKNOWN_CODE'
    if len(codes) != len(set(codes)):
        return 'INVALID', 'E_DUPLICATE_CODE'
    exclusives = set(item['exclusive_codes'])
    # An explicit refusal cannot be mixed with a substantive response.
    exclusives.update(c for c, s in item.get('option_to_state_map', {}).items()
                      if s == 'REFUSED')
    if exclusives.intersection(codes) and len(codes) != 1:
        return 'INVALID', 'E_EXCLUSIVE_CODE_CONFLICT'
    cap = item.get('max_selections')
    counted = item.get('counts_toward_max_selections', item['substantive_codes'])
    if cap is not None and sum(c in counted for c in codes) > cap:
        return 'INVALID', 'E_MAX_SELECTIONS'
    mapping = q01_map if item['id'] == 'Q01' else item['option_to_state_map']
    states = {mapping[c] for c in codes}
    if len(states) != 1:
        return 'INVALID', 'E_MIXED_RESPONSE_STATES'
    state = states.pop()
    reason = '|'.join(codes) if state in {'ANSWERED_NON_SUBSTANTIVE', 'REFUSED'} else None
    return state, reason


def q01_screen(item: dict, state: str, value: object) -> str:
    if state == 'INVALID':
        return 'SCREEN_INVALID'
    if state == 'ANSWERED_SUBSTANTIVE':
        return 'ELIGIBLE'
    if state == 'ANSWERED_NON_SUBSTANTIVE' and isinstance(value, list) and len(value) == 1:
        return item['eligibility_effect'][value[0]]
    return 'AREA_UNKNOWN'


def validate_structured_pretest(question: str, locale: str, check: str,
                                result: str, policy: dict) -> None:
    metadata = policy['structured_pretest'].get(question)
    if metadata is None or locale not in metadata['locales']:
        raise ValueError('Unregistered pretest item or locale.')
    if check not in metadata['checks'] or result not in metadata['result_choices']:
        raise ValueError('Pretests accept registered closed-ended codes only.')
