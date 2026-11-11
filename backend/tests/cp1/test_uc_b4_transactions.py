"""B4-03: real-login transaction/idempotency/source-integrity scenarios.

Requires already-committed test candidate versions in the disposable clone;
never seeds, changes, or deletes existing canonical M2 rows.
"""
from uuid import uuid4

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from _uc_b4_support import (
    GATEWAY_SQL, assert_admin_clean, blocked, gateway_call,
    restricted_engine, reversible_gateway_connection, version_fixture,
)


def test_01_confirmation_retry_is_idempotent_and_rolled_back():
    actor, version = version_fixture("A")
    event = uuid4()
    receipt = f"CP1-B4-retry-{uuid4()}"
    with restricted_engine("human") as engine:
        with reversible_gateway_connection(engine) as conn:
            _, first = gateway_call(conn, actor_id=actor, version_id=version,
                                    event_id=event, receipt=receipt)
            _, second = gateway_call(conn, actor_id=actor, version_id=version,
                                     event_id=event, receipt=receipt)
            assert first == event and second == event
    assert_admin_clean(event)


def test_02_reusing_event_id_with_changed_receipt_is_denied():
    actor, version = version_fixture("A")
    event = uuid4()
    with restricted_engine("human") as engine:
        with reversible_gateway_connection(engine) as conn:
            _, first = gateway_call(conn, actor_id=actor, version_id=version,
                                    event_id=event, receipt="CP1-B4-original")
            assert first == event
            with pytest.raises(DBAPIError) as exc:
                # Rollback must be scoped to the failing savepoint, not the
                # successful earlier decision in the outer test transaction.
                with conn.begin_nested():
                    conn.execute(GATEWAY_SQL, {
                        "actor_id": actor, "event_id": event,
                        "version_id": version, "action": "CONFIRMED",
                        "receipt": "CP1-B4-different",
                    })
            assert "idempotency" in str(exc.value.orig).lower()
    assert_admin_clean(event)


def test_03_failed_uc_event_insert_rolls_back_canonical_m2_insert():
    actor, version = version_fixture("A")
    event = uuid4()
    with restricted_engine("human") as engine:
        with reversible_gateway_connection(engine) as conn:
            with pytest.raises(DBAPIError) as exc:
                with conn.begin_nested():
                    conn.execute(GATEWAY_SQL, {
                        "actor_id": actor, "event_id": event,
                        "version_id": version, "action": "CONFIRMED",
                        "receipt": " ",  # violates the UC event CHECK
                    })
            assert exc.value.orig.pgcode == "23514"
            # A subsequent valid same event ID must work: failed canonical
            # insert did not survive the statement/savepoint rollback.
            _, result = gateway_call(conn, actor_id=actor, version_id=version,
                                     event_id=event, receipt="CP1-B4-recovered")
            assert result == event
    assert_admin_clean(event)


def test_04_prepared_stale_candidate_is_rejected():
    """Requires a separately provisioned stale candidate; never mutate M2."""
    import os
    raw = os.environ.get("UC_B4_STALE_VERSION_ID")
    actor, _ = version_fixture("A")
    if not raw:
        blocked("provide UC_B4_STALE_VERSION_ID as a stale fixture in isolated DB")
    from uuid import UUID
    try:
        stale = UUID(raw)
    except ValueError:
        pytest.fail("UC_B4_STALE_VERSION_ID must be a UUID")
    with restricted_engine("human") as engine:
        with reversible_gateway_connection(engine) as conn:
            with pytest.raises(DBAPIError) as exc:
                conn.execute(GATEWAY_SQL, {
                    "actor_id": actor, "event_id": uuid4(),
                    "version_id": stale, "action": "CONFIRMED",
                    "receipt": "CP1-B4-stale-refusal",
                })
            msg = str(exc.value.orig).lower()
            assert any(word in msg for word in (
                "stale", "mismatch", "superseded", "current"
            )), f"Not an evidence-stale rejection: {msg}"
