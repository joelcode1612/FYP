"""Create and confirm a synthetic 11-item M2V1 assessment in the disposable DB.

Uses the normal services (`M2Service`, `ConfirmationService`) — no raw inserts
into application tables — so the confirmation is produced by the same code path
the API uses. Disposable target only.

Run:
    PYTHONPATH=src .venv/Scripts/python.exe tools/phase2_create_assessment_20261121.py
"""
import json
import shutil
import uuid
from pathlib import Path

from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session

TARGET_DB = "project1_workflow_tests"
PORT = 5433
BACKEND = Path(__file__).resolve().parents[1]

ANSWERS = {"M2V1-01": "UNDECIDED", "M2V1-02": "DINE_IN",
           "M2V1-03": ["COFFEE", "BAKED_GOODS"], "M2V1-04": ["STUDENTS", "OFFICE_WORKERS"],
           "M2V1-05": "STUDENTS", "M2V1-06": "CONVENIENCE", "M2V1-07": "STUDY_WORK",
           "M2V1-08": ["UNKNOWN"], "M2V1-09": ["CONCEPT_INTEREST"],
           "M2V1-10": "CONCEPT_INTEREST", "M2V1-11": "UNSURE"}


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


def main():
    preflight()
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    from sitewise.services.m2_service import M2Service
    from sitewise.services.confirmation_service import ConfirmationService
    from sitewise.project1.projection import M2SourceProjection

    engine = create_engine(db_url().replace("postgresql://", "postgresql+psycopg2://", 1))
    actor = uuid.uuid4()
    with Session(engine) as session:
        repo = SqlModelM2Repository(session)
        m2, conf = M2Service(repo), ConfirmationService(repo)
        instrument_id = session.execute(text(
            "select id from public.m2_instrument_versions where version_tag='M2V1-20261114-1'"
        )).scalar_one()
        assessment = m2.create_assessment(uuid.UUID(str(instrument_id)), actor)
        aid = uuid.UUID(str(assessment["id"]))
        revision = assessment["revision"]
        print("assessment:", aid, "rev", revision)

        for key in sorted(ANSWERS):
            try:
                m2.update_answer(aid, actor, expected_revision=revision,
                                 item_key=key, state="ANSWERED", value=ANSWERS[key])
            except Exception as exc:
                print(f"  REJECTED {key} value={ANSWERS[key]!r}: {type(exc).__name__}: {exc}")
                raise
            revision = m2.read_assessment(aid, actor)["assessment"]["revision"]
        print("saved 11 answers, revision now", revision)

        conf.record_review(aid, actor, revision)
        result = conf.confirm(aid, actor, expected_revision=revision,
                              acknowledged_issue_ids=[])
        print("confirmed:", result.get("id"), "digest", str(result.get("snapshot_digest"))[:12])

        projected = M2SourceProjection(repo).read(aid, actor, revision)
        fp = projected["source_fingerprint"]
        decls = projected["declarations"]
        session.rollback()

    with engine.begin() as conn:
        conn.exec_driver_sql("SET TRANSACTION READ ONLY")
        conf_row = conn.execute(text(
            "select id, assessment_revision, snapshot_digest from public.m2_confirmation_snapshots"
            " order by created_at desc limit 1")).mappings().one()
        answers = conn.execute(text(
            "select count(distinct i.item_key) from public.m2_answer_revisions a"
            " join public.m2_item_versions i on i.id = a.item_version_id"
            " where a.assessment_id = :a"), {"a": aid, "r": revision}).scalar_one()

    evidence = {"gate": 2, "target": f"{TARGET_DB}@{PORT}", "assessment_id": str(aid),
                "confirmation_id": str(conf_row["id"]),
                "confirmation_revision": conf_row["assessment_revision"],
                "snapshot_digest": conf_row["snapshot_digest"],
                "source_fingerprint": fp, "declarations": len(decls),
                "answer_revisions": answers,
                "item_keys": [d["item_key"] for d in decls],
                "verdict": "PASS" if len(decls) == 11 and answers >= 11 else "FAIL"}
    out = BACKEND.parent / "deliverables/phase2/BDJ_SYNTHETIC_ASSESSMENT_20261121.json"
    if out.exists():
        prev = out.with_suffix(".failed.json")
        if not prev.exists():
            shutil.copy2(out, prev)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding="utf-8")
    print("declarations:", len(decls), "| answer revisions:", answers)
    print("source fingerprint:", fp[:16], "…")
    print("evidence:", out)
    print("VERDICT:", evidence["verdict"])
    return 0 if evidence["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
