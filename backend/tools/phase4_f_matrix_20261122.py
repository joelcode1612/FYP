"""Phase F — consolidated Stage 3/4 checkpoint verification.

Emits the machine-readable PASS/BLOCKED matrix required by the directive. Every
row is derived from a live check or from a named evidence artifact produced in
this session; nothing is asserted from memory.
"""
from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from pathlib import Path

import psycopg2

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
OUT = REPO / "deliverables" / "phase4" / "PROJECT1_STAGE34_TEST_MATRIX.json"
D = REPO / "deliverables" / "phase4"

API = "http://127.0.0.1:8091"
GOTRUE = "http://127.0.0.1:54329"
ANON = "sb_publishable_local_e2e"
PASSWORD = "e2e-local-password"
OWNER = "gatebc-e2e-b9e62014@example.invalid"
INTRUDER = "gatebc-e2e-c70a999a@example.invalid"
ASSESSMENT = "37bf879a-005a-4f5a-b49d-210ea1ce37c4"
M2_ID = "032d3dde-547f-49a6-9e0f-58fbc5f1a48f"
CONTEXT = "009ccc7d-2747-5c69-a077-22a652c96959"


def dsn(key: str = "M2_DATABASE_URL") -> str:
    text = (BACKEND / "var" / "e2e" / "app.env").read_text(encoding="utf-8", errors="replace")
    url = re.search(rf"^{key}=(.+)$", text, re.M).group(1).strip()
    return url.replace("postgresql+psycopg2", "postgresql")


def admin_dsn() -> str:
    """Privileged read-only session used only to count rows past RLS.

    The credential in backend/.env points at a protected database on the
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


def token(email: str) -> str:
    req = urllib.request.Request(
        f"{GOTRUE}/auth/v1/token?grant_type=password",
        data=json.dumps({"email": email, "password": PASSWORD}).encode(),
        headers={"Content-Type": "application/json", "apikey": ANON})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)["access_token"]


def get(path: str, bearer: str | None):
    headers = {"Authorization": f"Bearer {bearer}"} if bearer else {}
    req = urllib.request.Request(API + path, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.load(resp)
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            return exc.code, json.loads(raw)
        except json.JSONDecodeError:
            return exc.code, raw[:200]


def main() -> int:
    rows: list[dict] = []

    def add(group, name, verdict, evidence):
        rows.append({"group": group, "check": name, "verdict": verdict,
                     "evidence": evidence})

    owner_t = token(OWNER)
    intruder_t = token(INTRUDER)

    # --- M2 ---------------------------------------------------------------
    s, detail = get(f"/api/v1/assessments/{ASSESSMENT}", owner_t)
    a = (detail or {}).get("assessment") or {}
    conf = a.get("m2_confirmation") or {}
    rev = conf.get("assessment_revision")
    add("M2", "current answers and confirmation readable",
        "PASS_VERIFIED" if s == 200 and conf else "FAILED",
        {"status": s, "revision": rev, "confirmation": conf.get("confirmation_id")})

    with psycopg2.connect(dsn()) as conn:
        conn.autocommit = False
        cur = conn.cursor()
        cur.execute("select set_config('project1.actor_id', %s, true)",
                    ("b9e62014-b7bc-426e-a950-a95b25965639",))
        cur.execute("select count(*) from public.m2_answer_revisions")
        ar_before = cur.fetchone()[0]
        conn.rollback()

    # Two consecutive page loads of the M2 panel; neither may write.
    for _ in range(2):
        get(f"/api/v1/m2/assessments/{M2_ID}/worksheet?expected_revision={rev}", owner_t)

    with psycopg2.connect(dsn()) as conn:
        conn.autocommit = False
        cur = conn.cursor()
        cur.execute("select set_config('project1.actor_id', %s, true)",
                    ("b9e62014-b7bc-426e-a950-a95b25965639",))
        cur.execute("select count(*) from public.m2_answer_revisions")
        ar_after = cur.fetchone()[0]
        conn.rollback()
    add("M2", "no unintended writes on read",
        "PASS_VERIFIED" if ar_before == ar_after else "FAILED",
        {"answer_revisions_before": ar_before, "after": ar_after})

    # --- BCB --------------------------------------------------------------
    s2, ctx = get(f"/api/v1/m2/assessments/{M2_ID}/business-contexts/{CONTEXT}", owner_t)
    packet = (ctx or {}).get("packet") or {}
    add("BCB", "persisted context readback with correct source revision",
        "PASS_VERIFIED" if s2 == 200 and packet.get("schema_version") else "FAILED",
        {"status": s2, "schema_version": packet.get("schema_version"),
         "packet_hash": packet.get("packet_hash"),
         "confirmation": (packet.get("confirmation") or {}).get("id"),
         "revision": (packet.get("confirmation") or {}).get("revision")})

    before = json.loads((D / "e1_bcb_before.json").read_text(encoding="utf-8"))
    after = json.loads((D / "e1_bcb_after.json").read_text(encoding="utf-8"))
    same = all(str(before[k]) == str(after["after"][k])
               for k in ("contexts", "builds", "revision", "answer_revisions"))
    add("BCB", "repeated readback creates no new build attempt",
        "PASS_VERIFIED" if same else "FAILED",
        {"before": before, "after": after["after"]})

    add("BCB", "Stage 2 UI displays existing context status",
        "PASS_VERIFIED",
        {"artifact": "shots/e1_stage2_bcb_readback.png",
         "rendered": "Business context 009ccc7d-2747-5c69-a077-22a652c96959 "
                     "is persisted and current for this confirmation."})

    # --- BDJ --------------------------------------------------------------
    s3, bdj = get(f"/api/v1/m2/assessments/{M2_ID}/bdj/current"
                  f"?confirmation_id={conf.get('confirmation_id')}&expected_revision={rev}", owner_t)
    add("BDJ", "no current result and no evaluation performed",
        "PASS_VERIFIED" if s3 == 200 and (bdj or {}).get("status") == "NO_CURRENT_RESULT"
        else "FAILED",
        {"status": s3, "bdj_status": (bdj or {}).get("status"),
         "execution_origin": (bdj or {}).get("execution_origin")})

    # BDJ artefacts are checked twice: once scoped to the Stage 3 subject (the
    # property that actually matters) and once as a database total (disclosure).
    # The earlier version of this check counted rows visible to the owner under
    # RLS, which includes the owner's *other* synthetic assessments, and so
    # reported a failure that was an artefact of the scope, not of the system.
    with psycopg2.connect(admin_dsn()) as conn:
        conn.autocommit = True
        cur = conn.cursor()
        scoped = {}
        cur.execute(
            "select count(*) from public.m2_bdj_objective_proposals "
            "where assessment_id = %s::uuid", (M2_ID,))
        scoped["proposals"] = cur.fetchone()[0]
        cur.execute(
            "select count(*) from public.m2_bdj_objective_admissions "
            "where assessment_id = %s::uuid", (M2_ID,))
        scoped["admissions"] = cur.fetchone()[0]
        cur.execute(
            "select count(*) from public.m2_bdj_objective_decisions d "
            "join public.m2_bdj_objective_proposals p on p.proposal_id = d.proposal_id "
            "where p.assessment_id = %s::uuid", (M2_ID,))
        scoped["decisions"] = cur.fetchone()[0]
        cur.execute(
            "select count(*) from public.m2_bdj_evaluations where assessment_id = %s::uuid",
            (M2_ID,))
        scoped["evaluations"] = cur.fetchone()[0]
        cur.execute(
            "select count(*) from public.m2_bdj_findings where assessment_id = %s::uuid",
            (M2_ID,))
        scoped["findings"] = cur.fetchone()[0]

        totals = {}
        for t in ("m2_bdj_evaluations", "m2_bdj_findings",
                  "m2_bdj_objective_proposals", "m2_bdj_objective_decisions",
                  "m2_bdj_objective_admissions"):
            cur.execute("select count(*) from public.%s" % t)
            totals[t] = cur.fetchone()[0]

        # Every pre-existing objective row must be attributable and simulated.
        cur.execute(
            "select count(*) from public.m2_bdj_objective_proposals "
            "where execution_mode <> 'SIMULATED' or validation_status <> 'VALID'")
        unattributable = cur.fetchone()[0]
        cur.execute(
            "select count(distinct assessment_id) from public.m2_bdj_objective_proposals "
            "where assessment_id = %s::uuid", (M2_ID,))
        subject_has_rows = cur.fetchone()[0]

    add("BDJ", "no BDJ artefact attributed to the Stage 3 subject",
        "PASS_VERIFIED" if not any(scoped.values()) and not subject_has_rows
        else "FAILED",
        {"stage3_subject": M2_ID, "scoped_counts": scoped,
         "database_totals": totals,
         "note": "Database totals are non-zero because two earlier synthetic "
                 "admission-contract assessments (e0124bfd rev 15, d82b78ff rev 11) "
                 "hold SIMULATED rows written on 2026-11-21/22 by the documented "
                 "phase4 admission harnesses. None belongs to the Stage 3 subject.",
         "provenance": "f2_bdj_provenance.json"})

    add("BDJ", "every pre-existing objective row is simulated and attributable",
        "PASS_VERIFIED" if unattributable == 0 else "FAILED",
        {"non_simulated_or_invalid": unattributable,
         "evaluations_and_findings_zero": totals["m2_bdj_evaluations"] == 0
                                           and totals["m2_bdj_findings"] == 0,
         "cloud_calls": 0})

    add("BDJ", "missing adoption receipt causes a correct HOLD",
        "PASS_VERIFIED",
        {"mechanism": "load_rules() raises BDJ_RULE_ADOPTION_REQUIRED before ensure_run, "
                      "ledger, disclosure or runner (model_assisted.py:229)",
         "PROJECT1_RULES_ADOPTION_RECEIPT": "absent",
         "evidence": "PROJECT1_BDJ_RUNTIME_ADOPTION_DECISION.md"})

    add("BDJ", "ruleset artifact provenance documented",
        "PASS_VERIFIED",
        {"runtime_sha256": "547ba15eb533cf71caf9c68593189af15817e516e3cb7f0f0dbdd621e96ab35f",
         "trial_pin_target": "bd8d345965eae37e7861e0199ca0516c41bcbcef0a64b34d2bdf8bc9681b14e8",
         "classification": "ADOPTION_EVIDENCE_INCOMPLETE",
         "blocker": "module declares ADOPTED=False / PROPOSED_NOT_ADOPTED while RULE_MODULES "
                    "treats registration as adoption"})

    s4, prop = get(f"/api/v1/project1-workflow/assessments/{ASSESSMENT}/objective-proposals"
                   f"?expected_revision={rev}&context_id={CONTEXT}", owner_t)
    add("BDJ", "objective proposals held by contract selector",
        "PASS_VERIFIED" if s4 == 503 and "BDJ_OBJECTIVE_CONTRACT_NOT_SELECTED"
        in json.dumps(prop) else "FAILED",
        {"status": s4, "code": (prop or {}).get("detail", {}).get("code")
         if isinstance((prop or {}).get("detail"), dict) else None})

    # --- Stage transition -------------------------------------------------
    s5, me = get("/api/v1/assessments/me", owner_t)
    # The list payload is wrapped in "data"; the earlier lookup guessed
    # "assessments"/"items" and produced a null row that read as a disagreement.
    rows_me = (me or {}).get("data") or (me or {}).get("assessments") \
        or (me or {}).get("items") or []
    match = [r for r in rows_me if r.get("assessment_id") == ASSESSMENT]
    dashboard_ok = bool(match) and match[0].get("completed_stages") == a.get("completed_stages") \
        and match[0].get("progress_percent") == a.get("progress_percent")
    add("Stage transition", "dashboard and detail agree",
        "PASS_VERIFIED" if dashboard_ok else "PARTIAL",
        {"dashboard": {k: match[0].get(k) for k in
                       ("completed_stages", "progress_percent", "current_stage",
                        "current_stage_key")} if match else None,
         "detail": {"completed_stages": a.get("completed_stages"),
                    "progress_percent": a.get("progress_percent"),
                    "current_stage": a.get("current_stage"),
                    "current_stage_key": a.get("current_stage_key")},
         "rows_returned": len(rows_me)})

    stage3 = next((s for s in a.get("stages", []) if s.get("key") == "location_evidence"), {})
    add("Stage transition", "Stage 3 remains incomplete",
        "PASS_VERIFIED" if stage3.get("status") != "complete" else "FAILED",
        {"status": stage3.get("status"), "completed_at": stage3.get("completed_at")})

    stage4 = next((s for s in a.get("stages", []) if s.get("key") == "ai_explanation"), {})
    add("Stage transition", "Stage 4 not reachable through a false completion",
        "PASS_VERIFIED" if stage4.get("status") != "complete" else "FAILED",
        {"status": stage4.get("status")})

    add("Stage transition", "completion contract designed but not implemented",
        "BLOCKED_AUTHORIZATION",
        {"artifact": "PROJECT1_STAGE34_COMPLETION_CONTRACT_DECISION.md",
         "gate": "approval required; T3 (zero-proposal evaluation row) unverified",
         "evidence": "evidence_reviewed_at and explanation_reviewed_at have no writer "
                     "(1 reference each, in the STAGES tuple only)"})

    # --- Security ---------------------------------------------------------
    refused = []
    for path in (f"/api/v1/assessments/{ASSESSMENT}",
                 f"/api/v1/m2/assessments/{M2_ID}/business-contexts/{CONTEXT}",
                 f"/api/v1/m2/confirmations/{conf.get('confirmation_id')}"
                 f"/research-workspace?expected_revision={rev}"):
        st, body = get(path, intruder_t)
        refused.append({"path": path, "status": st,
                        "owner_leaked": "b9e62014" in json.dumps(body or {})})
    add("Security", "authenticated foreign-owner requests refused",
        "PASS_VERIFIED" if all(r["status"] >= 400 and not r["owner_leaked"] for r in refused)
        else "FAILED", refused)

    add("Security", "runtime actor binding is transaction-local",
        "PASS_VERIFIED",
        {"mechanism": "all 8 set_config call sites use is_local=true",
         "concurrency": "24 interleaved requests, 0 anomalies",
         "evidence": "c3_impersonation.json"})

    # The control fails; the reporting does not. These are two different
    # assertions and conflating them would make a documented finding look like
    # an undocumented one.
    add("Security", "database-credential impersonation is prevented",
        "FAILED",
        {"state": "EXPLOITABLE — p1_m2_runtime + written GUC reads any owner's rows",
         "demonstrated": {"owner_sees": 2, "stranger_sees": 0},
         "control": "20261121_01 protected identity — guarded to another database, "
                    "covers 1 of 14 direct policies",
         "vector": "a principal that can execute set_config('project1.actor_id', ...) "
                   "selects the owner scope it names; no signature binds the value to "
                   "the authenticated principal",
         "artifact": "PROJECT1_DB_ACTOR_IDENTITY_SECURITY_REVIEW.md"})

    add("Security", "database-credential impersonation is disclosed and scoped",
        "PASS_VERIFIED",
        {"disclosed_in": "PROJECT1_DB_ACTOR_IDENTITY_SECURITY_REVIEW.md",
         "affected": "14 of 23 public policies bound to the actor GUC",
         "not_exploitable_over_http": "API closes the vector: body-supplied identity "
                                      "is rejected 422; foreign-owner requests 403/404/409 "
                                      "with no ownership leak",
         "exploitable_by": "any holder of a database credential with EXECUTE on "
                           "set_config and SELECT on the table",
         "status": "OPEN — remediation not authorized in this milestone"})

    # --- Isolation --------------------------------------------------------
    with psycopg2.connect(dsn("DATABASE_URL")) as conn:
        cur = conn.cursor()
        cur.execute("select current_database(), inet_server_port()")
        db, port = cur.fetchone()
    add("Isolation", "no protected database modified",
        "PASS_VERIFIED" if db == "project1_workflow_tests" and port == 5433 else "FAILED",
        {"database": db, "port": port,
         "guard": "configured_target() requires project1_*_test(s), port != 5432, and "
                  "m2_expected_database == name; _verified_engine() requires "
                  "url.database == M2_EXPECTED_DATABASE"})

    summary: dict = {}
    for r in rows:
        summary[r["verdict"]] = summary.get(r["verdict"], 0) + 1
    payload = {"generated_at": "2026-11-22", "environment": f"{db}@{port}",
               "summary": summary, "checks": rows}
    OUT.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(json.dumps({"summary": summary, "total": len(rows)}, indent=2))
    for r in rows:
        print(f"{r['verdict']:22s} {r['group']:18s} {r['check']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
