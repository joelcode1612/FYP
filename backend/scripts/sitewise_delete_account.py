"""Safely delete one SiteWise account by *both* email and role.

Run from the FYP/backend directory with its .venv Python.
Default: read-only preview. Add --apply for an explicitly confirmed deletion.

Targets:
  1. Local PostgreSQL public.users (mirror)
  2. Supabase Auth user
  3. Supabase public.agent profile if applicable
  4. Supabase public.users (authoritative profile)

This is NOT a distributed transaction. If cloud deletion succeeds and a later
operation fails, the output explains that manual reconciliation is needed.
It never cascades through or deletes commercial property records.
"""

from __future__ import annotations

import argparse
import sys
import uuid

from sqlalchemy import create_engine, text

from sitewise.core.config import settings
from sitewise.core.supabase_admin import SupabaseAdminService, get_supabase_admin_client

ROLES = ("entrepreneur", "owner", "agent", "admin")


def stop(message: str) -> None:
    raise RuntimeError(message)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--email", required=True, help="Exact email to match")
    parser.add_argument("--role", required=True, choices=ROLES)
    parser.add_argument("--apply", action="store_true", help="Perform deletion after interactive confirmation")
    parser.add_argument("--allow-admin", action="store_true", help="Explicitly allow an admin account (use with caution)")
    args = parser.parse_args()
    email = args.email.strip().lower()
    role = args.role
    if not email or "@" not in email:
        stop("Provide a valid --email.")
    if role == "admin" and not args.allow_admin:
        stop("Admin accounts are protected. Add --allow-admin only if absolutely intended.")
    if not settings.supabase_secret_key or not settings.supabase_url:
        stop("Supabase server credentials are not configured in backend/.env.")

    service = SupabaseAdminService()
    client = get_supabase_admin_client()
    auth_user = service.find_auth_user_by_email(email)
    if not auth_user:
        stop(f"No Supabase Auth account found with email {email!r}; nothing was deleted.")
    user_id = str(uuid.UUID(str(auth_user["id"])))
    auth_email = (auth_user.get("email") or "").strip().lower()
    if auth_email != email:
        stop("Supabase Auth email does not match the requested email.")

    cloud_user = service.get_identity_profile(user_id)
    if not cloud_user:
        stop("Supabase public.users profile missing; cannot confirm role. Nothing deleted.")
    if (cloud_user.get("email") or "").strip().lower() != email:
        stop("Supabase public.users email differs from Supabase Auth; nothing deleted.")
    if cloud_user.get("role") != role:
        stop(f"Supabase role is {cloud_user.get('role')!r}, not requested {role!r}; nothing deleted.")

    agent_result = client.table("agent").select("agent_id,user_id").eq("user_id", user_id).execute()
    agents = agent_result.data or []
    if len(agents) > 1:
        stop("Multiple agent profiles use this UUID; resolve duplicates before deletion.")
    agent_id = int(agents[0]["agent_id"]) if agents else None

    engine = create_engine(settings.database_url, pool_pre_ping=True)
    try:
        with engine.connect() as db:
            # Do not delete owned or assigned commercial properties as a side effect.
            owned = int(db.execute(
                text("SELECT count(*) FROM fyp.rental_properties WHERE owner_user_id = :uid"),
                {"uid": user_id},
            ).scalar_one())
            assigned = int(db.execute(
                text("SELECT count(*) FROM public.agent_listing_assignment WHERE agent_id = :aid"),
                {"aid": agent_id},
            ).scalar_one()) if agent_id is not None else 0

            local_rows = db.execute(
                text("SELECT user_id, email, role FROM public.users WHERE lower(email) = :email OR user_id = :uid"),
                {"email": email, "uid": user_id},
            ).mappings().all()
            if len(local_rows) > 1:
                stop("Conflicting local account rows for email/UUID; nothing deleted.")
            if local_rows:
                local = local_rows[0]
                if (str(local["user_id"]) != user_id or
                        str(local["email"]).strip().lower() != email or
                        local["role"] != role):
                    stop("Local UUID, email, or role differs from Supabase; nothing deleted.")

            print("\nACCOUNT PREVIEW (no changes yet)")
            print(f"  Email:                {email}")
            print(f"  Role:                 {role}")
            print(f"  Supabase Auth UUID:   {user_id}")
            print(f"  Supabase public.users: FOUND")
            print(f"  Local public.users:    {'FOUND' if local_rows else 'MISSING'}")
            print(f"  Supabase agent ID:    {agent_id if agent_id is not None else 'none'}")
            print(f"  Owned properties:     {owned}")
            print(f"  Agent assignments:    {assigned}")

            if owned or assigned:
                stop("Account manages properties. Reassign them first; this script will not orphan or delete listings.")
            if not args.apply:
                print("\nDRY RUN ONLY. Add --apply to delete this exact account.")
                return

            expected = f"DELETE {email} {role} {user_id}"
            if input(f"\nType EXACTLY '{expected}' to confirm: ").strip() != expected:
                stop("Confirmation did not match. Nothing deleted.")

            # Stage the local removal in an uncommitted transaction. This
            # exposes local foreign-key blockers before touching Supabase.
            # Local commit happens only after cloud removal is confirmed.
            db.rollback()  # Finish read-only implicit transaction before staging DELETE.
            transaction = db.begin()
            cloud_deleted = False
            try:
                if local_rows:
                    deleted = db.execute(
                        text("DELETE FROM public.users WHERE user_id = :uid "
                             "AND lower(email) = :email AND role = :role RETURNING user_id"),
                        {"uid": user_id, "email": email, "role": role},
                    ).fetchall()
                    if len(deleted) != 1:
                        stop("Local user changed since preview; nothing deleted in Supabase.")

                # Auth identity first: a surviving Auth user could re-create
                # the local mirror on the next authenticated request.
                service.delete_auth_user(user_id)
                cloud_deleted = True

                # Keep management metadata clean; only unassigned agents reach
                # this stage. If a FK prevents deletion, report partial state.
                if agent_id is not None:
                    client.table("agent").delete().eq("agent_id", agent_id).eq("user_id", user_id).execute()

                # Some Supabase deployments cascade public.users when auth.users
                # is removed; others don't. Remove explicitly only if it remains.
                if service.get_identity_profile(user_id) is not None:
                    client.table("users").delete().eq("user_id", user_id).eq("role", role).execute()

                if service.get_identity_profile(user_id) is not None:
                    stop("Supabase public.users is still present after deletion attempt.")
                if agent_id is not None and (client.table("agent").select("agent_id").eq("user_id", user_id).execute().data or []):
                    stop("Supabase agent profile is still present after deletion attempt.")
                if service.get_auth_user(user_id) is not None:
                    stop("Supabase Auth identity is still present after deletion attempt.")

                transaction.commit()
                print("\nSUCCESS: Supabase Auth, Supabase public.users, and local mirror removed.")
                if agent_id is not None:
                    print("Supabase agent profile removal was requested too.")
            except Exception:
                transaction.rollback()
                if cloud_deleted:
                    print("\nPARTIAL DELETION: Supabase Auth was deleted but a later action failed.", file=sys.stderr)
                    print("Local PostgreSQL deletion was rolled back. Reconcile public.users / agent ",
                          "and the local mirror manually; do not assume the operation is atomic.", file=sys.stderr)
                raise
    finally:
        engine.dispose()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
