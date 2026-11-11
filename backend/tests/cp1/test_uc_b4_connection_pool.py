"""B4-03: same physical restricted-login connection, two entrepreneurs.

These are DB trust-boundary tests, NOT proof that FastAPI verified the actor.
All positive confirmations are rolled back by the outer connection transaction.
"""
from uuid import uuid4

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from _uc_b4_support import (
    GATEWAY_SQL, gateway_call, restricted_engine,
    reversible_gateway_connection, version_fixture,
)


def test_01_pool_reuses_one_physical_connection_without_changing_db_login():
    with restricted_engine("human", pooled=True) as engine:
        with engine.connect() as first:
            pid_a = first.execute(text("SELECT pg_backend_pid()" )).scalar_one()
            assert first.execute(text("SELECT session_user")).scalar_one() == "p1uc_stage_human"
        with engine.connect() as second:
            pid_b = second.execute(text("SELECT pg_backend_pid()" )).scalar_one()
            assert second.execute(text("SELECT session_user")).scalar_one() == "p1uc_stage_human"
        assert pid_a == pid_b, "Pool did not reuse a physical connection"


def test_02_two_distinct_owners_on_the_same_pooled_connection():
    a_actor, a_version = version_fixture("A")
    b_actor, b_version = version_fixture("B")
    assert a_actor != b_actor, "Need two distinct real test entrepreneurs"
    assert a_version != b_version
    with restricted_engine("human", pooled=True) as engine:
        with engine.connect() as before:
            physical_pid = before.execute(text("SELECT pg_backend_pid()" )).scalar_one()
        # A makes a valid request. The outer transaction rolls back the write.
        with reversible_gateway_connection(engine) as conn:
            assert conn.execute(text("SELECT pg_backend_pid()" )).scalar_one() == physical_pid
            event, result = gateway_call(conn, actor_id=a_actor, version_id=a_version)
            assert result == event
        # B follows on the exact same pool connection. No previous actor may leak.
        with reversible_gateway_connection(engine) as conn:
            assert conn.execute(text("SELECT pg_backend_pid()" )).scalar_one() == physical_pid
            event, result = gateway_call(conn, actor_id=b_actor, version_id=b_version)
            assert result == event
        # A attempting B's valid candidate must still be denied.
        with reversible_gateway_connection(engine) as conn:
            with pytest.raises(DBAPIError) as exc:
                conn.execute(GATEWAY_SQL, {
                    "actor_id": a_actor, "event_id": uuid4(),
                    "version_id": b_version, "action": "CONFIRMED",
                    "receipt": "CP1-B4-cross-user-pooled",
                })
            assert exc.value.orig.pgcode == "42501"


def test_03_error_does_not_poison_next_pool_checkout():
    a_actor, a_version = version_fixture("A")
    with restricted_engine("human", pooled=True) as engine:
        with reversible_gateway_connection(engine) as conn:
            with pytest.raises(DBAPIError):
                conn.execute(GATEWAY_SQL, {
                    "actor_id": uuid4(), "event_id": uuid4(),
                    "version_id": a_version, "action": "CONFIRMED",
                    "receipt": "CP1-B4-error-before-reuse",
                })
        with reversible_gateway_connection(engine) as next_conn:
            event, result = gateway_call(next_conn, actor_id=a_actor, version_id=a_version)
            assert result == event
