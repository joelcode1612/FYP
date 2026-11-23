"""Checkpoint item 3 — impersonation and authenticated actor binding.

Three distinct questions, because they have three different answers:

  A. Can an authenticated user read another owner's rows through the API?
  B. Can the actor binding leak between requests sharing a pooled connection?
  C. If someone holds the application's database credentials, can they read any
     owner's rows by writing the GUC directly?

A and B are application-level and must fail closed. C is a database-level
property, and the honest answer is that it is not defended here — this harness
demonstrates that rather than asserting it.
"""
from __future__ import annotations

import concurrent.futures
import json
import re
import urllib.error
import urllib.request
from pathlib import Path

import psycopg2

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent
OUT = REPO / "deliverables" / "phase4" / "c3_impersonation.json"

API = "http://127.0.0.1:8091"
GOTRUE = "http://127.0.0.1:54329"
ANON = "sb_publishable_local_e2e"
PASSWORD = "e2e-local-password"
OWNER = "gatebc-e2e-b9e62014@example.invalid"
INTRUDER = "gatebc-e2e-c70a999a@example.invalid"
OWNER_ID = "b9e62014-b7bc-426e-a950-a95b25965639"
OWNER_ASSESSMENT = "37bf879a-005a-4f5a-b49d-210ea1ce37c4"
OWNER_M2 = "032d3dde-547f-49a6-9e0f-58fbc5f1a48f"
OWNER_CONFIRMATION = "00ea0ece-cdca-48f6-9c4c-53c47cedc329"


def dsn() -> str:
    text = (BACKEND / "var" / "e2e" / "app.env").read_text(encoding="utf-8", errors="replace")
    url = re.search(r"^M2_DATABASE_URL=(.+)$", text, re.M).group(1).strip()
    return url.replace("postgresql+psycopg2", "postgresql")


def token(email: str) -> str:
    req = urllib.request.Request(
        f"{GOTRUE}/auth/v1/token?grant_type=password",
        data=json.dumps({"email": email, "password": PASSWORD}).encode(),
        headers={"Content-Type": "application/json", "apikey": ANON})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)["access_token"]


def call(path: str, bearer: str | None, body: dict | None = None, method: str = "GET"):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"} if data else {}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    req = urllib.request.Request(API + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read().decode("utf-8", "replace")
            try:
                return resp.status, json.loads(raw)
            except json.JSONDecodeError:
                return resp.status, raw[:300]
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            return exc.code, json.loads(raw)
        except json.JSONDecodeError:
            return exc.code, raw[:300]


def main() -> int:
    out: dict = {"checks": []}

    def record(name, ok, detail):
        out["checks"].append({"check": name, "pass": bool(ok), "detail": detail})

    owner_t = token(OWNER)
    intruder_t = token(INTRUDER)

    # --- A. API-level cross-owner reads -----------------------------------
    # Every surface that returns owner-scoped M2 data, addressed with the
    # owner's real identifiers but the intruder's token.
    surfaces = [
        ("assessment detail", f"/api/v1/assessments/{OWNER_ASSESSMENT}", None),
        ("research workspace",
         f"/api/v1/m2/confirmations/{OWNER_CONFIRMATION}/research-workspace?expected_revision=17", None),
        ("bcb read", f"/api/v1/m2/assessments/{OWNER_M2}/business-contexts/"
                     f"009ccc7d-2747-5c69-a077-22a652c96959", None),
        ("bdj current",
         f"/api/v1/m2/assessments/{OWNER_M2}/bdj/current"
         f"?confirmation_id={OWNER_CONFIRMATION}&expected_revision=17", None),
        ("bcb construct", f"/api/v1/m2/assessments/{OWNER_M2}/business-context",
         {"confirmation_id": OWNER_CONFIRMATION, "expected_revision": 17}),
    ]
    cross = {}
    for label, path, body in surfaces:
        status, payload = call(path, intruder_t, body,
                               "POST" if body else "GET")
        leaked = False
        if isinstance(payload, dict):
            # Any of these appearing means the intruder received owner data.
            blob = json.dumps(payload)
            leaked = OWNER_ID in blob or OWNER_CONFIRMATION in blob and status < 400
        cross[label] = {"status": status, "leaked_owner_identity": leaked}
    record("foreign token cannot read any owner-scoped surface",
           all(v["status"] >= 400 and not v["leaked_owner_identity"] for v in cross.values()),
           cross)

    # --- A2. identity cannot be supplied in the request --------------------
    # If any endpoint honoured a body-supplied identity, this would return the
    # owner's data under the intruder's token.
    status, payload = call(
        f"/api/v1/m2/assessments/{OWNER_M2}/business-context", intruder_t,
        {"confirmation_id": OWNER_CONFIRMATION, "expected_revision": 17,
         "owner_user_id": OWNER_ID, "user_id": OWNER_ID, "actor_id": OWNER_ID},
        "POST")
    record("body-supplied identity is not honoured (extra fields refused or ignored)",
           status >= 400,
           {"status": status,
            "note": "BuildRequest sets extra='forbid', so identity fields are a 422"})

    # --- B. no cross-request binding leakage ------------------------------
    # Interleave owner and intruder calls on the same server so they share the
    # connection pool. If the GUC were session-scoped rather than transaction-
    # local, an intruder request would occasionally inherit the owner's actor.
    def one(kind: str):
        bearer = owner_t if kind == "owner" else intruder_t
        path = (f"/api/v1/assessments/{OWNER_ASSESSMENT}" if kind == "owner"
                else "/api/v1/assessments/me")
        status, payload = call(path, bearer)
        return kind, status, payload

    tasks = [("owner" if i % 2 == 0 else "intruder") for i in range(24)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(one, tasks))

    owner_ok, intruder_ok = 0, 0
    anomalies = []
    for kind, status, payload in results:
        if kind == "owner":
            body = (payload or {}).get("assessment") if isinstance(payload, dict) else None
            if status == 200 and body and body.get("user_id") == OWNER_ID:
                owner_ok += 1
            else:
                anomalies.append({"kind": kind, "status": status})
        else:
            # The intruder must never receive a payload owned by the owner.
            blob = json.dumps(payload or {})
            if OWNER_ID in blob:
                anomalies.append({"kind": kind, "status": status,
                                  "owner_id_present": True})
            else:
                intruder_ok += 1
    record("24 interleaved requests: no actor binding leaked across the pool",
           not anomalies and owner_ok == 12 and intruder_ok == 12,
           {"owner_consistent": owner_ok, "intruder_clean": intruder_ok,
            "anomalies": anomalies,
            "mechanism": "every set_config uses is_local=true (transaction-local)"})

    # --- C. direct database access ---------------------------------------
    # Hold the runtime role's credentials and write the GUC. This is the vector
    # the API cannot defend against, demonstrated rather than asserted.
    direct = {}
    with psycopg2.connect(dsn()) as conn:
        conn.autocommit = False
        cur = conn.cursor()
        cur.execute("select set_config('project1.actor_id', %s, true)", (OWNER_ID,))
        cur.execute("select count(*) from public.m2_assessments")
        direct["assessments_visible_as_owner"] = cur.fetchone()[0]
        cur.execute("select count(*) from public.m2_confirmation_snapshots")
        direct["confirmations_visible_as_owner"] = cur.fetchone()[0]
        conn.rollback()

        # Same credentials, a stranger's uuid: the policies simply follow the GUC.
        cur.execute("select set_config('project1.actor_id', %s, true)",
                    ("00000000-0000-0000-0000-0000000000ff",))
        cur.execute("select count(*) from public.m2_assessments")
        direct["assessments_visible_as_stranger"] = cur.fetchone()[0]
        conn.rollback()

        cur.execute("select current_user, session_user")
        direct["role"] = list(cur.fetchone())
        conn.rollback()
    out["direct_db"] = direct

    # The control that would defend this is designed but not installed here.
    with psycopg2.connect(dsn()) as conn:
        cur = conn.cursor()
        cur.execute("select count(*) from information_schema.schemata "
                    "where schema_name = 'project1_identity'")
        identity_schema = cur.fetchone()[0]
    out["protected_identity"] = {
        "schema_present": bool(identity_schema),
        "setting_enabled": False,
        "note": ("m2_protected_identity_enabled is off and its schema is absent. "
                 "migrations/m2/20261121_01 is guarded to database "
                 "project1_m2_bcb_test and self-describes as "
                 "'PRIVATE TEST REHEARSAL ONLY ... not approved or usable for original Dss', "
                 "so it cannot be installed on project1_workflow_tests."),
    }
    record("direct DB access can read any owner's rows by writing the GUC",
           direct["assessments_visible_as_owner"] > 0
           and direct["assessments_visible_as_stranger"] == 0,
           {"owner_sees": direct["assessments_visible_as_owner"],
            "stranger_sees": direct["assessments_visible_as_stranger"],
            "verdict": "VECTOR CONFIRMED — unmitigated in this environment"})

    out["passed"] = sum(1 for c in out["checks"] if c["pass"])
    out["total"] = len(out["checks"])
    OUT.write_text(json.dumps(out, indent=2), encoding="utf-8")
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
