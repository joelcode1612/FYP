"""Phase B — BCB construction, reproducibility, readback and validity.

Live-API checks against the disposable server. Validity is exercised three ways:

  * current valid confirmation          -> 201, persisted
  * stale expected_revision             -> refusal
  * missing / non-positive validity     -> configuration refusal (separate runs,
                                           reported by phase4_b2_validity_config)

Genuine expiry is covered by phase4_b2_expiry_clock, which drives the service
clock instead of ageing a real confirmation: rewriting `created_at` on an audit
row to manufacture an expired case would be fabricating evidence.
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
OUT = REPO / "deliverables" / "phase4" / "b1_bcb_construction.json"

API = "http://127.0.0.1:8091"
GOTRUE = "http://127.0.0.1:54329"
ANON = "sb_publishable_local_e2e"
OWNER = "gatebc-e2e-b9e62014@example.invalid"
INTRUDER = "gatebc-e2e-c70a999a@example.invalid"
PASSWORD = "e2e-local-password"
ASSESSMENT = "37bf879a-005a-4f5a-b49d-210ea1ce37c4"


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


def call(method: str, path: str, bearer: str | None, body: dict | None = None):
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

    def record(name, ok, detail):
        checks.append({"check": name, "pass": bool(ok), "detail": detail})

    owner = token(OWNER)
    intruder = token(INTRUDER)

    status, detail = call("GET", f"/api/v1/assessments/{ASSESSMENT}", owner)
    body = (detail or {}).get("assessment") or {}
    conf = body.get("m2_confirmation") or {}
    cid, revision = conf.get("confirmation_id"), conf.get("assessment_revision")
    # The BCB route is namespaced under /m2 and takes the M2 assessment id, not
    # the marketplace assessment id the detail endpoint was addressed with.
    m2_assessment = conf.get("m2_assessment_id")
    record("confirmed synthetic M2 source available",
           status == 200 and bool(cid) and bool(m2_assessment),
           {"status": status, "confirmation_id": cid, "revision": revision,
            "m2_assessment_id": m2_assessment})
    if not cid or not m2_assessment:
        OUT.write_text(json.dumps(out, indent=2), encoding="utf-8")
        return 1

    payload = {"confirmation_id": cid, "expected_revision": revision}
    base = f"/api/v1/m2/assessments/{m2_assessment}/business-context"

    # --- 1. construction ---------------------------------------------------
    # The contract is 201 on first persistence and 200 on replay. Asserting a
    # blanket 201 would fail a correct replay, and asserting a blanket 200 would
    # hide a duplicate insert, so the status is checked against `replayed`.
    status, ctx = call("POST", base, owner, payload)
    replayed = bool((ctx or {}).get("replayed"))
    record("construct from confirmed source -> 201 first, 200 replay",
           status == (200 if replayed else 201) and isinstance(ctx, dict)
           and ctx.get("lifecycle_status") == "PERSISTED",
           {"status": status, "replayed": replayed,
            "context_id": (ctx or {}).get("context_id"),
            "schema_version": ((ctx or {}).get("packet") or {}).get("schema_version"),
            "builder_version": ((ctx or {}).get("packet") or {}).get("context_version"),
            "error": (ctx or {}).get("detail") if status >= 400 else None})
    context_id = (ctx or {}).get("context_id")

    if context_id:
        packet = (ctx or {}).get("packet") or {}
        # --- 2. readback ---------------------------------------------------
        status, back = call("GET", f"{base}s/{context_id}", owner)
        back_packet = (back or {}).get("packet") or {}
        record("persisted context readback -> 200, identical identity and packet hash",
               status == 200 and (back or {}).get("context_id") == context_id
               and back_packet.get("packet_hash") == packet.get("packet_hash"),
               {"status": status,
                "context_id": (back or {}).get("context_id"),
                "confirmation_id": (back or {}).get("confirmation_id"),
                "assessment_revision": (back or {}).get("assessment_revision"),
                "schema_version": back_packet.get("schema_version"),
                "context_version": back_packet.get("context_version"),
                "packet_hash": back_packet.get("packet_hash"),
                "snapshot_digest": (back_packet.get("provenance") or {}).get("snapshot_digest")})

        # --- 2b. packet content --------------------------------------------
        conf_block = packet.get("confirmation") or {}
        record("packet carries the confirmed M2 source, not a substitute",
               packet.get("schema_version") == "business-context-package/1.1"
               and len(packet.get("m2_answers") or []) == 11
               and conf_block.get("id") == cid
               and conf_block.get("status") == "CURRENT_CONFIRMED",
               {"schema_version": packet.get("schema_version"),
                "context_version": packet.get("context_version"),
                "m2_answers": len(packet.get("m2_answers") or []),
                "confirmation_id": conf_block.get("id"),
                "confirmation_status": conf_block.get("status"),
                "revision": conf_block.get("revision"),
                "snapshot_digest": conf_block.get("digest")})

        # Absence must be represented, never filled in.
        record("unknown information is preserved as absent, not invented",
               packet.get("geography") is None
               and packet.get("supporting_sources") == []
               and packet.get("findings") == []
               and len(packet.get("unknowns") or []) >= 1,
               {"geography": packet.get("geography"),
                "supporting_sources": packet.get("supporting_sources"),
                "findings": packet.get("findings"),
                "unknowns": len(packet.get("unknowns") or [])})

        # --- 3. reproducibility --------------------------------------------
        status2, ctx2 = call("POST", base, owner, payload)
        record("identical inputs -> replay, not a second context",
               status2 == 200 and (ctx2 or {}).get("context_id") == context_id,
               {"status": status2,
                "context_id": (ctx2 or {}).get("context_id"),
                "same_context": (ctx2 or {}).get("context_id") == context_id})

        # --- 4. foreign owner ----------------------------------------------
        status3, ctx3 = call("POST", base, intruder, payload)
        record("foreign owner -> refused, no context id",
               status3 >= 400 and not (ctx3 or {}).get("context_id"),
               {"status": status3})

        # --- 5. no authority promotion -------------------------------------
        record("BCB asserts no QG/QJ execution authority",
               ctx.get("qj_execution_authorized") is False
               and ctx.get("qg_execution_authorized") is False,
               {"qj_execution_authorized": ctx.get("qj_execution_authorized"),
                "qg_execution_authorized": ctx.get("qg_execution_authorized")})

    # --- 6. stale revision -------------------------------------------------
    status, stale = call("POST", base, owner,
                         {"confirmation_id": cid, "expected_revision": max(0, int(revision) - 1)})
    record("stale expected_revision -> refused",
           status >= 400 and not (stale or {}).get("context_id"),
           {"status": status,
            "code": ((stale or {}).get("detail") or {}).get("code")
            if isinstance((stale or {}).get("detail"), dict) else None})

    # --- 7. unknown confirmation ------------------------------------------
    status, ghost = call("POST", base, owner,
                         {"confirmation_id": "00000000-0000-0000-0000-000000000001",
                          "expected_revision": revision})
    record("unknown confirmation -> refused",
           status >= 400 and not (ghost or {}).get("context_id"),
           {"status": status})

    # --- 8. database truth -------------------------------------------------
    with psycopg2.connect(dsn()) as conn:
        conn.autocommit = False
        cur = conn.cursor()
        # RLS on these tables is actor-keyed, so the count is meaningless without
        # a binding. Set it in this transaction, not the session.
        cur.execute("select set_config('project1.actor_id', %s, true)",
                    ("b9e62014-b7bc-426e-a950-a95b25965639",))
        cur.execute("select count(*) from public.m2_business_contexts")
        contexts = cur.fetchone()[0]
        cur.execute("select count(*) from public.m2_business_contexts "
                    "where assessment_revision = %s", (revision,))
        at_revision = cur.fetchone()[0]
        cur.execute("select count(*) from public.m2_business_context_builds")
        builds = cur.fetchone()[0]
        cur.execute("""select context_id::text, schema_version, builder_version, purpose,
                              concept_version, snapshot_digest, packet_hash,
                              assessment_revision, lifecycle_status
                       from public.m2_business_contexts order by assessment_revision desc limit 3""")
        rows = cur.fetchall()
        cur.execute("select count(*) from public.m2_bdj_findings")
        findings = cur.fetchone()[0]
        cur.execute("select count(*) from public.m2_bdj_evaluations")
        evals = cur.fetchone()[0]
        conn.rollback()
    out["database"] = {
        "business_contexts": contexts,
        "contexts_at_current_revision": at_revision,
        "business_context_builds": builds,
        "bdj_findings": findings,
        "bdj_evaluations": evals,
        "latest": [
            {"context_id": r[0], "schema_version": r[1], "builder_version": r[2],
             "purpose": r[3], "concept_version": r[4], "snapshot_digest": r[5],
             "packet_hash": r[6], "assessment_revision": r[7], "lifecycle_status": r[8]}
            for r in rows
        ],
    }
    # One context per confirmed revision. An earlier revision may legitimately
    # hold its own immutable context; what must never happen is two for one
    # revision, which would mean the replay path persisted a duplicate.
    record("exactly one context at the current revision",
           at_revision == 1, {"contexts_at_current_revision": at_revision,
                              "total": contexts})
    record("no BDJ finding or evaluation created by BCB construction",
           findings == 0 and evals == 0,
           {"bdj_findings": findings, "bdj_evaluations": evals})

    out["passed"] = sum(1 for c in checks if c["pass"])
    out["total"] = len(checks)
    out["verdict"] = "PASS" if out["passed"] == out["total"] else "FAIL"
    OUT.write_text(json.dumps(out, indent=2), encoding="utf-8")
    print(json.dumps(out, indent=2))
    return 0 if out["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
