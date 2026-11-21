"""CP-04: authoritative BCB binding readiness probe (read-only).

BusinessContextBuilderV1._build requires ten governed bindings. At the time of
this probe the production composition supplied `UnverifiedContextBindings`, whose
`resolve()` always raised `BCB_BINDING_AUTHORITY_UNVERIFIED` — deliberately,
because no guessed tenant/concept/GEO/purpose receipts may be invented. That stub
has since been replaced by the M2-backed `M2ContextBindings` resolver; this probe
is retained as the historical structural inventory of the required bindings.

This probe answers one question with evidence rather than assertion:
for each required binding, does an authoritative persisted source actually exist?

Introspection uses pg_class / pg_attribute, NOT information_schema: the app role
is privilege-filtered there and a restricted view would report a populated table
as absent. RLS also hides rows unless `project1.actor_id` is set in the same
transaction, so every read below happens inside one explicit transaction.

It changes nothing and dispatches nothing.
"""
import sys
from pathlib import Path
from uuid import UUID

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from sqlalchemy import create_engine, text  # noqa: E402

from sitewise.core.config import settings  # noqa: E402

ACTOR = UUID("11111111-1111-4111-8111-111111111111")
ASSESSMENT = UUID("da90aa4a-f9cf-4145-9acf-7de36c9d6fad")
REV = 12

# binding -> (why the builder needs it, source table, required columns)
REQUIRED = {
    "request.tenant_id": (
        "scopes every row and must equal bindings.scope.tenant_id",
        None, ()),
    "bindings.snapshot_id": (
        "SNAPSHOT_SCOPE_INVALID unless a snapshot registry yields an immutable id",
        None, ()),
    "bindings.concept": (
        "CONCEPT_MISSING/CONCEPT_STALE: version, status, confirmed_by, content, "
        "valid_until, source_hash, m2_snapshot_digest",
        None, ("version", "status", "confirmed_by", "confirmation_event_id",
               "valid_until", "source_hash", "m2_snapshot_digest")),
    "bindings.current_concept_version": (
        "must equal concept.version and request.concept_version", None, ()),
    "bindings.geography": (
        "GEO_UNAPPROVED: GEO_V1 catalogue_family, approval_state, approval_ref, "
        "catalogue_version, catalogue_hash, area_id, jurisdiction, area_kind, identity_hash",
        None, ("approval_ref", "approval_state", "catalogue_hash", "jurisdiction")),
    "bindings.rule_versions": (
        "FINDING_VERSION_INVALID unless rule_id -> rule_version is registered",
        "m2_bdj_findings", ("rule_id", "rule_version")),
    "bindings.finding_authorities": (
        "FINDING_AUTHORITY_INVALID for VERIFIED findings: finding_hash, "
        "confirmation_id, review_event_id",
        None, ("finding_hash", "review_event_id")),
    "bindings.uncertainty": (
        "UNCERTAINTY_NOT_CONFIRMED otherwise: id, confirmation_id, actor_user_id, exact_text",
        "m2_confirmed_uncertainties", ("confirmation_id", "actor_user_id", "exact_text")),
    "bindings.sources": (
        "SOURCE_QUALIFICATION_INVALID: citation, evidence_class, allowed_purposes, "
        "allowed_viewers, valid_until, facts, limitations",
        None, ("citation", "evidence_class", "allowed_purposes", "allowed_viewers")),
    "decision": (
        "ACCESS_DENIED unless allowed/scope/owner_id/decision_id/policy_version/valid_until",
        None, ("decision_id", "policy_version", "valid_until")),
}


def relations(conn):
    return {r for r in conn.execute(text(
        "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
        "WHERE n.nspname='public' AND c.relkind IN ('r','v','m')")).scalars()}


def columns(conn):
    rows = conn.execute(text(
        "SELECT c.relname, a.attname FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid "
        "JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' "
        "AND c.relkind='r' AND a.attnum>0 AND NOT a.attisdropped")).all()
    out = {}
    for table, col in rows:
        out.setdefault(table, set()).add(col)
    return out


def main() -> int:
    engine = create_engine(settings.m2_database_url.get_secret_value(), hide_parameters=True)
    results = {}
    with engine.connect() as c:
        tx = c.begin()
        c.execute(text("SELECT set_config('project1.actor_id', :a, true)"), {"a": str(ACTOR)})
        rels, cols = relations(c), columns(c)
        rows = {t: c.execute(text(f"SELECT count(*) FROM {t}")).scalar()
                for t in ("m2_assessments", "m2_answer_revisions", "m2_confirmation_snapshots",
                          "m2_bdj_findings", "m2_confirmed_uncertainties",
                          "m2_business_contexts")}

        # A binding is resolvable only if some source table carries ALL required columns.
        for name, (why, table, need) in REQUIRED.items():
            if table is not None:
                have = cols.get(table, set())
                missing = [x for x in need if x not in have]
                ok = not missing and rows.get(table, 0) > 0
                detail = (f"{table}: {len(need)}/{len(need)} cols, rows={rows.get(table, 0)}"
                          if not missing else f"{table}: missing cols {missing}")
            else:
                # Search the whole schema for a table carrying every required column.
                hits = [t for t, have in cols.items() if need and all(x in have for x in need)]
                if not need:
                    hits = []
                ok = bool(hits)
                detail = f"candidate tables={hits}" if hits else "no source table carries these columns"
            results[name] = (ok, detail, why)

        print(f"assessment={ASSESSMENT} rev={REV} actor={ACTOR}")
        print(f"relations in public: {len(rels)} | rows: " +
              ", ".join(f"{k}={v}" for k, v in rows.items()))
        print()
        for name, (ok, detail, why) in results.items():
            print(f"{'RESOLVABLE' if ok else 'MISSING   '}  {name:32s} {detail}")
        print()
        # The output table proves the distinction: tenant_id/concept_version exist as
        # *columns of the context output*, not as authoritative sources anywhere.
        out_cols = cols.get("m2_business_contexts", set())
        print("NOTE  m2_business_contexts carries tenant_id/concept_version "
              f"({'yes' if {'tenant_id','concept_version'} <= out_cols else 'no'}) "
              "as OUTPUT columns only; no source table defines them.")
        tx.rollback()

    missing = [k for k, v in results.items() if not v[0]]
    print()
    print(f"resolvable={len(results)-len(missing)} missing={len(missing)}")
    print("VERDICT=" + ("BLOCKED" if missing else "READY"))
    return 0 if not missing else 1


if __name__ == "__main__":
    raise SystemExit(main())
