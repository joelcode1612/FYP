r"""One-time Sitewise initial Administrator setup (NO invitation).

Run from the FYP project directory:
    & ".\backend\.venv\Scripts\python.exe" ".\bootstrap_sitewise_admin.py"

Requires: supabase Python SDK already installed in the backend virtualenv.
Put SUPABASE_SECRET_KEY=<NEW ROTATED KEY> in backend/.env or enter it at prompt.
Never put the secret key in Flutter/Jaspr or commit it to Git.
"""

import hashlib
import os
import sys
import uuid
from getpass import getpass
from pathlib import Path

from supabase import create_client
from supabase.lib.client_options import ClientOptions


# Public project URL and intended one-time Administrator address.
SUPABASE_URL = "https://lzdpjwmcjbhtkzkqudyt.supabase.co"
ADMIN_EMAIL = "admin.sitewise1@gmail.com"
ADMIN_FULL_NAME = "Sitewise Administrator1"

# SHA-256 fingerprint ONLY (not the secret) of the key previously exposed.
EXPOSED_KEY_SHA256 = (
    "sb_secret_q2uEfjpJOCpsUCGeRf7YFA__i2Qanpk"
)


def load_local_env():
    """Load simple KEY=VALUE entries without requiring python-dotenv."""
    root = Path(__file__).resolve().parent
    for path in (root / ".env", root / "backend" / ".env"):
        if not path.is_file():
            continue
        for line in path.read_text(encoding="utf-8-sig").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, value = line.split("=", 1)
            name, value = name.strip(), value.strip()
            if not name or not name.isidentifier():
                continue
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                value = value[1:-1]
            os.environ.setdefault(name, value)


def fail(message):
    raise SystemExit("ERROR: " + message)


def get_admin_by_email(client, email):
    """Search every relevant page; never create a duplicate on lookup failure."""
    page_size = 200
    for page in range(1, 101):
        response = client.auth.admin.list_users(page=page, per_page=page_size)
        users = getattr(response, "users", None)
        if users is None and isinstance(response, dict):
            users = response.get("users")
        if users is None and isinstance(response, list):
            users = response
        if users is None:
            fail("Unexpected list_users() response; no user was created. Check supabase SDK version.")
        for user in users:
            user_email = (getattr(user, "email", None) or "").lower()
            if user_email == email:
                return user
        if len(users) < page_size:
            return None
    fail("Auth user list exceeded the safety limit. No user was created.")


def main():
    load_local_env()
    url = os.getenv("SUPABASE_URL", SUPABASE_URL).strip().rstrip("/")
    # Use only the NEW secret key; no publishable/anon key can create Auth users.
    secret = (os.getenv("SUPABASE_SECRET_KEY") or "").strip()
    if not secret:
        secret = getpass("Paste your NEW ROTATED Supabase secret key (hidden): ").strip()

    if not secret.startswith("sb_secret_"):
        fail("Use the NEW sb_secret_ key, not the sb_publishable_ key.")
    if hashlib.sha256(secret.encode()).hexdigest() == EXPOSED_KEY_SHA256:
        fail("This is the previously exposed key. Revoke it in Supabase and create a NEW secret key.")
    if url != SUPABASE_URL:
        fail("SUPABASE_URL points to a different project; check backend/.env.")

    print("Sitewise initial Administrator setup")
    print("Project:", url)
    print("Administrator:", ADMIN_EMAIL)
    print("This is a privileged, one-time bootstrap operation.")
    if input("Type BOOTSTRAP to authorize this action: ").strip() != "BOOTSTRAP":
        fail("Cancelled.")

    client = create_client(
        url,
        secret,
        options=ClientOptions(auto_refresh_token=False, persist_session=False),
    )

    try:
        auth_user = get_admin_by_email(client, ADMIN_EMAIL)
    except Exception as exc:
        fail(
            "Could not list Supabase Auth users: " + str(exc)
            + "\nCheck the NEW secret key, project, and supabase SDK version."
        )

    if auth_user is None:
        print("No existing Auth account was found for this email.")
        print("No invitation email will be sent.")
        print("Only continue if you control and have verified this mailbox.")
        if input("Type I-OWN-EMAIL to confirm email ownership: ").strip() != "I-OWN-EMAIL":
            fail("Cancelled.")
        password = getpass("Choose a NEW Administrator password (hidden): ")
        repeat = getpass("Repeat the password: ")
        if password != repeat or len(password) < 12:
            fail("Passwords must match and contain at least 12 characters.")
        try:
            response = client.auth.admin.create_user(
                {
                    "email": ADMIN_EMAIL,
                    "password": password,
                    "email_confirm": True,
                    "user_metadata": {"full_name": ADMIN_FULL_NAME},
                }
            )
            auth_user = response.user
            if auth_user is None:
                fail("Auth API returned no user; review Authentication > Users.")
            print("Supabase Auth identity created successfully.")
        except Exception as exc:
            fail(
                "Auth account creation failed: " + str(exc)
                + "\nIf you see 'Database error creating new user', check your legacy"
                " public.handle_new_auth_user trigger; it may insert the removed 'user' role."
            )
        finally:
            password = repeat = None
    else:
        print("Existing Auth identity found; it will NOT be recreated or have its password reset.")
        confirmed = getattr(auth_user, "email_confirmed_at", None) or getattr(
            auth_user, "confirmed_at", None
        )
        if not confirmed:
            fail("Existing Auth account is not email-confirmed. Verify it first.")

    uid = str(auth_user.id)

    try:
        existing_result = client.table("users").select(
            "user_id,email,role,account_status"
        ).eq("user_id", uid).limit(1).execute()
        existing = (existing_result.data or [None])[0]

        if existing and existing.get("account_status") == "suspended":
            fail("Existing profile is suspended; do not bootstrap over a suspension.")
        if existing and existing.get("role") not in ("entrepreneur", "admin", "user"):
            fail("Existing profile has a conflicting role; review manually.")
        if existing and existing.get("role") != "admin":
            print("Existing profile role:", existing.get("role"))
            if input("Type PROMOTE to make this identity the Administrator: ").strip() != "PROMOTE":
                fail("Cancelled before profile role change. Auth account remains available.")

        client.table("users").upsert(
            {
                "user_id": uid,
                "full_name": ADMIN_FULL_NAME,
                "email": ADMIN_EMAIL,
                "role": "admin",
                "account_status": "active",
                "email_verified": True,
            },
            on_conflict="user_id",
        ).execute()
        verification = client.table("users").select(
            "user_id,email,role,account_status"
        ).eq("user_id", uid).limit(1).execute()
        record = (verification.data or [None])[0]
        if not record or record.get("role") != "admin" or record.get("account_status") != "active":
            fail("Profile verification failed; review public.users in SQL Editor.")
    except SystemExit:
        raise
    except Exception as exc:
        fail(
            "Auth user exists, but public.users profile update failed: " + str(exc)
            + "\nDo NOT create the Auth account again. Check the users table, triggers, and logs."
        )

    # --- Local application mirror (what FastAPI /auth/me actually reads) ------
    # The Supabase public.users row alone is NOT enough: the backend resolves
    # the authoritative role from its own PostgreSQL mirror and auto-provisions
    # a missing row as `entrepreneur` on first sign-in. Reconcile the SAME
    # Supabase Auth UUID here through the trusted staff-provisioning service so
    # both stores agree and the Administrator lands on /admin, never
    # /entrepreneur. No client-submitted role is involved.
    try:
        src = Path(__file__).resolve().parent / "backend" / "src"
        if src.is_dir() and str(src) not in sys.path:
            sys.path.insert(0, str(src))
        from sqlmodel import Session

        from sitewise.db.session import engine
        from sitewise.repositories.user_repository import UserRepository
        from sitewise.services.user_service import UserService

        with Session(engine) as session:
            mirror = UserService(session).ensure_staff_profile(
                user_id=uuid.UUID(uid),
                email=ADMIN_EMAIL,
                full_name=ADMIN_FULL_NAME,
                phone_number=None,
                role="admin",
                account_status="active",
            )
            if not mirror.email_verified:
                # Supabase owns verification; mirror the confirmed flag.
                UserRepository(session).update(mirror.user_id, {"email_verified": True})
        print("Local application profile reconciled (role=admin, status=active).")
    except SystemExit:
        raise
    except Exception as exc:
        fail(
            "Supabase profile is correct, but the local application mirror could not be reconciled: "
            + str(exc)
            + "\nRun this script with backend/.venv/Scripts/python.exe so the sitewise package and "
            "DATABASE_URL are available, then verify the users table."
        )

    print("\nSUCCESS: Initial Sitewise Administrator is provisioned.")
    print("Email:", record["email"])
    print("Role:", record["role"])
    print("Status:", record["account_status"])
    print("Next: sign in to Staff Portal, enroll TOTP MFA and complete aal2 verification.")
    print("This setup does NOT bypass MFA and does NOT invite any Agents.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        fail("Cancelled by keyboard interrupt.")
