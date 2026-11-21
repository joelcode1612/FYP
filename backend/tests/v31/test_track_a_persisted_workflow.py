"""V3.1 CP-04 TRACK A: real application integration over PERSISTED records.

What this is
------------
An authenticated Entrepreneur -> saved assessment -> persisted M2 responses ->
BDJ-backed confirmation snapshot -> confirmed research objective -> BCB-style
context -> QG candidate -> owner review -> persisted history journey, driven
through FastAPI TestClient against the disposable CLONE database
``project1_workflow_tests``. The model runner is a MOCK. No provider, model,
network-model or real-data disclosure call is made. This is explicitly NOT
real-data provider verification and NOT production BCB authority.

What is deliberately a double
-----------------------------
* ``MockQgRunner`` returns a contract-valid QG-PROPOSE-6-CAND DRAFT. The real
  contract validators in ``qg_contract`` still admit it.
* ``TrackATestContextResolver`` is a TEST-ONLY, explicitly labelled authority
  that derives a packet from persisted M2 rows. The production resolver
  refuses (``UnverifiedContextBindings`` / missing validity basis); this test
  never claims production BCB authority. Every evidence record carries the
  ``TEST_ONLY_NOT_PRODUCTION_BCB_AUTHORITY`` label.
* ``budget.reserve`` is patched so no real attempt ledger is consumed.

Every id used as an input is discovered by SELECT at runtime. No assessment,
objective, confirmation or synthetic fixture id is hardcoded as an input.
All writes occur inside one transaction that is ALWAYS rolled back.
"""
from __future__ import annotations

import copy
import json
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlmodel import Session

from sitewise.api.v1 import m2 as m2_api
from sitewise.api.v1 import qg_candidate as qg_api
from sitewise.core.config import settings
from sitewise.core.exceptions import SiteWiseError
from sitewise.dependencies import (
    get_db,
    get_m2_scoped_db,
    get_persisted_business_context_service,
    get_qg_runner,
)
from sitewise.main import auth_error_handler, workflow_held_handler
from sitewise.project1 import budget
from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.measurement_policy import (
    QJ_INVARIANTS_POLICY,
    MeasurementAuthority,
)
from sitewise.project1.qg_contract import QGCandidate, validate_candidate
from sitewise.repositories.m2_repository import SqlModelM2Repository
from sitewise.services.confirmation_service import ConfirmationService
from sitewise.services.qg_candidate_service import QgCandidateService
from tests.conftest import make_token

CLONE = "project1_workflow_tests"
AUTHORITY = "TRACK_A_TEST_ONLY_NOT_PRODUCTION_BCB_AUTHORITY"
SYNTHETIC_PREFIXES = ("da90aa4a", "a1b2c3d4", "b2c3d4e5")
REPO_ROOT = Path(__file__).resolve().parents[3]
EVIDENCE_DIR = REPO_ROOT / "artifacts" / "v31" / "CP04_track_a"

DISCOVER_SQL = """
SELECT a.id, a.owner_user_id AS owner_id, a.revision, a.confirmed_revision,
       c.id AS confirmation_id, c.snapshot_digest,
       c.actor_user_id AS confirmer_id
FROM public.m2_assessments a
JOIN public.m2_confirmation_snapshots c
  ON c.assessment_id = a.id AND c.assessment_revision = a.revision
WHERE a.confirmed_revision = a.revision
  AND EXISTS (SELECT 1 FROM public.m2_answer_revisions ar
              WHERE ar.assessment_id = a.id)
  AND NOT EXISTS (SELECT 1 FROM public.m2_confirmed_uncertainties u
                  WHERE u.confirmation_id = c.id)
  AND a.id::text NOT LIKE 'da90aa4a%'
  AND a.id::text NOT LIKE 'a1b2c3d4%'
  AND a.id::text NOT LIKE 'b2c3d4e5%'
ORDER BY a.created_at
LIMIT 1
"""

BASELINE_SQL = """
SELECT
 (SELECT count(*) FROM public.m2_confirmed_uncertainties) AS uncertainties,
 (SELECT count(*) FROM public.m2_research_objective_sources) AS objectives,
 (SELECT count(*) FROM public.m2_review_question_versions) AS candidates,
 (SELECT count(*) FROM public.m2_candidate_review_assignments) AS assignments,
 (SELECT count(*) FROM public.m2_candidate_owner_reviews) AS reviews
"""


def _clone_engine():
    url = make_url(settings.database_url).set(database=CLONE)
    engine = create_engine(url, hide_parameters=True, pool_pre_ping=True)
    with engine.connect() as connection:
        name = connection.execute(text("SELECT current_database()")).scalar_one()
        if name != CLONE:
            engine.dispose()
            raise RuntimeError(f"resolved database is {name}, not {CLONE}")
    return engine


try:
    ENGINE = _clone_engine()
except Exception as exc:  # pragma: no cover - environment dependent
    pytest.skip(
        f"clone {CLONE} not reachable ({type(exc).__name__}: {exc}); "
        "Track A integration is unverified here",
        allow_module_level=True,
    )


class Recorder:
    """One record per HTTP call, checkpoint and lineage assertion."""

    def __init__(self):
        self.api_calls: list[dict] = []
        self.checkpoints: list[dict] = []
        self.ids: dict = {}
        self.notes: list[str] = []
        self.baseline: dict = {}
        self.after_rollback: dict = {}
        self.lineage: list[dict] = []

    def call(self, method, path, *, response, request_json=None):
        self.api_calls.append({
            "seq": len(self.api_calls) + 1,
            "authority": AUTHORITY,
            "method": method,
            "path": path,
            "authorization": "Bearer <REDACTED>",
            "request_json": request_json,
            "status_code": response.status_code,
            "response_json": _json_safe(response.json()),
        })

    def checkpoint(self, name, status, detail):
        self.checkpoints.append({
            "name": name,
            "status": status,
            "detail": detail,
            "authority": AUTHORITY,
        })
        print(f"[{status}] {name} :: {detail}")

    def lineage_row(self, step, table, sql, values):
        self.lineage.append({
            "step": step,
            "table": table,
            "sql": " ".join(sql.split()),
            "values": _json_safe(values),
            "authority": AUTHORITY,
        })


def _json_safe(value):
    if isinstance(value, dict):
        return {str(k): _json_safe(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_safe(v) for v in value]
    if isinstance(value, UUID):
        return str(value)
    return value


def write_evidence(recorder: Recorder):
    """Write the three required evidence artefacts (always, pass or fail)."""
    EVIDENCE_DIR.mkdir(parents=True, exist_ok=True)

    json_payload = {
        "track": "A",
        "scope": (
            "Real application integration over persisted records with a mocked "
            "model. NOT real-data provider verification. NOT production BCB authority."
        ),
        "authority": AUTHORITY,
        "provider_or_network_model_calls": 0,
        "ids": _json_safe(recorder.ids),
        "notes": recorder.notes,
        "baseline_counts": recorder.baseline,
        "counts_after_rollback": recorder.after_rollback,
        "checkpoints": recorder.checkpoints,
        "api_requests_and_responses": recorder.api_calls,
    }
    (EVIDENCE_DIR / "api_evidence.json").write_text(
        json.dumps(json_payload, indent=2, ensure_ascii=False), encoding="utf-8")

    sql_lines = [
        "-- V3.1 CP-04 TRACK A SQL lineage.",
        "-- Real application integration over persisted records; mocked model.",
        f"-- AUTHORITY: {AUTHORITY} (test authority, NOT production BCB authority).",
        "-- Database: disposable clone project1_workflow_tests. All writes rolled back.",
        "-- The following SELECTs reproduce the exact chain asserted by the test.",
        "",
    ]
    for row in recorder.lineage:
        sql_lines.extend([
            f"-- STEP {row['step']} :: {row['table']} :: {AUTHORITY}",
            row["sql"] + ";",
            "-- observed values: " + json.dumps(row["values"], ensure_ascii=False),
            "",
        ])
    sql_lines.extend([
        "-- Rollback verification (read-only, separate connection):",
        "-- baseline: " + json.dumps(recorder.baseline, sort_keys=True),
        "-- after  : " + json.dumps(recorder.after_rollback, sort_keys=True),
    ])
    (EVIDENCE_DIR / "sql_lineage.sql").write_text(
        "\n".join(sql_lines) + "\n", encoding="utf-8")

    counts = {}
    for checkpoint in recorder.checkpoints:
        counts[checkpoint["status"]] = counts.get(checkpoint["status"], 0) + 1
    rows = []
    for checkpoint in recorder.checkpoints:
        rows.append(
            f"| {checkpoint['name']} | {checkpoint['status']} | "
            f"{checkpoint['detail']} | {AUTHORITY} |"
        )
    report = [
        "# V3.1 CP-04 — TRACK A integration report",
        "",
        "**Classification:** real application integration over persisted records "
        "with a mocked model. **NOT** real-data provider verification. "
        "**NOT** production BCB authority.",
        "",
        f"**Authority label on every line:** `{AUTHORITY}`",
        "",
        "## Source of ids (all read from the clone at runtime)",
        "",
        "```json",
        json.dumps(recorder.ids, indent=2, ensure_ascii=False),
        "```",
        "",
        "## Checkpoints",
        "",
        "| Checkpoint | Status | Detail | Authority |",
        "| --- | --- | --- | --- |",
        *rows,
        "",
        "Checkpoint tally: " + (", ".join(f"{k}={v}" for k, v in sorted(counts.items())) or "none"),
        "",
        "## Doubles and scope",
        "",
        "- Model runner: `MockQgRunner`, a contract-valid QG-PROPOSE-6-CAND DRAFT. "
        "Zero provider/model/network-model calls; no real-data disclosure.",
        "- BCB context: `TrackATestContextResolver`, a TEST-ONLY authority deriving "
        "a packet from persisted M2 answers, confirmation and objective. It is "
        "not a production BCB binding; the production resolver refuses this data.",
        "- `budget.reserve` patched; no real attempt ledger row consumed.",
        "- All writes were executed inside one transaction and rolled back.",
        "",
        "## Rollback verification",
        "",
        "- before: " + json.dumps(recorder.baseline, sort_keys=True),
        "- after : " + json.dumps(recorder.after_rollback, sort_keys=True),
        "",
        "## Evidence files",
        "",
        "- artifacts/v31/CP04_track_a/api_evidence.json",
        "- artifacts/v31/CP04_track_a/sql_lineage.sql",
        "- artifacts/v31/CP04_track_a/report.md",
    ]
    (EVIDENCE_DIR / "report.md").write_text(
        "\n".join(report) + "\n", encoding="utf-8")


class TrackATestContextResolver:
    """TEST-ONLY BCB-style resolver. Not a production BCB authority.

    Every value is read from persisted rows at call time. No tenant, GEO,
    finding-authority or external-source fact is invented.
    """

    def __init__(self, session, discovered):
        self.session = session
        self.discovered = discovered
        self.calls = 0
        self.authority = AUTHORITY

    def retrieve(self, assessment_id, context_id, actor):
        self.calls += 1
        objective_id = self.discovered["objective_id"]
        confirmation_id = self.discovered["confirmation_id"]
        row = self.session.execute(text("""
            SELECT c.id, c.assessment_revision, c.snapshot_digest,
                   u.id AS uncertainty_id, u.exact_text,
                   c.snapshot_json::jsonb->'answer_revisions' AS answer_revisions
            FROM public.m2_confirmation_snapshots c
            JOIN public.m2_confirmed_uncertainties u ON u.confirmation_id = c.id
            WHERE c.id = :confirmation AND u.id = :objective
        """), {"confirmation": confirmation_id, "objective": objective_id}).mappings().one()
        answers = []
        for answer in row["answer_revisions"] or []:
            answers.append({
                "answer_revision_id": str(answer["answer_revision_id"]),
                "item_key": answer["item_key"],
                "answer_state": answer["answer_state"],
                "value": answer["value"],
            })
        packet = {
            "schema_version": "business-context-package/1.1",
            "authority_label": AUTHORITY,
            "assessment_id": str(assessment_id),
            "context_id": str(context_id),
            "confirmation": {
                "status": "CURRENT_CONFIRMED",
                "id": str(row["id"]),
                "revision": int(row["assessment_revision"]),
            },
            "confirmed_uncertainty": {
                "id": str(row["uncertainty_id"]),
                "confirmation_id": str(row["id"]),
                "actor_user_id": str(self.discovered["owner_id"]),
                "exact_text": row["exact_text"],
            },
            "geography": None,
            "permissions": {"qj_execution": False},
            "m2_answers": answers,
            "supporting_sources": [],
        }
        packet["packet_hash"] = digest({k: v for k, v in packet.items() if k != "packet_hash"})
        return {"packet": packet, "qj_execution_authorized": False}


class MockQgRunner:
    """Contract-valid QG-PROPOSE-6-CAND DRAFT, with no facts invented."""

    LABELS = ("alpha", "bravo", "charlie", "delta", "echo", "foxtrot")

    def __init__(self):
        self.calls = 0
        self.stages: list[str] = []
        self.authority = AUTHORITY

    def __call__(self, stage, payload, output_type, prompt_key=None):
        assert output_type is QGCandidate, "the real contract type must be requested"
        self.calls += 1
        self.stages.append(stage)
        objective_id = payload["confirmed_facts"]["objective_id"]
        assert objective_id, "a persisted objective id must be bound in the QG input"
        label = self.LABELS[min(self.calls - 1, len(self.LABELS) - 1)]
        # No digits, currency or offer components: the confirmed text for this
        # assessment has none, so the contract forbids inventing any.
        return {
            "decision": "DRAFT",
            "question": (
                "Would eligible customers consider the confirmed concept "
                f"acceptable ({label} wording)?" 
            ),
            "justification": f"TEST-ONLY mock proposal, variant {label}.",
            "construct_interpretation": "Stated acceptability of the confirmed offer.",
            "response_options": ["Acceptable", "Not acceptable", "No opinion"],
            "response_codes": ["ACCEPTABLE", "NOT_ACCEPTABLE", "NO_OPINION"],
            "routing": {
                "ACCEPTABLE": "END",
                "NOT_ACCEPTABLE": "END",
                "NO_OPINION": "END",
            },
            "reference_period": "At the moment the respondent views the offer.",
            "measurement_description": "Share describing the offer as acceptable.",
            "denominator_specification": (
                "ACCEPTABLE and NOT_ACCEPTABLE respondents; NO_OPINION reported "
                "separately."
            ),
            "limitations": (
                "Stated acceptability only. This is a proposal for review, not a "
                "purchase estimate and not a scientifically adopted measurement."
            ),
            "unresolved_assumptions": [],
            "missing_business_facts": [],
            "used_confirmed_facts": [str(objective_id)],
        }


@pytest.fixture(scope="module")
def recorder():
    return Recorder()


@pytest.fixture(scope="module", autouse=True)
def _engine_lifetime(recorder):
    yield
    ENGINE.dispose()
    write_evidence(recorder)


@pytest.fixture(scope="module")
def connection(recorder):
    conn = ENGINE.connect()
    transaction = conn.begin()
    recorder.baseline = dict(conn.execute(text(BASELINE_SQL)).mappings().one())
    state = {"rolled_back": False}

    def rollback_now():
        if state["rolled_back"]:
            return
        state["rolled_back"] = True
        transaction.rollback()
        conn.close()
        with ENGINE.connect() as fresh:
            recorder.after_rollback = dict(
                fresh.execute(text(BASELINE_SQL)).mappings().one())

    recorder.rollback_now = rollback_now
    try:
        yield conn
    finally:
        rollback_now()


@pytest.fixture(scope="module")
def session(connection):
    return Session(bind=connection)


@pytest.fixture(scope="module")
def discovered(connection, recorder):
    row = connection.execute(text(DISCOVER_SQL)).mappings().first()
    assert row is not None, "no real assessment with persisted answers + confirmation"
    found = dict(row)
    for key in ("id", "confirmation_id", "owner_id", "confirmer_id"):
        assert found[key] is not None
    for value in (found["id"], found["confirmation_id"]):
        assert not str(value).startswith(SYNTHETIC_PREFIXES), (
            f"synthetic fixture id selected by discovery: {value}")
    assert found["revision"] == found["confirmed_revision"]

    snapshot = connection.execute(text("""
        SELECT snapshot_digest,
               snapshot_json::jsonb->>'instrument_version' AS instrument_version,
               snapshot_json::jsonb->>'bdj_evaluation_id' AS bdj_evaluation_id,
               snapshot_json::jsonb->>'bdj_rule_version' AS bdj_rule_version,
               snapshot_json::jsonb->'answer_revisions' AS answer_revisions,
               snapshot_json::jsonb->'unresolved_candidate_findings' AS issues
        FROM public.m2_confirmation_snapshots WHERE id = :id
    """), {"id": found["confirmation_id"]}).mappings().one()
    bdj = connection.execute(text("""
        SELECT id, assessment_revision, evaluator_version
        FROM public.m2_bdj_evaluations
        WHERE assessment_id = :id AND assessment_revision = :revision
        ORDER BY created_at LIMIT 1
    """), {"id": found["id"], "revision": found["revision"]}).mappings().first()
    assert bdj is not None, "the real assessment must have a persisted BDJ evaluation"
    assert str(snapshot["bdj_evaluation_id"]) == str(bdj["id"])
    answers = {a["item_key"]: a for a in snapshot["answer_revisions"] or []}
    assert {"M2V1-09", "M2V1-10", "M2V1-11"} <= set(answers)
    priority = answers["M2V1-10"]["value"]
    decision_status = answers["M2V1-11"]["value"]
    topics = answers["M2V1-09"]["value"]
    assert isinstance(topics, list) and priority in topics
    objective_text = f"{priority} | {decision_status}"

    recorder.ids.update({
        "assessment_id": str(found["id"]),
        "assessment_revision": found["revision"],
        "owner_id": str(found["owner_id"]),
        "confirmation_id": str(found["confirmation_id"]),
        "confirmation_snapshot_digest": snapshot["snapshot_digest"],
        "instrument_version": snapshot["instrument_version"],
        "bdj_evaluation_id": str(bdj["id"]),
        "bdj_evaluator_version": bdj["evaluator_version"],
        "bdj_rule_version_pinned_in_snapshot": snapshot["bdj_rule_version"],
        "answer_revision_count": len(answers),
        "objective_text_derived_from_persisted_answers": objective_text,
    })
    recorder.lineage_row(
        1, "m2_assessments -> m2_confirmation_snapshots", DISCOVER_SQL,
        {"assessment_id": str(found["id"]),
         "confirmation_id": str(found["confirmation_id"]),
         "revision": found["revision"]})
    recorder.lineage_row(
        2, "m2_bdj_evaluations pinned in m2_confirmation_snapshots",
        "SELECT id, assessment_revision, evaluator_version FROM m2_bdj_evaluations "
        "WHERE assessment_id=:id AND assessment_revision=:revision",
        {"bdj_evaluation_id": str(bdj["id"]),
         "evaluator_version": bdj["evaluator_version"],
         "snapshot_bdj_evaluation_id": snapshot["bdj_evaluation_id"],
         "bdj_rule_version": snapshot["bdj_rule_version"]})
    recorder.lineage_row(
        3, "m2_confirmation_snapshots.answer_revisions",
        "SELECT snapshot_digest, snapshot_json::jsonb->'answer_revisions' "
        "FROM public.m2_confirmation_snapshots WHERE id = :id",
        {"confirmation_id": str(found["confirmation_id"]),
         "answer_revision_ids": [a["answer_revision_id"] for a in answers.values()]})
    return {**found, "snapshot": dict(snapshot), "objective_text": objective_text,
            "bdj_evaluation_id": bdj["id"],
            "bdj_evaluator_version": bdj["evaluator_version"]}


@pytest.fixture(scope="module")
def contexts(session, discovered):
    return TrackATestContextResolver(session, discovered)


@pytest.fixture(scope="module")
def runner():
    return MockQgRunner()


@pytest.fixture(scope="module")
def api_client(connection, session, contexts, runner, discovered):
    app = FastAPI()
    app.include_router(m2_api.router, prefix="/m2")
    app.include_router(qg_api.router, prefix="/m2")
    app.add_exception_handler(SiteWiseError, auth_error_handler)
    app.add_exception_handler(WorkflowHeld, workflow_held_handler)

    # Only the test doubles are overridden: auth, route, service and repository
    # chains remain real. get_db/get_m2_scoped_db share the rolled-back session.
    app.dependency_overrides[get_db] = lambda: session
    app.dependency_overrides[get_m2_scoped_db] = lambda: session
    app.dependency_overrides[get_qg_runner] = lambda: runner
    app.dependency_overrides[get_persisted_business_context_service] = lambda: contexts

    owner_email = connection.execute(text(
        "SELECT email FROM public.users WHERE user_id = :id"
    ), {"id": discovered["owner_id"]}).scalar_one()
    token = make_token(sub=str(discovered["owner_id"]), email=owner_email)

    original_reserve = budget.reserve
    budget.reserve = lambda *args, **kwargs: 1
    try:
        with TestClient(app) as client:
            client.headers.update({"Authorization": f"Bearer {token}"})
            yield client, app, token
    finally:
        budget.reserve = original_reserve


def _call(client, recorder, method, path, **kwargs):
    response = client.request(method, path, **kwargs)
    recorder.call(method, path, response=response,
                  request_json=kwargs.get("json"))
    return response


# ---------------------------------------------------------------------------
# 1. Discovery
# ---------------------------------------------------------------------------
def test_01_discover_real_persisted_assessment(discovered, recorder, connection):
    assert str(discovered["id"]) == recorder.ids["assessment_id"]
    assert not str(discovered["id"]).startswith(SYNTHETIC_PREFIXES)
    assert not str(discovered["confirmation_id"]).startswith(SYNTHETIC_PREFIXES)
    assert str(discovered["bdj_evaluation_id"]) == \
        discovered["snapshot"]["bdj_evaluation_id"]
    recorder.checkpoint(
        "01b_bdj_persisted_evidence", "PASS",
        f"BDJ evaluation {discovered['bdj_evaluation_id']} "
        f"({discovered['bdj_evaluator_version']}) is persisted and pinned in the "
        "confirmation snapshot; BDJ was consumed as a persisted record, not "
        "re-executed in this test.")
    recorder.checkpoint(
        "01_discover_persisted_assessment", "PASS",
        f"assessment={discovered['id']} confirmation={discovered['confirmation_id']} "
        f"revision={discovered['revision']} answers={len(discovered['snapshot']['answer_revisions'])} "
        "selected by SELECT, not hardcoded; excluded synthetic prefixes.")
    assert "owner_id" in recorder.ids


# ---------------------------------------------------------------------------
# 2. Existing confirmation workflow -> confirmed research objective
# ---------------------------------------------------------------------------
def test_02_confirm_objective_from_persisted_responses(
        api_client, discovered, connection, recorder):
    client, _, _ = api_client
    confirmation_id = discovered["confirmation_id"]
    response = _call(
        client, recorder, "POST",
        f"/m2/confirmations/{confirmation_id}/research-objectives",
        json={
            "expected_revision": discovered["revision"],
            "origin": "ENTREPRENEUR",
            "objective": discovered["objective_text"],
            "finding_id": None,
        },
    )
    assert response.status_code == 201, response.json()
    body = response.json()
    objective_id = body["id"]
    assert objective_id and str(objective_id) != "None"
    assert not str(objective_id).startswith(SYNTHETIC_PREFIXES)
    assert body["source"]["confirmation_id"] == str(confirmation_id)
    assert body["source"]["assessment_id"] == str(discovered["id"])
    assert body["qj_execution_authorized"] is False
    discovered["objective_id"] = UUID(str(objective_id))
    recorder.ids["objective_id"] = str(objective_id)
    recorder.ids["objective_source"] = "existing POST /confirmations/{id}/research-objectives"

    row = connection.execute(text("""
        SELECT u.id, u.exact_text, s.provenance
        FROM public.m2_confirmed_uncertainties u
        JOIN public.m2_research_objective_sources s ON s.objective_id = u.id
        WHERE u.id = :id
    """), {"id": objective_id}).mappings().one()
    assert str(row["id"]) == str(objective_id)
    assert row["exact_text"] == discovered["objective_text"]
    recorder.lineage_row(
        4, "m2_confirmed_uncertainties -> m2_research_objective_sources",
        "SELECT u.id, u.exact_text, s.provenance FROM m2_confirmed_uncertainties u "
        "JOIN m2_research_objective_sources s ON s.objective_id=u.id WHERE u.id=:id",
        {"objective_id": str(row["id"]), "exact_text": row["exact_text"],
         "provenance": dict(row["provenance"])})
    recorder.checkpoint(
        "02_confirmed_objective_via_existing_workflow", "PASS",
        f"objective={objective_id} created by the real route from persisted M2 answers")


# ---------------------------------------------------------------------------
# 3. TEST-ONLY BCB-style context derived from persisted responses
# ---------------------------------------------------------------------------
def test_03_test_only_context_from_persisted_data(contexts, discovered, recorder):
    assert contexts.authority == AUTHORITY
    context_id = uuid4()
    response = contexts.retrieve(discovered["id"], context_id,
                                 discovered["owner_id"])
    packet = response["packet"]
    assert packet["authority_label"] == AUTHORITY
    assert packet["confirmation"]["id"] == str(discovered["confirmation_id"])
    assert packet["confirmation"]["revision"] == discovered["revision"]
    assert packet["confirmed_uncertainty"]["id"] == str(discovered["objective_id"])
    assert packet["confirmed_uncertainty"]["exact_text"] == discovered["objective_text"]
    assert packet["packet_hash"] == digest(
        {k: v for k, v in packet.items() if k != "packet_hash"})
    assert [a["answer_revision_id"] for a in packet["m2_answers"]] == [
        a["answer_revision_id"] for a in discovered["snapshot"]["answer_revisions"]]
    discovered["context_id"] = context_id
    discovered["context_hash"] = packet["packet_hash"]
    recorder.ids["context_id_test_only_locator"] = str(context_id)
    recorder.ids["context_packet_hash"] = packet["packet_hash"]
    recorder.notes.append(
        f"{AUTHORITY}: the BCB-style packet was derived from persisted M2 rows by "
        "the test-only resolver; production BCB authority was not used or claimed.")
    recorder.checkpoint(
        "03_bcb_context_test_authority", "PASS",
        "TEST-ONLY resolver derived hash-verified packet from persisted answers; "
        "NOT production BCB authority")


# ---------------------------------------------------------------------------
# 4. Real QG candidate route, mocked model
# ---------------------------------------------------------------------------
def test_04_prepare_candidate(api_client, discovered, recorder, connection, runner):
    client, _, _ = api_client
    response = _call(
        client, recorder, "POST",
        f"/m2/research-objectives/{discovered['objective_id']}/qg-candidate",
        json={"expected_revision": discovered["revision"],
              "context_id": str(discovered["context_id"])},
    )
    body = response.json()
    assert response.status_code == 200, body
    assert body["status"] == "VALIDATED_OUTPUT"
    assert "candidate" in body and body["candidate"] is not None
    assert body["field_authority"]["scientifically_adopted"] is False
    assert body["field_authority"]["fielding_authorized"] is False
    assert body["field_authority"]["contract_version"] == "P1-QG-CONTRACT-2.0"
    assert body["candidate_authority"] == "ENTREPRENEUR_REVIEW_ONLY"
    assert body["admission"]["uncertainty_version"] == str(discovered["objective_id"])
    assert body["composition"]["qj_executed"] is False
    assert runner.stages == ["QG"]
    version = UUID(body["version"])
    discovered["version_1"] = version
    row = connection.execute(text("""
        SELECT objective_id, question, source_receipt FROM public.m2_review_question_versions
        WHERE id = :id
    """), {"id": version}).mappings().one()
    assert str(row["objective_id"]) == str(discovered["objective_id"])
    receipt = json.loads(row["source_receipt"])
    assert str(receipt["evaluation"]["objective_id"]) == str(discovered["objective_id"])
    assert receipt["evaluation"]["objective_id"] is not None
    recorder.ids["candidate_version_1"] = str(version)
    recorder.lineage_row(
        5, "m2_review_question_versions",
        "SELECT objective_id, question, source_receipt FROM m2_review_question_versions WHERE id=:id",
        {"version": str(version), "objective_id": str(row["objective_id"]),
         "evaluation_objective_id": receipt["evaluation"]["objective_id"]})
    recorder.checkpoint(
        "04_prepare_candidate", "PASS",
        f"version={version}; wire key 'candidate'; objective_id={discovered['objective_id']} "
        "from persisted objective; mocked model only")


# ---------------------------------------------------------------------------
# 5. Read and history, real persisted objective id
# ---------------------------------------------------------------------------
def test_05_read_and_history(api_client, discovered, recorder):
    client, _, _ = api_client
    version = discovered["version_1"]

    read = _call(client, recorder, "GET", f"/m2/research-questions/{version}")
    body = read.json()
    assert read.status_code == 200, body
    assert body["version"] == str(version)
    assert body["objective_id"] == str(discovered["objective_id"])
    assert body["objective_id"] is not None
    assert body["field_authority"]["scientifically_adopted"] is False
    assert body["field_authority"]["fielding_authorized"] is False

    history = _call(
        client, recorder, "GET",
        f"/m2/research-objectives/{discovered['objective_id']}/research-questions",
        params={"expected_revision": discovered["revision"]},
    )
    body = history.json()
    assert history.status_code == 200, body
    assert body["objective_id"] == str(discovered["objective_id"])
    assert body["version_count"] >= 1
    assert body["versions"][0]["version"] == str(version)
    recorder.checkpoint(
        "05_read_and_history", "PASS",
        f"GET candidate and history both carry real objective_id={discovered['objective_id']}")


def _assign(connection, version, reviewer_id):
    connection.execute(text("""
        INSERT INTO public.m2_candidate_review_assignments
            (candidate_id, reviewer_id, authority_reference)
        VALUES (:candidate, :reviewer, :authority)
        ON CONFLICT (candidate_id, reviewer_id) DO NOTHING
    """), {"candidate": version, "reviewer": reviewer_id,
           "authority": AUTHORITY + "_REVIEW_SCAFFOLDING"})


def _review(client, recorder, version, decision, rationale):
    return _call(client, recorder, "POST",
                 f"/m2/research-questions/{version}/owner-review",
                 json={"decision": decision, "rationale": rationale})


# ---------------------------------------------------------------------------
# 6. All three owner decisions and revision after REQUEST_REVISION
# ---------------------------------------------------------------------------
def test_06_owner_reviews_and_revision(
        api_client, discovered, recorder, connection, session):
    client, _, _ = api_client
    owner = discovered["owner_id"]
    v1 = discovered["version_1"]
    _assign(connection, v1, owner)

    revision_request = _review(
        client, recorder, v1, "REQUEST_REVISION",
        "TEST-ONLY review scaffolding: ask for one concept at a time.")
    assert revision_request.status_code == 201, revision_request.json()
    assert revision_request.json()["decision"] == "REQUEST_REVISION"
    assert revision_request.json()["fielding_authorized"] is False

    revise = _call(
        client, recorder, "POST", f"/m2/research-questions/{v1}/revision",
        json={"expected_revision": discovered["revision"],
              "context_id": str(discovered["context_id"])},
    )
    revised_body = revise.json()
    assert revise.status_code == 200, revised_body
    child = UUID(revised_body["version"])
    assert child != v1
    assert "candidate" in revised_body and revised_body["candidate"] is not None
    assert revised_body["field_authority"]["scientifically_adopted"] is False
    stored = connection.execute(text(
        "SELECT supersedes FROM public.m2_review_question_versions WHERE id=:id"
    ), {"id": child}).scalar_one()
    assert stored == v1
    discovered["version_1_revision"] = child
    recorder.ids["candidate_version_1_revision"] = str(child)

    _assign(connection, child, owner)
    approve = _review(
        client, recorder, child, "APPROVE_FOR_REVIEW",
        "TEST-ONLY review scaffolding: accepted for methodologist review.")
    assert approve.status_code == 201, approve.json()
    assert approve.json()["decision"] == "APPROVE_FOR_REVIEW"

    prepare2 = _call(
        client, recorder, "POST",
        f"/m2/research-objectives/{discovered['objective_id']}/qg-candidate",
        json={"expected_revision": discovered["revision"],
              "context_id": str(discovered["context_id"])},
    )
    body2 = prepare2.json()
    assert prepare2.status_code == 200, body2
    v2 = UUID(body2["version"])
    assert v2 != v1 and v2 != child
    _assign(connection, v2, owner)
    reject = _review(
        client, recorder, v2, "REJECT",
        "TEST-ONLY review scaffolding: insufficient confirmed detail.")
    assert reject.status_code == 201, reject.json()
    assert reject.json()["decision"] == "REJECT"
    discovered["version_2"] = v2
    recorder.ids["candidate_version_2"] = str(v2)

    review_rows = connection.execute(text("""
        SELECT r.candidate_id, r.decision, r.context_hash, r.reviewer_id
        FROM public.m2_candidate_owner_reviews r ORDER BY r.recorded_at, r.candidate_id
    """)).mappings().all()
    assert len(review_rows) == 3
    assert {r["decision"] for r in review_rows} == {
        "REQUEST_REVISION", "APPROVE_FOR_REVIEW", "REJECT"}
    for row in review_rows:
        assert str(row["context_hash"]) == discovered["snapshot_digest"]
    recorder.lineage_row(
        6, "m2_candidate_owner_reviews (context_hash)",
        "SELECT r.candidate_id, r.decision, r.context_hash, r.reviewer_id "
        "FROM m2_candidate_owner_reviews r",
        [{"candidate_id": str(r["candidate_id"]), "decision": r["decision"],
          "context_hash": str(r["context_hash"]), "reviewer_id": str(r["reviewer_id"])}
         for r in review_rows])

    history = _call(
        client, recorder, "GET",
        f"/m2/research-objectives/{discovered['objective_id']}/research-questions",
        params={"expected_revision": discovered["revision"]},
    ).json()
    assert history["version_count"] == 3
    assert {entry["decision"] for entry in history["versions"]} == {
        "REQUEST_REVISION", "APPROVE_FOR_REVIEW", "REJECT"}
    assert {entry["version"] for entry in history["versions"]} == {
        str(v1), str(child), str(v2)}
    recorder.checkpoint(
        "06_owner_reviews_all_three_and_revision", "PASS",
        "REQUEST_REVISION -> revision -> APPROVE_FOR_REVIEW, plus REJECT; "
        "3 persisted reviews with context_hash; history shows all 3 versions")


# ---------------------------------------------------------------------------
# 7. Evidence integrity and rollback proof
# ---------------------------------------------------------------------------
def test_07_evidence_files_and_rollback(recorder):
    recorder.rollback_now()
    write_evidence(recorder)
    for name in ("api_evidence.json", "sql_lineage.sql", "report.md"):
        path = EVIDENCE_DIR / name
        assert path.is_file() and path.stat().st_size > 0, path
    payload = json.loads((EVIDENCE_DIR / "api_evidence.json").read_text(encoding="utf-8"))
    assert payload["authority"] == AUTHORITY
    assert payload["provider_or_network_model_calls"] == 0
    assert payload["api_requests_and_responses"]
    for item in payload["api_requests_and_responses"]:
        assert item["authorization"] == "Bearer <REDACTED>"
        assert item["authority"] == AUTHORITY
    assert recorder.after_rollback == recorder.baseline, (
        f"clone was mutated: {recorder.baseline} -> {recorder.after_rollback}")
    recorder.checkpoint(
        "07_evidence_and_rollback", "PASS",
        f"3 evidence files written; all row counts identical after rollback "
        f"({recorder.baseline})")
