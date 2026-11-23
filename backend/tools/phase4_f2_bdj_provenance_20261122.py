"""Phase F2 - provenance of non-zero BDJ objective rows.

The Phase F matrix reported FAILED for "no fabricated findings, proposals,
decisions or admissions" because it counted the BDJ objective tables
globally. This probe establishes, per row, which assessment it belongs to,
when it was written and by which principal, so the failure can be
characterised as either (a) rows created by this session's synthetic
admission-contract test, or (b) rows fabricated against the Stage 3 subject.

Read-only. Connects to project1_workflow_tests@5433 only.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import psycopg2

BACKEND = Path(__file__).resolve().parents[1]
ROOT = BACKEND.parent
OUT = ROOT / "deliverables" / "phase4"

STAGE3_ASSESSMENT = "37bf879a-005a-4f5a-b49d-210ea1ce37c4"
STAGE3_M2 = "032d3dde-547f-49a6-9e0f-58fbc5f1a48f"

TEXT = (BACKEND / "var" / "e2e" / "app.env").read_text(encoding="utf-8", errors="replace")


def dsn(key: str) -> str:
    url = re.search(rf"^{key}=(.+)$", TEXT, re.M).group(1).strip()
    return url.replace("postgresql+psycopg2", "postgresql")


def admin_dsn() -> str:
    """Privileged read-only session for provenance inspection.

    The admin credential in backend/.env points at a different database on the
    protected port; it is redirected to the authorized disposable target and
    refused unless the redirection lands exactly there.
    """
    from sqlalchemy.engine import make_url

    lines = (BACKEND / ".env").read_text(encoding="utf-8", errors="ignore").splitlines()
    raw = next(line.split("=", 1)[1].strip() for line in lines if line.startswith("DATABASE_URL="))
    url = make_url(raw)
    if url.get_backend_name() != "postgresql" or url.host not in {"localhost", "127.0.0.1"}:
        raise SystemExit("REFUSED: configured host is not local")
    target = url.set(port=5433, database="project1_workflow_tests")
    if (target.port != 5433 or target.database != "project1_workflow_tests"
            or target.database in {"Dss", "Final_Location_Analysis"}):
        raise SystemExit("REFUSED: not the authorized disposable target")
    return target.render_as_string(hide_password=False).replace(
        "postgresql+psycopg2://", "postgresql://", 1)


TABLES = [
    "m2_bdj_evaluations",
    "m2_bdj_findings",
    "m2_bdj_objective_proposals",
    "m2_bdj_objective_decisions",
    "m2_bdj_objective_admissions",
]


def columns(cur, table: str) -> list[str]:
    cur.execute(
        """
        select column_name from information_schema.columns
         where table_schema='public' and table_name=%s
         order by ordinal_position
        """,
        (table,),
    )
    return [r[0] for r in cur.fetchall()]


def main() -> int:
    report: dict = {
        "checkpoint": "PHASE_F2_BDJ_PROVENANCE",
        "target": {"database": "project1_workflow_tests", "port": 5433},
        "stage3_subject": {"assessment_id": STAGE3_ASSESSMENT, "m2_assessment_id": STAGE3_M2},
        "tables": {},
    }

    with psycopg2.connect(dsn("M2_DATABASE_URL")) as conn:
        conn.autocommit = True
        cur = conn.cursor()
        cur.execute("select current_user, current_database(), inet_server_port()")
        report["principal"] = dict(zip(("user", "database", "port"), cur.fetchone()))

        for table in TABLES:
            entry: dict = {}
            try:
                cols = columns(cur, table)
                entry["columns"] = cols
                # count via pg_class to avoid RLS masking the true row count
                cur.execute(
                    "select reltuples::bigint from pg_class where oid = %s::regclass", (table,)
                )
                entry["reltuples"] = cur.fetchone()[0]

                try:
                    cur.execute(f"select count(*) from public.{table}")
                    entry["visible_count"] = cur.fetchone()[0]
                except Exception as exc:  # permission denied is itself evidence
                    conn.rollback()
                    entry["visible_count"] = f"DENIED: {type(exc).__name__}"
            except Exception as exc:
                conn.rollback()
                entry["error"] = f"{type(exc).__name__}: {exc}"
            report["tables"][table] = entry

    # Provenance requires bypassing RLS, so this read runs as the cluster
    # administrator against the disposable target. SELECT only; no writes.
    prov: dict = {}
    with psycopg2.connect(admin_dsn()) as conn:
        conn.autocommit = True
        cur = conn.cursor()
        cur.execute("select current_user, current_database(), inet_server_port()")
        report["provenance_principal"] = cur.fetchone()

        probes = {
            "m2_bdj_objective_proposals": (
                "select proposal_id::text, assessment_id::text, review_state, "
                "owner_user_id::text, execution_mode, validation_status, created_at "
                "from public.m2_bdj_objective_proposals order by created_at"
            ),
            "m2_bdj_objective_decisions": (
                "select decision_id::text, proposal_id::text, decision, "
                "decided_by::text, decided_at "
                "from public.m2_bdj_objective_decisions order by decided_at"
            ),
            "m2_bdj_objective_admissions": (
                "select admission_id::text, proposal_id::text, assessment_id::text, "
                "decision, actor_user_id::text, created_at "
                "from public.m2_bdj_objective_admissions order by created_at"
            ),
        }
        for name, sql in probes.items():
            try:
                cur.execute(sql)
                rows = cur.fetchall()
                heads = [d[0] for d in cur.description]
                prov[name] = [dict(zip(heads, r)) for r in rows]
            except Exception as exc:
                conn.rollback()
                prov[name] = f"{type(exc).__name__}: {exc}"

        # Scope check: does any BDJ objective row belong to the Stage 3 subject?
        cur.execute(
            """
            select 'proposals' as t, count(*) from public.m2_bdj_objective_proposals
             where assessment_id in (%s::uuid, %s::uuid)
            union all
            select 'admissions', count(*) from public.m2_bdj_objective_admissions
             where assessment_id in (%s::uuid, %s::uuid)
            """,
            (STAGE3_ASSESSMENT, STAGE3_M2, STAGE3_ASSESSMENT, STAGE3_M2),
        )
        report["stage3_scoped_counts"] = dict(cur.fetchall())

        # Authoritative totals. reltuples is an estimate (it reported 6 for a
        # table holding 8 rows), so the runtime-visible counts above are not
        # evidence of absence.
        totals = {}
        for table in TABLES:
            cur.execute(f"select count(*) from public.{table}")
            totals[table] = cur.fetchone()[0]
        report["admin_totals"] = totals

        # Who owns the assessments the BDJ objective rows are attached to?
        cur.execute(
            """
            select m.id::text, m.owner_user_id::text, m.revision
              from public.m2_assessments m
             where m.id in (
                   select distinct assessment_id from public.m2_bdj_objective_proposals
                   union
                   select distinct assessment_id from public.m2_bdj_objective_admissions)
             order by 1
            """
        )
        report["bdj_assessment_owners"] = [dict(zip(("m2_assessment_id", "owner_user_id", "revision"), r))
                                           for r in cur.fetchall()]

    report["provenance"] = prov
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "f2_bdj_provenance.json").write_text(
        json.dumps(report, indent=2, default=str), encoding="utf-8"
    )
    print(json.dumps(report, indent=2, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
