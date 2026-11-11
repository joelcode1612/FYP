"""Startup metadata must keep legacy integers separate from app UUIDs.

These checks never connect to a database or provision the external schema.
"""

import uuid
from contextlib import nullcontext
from pathlib import Path
import runpy
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from sqlalchemy import BigInteger, MetaData, create_mock_engine
from sqlalchemy.dialects import postgresql
from sqlalchemy.schema import CreateTable
from sqlmodel import SQLModel

from sitewise.db import session as db_session
from sitewise.db.base import Base
from sitewise.db.models import (
    FypRecommendationResult, FypRentalProperty, RecommendationResult, User,
)


def test_all_registered_metadata_and_foreign_keys_resolve():
    assert Base.metadata is SQLModel.metadata
    assert User.__table__.metadata is FypRentalProperty.__table__.metadata
    tables = list(Base.metadata.sorted_tables)
    for table in tables:
        str(CreateTable(table).compile(dialect=postgresql.dialect()))
        for fk in table.foreign_keys:
            assert fk.column.table in tables
    assert "fyp.users" not in Base.metadata.tables
    assert "public.users" not in Base.metadata.tables


def test_legacy_identity_columns_do_not_reference_uuid_profiles():
    for column in (
        FypRentalProperty.__table__.c.owner_id,
        FypRecommendationResult.__table__.c.user_id,
    ):
        assert isinstance(column.type, BigInteger)
        assert not column.foreign_keys
    assert FypRentalProperty.__table__.c.owner_id.nullable
    assert not FypRecommendationResult.__table__.c.user_id.nullable
    assert User.__table__.c.user_id.type.python_type is uuid.UUID
    fk = next(iter(RecommendationResult.__table__.c.user_id.foreign_keys))
    assert fk.column is User.__table__.c.user_id


def test_startup_never_creates_external_mirrors(monkeypatch):
    emitted = []
    mock_engine = create_mock_engine(
        "postgresql://", lambda sql, *args, **kwargs: emitted.append(
            str(sql.compile(dialect=postgresql.dialect()))
        )
    )
    has_table = Mock(return_value=True)
    monkeypatch.setattr(db_session, "engine", mock_engine)
    monkeypatch.setattr(
        db_session, "inspect", lambda engine: SimpleNamespace(has_table=has_table)
    )
    db_session.create_db_and_tables()
    assert emitted
    assert not any("CREATE TABLE fyp." in sql for sql in emitted)
    assert any("CREATE TABLE users" in sql for sql in emitted)
    checked = {call.args[0] for call in has_table.call_args_list}
    assert checked == {
        table.name for table in Base.metadata.tables.values() if table.schema == "fyp"
    }


def test_missing_external_schema_blocks_startup_before_any_ddl(monkeypatch):
    create_all = Mock()
    monkeypatch.setattr(Base.metadata, "create_all", create_all)
    monkeypatch.setattr(
        db_session, "inspect",
        lambda engine: SimpleNamespace(has_table=lambda *args, **kwargs: False),
    )
    with pytest.raises(RuntimeError, match="Verify DATABASE_URL") as error:
        db_session.create_db_and_tables()
    assert "fyp.rental_properties" in str(error.value)
    create_all.assert_not_called()


def test_autogenerate_cannot_remove_external_legacy_constraints(monkeypatch):
    from alembic import context

    configure = Mock()
    monkeypatch.setattr(context, "config", Mock(), raising=False)
    monkeypatch.setattr(context, "is_offline_mode", lambda: True)
    monkeypatch.setattr(context, "configure", configure)
    monkeypatch.setattr(context, "begin_transaction", nullcontext)
    monkeypatch.setattr(context, "run_migrations", Mock())
    runpy.run_path(str(Path(__file__).resolve().parents[1] / "alembic" / "env.py"))
    include = configure.call_args.kwargs["include_object"]
    table = FypRentalProperty.__table__
    reflected = table.to_metadata(MetaData())
    reflected.info.clear()
    assert not include(table, table.name, "table", False, None)
    assert not include(reflected, table.name, "table", True, table)
    assert include(User.__table__, "users", "table", False, None)
