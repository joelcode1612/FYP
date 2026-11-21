"""CP-03F-02: server-resolved conditional fields, read straight from the API.

Read-only. Prints, for the conditional items, the two option fields side by side:

  effective_options  what the server says is selectable *now*, given the answers
  option_values      the static catalogue, independent of any answer

UI-03 was the panel reading the wrong one. The discriminator is that they differ
while the source item is unanswered: the static catalogue is populated, the
effective list is empty and `applicable` is false. A panel reading
`option_values` would render selectable chips that the server will reject.
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
ITEMS = ("M2V1-04", "M2V1-05", "M2V1-09", "M2V1-10", "M2V1-11")


def main() -> int:
    workdir = Path(tempfile.mkdtemp(prefix="cp03f_instr_"))
    priv = H.make_keypair(workdir)
    sub_id, email, _ = H.entrepreneur()
    token = H.mint(priv, sub_id, email)
    srv = H.serve_jwks(workdir)
    backend = None
    try:
        backend = H.start_backend()
        base = f"http://127.0.0.1:{H.BACKEND_PORT}"
        res = requests.get(f"{base}/api/v1/m2/assessments/{ASSESSMENT}",
                           headers={"Authorization": f"Bearer {token}"}, timeout=20)
        body = res.json()
        items = body.get("items") or body.get("data", {}).get("items") or []
        print("GET", res.status_code, "items:", len(items))
        out = []
        for item in items:
            if item.get("item_key") not in ITEMS:
                continue
            row = {
                "item_key": item.get("item_key"),
                "answer_kind": item.get("answer_kind"),
                "applicable": item.get("applicable"),
                "effective_options": item.get("effective_options"),
                "option_values": item.get("option_values"),
                "answer_state": item.get("answer_state"),
            }
            out.append(row)
            print(json.dumps(row, ensure_ascii=False))
        Path(H.OUT / "instrument_conditional.json").write_text(
            json.dumps(out, indent=2, ensure_ascii=False), encoding="utf-8")
        return 0
    finally:
        if backend:
            backend.terminate()
        srv.shutdown()
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
