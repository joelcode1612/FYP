"""Read-only, two-database assessment/CQ relationship evidence.

Uses current configuration without importing the application or running startup.
Does not create assessments, links, campaigns, questionnaires or approvals.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys

from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

BACKEND = Path(__file__).resolve().parents[1]
ROOT = BACKEND.parent
sys.path.insert(0, str(BACKEND / "src"))
from sitewise.core.config import Settings

SQL_DIR = ROOT / "docs/architecture/assessment_cq"


def read_database(url, sql_file):
    """Each database gets its own explicitly read-only repeatable-read snapshot."""
    source = sql_file.read_text(encoding="utf-8")
    parts = re.split(r"^-- audit: (\w+)\s*$", source, flags=re.MULTILINE)
    engine = create_engine(url, hide_parameters=True, connect_args={
        "options": "-c default_transaction_read_only=on -c statement_timeout=15000",
        "connect_timeout": 5,
    })
    queries = {}
    try:
        with engine.connect().execution_options(isolation_level="REPEATABLE READ") as c:
            with c.begin():
                c.execute(text("SET TRANSACTION READ ONLY"))
                identity = dict(c.execute(text("""
                    SELECT current_database() AS database, current_user AS role,
                           inet_server_port() AS port, version() AS version,
                           current_setting('transaction_read_only') AS read_only,
                           current_setting('transaction_isolation') AS isolation,
                           pg_current_snapshot()::text AS snapshot,
                           clock_timestamp() AS observed_at
                """)).mappings().one())
                for i in range(1, len(parts), 2):
                    query = re.sub(r"\s*ROLLBACK;\s*$", "", parts[i + 1]).strip()
                    queries[parts[i]] = [dict(r) for r in c.execute(text(query)).mappings()]
    finally:
        engine.dispose()
    return {"connection": {"host": url.host, "configured_role": url.username,
                           "driver": url.drivername, **identity},
            "sql_file": str(sql_file),
            "sql_sha256": hashlib.sha256(source.encode()).hexdigest(),
            "queries": queries}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    settings = Settings(_env_file=(BACKEND / ".env", BACKEND / ".env.local"))
    main_url = make_url(settings.database_url)
    m2_url = make_url(settings.m2_database_url.get_secret_value())
    if (main_url.database != "Final_Location_Analysis" or m2_url.database != "Dss"
            or main_url.drivername != "postgresql+psycopg2"
            or m2_url.drivername != "postgresql+psycopg2"
            or (main_url.host, main_url.port) != (m2_url.host, m2_url.port)):
        raise ValueError("Unexpected configured database responsibilities; review before running")
    # Existing local diagnostic operator, not a fallback in the application.
    # Database-wide integrity checks need visibility across all RLS owners.
    dss_operator_url = main_url.set(database=m2_url.database)
    result = {"observed_at": datetime.now(timezone.utc).isoformat(),
              "scope": "READ_ONLY_DATABASE_VERIFICATION",
              "http_ui_test": "NOT_PERFORMED_BY_THIS_SCRIPT",
              "cross_database_atomic_snapshot": False,
              "warning": "Two sequential database snapshots; no distributed transaction implied",
              "databases": {}, "checks": []}
    for db, url, file in (
        ("Final_Location_Analysis", main_url, "VERIFY_MARKETPLACE.sql"),
        ("Dss", dss_operator_url, "VERIFY_DSS.sql"),
    ):
        result["databases"][db] = read_database(url, SQL_DIR / file)
    market = result["databases"]["Final_Location_Analysis"]["queries"]
    dss = result["databases"]["Dss"]["queries"]
    checks = result["checks"]

    def check(name, passed, evidence):
        checks.append({"name": name, "status": "PASS" if passed else "FAIL", "evidence": evidence})

    for db, record in result["databases"].items():
        check(db + "_read_only", record["connection"]["read_only"] == "on",
              record["connection"]["isolation"])
    web = {str(r["assessment_id"]): r for r in market["marketplace_assessments"]}
    links = [r for r in dss["assessment_links"] if r["revoked_at"] is None]
    invalid = [str(r["link_id"]) for r in links
               if str(r["marketplace_assessment_id"]) not in web
               or str(web[str(r["marketplace_assessment_id"])]["user_id"]) != str(r["user_id"])
               or str(r["m2_owner"]) != str(r["user_id"])]
    check("active_cross_database_links_exist_and_match_both_owners", bool(links) and not invalid,
          {"checked": len(links), "invalid_link_ids": invalid})
    check("marketplace_property_references_resolve", bool(web) and all(
        r["catalogue_reference_exists"] for r in web.values()), {"checked": len(web)})
    for item in dss["integrity"]:
        check(item["check_name"], item["violations"] == 0, item["violations"])
    case = next((r for r in dss["synthetic_cases"] if r["case_key"] == "06-single-continue-check"), None)
    check("previous_full_questionnaire_receipt_and_lifecycle", case is not None and
          case["submission_record_status"] == "SUBMITTED" and case["lifecycle_status"] == "COMPLETED"
          and case["receipt_id"] is not None and case["current_question_count"] == 13
          and case["current_answer_pointers"] == 14, case)
    check("previous_full_questionnaire_is_explicitly_synthetic", case is not None and
          case["origin"] == "SYNTHETIC_TEST" and case["real_reportable"] is False
          and case["research_mode"] == "DEVELOPER_PREVIEW", None)
    linked_completed = [r for r in links if case and r["m2_assessment_id"] == case["assessment_id"]]
    checks.append({"name": "property_assessment_to_previous_completed_questionnaire",
                   "status": "CONNECTED" if linked_completed else "NOT_CONNECTED",
                   "evidence": {"matching_active_links": len(linked_completed),
                                "completed_session_id": case["session_id"] if case else None},
                   "action": "Never reparent synthetic responses to genuine entrepreneur assessments"})
    result["verdict"] = "RELATIONSHIP_CHECKS_PASS_WORKFLOW_NOT_CONNECTED" if all(
        r["status"] != "FAIL" for r in checks) and not linked_completed else (
        "FAIL" if any(r["status"] == "FAIL" for r in checks) else "CONNECTED")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, default=str) + "\n", encoding="utf-8")
    print(json.dumps({"verdict": result["verdict"],
                      "checks": [{"name": c["name"], "status": c["status"]} for c in checks],
                      "evidence": str(args.output)}, indent=2))
    return 1 if any(c["status"] == "FAIL" for c in checks) else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        # Never print connection strings or secret-bearing exception chains.
        print(json.dumps({"status": "ERROR", "error_type": type(exc).__name__}))
        raise SystemExit(1)
