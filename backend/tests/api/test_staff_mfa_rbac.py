"""Regression matrix for the MFA security hardening (F1, F4, F5, F7, F8).

Complements ``test_staff_authorization.py`` / ``test_staff_admin_api.py`` (which
cover the ``/staff/*`` portal) by pinning the *user-administration* and
*recommendation-overview* routes, the read-only ``assurance_level`` echo,
canonical role output, and the removal of the unsafe role-only staff helpers.

Every authorization decision runs through the real FastAPI dependency chain
(ES256 JWT verification via the conftest JWKS fake -> active check -> staff role
-> ``aal2``). No frontend flag, request body or query parameter can substitute
for the signed ``aal`` claim.
"""

import uuid

import pytest

from tests.conftest import TEST_EMAIL_DOMAIN, make_token, register_user_id


def auth(token):
    return {"Authorization": f"Bearer {token}"}


def _mirror(cleanup_users, *, role, status="active", aal=None):
    """Provision an authoritative local row + a token carrying the chosen aal."""
    sub = uuid.uuid4()
    register_user_id(cleanup_users, sub)
    email = f"mfa-{sub.hex[:10]}@{TEST_EMAIL_DOMAIN}"
    from sqlmodel import Session

    from sitewise.db.session import engine
    from sitewise.repositories.user_repository import UserRepository

    with Session(engine) as session:
        repo = UserRepository(session)
        repo.get_or_create_from_supabase(user_id=sub, email=email, email_verified=True)
        repo.update(sub, {"role": role, "account_status": status})
    kwargs = {"sub": str(sub), "email": email}
    if aal:
        kwargs["aal"] = aal
        kwargs["amr"] = [{"method": "password"}, {"method": "totp"}]
    return sub, make_token(**kwargs)


# Administrative data routes: every one must require admin role AND aal2.
# {target} is filled with an arbitrary UUID - the guard fires before any lookup.
ADMIN_ROUTES = [
    ("GET", "/api/v1/users/"),
    ("GET", "/api/v1/users/{target}"),
    ("PATCH", "/api/v1/users/{target}"),
    ("DELETE", "/api/v1/users/{target}"),
    ("GET", "/api/v1/recommendations/"),
]


def _call(client, method, path, token, target):
    url = path.format(target=target)
    body = {"role": "agent"} if method == "PATCH" else None
    return client.request(method, url, headers=auth(token), json=body)


# ----------------------------------------------------------------------- F1


@pytest.mark.parametrize("aal", [None, "aal1"])
@pytest.mark.parametrize("method,path", ADMIN_ROUTES)
def test_admin_routes_require_aal2(client, cleanup_users, method, path, aal):
    """F1: an admin-role session that has NOT completed MFA (no ``aal`` claim or
    ``aal1``) is denied on every administrative route with the structured
    ``staff_mfa_required`` signal the frontend branches on."""
    _, token = _mirror(cleanup_users, role="admin", aal=aal)
    r = _call(client, method, path, token, str(uuid.uuid4()))
    assert r.status_code == 403, r.text
    assert r.json()["detail"]["code"] == "staff_mfa_required"


@pytest.mark.parametrize("method,path", ADMIN_ROUTES)
def test_admin_routes_deny_entrepreneur(client, cleanup_users, method, path):
    """F1: the default provisioned role (entrepreneur) is not staff, so even a
    completed-MFA entrepreneur cannot reach administrative routes."""
    _, token = _mirror(cleanup_users, role="entrepreneur", aal="aal2")
    r = _call(client, method, path, token, str(uuid.uuid4()))
    assert r.status_code == 403, r.text


@pytest.mark.parametrize("method,path", ADMIN_ROUTES)
def test_admin_routes_deny_agent(client, cleanup_users, method, path):
    """F1: an agent is staff but cannot administer users or read the global
    overview - those are administrator-only, even at aal2."""
    _, token = _mirror(cleanup_users, role="agent", aal="aal2")
    r = _call(client, method, path, token, str(uuid.uuid4()))
    assert r.status_code == 403, r.text


def test_aal2_admin_can_list_and_read_users(client, cleanup_users):
    admin_sub, token = _mirror(cleanup_users, role="admin", aal="aal2")
    r = client.get("/api/v1/users/", headers=auth(token))
    assert r.status_code == 200, r.text
    assert isinstance(r.json(), list)
    r2 = client.get(f"/api/v1/users/{admin_sub}", headers=auth(token))
    assert r2.status_code == 200, r2.text
    assert r2.json()["user_id"] == str(admin_sub)


def test_aal2_admin_can_read_recommendation_overview(client, cleanup_users):
    _, token = _mirror(cleanup_users, role="admin", aal="aal2")
    r = client.get("/api/v1/recommendations/", headers=auth(token))
    assert r.status_code == 200, r.text


def test_aal2_admin_can_delete_other_user(client, cleanup_users):
    _, token = _mirror(cleanup_users, role="admin", aal="aal2")
    target, _ = _mirror(cleanup_users, role="entrepreneur")
    r = client.delete(f"/api/v1/users/{target}", headers=auth(token))
    assert r.status_code == 204, r.text
    # The row is gone; a second delete is a clean 404 (not a crash).
    r2 = client.delete(f"/api/v1/users/{target}", headers=auth(token))
    assert r2.status_code == 404


def test_admin_cannot_delete_self(client, cleanup_users):
    admin_sub, token = _mirror(cleanup_users, role="admin", aal="aal2")
    r = client.delete(f"/api/v1/users/{admin_sub}", headers=auth(token))
    assert r.status_code == 422


# ------------------------------------------------------------- F4 / F7 echo


@pytest.mark.parametrize("aal,expected", [(None, None), ("aal1", "aal1"), ("aal2", "aal2")])
def test_auth_me_echoes_verified_assurance_level(client, cleanup_users, aal, expected):
    """F4: /auth/me reports the assurance level straight off the signed token's
    ``aal`` claim (read-only). Informational - never an authorization input."""
    _, token = _mirror(cleanup_users, role="entrepreneur", aal=aal)
    r = client.get("/api/v1/auth/me", headers=auth(token))
    assert r.status_code == 200, r.text
    assert r.json()["assurance_level"] == expected


def test_password_only_admin_reads_own_status_but_not_staff_data(client, cleanup_users):
    """F7 Option A + F1: an admin who has only entered a password (aal1) may read
    their OWN profile/status (so the client can route to the MFA screen), but the
    very same session is denied every administrative data route. The echoed
    assurance_level is not a capability."""
    _, token = _mirror(cleanup_users, role="admin", aal="aal1")
    me = client.get("/api/v1/auth/me", headers=auth(token))
    assert me.status_code == 200, me.text
    assert me.json()["assurance_level"] == "aal1"
    assert me.json()["role"] == "admin"
    denied = client.get("/api/v1/users/", headers=auth(token))
    assert denied.status_code == 403
    assert denied.json()["detail"]["code"] == "staff_mfa_required"


# --------------------------------------------------------- F5 canonical role


@pytest.mark.parametrize(
    "stored,canonical",
    [
        ("administrator", "admin"),
        ("property_owner", "entrepreneur"),
        ("user", "entrepreneur"),
        ("agent", "agent"),
        ("admin", "admin"),
        ("entrepreneur", "entrepreneur"),
    ],
)
def test_auth_me_canonicalizes_role(client, cleanup_users, stored, canonical):
    """F5: legacy role aliases are normalised to the canonical three-role model
    on read, so clients never have to special-case deprecated values."""
    _, token = _mirror(cleanup_users, role=stored, aal="aal2")
    r = client.get("/api/v1/auth/me", headers=auth(token))
    assert r.status_code == 200, r.text
    assert r.json()["role"] == canonical


def test_auth_session_canonicalizes_role(client, cleanup_users):
    _, token = _mirror(cleanup_users, role="administrator", aal="aal1")
    r = client.get("/api/v1/auth/session", headers=auth(token))
    assert r.status_code == 200, r.text
    assert r.json()["role"] == "admin"


# ------------------------------------------------- F8 unsafe helpers removed


def test_role_only_staff_helpers_removed():
    """F8: the role-only ``require_admin`` / ``require_agent`` helpers (which
    authorized staff actions WITHOUT aal2) are gone; only the MFA-enforcing
    variants and the shared staff gate remain."""
    from sitewise import dependencies as deps

    assert not hasattr(deps, "require_admin")
    assert not hasattr(deps, "require_agent")
    for safe in ("require_admin_mfa", "require_agent_mfa", "get_staff_user"):
        assert hasattr(deps, safe), safe

def test_password_only_admin_cannot_use_property_owner_admin_exception(
    client, cleanup_users
):
    """Admin access through owner APIs must require AAL2."""
    _, token = _mirror(cleanup_users, role="admin", aal="aal1")

    response = client.get(
        # The legacy /properties/mine (public.property) was retired with
        # migration 0005; the owner surface is now the canonical listings
        # endpoint, guarded by the same property-owner dependency.
        "/api/v1/properties/listings/mine",
        headers=auth(token),
    )

    assert response.status_code == 403, response.text
    assert (
        response.json()["detail"]["code"]
        == "staff_mfa_required"
    )