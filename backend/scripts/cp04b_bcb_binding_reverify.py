"""CP-04B: re-verify BCB authority bindings against the CURRENT implementation.

Why this script exists
----------------------
`cp04_bcb_binding_readiness.py` (CP-04) reported `resolvable=1 missing=9` using an
abbreviated column list per binding. Two things about that number need re-measuring
rather than assuming:

1. The abbreviated list is weaker than what `BusinessContextBuilderV1._build`
   actually enforces. `bindings.concept`, for instance, is checked against twelve
   fields plus a link to a specific confirmation row, not the seven the old probe
   tested. A table could satisfy the probe and still fail the builder.

2. "A table with the right columns exists" is not the same claim as "the builder
   can obtain this binding". All ten bindings are supplied by
   `ContextUnit.resolve_inputs` -> `resolver.resolve(selection, actor)`. The
   production composition now wires `M2ContextBindings`, which derives them from
   confirmed M2 records (owner, confirmation, findings, uncertainty). So the
   operational count and the structural count are different numbers and must be
   reported separately.

This script therefore reports two verdicts:

    STRUCTURAL  — does an authoritative persisted source exist with the full
                  field set the builder requires, correctly scoped to the live
                  confirmation?
    OPERATIONAL — can the builder actually obtain the binding through the wired
                  composition today?

Read-only: one transaction, actor bound, rolled back. Dispatches nothing, writes
nothing, and does not call `construct_and_save` (which would increment the build
receipt's attempt_count).
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

# Full field sets as enforced in src/sitewise/services/business_context_v1.py.
# `need`  = columns that must exist on one relation (builder calls text_fields/
#           requires these keys unconditionally).
# `where` = line references in the builder, for auditability.
REQUIRED = {
    "request.tenant_id": dict(
        need=(), where="L118-121, L156 (scope equality), L331 (identity.tenant_id)",
        why="scopes every row; must equal bindings.scope.tenant_id",
        note="requires a tenant registry, not a column on the context output",
        # A registry must be able to *define* a tenant, so it needs both an id
        # column and an owner/lifecycle column. Searching for `tenant_id` alone
        # would match the context output table and produce a false positive.
        probe=("tenant_id", "owner_user_id"),
        # m2_business_contexts carries tenant_id because the packet *emits* it.
        # Counting the output as the source of its own input is the error class
        # this script exists to avoid.
        exclude=("public.m2_business_contexts",)),
    "bindings.snapshot_id": dict(
        need=(), where="L155-158",
        why="SNAPSHOT_SCOPE_INVALID unless snapshot_id is non-empty and "
            "consistency == IMMUTABLE_SNAPSHOT",
        note="requires a snapshot registry with a consistency label",
        probe=("snapshot_id", "consistency")),
    "bindings.concept": dict(
        need=("tenant_id", "assessment_id", "version", "confirmation_id",
              "assessment_revision", "status", "confirmed_by",
              "confirmation_event_id", "content", "valid_until",
              "m2_snapshot_digest", "source_hash"),
        where="L223-241",
        why="CONCEPT_MISSING / CONCEPT_STALE / CONCEPT_SOURCE_INVALID",
        note="must link to the live confirmation row and carry a content digest"),
    "bindings.current_concept_version": dict(
        need=("version", "status"), where="L228-232",
        why="must equal concept.version and request.concept_version",
        note="same registry as bindings.concept"),
    "bindings.geography": dict(
        need=("tenant_id", "assessment_id", "catalogue_family", "catalogue_version",
              "catalogue_hash", "approval_state", "approval_ref", "confirmation_id",
              "source_code", "area_id", "jurisdiction", "area_kind", "identity_hash"),
        where="L242-260",
        why="GEO_UNAPPROVED / GEO_SCOPE_INVALID / GEO_IDENTITY_INVALID",
        note="must be catalogue_family='GEO_V1' with approval_state='APPROVED'"),
    "bindings.rule_versions": dict(
        need=(), where="L271 (b['rule_versions'].get(f['rule_id']) == f['rule_version'])",
        why="FINDING_VERSION_INVALID unless rule_id -> rule_version is registered",
        note="needs an authoritative ruleset registry; deriving it from "
             "m2_bdj_findings is circular, because the check would then verify "
             "the findings against themselves",
        probe=("rule_id", "rule_version"),
        # m2_bdj_findings carries rule_id/rule_version because the finding
        # *records* which version produced it. Using it as the registry makes the
        # builder's check circular: the finding would be validated against itself.
        exclude=("public.m2_bdj_findings",)),
    "bindings.finding_authorities": dict(
        need=("tenant_id", "assessment_id", "finding_hash", "confirmation_id",
              "review_event_id"),
        where="L274-285",
        why="FINDING_AUTHORITY_INVALID for any finding with review_state=VERIFIED",
        note="per-finding authority event, scoped to the confirmation"),
    "bindings.uncertainty": dict(
        need=("id", "confirmation_id", "actor_user_id", "exact_text"),
        where="L294-304",
        why="UNCERTAINTY_UNCONFIRMED (downgraded to an 'unknown', not a refusal, "
            "when absent)",
        note="the only binding with a plausible persisted source"),
    "bindings.sources": dict(
        need=("id", "version", "citation", "evidence_class", "source_hash",
              "valid_until", "review_ref", "limitations", "authorized",
              "allowed_purposes", "allowed_viewers", "facts"),
        where="L305-327",
        why="SOURCE_QUALIFICATION_INVALID / SOURCE_ACCESS_DENIED / SOURCE_STALE",
        note="external source qualification with per-purpose and per-viewer grants"),
    "decision": dict(
        need=("allowed", "scope", "owner_id", "decision_id", "policy_version",
              "valid_until"),
        where="L123-135",
        why="ACCESS_DENIED; checked BEFORE any content is opened",
        note="an access-decision service, not a table of rows"),
}


def all_relations(conn):
    return conn.execute(text(
        "SELECT n.nspname, c.relname, c.relkind FROM pg_class c "
        "JOIN pg_namespace n ON n.oid=c.relnamespace "
        "WHERE n.nspname IN ('public','project1_ai') "
        "AND c.relkind IN ('r','v','m','p')")).all()


def all_columns(conn):
    rows = conn.execute(text(
        "SELECT n.nspname, c.relname, a.attname FROM pg_attribute a "
        "JOIN pg_class c ON c.oid=a.attrelid "
        "JOIN pg_namespace n ON n.oid=c.relnamespace "
        "WHERE n.nspname IN ('public','project1_ai') "
        "AND c.relkind IN ('r','v','m','p') AND a.attnum>0 AND NOT a.attisdropped")).all()
    out = {}
    for schema, table, col in rows:
        out.setdefault(f"{schema}.{table}", set()).add(col)
    return out


def count_rows(conn, relation):
    """Row count under a savepoint, so an RLS/permission failure cannot poison
    the surrounding transaction (a prior probe lost later checks to exactly this)."""
    sp = conn.begin_nested()
    try:
        n = conn.execute(text(f"SELECT count(*) FROM {relation}")).scalar()
        sp.commit()
        return n
    except Exception as exc:                      # noqa: BLE001 - reported verbatim
        sp.rollback()
        return f"UNREADABLE({type(exc).__name__})"


def candidates(cols, need, exclude=()):
    """Relations carrying every required column, minus relations that only carry
    those columns because they record the binding's *effect*."""
    return sorted(rel for rel, have in cols.items()
                  if need and rel not in exclude and all(x in have for x in need))


def main() -> int:
    engine = create_engine(settings.m2_database_url.get_secret_value(),
                           hide_parameters=True)
    structural, operational = {}, {}

    with engine.connect() as conn:
        tx = conn.begin()
        conn.execute(text("SELECT set_config('project1.actor_id', :a, true)"),
                     {"a": str(ACTOR)})
        rels, cols = all_relations(conn), all_columns(conn)

        conf = conn.execute(text(
            "SELECT id, assessment_revision, actor_user_id FROM m2_confirmation_snapshots "
            "WHERE assessment_id=:a AND assessment_revision=:r"),
            {"a": ASSESSMENT, "r": REV}).mappings().all()
        live_conf = conf[0]["id"] if len(conf) == 1 else None

        print(f"assessment={ASSESSMENT} rev={REV} actor={ACTOR}")
        print(f"relations: {len(rels)} across public + project1_ai")
        print(f"live confirmation at rev {REV}: {live_conf} "
              f"({len(conf)} row(s) -> {'unique' if live_conf else 'NOT UNIQUE'})")
        print()

        for name, spec in REQUIRED.items():
            exclude = set(spec.get("exclude", ()))
            need, hits = spec["need"], candidates(cols, spec["need"], exclude)
            if not need:
                # No single relation is expected to hold the binding (it is a
                # registry or a service). Report where the indicative columns
                # actually live so the negative is measured, not asserted.
                probe = set(spec.get("probe", ()))
                where = {rel: sorted(probe & have)
                         for rel, have in cols.items()
                         if probe and rel not in exclude and probe & have}
                full = [rel for rel, have in where.items() if len(have) == len(probe)]
                if full:
                    structural[name] = (True, f"candidate registries={sorted(full)}")
                else:
                    partial = ", ".join(f"{rel}{have}" for rel, have in sorted(where.items()))
                    excluded = f" (excluded {sorted(exclude)})" if exclude else ""
                    structural[name] = (
                        False,
                        f"no registry carries {sorted(probe)}; indicative columns "
                        f"appear only as: {partial or 'nowhere'}{excluded}")
                continue
            if not hits:
                structural[name] = (False, "no relation carries all "
                                           f"{len(need)} required fields")
                continue
            # A candidate must also be non-empty and scoped to the live confirmation.
            best = None
            for rel in hits:
                n = count_rows(conn, rel)
                if isinstance(n, str) or n == 0:
                    continue
                if "confirmation_id" in cols[rel] and live_conf is not None:
                    sp = conn.begin_nested()
                    try:
                        linked = conn.execute(text(
                            f"SELECT count(*) FROM {rel} WHERE confirmation_id=:c"),
                            {"c": live_conf}).scalar()
                        sp.commit()
                    except Exception:             # noqa: BLE001
                        sp.rollback()
                        linked = 0
                    if not linked:
                        continue
                best = (rel, n)
                break
            if best:
                structural[name] = (True, f"{best[0]}: rows={best[1]}, "
                                          f"linked to live confirmation")
            else:
                structural[name] = (False, f"candidate(s) {hits} exist but are empty "
                                           "or not linked to the live confirmation")

        # --- OPERATIONAL: what the wired composition can actually obtain --------
        from sitewise.repositories.m2_context_bindings import M2ContextBindings
        try:
            # A live session is required to resolve real M2 rows; this probe holds
            # a rolled-back audit transaction, so it reports the wired resolver
            # rather than claiming a resolved binding it did not obtain.
            operational["ALL"] = (False, "resolver=M2ContextBindings "
                f"(M2-backed); probe requires a live session, code={M2ContextBindings.__name__}")
        except Exception as exc:                  # noqa: BLE001
            operational["ALL"] = (False, f"resolver import failed: {exc}")

        receipt = conn.execute(text(
            "SELECT status, last_code, context_id, attempt_count "
            "FROM m2_business_context_builds WHERE confirmation_id=:c"),
            {"c": live_conf}).mappings().all() if live_conf else []

        tx.rollback()

    print("STRUCTURAL — authoritative source exists with the full builder field set")
    for name, (ok, detail) in structural.items():
        print(f"  {'YES ' if ok else 'NO  '} {name:34s} {detail}")
    s_ok = sum(1 for v in structural.values() if v[0])
    print(f"  -> structural={s_ok}/{len(structural)}")

    print()
    print("OPERATIONAL — obtainable through the wired production composition")
    for name, (ok, detail) in operational.items():
        print(f"  {'YES ' if ok else 'NO  '} {name:34s} {detail}")
    o_ok = sum(1 for v in operational.values() if v[0]) * len(structural)
    print(f"  -> operational={o_ok}/{len(structural)} "
          "(every binding is gated behind one resolver)")

    print()
    print("PERSISTED BUILD RECEIPT for this confirmation")
    if not receipt:
        print("  none")
    for r in receipt:
        print(f"  status={r['status']} last_code={r['last_code']} "
              f"context_id={r['context_id']} attempt_count={r['attempt_count']}")

    print()
    print(f"STRUCTURAL={s_ok}/{len(structural)} OPERATIONAL={o_ok}/{len(structural)}")
    print("VERDICT=" + ("READY" if o_ok == len(structural) else "BLOCKED"))
    return 0 if o_ok == len(structural) else 1


if __name__ == "__main__":
    raise SystemExit(main())
