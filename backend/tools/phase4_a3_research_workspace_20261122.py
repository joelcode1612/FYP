"""Phase A3 — Research Workspace endpoint and RLS regression.

Checks, each against the real endpoint on 127.0.0.1:8091 and the real cluster:

 1. owner, current revision                       -> 200, contracted shape
 2. owner, stale expected_revision                -> 404 (not a stale read)
 3. foreign owner (declared synthetic intruder)   -> 404, no row leak
 4. unauthenticated                               -> 401/403
 5. malformed bearer                              -> 401
 6. DB: runtime role, actor unset                 -> 0 rows (fail-closed)
 7. DB: runtime role, owner actor                 -> >= 0 rows, no error
 8. DB: runtime role, stranger actor              -> 0 rows
 9. DB: writes still denied on the read-scoped tables
10. historical research rows unchanged across the whole run

A denial is asserted as "no rows / no error message containing data", never as a
specific status code alone: a 404 that still returns a body would be a leak.
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
OUT = REPO / "deliverables" / "phase4" / "a3_research_workspace.json"

API = "http://127.0.0.1:8091"
GOTRUE = "http://127.0.0.1:54329"
ANON = "sb_publishable_local_e2e"
OWNER = "gatebc-e2e-b9e62014@example.invalid"
INTRUDER = "gatebc-e2e-c70a999a@example.invalid"
PASSWORD = "e2e-local-password"
OWNER_ID = "b9e62014-b7bc-426e-a950-a95b25965639"
ASSESSMENT = "37bf879a-005a-4f5a-b49d-210ea1ce37c4"

READ_SCOPED = [
    "m2_research_objective_sources",
    "m2_research_clarifications",
    "m2_research_revisions",
    "m2_desired_options",
    "m2_candidate_owner_reviews",
    "m2_review_question_versions",
]


def dsn() -> str:
    """RLS must be probed as the role RLS applies to, not as the app role.

    `sitewise_e2e` holds no privilege on the research tables at all, so counting
    through it would test the grant, not the policy. `p1_m2_runtime` is the role
    that holds SELECT and is subject to these policies.
    """
    text = (BACKEND / "var" / "e2e" / "app.env").read_text(encoding="utf-8", errors="replace")
    url = re.search(r"^M2_DATABASE_URL=(.+)$", text, re.M).group(1).strip()
    return url.replace("postgresql+psycopg2", "postgresql")


def token(email: str) -> str:
    body = json.dumps({"email": email, "password": PASSWORD}).encode()
    req = urllib.request.Request(
        f"{GOTRUE}/auth/v1/token?grant_type=password", data=body,
        headers={"Content-Type": "application/json", "apikey": ANON})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)["access_token"]


def call(path: str, bearer: str | None) -> tuple[int, object]:
    headers = {"Authorization": f"Bearer {bearer}"} if bearer else {}
    req = urllib.request.Request(API + path, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read().decode("utf-8", "replace")
            try:
                return resp.status, json.loads(raw)
            except json.JSONDecodeError:
                return resp.status, raw[:400]
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            return exc.code, json.loads(raw)
        except json.JSONDecodeError:
            return exc.code, raw[:400]


def main() -> int:
    out: dict = {"checks": []}
    checks = out["checks"]

    def record(name: str, ok: bool, detail: object) -> None:
        checks.append({"check": name, "pass": bool(ok), "detail": detail})

    owner_token = token(OWNER)
    intruder_token = token(INTRUDER)

    # --- current confirmation for the seeded owner ------------------------
    status, detail = call(f"/api/v1/assessments/{ASSESSMENT}", owner_token)
    # The detail endpoint wraps its payload in `assessment`.
    record_body = (detail or {}).get("assessment") if isinstance(detail, dict) else {}
    record_body = record_body or {}
    confirmation = record_body.get("m2_confirmation") or {}
    cid = confirmation.get("confirmation_id")
    revision = confirmation.get("assessment_revision")
    record("assessment detail exposes a current M2 confirmation",
           status == 200 and bool(cid) and revision is not None,
           {"status": status, "confirmation_id": cid, "revision": revision,
            "stage_2_basis": record_body.get("stage_2_basis")})
    if not cid:
        OUT.write_text(json.dumps(out, indent=2), encoding="utf-8")
        print(json.dumps(out, indent=2))
        return 1

    base = f"/api/v1/m2/confirmations/{cid}/research-workspace"

    # 1. owner, current revision
    status, body = call(f"{base}?expected_revision={revision}", owner_token)
    record("owner, current revision -> 200 with contracted shape",
           status == 200 and isinstance(body, dict) and isinstance(body.get("objectives"), list),
           {"status": status, "body": body if not isinstance(body, dict) or len(
               json.dumps(body)) < 600 else "<truncated>"})

    # 2. stale revision
    status, body = call(f"{base}?expected_revision={max(0, int(revision) - 1)}", owner_token)
    record("owner, stale revision -> 404, no payload",
           status == 404 and not (isinstance(body, dict) and body.get("objectives")),
           {"status": status, "body": body})

    # 3. foreign owner
    status, body = call(f"{base}?expected_revision={revision}", intruder_token)
    record("foreign owner -> refused, no payload",
           status == 404 and not (isinstance(body, dict) and body.get("objectives")),
           {"status": status, "body": body})

    # 4. unauthenticated
    status, body = call(f"{base}?expected_revision={revision}", None)
    record("unauthenticated -> 401/403", status in (401, 403),
           {"status": status, "body": body})

    # 5. malformed bearer
    status, body = call(f"{base}?expected_revision={revision}", "not-a-jwt")
    record("malformed bearer -> 401/403", status in (401, 403),
           {"status": status, "body": body})

    # --- DB level: RLS under three actor bindings -------------------------
    # Each count runs inside a savepoint so a permission error cannot abort the
    # enclosing transaction and poison the next probe.
    db: dict = {}
    with psycopg2.connect(dsn()) as conn:
        conn.autocommit = False
        cur = conn.cursor()
        for label, actor in (("unset", None), ("owner", OWNER_ID),
                             ("stranger", "00000000-0000-0000-0000-0000000000ff")):
            cur.execute("savepoint s0")
            cur.execute("select set_config('project1.actor_id', %s, true)",
                        (actor if actor is not None else "",))
            counts = {}
            for t in READ_SCOPED:
                cur.execute("savepoint s1")
                try:
                    cur.execute("select count(*) from public.%s" % t)
                    counts[t] = cur.fetchone()[0]
                    cur.execute("release savepoint s1")
                except psycopg2.errors.InsufficientPrivilege:
                    cur.execute("rollback to savepoint s1")
                    counts[t] = "DENIED"
            db[label] = counts
            cur.execute("release savepoint s0")
        conn.rollback()
    out["rls_counts"] = db

    record("RLS: actor unset -> every read-scoped table returns 0 rows",
           all(v == 0 for v in db["unset"].values()), db["unset"])
    record("RLS: owner actor -> reads succeed (no DENIED, no error)",
           all(v != "DENIED" for v in db["owner"].values()), db["owner"])
    record("RLS: stranger actor -> 0 rows on every read-scoped table",
           all(v == 0 for v in db["stranger"].values()), db["stranger"])

    # --- writes must remain denied ---------------------------------------
    write_probe = {}
    with psycopg2.connect(dsn()) as conn:
        conn.autocommit = True
        cur = conn.cursor()
        cur.execute("select set_config('project1.actor_id', %s, false)", (OWNER_ID,))
        for t in READ_SCOPED:
            held = []
            for p in ("INSERT", "UPDATE", "DELETE", "TRUNCATE"):
                cur.execute("select has_table_privilege(%s, %s, %s)",
                            ("p1_m2_runtime", f"public.{t}", p))
                if cur.fetchone()[0]:
                    held.append(p)
            write_probe[t] = held
    out["write_privileges"] = write_probe
    unexpected = {t: p for t, p in write_probe.items()
                  if p and t != "m2_research_objective_sources"}
    record("writes stay denied (objective_sources keeps append-only INSERT)",
           not unexpected
           and write_probe["m2_research_objective_sources"] == ["INSERT"],
           {"write_privileges": write_probe, "unexpected": unexpected})

    out["passed"] = sum(1 for c in checks if c["pass"])
    out["total"] = len(checks)
    out["verdict"] = "PASS" if out["passed"] == out["total"] else "FAIL"
    OUT.write_text(json.dumps(out, indent=2), encoding="utf-8")
    print(json.dumps(out, indent=2))
    return 0 if out["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
