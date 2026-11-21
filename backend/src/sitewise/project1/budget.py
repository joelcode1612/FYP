"""The authoritative provider-attempt budget.

Why this module exists
----------------------
The limit used to live in two unrelated places: a ``BUDGET = 6`` constant inside
a test-side campaign runner, and a ``len(previous) >= 6`` check inside the
production ledger. Neither was the other's authority, and a change to one would
have silently disagreed with the other. This module is the single place the
authorized ceiling is stated.

What it is not
--------------
* Not a flag. There is no argument, environment variable or API field that can
  raise the limit at run time; raising it is a code change a reviewer can see.
* Not a reset. ``reserve`` only ever increments ``spent`` and appends to
  ``attempts``. Existing attempt records are preserved across limit changes, so
  the ledger stays a history rather than becoming a counter that can be zeroed.
* Not a cost control by itself. The zero-cost ceiling lives in the provider
  configuration; this bounds *attempts*, and the two are independent.

Reservation order matters: the slot is consumed and fsynced to disk **before** a
transport is constructed, so a crash after the increment consumes the slot rather
than refunding it. An attempt that was never made is cheap to explain; an
unbounded loop that lost count is not.
"""
from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path

#: The Project Owner's authorized cumulative limit (directive V3.0, CP-03).
#: Historical attempts are preserved; this is a ceiling, not a reset.
AUTHORIZED_CUMULATIVE_LIMIT = 50

_BACKEND = Path(__file__).resolve().parents[3]
DEFAULT_STATE_PATH = _BACKEND / 'var' / 'llm_campaign' / 'budget_state.json'


class BudgetExhausted(RuntimeError):
    """Raised before any socket is opened."""


def state_path(path: Path | str | None = None) -> Path:
    return Path(path) if path is not None else DEFAULT_STATE_PATH


def read_state(path: Path | str | None = None) -> dict:
    """Read the ledger, defaulting to the authorized limit and zero spend.

    A missing file is a fresh ledger, not an error: the first reservation creates
    it. A file whose ``limit`` disagrees with ``AUTHORIZED_CUMULATIVE_LIMIT`` is
    reported by ``status()`` rather than silently trusted, because a stale state
    file is exactly how a budget change goes unnoticed.
    """
    target = state_path(path)
    if not target.exists():
        return {'limit': AUTHORIZED_CUMULATIVE_LIMIT, 'spent': 0, 'attempts': []}
    return json.loads(target.read_text(encoding='utf-8'))


def _write_atomic(target: Path, payload: dict) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(target.suffix + '.tmp')
    with open(tmp, 'w', encoding='utf-8') as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, target)


def remaining(path: Path | str | None = None) -> int:
    state = read_state(path)
    return max(0, AUTHORIZED_CUMULATIVE_LIMIT - int(state.get('spent', 0)))


def reserve(path: Path | str | None = None, scenario: str = '', *,
            limit: int | None = None) -> int:
    """Consume one slot and persist it. Raises before any transport is built.

    ``limit`` exists only so a test can exercise the boundary without consuming
    fifty slots. It can lower the ceiling, never raise it past the authorized
    value — a caller cannot grant itself more attempts than the Owner did.
    """
    ceiling = AUTHORIZED_CUMULATIVE_LIMIT if limit is None else min(
        int(limit), AUTHORIZED_CUMULATIVE_LIMIT)
    state = read_state(path)
    spent = int(state.get('spent', 0))
    if spent >= ceiling:
        raise BudgetExhausted(
            f'budget exhausted: {spent}/{ceiling} calls already spent; '
            'refusing to open a socket')
    spent += 1
    state['spent'] = spent
    # The authorized limit is written on every reservation so the file can never
    # claim a ceiling the code does not hold.
    state['limit'] = ceiling
    state.setdefault('attempts', []).append({
        'n': spent, 'scenario': scenario,
        'at': datetime.now(timezone.utc).isoformat()})
    _write_atomic(state_path(path), state)
    return spent


def status(path: Path | str | None = None) -> dict:
    """Report the budget and any disagreement between the file and the code."""
    state = read_state(path)
    spent = int(state.get('spent', 0))
    return {
        'authorized_limit': AUTHORIZED_CUMULATIVE_LIMIT,
        'state_limit': state.get('limit'),
        'limit_matches_authorized': state.get('limit') == AUTHORIZED_CUMULATIVE_LIMIT,
        'spent': spent,
        'remaining': max(0, AUTHORIZED_CUMULATIVE_LIMIT - spent),
        'attempts_preserved': len(state.get('attempts') or []),
        'cost_ceiling_usd': 0.00,
    }


__all__ = ['AUTHORIZED_CUMULATIVE_LIMIT', 'BudgetExhausted', 'DEFAULT_STATE_PATH',
           'read_state', 'remaining', 'reserve', 'state_path', 'status']
