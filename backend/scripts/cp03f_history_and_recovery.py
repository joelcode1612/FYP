"""CP-03F-12 / CP-03F-13: history fidelity, cross-owner denial, recovery.

Checks that cannot be made from inside one request:

  * a second owner cannot read another owner's assessment or history,
  * persisted activity is immutable (no UPDATE/DELETE path for the app role),
  * a backend restart preserves revisions and history,
  * an interrupted request cannot produce two decisions (the CAS must refuse the
    replay rather than append a second revision).

Read-only except for the writes needed to produce the rows being checked.
"""
from __future__ import annotations

import json
import shutil
import sys
import tempfile
from pathlib import Path
from uuid import UUID

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "src"))
sys.path.insert(0, str(HERE))

import requests  # noqa: E402

import cp03f_e2e_browser as H  # noqa: E402

INSTRUMENT = "50906385-072b-5cf1-9661-4d001898ffb8"
OTHER_OWNER = "11111111-1111-4111-8111-111111111111"


def main() -> int:
    workdir = Path(tempfile.mkdtemp(prefix="cp03f_hr_"))
    priv = H.make_keypair(workdir)
    sub_id, email, _ = H.entrepreneur()
    token = H.mint(priv, sub_id, email)
    other = H.mint(priv, OTHER_OWNER, "other-owner@example.test")
    srv = H.serve_jwks(workdir)
    backend = None
    out: dict = {"results": []}
    try:
        backend = H.start_backend()
        base = f"http://127.0.0.1:{H.BACKEND_PORT}"
        auth = {"Authorization": f"Bearer {token}"}
        other_auth = {"Authorization": f"Bearer {other}"}

        def rec(name, **kw):
            out["results"].append({"check": name, **kw})
            print(f"[{name}] " + json.dumps(kw)[:400])

        created = requests.post(f"{base}/api/v1/m2/assessments", headers=auth,
                                json={"instrument_version_id": INSTRUMENT}, timeout=20)
        aid = created.json()["id"]
        out["assessment_id"] = aid

        # Produce a persisted answer so there is history to inspect.
        r = requests.put(f"{base}/api/v1/m2/assessments/{aid}/answers/M2V1-04",
                         headers=auth, json={"expected_revision": 0,
                                             "answer_state": "ANSWERED",
                                             "value": ["STUDENTS"]}, timeout=20)
        rec("WRITE", status=r.status_code, revision=r.json().get("assessment_revision"))

        # --- CP-03F-12: cross-owner denial -------------------------------------
        for label, headers in (("OWNER", auth), ("OTHER_OWNER", other_auth)):
            g = requests.get(f"{base}/api/v1/m2/assessments/{aid}", headers=headers, timeout=20)
            a = requests.get(f"{base}/api/v1/m2/assessments/{aid}/activity", headers=headers, timeout=20)
            rec("CROSS_OWNER_READ", who=label, assessment_status=g.status_code,
                activity_status=a.status_code)
        # The other owner's own list must not contain this assessment.
        lst = requests.get(f"{base}/api/v1/m2/assessments", headers=other_auth, timeout=20)
        ids = [i["id"] for i in ((lst.json() or {}).get("items") or [])] if lst.ok else []
        rec("CROSS_OWNER_LIST", status=lst.status_code, contains=(aid in ids), count=len(ids))

        # --- CP-03F-12: immutability -------------------------------------------
        # The application role must not be able to rewrite or delete a receipt.
        #
        # The actor GUC MUST be bound first: without it RLS hides every row, the
        # statement updates nothing, the BEFORE ROW trigger never fires, and the
        # absence of an exception reads as "mutation allowed". That false positive
        # was produced once already; rowcount and the post-state are therefore
        # recorded, not just the error.
        from sqlalchemy import create_engine, text

        from sitewise.core.config import settings
        eng = create_engine(settings.m2_database_url.get_secret_value())

        def with_actor():
            c = eng.connect()
            c.execute(text("select set_config('project1.actor_id', :o, false)"),
                      {"o": sub_id})
            return c

        with with_actor() as c:
            visible = c.execute(text(
                "select count(*) from public.m2_answer_revisions where assessment_id=:a"),
                {"a": aid}).scalar()
        rec("IMMUTABILITY_VISIBLE", rows=visible)

        for label, sql in (
            ("UPDATE", "update public.m2_answer_revisions set answer_state='NOT_PROVIDED' "
                       "where assessment_id = :a"),
            ("DELETE", "delete from public.m2_answer_revisions where assessment_id = :a"),
        ):
            with with_actor() as c:
                try:
                    res = c.execute(text(sql), {"a": aid})
                    rec("IMMUTABILITY", statement=label, outcome="NO_EXCEPTION",
                        rowcount=res.rowcount)
                    c.rollback()
                except Exception as exc:  # noqa: BLE001 - the denial is the datum
                    rec("IMMUTABILITY", statement=label, outcome="DENIED",
                        sqlstate=getattr(getattr(exc, "orig", None), "pgcode", None),
                        reason=str(exc).splitlines()[0][:140])
                    c.rollback()

        with with_actor() as c:
            post = c.execute(text(
                "select answer_state, value_json from public.m2_answer_revisions "
                "where assessment_id=:a order by assessment_revision"), {"a": aid}).all()
        rec("IMMUTABILITY_POST_STATE",
            rows=[{"state": r.answer_state, "value": r.value_json} for r in post])

        # --- CP-03F-13: idempotency of an interrupted request ------------------
        # Replaying the same body with the same expected_revision must be refused,
        # not applied twice.
        replay = requests.put(f"{base}/api/v1/m2/assessments/{aid}/answers/M2V1-04",
                              headers=auth, json={"expected_revision": 0,
                                                  "answer_state": "ANSWERED",
                                                  "value": ["STUDENTS"]}, timeout=20)
        rec("IDEMPOTENT_REPLAY", status=replay.status_code, body=replay.text[:200])

        before = requests.get(f"{base}/api/v1/m2/assessments/{aid}", headers=auth,
                              timeout=20).json()
        act_before = requests.get(f"{base}/api/v1/m2/assessments/{aid}/activity",
                                  headers=auth, timeout=20).json()
        rec("BEFORE_RESTART", revision=before["assessment"]["revision"],
            events=len(act_before.get("events") or []))

        # --- CP-03F-13: restart ------------------------------------------------
        backend.terminate()
        backend.wait(timeout=30)
        backend = H.start_backend()

        after = requests.get(f"{base}/api/v1/m2/assessments/{aid}", headers=auth,
                             timeout=20).json()
        act_after = requests.get(f"{base}/api/v1/m2/assessments/{aid}/activity",
                                 headers=auth, timeout=20).json()
        rec("AFTER_RESTART", revision=after["assessment"]["revision"],
            events=len(act_after.get("events") or []),
            same_revision=(after["assessment"]["revision"] == before["assessment"]["revision"]),
            same_event_ids=(sorted(str(e.get("event_id")) for e in (act_after.get("events") or []))
                            == sorted(str(e.get("event_id")) for e in (act_before.get("events") or []))),
            answer=(after.get("answers") or {}).get("M2V1-04", {}).get("value_json"))

        (H.OUT / "history_recovery.json").write_text(json.dumps(out, indent=2, default=str),
                                                     encoding="utf-8")
        return 0
    finally:
        if backend:
            backend.terminate()
        srv.shutdown()
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
