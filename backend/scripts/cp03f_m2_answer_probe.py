"""CP-03F: reproduce the M2 answer PUT that the browser reported as rejected.

The panel's catch block replaces the server error with a fixed sentence, so the
status code has to be obtained out of band. This probe sends the exact body the
browser sent (`{"expected_revision":0,"answer_state":"ANSWERED",
"value":["STUDENTS","OFFICE_WORKERS"]}`) and prints the real response.

Read-only until the PUT is issued; the PUT is a real write to the owner's own
assessment, which is what E2E is for. It prints before/after revision so the
effect is explicit.
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


def main() -> int:
    workdir = Path(tempfile.mkdtemp(prefix="cp03f_probe_"))
    priv = H.make_keypair(workdir)
    sub_id, email, _ = H.entrepreneur()
    token = H.mint(priv, sub_id, email)
    srv = H.serve_jwks(workdir)
    backend = None
    try:
        backend = H.start_backend()
        base = f"http://127.0.0.1:{H.BACKEND_PORT}"
        auth = {"Authorization": f"Bearer {token}"}

        before = requests.get(f"{base}/api/v1/m2/assessments/{ASSESSMENT}",
                              headers=auth, timeout=20)
        print("GET assessment", before.status_code)
        payload = before.json() if before.ok else {}
        # `revision` is nested under `assessment`; reading a top-level key silently
        # yields None, and defaulting that to 0 only ever works at revision 0.
        assessment = payload.get("assessment") or {}
        if "revision" not in assessment:
            print("  cannot determine revision from response keys:", sorted(payload))
            return 3
        revision = assessment["revision"]
        print("  revision:", revision,
              "confirmed_revision:", assessment.get("confirmed_revision"))

        item = None
        for candidate in payload.get("items") or []:
            if candidate.get("item_key") == "M2V1-04":
                item = candidate
                break
        print("  M2V1-04 present:", item is not None)
        if item:
            print("  answer_kind:", item.get("answer_kind"),
                  "applicable:", item.get("applicable"))
            print("  effective_options:",
                  json.dumps(item.get("effective_options"))[:300])

        body = {"expected_revision": revision,
                "answer_state": "ANSWERED",
                "value": ["STUDENTS", "OFFICE_WORKERS"]}
        print("PUT body:", json.dumps(body))
        put = requests.put(
            f"{base}/api/v1/m2/assessments/{ASSESSMENT}/answers/M2V1-04",
            headers=auth, json=body, timeout=20)
        print("PUT status:", put.status_code)
        print("PUT response:", put.text[:1200])

        after = requests.get(f"{base}/api/v1/m2/assessments/{ASSESSMENT}",
                             headers=auth, timeout=20)
        after_payload = after.json() if after.ok else {}
        print("POST revision:", (after_payload.get("assessment") or {}).get("revision"))
        return 0 if put.ok else 2
    finally:
        if backend:
            backend.terminate()
        srv.shutdown()
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
