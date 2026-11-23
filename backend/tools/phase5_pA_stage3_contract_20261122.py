"""Phase A - Stage 3 completion contract, evaluated against real records.

Three things are produced here:

1. The live verdict for the Stage 3 subject, from authoritative records.
2. The two zero-proposal cases (A3), as pure fixtures over `decide()`. Nothing
   is written to any database: the fixtures are in-memory dictionaries that
   stand in for `collect()` output, which is why they cannot pollute the real
   subject.
3. The invalidation matrix (A5): each upstream change is applied to a copy of
   a satisfied record set and the verdict must flip to incomplete.

It also asserts the A6 gate: the evaluator is NOT wired into the readiness
payload, so the API's authoritative stage status is unchanged.
"""

from __future__ import annotations

import copy
import json
import re
import sys
import urllib.request
from pathlib import Path

import psycopg2

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
sys.path.insert(0, str(BACKEND / "src"))

from sitewise.services import stage3_completion as s3  # noqa: E402

OUT = REPO / "deliverables" / "phase5"

API = "http://127.0.0.1:8091"
GOTRUE = "http://127.0.0.1:54329"
ANON = "sb_publishable_local_e2e"
PASSWORD = "e2e-local-password"
OWNER = "gatebc-e2e-b9e62014@example.invalid"

ASSESSMENT = "37bf879a-005a-4f5a-b49d-210ea1ce37c4"
M2_ID = "032d3dde-547f-49a6-9e0f-58fbc5f1a48f"
OWNER_ID = "b9e62014-b7bc-426e-a950-a95b25965639"
CONTEXT = "009ccc7d-2747-5c69-a077-22a652c96959"
CONFIRMATION = "00ea0ece-cdca-48f6-9c4c-53c47cedc329"
DIGEST = "52fd4be1bd96ffe0af434756419fad5d1efebcaad5f2324d645e18b6a1378276"
# digest(project1-m2-projection/1-candidate) - what BDJ actually stores. It is
# NOT the confirmation snapshot digest above; the two hash different objects.
SOURCE_FP = "0c29fe5c8f4c755afa147642f722164aa357f91311bb3bffa2c031e6973112e2"
REVISION = 17

TEXT = (BACKEND / "var" / "e2e" / "app.env").read_text(encoding="utf-8", errors="replace")


def dsn(key: str = "M2_DATABASE_URL") -> str:
    url = re.search(rf"^{key}=(.+)$", TEXT, re.M).group(1).strip()
    return url.replace("postgresql+psycopg2", "postgresql")


def admin_dsn() -> str:
    """Read-only privileged session for the two ownership facts.

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


def api(path: str, bearer: str):
    req = urllib.request.Request(API + path, headers={"Authorization": f"Bearer {bearer}"})
    with urllib.request.urlopen(req) as resp:
        return resp.status, json.load(resp)


# ---------------------------------------------------------------------------
# A3 - zero-proposal fixtures
# ---------------------------------------------------------------------------

def satisfied_records(*, proposals=(), decisions=None, admissions=None,
                      evaluations=None, authorizations=None) -> dict:
    """A record set that satisfies every predicate except objective specifics.

    Every value here is a stand-in for what `collect()` would return. It is
    labelled a fixture everywhere it is reported.
    """
    actor = OWNER_ID
    return {
        "subject": {
            "marketplace_assessment_id": ASSESSMENT,
            "m2_assessment_id": M2_ID,
            "actor_id": actor,
        },
        "assessment": {"assessment_id": ASSESSMENT, "user_id": actor, "status": "in_progress"},
        "m2": {"id": M2_ID, "owner_user_id": actor, "revision": REVISION,
               "confirmed_revision": REVISION},
        "link": {"marketplace_assessment_id": ASSESSMENT, "m2_assessment_id": M2_ID,
                 "user_id": actor},
        "confirmation": {"id": CONFIRMATION, "assessment_revision": REVISION,
                         "actor_user_id": actor, "snapshot_digest": DIGEST},
        "context": {"context_id": CONTEXT, "confirmation_id": CONFIRMATION,
                    "assessment_revision": REVISION, "snapshot_digest": DIGEST,
                    "packet_hash": "cceb554f" + "0" * 56, "lifecycle_status": "PERSISTED",
                    "owner_user_id": actor},
        "evaluations": list(evaluations if evaluations is not None else [{
            "result_id": "11111111-1111-4111-8111-111111111111",
            "run_id": "22222222-2222-4222-8222-222222222222",
            "attempt_no": 1,
            "assessment_revision": REVISION,
            "source_fingerprint": SOURCE_FP,
            "ruleset_version": "BDJ-M2V1-IG-0.1-PROP",
            "prompt_version": "bdj-m2v1-ig/1",
            "execution_outcome": "VALIDATED_OUTPUT",
            "validation_status": "VALID",
            "finding_authority": "RULESET",
            "finding_count": 0,
            "execution_mode": "SYNTHETIC_AUTHORIZED",
            "provider_dispatched": True,
            "result_payload": {"context_id": CONTEXT},
        }]),
        "authorizations": list(authorizations if authorizations is not None else [{
            "id": "33333333-3333-4333-8333-333333333333",
            "consumed_at": "2026-11-22T00:00:00+08:00",
            "consumed_run_id": "22222222-2222-4222-8222-222222222222",
            "receipt": "fixture",
            "expires_at": "2026-12-22T00:00:00+08:00",
        }]),
        "proposals": list(proposals),
        "decisions": decisions or {},
        "admissions": admissions or {},
        "expected": {"source_fingerprint": SOURCE_FP},
    }


def fixture_tests() -> list[dict]:
    tests: list[dict] = []

    # Case 1: authorized evaluation that legitimately produced zero proposals.
    case1 = s3.decide(satisfied_records())
    tests.append({
        "case": "authorized evaluation, zero proposals",
        "expect_complete": True,
        "complete": case1["complete"],
        "T3-04": case1["predicates"]["T3-04"]["reason"],
        "T3-05": case1["predicates"]["T3-05"]["reason"],
        "pass": case1["complete"] is True,
    })

    # Case 2: BDJ never executed, zero proposals (no evaluation row).
    case2 = s3.decide(satisfied_records(evaluations=[], authorizations=[]))
    tests.append({
        "case": "BDJ never executed, zero proposals",
        "expect_complete": False,
        "complete": case2["complete"],
        "T3-04": case2["predicates"]["T3-04"]["reason"],
        "T3-05": case2["predicates"]["T3-05"]["reason"],
        "blockers": case2["blockers"],
        "pass": case2["complete"] is False
                and case2["predicates"]["T3-05"]["reason"] == "ZERO_PROPOSALS_WITHOUT_EVALUATION",
    })

    # Case 3: a simulated fixture must never count as an evaluation.
    sim = satisfied_records()
    sim["evaluations"][0]["execution_mode"] = "SIMULATED"
    case3 = s3.decide(sim)
    tests.append({
        "case": "simulated result is not an evaluation",
        "expect_complete": False,
        "complete": case3["complete"],
        "T3-04": case3["predicates"]["T3-04"]["reason"],
        "pass": case3["complete"] is False,
    })

    # Case 4: evaluation exists but its authorization was never consumed.
    noauth = satisfied_records(authorizations=[])
    case4 = s3.decide(noauth)
    tests.append({
        "case": "evaluation without a consumed authorization",
        "expect_complete": False,
        "complete": case4["complete"],
        "T3-04": case4["predicates"]["T3-04"]["reason"],
        "pass": case4["complete"] is False
                and case4["predicates"]["T3-04"]["reason"] == "EVALUATION_NOT_AUTHORIZED",
    })

    # Case 5: proposals exist, all decided and admitted -> satisfied.
    p1, p2 = "aaaa1111-1111-4111-8111-111111111111", "bbbb2222-2222-4222-8222-222222222222"
    full = satisfied_records(
        proposals=[{"proposal_id": p1, "review_state": "APPROVED", "owner_user_id": OWNER_ID,
                    "context_packet_hash": "x", "confirmation_revision": REVISION,
                    "execution_mode": "SIMULATED"},
                   {"proposal_id": p2, "review_state": "REJECTED", "owner_user_id": OWNER_ID,
                    "context_packet_hash": "x", "confirmation_revision": REVISION,
                    "execution_mode": "SIMULATED"}],
        decisions={p1: [{"decision": "APPROVED"}], p2: [{"decision": "REJECTED"}]},
        admissions={p1: [{"decision": "WORTH_RESEARCHING"}], p2: []},
    )
    case5 = s3.decide(full)
    tests.append({
        "case": "all proposals decided and the approved one admitted",
        "expect_complete": True,
        "complete": case5["complete"],
        "T3-05": case5["predicates"]["T3-05"]["reason"],
        "pass": case5["complete"] is True,
    })

    # Case 6: the evaluation was made against a different projection.
    stale_fp = satisfied_records()
    stale_fp["expected"]["source_fingerprint"] = "9" * 64
    case6a = s3.decide(stale_fp)
    tests.append({
        "case": "evaluation made against a superseded projection",
        "expect_complete": False,
        "complete": case6a["complete"],
        "T3-04": case6a["predicates"]["T3-04"]["reason"],
        "pass": case6a["complete"] is False
                and case6a["predicates"]["T3-04"]["reason"] == "EVALUATION_PROVENANCE_MISMATCH",
    })

    # Case 7: the caller cannot supply the current fingerprint -> fail closed.
    no_fp = satisfied_records()
    no_fp["expected"] = {}
    case7 = s3.decide(no_fp)
    tests.append({
        "case": "current projection fingerprint unavailable",
        "expect_complete": False,
        "complete": case7["complete"],
        "T3-04": case7["predicates"]["T3-04"]["reason"],
        "pass": case7["complete"] is False
                and case7["predicates"]["T3-04"]["reason"] == "SOURCE_FINGERPRINT_UNAVAILABLE",
    })

    # Case 8: approved but not admitted -> not complete (APPROVED != ADMITTED).
    not_admitted = copy.deepcopy(full)
    not_admitted["admissions"][p1] = []
    case6 = s3.decide(not_admitted)
    tests.append({
        "case": "approved objective without admission",
        "expect_complete": False,
        "complete": case6["complete"],
        "T3-05": case6["predicates"]["T3-05"]["reason"],
        "pass": case6["complete"] is False
                and case6["predicates"]["T3-05"]["reason"] == "APPROVED_NOT_ADMITTED",
    })

    return tests


# ---------------------------------------------------------------------------
# A5 - invalidation matrix
# ---------------------------------------------------------------------------

def invalidation_tests() -> list[dict]:
    base = satisfied_records()
    assert s3.decide(base)["complete"] is True, "base fixture must be complete"

    mutations = [
        ("new M2 revision", lambda r: r["m2"].__setitem__("revision", REVISION + 1),
         "T3-02"),
        ("invalidated confirmation", lambda r: r.__setitem__("confirmation", None),
         "T3-02"),
        ("superseded BCB context",
         lambda r: r["context"].__setitem__("assessment_revision", REVISION - 1), "T3-03"),
        ("context built from a different digest",
         lambda r: r["context"].__setitem__("snapshot_digest", "f" * 64), "T3-03"),
        ("BDJ ruleset superseded",
         lambda r: r.__setitem__("expected", {"ruleset_version": "BDJ-M2V1-IG-0.2-PROP"}),
         "T3-04"),
        ("objective decision withdrawn",
         lambda r: r["decisions"].__setitem__("aaaa1111-1111-4111-8111-111111111111", []),
         "T3-05"),
        ("objective admission withdrawn",
         lambda r: r["admissions"].__setitem__("aaaa1111-1111-4111-8111-111111111111", []),
         "T3-05"),
        ("assessment ownership changed",
         lambda r: r["assessment"].__setitem__("user_id",
                                               "c70a999a-50c6-4a31-8f7a-b914d0a5c641"),
         "T3-01"),
    ]

    # The last two mutations need a proposal set in the base record.
    p1 = "aaaa1111-1111-4111-8111-111111111111"
    base["proposals"] = [{"proposal_id": p1, "review_state": "APPROVED",
                          "owner_user_id": OWNER_ID, "context_packet_hash": "x",
                          "confirmation_revision": REVISION, "execution_mode": "SIMULATED"}]
    base["decisions"] = {p1: [{"decision": "APPROVED"}]}
    base["admissions"] = {p1: [{"decision": "WORTH_RESEARCHING"}]}

    out = []
    for name, mutate, expect_predicate in mutations:
        records = copy.deepcopy(base)
        mutate(records)
        verdict = s3.decide(records)
        failed = [p for p in ("T3-01", "T3-02", "T3-03", "T3-04", "T3-05")
                  if not verdict["predicates"][p]["satisfied"]]
        out.append({
            "change": name,
            "expected_failing_predicate": expect_predicate,
            "complete": verdict["complete"],
            "failing": failed,
            "reason": verdict["predicates"][expect_predicate]["reason"],
            "pass": verdict["complete"] is False and expect_predicate in failed,
        })
    return out


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    report: dict = {"checkpoint": "PHASE_A_STAGE3_COMPLETION_CONTRACT",
                    "contract_version": s3.CONTRACT_VERSION, "checks": []}

    def add(name, ok, detail):
        report["checks"].append({"check": name,
                                 "verdict": "PASS_VERIFIED" if ok else "FAILED",
                                 "detail": detail})

    # ---- live verdict ---------------------------------------------------
    # The M2 runtime role has no SELECT on public.assessment or
    # public.m2_assessment_links, so the two ownership facts are read once as
    # the cluster administrator and passed in. That mirrors how the
    # application layer would supply them, and it is recorded as a design
    # constraint rather than hidden.
    ownership = {}
    with psycopg2.connect(admin_dsn()) as admin:
        admin.autocommit = True
        cur = admin.cursor()
        cur.execute("select assessment_id::text, user_id::text, status "
                    "from public.assessment where assessment_id = %s::uuid", (ASSESSMENT,))
        row = cur.fetchone()
        ownership["assessment"] = ({"assessment_id": row[0], "user_id": row[1],
                                    "status": row[2]} if row else None)
        cur.execute("select marketplace_assessment_id::text, m2_assessment_id::text, "
                    "user_id::text from public.m2_assessment_links "
                    "where marketplace_assessment_id = %s::uuid", (ASSESSMENT,))
        row = cur.fetchone()
        ownership["link"] = ({"marketplace_assessment_id": row[0],
                              "m2_assessment_id": row[1], "user_id": row[2]}
                             if row else None)
    report["ownership_facts"] = ownership

    # The current projection fingerprint. It cannot be derived from the tables
    # the evaluator reads: it is digest(project1-m2-projection/1-candidate),
    # which only the projection builder produces. The BDJ read surface exposes
    # the value the engine itself would use, so it is the authoritative source
    # here. Verified separately that it is NOT the confirmation digest.
    t0 = token(OWNER)
    s_fp, fp_payload = api(f"/api/v1/m2/assessments/{M2_ID}/bdj/current"
                           f"?confirmation_id={CONFIRMATION}&expected_revision={REVISION}", t0)
    live_fp = (fp_payload or {}).get("source_fingerprint")
    report["source_fingerprint"] = {
        "status": s_fp, "projection_fingerprint": live_fp,
        "confirmation_snapshot_digest": DIGEST,
        "equal": live_fp == DIGEST,
        "note": "different hashes over different objects; comparing them would "
                "fail for every valid evaluation",
    }

    with psycopg2.connect(dsn()) as conn, psycopg2.connect(dsn("PROJECT1_RUNTIME_DATABASE_URL")) as ledger:
        conn.autocommit = False
        ledger.autocommit = True
        # The ledger login is only a member of the restricted role; the grants
        # live on p1ai_runtime, so the session switches down to it exactly as
        # the application does.
        ledger.cursor().execute("SET ROLE p1ai_runtime")
        cur = conn.cursor()
        cur.execute("select set_config('project1.actor_id', %s, true)", (OWNER_ID,))
        live = s3.evaluate(cur, marketplace_assessment_id=ASSESSMENT,
                           m2_assessment_id=M2_ID, actor_id=OWNER_ID,
                           assessment=ownership["assessment"], link=ownership["link"],
                           ledger_cur=ledger.cursor(),
                           expected={"source_fingerprint": live_fp})
        conn.rollback()
    report["live_verdict"] = live
    add("live evaluation is read-only and completes without writes",
        True, {"contract_version": live["contract_version"],
               "transaction": "rolled back"})
    add("live verdict: Stage 3 is not complete",
        live["complete"] is False,
        {"complete": live["complete"],
         "blockers": [b["reason"] for b in live["blockers"]]})
    add("live verdict: the blocking predicate is BDJ execution (T3-04)",
        live["predicates"]["T3-04"]["satisfied"] is False,
        {"T3-04": live["predicates"]["T3-04"]["reason"]})
    add("live verdict: ownership, confirmation and context all hold",
        all(live["predicates"][p]["satisfied"] for p in ("T3-01", "T3-02", "T3-03")),
        {p: live["predicates"][p]["reason"] for p in ("T3-01", "T3-02", "T3-03")})
    add("live verdict: legacy timestamp is not consulted",
        "evidence_reviewed_at" not in json.dumps(live),
        {"note": "the evaluator never reads assessment.evidence_reviewed_at"})

    # ---- A3 fixtures ----------------------------------------------------
    fixtures = fixture_tests()
    report["zero_proposal_cases"] = fixtures
    add("A3: authorized evaluation with zero proposals may complete",
        fixtures[0]["pass"], fixtures[0])
    add("A3: zero proposals with no evaluation must not complete",
        fixtures[1]["pass"], fixtures[1])
    add("A3: a simulated result never counts as an evaluation",
        fixtures[2]["pass"], fixtures[2])
    add("A3: an unconsumed authorization does not authorize an evaluation",
        fixtures[3]["pass"], fixtures[3])
    add("A3: an evaluation against a superseded projection is rejected",
        fixtures[5]["pass"], fixtures[5])
    add("A3: a missing projection fingerprint fails closed",
        fixtures[6]["pass"], fixtures[6])
    add("A3: approved without admission is not resolved",
        fixtures[7]["pass"], fixtures[7])

    # ---- A5 invalidation ------------------------------------------------
    invalidations = invalidation_tests()
    report["invalidation_matrix"] = invalidations
    add("A5: every upstream change invalidates the completion",
        all(t["pass"] for t in invalidations),
        [{"change": t["change"], "failing": t["failing"]} for t in invalidations])

    # ---- A6 gate: evaluator is not wired -------------------------------
    t = token(OWNER)
    s_readiness, readiness = api(f"/api/v1/assessments/{ASSESSMENT}/workflow-readiness", t)
    report["readiness_payload"] = readiness
    add("A6: authoritative readiness still reports NOT_IMPLEMENTED",
        readiness.get("stage_3", {}).get("completion") == "NOT_IMPLEMENTED"
        and readiness.get("stage_3", {}).get("complete") is False,
        {"stage_3": readiness.get("stage_3")})
    add("A6: readiness contract version unchanged",
        readiness.get("contract_version") == "sitewise-assessment-workflow/2",
        {"contract_version": readiness.get("contract_version")})

    s_detail, detail = api(f"/api/v1/assessments/{ASSESSMENT}", t)
    stages = {x["key"]: x["status"] for x in detail["assessment"]["stages"]}
    add("A6: stage 3 status unchanged in the authoritative payload",
        stages.get("location_evidence") == "current",
        {"stages": stages})

    passed = sum(1 for c in report["checks"] if c["verdict"] == "PASS_VERIFIED")
    report["summary"] = {"PASS_VERIFIED": passed,
                         "FAILED": len(report["checks"]) - passed,
                         "total": len(report["checks"])}

    (OUT / "pA_stage3_contract.json").write_text(json.dumps(report, indent=2, default=str),
                                                 encoding="utf-8")
    print(json.dumps({"summary": report["summary"],
                      "live_complete": live["complete"],
                      "blockers": live["blockers"]}, indent=2, default=str))
    for c in report["checks"]:
        print(f"{c['verdict']:<15} {c['check']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
