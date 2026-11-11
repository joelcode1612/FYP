"""B4-01: real PostgreSQL login authorization on port 5433 (read-only tests).

Missing credential URLs produce BLOCKED/skips, not false PASS results.
No SET ROLE / SET SESSION AUTHORIZATION impersonation is used.
"""
from uuid import uuid4

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from _uc_b4_support import (
    GATEWAY_SIGNATURE, GATEWAY_SQL, ROLE_NAMES,
    restricted_engine, reversible_gateway_connection, version_fixture,
)


@pytest.mark.parametrize("role", ["human", "llm", "qj"])
def test_01_actual_login_identity_and_permissions(role):
    with restricted_engine(role) as engine:
        with engine.connect() as conn:
            allowed = conn.execute(text(
                "SELECT has_function_privilege(session_user, :sig, 'EXECUTE')"
            ), {"sig": GATEWAY_SIGNATURE}).scalar_one()
            assert allowed is (role == "human")
            no_table_write = conn.execute(text(
                "SELECT has_table_privilege(session_user, "
                "'project1_uc.candidate_events', 'INSERT')"
            )).scalar_one()
            assert no_table_write is False


@pytest.mark.parametrize("role", ["human", "llm", "qj"])
def test_02_no_direct_uc_event_read(role):
    with restricted_engine(role) as engine:
        with reversible_gateway_connection(engine) as conn:
            with pytest.raises(DBAPIError) as exc:
                conn.execute(text("SELECT count(*) FROM project1_uc.candidate_events"))
            assert exc.value.orig.pgcode == "42501"


@pytest.mark.parametrize("role", ["llm", "qj"])
def test_03_service_logins_cannot_execute_human_decision(role):
    with restricted_engine(role) as engine:
        with reversible_gateway_connection(engine) as conn:
            with pytest.raises(DBAPIError) as exc:
                conn.execute(GATEWAY_SQL, {
                    "actor_id": uuid4(), "event_id": uuid4(),
                    "version_id": uuid4(), "action": "CONFIRMED",
                    "receipt": "CP1-B4-service-denial",
                })
            assert exc.value.orig.pgcode == "42501"


def test_04_real_human_login_can_reach_gateway():
    """Invalid version proves function execution, not a positive confirmation."""
    with restricted_engine("human") as engine:
        with reversible_gateway_connection(engine) as conn:
            with pytest.raises(DBAPIError) as exc:
                conn.execute(GATEWAY_SQL, {
                    "actor_id": uuid4(), "event_id": uuid4(),
                    "version_id": uuid4(), "action": "CONFIRMED",
                    "receipt": "CP1-B4-invalid-version",
                })
            assert "UC version absent" in str(exc.value.orig)


def test_05_real_login_wrong_entrepreneur_cannot_confirm():
    owner_id, version_id = version_fixture("A")
    with restricted_engine("human") as engine:
        with reversible_gateway_connection(engine) as conn:
            with pytest.raises(DBAPIError) as exc:
                conn.execute(GATEWAY_SQL, {
                    "actor_id": uuid4(), "event_id": uuid4(),
                    "version_id": version_id, "action": "CONFIRMED",
                    "receipt": "CP1-B4-cross-owner",
                })
            assert exc.value.orig.pgcode == "42501"
