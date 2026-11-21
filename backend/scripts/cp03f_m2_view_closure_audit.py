"""CP-03F: full privilege/RLS audit of the `m2_workflow_summary` dependency closure.

A hand-written list of objects is how M2-WRITE-01 survived two rounds of grants:
`m2_workflow_campaigns` is replaced by the CQ bridge (migration 20261115_03) and
reaches four `cq_*` tables that no list mentioned. So the closure is computed from
the catalog instead: start at the two `security_invoker` views and follow the
`_RETURN` rewrite rules' relation dependencies recursively.

For every relation reached, report whether `p1_m2_runtime` may SELECT it, whether
RLS is on, and whether RLS actually scopes rows to the calling owner. A relation
that is readable but not owner-scoped is a cross-owner read path, which matters
because `m2_workflow_campaigns` is directly queryable, not only through the
summary view.

Read-only.
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "src"))

from sqlalchemy import create_engine, text  # noqa: E402

from sitewise.core.config import settings  # noqa: E402

ROLE = "p1_m2_runtime"
ROOTS = ["public.m2_workflow_summary", "public.m2_workflow_campaigns"]

CLOSURE = text("""
WITH RECURSIVE walk(rel) AS (
  SELECT unnest(CAST(:roots AS regclass[]))
  UNION
  SELECT dep.refobjid
    FROM walk w
    JOIN pg_rewrite rw ON rw.ev_class = w.rel AND rw.rulename = '_RETURN'
    JOIN pg_depend dep ON dep.objid = rw.oid
                      AND dep.classid = 'pg_rewrite'::regclass
                      AND dep.refclassid = 'pg_class'::regclass
)
SELECT c.relname, c.relkind::text AS kind,
       has_table_privilege(:role, c.oid, 'SELECT') AS sel,
       c.relrowsecurity AS rls, c.relforcerowsecurity AS forced,
       (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid) AS pol,
       coalesce((SELECT string_agg(pg_get_expr(p.polqual, p.polrelid), ' | ')
                   FROM pg_policy p WHERE p.polrelid = c.oid), '') AS quals
  FROM walk w
  JOIN pg_class c ON c.oid = w.rel
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public'
 ORDER BY c.relname
""")


def main() -> int:
    engine = create_engine(settings.m2_database_url.get_secret_value())
    with engine.connect() as conn:
        rows = conn.execute(CLOSURE, {"roots": ROOTS, "role": ROLE}).all()

    print(f"dependency closure of {', '.join(ROOTS)}")
    print(f"role: {ROLE}\n")
    hdr = f"{'relation':36} {'kind':4} {'sel':4} {'rls':4} {'pol':4} scoped"
    print(hdr)
    print("-" * 92)
    missing: list[str] = []
    unscoped: list[str] = []
    for r in rows:
        qual = " ".join(r.quals.split())
        scoped = ("actor_id" in qual) or ("m2_assessments" in qual) or ("m2_confirmed" in qual) \
                 or ("m2_review_question" in qual) or ("m2_confirmation" in qual) or ("true" == qual)
        print(f"{r.relname:36} {r.kind:4} {str(r.sel)[0]:4} {str(r.rls)[0]:4} {r.pol:<4} "
              f"{'yes' if scoped else 'NO'}   {qual[:70]}")
        if not r.sel:
            missing.append(r.relname)
        if not r.rls and r.kind == "r":
            unscoped.append(r.relname)

    print()
    print("MISSING SELECT :", ", ".join(missing) or "(none)")
    print("RLS DISABLED   :", ", ".join(unscoped) or "(none)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
