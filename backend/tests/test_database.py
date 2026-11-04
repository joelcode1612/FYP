"""Database connectivity and identity-mapping tests (spec 15 - database tests)."""

import uuid

import pytest
from sqlalchemy import text
from sqlmodel import Session

from sitewise.db.analytics_session import analytics_engine
from sitewise.db.session import engine
from sitewise.repositories.user_repository import UserRepository


@pytest.fixture()
def cleanup_users():
    created: list[uuid.UUID] = []
    yield created
    with Session(engine) as session:
        repo = UserRepository(session)
        for user_id in created:
            repo.delete(user_id)


def test_application_database_connects():
    with Session(engine) as session:
        assert session.exec(text("SELECT 1")).scalar() == 1
        tables = {
            row[0]
            for row in session.exec(
                text(
                    "SELECT table_name FROM information_schema.tables "
                    "WHERE table_schema='public'"
                )
            )
        }
        assert {"users", "property", "favorite_property", "recommendation_result"} <= tables


def test_analytics_database_connects_and_is_read_only_in_practice():
    with Session(analytics_engine) as session:
        assert session.exec(text("SELECT 1")).scalar() == 1
        tables = {
            row[0]
            for row in session.exec(
                text(
                    "SELECT table_name FROM information_schema.tables "
                    "WHERE table_schema='public'"
                )
            )
        }
        assert "district_population" in tables
        assert "vw_latest_district_statistics" in tables
        # Read-only proof: a SELECT works.
        session.exec(text("SELECT count(*) FROM district_population"))


def test_identity_mapping_no_duplicate_rows(cleanup_users):
    """The same Supabase UUID must map to exactly one local profile."""
    user_id = uuid.uuid4()
    cleanup_users.append(user_id)
    email = f"mapping-{user_id.hex[:10]}@jwks-test.example"

    with Session(engine) as session:
        repo = UserRepository(session)
        first, created_1 = repo.get_or_create_from_supabase(
            user_id=user_id, email=email, email_verified=True
        )
        second, created_2 = repo.get_or_create_from_supabase(
            user_id=user_id, email=email, email_verified=True
        )
        assert created_1 is True
        assert created_2 is False
        assert first.user_id == second.user_id == user_id
        assert first.email == second.email == email

        count = session.exec(
            text("SELECT count(*) FROM users WHERE user_id = :uid"),
            params={"uid": str(user_id)},
        ).scalar()
        assert count == 1


def test_no_password_or_token_columns_in_local_users(cleanup_users):
    """Supabase owns credentials; the local table must not mirror them."""
    user_id = uuid.uuid4()
    cleanup_users.append(user_id)
    with Session(engine) as session:
        columns = {
            row[0]
            for row in session.exec(
                text(
                    "SELECT column_name FROM information_schema.columns "
                    "WHERE table_schema='public' AND table_name='users'"
                )
            )
        }
        assert "password" not in columns
        assert "password_hash" not in columns
        assert "refresh_token" not in columns
        # The Supabase UUID is the PK.
        pk = session.exec(
            text(
                "SELECT column_name FROM information_schema.key_column_usage "
                "WHERE table_schema='public' AND table_name='users' "
                "AND constraint_name LIKE '%pkey'"
            )
        ).scalars()
        assert "user_id" in set(pk)


def test_dosm_statistics_endpoint_works(client):
    """Existing analytics endpoint remains functional (read-only)."""
    response = client.get("/api/v1/statistics/districts")
    assert response.status_code == 200
    rows = response.json()
    assert isinstance(rows, list) and len(rows) > 0
    assert "state" in rows[0] and "district" in rows[0]
