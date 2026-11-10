"""READ-ONLY probe: report everything referencing two SiteWise accounts.

Prints auth identities, mirror profiles, audit rows, invitations, agent
profiles, listings and local-Postgres rows. Performs NO writes.
Secrets are never printed.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

EMAILS = ["joeltanhoujun@gmail.com", "joelstrengthpersonal@gmail.com"]


def load_local_env() -> None:
    root = Path(__file__).resolve().parents[2]  # .workbuddy-ai/tmp -> repo root
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


def safe(label: str, fn):
    try:
        fn()
    except Exception as exc:  # noqa: BLE001 - probe must never abort
        print(f"  [{label}] ERROR: {exc}")


def rows_of(result) -> list[dict]:
    return getattr(result, "data", None) or []


def main() -> int:
    load_local_env()
    url = os.getenv("SUPABASE_URL", "").strip()
    secret = os.getenv("SUPABASE_SECRET_KEY", "").strip()
    if not url or not secret:
        print("ERROR: SUPABASE_URL / SUPABASE_SECRET_KEY missing.")
        return 1

    from supabase import create_client

    # Match the backend's own construction (no ClientOptions — this venv's
    # supabase/gotrue combination rejects a hand-built ClientOptions).
    client = create_client(url, secret)

    found: dict[str, dict] = {}

    # --- auth.users ---
    auth_users = []
    for page in range(1, 6):
        resp = client.auth.admin.list_users(page=page, per_page=200)
        users = getattr(resp, "users", None) or (resp if isinstance(resp, list) else [])
        auth_users.extend(users)
        if len(users) < 200:
            break
    print(f"auth.users total fetched: {len(auth_users)}")
    for email in EMAILS:
        match = next(
            (u for u in auth_users if ((getattr(u, "email", None) or "").casefold() == email)),
            None,
        )
        print(f"\n=== AUTH: {email} ===")
        if match is None:
            print("  not found in Supabase Auth")
            continue
        uid = str(getattr(match, "id", ""))
        found[email] = {"uid": uid}
        print(f"  id={uid}")
        print(f"  email_confirmed_at={getattr(match, 'email_confirmed_at', None)}")
        print(f"  created_at={getattr(match, 'created_at', None)}")
        print(f"  last_sign_in_at={getattr(match, 'last_sign_in_at', None)}")
        meta = getattr(match, "user_metadata", None) or {}
        print(f"  user_metadata.full_name={meta.get('full_name')}")
        app_meta = getattr(match, "app_metadata", None) or {}
        print(f"  app_metadata={app_meta}")
        providers = getattr(match, "providers", None)
        print(f"  providers={providers}")

        uid_esc = uid.replace("'", "''")

        # --- public.users mirror ---
        def q_users():
            data = rows_of(client.table("users").select("*").eq("user_id", uid).limit(5).execute())
            print("  [public.users]")
            for r in data:
                print("   ", {k: r.get(k) for k in ("user_id", "email", "role", "account_status", "email_verified", "full_name")})

        safe("public.users", q_users)

        # --- role_change_audit (both directions) ---
        def q_audit():
            data = rows_of(
                client.table("role_change_audit")
                .select("user_id_affected,affected_email_snapshot,changed_by_user_id,entity_type,action_status,old_role,new_role,old_account_status,new_account_status,changed_at")
                .or_(f"user_id_affected.eq.{uid_esc},changed_by_user_id.eq.{uid_esc}")
                .order("changed_at", desc=True)
                .limit(30)
                .execute()
            )
            print(f"  [role_change_audit] {len(data)} row(s) involving this user (as subject OR actor)")
            for r in data[:10]:
                print("   ", r)

        safe("role_change_audit", q_audit)

        # --- staff_invitations (all directions) ---
        def q_invites():
            data = rows_of(
                client.table("staff_invitations")
                .select("*")
                .or_(f"invited_user_id.eq.{uid_esc},invited_by_user_id.eq.{uid_esc}")
                .limit(30)
                .execute()
            )
            print(f"  [staff_invitations by user_id] {len(data)} row(s)")
            for r in data[:10]:
                print("   ", {k: r.get(k) for k in ("id", "email", "invited_user_id", "invited_by_user_id", "role", "status", "created_at") if k in r})

        safe("staff_invitations", q_invites)

        # --- agent profile ---
        def q_agent():
            data = rows_of(client.table("agent").select("*").eq("user_id", uid).limit(5).execute())
            print(f"  [agent] {len(data)} row(s)")
            for r in data:
                print("   ", {k: r.get(k) for k in ("id", "agent_name", "user_id", "company_id", "listing_count") if k in r})

        safe("agent", q_agent)

        # --- listing_verification (as verifier) ---
        def q_lverify():
            data = rows_of(
                client.table("listing_verification").select("*").eq("verified_by_user_id", uid).limit(10).execute()
            )
            print(f"  [listing_verification verified_by_user_id] {len(data)} row(s)")

        safe("listing_verification", q_lverify)

    # --- staff_invitations by email (even without auth user) ---
    def q_invites_email():
        ors = ",".join(f"email.eq.{e.replace("'", chr(39) * 2)}" for e in EMAILS)
        data = rows_of(client.table("staff_invitations").select("*").or_(ors).limit(30).execute())
        print(f"\n[staff_invitations by email] {len(data)} row(s)")
        for r in data[:10]:
            print("  ", {k: r.get(k) for k in ("id", "email", "invited_user_id", "invited_by_user_id", "role", "status", "created_at") if k in r})

    safe("staff_invitations(email)", q_invites_email)

    # --- fyp.rental_properties.owner_user_id (schema may not be exposed) ---
    def q_fyp():
        for email, info in found.items():
            uid = info["uid"]
            data = rows_of(
                client.schema("fyp").table("rental_properties").select("id,email,owner_user_id,is_published").eq("owner_user_id", uid).limit(10).execute()
            )
            print(f"\n[fyp.rental_properties owner] {email}: {len(data)} row(s)")
            for r in data[:10]:
                print("  ", r)

    safe("fyp.rental_properties", q_fyp)

    # --- local Postgres mirror ---
    def q_local():
        db = os.getenv("DATABASE_URL", "")
        if not db:
            print("\n[local Postgres] DATABASE_URL missing")
            return
        import psycopg2

        conn = psycopg2.connect(db.replace("postgresql+psycopg2://", "postgresql://"))
        cur = conn.cursor()
        print("\n[local Postgres mirror]")
        for email in EMAILS:
            cur.execute(
                "SELECT user_id, email, role, account_status, email_verified FROM users WHERE lower(email) = %s",
                (email.casefold(),),
            )
            found_rows = cur.fetchall()
            print(f"  users ({email}): {found_rows if found_rows else 'none'}")
            for (uid, *_rest) in found_rows:
                for table, col in (
                    ("user_tokens", "user_id"),
                    ("recommendation_result", "user_id"),
                    ("property", "user_id"),
                ):
                    cur.execute(f"SELECT count(*) FROM {table} WHERE {col} = %s", (uid,))
                    print(f"    {table}: {cur.fetchone()[0]} row(s)")
        conn.close()

    safe("local Postgres", q_local)

    print("\nPROBE COMPLETE (no writes performed).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
