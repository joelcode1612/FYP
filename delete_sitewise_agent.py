"""Permanently delete one SiteWise Agent from Supabase Auth and its public profile.

Run this script from the SiteWise repository root. It loads SUPABASE_URL and
SUPABASE_SECRET_KEY from the root .env or backend/.env, or prompts for the
secret key without displaying it.

This script is intentionally restricted to one exact user ID + email pair.
It deletes the Auth identity first through the Supabase Auth Admin API. If the
public.users profile remains after successful Auth deletion, it removes only
that matching profile row.
"""

from __future__ import annotations

import os
import sys
from getpass import getpass
from pathlib import Path


EXPECTED_SUPABASE_URL = "https://lzdpjwmcjbhtkzkqudyt.supabase.co"
TARGET_USER_ID = "83cdcd24-9927-4b78-abe3-f234d7f04bdf"
TARGET_EMAIL = "joelstrengthpersonal@gmail.com"
CONFIRMATION_TEXT = f"DELETE {TARGET_EMAIL}"


def load_local_env() -> None:
    """Load simple KEY=VALUE pairs without overwriting existing env variables."""
    root = Path(__file__).resolve().parent
    for env_path in (root / ".env", root / "backend" / ".env"):
        if not env_path.is_file():
            continue
        try:
            lines = env_path.read_text(encoding="utf-8-sig").splitlines()
        except OSError as exc:
            raise SystemExit(f"ERROR: Cannot read {env_path}: {exc}")

        for raw_line in lines:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = (part.strip() for part in line.split("=", 1))
            if not key.isidentifier():
                continue
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                value = value[1:-1]
            os.environ.setdefault(key, value)


def extract_user(response):
    """Handle common supabase-py response object shapes."""
    user = getattr(response, "user", None)
    if user is not None:
        return user

    data = getattr(response, "data", None)
    if data is not None:
        user = getattr(data, "user", None)
        if user is not None:
            return user

    if isinstance(response, dict):
        if response.get("user") is not None:
            return response["user"]
        data = response.get("data")
        if isinstance(data, dict):
            return data.get("user")

    return None


def get_value(obj, key: str):
    if isinstance(obj, dict):
        return obj.get(key)
    return getattr(obj, key, None)


def main() -> int:
    load_local_env()

    url = (os.getenv("SUPABASE_URL") or EXPECTED_SUPABASE_URL).strip().rstrip("/")
    if url != EXPECTED_SUPABASE_URL:
        print("ERROR: SUPABASE_URL does not match the expected SiteWise project.")
        return 1

    secret = (os.getenv("SUPABASE_SECRET_KEY") or "").strip()
    if not secret:
        secret = getpass("Enter the ROTATED Supabase secret key (input hidden): ").strip()

    if not secret:
        print("ERROR: SUPABASE_SECRET_KEY is required.")
        return 1
    if secret.startswith("sb_publishable_"):
        print("ERROR: A publishable key cannot perform Auth Admin deletion.")
        return 1

    try:
        from supabase import create_client
        from supabase.lib.client_options import ClientOptions
    except ImportError:
        print("ERROR: supabase package is missing.")
        print(f'Install it with: "{sys.executable}" -m pip install --upgrade supabase')
        return 1

    try:
        client = create_client(
            url,
            secret,
            options=ClientOptions(auto_refresh_token=False, persist_session=False),
        )

        # Confirm the Auth identity matches BOTH the expected UUID and email.
        auth_response = client.auth.admin.get_user_by_id(TARGET_USER_ID)
        auth_user = extract_user(auth_response)
        if auth_user is None:
            print("ERROR: Supabase did not return the requested Auth user. Nothing deleted.")
            return 1

        actual_id = str(get_value(auth_user, "id") or "")
        actual_email = str(get_value(auth_user, "email") or "").casefold()
        if actual_id != TARGET_USER_ID or actual_email != TARGET_EMAIL.casefold():
            print("ERROR: Auth user ID/email does not match the fixed target. Nothing deleted.")
            print(f"Returned ID: {actual_id or '(missing)'}")
            print(f"Returned email: {actual_email or '(missing)'}")
            return 1

        # Check the associated SiteWise public profile before doing anything.
        profile_response = (
            client.table("users")
            .select("user_id,email,role,account_status")
            .eq("user_id", TARGET_USER_ID)
            .limit(1)
            .execute()
        )
        profiles = profile_response.data or []
        profile = profiles[0] if profiles else None
        if profile:
            profile_email = str(profile.get("email") or "").casefold()
            if profile_email != TARGET_EMAIL.casefold():
                print("ERROR: public.users profile email does not match the target. Nothing deleted.")
                print(f"Profile email: {profile_email or '(missing)'}")
                return 1

        print("\nSiteWise account deletion (administrator-only)")
        print(f"Supabase project: {url}")
        print(f"Target email: {TARGET_EMAIL}")
        print(f"Auth UUID: {TARGET_USER_ID}")
        if profile:
            print(f"public.users profile: found (role={profile.get('role')}, status={profile.get('account_status')})")
        else:
            print("public.users profile: not found")
        print("\nWARNING: This permanently deletes the Auth identity.")
        print("If the Auth deletion succeeds and the public profile remains, this script removes that exact profile too.")

        typed = input(f"To continue, type exactly {CONFIRMATION_TEXT}: ").strip()
        if typed != CONFIRMATION_TEXT:
            print("Cancelled. No changes were made.")
            return 0

        # Delete the Auth identity through Supabase's supported Admin API.
        client.auth.admin.delete_user(TARGET_USER_ID)
        print("\nSupabase Auth Admin delete request completed.")

        # If the project does not have ON DELETE CASCADE configured for this
        # profile relation, remove only the matching residual public profile.
        remaining = (
            client.table("users")
            .select("user_id,email")
            .eq("user_id", TARGET_USER_ID)
            .limit(1)
            .execute()
        )
        remaining_profiles = remaining.data or []
        if remaining_profiles:
            remaining_email = str(remaining_profiles[0].get("email") or "").casefold()
            if remaining_email != TARGET_EMAIL.casefold():
                print("WARNING: A residual public profile has a different email. It was NOT deleted.")
            else:
                (
                    client.table("users")
                    .delete()
                    .eq("user_id", TARGET_USER_ID)
                    .eq("email", TARGET_EMAIL)
                    .execute()
                )
                print("Matching public.users profile deletion request completed.")
        else:
            print("public.users profile was already removed (likely by ON DELETE CASCADE).")

        # Verify the public profile through the Data API.
        final_profile = (
            client.table("users")
            .select("user_id,email")
            .eq("user_id", TARGET_USER_ID)
            .limit(1)
            .execute()
        )
        if final_profile.data:
            print("WARNING: public.users still contains the profile. Check constraints/triggers and database logs.")
        else:
            print("Verified: no matching public.users profile remains.")

        print("\nNext verification in Supabase SQL Editor:")
        print("SELECT id, email FROM auth.users WHERE id = '")
        print(f"{TARGET_USER_ID}';")
        print("Expected: Success. No rows returned.")
        print("\nDeletion call finished. Verify Authentication > Users before considering the task complete.")
        return 0

    except Exception as exc:
        print("\nERROR: Account deletion did not complete successfully.")
        print(f"Details: {exc}")
        print("No direct SQL DELETE against auth.users was attempted.")
        print("If the error mentions a foreign-key constraint, inspect dependent tables and ON DELETE rules.")
        print("If it mentions Storage ownership, remove or reassign the user's owned Storage objects first.")
        return 1
    finally:
        # Avoid retaining an unnecessary reference in this script's scope.
        secret = None


if __name__ == "__main__":
    raise SystemExit(main())
