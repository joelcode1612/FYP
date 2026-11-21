"""CP-03F-09: conditional-item matrix for M2V1-05 / M2V1-10 / M2V1-11.

The directive requires, for each conditional item, the controlling answer and its
revision, the backend `effective_options`, `applicable`, the options the Jaspr
panel actually showed, the codes submitted, the API status, the DB readback, the
behaviour after changing the controlling answer, and the behaviour after reload.

This drives the authenticated API for one owner and records all of it. The browser
half (what Jaspr renders) is captured separately by cp03f_e2e_browser.py; this
script is the server-of-record view.

Why it matters: M2V1-11 has `applicable=false` while `effective_options` lists four
codes, and M2V1-05 has an empty static `option_values` while its derived list is
populated. A panel that trusts either field in isolation renders controls the
server will reject, or none at all.

Writes are real, to the E2E owner's own assessment. Every step prints the resulting
revision so the sequence is auditable.
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

ASSESSMENT = "510dfdd8-4bdd-4e00-915c-d5d7fa9df747"
CONDITIONAL = ("M2V1-05", "M2V1-10", "M2V1-11")


def snapshot(base, auth):
    r = requests.get(f"{base}/api/v1/m2/assessments/{ASSESSMENT}", headers=auth, timeout=20)
    r.raise_for_status()
    body = r.json()
    items = {i["item_key"]: i for i in body.get("items") or []}
    raw = body.get("answers") or {}
    # The API returns answers keyed by item_key; tolerate a list shape too rather
    # than assuming, because assuming is what produced a KeyError last time.
    if isinstance(raw, dict):
        answers = raw
    else:
        answers = {a["item_key"]: a for a in raw}
    return body["assessment"]["revision"], items, answers


def show(label, revision, items, answers):
    print(f"\n--- {label}  (assessment revision {revision}) ---")
    for key in ("M2V1-04", "M2V1-09", *CONDITIONAL):
        it = items.get(key)
        if not it:
            print(f"  {key}: ABSENT")
            continue
        ans = answers.get(key) or {}
        print(f"  {key}  kind={it.get('answer_kind')}  applicable={it.get('applicable')}")
        print(f"      effective_options = {json.dumps(it.get('effective_options'))}")
        static = (it.get("option_values") or {}).get("options") or []
        print(f"      static option_values = {len(static)} codes")
        print(f"      answer_state={ans.get('answer_state')!r} value={json.dumps(ans.get('value_json'))}"
              f" revision={ans.get('assessment_revision')}")


def put(base, auth, item_key, revision, state, value):
    body = {"expected_revision": revision, "answer_state": state, "value": value}
    r = requests.put(f"{base}/api/v1/m2/assessments/{ASSESSMENT}/answers/{item_key}",
                     headers=auth, json=body, timeout=20)
    text = r.text[:300].replace("\n", " ")
    print(f"  PUT {item_key} {json.dumps(body)} -> {r.status_code} {text}")
    return r


def main() -> int:
    workdir = Path(tempfile.mkdtemp(prefix="cp03f_cond_"))
    priv = H.make_keypair(workdir)
    sub_id, email, _ = H.entrepreneur()
    token = H.mint(priv, sub_id, email)
    srv = H.serve_jwks(workdir)
    backend = None
    try:
        backend = H.start_backend()
        base = f"http://127.0.0.1:{H.BACKEND_PORT}"
        auth = {"Authorization": f"Bearer {token}"}

        rev, items, answers = snapshot(base, auth)
        show("T0 baseline", rev, items, answers)

        # 1. Control M2V1-05 through M2V1-04.
        r = put(base, auth, "M2V1-04", rev, "ANSWERED", ["STUDENTS", "OFFICE_WORKERS"])
        if not r.ok:
            return 2
        rev, items, answers = snapshot(base, auth)
        show("T1 after M2V1-04 = [STUDENTS, OFFICE_WORKERS]", rev, items, answers)

        # 2. Answer M2V1-05 with a code that the *next* step removes, so the
        #    staleness case is actually exercised. Choosing the first derived
        #    option would leave a still-valid value and prove nothing.
        derived = items["M2V1-05"]["effective_options"]
        doomed = "OFFICE_WORKERS" if "OFFICE_WORKERS" in derived else (
            derived[0] if derived else None)
        print(f"\n  derived M2V1-05 options now: {derived}; choosing {doomed!r} "
              f"(to be invalidated next)")
        r = put(base, auth, "M2V1-05", rev, "ANSWERED", doomed)
        if not r.ok:
            return 2
        rev, items, answers = snapshot(base, auth)
        show("T2 after M2V1-05 answered from derived list", rev, items, answers)

        # 3. Change the controlling answer so M2V1-05's stored value becomes
        #    invalid. This is the case the directive calls out: a static frontend
        #    option array would still be showing the old codes.
        r = put(base, auth, "M2V1-04", rev, "ANSWERED", ["STUDENTS"])
        if not r.ok:
            return 2
        rev, items, answers = snapshot(base, auth)
        show("T3 after M2V1-04 = [STUDENTS] (drops the M2V1-05 selection)", rev, items, answers)
        after = items["M2V1-05"]
        still_offered = doomed in (after.get("effective_options") or [])
        stored = (answers.get("M2V1-05") or {}).get("value_json")
        print(f"      doomed code {doomed!r} still in effective_options? {still_offered}")
        print(f"      M2V1-05 stored answer now: {json.dumps(stored)}")
        if still_offered:
            print("      INCONCLUSIVE: the controlling change did not remove the code;"
                  " staleness was not exercised")
        if stored == doomed:
            print("      NOTE: the stored answer still carries a value the server no"
                  " longer offers. Recorded as a finding, not corrected here.")

        # 4. Submitting the now-invalid code must be refused, not silently stored.
        print("\n  attempting to re-submit the no-longer-valid code:")
        bad = put(base, auth, "M2V1-05", rev, "ANSWERED", doomed)
        print(f"      verdict: {'REFUSED (correct)' if not bad.ok else 'ACCEPTED (defect)'}")
        # Re-read rather than assume the revision moved or did not.
        rev, items, answers = snapshot(base, auth)

        # 5. Unlock M2V1-10 by answering M2V1-09.
        r = put(base, auth, "M2V1-09", rev, "ANSWERED", ["CONCEPT_INTEREST"])
        if not r.ok:
            return 2
        rev, items, answers = snapshot(base, auth)
        show("T4 after M2V1-09 = [CONCEPT_INTEREST]", rev, items, answers)

        # 6. Answer M2V1-10 from its derived list, which unlocks M2V1-11.
        derived10 = items["M2V1-10"]["effective_options"]
        pick10 = derived10[0] if derived10 else None
        r = put(base, auth, "M2V1-10", rev, "ANSWERED", pick10)
        if not r.ok:
            return 2
        rev, items, answers = snapshot(base, auth)
        show(f"T5 after M2V1-10 = {pick10!r}", rev, items, answers)

        # 7. Reload: a fresh GET must reproduce exactly the same state.
        rev2, items2, answers2 = snapshot(base, auth)
        same = (rev2 == rev
                and json.dumps({k: items[k].get("effective_options") for k in CONDITIONAL},
                               sort_keys=True)
                == json.dumps({k: items2[k].get("effective_options") for k in CONDITIONAL},
                              sort_keys=True)
                and json.dumps({k: (answers.get(k) or {}).get("value_json") for k in CONDITIONAL},
                               sort_keys=True)
                == json.dumps({k: (answers2.get(k) or {}).get("value_json") for k in CONDITIONAL},
                              sort_keys=True))
        print(f"\n  RELOAD identical (revision + options + values): {same}")
        show("T6 after reload", rev2, items2, answers2)
        return 0
    finally:
        if backend:
            backend.terminate()
        srv.shutdown()
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
