"""CP-03F: enumerate what `m2_workflow_summary` needs from `p1_m2_runtime`.

`m2_workflow_summary` and `m2_workflow_campaigns` are `security_invoker=true`
(migration 20261115_02, lines 25 and 28). That is deliberate: it keeps row-level
security on the underlying tables authoritative for the calling role instead of
bypassing it via the view owner. The cost is that the caller needs SELECT on
every object the view touches, and RLS must actually scope each of them.

This probe reports, per object in the view chain:
  * whether `p1_m2_runtime` already has SELECT,
  * whether RLS is enabled/forced,
  * how many policies exist and whether any keys on `project1.actor_id`.

Read-only. No grants are issued here; the output drives the migration.
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "src"))

from sqlalchemy import text  # noqa: E402

from sitewise.core.config import settings  # noqa: E402

ROLE = "p1_m2_runtime"

# Every relation named in the m2_workflow_summary definition, plus the view
# itself and the projection table written by refresh_m2_workflow.
OBJECTS = [
    ("view", "m2_workflow_summary"),
    ("view", "m2_workflow_campaigns"),
    ("table", "assessment_workflow_projection"),
    ("table", "m2_assessments"),
    ("table", "m2_instrument_versions"),
    ("table", "m2_review_events"),
    ("table", "m2_clarification_events"),
    ("table", "m2_confirmation_snapshots"),
    ("table", "m2_business_contexts"),
    ("table", "m2_business_context_builds"),
    ("table", "m2_bdj_evaluations"),
    ("table", "m2_bdj_findings"),
    ("table", "m2_confirmed_uncertainties"),
    ("table", "m2_research_objective_sources"),
    ("table", "m2_research_clarifications"),
    ("table", "m2_research_revisions"),
    ("table", "m2_review_question_versions"),
    ("table", "m2_desired_options"),
    ("table", "m2_candidate_owner_reviews"),
]

PRIV_SQL = text("""
SELECT c.relkind::text AS kind,
       c.relrowsecurity AS rls,
       c.relforcerowsecurity AS forced,
       has_table_privilege(:role, c.oid, 'SELECT') AS can_select,
       has_table_privilege(:role, c.oid, 'INSERT') AS can_insert,
       (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid) AS policies,
       (SELECT count(*) FROM pg_policy p
         WHERE p.polrelid = c.oid
           AND pg_get_expr(p.polqual, p.polrelid) LIKE '%project1.actor_id%') AS actor_policies,
       pg_get_userbyid(c.relowner) AS owner
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND c.relname = :name
""")


def main() -> int:
    from sqlalchemy import create_engine

    engine = create_engine(settings.m2_database_url.get_secret_value())
    print(f"role under test: {ROLE}\n")
    header = f"{'object':38} {'kind':5} {'sel':4} {'ins':4} {'rls':4} {'frc':4} {'pol':4} {'actor':5} owner"
    print(header)
    print("-" * len(header))
    missing_select: list[str] = []
    unscoped: list[str] = []
    with engine.connect() as conn:
        for _kind, name in OBJECTS:
            row = conn.execute(PRIV_SQL, {"role": ROLE, "name": name}).first()
            if row is None:
                print(f"{name:38} {'MISSING':5}")
                continue
            kind, rls, forced, sel, ins, pol, actor, owner = row
            print(f"{name:38} {kind:5} {str(sel)[0]:4} {str(ins)[0]:4} "
                  f"{str(rls)[0]:4} {str(forced)[0]:4} {pol:<4} {actor:<5} {owner}")
            if not sel:
                missing_select.append(name)
            # A relation that the caller reads but which has RLS with no
            # actor-keyed policy is either default-deny (safe, blocks reads) or
            # has a policy that does not scope by actor (unsafe).
            if rls and actor == 0:
                unscoped.append(name)

    print()
    print("MISSING SELECT:", ", ".join(missing_select) or "(none)")
    print("RLS WITHOUT ACTOR POLICY:", ", ".join(unscoped) or "(none)")

    # Cross-check: what the runtime role can actually see right now.
    print("\n--- runtime-visible row counts (RLS applies) ---")
    with engine.connect() as conn:
        conn.execute(text("SET ROLE " + ROLE))
        for _kind, name in OBJECTS:
            try:
                n = conn.execute(text(f"SELECT count(*) FROM public.{name}")).scalar()
                print(f"  {name:38} {n}")
            except Exception as exc:  # noqa: BLE001 - the denial is the datum
                print(f"  {name:38} DENIED: {str(exc).splitlines()[0][:90]}")
        conn.rollback()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
