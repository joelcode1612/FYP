"""Single audited gate for whether an M2 instrument version may be used.

Stored ``approval_state`` is governance data. It is never rewritten to make a
test pass, and no caller may compare it directly any more.

Two ways an instrument is usable:

``AUTHORIZED``
    The normal production path. Unchanged.

``PROPOSED_NOT_AUTHORIZED`` under an explicit synthetic test scope
    Permitted only when *all* of the following hold, and it fails closed
    otherwise:

    1. ``settings.m2_synthetic_instrument_scope`` is a non-empty scope name.
    2. ``configured_target()`` resolves to a disposable, explicitly configured
       target: a ``project1_*`` database on a non-default port that is not
       5432. Against ``Dss`` on 5432 this raises and the scope can never
       activate, so the mechanism is structurally unavailable in production
       rather than merely switched off by a flag.
    3. The instrument's state is one of the declared synthetic states.

The candidate instrument therefore stays ``PROPOSED_NOT_AUTHORIZED`` in the
database while remaining verifiable end to end on an isolated cluster.
"""
from __future__ import annotations

from sitewise.core.config import settings
from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.database_identity import configured_target

AUTHORIZED = "AUTHORIZED"

#: States that are usable only inside an explicit synthetic test scope.
SYNTHETIC_STATES = frozenset({"PROPOSED_NOT_AUTHORIZED"})


def synthetic_scope_active() -> bool:
    """True only when an explicit disposable-target synthetic scope is active."""
    scope = (getattr(settings, "m2_synthetic_instrument_scope", "") or "").strip()
    if not scope:
        return False
    try:
        name, port = configured_target()
    except WorkflowHeld:
        # The configured target is not a disposable database.
        return False
    if port is None or port == 5432:
        return False
    return bool(name) and name != "Dss"


def instrument_is_usable(instrument: dict | None) -> bool:
    """Whether this instrument version may be read, answered or confirmed."""
    if not instrument:
        return False
    state = instrument.get("approval_state")
    if state == AUTHORIZED:
        return True
    if state in SYNTHETIC_STATES:
        return synthetic_scope_active()
    return False


def authorization_reason(instrument: dict | None) -> str:
    """Stable, non-leaking reason code for diagnostics and evidence."""
    if not instrument:
        return "INSTRUMENT_NOT_FOUND"
    state = instrument.get("approval_state")
    if state == AUTHORIZED:
        return "AUTHORIZED"
    if state in SYNTHETIC_STATES:
        return ("SYNTHETIC_SCOPE_ACTIVE" if synthetic_scope_active()
                else "SYNTHETIC_SCOPE_INACTIVE")
    return "INSTRUMENT_UNAUTHORIZED"
