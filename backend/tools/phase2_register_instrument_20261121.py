"""Disposable-only M2V1 instrument registration (D-E2E-05, Option B).

Calls the existing `register()` library function instead of the production CLI,
which is hard-pinned to `Dss`. The CLI is not modified.

Guards:
  * host, port and database identity verified before any write;
  * the Owner adoption receipt is required verbatim;
  * `expected_database` is passed explicitly, so the function's own target check
    still applies;
  * nothing outside `project1_workflow_tests@5433` is reachable from here.

Run:
    PYTHONPATH=src .venv/Scripts/python.exe tools/phase2_register_instrument_20261121.py \
        --apply --adoption-receipt OWNER-ADOPTED-M2V1-20261114
"""
import argparse
import importlib.util
import json
from pathlib import Path

from sqlalchemy import create_engine, text

TARGET_DB = "project1_workflow_tests"
PORT = 5433
RECEIPT = "OWNER-ADOPTED-M2V1-20261114"
BACKEND = Path(__file__).resolve().parents[1]


def db_url(db=TARGET_DB):
    for line in (BACKEND / ".env").read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith("DATABASE_URL="):
            base = line.split("=", 1)[1].strip().replace("postgresql+psycopg2://",
                                                         "postgresql://")
            return base.rsplit("/", 1)[0].replace(":5432", f":{PORT}") + "/" + db
    raise SystemExit("DATABASE_URL missing")


def preflight():
    url = db_url()
    if f":{PORT}/" not in url or TARGET_DB not in url:
        raise SystemExit("REFUSED: not the authorized disposable target")
    if not any(h in url for h in ("@localhost", "@127.0.0.1")):
        raise SystemExit("REFUSED: host is not the local isolated cluster")


def load_script():
    path = BACKEND / "scripts/register_m2_v1.py"
    spec = importlib.util.spec_from_file_location("register_m2_v1", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--adoption-receipt", required=True)
    args = ap.parse_args()

    preflight()
    if args.apply and args.adoption_receipt != RECEIPT:
        raise SystemExit("REFUSED: adoption receipt does not match the pinned value")

    module = load_script()
    engine = create_engine(db_url().replace("postgresql://", "postgresql+psycopg2://", 1),
                           connect_args={"connect_timeout": 5})
    result = module.register(engine, apply=args.apply,
                             expected_database=TARGET_DB)

    with engine.begin() as conn:
        conn.exec_driver_sql("SET TRANSACTION READ ONLY")
        keys = [r[0] for r in conn.execute(text(
            "select item_key from public.m2_item_versions order by item_key"))]
        kinds = dict(conn.execute(text(
            "select item_key, answer_kind from public.m2_item_versions")).fetchall())
        inst = conn.execute(text(
            "select code, version_tag, approval_state from public.m2_instrument_versions"
        )).mappings().one()

    scored = [k for k in keys if k.startswith("M2V1-")]
    actions = [k for k in keys if not k.startswith("M2V1-")]
    evidence = {"defect": "D-E2E-05", "option": "B", "target": f"{TARGET_DB}@{PORT}",
                "receipt": args.adoption_receipt, "register_result": result,
                "instrument": dict(inst), "items_total": len(keys),
                "scored_items": scored, "action_items": actions,
                "action_kinds": {k: kinds.get(k) for k in actions},
                "verdict": "PASS" if (len(scored) == 11 and len(actions) == 2
                                      and inst["approval_state"] == "AUTHORIZED") else "FAIL"}
    out = BACKEND.parent / "deliverables/phase2/BDJ_INSTRUMENT_REGISTRATION_20261121.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding="utf-8")

    print("target      :", evidence["target"])
    print("instrument  :", inst["code"], inst["version_tag"], inst["approval_state"])
    print("items       :", len(keys), "=", len(scored), "scored +", len(actions), "action")
    print("scored keys :", ", ".join(scored))
    print("action keys :", ", ".join(actions), "->", evidence["action_kinds"])
    print("replayed    :", result["replayed"], "| schema_digest:", result["schema_digest"][:12])
    print("evidence    :", out)
    print("VERDICT     :", evidence["verdict"])
    return 0 if evidence["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
