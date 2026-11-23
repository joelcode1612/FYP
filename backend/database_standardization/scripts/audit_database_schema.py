"""Read-only inventory of the SiteWise databases (local PostgreSQL + Supabase).

Deliverable of the database-standardization effort. Produces a complete,
classified inventory of every schema, table, view, column, constraint, index,
RLS policy, grant and row count, and writes JSON + Markdown reports to
``database_standardization/audit/``.

Targets
--------
``local``
    Direct SQLAlchemy connection using ``DATABASE_URL`` from the backend
    environment. Full catalog introspection (constraints, policies, grants).
``supabase``
    REST-only inventory through PostgREST (``SUPABASE_URL`` +
    ``SUPABASE_SECRET_KEY``). Exposed tables/columns/row counts only --
    PostgREST cannot report constraints, RLS or grants. When a direct DSN is
    available (``--supabase-dsn`` or ``SUPABASE_DB_URL``), the local-style
    full introspection is used instead.

Security
--------
Credentials are read from the environment only and never printed, logged or
written to any output file. Output reports contain schema/table/column
metadata exclusively.

Usage (Windows PowerShell, from ``backend/``)::

    .venv\\Scripts\\python.exe database_standardization\\scripts\\audit_database_schema.py --target both

This tool is strictly read-only.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

PG_SYSTEM_SCHEMAS = {
    "information_schema",
    "pg_catalog",
    "pg_toast",
    "pg_temp_1",
    "pg_toast_temp_1",
}

SUPABASE_MANAGED_SCHEMAS = {
    "auth",
    "storage",
    "extensions",
    "graphql",
    "graphql_public",
    "realtime",
    "net",
    "pgsodium",
    "pgsodium_masks",
    "vault",
    "supabase_functions",
    "supabase_migrations",
    "pgtle",
    "cron",
    "pgbouncer",
}

RESEARCH_SCHEMA_PREFIXES = (
    "sitewise_",
    "fyp_features",
    "demand_gen",
    "dosm",
    "analytics",
)

# Explicit classification for known operational tables.
OPERATIONAL_TABLES = {
    ("fyp", "rental_properties"),
    ("fyp", "property_photos"),
    ("fyp", "property_features"),
    ("fyp", "favourite_property"),
    ("fyp", "entrepreneur_preferences"),
    ("fyp", "assessment"),
    ("fyp", "recommendation_result"),
    ("fyp", "ai_explanation"),
    ("fyp", "ml_explanation_cache"),
    ("fyp", "listing_change_request"),
    ("fyp", "property_verification"),
    ("fyp", "verification_document"),
    ("fyp", "verification_audit"),
    ("fyp", "virtual_tour"),
    ("fyp", "capture_sessions"),
    ("fyp", "capture_frames"),
    ("fyp", "panorama_jobs"),
    ("fyp", "panoramas"),
    ("fyp", "property_enrichment_category"),
    ("fyp", "property_feature_freshness"),
    ("fyp", "geo_refresh_state"),
    ("fyp", "address_validation_cache"),
    ("public", "users"),
    ("public", "agent"),
    ("public", "company"),
    ("public", "staff_invitations"),
    ("public", "role_change_audit"),
    ("public", "agent_listing_assignment"),
}

IDENTITY_TABLES = {
    ("public", "users"),
    ("public", "agent"),
    ("public", "company"),
    ("public", "staff_invitations"),
    ("public", "role_change_audit"),
}

# Documented read surfaces and externally-managed research artifacts inside
# the operational schema; never synchronized to Supabase.
FYP_KNOWN_NON_OPERATIONAL = {
    "catalogue_properties",  # documented research read view (EP-/MD- rows)
    "property_geospatial_features",
    "property_subject_links",
    "district_demographic",
    "nearby_competitor",
    "property_foot_traffic",
    "property_enrichment_category",
    "property_feature_freshness",
    "geo_refresh_state",
}


def classify(schema: str, table: str, relkind: str) -> str:
    """Classify a relation per the standardization policy."""
    if schema in SUPABASE_MANAGED_SCHEMAS or schema in PG_SYSTEM_SCHEMAS:
        return "supabase_managed_infrastructure"
    if (schema, table) in IDENTITY_TABLES:
        return "identity_or_security"
    if (schema, table) in OPERATIONAL_TABLES:
        return "shared_operational_application"
    if table.startswith("pano_"):
        return "legacy_external_capture_bridge"
    if table.startswith("sitewise_sync") or schema == "sitewise_sync":
        return "sync_infrastructure"
    if schema == "fyp":
        if table in FYP_KNOWN_NON_OPERATIONAL:
            return "operational_schema_research_or_state"
        return "unknown_requires_investigation"
    if schema == "public":
        return "unknown_requires_investigation"
    if schema.startswith(RESEARCH_SCHEMA_PREFIXES) or any(
        schema.startswith(p) for p in RESEARCH_SCHEMA_PREFIXES
    ):
        return "local_only_research_analytics"
    if relkind in ("v", "m"):
        return "view_materialized_view"
    return "unknown_requires_investigation"


def is_view(relkind: str) -> bool:
    return relkind in ("v", "m", "f")


# ---------------------------------------------------------------------------
# Direct (SQLAlchemy) inventory
# ---------------------------------------------------------------------------

SCHEMA_RELKINDS_SQL = """
SELECT n.nspname AS schema,
       c.relname AS name,
       c.relkind AS relkind,
       c.relrowsecurity AS rls,
       c.relforcerowsecurity AS rls_forced,
       COALESCE(c.reltuples, 0)::bigint AS approx_rows
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('information_schema', 'pg_catalog', 'pg_toast', 'pg_temp_1', 'pg_toast_temp_1')
  AND n.nspname NOT LIKE 'pg\\_%'
  AND c.relkind IN ('r', 'v', 'm', 'f', 'p')
ORDER BY n.nspname, c.relname
"""

COLUMNS_SQL = """
SELECT table_schema, table_name, column_name, ordinal_position,
       data_type, character_maximum_length, numeric_precision, numeric_scale,
       is_nullable, column_default, is_identity, identity_generation,
       udt_name, domain_schema, domain_name
FROM information_schema.columns
WHERE table_schema NOT IN ('information_schema', 'pg_catalog', 'pg_toast', 'pg_temp_1', 'pg_toast_temp_1')
  AND table_schema NOT LIKE 'pg\\_%'
ORDER BY table_schema, table_name, ordinal_position
"""

CONSTRAINTS_SQL = """
SELECT n.nspname AS schema,
       cl.relname AS table_name,
       con.conname AS name,
       con.contype AS type,
       pg_get_constraintdef(con.oid, true) AS definition
FROM pg_constraint con
JOIN pg_class cl ON cl.oid = con.conrelid
JOIN pg_namespace n ON n.oid = cl.relnamespace
WHERE n.nspname NOT IN ('information_schema', 'pg_catalog', 'pg_toast', 'pg_temp_1', 'pg_toast_temp_1')
  AND n.nspname NOT LIKE 'pg\\_%'
ORDER BY n.nspname, cl.relname, con.conname
"""

INDEXES_SQL = """
SELECT schemaname, tablename, indexname, indexdef
FROM pg_indexes
WHERE schemaname NOT IN ('information_schema', 'pg_catalog', 'pg_toast', 'pg_temp_1', 'pg_toast_temp_1')
  AND schemaname NOT LIKE 'pg\\_%'
ORDER BY schemaname, tablename, indexname
"""

TRIGGERS_SQL = """
SELECT event_object_schema AS schema, event_object_table AS table_name,
       trigger_name, action_timing, event_manipulation, action_statement
FROM information_schema.triggers
WHERE trigger_schema NOT IN ('information_schema', 'pg_catalog', 'pg_toast', 'pg_temp_1', 'pg_toast_temp_1')
  AND trigger_schema NOT LIKE 'pg\\_%'
ORDER BY event_object_schema, event_object_table, trigger_name
"""

POLICIES_SQL = """
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual,
       with_check
FROM pg_policies
WHERE schemaname NOT IN ('information_schema', 'pg_catalog', 'pg_toast', 'pg_temp_1', 'pg_toast_temp_1')
ORDER BY schemaname, tablename, policyname
"""

GRANTS_SQL = """
SELECT table_schema, table_name, grantee, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema NOT IN ('information_schema', 'pg_catalog', 'pg_toast', 'pg_temp_1', 'pg_toast_temp_1')
  AND table_schema NOT LIKE 'pg\\_%'
  AND grantee IN ('anon', 'authenticated', 'service_role', 'postgres', 'public')
ORDER BY table_schema, table_name, grantee, privilege_type
"""

SEQUENCES_SQL = """
SELECT schemaname, sequencename, data_type::text AS data_type, start_value,
       increment_by, COALESCE(last_value, 0)::bigint AS last_value
FROM pg_sequences
WHERE schemaname NOT IN ('information_schema', 'pg_catalog', 'pg_toast', 'pg_temp_1', 'pg_toast_temp_1')
  AND schemaname NOT LIKE 'pg\\_%'
ORDER BY schemaname, sequencename
"""

ENUMS_SQL = """
SELECT n.nspname AS schema, t.typname AS name,
       string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder) AS labels
FROM pg_type t
JOIN pg_enum e ON e.enumtypid = t.oid
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname NOT IN ('information_schema', 'pg_catalog', 'pg_toast', 'pg_temp_1', 'pg_toast_temp_1')
GROUP BY n.nspname, t.typname
ORDER BY n.nspname, t.typname
"""

EXTENSIONS_SQL = "SELECT extname, extversion FROM pg_extension ORDER BY extname"

EXACT_COUNT_SQL = 'SELECT COUNT(*) FROM "{schema}"."{table}"'


def direct_inventory(engine, label: str, exact_count_limit: int = 200_000) -> dict:
    """Full catalog introspection of one PostgreSQL database."""
    from sqlalchemy import text

    out: dict = {
        "target": label,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "database": None,
        "server": None,
        "extensions": [],
        "schemas": [],
        "relations": [],
        "columns": [],
        "constraints": [],
        "indexes": [],
        "triggers": [],
        "policies": [],
        "grants": [],
        "sequences": [],
        "enums": [],
    }
    with engine.connect() as conn:
        out["database"] = conn.execute(text("SELECT current_database()")).scalar()
        out["server"] = conn.execute(text("SELECT version()")).scalar()

        out["extensions"] = [
            dict(r._mapping) for r in conn.execute(text(EXTENSIONS_SQL))
        ]
        out["schemas"] = [
            r._mapping["nspname"]
            for r in conn.execute(
                text(
                    "SELECT nspname FROM pg_namespace "
                    "WHERE nspname NOT IN ('information_schema', 'pg_catalog', "
                    "'pg_toast', 'pg_temp_1', 'pg_toast_temp_1') "
                    "AND nspname NOT LIKE 'pg\\_%' ORDER BY nspname"
                ),
            )
        ]

        relations = [
            dict(r._mapping) for r in conn.execute(text(SCHEMA_RELKINDS_SQL),
                                                   )
        ]
        for rel in relations:
            rel["classification"] = classify(
                rel["schema"], rel["name"], rel["relkind"]
            )
            rel["is_view"] = is_view(rel["relkind"])
        out["relations"] = relations

        out["columns"] = [
            dict(r._mapping) for r in conn.execute(text(COLUMNS_SQL),
                                                   )
        ]
        out["constraints"] = [
            dict(r._mapping) for r in conn.execute(text(CONSTRAINTS_SQL),
                                                   )
        ]
        out["indexes"] = [
            dict(r._mapping) for r in conn.execute(text(INDEXES_SQL),
                                                   )
        ]
        out["triggers"] = [
            dict(r._mapping) for r in conn.execute(text(TRIGGERS_SQL),
                                                   )
        ]
        out["policies"] = [
            dict(r._mapping) for r in conn.execute(text(POLICIES_SQL),
                                                   )
        ]
        out["grants"] = [
            dict(r._mapping) for r in conn.execute(text(GRANTS_SQL),
                                                   )
        ]
        out["sequences"] = [
            dict(r._mapping) for r in conn.execute(text(SEQUENCES_SQL))
        ]
        out["enums"] = [
            dict(r._mapping) for r in conn.execute(text(ENUMS_SQL),
                                                   )
        ]

        # Exact counts for operational-sized relations; estimates elsewhere.
        exact = {}
        for rel in relations:
            if rel["is_view"] or rel["relkind"] == "f":
                continue
            if rel["approx_rows"] <= exact_count_limit:
                try:
                    exact[f'{rel["schema"]}.{rel["name"]}'] = conn.execute(
                        text(
                            EXACT_COUNT_SQL.format(
                                schema=rel["schema"], table=rel["name"]
                            )
                        )
                    ).scalar()
                except Exception:  # noqa: BLE001 - inventory must not die on one table
                    exact[f'{rel["schema"]}.{rel["name"]}'] = None
        out["exact_row_counts"] = exact

        # FK orphans among operational relations (referential hygiene audit).
        orphans = []
        fk_defs = [
            c for c in out["constraints"]
            if c["type"] == "f" and c["schema"] in ("fyp", "public")
        ]
        for fk in fk_defs:
            # definition looks like: FOREIGN KEY (col) REFERENCES schema.tbl(col)
            try:
                orphans.extend(_fk_orphans(conn, fk))
            except Exception as exc:  # noqa: BLE001
                orphans.append(
                    {"constraint": fk["name"], "error": str(exc)[:160]}
                )
        out["operational_fk_orphans"] = orphans
    return out


def _fk_orphans(conn, fk: dict) -> list[dict]:
    """Detect child rows whose referenced parent no longer exists."""
    import re

    from sqlalchemy import text

    m = re.search(
        r"FOREIGN KEY \(([^)]+)\) REFERENCES ([^\s(]+)\(([^)]+)\)",
        fk["definition"] or "",
    )
    if not m:
        return []
    child_cols = [c.strip().strip('"') for c in m.group(1).split(",")]
    ref_table = m.group(2).strip().strip('"')
    ref_cols = [c.strip().strip('"') for c in m.group(3).split(",")]
    if "." not in ref_table:
        ref_table = f'{fk["schema"]}.{ref_table}'
    child_table = f'{fk["schema"]}.{fk["table_name"]}'
    # Skip self-referential and cross-schema-to-managed references.
    predicate = " AND ".join(
        f'c."{cc}" = p."{rc}"' for cc, rc in zip(child_cols, ref_cols)
    )
    # NULLs are allowed by definition.
    null_guard = " OR ".join(f'c."{cc}" IS NULL' for cc in child_cols)
    sql = (
        f'SELECT COUNT(*) FROM "{fk["schema"]}"."{fk["table_name"]}" c '
        f'LEFT JOIN "{ref_table}" p ON {predicate} '
        f"WHERE p.{ref_cols[0]} IS NULL AND NOT ({null_guard})"
    )
    count = conn.execute(text(sql)).scalar()
    if count:
        return [
            {
                "constraint": fk["name"],
                "child_table": child_table,
                "reference_table": ref_table,
                "orphan_rows": int(count),
            }
        ]
    return []


# ---------------------------------------------------------------------------
# Supabase REST inventory
# ---------------------------------------------------------------------------


def rest_inventory(base_url: str, secret_key: str, label: str) -> dict:
    """Inventory of what PostgREST exposes (public schema surface only)."""
    import httpx

    out: dict = {
        "target": label,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "mode": "rest_openapi",
        "limitations": (
            "PostgREST exposes only tables in the configured db-schemas with "
            "grants for the API roles; constraints, RLS policies, grants, "
            "views and non-exposed schemas are not visible via REST."
        ),
        "tables": [],
        "not_exposed_or_error": [],
    }
    headers = {
        "apikey": secret_key,
        "Authorization": f"Bearer {secret_key}",
    }
    with httpx.Client(timeout=20, follow_redirects=False) as client:
        spec_resp = client.get(f"{base_url.rstrip('/')}/rest/v1/", headers=headers)
        if spec_resp.status_code != 200:
            out["error"] = (
                f"OpenAPI root returned {spec_resp.status_code}; "
                "REST inventory unavailable."
            )
            return out
        spec = spec_resp.json()
        tables = sorted(
            path.strip("/").split("?")[0]
            for path in spec.get("paths", {})
            if path.strip("/") and "?" not in path
        )
        for table in tables:
            definition = spec.get("definitions", {}).get(table, {})
            columns = [
                {
                    "name": name,
                    "type": prop.get("format") or prop.get("type"),
                    "description": prop.get("description"),
                    "required": name in definition.get("required", []),
                }
                for name, prop in definition.get("properties", {}).items()
            ]
            entry = {
                "table": table,
                "columns": columns,
                "row_count": None,
                "count_error": None,
            }
            try:
                count_resp = client.get(
                    f"{base_url.rstrip('/')}/rest/v1/{table}",
                    headers={**headers, "Prefer": "count=exact"},
                    params={"select": "", "limit": "0"},
                )
                cr = count_resp.headers.get("content-range", "")
                if "/" in cr:
                    total = cr.split("/")[-1]
                    entry["row_count"] = None if total == "*" else int(total)
                elif count_resp.status_code in (401, 403, 404):
                    entry["count_error"] = f"HTTP {count_resp.status_code}"
                else:
                    entry["count_error"] = (
                        f"HTTP {count_resp.status_code} no content-range"
                    )
            except Exception as exc:  # noqa: BLE001
                entry["count_error"] = str(exc)[:160]
            entry["classification"] = classify("public", table, "r")
            out["tables"].append(entry)
    return out


# ---------------------------------------------------------------------------
# Markdown rendering
# ---------------------------------------------------------------------------


def render_markdown(inv: dict, title: str) -> str:
    lines = [f"# {title}", "", f"- Database: `{inv.get('database', 'REST')}`",
             f"- Generated: {inv.get('generated_at')}", ""]
    if inv.get("server"):
        lines += [f"- Server: `{inv['server'][:80]}`", ""]

    rels = inv.get("relations", [])
    if rels:
        by_class: dict[str, list] = defaultdict(list)
        for rel in rels:
            by_class[rel["classification"]].append(rel)
        lines += ["## Relations by classification", ""]
        order = [
            "shared_operational_application",
            "identity_or_security",
            "sync_infrastructure",
            "operational_schema_research_or_state",
            "legacy_external_capture_bridge",
            "local_only_research_analytics",
            "view_materialized_view",
            "unknown_requires_investigation",
            "supabase_managed_infrastructure",
        ]
        counts = {}
        for cls in order:
            rows = by_class.get(cls, [])
            if not rows:
                continue
            counts[cls] = len(rows)
        for cls, rows in sorted(by_class.items(), key=lambda kv: -len(kv[1])):
            lines.append(f"### {cls} ({len(rows)})")
            lines.append("")
            lines.append("| Relation | Kind | Approx rows | Exact | RLS |")
            lines.append("|---|---|---:|---:|---|")
            for rel in rows[:60]:
                name = f'{rel["schema"]}.{rel["name"]}'
                exact = inv.get("exact_row_counts", {}).get(name, "-")
                rls = ""
                if rel.get("rls"):
                    rls = "forced" if rel.get("rls_forced") else "enabled"
                lines.append(
                    f"| {name} | {rel['relkind']} "
                    f"| {rel.get('approx_rows', '-')} | {exact} | {rls} |"
                )
            if len(rows) > 60:
                lines.append(f"| ... {len(rows) - 60} more | | | | |")
            lines.append("")

    if inv.get("operational_fk_orphans"):
        lines += ["## Operational FK orphan check", ""]
        for orphan in inv["operational_fk_orphans"]:
            lines.append(f"- {json.dumps(orphan)}")
        lines.append("")

    if inv.get("policies"):
        lines += ["## RLS policies", ""]
        by_table: dict[str, list] = defaultdict(list)
        for pol in inv["policies"]:
            by_table[f'{pol["schemaname"]}.{pol["tablename"]}'].append(pol)
        for table, pols in sorted(by_table.items()):
            lines.append(f"- **{table}**: {len(pols)} policy/policies "
                         f"({', '.join(p['cmd'] + ':' + p['policyname'] for p in pols[:6])})"
                         + (" ..." if len(pols) > 6 else ""))
        lines.append("")

    if inv.get("tables"):  # REST mode
        lines += ["## REST-exposed tables", ""]
        lines.append("| Table | Columns | Row count | Classification |")
        lines.append("|---|---:|---:|---|")
        for t in inv["tables"]:
            lines.append(
                f"| {t['table']} | {len(t['columns'])} "
                f"| {t['row_count']} | {t['classification']} |"
            )
        lines.append("")

    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--target",
        choices=["local", "supabase", "both"],
        default="both",
    )
    parser.add_argument(
        "--supabase-dsn",
        default=None,
        help="Optional direct Postgres DSN for full Supabase introspection. "
        "Read from SUPABASE_DB_URL when omitted. Never printed.",
    )
    parser.add_argument(
        "--output-dir",
        default=str(Path(__file__).resolve().parents[1] / "audit"),
    )
    parser.add_argument(
        "--exact-count-limit",
        type=int,
        default=200_000,
        help="Tables with estimated rows at or below this get exact COUNT(*)s.",
    )
    args = parser.parse_args(argv)
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # Imports scoped so --help works without a backend environment.
    try:
        from sitewise.core.config import settings
        from sitewise.db.session import engine  # local DATABASE_URL
    except Exception as exc:  # noqa: BLE001
        print(f"Backend environment unavailable: {exc}", file=sys.stderr)
        return 2

    if args.target in ("local", "both"):
        print("Inventorying local database (full catalog introspection)...")
        inv = direct_inventory(engine, "local_postgresql",
                               exact_count_limit=args.exact_count_limit)
        (out_dir / "local_inventory.json").write_text(
            json.dumps(inv, indent=2, default=str), encoding="utf-8"
        )
        (out_dir / "local_inventory.md").write_text(
            render_markdown(inv, "Local PostgreSQL Inventory "
                                 f"({inv.get('database')})"),
            encoding="utf-8",
        )
        n_ops = sum(
            1 for r in inv["relations"]
            if r["classification"] == "shared_operational_application"
        )
        print(f"  database={inv['database']} relations={len(inv['relations'])} "
              f"operational={n_ops} -> audit/local_inventory.{{json,md}}")

    if args.target in ("supabase", "both"):
        dsn = args.supabase_dsn
        if dsn:
            print("Inventorying Supabase (direct DSN, full introspection)...")
            from sqlalchemy import create_engine

            supa_engine = create_engine(dsn, connect_args={"sslmode": "require"})
            inv = direct_inventory(supa_engine, "supabase_postgresql",
                                   exact_count_limit=args.exact_count_limit)
            suffix = "direct"
        else:
            print("Inventorying Supabase via PostgREST OpenAPI (no direct DSN "
                  "configured; constraints/RLS not visible via REST)...")
            inv = rest_inventory(settings.supabase_url,
                                 settings.supabase_secret_key,
                                 "supabase_rest")
            suffix = "rest"
            print(f"  exposed tables={len(inv.get('tables', []))}")
        (out_dir / f"supabase_inventory_{suffix}.json").write_text(
            json.dumps(inv, indent=2, default=str), encoding="utf-8"
        )
        (out_dir / f"supabase_inventory_{suffix}.md").write_text(
            render_markdown(inv, "Supabase Inventory"),
            encoding="utf-8",
        )
        print(f"  -> audit/supabase_inventory_{suffix}.{{json,md}}")

    print("Audit complete (read-only; no credentials written to outputs).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
