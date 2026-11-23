"""Phase A1b — privilege and actor-scope probe.

`information_schema.role_table_grants` only shows grants where the current user
is grantor or grantee, so it under-reports what `p1_m2_runtime` holds. The
`has_table_privilege()` family reports ground truth for any role and is the only
sound basis for a privilege verdict.

Also answers the A2 security question directly: is
`owner_user_id = project1_actor()` equivalent to the literal expression the
migration guard greps for, and can the helper be used to impersonate?
"""
from __future__ import annotations

import json
import re
from pathlib import Path

import psycopg2

ENV = Path(__file__).resolve().parents[1] / "var" / "e2e" / "app.env"
SEEDED_ACTOR = "b9e62014-b7bc-426e-a950-a95b25965639"

TABLES = [
    "m2_assessments",
    "m2_assessment_links",
    "m2_confirmation_snapshots",
    "m2_research_objective_sources",
    "m2_research_clarifications",
    "m2_research_revisions",
    "m2_desired_options",
    "m2_candidate_owner_reviews",
    "m2_review_question_versions",
    "m2_confirmed_uncertainties",
]
PRIVS = ["SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER"]


def dsn() -> str:
    text = ENV.read_text(encoding="utf-8", errors="replace")
    url = re.search(r"^DATABASE_URL=(.+)$", text, re.M).group(1).strip()
    return url.replace("postgresql+psycopg2", "postgresql")


def main() -> int:
    out: dict = {}
    with psycopg2.connect(dsn()) as conn:
        conn.autocommit = True
        cur = conn.cursor()

        # --- ground-truth privileges per role -----------------------------
        grants: dict = {}
        for t in TABLES:
            cur.execute("select to_regclass(%s)", (f"public.{t}",))
            if cur.fetchone()[0] is None:
                grants[t] = {"exists": False}
                continue
            entry = {}
            for role in ("p1_m2_runtime", "sitewise_e2e"):
                held = []
                for p in PRIVS:
                    cur.execute(
                        "select has_table_privilege(%s, %s, %s)",
                        (role, f"public.{t}", p),
                    )
                    if cur.fetchone()[0]:
                        held.append(p)
                entry[role] = held
            grants[t] = entry
        out["privileges_ground_truth"] = grants

        # --- RLS posture ---------------------------------------------------
        rls = {}
        for t in TABLES:
            cur.execute("select to_regclass(%s)", (f"public.{t}",))
            if cur.fetchone()[0] is None:
                rls[t] = {"exists": False}
                continue
            cur.execute(
                "select relrowsecurity, relforcerowsecurity from pg_class "
                "where oid = %s::regclass",
                (f"public.{t}",),
            )
            rr, rf = cur.fetchone()
            cur.execute(
                "select policyname, cmd, qual from pg_policies "
                "where schemaname='public' and tablename=%s order by policyname",
                (t,),
            )
            pol = [{"name": a, "cmd": b, "qual": c} for a, b, c in cur.fetchall()]
            rls[t] = {
                "rls_enabled": rr,
                "rls_forced": rf,
                "select_policy_count": sum(1 for p in pol if p["cmd"] in ("SELECT", "ALL")),
                "policies": pol,
            }
        out["rls_posture"] = rls

        # --- equivalence of the helper with the literal expression ---------
        # Evaluated in one session with the GUC unset, then set to the seeded
        # actor, so both forms are compared under identical inputs.
        cur.execute("select nullif(current_setting('project1.actor_id', true), '')::uuid")
        out["equivalence"] = {"unset_helper": cur.fetchone()[0]}

        cur.execute("select set_config('project1.actor_id', %s, true)", (SEEDED_ACTOR,))
        cur.execute(
            "select project1_actor()::text, "
            "nullif(current_setting('project1.actor_id', true), '')::uuid::text"
        )
        a, b = cur.fetchone()
        out["equivalence"].update({"set_helper": a, "set_literal": b, "identical": a == b})

        # Does the policy expression behave identically when the actor matches
        # and when it is a stranger? Evaluated through the policy's own predicate.
        for label, actor in (("seeded_owner", SEEDED_ACTOR),
                             ("stranger", "00000000-0000-0000-0000-0000000000ff")):
            cur.execute("select set_config('project1.actor_id', %s, true)", (actor,))
            cur.execute(
                "select count(*) from public.m2_assessments where owner_user_id = project1_actor()"
            )
            via_helper = cur.fetchone()[0]
            cur.execute(
                "select count(*) from public.m2_assessments where owner_user_id = "
                "nullif(current_setting('project1.actor_id', true), '')::uuid"
            )
            via_literal = cur.fetchone()[0]
            out.setdefault("predicate_behaviour", {})[label] = {
                "via_helper": via_helper,
                "via_literal": via_literal,
                "identical": via_helper == via_literal,
            }

        # --- impersonation reachability ------------------------------------
        # A non-superuser role that can set the GUC can read another owner's
        # rows. Record what the *runtime* role is actually allowed to do.
        cur.execute("select set_config('project1.actor_id', %s, true)", (SEEDED_ACTOR,))
        cur.execute(
            "select current_user, current_setting('project1.actor_id', true), "
            "has_function_privilege(current_user, 'public.project1_actor()', 'EXECUTE')"
        )
        cu, guc, can_exec = cur.fetchone()
        out["impersonation"] = {
            "session_user": cu,
            "actor_guc_readable_by_caller": guc == SEEDED_ACTOR,
            "project1_actor_executable": can_exec,
            "note": (
                "project1.actor_id is a placeholder GUC: any role may set it to any "
                "uuid. Owner isolation therefore rests on the application setting it "
                "from the verified token, not on the database."
            ),
        }

        # --- owner-scoped visibility of the confirmation chain -------------
        chain = {}
        for t in ("m2_assessment_links", "m2_confirmation_snapshots"):
            try:
                cur.execute("select count(*) from public.%s" % t)
                chain[t] = cur.fetchone()[0]
            except psycopg2.errors.InsufficientPrivilege:
                conn.rollback()
                chain[t] = "DENIED"
        out["owner_scoped_counts"] = chain

    print(json.dumps(out, indent=2, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
