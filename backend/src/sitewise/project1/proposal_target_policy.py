"""Single source of truth for where proposal / decision rows may be written.

DD-006 was not a single hardcoded string: the *route* guard pinned one
``(database, port)`` pair while the *adapter* had a name allowlist that could be
widened with ``PROJECT1_PROPOSAL_DB_ALLOWLIST``. The two disagreed on PG18 —
the adapter was parameterised for it, the route still refused it — so a request
could pass one gate and fail the other depending on which layer ran first.

Both layers now import this module and neither can be widened from the
environment. Adding a target is a code change with a review, which is the point:
the allowlist is the sole authority on where attempt receipts and proposal rows
land, and ``Dss`` / ``Final_Location_Analysis`` must never become reachable by
editing a config file.
"""
from __future__ import annotations

#: ``(database, port)`` -> principals that may hold the connection there.
APPROVED_TARGETS: dict[tuple[str, int], frozenset[str]] = {
    ('project1_workflow_tests', 5433): frozenset({'p1_m2_runtime'}),
    ('project1_pg18_migrated_tests', 5544): frozenset({'p1_m2_runtime'}),
}

#: Only a loopback server is a disposable target; a remote host is never one.
TARGET_HOSTS = frozenset({'127.0.0.1', 'localhost'})

#: Never allowlisted, and checked *before* the allowlist so a later edit which
#: adds one of these names fails loudly instead of silently authorising it.
PROTECTED_DATABASES = frozenset({
    'Dss', 'Final_Location_Analysis', 'postgres', 'sitesense', 'dss',
})

#: The restricted principal that owns the proposal/decision grants.
PROPOSAL_PRINCIPAL = 'p1_m2_runtime'


def approved_principals(database, port) -> frozenset[str] | None:
    """Principals permitted at ``(database, port)``; ``None`` means refused.

    A protected name is refused before the allowlist is consulted, so the
    allowlist can never become a route to one of those databases.
    """
    if database in PROTECTED_DATABASES:
        return None
    return APPROVED_TARGETS.get((database, port))


def is_approved(database, port) -> bool:
    return approved_principals(database, port) is not None


def refusal(database, port) -> str | None:
    """Human-readable reason for a refusal, or ``None`` when approved.

    Kept as data rather than a raised exception so the route can map it to HTTP
    and the adapter can map it to ``WorkflowHeld`` without either owning the
    policy.
    """
    if database in PROTECTED_DATABASES:
        return 'PROTECTED_DATABASE'
    if (database, port) not in APPROVED_TARGETS:
        return 'TARGET_NOT_ALLOWLISTED'
    return None
