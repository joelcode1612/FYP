"""Real PostgreSQL RLS regression; only the CP-11 private cluster is permitted."""
import os
from uuid import UUID

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

from sitewise.db import m2_session

RAW = os.environ.get('CP11_M2_RUNTIME_URL')
if not RAW:
    pytest.skip('CP11_M2_RUNTIME_URL required; no live database writes', allow_module_level=True)
URL = make_url(RAW)
if URL.database != 'project1_workflow_tests' or URL.host != '127.0.0.1' or URL.port == 5432:
    raise RuntimeError('Only the explicitly configured private PostgreSQL cluster is allowed')

OWNER = UUID('11111111-1111-4111-8111-111111111111')
OTHER = UUID('22222222-2222-4222-8222-222222222222')


@pytest.fixture
def engine(monkeypatch):
    value = create_engine(URL, hide_parameters=True)
    monkeypatch.setattr(m2_session, 'get_m2_engine', lambda: value)
    yield value
    value.dispose()


def visible(session):
    return session.execute(text('SELECT owner_id FROM cp11_owner_probe ORDER BY owner_id')).scalars().all()


def test_owner_visibility_survives_projection_rollback_and_a_later_commit(engine):
    with m2_session.m2_session_for(OWNER) as session:
        assert visible(session) == [OWNER]
        session.rollback()  # M2SourceProjection.read() ends its read this way.
        assert visible(session) == [OWNER]
        session.commit()
        assert visible(session) == [OWNER]
        session.rollback()
        assert visible(session) == [OWNER]


def test_different_owner_cannot_inherit_or_read_the_previous_actor(engine):
    for actor in (OWNER, OTHER, OWNER):
        with m2_session.m2_session_for(actor) as session:
            assert visible(session) == [actor]
            session.rollback()
            assert visible(session) == [actor]
    with engine.connect() as connection:
        assert connection.execute(text('SELECT count(*) FROM cp11_owner_probe')).scalar_one() == 0


def test_database_error_recovery_does_not_drop_owner_scope(engine):
    from sqlalchemy.exc import DBAPIError
    with m2_session.m2_session_for(OWNER) as session:
        assert visible(session) == [OWNER]
        with pytest.raises(DBAPIError):
            session.execute(text('SELECT 1 / 0'))
        session.rollback()
        assert visible(session) == [OWNER]
