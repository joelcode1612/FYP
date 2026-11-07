"""One-time SiteWise Agent account provisioning (NO invitation email).

Run from the FYP repository root on an administrator-controlled computer:

    & ".\\backend\\.venv\\Scripts\\python.exe" ".\\bootstrap_sitewise_agent.py"

Uses the existing SiteWise Supabase project and the FastAPI application's
PostgreSQL mirror. Never run this script from Flutter/Jaspr or distribute a
Supabase secret key to an Agent.

For a NEW account, an authorized administrator must first independently
verify that the intended Agent controls the email address. Because Supabase
admin.create_user(email_confirm=True) bypasses email verification, this
script requires explicit confirmation of that verification before creation.
Prefer the normal invitation/verified-signup flow where available.
"""

from __future__ import annotations

import hashlib
import os
import re
import sys
import uuid
from getpass import getpass
from pathlib import Path

from supabase import create_client
from supabase.lib.client_options import ClientOptions


EXPECTED_SUPABASE_URL = "https://lzdpjwmcjbhtkzkqudyt.supabase.co"
AGENT_ROLE = "agent"
ALLOWED_PREVIOUS_ROLES = {"entrepreneur", "user", "agent"}

# A fingerprint, NOT a credential. Rejects the exposed key copied into the
# Administrator script supplied as the template. Other previously leaked keys
# must also be revoked in Supabase before provisioning.
EXPOSED_KEY_SHA256 = "cda8df19ce4be057333aa67428393e2f37f434d4bfb89a95fcb9fd3251030503"
EMAIL_PATTERN = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def load_local_env() -> None:
    """Load simple KEY=VALUE entries, without printing or overriding env vars."""
    project_root = Path(__file__).resolve().parent
    for env_path in (project_root / ".env", project_root / "backend" / ".env"):
        if not env_path.is_file():
            continue
        for line in env_path.read_text(encoding="utf-8-sig").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = (part.strip() for part in line.split("=", 1))
            if not key.isidentifier():
                continue
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                value = value[1:-1]
            os.environ.setdefault(key, value)


def confirm(prompt: str, phrase: str) -> None:
    if input(f"{prompt} Type {phrase}: ").strip() != phrase:
        fail("Cancelled. No further changes were made.")


def get_auth_user_by_email(client, email: str):
    """Paginate Auth identities; never create a duplicate if listing fails."""
    page_size = 200
    for page in range(1, 101):
        response = client.auth.admin.list_users(page=page, per_page=page_size)
        users = getattr(response, "users", None)
        if users is None and isinstance(response, dict):
            users = response.get("users")
        if users is None and isinstance(response, list):
            users = response
        if users is None:
            fail("Unexpected Supabase Auth list_users response; review SDK compatibility.")
        for user in users:
            user_email = (getattr(user, "email", None) or "").casefold()
            if user_email == email:
                return user
        if len(users) < page_size:
            return None
    fail("Auth user search exceeded 100 pages. No account created.")


def read_public_profile(client, user_id: str):
    result = (
        client.table("users")
        .select("user_id,email,role,account_status")
        .eq("user_id", user_id)
        .limit(1)
        .execute()
    )
    return (result.data or [None])[0]


def assert_role_transition_safe(existing: dict | None, email: str) -> None:
    if not existing:
        return
    current_role = existing.get("role")
    status = existing.get("account_status")
    existing_email = (existing.get("email") or "").casefold()

    if status == "suspended":
        fail("Existing profile is suspended. Do not override the suspension.")
    if current_role not in ALLOWED_PREVIOUS_ROLES:
        fail(f"Conflicting existing role ({current_role!r}); refusing role change.")
    if existing_email and existing_email != email:
        fail("Existing profile email differs from the Auth identity. Review manually.")


def create_new_auth_user(client, email: str, full_name: str):
    print("No existing Supabase Auth account found for this email.")
    print("This script does NOT send an invitation or verification email.")
    print("The administrator MUST have independently verified the Agent's email ownership.")
    confirm("Confirm that independent email verification has already been completed.", "EMAIL-VERIFIED")

    password = getpass("Enter the new Agent's password (hidden, minimum 12 characters): ")
    repeated = getpass("Repeat the password: ")
    if password != repeated or len(password) < 12:
        fail("Passwords must match and be at least 12 characters.")

    confirm("Authorize creation of this Agent Auth identity.", "CREATE-AGENT")
    try:
        response = client.auth.admin.create_user(
            {
                "email": email,
                "password": password,
                "email_confirm": True,
                "user_metadata": {"full_name": full_name},
            }
        )
        user = getattr(response, "user", None)
        if user is None:
            fail("Auth API created no returned user. Check Authentication > Users.")
        print("Supabase Auth identity created.")
        return user
    except Exception as exc:
        fail(
            "Supabase Auth creation failed: " + str(exc)
            + "\nIf this is a database trigger error, check your Auth user creation triggers."
        )
    finally:
        password = repeated = None


def reconcile_local_profile(user_id: str, email: str, full_name: str) -> None:
    """Use the application's existing trusted staff service, not a new role path."""
    root = Path(__file__).resolve().parent
    backend_src = root / "backend" / "src"
    if not backend_src.is_dir():
        fail("backend/src not found beside this script. Run it from the FYP repository root.")
    if str(backend_src) not in sys.path:
        sys.path.insert(0, str(backend_src))

    from sqlmodel import Session

    from sitewise.db.session import engine
    from sitewise.repositories.user_repository import UserRepository
    from sitewise.services.user_service import UserService

    with Session(engine) as session:
        profile = UserService(session).ensure_staff_profile(
            user_id=uuid.UUID(user_id),
            email=email,
            full_name=full_name,
            phone_number=None,
            role=AGENT_ROLE,
            account_status="active",
        )
        if not getattr(profile, "email_verified", False):
            UserRepository(session).update(profile.user_id, {"email_verified": True})

    print("Local PostgreSQL application profile synchronized (role=agent, active).")


def main() -> None:
    load_local_env()

    url = (os.getenv("SUPABASE_URL") or EXPECTED_SUPABASE_URL).strip().rstrip("/")
    if url != EXPECTED_SUPABASE_URL:
        fail("SUPABASE_URL points to a different project; refusing to proceed.")

    secret = (os.getenv("SUPABASE_SECRET_KEY") or "").strip()
    if not secret:
        secret = getpass("Paste your ROTATED Supabase secret key (hidden): ").strip()
    if not secret.startswith("sb_secret_"):
        fail("SUPABASE_SECRET_KEY must be a Supabase sb_secret_ key.")
    if hashlib.sha256(secret.encode()).hexdigest() == EXPOSED_KEY_SHA256:
        fail("This key was exposed in the supplied Administrator script. Rotate it first.")

    print("\nSiteWise Agent account provisioning (administrator-only)")
    print("Supabase project:", url)
    email = input("Agent email: ").strip().casefold()
    full_name = " ".join(input("Agent full name: ").strip().split())
    if not EMAIL_PATTERN.fullmatch(email):
        fail("Invalid Agent email address.")
    if not (1 <= len(full_name) <= 150):
        fail("Agent full name must be between 1 and 150 characters.")

    print(f"\nAccount: {email} ({full_name})")
    print("Requested role: agent")
    print("Neither an admin nor a property_owner profile may be overwritten.")
    confirm("Confirm authorized administrator operation.", "PROVISION-AGENT")

    client = create_client(
        url,
        secret,
        options=ClientOptions(auto_refresh_token=False, persist_session=False),
    )

    try:
        auth_user = get_auth_user_by_email(client, email)
    except SystemExit:
        raise
    except Exception as exc:
        fail("Could not search Supabase Auth users: " + str(exc))

    if auth_user is None:
        auth_user = create_new_auth_user(client, email, full_name)
    else:
        print("Existing Auth user found. Will not recreate or reset its password.")
        confirmed = (
            getattr(auth_user, "email_confirmed_at", None)
            or getattr(auth_user, "confirmed_at", None)
        )
        if not confirmed:
            fail("This existing account has not confirmed its email. Verify it first.")

    uid = str(auth_user.id)

    try:
        existing = read_public_profile(client, uid)
        assert_role_transition_safe(existing, email)
        if existing and existing.get("role") not in (None, AGENT_ROLE):
            print("Current role:", existing.get("role"))
            confirm("Confirm authorized promotion to Agent.", "PROMOTE-AGENT")

        client.table("users").upsert(
            {
                "user_id": uid,
                "full_name": full_name,
                "email": email,
                "role": AGENT_ROLE,
                "account_status": "active",
                "email_verified": True,
            },
            on_conflict="user_id",
        ).execute()

        record = read_public_profile(client, uid)
        if not record or record.get("role") != AGENT_ROLE or record.get("account_status") != "active":
            fail("Supabase public.users verification failed. Inspect the database.")
    except SystemExit:
        raise
    except Exception as exc:
        fail(
            "Supabase Auth exists, but public.users update failed: " + str(exc)
            + "\nDo not create another Auth user. Inspect users/triggers and rerun."
        )

    try:
        reconcile_local_profile(uid, email, full_name)
    except SystemExit:
        raise
    except Exception as exc:
        fail(
            "Supabase profile is updated, but local PostgreSQL synchronization failed: "
            + str(exc)
            + "\nResolve backend/.env DATABASE_URL or service errors, then rerun this script."
        )

    print("\nSUCCESS: SiteWise Agent provisioned in both identity stores.")
    print("Email:", email)
    print("Role: agent")
    print("Status: active")
    print("Supabase Auth UUID:", uid)
    print("Next: Agent signs in through the Staff Portal and completes required MFA.")
    print("No invitation email was sent; no administrator privilege was granted.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        fail("Cancelled by keyboard interrupt.")
