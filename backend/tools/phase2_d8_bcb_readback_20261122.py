"""Defect D8 — BCB HTTP readback and status verification.

Proves the correction against the authorised disposable cluster
(``project1_workflow_tests@127.0.0.1:5433``) with real HTTP requests, not by
inspecting the response model:

1. an existing context whose recorded ``created_at`` is NULL reads successfully
   and reports ``null`` rather than a 500 (absence represented, not invented);
2. the matching status route reads successfully;
3. a brand-new context, constructed through the real service, records the
   timestamp of its own insert transaction;
4. owner scoping still refuses a foreign principal;
5. the read requests create no build row and mutate no build state.

No protected database is touched, no .env is edited, no cloud model is called.
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
ROOT = BACKEND.parent
TARGET_DB = "project1_workflow_tests"
PORT = 5433
HOST = "127.0.0.1"
M2_PREFIX = "/api/v1/m2"

sys.path.insert(0, str(BACKEND / "src"))

#: Existing persisted contexts (recorded created_at is NULL on this cluster).
EXISTING = [
    {"assessment": "d82b78ff-dad0-41d8-afa4-0205ad199a20",
     "owner": "c70a999a-50c6-4a31-8f7a-b914d0a5c641",
     "confirmation": "658dfcc7-75e6-4f76-b245-71678459ba60",
     "context": "79151dfe-c411-54d9-b03c-47b19ce44ecb"},
    {"assessment": "e0124bfd-e54b-4d57-bc19-2023c8e7a5e6",
     "owner": "b9e62014-b7bc-426e-a950-a95b25965639",
     "confirmation": "b73d9297-ac39-42f4-9213-4fdd5254af28",
     "context": "0af90393-46b3-56ed-bd76-7776cd5ec1c2"},
]

#: A confirmed assessment with no persisted context, used to prove that a new
#: context receives a real creation timestamp.
FRESH = {"assessment": "4a7ac7de-aeac-4d6a-91b0-53e6628af334",
         "owner": "54bd4dce-52d1-47b5-bdaf-9e4ef4175a99",
         "confirmation": "3655e12a-4e08-4f5b-b46c-3621039dfb90",
         "revision": 11}

FOREIGN = "11111111-2222-3333-4444-555555555555"

steps: list[dict] = []
verdicts: dict[str, str] = {}


def step(name, result, **detail):
    entry = {"step": name, "result": result}
    entry.update({k: v for k, v in detail.items() if v is not None})
    steps.append(entry)
    print(f"  {result:<6} {name[:58]:<58} {str(detail.get('note', ''))[:58]}")
    return entry


def main():
    import psycopg2
    from psycopg2.extras import RealDictCursor

    from tools import phase2_gateBC_http_e2e_20261122 as harness
    from tools.phase2_gateBC_regression_20261122 import builds_snapshot, set_environment

    url, configured_db = harness.base_url()
    # The workflow and /m2 surfaces are opt-in and absent from the persistent
    # .env, so every disposable override is applied before any module that
    # instantiates application settings is imported.
    set_environment(url)
    conn = psycopg2.connect(harness.psycopg_dsn(url))
    conn.autocommit = True
    cur = conn.cursor(cursor_factory=RealDictCursor)

    cur.execute("SELECT current_database() db, inet_server_port() port, current_user cu")
    ident = dict(cur.fetchone())
    if ident["db"] != TARGET_DB or ident["port"] != PORT:
        raise SystemExit(f"REFUSED: server identity mismatch {ident}")
    step("D8.0 server identity", "PASS",
         note=f"{ident['db']}@{HOST}:{ident['port']} as {ident['cu']} "
              f"(configured db {configured_db} was never connected)")

    # The identity mirror is disposable-only; it refuses any other database.
    cur.execute(harness.FIXTURE.read_text(encoding="utf-8"))
    harness.OWNER = FRESH["owner"]
    harness.EMAIL = f"d8-fresh-{FRESH['owner'][:8]}@example.invalid"
    harness.provision_fixture(cur)
    step("D8.1 identity fixture", "PASS",
         note=f"users row for {FRESH['owner'][:8]} ready")

    # ---- column contract -------------------------------------------------
    cur.execute("""
        SELECT table_name, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema='public' AND column_name='created_at'
          AND table_name IN ('m2_business_contexts','m2_business_context_builds')
        ORDER BY table_name""")
    columns = [dict(r) for r in cur.fetchall()]
    defaulted = all(c["column_default"] == "now()" for c in columns)
    step("D8.2 created_at default restored", "PASS" if defaulted else "FAIL",
         note="; ".join(f"{c['table_name']}: nullable={c['is_nullable']} "
                        f"default={c['column_default']}" for c in columns))

    before = builds_snapshot(cur)
    step("D8.3 build fingerprint BEFORE", "PASS",
         note=f"rows={before['row_count']} attempts={before['sum_attempt_count']} "
              f"digest={before['digest'][:16]}")

    app, token = harness.build_app()
    from fastapi.testclient import TestClient

    client = TestClient(app, raise_server_exceptions=False)

    def call(owner, email, method, path, body=None):
        headers = {"Authorization": f"Bearer {token(owner, email)}"}
        return client.request(method, path, json=body, headers=headers)

    # ---- existing NULL-timestamp rows must read --------------------------
    reads = []
    for spec in EXISTING:
        email = f"d8-existing-{spec['owner'][:8]}@example.invalid"
        harness.OWNER = spec["owner"]
        harness.EMAIL = email
        harness.provision_fixture(cur)
        read = call(spec["owner"], email, "GET",
                    f"{M2_PREFIX}/assessments/{spec['assessment']}"
                    f"/business-contexts/{spec['context']}")
        status = call(spec["owner"], email, "GET",
                      f"{M2_PREFIX}/assessments/{spec['assessment']}/confirmations/"
                      f"{spec['confirmation']}/business-context-status")
        foreign = call(FOREIGN, "d8-foreign@example.invalid", "GET",
                       f"{M2_PREFIX}/assessments/{spec['assessment']}"
                       f"/business-contexts/{spec['context']}")
        body = read.json() if read.status_code == 200 else {}
        status_body = status.json() if status.status_code == 200 else {}
        entry = {
            "scenario": "existing-null-timestamp",
            "context_id": spec["context"],
            "read_status": read.status_code,
            "read_created_at": body.get("created_at"),
            "read_contract": body.get("contract_version"),
            "read_lifecycle": body.get("lifecycle_status"),
            "read_has_packet": isinstance(body.get("packet"), dict),
            "read_qg_authorized": body.get("qg_execution_authorized"),
            "status_status": status.status_code,
            "status_created_at": status_body.get("created_at"),
            "status_updated_at": status_body.get("updated_at"),
            "status_source_is_current": status_body.get("source_is_current"),
            "foreign_status": foreign.status_code,
        }
        reads.append(entry)
        step(f"D8.4 read existing {spec['context'][:8]}",
             "PASS" if (read.status_code == 200 and status.status_code == 200
                        and foreign.status_code in (403, 404)) else "FAIL",
             note=f"GET={read.status_code} created_at={entry['read_created_at']} "
                  f"status={status.status_code} foreign={foreign.status_code}")

    after_reads = builds_snapshot(cur)
    unchanged = (before["digest"] == after_reads["digest"]
                 and before["sum_attempt_count"] == after_reads["sum_attempt_count"]
                 and before["max_updated_at"] == after_reads["max_updated_at"])
    step("D8.5 reads created/mutated no build row", "PASS" if unchanged else "FAIL",
         note=f"digest {before['digest'][:16]} -> {after_reads['digest'][:16]} "
              f"over {len(reads) * 3} read requests")

    # ---- a new context must record its own timestamp ---------------------
    email = f"d8-fresh-{FRESH['owner'][:8]}@example.invalid"
    created = call(FRESH["owner"], email, "POST",
                   f"{M2_PREFIX}/assessments/{FRESH['assessment']}/business-context",
                   {"confirmation_id": FRESH["confirmation"],
                    "expected_revision": FRESH["revision"]})
    created_body = created.json() if created.status_code in (200, 201) else {}
    new_context = created_body.get("context_id")
    step("D8.6 new context constructed", "PASS" if created.status_code == 201 else "FAIL",
         note=f"POST={created.status_code} replayed={created_body.get('replayed')} "
              f"context={str(new_context)[:8]}")

    cur.execute("""
        SELECT context_id, created_at, lifecycle_status
        FROM public.m2_business_contexts WHERE context_id=%s""", (new_context,))
    stored = cur.fetchone()
    stored = {k: str(v) for k, v in dict(stored).items()} if stored else {}
    step("D8.7 new row recorded created_at", "PASS" if stored.get("created_at") not in (None, "None")
         else "FAIL", note=f"stored created_at={stored.get('created_at')}")

    new_read = call(FRESH["owner"], email, "GET",
                    f"{M2_PREFIX}/assessments/{FRESH['assessment']}"
                    f"/business-contexts/{new_context}")
    new_body = new_read.json() if new_read.status_code == 200 else {}
    new_status = call(FRESH["owner"], email, "GET",
                      f"{M2_PREFIX}/assessments/{FRESH['assessment']}/confirmations/"
                      f"{FRESH['confirmation']}/business-context-status")
    new_status_body = new_status.json() if new_status.status_code == 200 else {}
    step("D8.8 new context readback", "PASS"
         if (new_read.status_code == 200 and new_body.get("created_at")) else "FAIL",
         note=f"GET={new_read.status_code} created_at={new_body.get('created_at')}")
    step("D8.9 new status readback", "PASS"
         if (new_status.status_code == 200 and new_status_body.get("created_at")) else "FAIL",
         note=f"status={new_status.status_code} created_at={new_status_body.get('created_at')} "
              f"state={new_status_body.get('status')}")

    new_foreign = call(FOREIGN, "d8-foreign@example.invalid", "GET",
                       f"{M2_PREFIX}/assessments/{FRESH['assessment']}"
                       f"/business-contexts/{new_context}")
    step("D8.10 new context owner scoping", "PASS"
         if new_foreign.status_code in (403, 404) else "FAIL",
         note=f"foreign GET={new_foreign.status_code}")

    # Replay must return the same recorded timestamp, not a new one.
    replay = call(FRESH["owner"], email, "POST",
                  f"{M2_PREFIX}/assessments/{FRESH['assessment']}/business-context",
                  {"confirmation_id": FRESH["confirmation"],
                   "expected_revision": FRESH["revision"]})
    replay_body = replay.json() if replay.status_code in (200, 201) else {}
    same = (replay.status_code == 200 and replay_body.get("replayed") is True
            and replay_body.get("created_at") == new_body.get("created_at"))
    step("D8.11 replay keeps the original timestamp", "PASS" if same else "FAIL",
         note=f"POST={replay.status_code} replayed={replay_body.get('replayed')} "
              f"created_at={replay_body.get('created_at')}")

    final = builds_snapshot(cur)
    step("D8.12 build fingerprint AFTER", "PASS",
         note=f"rows={final['row_count']} attempts={final['sum_attempt_count']} "
              f"digest={final['digest'][:16]}")

    # ---- verdicts --------------------------------------------------------
    existing_ok = all(r["read_status"] == 200 and r["status_status"] == 200
                      and r["read_created_at"] is None for r in reads)
    verdicts["BCB_HTTP_READBACK_CORRECTION"] = "PASS" if (
        existing_ok and created.status_code == 201 and new_read.status_code == 200) else "FAIL"
    verdicts["BCB_NULL_TIMESTAMP_HANDLED"] = "PASS" if existing_ok else "FAIL"
    verdicts["BCB_NEW_TIMESTAMP_RECORDED"] = "PASS" if (
        stored.get("created_at") not in (None, "None") and new_body.get("created_at")) else "FAIL"
    verdicts["BCB_OWNER_SCOPING_ENFORCED"] = "PASS" if (
        all(r["foreign_status"] in (403, 404) for r in reads)
        and new_foreign.status_code in (403, 404)) else "FAIL"
    verdicts["BCB_READ_CREATES_NO_BUILD_ROW"] = "PASS" if unchanged else "FAIL"
    verdicts["BCB_REPLAY_TIMESTAMP_STABLE"] = "PASS" if same else "FAIL"

    evidence = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "target": {"database": TARGET_DB, "host": HOST, "port": PORT,
                   "admin_user": ident["cu"]},
        "defect": "D8 — BCB readback/status returned 500 because created_at was NULL "
                  "and the response model required a datetime",
        "root_cause": "disposable cluster drift: the adopted DDL declares "
                      "created_at timestamptz NOT NULL DEFAULT now() on both BCB "
                      "tables, but the clone's columns were nullable with no default",
        "correction": {
            "response_model": "created_at is datetime | None on ContextResponse and "
                              "ContextStatusResponse; absence is reported, never invented",
            "migration": "migrations/m2/20261122_10_bcb_created_at_disposable.sql "
                         "restores DEFAULT now() for new rows",
            "backfill": "none — existing creation times are not recoverable; the "
                        "build table is not a reliable witness (the primary build row "
                        "was overwritten by a later HELD attempt with context_id NULL)",
            "not_null": "not restored: it cannot be applied while historical rows are "
                        "NULL and must not be satisfied by invented values",
        },
        "columns": columns,
        "reads": reads,
        "new_context": {"assessment": FRESH["assessment"],
                        "confirmation": FRESH["confirmation"],
                        "context_id": new_context,
                        "post_status": created.status_code,
                        "stored_created_at": stored.get("created_at"),
                        "read_created_at": new_body.get("created_at"),
                        "status_created_at": new_status_body.get("created_at"),
                        "status_state": new_status_body.get("status"),
                        "foreign_status": new_foreign.status_code,
                        "replay_status": replay.status_code,
                        "replay_created_at": replay_body.get("created_at")},
        "build_fingerprint": {"before": before, "after_reads": after_reads,
                              "final": final},
        "verdicts": verdicts, "steps": steps,
    }
    out = ROOT / "deliverables/phase2/BDJ_D8_BCB_READBACK_20261122.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    print(json.dumps(verdicts, indent=2))
    print(f"evidence -> {out}")
    conn.close()
    return 0 if "FAIL" not in verdicts.values() else 1


if __name__ == "__main__":
    raise SystemExit(main())
