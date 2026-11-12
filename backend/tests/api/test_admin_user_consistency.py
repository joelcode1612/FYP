"""Administrator user-management consistency (spec 5 + 6A).

Covers the two-database write (authoritative Supabase identity row + local
enforcement mirror), the truthful audit result, and the authoritative
per-owner listing count. Supabase is faked; the local Postgres is real and
every created row is removed by ``cleanup_users``. No operational property
row is written.
"""

import uuid

import pytest
from sqlalchemy import event, text
from sqlmodel import Session

import sitewise.api.v1.users as users_module
from sitewise.core.exceptions import AuthUnavailableError
from sitewise.core.supabase_admin import SupabaseAdminError
from sitewise.db.session import engine
from sitewise.repositories.user_repository import UserRepository
from sitewise.services.user_service import UserService
from tests.conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id
from tests.fakes import FakeSupabaseAdmin


@pytest.fixture()
def fake_admin(monkeypatch):
    fake = FakeSupabaseAdmin()
    monkeypatch.setattr(users_module, "get_admin_service", lambda: fake)
    return fake


def auth(token):
    return {"Authorization": f"Bearer {token}"}


def _provision(cleanup_users, *, role="entrepreneur", aal="aal2"):
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    token = make_token(
        sub=str(sub),
        email=f"u-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}",
        aal=aal,
        amr=[{"method": "password"}, {"method": "totp"}],
    )
    with Session(engine) as session:
        repo = UserRepository(session)
        repo.get_or_create_from_supabase(
            user_id=sub, email=f"u-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}", email_verified=True
        )
        if role != "entrepreneur":
            repo.update(sub, {"role": role})
    return sub, token


def _local_role(user_id):
    with Session(engine) as session:
        return UserRepository(session).get_by_id(user_id).role


# --------------------------------------------------------------- 6A: counts


def test_directory_counts_listings_in_one_grouped_query(client, cleanup_users, fake_admin):
    """The count comes from the operational owner key, and the whole page is
    served by ONE grouped query - never one query per account."""
    _, token = _provision(cleanup_users, role="admin")
    statements: list[str] = []

    def _record(conn, cursor, statement, parameters, context, executemany):
        if "fyp.rental_properties" in statement:
            statements.append(statement)

    event.listen(engine, "before_cursor_execute", _record)
    try:
        r = client.get("/api/v1/users/?limit=200", headers=auth(token))
    finally:
        event.remove(engine, "before_cursor_execute", _record)

    assert r.status_code == 200, r.text
    rows = r.json()
    assert len(rows) > 1, "need several accounts to prove the absence of N+1"
    assert all("listing_count" in row for row in rows)
    assert len(statements) == 1, statements
    assert "GROUP BY owner_user_id" in statements[0]

    with Session(engine) as session:
        expected = UserRepository(session).listing_counts_by_owner()
    for row in rows:
        assert row["listing_count"] == expected.get(uuid.UUID(row["user_id"]), 0)


def test_detail_count_matches_the_owner_aggregate(client, cleanup_users, fake_admin):
    sub, token = _provision(cleanup_users, role="admin")
    r = client.get(f"/api/v1/users/{sub}", headers=auth(token))
    assert r.status_code == 200, r.text
    with Session(engine) as session:
        repo = UserRepository(session)
        assert r.json()["listing_count"] == repo.listing_count_for(sub)
        direct = session.execute(
            text(
                "SELECT count(*) FROM fyp.rental_properties WHERE owner_user_id = :o"
            ),
            {"o": str(sub)},
        ).scalar_one()
    assert r.json()["listing_count"] == int(direct)


# --------------------------------------------------- 5: cross-database write


def test_identity_rejection_fails_closed_without_local_change(client, cleanup_users, fake_admin):
    _, admin_token = _provision(cleanup_users, role="admin")
    target, _ = _provision(cleanup_users)

    def _reject(user_id, data):
        raise SupabaseAdminError("Identity profile update failed: upstream 500")

    fake_admin.update_identity_profile = _reject
    r = client.patch(
        f"/api/v1/users/{target}", headers=auth(admin_token), json={"role": "agent"}
    )
    assert r.status_code == 502, r.text
    assert "no change was applied" in r.json()["detail"]
    assert _local_role(target) == "entrepreneur"
    assert fake_admin.audit == []


def test_unconfigured_adapter_is_unavailable_not_a_local_only_write(
    client, cleanup_users, monkeypatch
):
    _, admin_token = _provision(cleanup_users, role="admin")
    target, _ = _provision(cleanup_users)

    def _unavailable():
        raise AuthUnavailableError("Supabase project URL or secret key is not configured.")

    monkeypatch.setattr(users_module, "get_admin_service", _unavailable)
    r = client.patch(
        f"/api/v1/users/{target}", headers=auth(admin_token), json={"role": "agent"}
    )
    assert r.status_code == 503, r.text
    assert _local_role(target) == "entrepreneur"


def test_mirror_failure_reports_an_explicit_partial_result(client, cleanup_users, fake_admin):
    """The authoritative row already changed, so the response must say exactly
    that instead of claiming success or pretending nothing happened."""
    _, admin_token = _provision(cleanup_users, role="admin")
    target, _ = _provision(cleanup_users)

    class _MirrorFails(UserService):
        def update_user(self, user_id, data):
            raise RuntimeError("local mirror write rejected")

    original = users_module.UserService
    users_module.UserService = _MirrorFails
    try:
        r = client.patch(
            f"/api/v1/users/{target}", headers=auth(admin_token), json={"role": "agent"}
        )
    finally:
        users_module.UserService = original

    assert r.status_code == 502, r.text
    detail = r.json()["detail"]
    assert "Partially applied" in detail
    assert "identity record was updated" in detail
    assert "local access-control record was not" in detail
    assert fake_admin.identity[str(target)]["role"] == "agent"
    assert _local_role(target) == "entrepreneur"
    assert any(a["details"]["consistency"] == "partial" for a in fake_admin.audit)

    # Recovery is retrying the same idempotent change - no repair by overwrite.
    retry = client.patch(
        f"/api/v1/users/{target}", headers=auth(admin_token), json={"role": "agent"}
    )
    assert retry.status_code == 200, retry.text
    assert _local_role(target) == "agent"


def test_audit_failure_is_reported_and_never_claimed(client, cleanup_users, fake_admin):
    _, admin_token = _provision(cleanup_users, role="admin")
    target, _ = _provision(cleanup_users)

    def _audit_down(**kwargs):
        raise SupabaseAdminError("role_change_audit insert failed")

    fake_admin.insert_role_audit = _audit_down
    r = client.patch(
        f"/api/v1/users/{target}", headers=auth(admin_token), json={"role": "agent"}
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["role"] == "agent"
    assert body["identity_synced"] is True
    assert body["audit_recorded"] is False
    assert _local_role(target) == "agent"


def test_successful_change_reports_the_recorded_audit_event(client, cleanup_users, fake_admin):
    _, admin_token = _provision(cleanup_users, role="admin")
    target, _ = _provision(cleanup_users)
    r = client.patch(
        f"/api/v1/users/{target}",
        headers=auth(admin_token),
        json={"account_status": "suspended"},
    )
    assert r.status_code == 200, r.text
    assert r.json()["audit_recorded"] is True
    assert r.json()["account_status"] == "suspended"
    assert fake_admin.identity[str(target)]["account_status"] == "suspended"
    assert any(
        a["action"] == "status.changed"
        and a["previous_status"] == "active"
        and a["new_status"] == "suspended"
        for a in fake_admin.audit
    )


def test_profile_only_edit_expects_no_audit_event(client, cleanup_users, fake_admin):
    _, admin_token = _provision(cleanup_users, role="admin")
    target, _ = _provision(cleanup_users)
    r = client.patch(
        f"/api/v1/users/{target}", headers=auth(admin_token), json={"full_name": "Renamed"}
    )
    assert r.status_code == 200, r.text
    assert r.json()["full_name"] == "Renamed"
    assert r.json()["audit_recorded"] is None
    assert fake_admin.audit == []


def test_unknown_role_and_status_are_rejected_before_any_write(client, cleanup_users, fake_admin):
    _, admin_token = _provision(cleanup_users, role="admin")
    target, _ = _provision(cleanup_users)
    for body in ({"role": "owner"}, {"account_status": "banned"}):
        r = client.patch(f"/api/v1/users/{target}", headers=auth(admin_token), json=body)
        assert r.status_code == 422, r.text
    assert fake_admin.identity == {}
    assert fake_admin.audit == []