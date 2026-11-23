"""M2 preservation + BDJ consumption proof (disposable target only).

1. Compares the registered M2V1 definition in `project1_workflow_tests` with the
   read-only `Dss` definition: version, schema digest, item keys, answer kinds,
   option codes, dependency rules.
2. Reads the confirmed projection and runs `BDJEngine.propose_objectives` with a
   simulated provider.
3. Proves M2 data was not modified: row count + max(created_at) before and after.

`Dss` is opened READ ONLY. No write of any kind is issued against it.

Run:
    PYTHONPATH=src .venv/Scripts/python.exe tools/phase2_compat_and_consumption_20261121.py
"""
import json
import uuid
from pathlib import Path

import psycopg2
from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session

TARGET_DB = "project1_workflow_tests"
PORT = 5433
BACKEND = Path(__file__).resolve().parents[1]
INSTRUMENT = "M2V1-20261114-1"


def urls():
    for line in (BACKEND / ".env").read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith("DATABASE_URL="):
            base = line.split("=", 1)[1].strip().replace("postgresql+psycopg2://",
                                                         "postgresql://")
            host = base.rsplit("/", 1)[0]
            return (host.replace(":5432", f":{PORT}") + "/" + TARGET_DB), (host + "/Dss")
    raise SystemExit("DATABASE_URL missing")


def definition(conn):
    with conn.cursor() as cur:
        cur.execute("select id, code, version_tag, schema_digest, approval_state "
                    "from public.m2_instrument_versions where version_tag=%s", (INSTRUMENT,))
        inst = cur.fetchone()
        if inst is None:
            return None
        cur.execute("select item_key, answer_kind, option_values, allowed_states, "
                    "requiredness, sort_order from public.m2_item_versions "
                    "where instrument_id=%s order by item_key", (inst[0],))
        items = cur.fetchall()
    return {"instrument": {"id": str(inst[0]), "code": inst[1], "version_tag": inst[2],
                           "schema_digest": inst[3], "approval_state": inst[4]},
            "items": [{"item_key": r[0], "answer_kind": r[1],
                       "option_codes": [o.get("code") for o in (r[2] or {}).get("options", [])],
                       "rules": (r[2] or {}).get("rules", {}),
                       "allowed_states": r[3], "requiredness": r[4], "sort_order": r[5]}
                      for r in items]}


def main():
    test_url, dss_url = urls()
    if f":{PORT}/" not in test_url:
        raise SystemExit("REFUSED: not the disposable target")

    test_conn = psycopg2.connect(test_url)
    dss_conn = psycopg2.connect(dss_url)
    dss_conn.autocommit = False
    with dss_conn.cursor() as cur:
        cur.execute("SET TRANSACTION READ ONLY")

    local = definition(test_conn)
    remote = definition(dss_conn)

    diffs = []
    if local["instrument"]["schema_digest"] != remote["instrument"]["schema_digest"]:
        diffs.append("schema_digest")
    if local["instrument"]["version_tag"] != remote["instrument"]["version_tag"]:
        diffs.append("version_tag")
    lk = [i["item_key"] for i in local["items"]]
    rk = [i["item_key"] for i in remote["items"]]
    if lk != rk:
        diffs.append(f"item_keys local={len(lk)} dss={len(rk)}")
    for a, b in zip(local["items"], remote["items"]):
        for field in ("answer_kind", "option_codes", "rules", "allowed_states", "requiredness"):
            if a[field] != b[field]:
                diffs.append(f"{a['item_key']}.{field}")

    print("=" * 78)
    print("1. M2V1 PRESERVATION — disposable vs Dss (read-only)")
    print("=" * 78)
    print("disposable:", local["instrument"]["version_tag"], local["instrument"]["schema_digest"][:12],
          "| items", len(local["items"]))
    print("dss       :", remote["instrument"]["version_tag"], remote["instrument"]["schema_digest"][:12],
          "| items", len(remote["items"]))
    print("differences:", diffs or "none")

    # 2. Confirmed projection + BDJ consumption.
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    from sitewise.project1.projection import M2SourceProjection
    from sitewise.project1.bdj import BDJEngine
    from sitewise.project1.rules import bdj_m2v1_ig_proposal as rules
    from sitewise.project1.objective_proposal import CONTRACT_VERSION, ObjectiveProposal
    from sitewise.services.business_context_v1 import source_hash

    engine = create_engine(test_url.replace("postgresql://", "postgresql+psycopg2://", 1))
    with Session(engine) as session:
        row = session.execute(text(
            "select assessment_id, actor_user_id, assessment_revision, id, snapshot_digest "
            "from public.m2_confirmation_snapshots order by created_at desc limit 1")).one()
        aid, actor, revision, conf_id, digest = row
        repo = SqlModelM2Repository(session)
        before = session.execute(text(
            "select count(*), coalesce(max(created_at)::text,'') from public.m2_answer_revisions"
        )).one()
        packet = M2SourceProjection(repo).read(uuid.UUID(str(aid)), uuid.UUID(str(actor)),
                                               revision)
        packet["confirmation"] = {"confirmation_id": str(conf_id), "snapshot_digest": digest}
        from sitewise.project1.contracts import digest as fp_digest
        packet["source_fingerprint"] = fp_digest({k: v for k, v in packet.items()
                                                  if k != "source_fingerprint"})
        ctx = {"schema_version": "persisted-business-context/1", "context_version": "1.1",
               "confirmation": {"id": str(conf_id), "revision": revision,
                                "digest": digest, "status": "CURRENT_CONFIRMED"},
               "m2_answers": [{k: d[k] for k in ("item_key", "answer_revision_id",
                                                 "item_version_id", "answer_state", "value")}
                              for d in packet["declarations"]],
               "permissions": {"report_admission": False, "report_release": False,
                               "qj_execution": False, "qg_execution": False}}
        ctx["packet_hash"] = source_hash(ctx)

        def rec(key, status="MOST_SUGGESTED"):
            d = next(x for x in packet["declarations"] if x["item_key"] == key)
            return {"recommendation_status": status,
                    "problem_type": ("SOURCE_CONFIRMED_INFORMATION_GAP"
                                     if status == "MOST_SUGGESTED"
                                     else "EXPLORATORY_RESEARCH_NEED"),
                    "problem": (f"The confirmed answer to {key} is {d['value']}."
                                if status == "MOST_SUGGESTED" else None),
                    "research_objective": f"To investigate what {key} leaves unresolved.",
                    "source_refs": ([{"item_key": key,
                                      "answer_revision_id": d["answer_revision_id"],
                                      "item_version_id": d["item_version_id"]}]
                                    if status == "MOST_SUGGESTED" else []),
                    "reason": "Restates the confirmed uncertainty.",
                    "authority": "CANDIDATE_ONLY"}

        payload = {"contract_version": CONTRACT_VERSION,
                   "recommendations": [rec("M2V1-01"), rec("M2V1-08")]}
        runner = lambda stage, p, t, **kw: json.loads(json.dumps(payload))
        result = BDJEngine(rules, model_runner=runner).propose_objectives(
            packet, recheck_current=lambda: packet["source_fingerprint"],
            context_packet=ctx, context_id="ctx-compat")
        after = session.execute(text(
            "select count(*), coalesce(max(created_at)::text,'') from public.m2_answer_revisions"
        )).one()
        session.rollback()

    print()
    print("=" * 78)
    print("2. BDJ CONSUMPTION OF THE CONFIRMED PROJECTION")
    print("=" * 78)
    print("assessment:", aid, "| confirmation:", conf_id)
    print("declarations:", len(packet["declarations"]),
          "| fingerprint:", packet["source_fingerprint"][:16], "…")
    print("engine outcome:", result["outcome"], "| proposals:", len(result["proposals"]))
    print("m2_answer_revisions before:", tuple(before), "after:", tuple(after))
    unchanged = tuple(before) == tuple(after)

    evidence = {"target": f"{TARGET_DB}@{PORT}", "dss_read_only": True,
                "preservation": {"differences": diffs,
                                 "local_items": len(local["items"]),
                                 "dss_items": len(remote["items"]),
                                 "version": local["instrument"]["version_tag"],
                                 "schema_digest": local["instrument"]["schema_digest"]},
                "assessment": str(aid), "confirmation": str(conf_id),
                "declarations": len(packet["declarations"]),
                "source_fingerprint": packet["source_fingerprint"],
                "engine_outcome": result["outcome"],
                "proposals": len(result["proposals"]),
                "m2_rows_before": list(before), "m2_rows_after": list(after),
                "m2_unchanged": unchanged,
                "verdict": "PASS" if (not diffs and unchanged
                                      and result["outcome"] == "reviewed") else "FAIL"}
    out = BACKEND.parent / "deliverables/phase2/BDJ_M2_COMPAT_AND_CONSUMPTION_20261121.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, indent=2, ensure_ascii=False, default=str), encoding="utf-8")
    print("\n  evidence:", out)
    print("  VERDICT:", evidence["verdict"])
    dss_conn.rollback()
    dss_conn.close()
    test_conn.close()
    return 0 if evidence["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
