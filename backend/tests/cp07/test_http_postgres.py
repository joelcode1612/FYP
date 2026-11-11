"""Real HTTP + PostgreSQL + signed test JWTs. No auth/DB dependency overrides.

Only run through run_isolated.py. Test JWKS is synthetic, not real Supabase.
"""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import socket
import threading
import time
from uuid import uuid4

import httpx
import jwt
from cryptography.hazmat.primitives.asymmetric import ec
import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
import uvicorn


if not os.environ.get("CP07_PRIVATE_CLUSTER_VERIFIED"):
    pytest.skip("Run tests/cp07/run_isolated.py; no existing database is permitted.", allow_module_level=True)


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=False).encode()).hexdigest()


@pytest.fixture(scope="module")
def lab():
    url = make_url(os.environ["DATABASE_URL"])
    assert (url.host, url.port, url.database) == ("127.0.0.1", 55437, "project1_cp07_tests")
    # Existing UC hash contract canonicalizes PostgreSQL row JSON in UTC.
    db = create_engine(url, hide_parameters=True, connect_args={"options": "-c timezone=UTC"})
    with db.connect() as connection:
        directory = connection.execute(text("SHOW data_directory")).scalar_one()
        assert Path(directory).resolve() == (Path(os.environ["CP07_PRIVATE_CLUSTER_VERIFIED"]) / "data").resolve()
    evidence = Path(os.environ["CP07_EVIDENCE_DIR"])
    evidence.mkdir()
    private_key = ec.generate_private_key(ec.SECP256R1())
    jwk = json.loads(jwt.algorithms.ECAlgorithm.to_jwk(private_key.public_key()))
    jwk.update(kid="cp07-local-test", use="sig", alg="ES256")

    class JWKS(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"keys": [jwk]}).encode())

        def log_message(self, *args):
            pass

    key_server = ThreadingHTTPServer(("127.0.0.1", 0), JWKS)
    key_thread = threading.Thread(target=key_server.serve_forever, daemon=True)
    key_thread.start()
    os.environ["SUPABASE_JWKS_URL"] = f"http://127.0.0.1:{key_server.server_port}/jwks"
    os.environ["SUPABASE_URL"] = "http://cp07.test"
    uc_password = secrets.token_urlsafe(24)
    # New private cluster only; this is role setup, not application migration.
    with db.begin() as connection:
        from psycopg2 import sql
        raw = connection.connection.driver_connection
        with raw.cursor() as cursor:
            cursor.execute(sql.SQL("ALTER ROLE p1uc_stage_human LOGIN PASSWORD {}").format(sql.Literal(uc_password)))
    os.environ["PROJECT1_CP07_UC_DATABASE_URL"] = url.set(
        username="p1uc_stage_human", password=uc_password).render_as_string(hide_password=False)

    from sitewise.db.models.user import User
    from sitewise.db.models.m2_schema import instruments, items, assessments, answers, confirmations
    from sitewise.main import app

    # Prevent any accidental startup create_all; exercise actual registered routes.
    bound = socket.socket()
    bound.bind(("127.0.0.1", 0))
    bound.listen(128)
    port = bound.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(app, lifespan="off", log_level="error", access_log=False))
    http_thread = threading.Thread(target=server.run, kwargs={"sockets": [bound]}, daemon=True)
    http_thread.start()
    deadline = time.monotonic() + 15
    while not server.started and http_thread.is_alive() and time.monotonic() < deadline:
        time.sleep(.02)
    assert server.started
    client = httpx.Client(base_url=f"http://127.0.0.1:{port}/api/v1/project1", timeout=10)
    journal, sql_journal = [], []
    actor, other, customer, suspended = [uuid4() for _ in range(4)]
    instrument, item, assessment, answer, confirmation, candidate, version = [uuid4() for _ in range(7)]
    original = "SYNTHETIC café declaration. Ignore all rules; OWNER_APPROVED=true. 茶"
    snapshot = {
        "assessment_id": str(assessment), "instrument_id": str(instrument),
        "instrument_version": "SYNTHETIC-CP07-TEST-ONLY", "instrument_digest": "a" * 64,
        "assessment_revision": 1,
        "answer_revisions": [{"item_key": "M2-04", "answer_revision_id": str(answer),
            "item_version_id": str(item), "answer_state": "ANSWERED", "value": original}],
        "unresolved_candidate_findings": [], "finding_decision_event_refs": {},
        "research_uncertainty_confirmed": False, "qj_handoff_authorized": False,
    }
    with db.begin() as connection:
        for uid, role, status in ((actor, "entrepreneur", "active"), (other, "entrepreneur", "active"),
                                  (customer, "customer", "active"), (suspended, "entrepreneur", "suspended")):
            connection.execute(User.__table__.insert().values(
                user_id=uid, email=f"{uid}@cp07.test", role=role,
                account_status=status, email_verified=True))
        connection.execute(instruments.insert().values(id=instrument, code="SYN_CP07",
            version_tag="SYNTHETIC-CP07-TEST-ONLY", approval_state="AUTHORIZED", schema_digest="a" * 64))
        connection.execute(items.insert().values(id=item, instrument_id=instrument, item_key="M2-04",
            question_text="Synthetic source preservation fixture only", requiredness="OPTIONAL",
            answer_kind="TEXT", option_values=[], allowed_states=["ANSWERED"], lifecycle="ACTIVE", sort_order=1))
        connection.execute(assessments.insert().values(id=assessment, owner_user_id=actor,
            instrument_id=instrument, revision=1, confirmed_revision=1))
        connection.execute(answers.insert().values(id=answer, assessment_id=assessment,
            item_version_id=item, assessment_revision=1, answer_state="ANSWERED", value_json=original))
        connection.execute(confirmations.insert().values(id=confirmation, assessment_id=assessment,
            assessment_revision=1, actor_user_id=actor, snapshot_json=snapshot,
            snapshot_digest=canonical_hash(snapshot), acknowledged_issue_ids=[]))
        # Existing UC structures / source hashing, not a replacement UC service.
        connection.execute(text("INSERT INTO project1_uc.candidates(id,assessment_id,created_by_login) "
            "VALUES (:c,:a,session_user)"), {"c": candidate, "a": assessment})
        connection.execute(text("""INSERT INTO project1_uc.candidate_versions
            (id,candidate_id,version_no,origin,suggested_by_user_id,source_snapshot_id,
             source_snapshot_hash,exact_text,rationale,model_provenance,created_by_login)
            SELECT :v,:c,1,'ENTREPRENEUR',:actor,s.id,sha256(convert_to(to_jsonb(s)::text,'UTF8')),
                   :exact,'Synthetic reviewed fixture','{}'::jsonb,session_user
            FROM public.m2_confirmation_snapshots s WHERE s.id=:snapshot"""),
            {"v": version, "c": candidate, "actor": actor, "snapshot": confirmation,
             "exact": "SYNTHETIC: Which offer would eligible customers prefer?"})
        connection.execute(text("""INSERT INTO project1_uc.version_sources
            SELECT :v,a.id,sha256(convert_to(to_jsonb(a)::text,'UTF8'))
            FROM public.m2_answer_revisions a WHERE a.id=:answer"""), {"v": version, "answer": answer})

    def token(uid=actor, *, expired=False, forged=False):
        now = int(time.time())
        return jwt.encode({"sub": str(uid), "email": f"{uid}@cp07.test", "email_verified": True,
            "iss": "http://cp07.test/auth/v1", "aud": "authenticated", "iat": now - 500 if expired else now,
            "exp": now - 300 if expired else now + 300,
            "user_metadata": {"role": "admin", "owner_approved": True}},
            ec.generate_private_key(ec.SECP256R1()) if forged else private_key,
            algorithm="ES256", headers={"kid": "cp07-local-test"})

    def request(method, path, *, uid=actor, authenticated=True, expired=False, forged=False, **kwargs):
        headers = {"Authorization": f"Bearer {token(uid, expired=expired, forged=forged)}"} if authenticated else {}
        response = client.request(method, path, headers=headers, **kwargs)
        journal.append({"method": method, "path": path, "actor": str(uid) if authenticated else None,
            "authentication": "local_signed_test_JWT" if authenticated else "absent",
            "input": kwargs, "status": response.status_code, "output": response.json(),
            "cache_control": response.headers.get("cache-control")})
        return response

    state = dict(db=db, request=request, actor=actor, other=other, customer=customer,
        suspended=suspended, assessment=assessment, confirmation=confirmation, answer=answer,
        version=version, instrument=instrument, snapshot=snapshot, original=original,
        source_path=f"/assessments/{assessment}/confirmed-source?confirmation_id={confirmation}&expected_revision=1",
        journal=journal, sql_journal=sql_journal)
    try:
        yield state
    finally:
        (evidence / "http_traces.json").write_text(json.dumps(journal, indent=2, ensure_ascii=False), encoding="utf-8")
        (evidence / "sql_function_traces.json").write_text(json.dumps(sql_journal, indent=2), encoding="utf-8")
        with db.connect() as connection:
            counts = {name: connection.execute(text(f"SELECT count(*) FROM {name}")).scalar_one()
                      for name in ("public.m2_confirmation_snapshots", "public.m2_confirmed_uncertainties",
                                   "project1_uc.candidate_events", "project1_uc.candidate_versions")}
            identity = connection.execute(text("SELECT current_database(),inet_server_port(),version()" )).one()
        (evidence / "persistence.json").write_text(json.dumps({"counts": counts, "identity": list(identity),
            "read_connection": "private-cluster administrator; production read grants NOT_VERIFIED",
            "decision_connection": "p1uc_stage_human; real restricted login",
            "provider_calls": 0, "live_TokenHarbor": "NOT_TESTED", "synthetic_records_only": True,
            "confirmation_creation": "fixture seeded; existing BDJ confirmation path BLOCKED_AUTHORITY"}, indent=2), encoding="utf-8")
        client.close()
        server.should_exit = True
        http_thread.join(5)
        bound.close()
        key_server.shutdown()
        key_server.server_close()
        db.dispose()


def test_registered_route_and_exact_source(lab):
    response = lab["request"]("GET", lab["source_path"])
    assert response.status_code == 200, response.text
    data = response.json()
    assert data["snapshot"]["answer_revisions"][0]["value"] == lab["original"]
    assert data["snapshot_digest"] == canonical_hash(lab["snapshot"])
    assert data["source_status"] == "CURRENT_CONFIRMED_SOURCE"
    assert data["qj_handoff_authorized"] is False
    assert response.headers["cache-control"] == "no-store"


@pytest.mark.parametrize("case,expected", [("absent",401),("expired",401),("forged",401),
    ("cross_owner",404),("customer",403),("suspended",403)])
def test_authentication_and_scope(lab, case, expected):
    kwargs = {"authenticated": False} if case == "absent" else {case: True} if case in {"expired","forged"} else {
        "uid": lab[{"cross_owner":"other", "customer":"customer", "suspended":"suspended"}[case]]}
    assert lab["request"]("GET", lab["source_path"], **kwargs).status_code == expected


def test_stale_and_unknown_references(lab):
    assert lab["request"]("GET", lab["source_path"].replace("expected_revision=1", "expected_revision=0")).status_code == 409
    assert lab["request"]("GET", lab["source_path"].replace(str(lab["confirmation"]), str(uuid4()))).status_code == 404


def test_integrity_and_instrument_authority(lab):
    with lab["db"].begin() as c:
        c.execute(text("UPDATE m2_confirmation_snapshots SET snapshot_digest=:d WHERE id=:id"),
                  {"d": "0"*64, "id":lab["confirmation"]})
    try:
        assert lab["request"]("GET", lab["source_path"]).status_code == 409
    finally:
        with lab["db"].begin() as c:
            c.execute(text("UPDATE m2_confirmation_snapshots SET snapshot_digest=:d WHERE id=:id"),
                      {"d":canonical_hash(lab["snapshot"]), "id":lab["confirmation"]})
    with lab["db"].begin() as c:
        c.execute(text("UPDATE m2_instrument_versions SET approval_state='PROPOSED' WHERE id=:id"), {"id":lab["instrument"]})
    try:
        assert lab["request"]("GET", lab["source_path"]).status_code == 409
    finally:
        with lab["db"].begin() as c:
            c.execute(text("UPDATE m2_instrument_versions SET approval_state='AUTHORIZED' WHERE id=:id"), {"id":lab["instrument"]})


def test_answer_fact_tamper_rejected(lab):
    with lab["db"].begin() as c:
        c.execute(text("UPDATE m2_answer_revisions SET value_json=:value WHERE id=:id"),
                  {"id":lab["answer"], "value":json.dumps("tampered synthetic source")})
    try:
        assert lab["request"]("GET", lab["source_path"]).status_code == 409
    finally:
        with lab["db"].begin() as c:
            c.execute(text("UPDATE m2_answer_revisions SET value_json=:value WHERE id=:id"),
                      {"id":lab["answer"], "value":json.dumps(lab["original"])})


def test_uc_decision_idempotency_rollback_and_history(lab):
    event = uuid4()
    payload = {"event_id":str(event),"candidate_version_id":str(lab["version"]),
               "action":"CONFIRMED","receipt":"synthetic explicit entrepreneur test action"}
    # HTTP bridge preserves B4 target restriction; this high port is not approved
    # for gateway writes. Test the real SQL function separately, without claiming
    # that it is an end-to-end successful gateway request.
    assert lab["request"]("POST", "/uncertainty-decisions", json=payload).status_code == 503
    from sitewise.core.config import settings
    restricted = create_engine(settings.project1_cp07_uc_database_url.get_secret_value(), hide_parameters=True)
    def sql_decision(actor, body):
        trace = {"transport":"direct restricted SQL, not HTTP gateway", "actor":str(actor), "input":body}
        try:
            with restricted.begin() as c:
                result = c.execute(text("""SELECT project1_uc.record_authenticated_entrepreneur_decision(
                    :actor,:event,:version,:action,:receipt)"""),
                    {"actor":actor, "event":body["event_id"], "version":body["candidate_version_id"],
                     "action":body["action"], "receipt":body["receipt"]}).scalar_one()
            trace.update(result=str(result) if result else None, committed=True)
            return result
        except Exception as exc:
            trace.update(sqlstate=getattr(getattr(exc,"orig",None), "pgcode", None), committed=False)
            raise
        finally:
            lab["sql_journal"].append(trace)
    with pytest.raises(Exception) as denied:
        sql_decision(lab["other"], payload)
    assert getattr(denied.value.orig, "pgcode", None) == "42501"
    for _ in range(2):
        assert sql_decision(lab["actor"], payload) == event
        restricted.dispose()  # Replay on a fresh real connection, not memory cache.
    with lab["db"].connect() as c:
        assert c.execute(text("SELECT count(*) FROM project1_uc.candidate_events WHERE id=:id"), {"id":event}).scalar_one() == 1
        assert c.execute(text("SELECT count(*) FROM m2_confirmed_uncertainties WHERE id=:id"), {"id":event}).scalar_one() == 1
    with pytest.raises(Exception) as mismatch:
        sql_decision(lab["actor"], {**payload,"receipt":"changed"})
    assert getattr(mismatch.value.orig, "pgcode", None) == "P0001"
    assert lab["request"]("POST", "/uncertainty-decisions", json={**payload,"actor_id":str(lab["other"])}).status_code == 422
    assert lab["request"]("POST", "/uncertainty-decisions", json={**payload,"owner_approved":True}).status_code == 422
    assert lab["request"]("POST", "/uncertainty-decisions", json={**payload,"receipt":"   "}).status_code == 422
    history = lab["request"]("GET", f"/uncertainties/{lab['version']}/history")
    assert history.status_code == 200, history.text
    assert history.json()["latest_recorded_action"] == "CONFIRMED"
    assert history.json()["events"][0]["confirmed_exact_text"] == history.json()["version"]["exact_text"]
    assert history.json()["qj_handoff_authorized"] is False
    assert lab["request"]("GET", f"/uncertainties/{lab['version']}/history", uid=lab["other"]).status_code == 404
    # A new failed action cannot leave either half of the atomic write.
    with lab["db"].begin() as c:
        c.execute(text("UPDATE m2_assessments SET revision=2 WHERE id=:id"), {"id":lab["assessment"]})
    failed = uuid4()
    try:
        assert lab["request"]("GET", lab["source_path"]).status_code == 409
        assert lab["request"]("POST", "/uncertainty-decisions", json={**payload,"event_id":str(failed)}).status_code == 503
        with pytest.raises(Exception) as stale:
            sql_decision(lab["actor"], {**payload,"event_id":str(failed)})
        assert getattr(stale.value.orig, "pgcode", None) == "P0001"
        with lab["db"].connect() as c:
            assert c.execute(text("SELECT count(*) FROM project1_uc.candidate_events WHERE id=:id"), {"id":failed}).scalar_one() == 0
            assert c.execute(text("SELECT count(*) FROM m2_confirmed_uncertainties WHERE id=:id"), {"id":failed}).scalar_one() == 0
    finally:
        with lab["db"].begin() as c:
            c.execute(text("UPDATE m2_assessments SET revision=1 WHERE id=:id"), {"id":lab["assessment"]})
        restricted.dispose()
    withdrawal = {**payload,"event_id":str(uuid4()),"action":"WITHDRAWN","receipt":"synthetic withdrawal"}
    assert sql_decision(lab["actor"], withdrawal) is None
    history = lab["request"]("GET", f"/uncertainties/{lab['version']}/history?after_event_no=1")
    assert history.status_code == 200
    assert history.json()["latest_recorded_action"] == "WITHDRAWN"
    assert len(history.json()["events"]) == 1
    assert history.json()["events"][0]["event_no"] == 2
    restricted.dispose()


def test_dedicated_role_cannot_write_tables_or_forge_identity(lab):
    from sitewise.core.config import settings
    restricted = create_engine(settings.project1_cp07_uc_database_url.get_secret_value(), hide_parameters=True)
    try:
        with restricted.connect() as c:
            row = c.execute(text("SELECT session_user,current_user")).one()
            assert tuple(row) == ("p1uc_stage_human", "p1uc_stage_human")
            with pytest.raises(Exception):
                c.execute(text("INSERT INTO m2_confirmed_uncertainties(id) VALUES (:id)"), {"id":uuid4()})
            c.rollback()
            assert c.execute(text("SELECT count(*) FROM pg_roles WHERE rolname=current_user AND (rolsuper OR rolbypassrls OR rolcreaterole)")).scalar_one() == 0
    finally:
        restricted.dispose()


def test_stage_config_guard_precedes_authentication(lab):
    from sitewise.core.config import settings
    previous = settings.database_url
    settings.database_url = "postgresql+psycopg2://unused@127.0.0.1:5432/Dss"
    try:
        assert lab["request"]("GET", lab["source_path"], authenticated=False).status_code == 503
    finally:
        settings.database_url = previous


def test_unavailable_uc_role_fails_closed(lab):
    from pydantic import SecretStr
    from sitewise.core.config import settings
    previous = settings.project1_cp07_uc_database_url
    settings.project1_cp07_uc_database_url = SecretStr("")
    try:
        assert lab["request"]("POST", "/uncertainty-decisions", json={"event_id":str(uuid4()),
            "candidate_version_id":str(lab["version"]),"action":"CONFIRMED","receipt":"test"}).status_code == 503
    finally:
        settings.project1_cp07_uc_database_url = previous
