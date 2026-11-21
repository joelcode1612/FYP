"""CP-03F-10: the authenticated M2 journey, backend of record.

Runs the directive's 16 steps against a *fresh* assessment so every conditional
state is deterministic — reusing an assessment that already has answers makes
"before the controlling answer" impossible to observe, which is exactly how a
misleading label got into the earlier evidence.

This script is the API half. cp03f_journey_browser.py repeats the same journey
through the real Jaspr UI and compares. Neither is allowed to stand alone: a
passing API call does not show the panel offers the right controls, and a
rendering does not show what was persisted.

Everything is printed as it happens, including refusals. A refusal with an exact
status and reason is a valid outcome; a bypassed gate is not.
"""
from __future__ import annotations

import json
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "src"))
sys.path.insert(0, str(HERE))

import requests  # noqa: E402

import cp03f_e2e_browser as H  # noqa: E402

INSTRUMENT = "50906385-072b-5cf1-9661-4d001898ffb8"

# Ordered so each conditional item is answered only after its controller.
# M2V1-01 is GEO. The catalogue is not VERIFIED, so any concrete area is refused
# (correctly — no area reference may be invented), but `validate_m2_answer`
# explicitly accepts UNDECIDED before the catalogue check. That is a registered
# option, not a bypass, and it is the only way a required GEO item can be
# satisfied while the catalogue is unapproved.
PLAN = [
    ("M2V1-01", "ANSWERED", "UNDECIDED"),
    ("M2V1-02", "ANSWERED", "HYBRID"),
    ("M2V1-03", "ANSWERED", ["COFFEE", "BAKED_GOODS"]),
    ("M2V1-04", "ANSWERED", ["STUDENTS", "OFFICE_WORKERS"]),
    ("M2V1-05", "ANSWERED", None),      # derived from M2V1-04
    ("M2V1-06", "ANSWERED", "AFFORDABILITY"),
    ("M2V1-07", "ANSWERED", "STUDY_WORK"),
    ("M2V1-08", "ANSWERED", ["PERSONAL_OBSERVATION"]),
    ("M2V1-09", "ANSWERED", ["CONCEPT_INTEREST"]),
    ("M2V1-10", "ANSWERED", None),      # derived from M2V1-09
    ("M2V1-11", "ANSWERED", "VALIDATE_CHOICE"),
]


def main() -> int:
    workdir = Path(tempfile.mkdtemp(prefix="cp03f_j_"))
    priv = H.make_keypair(workdir)
    sub_id, email, _ = H.entrepreneur()
    token = H.mint(priv, sub_id, email)
    srv = H.serve_jwks(workdir)
    backend = None
    log: dict = {"steps": []}
    try:
        backend = H.start_backend()
        base = f"http://127.0.0.1:{H.BACKEND_PORT}"
        auth = {"Authorization": f"Bearer {token}"}

        def step(name, **kw):
            log["steps"].append({"step": name, **kw})
            print(f"[{name}] " + json.dumps(kw)[:400])

        # 1. Sign in.
        me = requests.get(f"{base}/api/v1/auth/me", headers=auth, timeout=20)
        step("01_SIGN_IN", status=me.status_code, user=(me.json() or {}).get("user_id") if me.ok else None)
        if not me.ok:
            return 1

        # 2. Create a fresh assessment (this is the "saved assessment" the
        #    browser will open in step 3).
        created = requests.post(f"{base}/api/v1/m2/assessments", headers=auth,
                                json={"instrument_version_id": INSTRUMENT}, timeout=20)
        if not created.ok:
            step("02_CREATE_ASSESSMENT", status=created.status_code, body=created.text[:300])
            return 1
        aid = created.json()["id"]
        step("02_CREATE_ASSESSMENT", status=created.status_code, assessment_id=aid)
        log["assessment_id"] = aid

        def read():
            r = requests.get(f"{base}/api/v1/m2/assessments/{aid}", headers=auth, timeout=20)
            b = r.json()
            items = {i["item_key"]: i for i in b.get("items") or []}
            answers = b.get("answers") or {}
            return r.status_code, b["assessment"]["revision"], items, answers

        # 4-5. Instrument and answers load.
        status, rev, items, answers = read()
        step("04_LOAD_INSTRUMENT", status=status, revision=rev, item_count=len(items),
             conditional={k: {"applicable": items[k].get("applicable"),
                              "effective_options": items[k].get("effective_options")}
                          for k in ("M2V1-05", "M2V1-10", "M2V1-11")})
        log["baseline_conditional"] = {
            k: {"applicable": items[k].get("applicable"),
                "effective_options": items[k].get("effective_options")}
            for k in ("M2V1-05", "M2V1-10", "M2V1-11")}

        # 6-7. Complete the valid items, saving each one.
        results = []
        for key, state, value in PLAN:
            if value is None:  # derived: take the server's own list
                opts = items[key].get("effective_options") or []
                value = opts[0] if opts else None
            body = {"expected_revision": rev, "answer_state": state, "value": value}
            r = requests.put(f"{base}/api/v1/m2/assessments/{aid}/answers/{key}",
                             headers=auth, json=body, timeout=20)
            results.append({"item": key, "status": r.status_code,
                            "value": value, "detail": None if r.ok else r.text[:200]})
            print(f"  PUT {key} {json.dumps(value)} -> {r.status_code}"
                  + ("" if r.ok else f" {r.text[:160]}"))
            status, rev, items, answers = read()
        step("06_COMPLETE_ITEMS", revision=rev, results=results)
        log["save_results"] = results

        # 8. Independent revision readback is done separately in SQL; here record
        #    what the API itself reports for each answer.
        step("08_READBACK", revision=rev,
             answers={k: {"state": (answers.get(k) or {}).get("answer_state"),
                          "value": (answers.get(k) or {}).get("value_json"),
                          "revision": (answers.get(k) or {}).get("assessment_revision")}
                      for k in [p[0] for p in PLAN]})

        # 9. Reload — a second GET must agree exactly.
        status2, rev2, items2, answers2 = read()
        step("09_RELOAD", status=status2, revision=rev2, revision_matches=(rev2 == rev),
             answers_match=(json.dumps(answers, sort_keys=True, default=str)
                            == json.dumps(answers2, sort_keys=True, default=str)))

        # 10. Deterministic BDJ evaluation.
        ev = requests.post(f"{base}/api/v1/m2/assessments/{aid}/bdj/evaluate",
                           headers=auth, json={"expected_revision": rev}, timeout=60)
        body = None
        try:
            body = ev.json()
        except ValueError:
            body = ev.text[:500]
        step("10_BDJ_EVALUATE", status=ev.status_code, body=body)
        log["bdj"] = {"status": ev.status_code, "body": body}

        # 11. Read the result.
        bu = requests.get(f"{base}/api/v1/m2/assessments/{aid}/business-understanding",
                          headers=auth, timeout=20)
        step("11_READ_RESULT", status=bu.status_code,
             body=(bu.json() if bu.ok else bu.text[:400]))
        log["business_understanding"] = bu.json() if bu.ok else bu.text[:400]

        # 12. Review obligations (M2-20).
        rv = requests.post(f"{base}/api/v1/m2/assessments/{aid}/review",
                           headers=auth, json={"expected_revision": rev}, timeout=20)
        step("12_REVIEW", status=rv.status_code, body=(rv.json() if rv.ok else rv.text[:400]))

        # 13. Confirm — expected to be refused while findings remain unresolved.
        cf = requests.post(f"{base}/api/v1/m2/assessments/{aid}/confirm",
                           headers=auth,
                           json={"expected_revision": rev, "acknowledged_issue_ids": []},
                           timeout=20)
        step("13_CONFIRM", status=cf.status_code, body=(cf.text[:400]))
        log["confirm"] = {"status": cf.status_code, "body": cf.text[:400]}

        # 15. Activity history. The contract key is `events`, not `items` — reading
        #    the wrong key reports an empty history that does not exist.
        act = requests.get(f"{base}/api/v1/m2/assessments/{aid}/activity",
                           headers=auth, timeout=20)
        payload = act.json() if act.ok else {}
        events = payload.get("events") or []
        step("15_ACTIVITY", status=act.status_code, event_count=len(events),
             contract=payload.get("contract_version"),
             event_ids=[e.get("event_id") for e in events][:12],
             event_types=[e.get("kind") for e in events][:12])
        log["activity"] = {"status": act.status_code, "events": events[:12]}

        (H.OUT / "journey_backend.json").write_text(json.dumps(log, indent=2, default=str),
                                                    encoding="utf-8")
        return 0
    finally:
        if backend:
            backend.terminate()
        srv.shutdown()
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
