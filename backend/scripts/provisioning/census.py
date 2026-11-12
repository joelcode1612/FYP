"""Read-only census of property ownership, management and identities.

Every query runs inside a session forced to ``READ ONLY``; only SELECTs are
issued. Supabase is read through the backend's own service-role client.

Usage (from ``backend``)::

    .\\.venv\\Scripts\\python.exe -m scripts.provisioning.census --json out.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from sqlalchemy import create_engine, text

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

from sitewise.core.config import settings  # noqa: E402


def _rows(conn, sql: str, **params) -> list[dict]:
    return [dict(r) for r in conn.execute(text(sql), params).mappings().all()]


def _one(conn, sql: str, **params):
    return conn.execute(text(sql), params).scalar()


PROPERTY_COLUMNS = """
SELECT table_schema, table_name, column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE (table_schema = 'fyp' AND table_name = 'rental_properties')
   OR (table_schema = 'public' AND table_name IN ('users', 'agent_listing_assignment'))
ORDER BY table_schema, table_name, ordinal_position
"""

PROPERTY_CENSUS = """
SELECT
    count(*) AS total,
    count(*) FILTER (WHERE owner_user_id IS NOT NULL) AS with_owner_uuid,
    count(*) FILTER (WHERE owner_user_id IS NULL AND owner_id IS NOT NULL) AS legacy_only,
    count(*) FILTER (WHERE owner_user_id IS NULL AND owner_id IS NULL) AS no_owner,
    count(*) FILTER (WHERE is_published IS TRUE) AS published,
    count(*) FILTER (WHERE verification_status = 'approved') AS approved,
    count(*) FILTER (WHERE verification_status = 'pending') AS pending,
    count(*) FILTER (WHERE verification_status = 'draft') AS draft
FROM fyp.rental_properties
"""

#: ``fyp.rental_properties`` has no provenance column. Origin is derived from the
#: only stable signal the schema carries: the external ``listing_id`` reference.
#: Numeric -> legacy demo seed; MD-/EP- -> research catalogue import; NULL -> owner draft.
PROVENANCE = """
SELECT CASE
         WHEN listing_id IS NULL THEN 'owner_draft'
         WHEN listing_id ~ '^[0-9]+$' THEN 'demo_seed'
         WHEN listing_id ~ '^(MD|EP)-' THEN 'research_import'
         ELSE 'other'
       END AS provenance,
       count(*) AS rows,
       count(*) FILTER (WHERE owner_user_id IS NOT NULL) AS owner_uuid,
       count(*) FILTER (WHERE owner_user_id IS NULL AND owner_id IS NOT NULL) AS legacy_only,
       count(*) FILTER (WHERE owner_user_id IS NULL AND owner_id IS NULL) AS no_owner,
       count(*) FILTER (WHERE is_published IS TRUE) AS published
FROM fyp.rental_properties
GROUP BY 1 ORDER BY 2 DESC
"""

ASSIGNMENTS = """
SELECT a.agent_id, count(*) AS listings,
       min(a.created_at) AS first_assigned, max(a.created_at) AS last_assigned
FROM public.agent_listing_assignment a
GROUP BY a.agent_id ORDER BY a.agent_id
"""

ORPHAN_ASSIGNMENTS = """
SELECT a.listing_id, a.agent_id
FROM public.agent_listing_assignment a
LEFT JOIN fyp.rental_properties p ON p.id = a.listing_id
WHERE p.id IS NULL
"""

LOCAL_USERS = """
SELECT role, account_status, count(*) AS rows
FROM public.users GROUP BY 1, 2 ORDER BY 1, 2
"""

LOCAL_ENTREPRENEURS = """
SELECT user_id::text AS user_id, full_name, email, account_status, email_verified,
       created_at
FROM public.users WHERE role = 'entrepreneur' ORDER BY created_at
"""

LEGACY_OWNERS = """
SELECT owner_id, count(*) AS listings,
       (SELECT count(DISTINCT owner_user_id) FROM fyp.rental_properties
        WHERE owner_id = p.owner_id AND owner_user_id IS NOT NULL) AS with_uuid
FROM fyp.rental_properties p
WHERE owner_user_id IS NULL AND owner_id IS NOT NULL
GROUP BY owner_id ORDER BY 2 DESC
"""


def census_local() -> dict:
    engine = create_engine(settings.database_url)
    out: dict = {"database": settings.database_url.rsplit("/", 1)[-1]}
    with engine.connect() as conn:
        conn.execute(text("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY"))
        conn.execute(text("BEGIN"))
        out["schema"] = _rows(conn, PROPERTY_COLUMNS)
        out["properties"] = _rows(conn, PROPERTY_CENSUS)[0]
        out["provenance"] = _rows(conn, PROVENANCE)
        out["assignments"] = _rows(conn, ASSIGNMENTS)
        out["orphan_assignments"] = _rows(conn, ORPHAN_ASSIGNMENTS)
        out["local_users"] = _rows(conn, LOCAL_USERS)
        out["local_entrepreneurs"] = _rows(conn, LOCAL_ENTREPRENEURS)
        out["legacy_owners"] = _rows(conn, LEGACY_OWNERS)
        out["assignment_table_exists"] = (
            _one(conn, "SELECT to_regclass('public.agent_listing_assignment')") is not None
        )
        out["users_table_exists"] = (
            _one(conn, "SELECT to_regclass('public.users')") is not None
        )
        conn.rollback()
    return out


def census_supabase() -> dict:
    """Read-only Supabase inspection through the service-role client."""
    from sitewise.core.supabase_admin import SupabaseAdminService

    svc = SupabaseAdminService()
    client = svc.client
    out: dict = {}

    users = client.table("users").select(
        "user_id,full_name,email,role,account_status,email_verified,created_at"
    ).execute().data or []
    out["public_users"] = users
    out["public_users_by_role"] = {}
    for row in users:
        key = f"{row.get('role')}/{row.get('account_status')}"
        out["public_users_by_role"][key] = out["public_users_by_role"].get(key, 0) + 1

    agents = client.table("agent").select("*").execute().data or []
    out["agents"] = agents

    companies = client.table("company").select("*").execute().data or []
    out["companies"] = companies

    try:
        # GoTrue admin listing: ``/auth/v1/admin/users``. The SDK call is the
        # same one ``find_auth_user_by_email`` already relies on.
        auth_users = client.auth.admin.list_users(page=1, per_page=200) or []
        out["auth_user_count"] = len(auth_users)
        out["auth_users"] = [
            {
                "id": str(getattr(u, "id", "") or ""),
                "email": getattr(u, "email", None),
                "email_confirmed_at": str(getattr(u, "email_confirmed_at", None) or ""),
                "confirmed_at": str(getattr(u, "confirmed_at", None) or ""),
                "banned_until": str(getattr(u, "banned_until", None) or ""),
                "last_sign_in_at": str(getattr(u, "last_sign_in_at", None) or ""),
            }
            for u in auth_users
        ]
    except Exception as exc:  # noqa: BLE001 - report, never invent
        out["auth_user_error"] = f"{type(exc).__name__}: {exc}"
        out["auth_user_count"] = None
        out["auth_users"] = []
    return out


def cross_check(report: dict) -> dict:
    """Compare the three identity universes without assuming they agree."""
    local = report.get("local", {})
    supa = report.get("supabase", {})
    if "error" in supa or not supa:
        return {"error": "supabase unavailable"}

    auth_ids = {u["id"] for u in supa.get("auth_users", []) if u.get("id")}
    supa_ids = {str(u.get("user_id")) for u in supa.get("public_users", [])}
    local_ids = {
        r["user_id"] for r in local.get("local_entrepreneurs", [])
    }
    # Local staff rows are not in the entrepreneur export; read the full mirror.
    local_all = set()
    try:
        engine = create_engine(settings.database_url)
        with engine.connect() as conn:
            conn.execute(text("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY"))
            local_all = {str(r[0]) for r in conn.execute(text("SELECT user_id FROM public.users"))}
            conn.rollback()
    except Exception:  # noqa: BLE001
        local_all = local_ids

    agent_uuid_to_id = {
        str(a.get("user_id")): a.get("agent_id") for a in supa.get("agents", [])
    }
    local_roles = {}
    try:
        engine = create_engine(settings.database_url)
        with engine.connect() as conn:
            conn.execute(text("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY"))
            for r in conn.execute(text("SELECT user_id, role, account_status FROM public.users")):
                local_roles[str(r[0])] = {"role": r[1], "status": r[2]}
            conn.rollback()
    except Exception:  # noqa: BLE001
        pass

    return {
        "auth_users": len(auth_ids),
        "supabase_public_users": len(supa_ids),
        "local_public_users": len(local_all),
        "auth_without_public_users": sorted(auth_ids - supa_ids),
        "public_users_without_auth": sorted(supa_ids - auth_ids),
        "supabase_without_local_mirror": sorted(supa_ids - local_all),
        "local_without_supabase": sorted(local_all - supa_ids),
        "agents": {
            str(agent_id): {
                "user_id": uuid,
                "in_auth": uuid in auth_ids,
                "in_supabase_public_users": uuid in supa_ids,
                "in_local_mirror": uuid in local_all,
                "local_role": local_roles.get(uuid, {}).get("role"),
                "local_status": local_roles.get(uuid, {}).get("status"),
            }
            for uuid, agent_id in agent_uuid_to_id.items()
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", type=Path, default=None)
    parser.add_argument("--skip-supabase", action="store_true")
    args = parser.parse_args()

    report: dict = {"local": census_local()}
    if not args.skip_supabase:
        try:
            report["supabase"] = census_supabase()
        except Exception as exc:  # noqa: BLE001
            report["supabase"] = {"error": f"{type(exc).__name__}: {exc}"}
    if not args.skip_supabase and "error" not in report["supabase"]:
        report["sync"] = cross_check(report)

    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(report, indent=2, default=str), encoding="utf-8")

    local = report["local"]
    print("=" * 68)
    print(f"LOCAL DATABASE: {local['database']}")
    print("=" * 68)
    props = local["properties"]
    print(f"  total properties        : {props['total']}")
    print(f"  owner_user_id set       : {props['with_owner_uuid']}")
    print(f"  legacy owner_id only    : {props['legacy_only']}")
    print(f"  no owner at all         : {props['no_owner']}")
    print(f"  published / approved    : {props['published']} / {props['approved']}")
    print(f"  pending / draft         : {props['pending']} / {props['draft']}")
    print(f"  assignments             : {local['assignments'] or 'none'}")
    print(f"  orphan assignments      : {local['orphan_assignments'] or 'none'}")
    print("  provenance:")
    for row in local["provenance"]:
        print(
            f"    {row['provenance']:<18} rows={row['rows']:<5} uuid={row['owner_uuid']:<4} "
            f"legacy={row['legacy_only']:<4} none={row['no_owner']:<4} published={row['published']}"
        )
    print("  local users by role/status:")
    for row in local["local_users"]:
        print(f"    {row['role']:<15} {row['account_status']:<10} {row['rows']}")
    print(f"  local entrepreneurs     : {len(local['local_entrepreneurs'])}")
    print(f"  legacy owner groups     : {local['legacy_owners']}")

    supa = report.get("supabase", {})
    print()
    print("=" * 68)
    print("SUPABASE")
    print("=" * 68)
    if "error" in supa:
        print(f"  ERROR: {supa['error']}")
    else:
        print(f"  auth.users (page 1)     : {supa.get('auth_user_count')}")
        if supa.get("auth_user_error"):
            print(f"  auth error              : {supa['auth_user_error']}")
        print(f"  public.users            : {len(supa.get('public_users', []))}")
        for key, value in sorted(supa.get("public_users_by_role", {}).items()):
            print(f"    {key:<24} {value}")
        print(f"  public.agent            : {len(supa.get('agents', []))}")
        for agent in supa.get("agents", []):
            print(
                f"    agent_id={agent.get('agent_id')} user_id={agent.get('user_id')} "
                f"name={agent.get('agent_name')!r} company={agent.get('company_id')}"
            )
        print(f"  public.company          : {len(supa.get('companies', []))}")

    sync = report.get("sync")
    if sync and "error" not in sync:
        print()
        print("=" * 68)
        print("IDENTITY SYNC")
        print("=" * 68)
        print(f"  auth.users              : {sync['auth_users']}")
        print(f"  supabase public.users   : {sync['supabase_public_users']}")
        print(f"  local public.users      : {sync['local_public_users']}")
        print(f"  auth w/o public.users   : {len(sync['auth_without_public_users'])}")
        print(f"  public.users w/o auth   : {len(sync['public_users_without_auth'])}")
        print(f"  supabase w/o local row  : {len(sync['supabase_without_local_mirror'])}")
        print(f"  local w/o supabase row  : {len(sync['local_without_supabase'])}")
        for agent_id, info in sync["agents"].items():
            print(
                f"  agent {agent_id}: auth={info['in_auth']} "
                f"supabase_users={info['in_supabase_public_users']} "
                f"local={info['in_local_mirror']} role={info['local_role']} "
                f"status={info['local_status']}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
