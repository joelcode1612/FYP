"""Reconcile application data between local PostgreSQL and Supabase.

Phase 5 of the database-standardization effort. Modes:

``--mode dry-run`` (default)
    Read-only. Reports the exact actions that apply-mode would take and the
    full reconciliation deltas (users, drafts, photos, property values).
``--mode apply``
    Executes the reconciliation:
      * syncs the four validated local drafts (9234, 9235, 9236, 10120) into
        Supabase ``fyp.rental_properties`` exactly as stored — draft status,
        unpublished, owners preserved (never invented, never published);
      * leaves user-identity divergence as a REPORT ONLY (Supabase rows must
        originate from ``auth.users``; creating profile rows without an auth
        identity would fabricate accounts).

Requires database_standardization/migrations/03_supabase_schema_migration.sql
to have been applied to Supabase, with the ``fyp`` schema exposed to PostgREST
for the service key (see MIGRATION_INSTRUCTIONS.md). Without it, apply mode
reports BLOCKED for the affected steps instead of failing silently.

Usage (PowerShell, from ``backend/``)::

    .venv\\Scripts\\python.exe database_standardization\\scripts\\reconcile_application_data.py
    .venv\\Scripts\\python.exe database_standardization\\scripts\\reconcile_application_data.py --mode apply
"""

from __future__ import annotations

import argparse
import json
import sys
import uuid as _uuid
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _supabase_rest import (
    CLASS_OTHER,
    CLASS_SCHEMA_NOT_EXPOSED,
    CLASS_TABLE_MISSING,
    PROPERTY_COLUMN_MAP,
    SupabaseRest,  # noqa: E402
)


def _json_safe(value):
    """PostgreSQL numeric columns arrive as Decimal and UUID columns as
    uuid.UUID; httpx (allow_nan=False) refuses to serialize either, so
    coerce to float/str for the REST payload."""
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, _uuid.UUID):
        return str(value)
    return value

DRAFT_IDS = (10120, 9236, 9235, 9234)


def _ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def local_engine():
    from sitewise.db.session import engine

    return engine


def reconcile_users(rest: SupabaseRest | None, report: dict) -> None:
    """UUID-level user reconciliation (report-only by design)."""
    from sqlalchemy import text

    with local_engine().connect() as c:
        local_rows = c.execute(
            text("SELECT user_id, email, role, account_status FROM public.users")
        ).all()
    local = {str(r[0]): {"email": r[1], "role": r[2], "status": r[3]} for r in local_rows}

    supa: dict[str, dict] = {}
    if rest is not None:
        rows, _ = rest.get("users", select="user_id,email,role,account_status", limit=1000)
        supa = {r["user_id"]: r for r in rows}
        if len(rows) >= 1000:
            report["users"]["note"] = "Supabase page limit reached; paginate for a complete diff."

    only_local = sorted(set(local) - set(supa))
    only_supa = sorted(set(supa) - set(local))
    report["users"] = {
        "local_count": len(local),
        "supabase_count": len(supa),
        "roles_local": _role_counts(local),
        "roles_supabase": _role_counts(supa),
        "only_local_uuids": only_local,
        "only_supabase_uuids": only_supa,
        "policy": (
            "Report-only: profile rows must originate from Supabase auth.users. "
            "Local-only profiles are dev/test artifacts unless a matching auth "
            "user exists; Supabase-only profiles are legitimate remote "
            "registrations to copy into local dev if desired."
        ),
    }


def _role_counts(users: dict) -> dict:
    counts: dict[str, int] = {}
    for u in users.values():
        role = u.get("role") or "?"
        counts[role] = counts.get(role, 0) + 1
    return counts


CANON_COLS = ("name", "property_type", "address", "rental_price",
              "built_up_sqft", "bathrooms", "verification_status",
              "is_published", "latitude", "longitude")


def _fetch_remote_properties(rest: SupabaseRest | None, report: dict) -> dict[int, dict]:
    """Fetch the remote property rows, whatever the migration state is.

    Post-migration (fyp schema exposed): canonical names, direct fetch.
    Pre-migration (legacy public.property): Supabase names mapped through
    PROPERTY_COLUMN_MAP, so parity reporting works before 03 is applied.
    """
    remote: dict[int, dict] = {}
    if rest is None:
        return remote
    try:
        rows, _total = rest.get(
            "rental_properties", select="id," + ", ".join(CANON_COLS), limit=2000)
        for r in rows:
            try:
                remote[int(r["id"])] = {c: r.get(c) for c in CANON_COLS}
            except (TypeError, ValueError):
                continue
        return remote
    except RuntimeError:
        pass  # fyp schema not exposed yet -> fall back to legacy names
    try:
        supa_cols = ", ".join(PROPERTY_COLUMN_MAP.keys())
        rows, _total = rest.get("property", select=supa_cols, limit=2000)
        for r in rows:
            try:
                # Pre-migration rows key the PK as property_id; post-migration
                # rows (fyp schema) key it as id.
                pid = r.get("property_id", r.get("id"))
                mapped = {cn: r.get(sn) for sn, cn in PROPERTY_COLUMN_MAP.items()}
                remote[int(pid)] = {c: mapped.get(c) for c in CANON_COLS}
            except (TypeError, ValueError):
                continue
    except RuntimeError as exc:
        report["property_values"]["blocked"] = str(exc)[:200]
    return remote


def reconcile_property_values(rest: SupabaseRest | None, report: dict) -> None:
    """Column-level value parity for the 916 core property records."""
    from sqlalchemy import text

    with local_engine().connect() as c:
        local_rows = c.execute(
            text(
                "SELECT id, " + ", ".join(CANON_COLS) +
                " FROM fyp.rental_properties WHERE is_published = true"
            )
        ).all()
    local = {r[0]: dict(zip(CANON_COLS, r[1:])) for r in local_rows}

    report["property_values"] = {}
    mismatches = []
    supa = _fetch_remote_properties(rest, report)

    for pid, lrow in local.items():
        srow = supa.get(pid)
        if srow is None:
            mismatches.append({"id": pid, "issue": "missing_on_supabase"})
            continue
        for col in ("name", "property_type", "verification_status"):
            lval, sval = lrow[col], srow.get(col)
            if (lval or "") != (sval or ""):
                mismatches.append({"id": pid, "column": col, "local": lval, "supabase": sval})
        for col in ("rental_price", "latitude", "longitude"):
            lval, sval = lrow[col], srow.get(col)
            if lval is not None and sval is not None and abs(float(lval) - float(sval)) > 1e-9:
                mismatches.append({"id": pid, "column": col, "local": lval, "supabase": sval})

    report["property_values"] = {
        "local_published": len(local),
        "supabase_seen": len(supa),
        "mismatch_count": len(mismatches),
        "mismatches_sample": mismatches[:50],
    }


def reconcile_photos(rest: SupabaseRest | None, report: dict) -> None:
    from sqlalchemy import text

    with local_engine().connect() as c:
        local_ids = {int(r[0]) for r in c.execute(text("SELECT id FROM fyp.property_photos"))}
    if rest is None:
        report["photos"] = {"local_count": len(local_ids), "supabase": "unavailable"}
        return
    # Live Supabase contract (post-migration): fyp.property_photos.id is a
    # UUID; the join key back to the local numeric fyp.property_photos.id is
    # local_source_photo_id (provenance written by the original import).
    table, key_col, cursor_col = "property_photos", "local_source_photo_id", "id"
    try:
        rows, total = rest.get(table, select=f"id,{key_col}", limit=1000, order=cursor_col)
    except RuntimeError:
        table, key_col, cursor_col = "property_photo", "photo_id", "photo_id"  # legacy
        rows, total = rest.get(table, select=key_col, limit=1000, order=cursor_col)

    mapped: set[int] = set()
    unmapped_rows: list[str] = []
    duplicate_keys: set[int] = set()

    def absorb(page: list[dict]) -> None:
        for r in page:
            key = r.get(key_col)
            if key is None:
                unmapped_rows.append(str(r.get("id") or r.get(key_col)))
                continue
            key = int(key)
            if key in mapped:
                duplicate_keys.add(key)
            mapped.add(key)

    absorb(rows)
    seen = len(rows)
    cursor = rows[-1][cursor_col] if rows else None
    while (total is None or seen < total) and cursor is not None:
        page, page_total = rest.get(table, select=f"id,{key_col}", limit=1000,
                                    order=cursor_col,
                                    filters={cursor_col: f"gt.{cursor}"})
        if not page:
            break
        absorb(page)
        seen += len(page)
        cursor = page[-1][cursor_col]
        if page_total is not None:
            total = page_total

    missing_on_supabase = sorted(local_ids - mapped)[:50]
    missing_on_local = sorted(mapped - local_ids)[:50]
    report["photos"] = {
        "local_count": len(local_ids),
        "supabase_count": total if total is not None else seen,
        "join_key": key_col,
        "matched_ids": len(local_ids & mapped),
        "missing_on_supabase": missing_on_supabase,
        "missing_on_local": missing_on_local,
        "unmapped_supabase_rows": len(unmapped_rows),
        "duplicate_source_keys": sorted(duplicate_keys)[:50],
    }


def sync_drafts(rest: SupabaseRest | None, mode: str, report: dict) -> None:
    """Sync the four local drafts to Supabase exactly as stored."""
    from sqlalchemy import text

    with local_engine().connect() as c:
        rows = c.execute(
            text(
                "SELECT id, owner_id, listing_id, name, property_type, "
                "description, address, city, state, latitude, longitude, "
                "rental_price, size_sqft, bathrooms, floor_level, tenure, "
                "furnishing, availability, verification_status, rejection_reason, "
                "is_published, created_at, updated_at, owner_user_id "
                "FROM fyp.rental_properties WHERE id = ANY(:ids)"
            ),
            {"ids": list(DRAFT_IDS)},
        ).mappings().all()
    drafts = [dict(r) for r in rows]

    payload = []
    for d in drafts:
        payload.append({
            "id": d["id"],
            "name": d["name"],
            "property_type": d["property_type"],
            "address": d["address"],
            "city": d["city"],
            "state": d["state"],
            "latitude": _json_safe(d["latitude"]),
            "longitude": _json_safe(d["longitude"]),
            "rental_price": _json_safe(d["rental_price"]),
            "built_up_sqft": _json_safe(d["size_sqft"]),
            "bathrooms": _json_safe(d["bathrooms"]),
            "floor_level": _json_safe(d["floor_level"]),
            "tenure": d["tenure"],
            "furnishing": d["furnishing"],
            "availability": d["availability"],
            "verification_status": "draft",
            "is_published": False,
            "owner_user_id": _json_safe(d["owner_user_id"]),
            "created_at": d["created_at"].isoformat() if d["created_at"] else None,
            "updated_at": d["updated_at"].isoformat() if d["updated_at"] else None,
        })

    report["drafts"] = {
        "ids": DRAFT_IDS,
        "found_local": len(drafts),
        "payload_preview": [
            {"id": p["id"], "name": p["name"], "owner_user_id": p["owner_user_id"],
             "verification_status": p["verification_status"], "is_published": p["is_published"]}
            for p in payload
        ],
        "policy": "verification_status='draft', is_published=false, owners preserved (never invented).",
    }
    if mode != "apply":
        return
    if rest is None:
        report["drafts"]["result"] = "BLOCKED: Supabase REST not configured."
        return
    try:
        rest.insert("rental_properties", payload, upsert_on="id")
        report["drafts"]["result"] = "applied"
    except RuntimeError as exc:
        report["drafts"]["result"] = f"BLOCKED: {exc}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["dry-run", "apply"], default="dry-run")
    parser.add_argument("--output", default=None, help="Write JSON report to this path.")
    args = parser.parse_args(argv)

    report: dict = {"generated_at": _ts(), "mode": args.mode}

    rest = None
    try:
        rest = SupabaseRest(profile="public")
    except RuntimeError as exc:
        report["rest"] = f"unavailable: {exc}"

    # After migration 03, the canonical tables live in the fyp schema.
    rest_fyp = None
    if rest is not None:
        probe = SupabaseRest(profile="fyp")
        try:
            _, total = probe.get("rental_properties", select="id", limit=1, count=True)
            rest_fyp = probe
            report["rest_fyp"] = f"reachable, rental_properties={total}"
        except RuntimeError as exc:
            classification = getattr(exc, "classification", CLASS_OTHER)
            hint = {
                CLASS_SCHEMA_NOT_EXPOSED: (
                    "migration 03 appears applied but the fyp schema is NOT "
                    "exposed to PostgREST (PGRST106); expose it via Supabase "
                    "Dashboard -> Settings -> API -> Exposed schemas"
                ),
                CLASS_TABLE_MISSING: (
                    "apply migrations/03_supabase_schema_migration.sql "
                    "(MIGRATION_INSTRUCTIONS.md)"
                ),
            }.get(classification, "apply migration 03 and expose fyp (MIGRATION_INSTRUCTIONS.md)")
            report["rest_fyp"] = (
                f"unreachable [{classification}] ({exc}); {hint}"
            )

    reconcile_users(rest, report)
    reconcile_property_values(rest_fyp or rest, report)
    reconcile_photos(rest_fyp or rest, report)
    sync_drafts(rest_fyp, args.mode, report)

    out = json.dumps(report, indent=2, default=str)
    if args.output:
        Path(args.output).write_text(out, encoding="utf-8")
        print(f"report -> {args.output}")
    else:
        print(out)

    blocked = "BLOCKED" in out
    print(f"\n{'DONE (with blocked steps)' if blocked else 'DONE'}: mode={args.mode}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
