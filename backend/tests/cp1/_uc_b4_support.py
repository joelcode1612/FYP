"""CP1-B4 test-only configuration and safety gates.

No database migrations, grants, role impersonation or public API changes.
Do not import this module from production code.
"""

from __future__ import annotations
from sitewise.repositories.uc_decision_gateway import UcDecisionGateway

import os
from contextlib import contextmanager
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.pool import NullPool, QueuePool
from sqlmodel import Session

STAGE_DB = "dss_uc_stage_tests"
STAGE_PORT = 5433
LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1"}
ROLE_NAMES = {
    "human": "p1uc_stage_human",
    "llm": "p1uc_stage_llm",
    "qj": "p1uc_stage_qj",
    "admin": "postgres",
}
URL_ENV = {
    role: f"UC_B4_DATABASE_URL_{role.upper()}" for role in ROLE_NAMES
}
GATEWAY_SIGNATURE = (
    "project1_uc.record_authenticated_entrepreneur_decision"
    "(uuid,uuid,uuid,text,text)"
)
GATEWAY_SQL = text(
    "SELECT project1_uc.record_authenticated_entrepreneur_decision("
    ":actor_id, :event_id, :version_id, :action, :receipt)"
)


def blocked(reason: str):
    pytest.skip(f"BLOCKED — {reason}")


def stage_url(role: str):
    """Return URL only for a deliberately isolated local stage DB.

    Explicit environment variables are required. Never synthesize passwords.
    """
    env_name = URL_ENV[role]
    raw = os.environ.get(env_name)
    if not raw:
        blocked(f"provide {env_name} for port-{STAGE_PORT} test instance")
    try:
        url = make_url(raw)
    except Exception as exc:
        pytest.fail(f"{env_name}: invalid SQLAlchemy URL ({type(exc).__name__})")
    if (
        url.database != STAGE_DB
        or url.host not in LOCAL_HOSTS
        or url.port != STAGE_PORT
        or url.username != ROLE_NAMES[role]
        or not url.drivername.startswith("postgresql")
    ):
        pytest.fail(
            f"SAFETY STOP: {env_name} must use local port {STAGE_PORT}, "
            f"database {STAGE_DB} and login {ROLE_NAMES[role]}"
        )
    return url


@contextmanager
def restricted_engine(role: str, *, pooled: bool = False):
    """Connect using a real password-authenticated login, not SET ROLE."""
    url = stage_url(role)
    kw = {"pool_pre_ping": True, "connect_args": {"connect_timeout": 4}}
    if pooled:
        kw.update(poolclass=QueuePool, pool_size=1, max_overflow=0)
    else:
        kw["poolclass"] = NullPool
    engine = create_engine(url, **kw)
    try:
        with engine.connect() as conn:
            db, port, login, effective = conn.execute(text(
                "SELECT current_database(), inet_server_port(), "
                "session_user, current_user"
            )).one()
            assert (db, port, login, effective) == (
                STAGE_DB, STAGE_PORT, ROLE_NAMES[role], ROLE_NAMES[role]
            ), "Unexpected PostgreSQL identity or database"
            flags = conn.execute(text(
                "SELECT rolsuper, rolbypassrls, rolcreatedb, rolcreaterole "
                "FROM pg_roles WHERE rolname = session_user"
            )).one()
            if role != "admin":
                assert flags == (False, False, False, False), (
                    f"{role} has unsafe database privileges"
                )
            assert conn.execute(text(
                "SELECT to_regprocedure(:signature) IS NOT NULL"
            ), {"signature": GATEWAY_SIGNATURE}).scalar_one() is True
        yield engine
    finally:
        engine.dispose()


def version_fixture(who: str) -> tuple[UUID, UUID]:
    """Requires a current committed candidate from the *isolated* clone.

    The fixture is intentionally not auto-inserted: UC history is append-only.
    """
    assert who in {"A", "B"}
    actor_env = f"UC_B4_ACTOR_{who}_USER_ID"
    version_env = f"UC_B4_CANDIDATE_{who}_VERSION_ID"
    if not os.environ.get(actor_env) or not os.environ.get(version_env):
        blocked(f"provide {actor_env} and {version_env} from stage-only fixtures")
    try:
        return UUID(os.environ[actor_env]), UUID(os.environ[version_env])
    except ValueError:
        pytest.fail(f"Invalid UUID in {actor_env} or {version_env}")


@contextmanager
def reversible_gateway_connection(engine):
    """Session commits may release savepoints; the outer tx always rolls back.

    A restricted login stays active on the same physical connection.
    This relies on SQLAlchemy 2.x join_transaction_mode='create_savepoint'.
    """
    with engine.connect() as conn:
        outer = conn.begin()
        try:
            yield conn
        finally:
            if outer.is_active:
                outer.rollback()


def gateway_call(conn, *, actor_id, version_id, event_id=None,
                 action="CONFIRMED", receipt=None):
    from sitewise.repositories.uc_decision_gateway import UcDecisionGateway

    event_id = event_id or uuid4()
    receipt = receipt if receipt is not None else f"CP1-B4-{uuid4()}"
    with Session(bind=conn, join_transaction_mode="create_savepoint") as session:
        result = UcDecisionGateway(session).record_decision(
            verified_actor_user_id=actor_id,
            event_id=event_id,
            candidate_version_id=version_id,
            action=action,
            receipt=receipt,
        )
    return event_id, result


def assert_admin_clean(event_id: UUID) -> None:
    """Outside the rolled-back real-login connection, verify no committed row."""
    with restricted_engine("admin") as admin:
        with admin.connect() as conn:
            result = conn.execute(text(
                "SELECT "
                "(SELECT count(*) FROM public.m2_confirmed_uncertainties WHERE id=:id) "
                "AS m2_count, "
                "(SELECT count(*) FROM project1_uc.candidate_events WHERE id=:id) "
                "AS uc_count"
            ), {"id": event_id}).one()
            assert result == (0, 0), "Rollback left persistent M2/UC rows"


def require_api_stage():
    """Never run in-process app/API writes against a default/live .env DB."""
    if os.environ.get("UC_B4_ENABLE_API_TESTS") != "YES_ISOLATED_STAGE_ONLY":
        blocked("set UC_B4_ENABLE_API_TESTS=YES_ISOLATED_STAGE_ONLY after API is wired")
    from sitewise.db.session import engine as app_engine
    u = app_engine.url
    if u.database != STAGE_DB or u.host not in LOCAL_HOSTS or u.port != STAGE_PORT:
        pytest.fail("SAFETY STOP: FastAPI primary engine must use local isolated B4 DB")
    # Ensures the separate restricted UC login also exists for API testing.
    stage_url("human")


def token_from_file(who: str) -> str:
    key = f"UC_B4_TOKEN_{who}_FILE"
    path_str = os.environ.get(key)
    if not path_str:
        blocked(f"provide {key} pointing to a protected local test-token file")
    p = Path(path_str).expanduser().resolve()
    if not p.is_file():
        pytest.fail(f"{key}: file missing")
    if Path.cwd().resolve() in p.parents:
        pytest.fail(f"{key}: token file must be outside repository")
    token = p.read_text(encoding="utf-8").strip()
    if not token:
        pytest.fail(f"{key}: empty test-token file")
    return token
