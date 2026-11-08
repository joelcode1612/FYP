"""Send a Supabase invitation for a SiteWise Agent account.

Run from the FYP repository root on an administrator-controlled computer:

    & ".\\backend\\.venv\\Scripts\\python.exe" ".\\bootstrap_sitewise_agent_invite.py"

The script uses Supabase Auth Admin to send the Agent an invitation email.
The Agent opens the email link and sets their own password on the configured
SiteWise invitation-acceptance page. The Supabase secret key is only read by
this trusted administrator-side script and must never be shipped to Jaspr,
Flutter, JavaScript, or an Agent's device.

Required environment variables (root .env or backend/.env):
    SUPABASE_URL=https://<project-ref>.supabase.co
    SUPABASE_SECRET_KEY=<NEWLY ROTATED sb_secret_... key>

Optional:
    SUPABASE_INVITE_REDIRECT_URL=https://<your-site>/auth/accept-invite

The redirect URL must be configured in Supabase Dashboard > Authentication >
URL Configuration > Redirect URLs. If omitted, Supabase uses the project's
configured Site URL.

After the Agent accepts the invite and sets a password, run this script again
for that email to reconcile email_verified=True in both user-profile stores.
The application should also perform this reconciliation in its authenticated
invite-acceptance callback/API; do not rely on user_metadata for authorization.
"""

from __future__ import annotations

import hashlib
import os
import re
import sys
import uuid
from getpass import getpass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from supabase import create_client
from supabase.lib.client_options import ClientOptions


EXPECTED_SUPABASE_URL = "https://lzdpjwmcjbhtkzkqudyt.supabase.co"
AGENT_ROLE = "agent"
ALLOWED_PREVIOUS_ROLES = {"entrepreneur", "user", "agent"}
EMAIL_PATTERN = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")

# Credential fingerprint only. It is not the credential itself. This blocks
# the known key that was embedded in the earlier administrator provisioning
# script. Rotate every key that has been exposed and use the replacement.
EXPOSED_KEY_SHA256 = "cda8df19ce4be057333aa67428393e2f37f434d4bfb89a95fcb9fd3251030503"


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def load_local_env() -> None:
    """Load simple KEY=VALUE entries without printing or overriding env vars."""
    project_root = Path(__file__).resolve().parent
    for env_path in (project_root / ".env", project_root / "backend" / ".env"):
        if not env_path.is_file():
            continue
        for raw_line in env_path.read_text(encoding="utf-8-sig").splitlines():
            line = raw_line.strip()
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


def field(value: Any, name: str, default: Any = None) -> Any:
    """Read a field from either an SDK model or a dictionary response."""
    if isinstance(value, dict):
        return value.get(name, default)
    return getattr(value, name, default)


def response_user(response: Any) -> Any:
    """Support the Auth SDK's model and dictionary response forms."""
    user = field(response, "user")
    if user is not None:
        return user
    data = field(response, "data")
    if data is not None:
        return field(data, "user")
    return None


def get_auth_user_by_email(client: Any, email: str) -> Any | None:
    """Paginate Auth identities; never invite if the search fails."""
    page_size = 200
    for page in range(1, 101):
        response = client.auth.admin.list_users(page=page, per_page=page_size)
        users = field(response, "users")
        if users is None and isinstance(response, list):
            users = response
        if users is None:
            fail("Unexpected Supabase Auth list_users response; review SDK compatibility.")

        for user in users:
            user_email = (field(user, "email") or "").casefold()
            if user_email == email:
                return user

        if len(users) < page_size:
            return None

    fail("Auth user search exceeded 100 pages. No invitation was sent.")


def read_public_profile(client: Any, user_id: str) -> dict[str, Any] | None:
    result = (
        client.table("users")
        .select("user_id,email,role,account_status,email_verified")
        .eq("user_id", user_id)
        .limit(1)
        .execute()
    )
    rows = field(result, "data", []) or []
    return rows[0] if rows else None


def assert_role_transition_safe(existing: dict[str, Any] | None, email: str) -> None:
    if not existing:
        return

    current_role = existing.get("role")
    status = existing.get("account_status")
    existing_email = (existing.get("email") or "").casefold()

    if status == "suspended":
        fail("Existing profile is suspended. Do not override the suspension.")
    if current_role not in (None, *ALLOWED_PREVIOUS_ROLES):
        fail(f"Conflicting existing role ({current_role!r}); refusing role change.")
    if existing_email and existing_email != email:
        fail("Existing profile email differs from the Auth identity. Review manually.")


def invite_new_auth_user(
    client: Any,
    email: str,
    full_name: str,
    redirect_url: str | None,
) -> Any:
    """Create an unconfirmed Auth identity and send its invitation email."""
    print("No existing Supabase Auth account found for this email.")
    print("Supabase will send the Agent an invitation email; no password is set by the admin.")

    options: dict[str, Any] = {"data": {"full_name": full_name}}
    if redirect_url:
        options["redirect_to"] = redirect_url

    confirm("Authorize sending the Agent invitation email.", "SEND-AGENT-INVITE")
    try:
        response = client.auth.admin.invite_user_by_email(email, options=options)
        user = response_user(response)
        if user is None:
            fail("Supabase invitation returned no user. Check Authentication > Users and email logs.")
        print("Supabase Auth invitation sent successfully.")
        return user
    except SystemExit:
        raise
    except Exception as exc:
        fail(
            "Supabase invitation failed: " + str(exc)
            + "\nCheck Auth email delivery, SMTP/rate limits, redirect allow-list, and whether this email already exists."
        )


def validate_redirect_url(value: str | None) -> str | None:
    if not value:
        return None
    parsed = urlparse(value)
    if parsed.scheme not in {"https", "http"} or not parsed.netloc:
        fail("SUPABASE_INVITE_REDIRECT_URL must be a complete https:// URL (http://localhost is allowed for development).")
    if parsed.scheme == "http" and parsed.hostname not in {"localhost", "127.0.0.1"}:
        fail("Use HTTPS for non-local invitation redirect URLs.")
    return value


def reconcile_local_profile(
    user_id: str,
    email: str,
    full_name: str,
    email_verified: bool,
) -> None:
    """Use the application's existing staff service and preserve verification state."""
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
        UserRepository(session).update(
            profile.user_id,
            {"email_verified": email_verified},
        )

    print(
        "Local PostgreSQL application profile synchronized "
        f"(role=agent, active, email_verified={email_verified})."
    )


def main() -> None:
    load_local_env()

    url = (os.getenv("SUPABASE_URL") or EXPECTED_SUPABASE_URL).strip().rstrip("/")
    if url != EXPECTED_SUPABASE_URL:
        fail("SUPABASE_URL points to a different project; refusing to proceed.")

    secret = (os.getenv("SUPABASE_SECRET_KEY") or "").strip()
    if not secret:
        secret = getpass("Paste your NEWLY ROTATED Supabase secret key (hidden): ").strip()
    if not secret.startswith("sb_secret_"):
        fail("SUPABASE_SECRET_KEY must be a Supabase sb_secret_ key.")
    if hashlib.sha256(secret.encode()).hexdigest() == EXPOSED_KEY_SHA256:
        fail("This key was exposed in the earlier administrator script. Rotate it before continuing.")

    redirect_url = validate_redirect_url(
        (os.getenv("SUPABASE_INVITE_REDIRECT_URL") or "").strip() or None
    )

    print("\nSiteWise Agent invitation (administrator-only)")
    print("Supabase project:", url)
    email = input("Agent email: ").strip().casefold()
    full_name = " ".join(input("Agent full name: ").strip().split())
    if not EMAIL_PATTERN.fullmatch(email):
        fail("Invalid Agent email address.")
    if not (1 <= len(full_name) <= 150):
        fail("Agent full name must be between 1 and 150 characters.")

    print(f"\nAccount: {email} ({full_name})")
    print("Requested role: agent")
    print("An invited Agent remains email-unverified until the invitation is accepted.")
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

    invited_now = False
    if auth_user is None:
        auth_user = invite_new_auth_user(client, email, full_name, redirect_url)
        invited_now = True
    else:
        confirmed_at = (
            field(auth_user, "email_confirmed_at")
            or field(auth_user, "confirmed_at")
        )
        if not confirmed_at:
            fail(
                "An unconfirmed Supabase Auth account already exists for this email. "
                "No duplicate user was created and no second email was sent. "
                "Check Authentication > Users and resend the pending invitation there, "
                "or let the Agent complete the existing invitation."
            )
        print("A confirmed Supabase Auth account already exists; no invitation was sent.")
        print("The script will only reconcile its SiteWise Agent profile after explicit authorization.")

    user_id = field(auth_user, "id")
    if not user_id:
        fail("Supabase Auth response did not include a user ID. Check Authentication > Users.")
    uid = str(user_id)

    email_verified = not invited_now
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
                "email_verified": email_verified,
            },
            on_conflict="user_id",
        ).execute()

        record = read_public_profile(client, uid)
        if (
            not record
            or record.get("role") != AGENT_ROLE
            or record.get("account_status") != "active"
            or bool(record.get("email_verified")) != email_verified
        ):
            fail("Supabase public.users verification failed. Inspect the database.")
    except SystemExit:
        raise
    except Exception as exc:
        fail(
            "Supabase Auth identity exists, but public.users update failed: " + str(exc)
            + "\nDo not create another Auth user. Inspect users/triggers and rerun after resolving the issue."
        )

    try:
        reconcile_local_profile(uid, email, full_name, email_verified)
    except SystemExit:
        raise
    except Exception as exc:
        fail(
            "Supabase profile is updated, but local PostgreSQL synchronization failed: "
            + str(exc)
            + "\nResolve backend/.env DATABASE_URL or service errors, then rerun this script."
        )

    print("\nSUCCESS: SiteWise Agent profile synchronized.")
    print("Email:", email)
    print("Role: agent")
    print("Status: active")
    print("Email verified:", email_verified)
    print("Supabase Auth UUID:", uid)
    if invited_now:
        print("Invitation: sent by Supabase Auth.")
        print("Next: Agent opens the email link, completes setup, and chooses a password.")
        print("After acceptance, synchronize email_verified=True via the app callback/API or rerun this script.")
    else:
        print("Invitation: not sent because this Auth account is already confirmed.")
    print("No administrator privilege was granted.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        fail("Cancelled by keyboard interrupt.")
