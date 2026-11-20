#!/usr/bin/env python3
"""SiteWise one-account maintenance: clear display name + reset verified TOTP MFA.

DRY RUN by default. Nothing is deleted except verified Supabase TOTP factors
when --apply is explicitly supplied. User IDs, emails, roles, verification,
account statuses, and other records are preserved.

Execute with the SAME trusted backend environment used by SiteWise:
    py sitewise_clear_name_reset_mfa.py --root "C:\\Users\\Lenovo\\AndroidStudioProjects\\FYP" --email user@example.com
    py sitewise_clear_name_reset_mfa.py --root "C:\\Users\\Lenovo\\AndroidStudioProjects\\FYP" --email user@example.com --apply

This operation spans two databases and Supabase Auth: it cannot be atomic.
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--root", type=Path, required=True, help="SiteWise FYP repository root")
    p.add_argument("--email", required=True, help="Exact email of one account; names are not unique")
    p.add_argument("--apply", action="store_true", help="Actually apply changes; otherwise preview only")
    return p.parse_args()


def ensure_one(rows: list, kind: str):
    if len(rows) != 1:
        raise RuntimeError(f"Expected exactly one {kind} record; found {len(rows)}. Nothing changed.")
    return rows[0]


def main() -> int:
    args = parse_args()
    email = args.email.strip().lower()
    if not email or "@" not in email or email.count("@") != 1:
        raise ValueError("Provide exactly one valid-looking email with --email.")

    backend = args.root.resolve() / "backend"
    src = backend / "src"
    if not (src / "sitewise" / "db" / "models" / "user.py").is_file():
        raise RuntimeError("--root does not look like the SiteWise FYP repository.")
    if not (backend / ".env").is_file():
        raise RuntimeError("backend/.env is missing. Configure it locally; never paste keys into this script.")

    # SiteWise BaseSettings reads the .env file relative to the backend CWD.
    os.chdir(backend)
    sys.path.insert(0, str(src))

    from sqlalchemy import func
    from sqlalchemy.engine import make_url
    from sqlmodel import Session, select
    from sitewise.core.config import settings
    from sitewise.core.supabase_admin import SupabaseAdminService
    from sitewise.db.models.user import User
    from sitewise.db.session import engine

    # This utility is specifically for the LOCAL operational mirror, not a
    # second connection to the hosted Supabase database. Fail closed otherwise.
    database_host = (make_url(settings.database_url).host or "").lower()
    if database_host not in {"localhost", "127.0.0.1", "::1"}:
        raise RuntimeError(
            f"DATABASE_URL points to '{database_host}', not a local database. "
            "Refusing to edit it as the local mirror."
        )
    supabase_host = urlparse(settings.supabase_url).hostname or ""
    if not supabase_host.endswith(".supabase.co") or not settings.supabase_secret_key:
        raise RuntimeError("Expected a configured Supabase project URL and server-only secret in backend/.env.")

    admin = SupabaseAdminService()
    with Session(engine) as session:
        local = ensure_one(
            list(session.exec(select(User).where(func.lower(User.email) == email)).all()),
            "local users",
        )
        uid = str(local.user_id)
        if str(local.role).lower() in {"admin", "administrator"}:
            raise RuntimeError("Refusing to reset an administrator account with this utility.")

        cloud_data = (
            admin.client.table("users")
            .select("user_id,email,full_name,role")
            .eq("user_id", uid)
            .limit(2)
            .execute()
        )
        cloud = ensure_one(list(cloud_data.data or []), "Supabase public.users")
        auth = admin.get_auth_user(uid)
        if auth is None:
            raise RuntimeError("Supabase Auth has no matching user; nothing changed.")
        if any(
            str(found).strip().lower() != email
            for found in (cloud.get("email"), auth.get("email"))
        ):
            raise RuntimeError("Email differs between local, Supabase public.users and Auth; nothing changed.")
        if str(cloud.get("role", "")).strip().lower() != str(local.role).strip().lower():
            raise RuntimeError("Role differs between local and Supabase; nothing changed.")

        factors = admin.admin_list_factors(uid)
        to_remove = [
            str(f.get("id") or f.get("factor_id"))
            for f in factors
            if str(f.get("status", "")).lower() == "verified"
            and str(f.get("factor_type", f.get("type", ""))).lower() == "totp"
            and (f.get("id") or f.get("factor_id"))
        ]
        if len(to_remove) != len(set(to_remove)):
            raise RuntimeError("Duplicate MFA factor IDs returned; nothing changed.")

        meta = auth.get("user_metadata") or {}
        if not isinstance(meta, dict):
            raise RuntimeError("Unreadable Auth user_metadata; nothing changed.")
        # Keep other user metadata and all app_metadata; change full_name only.
        revised_meta = {**meta, "full_name": ""}

        print(f"Account verified in three locations: {email} (user_id={uid})")
        print(f"Local role: {local.role}; Supabase role: {cloud.get('role')}")
        print(f"Local full_name populated: {bool(local.full_name)}")
        print(f"Supabase public.users full_name populated: {bool(cloud.get('full_name'))}")
        print(f"Supabase Auth metadata full_name populated: {bool(meta.get('full_name'))}")
        print(f"Verified TOTP factors eligible for reset: {len(to_remove)}")
        print("Other factor types, roles, passwords, emails and account statuses: untouched")

        if not args.apply:
            print("DRY RUN: No changes made. Repeat with --apply to execute.")
            return 0

        typed = input(f"Type the exact email '{email}' to confirm: ").strip().lower()
        if typed != email:
            print("Confirmation did not match; nothing changed.")
            return 2

        completed: list[str] = []
        try:
            # Cloud profile update; require an affected row to prevent silent success.
            updated = (
                admin.client.table("users")
                .update({"full_name": ""})
                .eq("user_id", uid)
                .select("user_id,full_name")
                .execute()
            )
            ensure_one(list(updated.data or []), "updated Supabase public.users")
            completed.append("Supabase public.users.full_name cleared")

            # Update Auth metadata (separate from the public profile table).
            admin.client.auth.admin.update_user_by_id(uid, {"user_metadata": revised_meta})
            refreshed_auth = admin.get_auth_user(uid)
            if not refreshed_auth or (refreshed_auth.get("user_metadata") or {}).get("full_name") not in ("", None):
                raise RuntimeError("Auth metadata name did not verify as blank")
            completed.append("Supabase Auth user_metadata.full_name cleared")

            # Commit local mirror only when both Supabase name writes succeeded.
            local.full_name = ""
            local.updated_at = datetime.now(timezone.utc)
            session.add(local)
            session.commit()
            session.refresh(local)
            if local.full_name != "":
                raise RuntimeError("Local name write did not verify as blank")
            completed.append("Local users.full_name cleared")

            # Factor deletion is intentionally LAST and cannot be rolled back.
            for factor_id in to_remove:
                admin.admin_delete_factor(uid, factor_id)
                completed.append(f"Supabase verified TOTP factor {factor_id} removed")
            still = admin.admin_list_factors(uid)
            remaining = [
                f for f in still
                if str(f.get("status", "")).lower() == "verified"
                and str(f.get("factor_type", f.get("type", ""))).lower() == "totp"
            ]
            if remaining:
                raise RuntimeError(f"{len(remaining)} verified TOTP factor(s) remain")

        except Exception as exc:
            session.rollback()
            print("ERROR: Operation stopped; results across systems may be PARTIAL.", file=sys.stderr)
            for step in completed:
                print("  COMPLETED: " + step, file=sys.stderr)
            print("  FAILED: " + str(exc), file=sys.stderr)
            print("Check both databases and Auth before retrying. Do not assume rollback.", file=sys.stderr)
            return 1

        print("SUCCESS: Name cleared in local DB, Supabase public.users and Supabase Auth metadata.")
        print(f"SUCCESS: Removed {len(to_remove)} verified Supabase TOTP factor(s).")
        print("NOTE: SiteWise role-based MFA enforcement is unchanged. Staff users must enroll MFA again.")
        print("NOTE: Resetting a verified factor may log the user out of all active sessions.")
        return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print("Stopped safely: " + str(exc), file=sys.stderr)
        sys.exit(1)
