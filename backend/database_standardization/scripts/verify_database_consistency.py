"""Verify schema and data consistency between local PostgreSQL and Supabase.

Phase 9 of the database-standardization effort. Produces a machine-readable
verification report distinguishing:

* **Verified parity** — checked against live data (schema contract and/or
  record sets matched via stable identifiers).
* **Reported differences** — intentional (local-only research schemas,
  Supabase-managed infrastructure, environment-specific records).
* **Blocked** — cannot be verified with the credentials available
  (e.g. no direct Supabase DSN: constraints/RLS invisible over REST).

Parity is NEVER asserted from row counts alone: primary-key sets and
column-level value comparisons are always included.

Usage (PowerShell, from ``backend/``)::

    .venv\\Scripts\\python.exe database_standardization\\scripts\\verify_database_consistency.py ^
        --output database_standardization\\FINAL_VERIFICATION_REPORT.json
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _supabase_rest import (
    CLASS_OTHER,
    CLASS_SCHEMA_NOT_EXPOSED,
    CLASS_TABLE_MISSING,
    SupabaseRest,  # noqa: E402
)

CANONICAL_TABLES = [
    # (canonical name, populated check, key column)
    ("rental_properties", True, "id"),
    ("property_photos", True, "id"),
    ("addresses", True, "id"),
    ("verification_audit", True, "audit_id"),
    ("property_features", False, "id"),
    ("favorite_property", False, "favorite_id"),
    ("entrepreneur_preferences", False, "preference_id"),
    ("recommendation_result", False, "result_id"),
    ("ai_explanation", False, "explanation_id"),
    ("virtual_tour", False, "tour_id"),
    ("property_verification", False, "verification_id"),
    ("verification_document", False, "document_id"),
    ("listing_change_request", False, "change_request_id"),
    ("listing_change_audit", False, "audit_id"),
    ("agent_listing_assignment", False, "listing_id"),
    ("district_demographic", False, "district_id"),
    ("ml_explanation_cache", False, "cache_key"),
]

CANONICAL_COLUMNS_RENTAL = [
    # (column, type_family) — verified over REST where available.
    "id", "name", "property_type", "address", "rental_price", "built_up_sqft",
    "bathrooms", "floor_level", "tenure", "furnishing", "availability",
    "is_corner_lot", "has_parking", "is_freehold", "is_fnb_suitable",
    "verification_status", "rejection_reason", "is_published", "created_at",
    "updated_at", "unit_position", "facing_direction", "published_at",
    "owner_user_id", "address_id", "district_id", "company_name",
    "parking_spaces", "bedrooms", "year_built", "status", "latitude",
    "longitude", "catalogue_source_data",
]

INTENTIONAL_DIFFERENCES = [
    {"item": "local research schemas (fnb_a, demand_gen, fyp_features, popfeat, public geo staging)",
     "reason": "Local-only research/analytics per policy 5C — never synchronized."},
    {"item": "fyp.capture_sessions / capture_frames / panorama_jobs / panoramas",
     "reason": "Local-operational capture pipeline; Supabase copies are created only at a verified cutover (alembic)."},
    {"item": "fyp.property_enrichment_category, property_feature_freshness, property_listing_sources, property_listing_verification, property_subject_links, property_geospatial_features, catalogue_properties, v_property_analysis",
     "reason": "Research/catalogue infrastructure and enrichment state — local-only."},
    {"item": "public.pano_capture_sessions / pano_capture_frames / pano_jobs",
     "reason": "Legacy AR-source pipeline; read-only through PublicPanoramaBridge."},
    {"item": "public.agent, public.company, public.staff_invitations, public.role_change_audit (Supabase only)",
     "reason": "Supabase-side staff identity managed by backend/supabase/migrations; not replicated locally."},
    {"item": "public.users row sets differ",
     "reason": "Dev/test profiles exist only where created; auth.users is the origin of truth for Supabase profiles."},
]


def local_schema_summary() -> dict:
    from sqlalchemy import text

    from sitewise.db.session import engine

    out: dict = {"tables": {}, "alembic": None, "legacy_remaining": []}
    with engine.connect() as c:
        out["alembic"] = c.execute(
            text("SELECT version_num FROM public.alembic_version")
        ).scalar()
        for name, _populated, _key in CANONICAL_TABLES:
            exists = c.execute(
                text("SELECT to_regclass(:t)"), {"t": f"fyp.{name}"}
            ).scalar() is not None
            count = None
            if exists:
                count = c.execute(text(f"SELECT COUNT(*) FROM fyp.{name}")).scalar()
            out["tables"][name] = {"exists_in_fyp": bool(exists),
                                   "exists_in_public": bool(c.execute(
                                       text("SELECT to_regclass(:t)"),
                                       {"t": f"public.{name}"}).scalar()),
                                   "rows": count}
        out["rental_columns"] = c.execute(
            text("SELECT COUNT(*) FROM information_schema.columns "
                 "WHERE table_schema='fyp' AND table_name='rental_properties'")
        ).scalar()
        for legacy in ("fyp.users", "fyp.favourite_properties", "fyp.ml_models",
                       "public.property_photo", "public.property_feature"):
            if c.execute(text("SELECT to_regclass(:t)"), {"t": legacy}).scalar():
                out["legacy_remaining"].append(legacy)
        out["outbox_seeded"] = c.execute(
            text("SELECT COUNT(*) FROM sitewise_sync.assignment_outbox")
        ).scalar() if c.execute(text("SELECT to_regclass('sitewise_sync.assignment_outbox')")).scalar() else None
    return out


def remote_summary(rest: SupabaseRest | None, profile: str) -> dict:
    """REST-visible canonical state (works pre- and post-migration)."""
    out: dict = {"profile": profile, "tables": {}}
    if rest is None:
        out["error"] = "REST not configured"
        return out
    for name, _pop, _key in CANONICAL_TABLES:
        try:
            _rows, total = rest.get(name, select="", limit=0, count=True)
            out["tables"][name] = {"rows": total}
        except RuntimeError as exc:
            out["tables"][name] = {"rows": None, "note": str(exc)[:120]}
    try:
        _rows, total = rest.get("rental_properties", select="", limit=0, count=True)
        spec = rest.get("rental_properties", select=", ".join(CANONICAL_COLUMNS_RENTAL),
                        limit=1)[0]
        out["rental_columns_present"] = sorted(spec[0].keys()) if spec else []
    except RuntimeError as exc:
        out["rental_note"] = str(exc)[:200]
    return out


def data_parity(rest_fyp: SupabaseRest | None, rest_legacy: SupabaseRest | None,
                report: dict) -> None:
    """PK-set and value parity for the property master (the load-bearing entity)."""
    from sqlalchemy import text

    from sitewise.db.session import engine

    with engine.connect() as c:
        local_ids = {int(r[0]) for r in c.execute(
            text("SELECT id FROM fyp.rental_properties WHERE is_published = true"))}
        local_sample = {
            int(r[0]): {"name": r[1], "verification_status": r[2],
                        "is_published": r[3]}
            for r in c.execute(text(
                "SELECT id, name, verification_status, is_published "
                "FROM fyp.rental_properties WHERE is_published = true"))}

    rest = rest_fyp or rest_legacy
    if rest is None:
        report["data_parity"] = {"status": "BLOCKED", "reason": "REST not configured"}
        return
    remote_ids: set[int] = set()
    remote_sample: dict[int, dict] = {}
    pk_col = "id" if rest_fyp else "property_id"
    name_col = "name" if rest_fyp else "title"
    try:
        rows, total = rest.get(
            "rental_properties" if rest_fyp else "property",
            select=f"{pk_col},{name_col},verification_status,is_published", limit=2000)
        for r in rows:
            pid = int(r[pk_col])
            remote_ids.add(pid)
            remote_sample[pid] = {
                "name": r.get(name_col),
                "verification_status": r.get("verification_status"),
                "is_published": r.get("is_published"),
            }
    except RuntimeError as exc:
        classification = getattr(exc, "classification", CLASS_OTHER)
        reason = {
            CLASS_SCHEMA_NOT_EXPOSED: (
                "fyp schema is not exposed to PostgREST (PGRST106): expose it "
                "in Supabase API settings to run parity checks"
            ),
            CLASS_TABLE_MISSING: (
                "legacy public.property no longer exists (migration 03 "
                "applied) and fyp is not REST-exposed; parity needs the fyp "
                "schema exposed"
            ),
        }.get(classification, str(exc)[:200])
        report["data_parity"] = {"status": "BLOCKED", "reason": reason}
        return

    value_mismatches = []
    for pid in sorted(local_ids & remote_ids):
        l, r = local_sample[pid], remote_sample[pid]
        if (l["name"] or "") != (r["name"] or ""):
            value_mismatches.append({"id": pid, "col": "name"})
        if (l["verification_status"] or "") != (r["verification_status"] or ""):
            value_mismatches.append({"id": pid, "col": "verification_status"})

    report["data_parity"] = {
        "status": "VERIFIED",
        "local_published_ids": len(local_ids),
        "remote_ids": len(remote_ids),
        "missing_on_remote": sorted(local_ids - remote_ids)[:50],
        "extra_on_remote": sorted(remote_ids - local_ids)[:50],
        "value_mismatch_count": len(value_mismatches),
        "value_mismatches_sample": value_mismatches[:25],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default=None)
    args = parser.parse_args(argv)

    report: dict = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "tool": "verify_database_consistency",
    }

    report["local"] = local_schema_summary()

    rest_legacy = None
    rest_fyp = None
    fyp_probe_failure: dict = {}
    try:
        rest_legacy = SupabaseRest(profile="public")
    except RuntimeError:
        pass
    if rest_legacy is not None:
        try:
            probe = SupabaseRest(profile="fyp")
            probe.get("rental_properties", select="", limit=0, count=True)
            rest_fyp = probe
        except RuntimeError as exc:
            fyp_probe_failure = {
                "classification": getattr(exc, "classification", CLASS_OTHER),
                "detail": str(exc)[:200],
            }
    report["supabase_fyp_probe"] = fyp_probe_failure

    # Structural evidence that migration 03 was APPLIED on Supabase: the
    # legacy public.property master is gone from the exposed public profile
    # (PGRST205 table_missing). Migration 03 is transactional, so a committed
    # rename means fyp.rental_properties exists even while fyp itself is not
    # REST-exposed (PGRST106).
    old_property_gone: bool | None = None
    if rest_legacy is not None:
        try:
            rest_legacy.get("property", select="", limit=0, count=True)
            old_property_gone = False  # legacy master still present
        except RuntimeError as exc:
            old_property_gone = (
                getattr(exc, "classification", CLASS_OTHER) == CLASS_TABLE_MISSING
            )
    report["supabase_legacy_property_gone"] = old_property_gone

    report["supabase"] = remote_summary(rest_fyp or rest_legacy,
                                        "fyp" if rest_fyp else "public")
    data_parity(rest_fyp, rest_legacy, report)
    report["intentional_differences"] = INTENTIONAL_DIFFERENCES

    # Composite verdict — never claims full parity from counts alone.
    local = report["local"]
    checks = {
        "canonical_tables_in_fyp_local": all(
            v["exists_in_fyp"] and not v["exists_in_public"]
            for v in local["tables"].values()),
        "no_legacy_duplicates_local": not local["legacy_remaining"],
        "rental_contract_60_columns": local["rental_columns"] == 60,
        "outbox_installed": bool(local["outbox_seeded"]),
        "remote_property_parity": report.get("data_parity", {}).get("status") == "VERIFIED"
        and not report["data_parity"].get("value_mismatch_count")
        and not report["data_parity"].get("missing_on_remote"),
        "supabase_fyp_schema_migrated": (
            rest_fyp is not None
            and report["supabase"]["tables"]["rental_properties"]["rows"] is not None
        ) or (
            old_property_gone is True
            and fyp_probe_failure.get("classification") == CLASS_SCHEMA_NOT_EXPOSED
        ),
        "fyp_schema_rest_exposed": rest_fyp is not None,
    }
    report["checks"] = checks
    if all(checks.values()):
        report["verdict"] = "PASS"
    elif not checks["fyp_schema_rest_exposed"] and checks["supabase_fyp_schema_migrated"]:
        report["verdict"] = (
            "PARTIAL (fyp migrated on Supabase; expose the fyp API schema to "
            "verify parity)"
        )
    elif (not checks["supabase_fyp_schema_migrated"]
          or report.get("data_parity", {}).get("status") == "BLOCKED"):
        report["verdict"] = "PARTIAL (Supabase-side steps blocked pending migration 03)"
    else:
        report["verdict"] = "FAIL"
    if not checks["fyp_schema_rest_exposed"] and checks["supabase_fyp_schema_migrated"]:
        report["verdict_note"] = (
            "Supabase-side migration 03 is APPLIED (legacy public.property is "
            "gone), but the fyp schema is not exposed to PostgREST (PGRST106). "
            "Expose it via Supabase Dashboard -> Settings -> API -> Exposed "
            "schemas (or ALTER DATABASE postgres SET pgrst.db_schemas), then "
            "re-run this tool for full parity confirmation."
        )
    elif not checks["supabase_fyp_schema_migrated"]:
        report["verdict_note"] = (
            "Local canonical migration verified. Supabase-side migration (03) "
            "requires the Supabase SQL editor / a direct DSN — apply it, then "
            "re-run this tool for full parity confirmation."
        )

    out = json.dumps(report, indent=2, default=str)
    if args.output:
        Path(args.output).write_text(out, encoding="utf-8")
        print(f"report -> {args.output}")
    print(json.dumps({"verdict": report["verdict"], "checks": checks}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
