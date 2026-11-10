"""Delete two SiteWise agent test accounts so the invite flow can be retested.

Scope (authorised by the repository owner, 2026-11-10):
  joeltanhoujun@gmail.com        role=agent, suspended
  joelstrengthpersonal@gmail.com role=agent, active

Order per account:
  1. Supabase: verify auth identity matches email AND public.users role==agent.
  2. Supabase: delete role_change_audit rows referencing the user (the FK has
     no ON DELETE action and would otherwise block auth deletion).
  3. Supabase: auth.admin.delete_user (GoTrue cascades public.users when the
     FK is ON DELETE CASCADE; a matching residual row is removed explicitly).
  4. Local Postgres: verify zero dependent rows across EVERY table that
     references users.user_id, then delete the mirror row.
Refuses to touch admin / property_owner accounts or mismatched emails.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

TARGETS = [
    "joeltanhoujun@gmail.com",
    "joelstrengthpersonal@gmail.com",
]

# Every local table/column that references users.user_id (from db/models).
LOCAL_FK_COLUMNS = [
    ("ai_explanation", "user_id"),
    ("assessment", "user_id"),
    ("entrepreneur_preferences", "user_id"),
    ("favourite_property", "user_id"),
    ("property_verification", "submitted_by"),
    ("property_verification", "reviewed_by"),
    ("property_verification", "uploaded_by"),
    ("property_verification", "admin_user_id"),
    ("recommendation_result", "user_id"),
    ("property", "user_id"),
    ("user_tokens", "user_id"),
]

ALLOWED_ROLES = {"agent"}


def load_local_env() -> None:
    root = Path(__file__).resolve().parents[2]
    for env_path in (root / ".env", root / "backend" / ".env"):
        if not env_path.is_file():
            continue
        for raw_line in env_path.read_text(encoding="utf-8-sig").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = (part.strip() for part in line.split("=", 1))
            if key.isidentifier():
                os.environ.setdefault(key, value)


def casefold_email(value) -> str:
    return str(value or "").casefold()


def get_user_field(user, key):
    if isinstance(user, dict):
        return user.get(key)
    return getattr(user, key, None)


def main() -> int:
    load_local_env()
    url = os.getenv("SUPABASE_URL", "").strip()
    secret = os.getenv("SUPABASE_SECRET_KEY", "").strip()
    if not url or not secret:
        print("ERROR: SUPABASE_URL / SUPABASE_SECRET_KEY missing.")
        return 1

    from supabase import create_client

    client = create_client(url, secret)

    # ---- Supabase phase ----
    for email in TARGETS:
        print(f"\n=== SUPABASE: {email} ===")
        resp = client.auth.admin.list_users(page=1, per_page=200)
        users = getattr(resp, "users", None) or (resp if isinstance(resp, list) else [])
        auth_user = next(
            (u for u in users if casefold_email(get_user_field(u, "email")) == email), None
        )
        if auth_user is None:
            print("  auth identity: not found (nothing to do)")
        else:
            uid = str(get_user_field(auth_user, "id"))
            print(f"  auth identity: {uid}")

            profile_rows = (
                client.table("users")
                .select("user_id,email,role,account_status")
                .eq("user_id", uid)
                .limit(1)
                .execute()
                .data
                or []
            )
            if profile_rows:
                profile = profile_rows[0]
                role = str(profile.get("role") or "").casefold()
                profile_email = casefold_email(profile.get("email"))
                if profile_email != email:
                    print(f"  REFUSED: public.users email mismatch ({profile_email})")
                    continue
                if role not in ALLOWED_ROLES:
                    print(f"  REFUSED: role '{role}' is not deletable by this script")
                    continue

            # 1. Audit rows referencing this user block the FK.
            audit_rows = (
                client.table("role_change_audit")
                .select("changed_at,entity_type,action_status")
                .eq("user_id_affected", uid)
                .limit(100)
                .execute()
                .data
                or []
            )
            if audit_rows:
                print(f"  deleting {len(audit_rows)} role_change_audit row(s) referencing this user")
                client.table("role_change_audit").delete().eq("user_id_affected", uid).execute()

            # 2. Auth identity (GoTrue).
            client.auth.admin.delete_user(uid)
            print("  auth.admin.delete_user completed")

            # 3. Residual mirror profile, if the FK was not cascading.
            residual = (
                client.table("users")
                .select("user_id,email")
                .eq("user_id", uid)
                .limit(1)
                .execute()
                .data
                or []
            )
            if residual and casefold_email(residual[0].get("email")) == email:
                client.table("users").delete().eq("user_id", uid).eq(
                    "email", email
                ).execute()
                print("  residual public.users row deleted")
            elif residual:
                print("  WARNING: residual public.users row has a different email; left in place")
            else:
                print("  public.users row removed (cascade) or already absent")

        # 4. Verification.
        after = client.auth.admin.list_users(page=1, per_page=200)
        after_users = getattr(after, "users", None) or (after if isinstance(after, list) else [])
        still = any(casefold_email(get_user_field(u, "email")) == email for u in after_users)
        mirror = (
            client.table("users")
            .select("user_id,email")
            .eq("email", email)
            .limit(1)
            .execute()
            .data
            or []
        )
        print(f"  VERIFY auth gone: {not still}; public.users gone: {not mirror}")
        if still or mirror:
            print("  ERROR: deletion incomplete for this account")
            return 1

    # ---- Local Postgres mirror phase ----
    print("\n=== LOCAL POSTGRES MIRROR ===")
    import psycopg2

    db = os.getenv("DATABASE_URL", "").replace("postgresql+psycopg2://", "postgresql://")
    conn = psycopg2.connect(db)
    conn.autocommit = False
    cur = conn.cursor()
    ok = True
    for email in TARGETS:
        cur.execute(
            "SELECT user_id, role, account_status FROM users WHERE lower(email) = %s",
            (email.casefold(),),
        )
        found = cur.fetchall()
        if not found:
            print(f"  {email}: no mirror row (already clean)")
            continue
        for uid, role, status in found:
            print(f"  {email}: mirror {uid} role={role} status={status}")
            if str(role).casefold() not in ALLOWED_ROLES:
                print("    REFUSED: role not deletable by this script")
                ok = False
                continue
            blocking = []
            for table, col in LOCAL_FK_COLUMNS:
                try:
                    cur.execute(f"SELECT count(*) FROM {table} WHERE {col} = %s", (uid,))
                    count = cur.fetchone()[0]
                except (psycopg2.errors.UndefinedTable, psycopg2.errors.UndefinedColumn):
                    # Model exists in code but this table/column was never
                    # migrated in this database — no rows can reference the user.
                    conn.rollback()
                    continue
                if count:
                    blocking.append(f"{table}.{col}={count}")
            if blocking:
                print(f"    SKIPPED: dependent rows exist -> {', '.join(blocking)}")
                ok = False
                continue
            cur.execute("DELETE FROM users WHERE user_id = %s AND lower(email) = %s", (uid, email.casefold()))
            print(f"    deleted mirror row (rowcount={cur.rowcount})")
    conn.commit()
    conn.close()
    print("  local mirror phase complete")

    print("\nDELETE COMPLETE." if ok else "\nCOMPLETED WITH SKIPPED ITEMS — review above.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
