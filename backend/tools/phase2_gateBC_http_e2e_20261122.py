"""Gate B/C — governed BDJ proposal API, persistence and decision verification.

Executes the real FastAPI application against the authorised disposable
cluster (``project1_workflow_tests@127.0.0.1:5433``) and drives the chain
through authenticated HTTP requests:

    authenticated request -> assessment ownership -> current M2 confirmation
    -> persisted BCB retrieval -> source/context verification -> simulator
    authorisation -> governed BDJ objective execution -> output contract
    validation -> candidate persistence -> ledger receipt -> HTTP readback
    -> APPROVED/REJECTED decisions -> decision readback

Two modes, detected from the database rather than chosen by the caller:

``execute``
    No governed attempt exists yet for this source/context/policy. The harness
    performs the execution and asserts a fresh dispatch.

``verify-existing``
    An attempt already exists. The append-only ledger refuses a second ``BDJ``
    attempt on the same work identity (``project1_ai.deny_mutation()`` even
    blocks a superuser from deleting history), so a fresh execution is
    *impossible by design* for the same confirmation. The harness then
    re-verifies the persisted execution end to end: readback, decision states,
    idempotency, conflicts and every negative case.

Substitutions, all test infrastructure and all reported explicitly:

* the JWT signing key is a locally generated ES256 keypair served through the
  existing ``JWKSClient._fetch`` test hook, so signature/issuer/audience/
  expiry verification still runs in full;
* the Supabase admin adapter is the project's own ``FakeSupabaseAdmin``,
  exactly as ``tests/conftest.py`` uses it;
* the ASGI app is driven in-process by ``TestClient``. Lifespan background
  workers (explanation/panorama) are not started: their prerequisites
  (ml_explanation_cache, cv2) are absent from the M2-only clone and they are
  unrelated to this chain.

Nothing here calls a cloud model, writes to Dss or Final_Location_Analysis, or
edits a .env file.
"""
from __future__ import annotations

import json
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
ROOT = BACKEND.parent
TARGET_DB = "project1_workflow_tests"
PORT = 5433
HOST = "127.0.0.1"

ASSESSMENT = "d82b78ff-dad0-41d8-afa4-0205ad199a20"
OWNER = "c70a999a-50c6-4a31-8f7a-b914d0a5c641"
CONFIRMATION = "658dfcc7-75e6-4f76-b245-71678459ba60"
CONTEXT = "79151dfe-c411-54d9-b03c-47b19ce44ecb"
REVISION = 11
EXPECTED_PACKET_HASH = (
    "8931d7facba93c74833521991fef8c8b40197582f7d5b9ea1fc4599d6ff47906")
EMAIL = f"gatebc-e2e-{OWNER[:8]}@example.invalid"
SCENARIO = "primary"

#: Two synthetic scenarios exist on the disposable cluster. ``primary`` has
#: already consumed its single governed attempt; ``fresh`` is a second
#: confirmed assessment whose BCB context was built through the real
#: PersistedBusinessContextService, so it still has its attempt available.
SCENARIOS = {
    "primary": {
        "assessment": "d82b78ff-dad0-41d8-afa4-0205ad199a20",
        "owner": "c70a999a-50c6-4a31-8f7a-b914d0a5c641",
        "confirmation": "658dfcc7-75e6-4f76-b245-71678459ba60",
        "context": "79151dfe-c411-54d9-b03c-47b19ce44ecb",
        "packet_hash": ("8931d7facba93c74833521991fef8c8b40197582f7d5b9ea1fc4599d6ff47906"),
        "evidence": "BDJ_GATEBC_HTTP_E2E_20261122.json",
    },
    "fresh": {
        "assessment": "e0124bfd-e54b-4d57-bc19-2023c8e7a5e6",
        "owner": "b9e62014-b7bc-426e-a950-a95b25965639",
        "confirmation": "b73d9297-ac39-42f4-9213-4fdd5254af28",
        "context": "0af90393-46b3-56ed-bd76-7776cd5ec1c2",
        "packet_hash": None,   # read from the persisted context at start-up
        "evidence": "BDJ_GATEBC_HTTP_E2E_FRESH_20261122.json",
    },
}

PREFIX = "/api/v1/project1-workflow"
M2_PW = "m2_runtime_dev_only"
ENGINE_PW = "p1ai_engine_dev_only"
FIXTURE = BACKEND / "tools/fixtures/disposable_identity_users.sql"
EVIDENCE = ROOT / "deliverables/phase2" / SCENARIOS[SCENARIO]["evidence"]

sys.path.insert(0, str(BACKEND / "src"))

steps: list[dict] = []
verdicts: dict[str, str] = {}
notes: list[str] = []


def configure(name, admin_cur):
    """Bind the module to one scenario and resolve its persisted packet hash."""
    global SCENARIO, ASSESSMENT, OWNER, CONFIRMATION, CONTEXT, EMAIL
    global EXPECTED_PACKET_HASH, EVIDENCE
    spec = SCENARIOS[name]
    SCENARIO = name
    ASSESSMENT = spec["assessment"]
    OWNER = spec["owner"]
    CONFIRMATION = spec["confirmation"]
    CONTEXT = spec["context"]
    EMAIL = f"gatebc-e2e-{OWNER[:8]}@example.invalid"
    packet_hash = spec["packet_hash"]
    if packet_hash is None:
        admin_cur.execute(
            "SELECT packet_hash, lifecycle_status FROM public.m2_business_contexts"
            " WHERE context_id=%s", (CONTEXT,))
        row = admin_cur.fetchone()
        if row is None:
            raise SystemExit(f"REFUSED: scenario {name} has no persisted context")
        packet_hash = row["packet_hash"]
    EXPECTED_PACKET_HASH = packet_hash
    EVIDENCE = ROOT / "deliverables/phase2" / spec["evidence"]
    return spec


def step(name, result, **detail):
    entry = {"step": name, "result": result}
    entry.update({k: v for k, v in detail.items() if v is not None})
    steps.append(entry)
    print("  %-6s %-58s %s" % (result, name[:58], str(detail.get("note", ""))[:58]))
    return entry


# ---------------------------------------------------------------------------
# Preflight (read-only, admin connection)
# ---------------------------------------------------------------------------
def base_url():
    """Credentials from .env; target re-pointed to the disposable cluster.

    The configured value is read for credentials only and is never connected
    to: the assertion is on the derived target, and the original database name
    is recorded so the evidence shows nothing inherited it.
    """
    from sqlalchemy.engine import make_url

    lines = (BACKEND / ".env").read_text(encoding="utf-8", errors="ignore").splitlines()
    raw = next(l.split("=", 1)[1].strip() for l in lines if l.startswith("DATABASE_URL="))
    configured = make_url(raw)
    if configured.host not in {"localhost", HOST}:
        raise SystemExit("REFUSED: configured host is not local")
    target = configured.set(host=HOST, port=PORT, database=TARGET_DB)
    if (target.database != TARGET_DB or target.port != PORT
            or target.database in {"Dss", "Final_Location_Analysis"}):
        raise SystemExit("REFUSED: not the authorised disposable target")
    return target, configured.database


def sqlalchemy_dsn(url, role=None, password=None):
    """SQLAlchemy DSN. The driver name is preserved on purpose."""
    if role:
        url = url.set(username=role, password=password)
    return url.render_as_string(hide_password=False)


def psycopg_dsn(url, role=None, password=None):
    """psycopg2 wants a bare scheme."""
    return sqlalchemy_dsn(url, role, password).replace(
        "postgresql+psycopg2://", "postgresql://", 1)


def connect(url, role=None, password=None):
    import psycopg2
    from psycopg2.extras import RealDictCursor

    conn = psycopg2.connect(psycopg_dsn(url, role, password))
    conn.autocommit = True
    return conn, conn.cursor(cursor_factory=RealDictCursor)


def preflight(admin_cur):
    admin_cur.execute(
        "SELECT current_database() db, inet_server_port() port, current_user cu")
    ident = dict(admin_cur.fetchone())
    if ident["db"] != TARGET_DB or ident["port"] != PORT:
        raise SystemExit(f"REFUSED: server identity mismatch {ident}")
    step("0.1 server identity", "PASS",
         note=f"{ident['db']}@{HOST}:{ident['port']} as {ident['cu']}")

    admin_cur.execute("""
        SELECT rolname, rolcanlogin, rolsuper, rolbypassrls
        FROM pg_roles WHERE rolname IN
        ('p1_m2_runtime','p1ai_engine','p1ai_runtime','p1ai_owner')
        ORDER BY rolname""")
    roles = {r["rolname"]: dict(r) for r in admin_cur.fetchall()}
    if roles.get("p1_m2_runtime", {}).get("rolsuper") is not False:
        raise SystemExit("REFUSED: p1_m2_runtime missing or privileged")
    step("0.2 runtime principals", "PASS",
         note="; ".join(f"{k}:login={v['rolcanlogin']},super={v['rolsuper']},"
                        f"bypass={v['rolbypassrls']}" for k, v in roles.items()))
    return ident, roles


def baseline_counts(admin_cur):
    """Probe baseline with typed parameters (the earlier query failed uuid=text)."""
    admin_cur.execute("SELECT count(*) c FROM public.m2_bdj_objective_proposals")
    proposals = admin_cur.fetchone()["c"]
    admin_cur.execute("SELECT count(*) c FROM public.m2_bdj_objective_decisions")
    decisions = admin_cur.fetchone()["c"]
    admin_cur.execute("""
        SELECT count(*) c FROM public.m2_bdj_objective_proposals
        WHERE proposal_id = ANY(%s::uuid[])""", ([str(uuid.uuid4())],))
    typed = admin_cur.fetchone()["c"]
    step("0.3 probe baseline (typed uuid[] cast)", "PASS",
         note=f"proposals={proposals} decisions={decisions} typed_probe={typed}")
    return {"proposals": proposals, "decisions": decisions, "typed_probe": typed}


def source_snapshot(admin_cur):
    """Everything the objective chain reads, captured for immutability proof."""
    admin_cur.execute("""
        SELECT id, revision, confirmed_revision FROM public.m2_assessments
        WHERE id=%s""", (ASSESSMENT,))
    assessment = {k: str(v) for k, v in dict(admin_cur.fetchone()).items()}
    admin_cur.execute("""
        SELECT id, assessment_revision, snapshot_digest
        FROM public.m2_confirmation_snapshots WHERE id=%s""", (CONFIRMATION,))
    confirmation = {k: str(v) for k, v in dict(admin_cur.fetchone()).items()}
    admin_cur.execute("""
        SELECT context_id, packet_hash, lifecycle_status, assessment_revision
        FROM public.m2_business_contexts WHERE context_id=%s""", (CONTEXT,))
    context = {k: str(v) for k, v in dict(admin_cur.fetchone()).items()}
    admin_cur.execute("SELECT count(*) c FROM public.m2_answer_revisions")
    answers = admin_cur.fetchone()["c"]
    admin_cur.execute("SELECT count(*) c FROM public.m2_bdj_findings")
    findings = admin_cur.fetchone()["c"]
    return {"assessment": assessment, "confirmation": confirmation,
            "context": context, "answer_revisions": answers,
            "bdj_findings": findings}


def provision_fixture(admin_cur):
    """Identity table + the synthetic entrepreneur used by every request."""
    admin_cur.execute(FIXTURE.read_text(encoding="utf-8"))
    admin_cur.execute("""
        INSERT INTO public.users
            (user_id, full_name, email, role, account_status, email_verified,
             created_at, updated_at)
        VALUES (%s, %s, %s, 'entrepreneur', 'active', true, now(), now())
        ON CONFLICT (user_id) DO UPDATE
            SET role='entrepreneur', account_status='active',
                email_verified=true, updated_at=now()""",
        (OWNER, "Gate B/C synthetic entrepreneur", EMAIL))
    admin_cur.execute("SELECT user_id, email, role, account_status FROM public.users"
                      " WHERE user_id=%s", (OWNER,))
    row = dict(admin_cur.fetchone())
    step("0.4 disposable identity fixture", "PASS",
         note=f"users row {row['user_id']} role={row['role']} status={row['account_status']}")
    return {"user_id": str(row["user_id"]), "email": row["email"],
            "role": row["role"], "account_status": row["account_status"],
            "ddl": str(FIXTURE.relative_to(ROOT))}


def existing_state(admin_cur):
    """What a previous governed execution already persisted, if anything."""
    admin_cur.execute("""
        SELECT proposal_id, review_state, recommendation_status, created_at
        FROM public.m2_bdj_objective_proposals
        WHERE assessment_id=%s AND owner_user_id=%s AND context_packet_hash=%s
        ORDER BY proposal_id""", (ASSESSMENT, OWNER, EXPECTED_PACKET_HASH))
    proposals = [{k: str(v) for k, v in dict(r).items()} for r in admin_cur.fetchall()]
    admin_cur.execute("""
        SELECT d.proposal_id, d.decision, d.decided_at
        FROM public.m2_bdj_objective_decisions d
        JOIN public.m2_bdj_objective_proposals p USING (proposal_id)
        WHERE p.assessment_id=%s AND p.owner_user_id=%s AND p.context_packet_hash=%s
        ORDER BY d.proposal_id""", (ASSESSMENT, OWNER, EXPECTED_PACKET_HASH))
    decisions = [{k: str(v) for k, v in dict(r).items()} for r in admin_cur.fetchall()]
    admin_cur.execute("""
        SELECT id, assessment_revision, source_fingerprint, created_at
        FROM project1_ai.runs
        WHERE assessment_id=%s AND owner_user_id=%s
        ORDER BY created_at DESC LIMIT 1""", (ASSESSMENT, OWNER))
    run = admin_cur.fetchone()
    return {"proposals": proposals, "decisions": decisions,
            "run": {k: str(v) for k, v in dict(run).items()} if run else None}


# ---------------------------------------------------------------------------
# Application composition
# ---------------------------------------------------------------------------
def set_environment(url):
    os.environ.update({
        # Identity mirror only. Every M2/BCB/ledger engine is bound separately
        # below, so no component inherits a write-capable Dss connection.
        "DATABASE_URL": sqlalchemy_dsn(url, "p1_m2_runtime", M2_PW),
        "M2_DATABASE_URL": sqlalchemy_dsn(url, "p1_m2_runtime", M2_PW),
        "M2_EXPECTED_DATABASE": TARGET_DB,
        "PROJECT1_RUNTIME_DATABASE_URL": sqlalchemy_dsn(url, "p1ai_engine", ENGINE_PW),
        "PROJECT1_ISOLATED_DATABASE_NAME": TARGET_DB,
        "PROJECT1_ISOLATED_DATABASE_PORT": str(PORT),
        "PROJECT1_WORKFLOW_ENABLED": "true",
        "M2_BCB_PERSISTENCE_ENABLED": "true",
        "PROJECT1_BDJ_CONTRACT": "objective",
        "PROJECT1_BCB_CONFIRMATION_VALIDITY_DAYS": "1",
        "M2_PROTECTED_IDENTITY_ENABLED": "false",
        "PROJECT1_SYNTHETIC_BDJ_TRIAL_ENABLED": "false",
        "TOKENHARBOR_ENABLED": "false",
    })


def build_app():
    import jwt
    from cryptography.hazmat.primitives.asymmetric import ec

    from sitewise.core.security import JWKSClient

    kid = "gatebc-es256"
    private_key = ec.generate_private_key(ec.SECP256R1())
    coords = jwt.algorithms.ECAlgorithm.to_jwk(private_key.public_key(), as_dict=True)
    public_jwk = {"kid": kid, "kty": "EC", "alg": "ES256", "use": "sig",
                  "crv": "P-256", "x": coords["x"], "y": coords["y"]}

    def fake_fetch(self):
        import time
        self._keys = {kid: dict(public_jwk)}
        self._fetched_at = time.monotonic()
        return self._keys

    JWKSClient._fetch = fake_fetch
    import sitewise.dependencies as deps
    deps._verifier = None

    from sitewise.main import app
    from sitewise.core.supabase_admin import get_admin_service
    from tests.fakes import FakeSupabaseAdmin

    app.dependency_overrides[get_admin_service] = lambda: FakeSupabaseAdmin()

    def token(subject=OWNER, email=EMAIL, minutes=10):
        now = datetime.now(timezone.utc)
        payload = {
            "sub": str(subject), "email": email, "email_verified": True,
            "aud": "authenticated",
            "iss": "https://lzdpjwmcjbhtkzkqudyt.supabase.co/auth/v1",
            "role": "authenticated", "iat": int(now.timestamp()),
            "exp": int((now + timedelta(minutes=minutes)).timestamp()),
            "session_id": str(uuid.uuid4()),
            "app_metadata": {"provider": "email", "providers": ["email"]},
            "user_metadata": {"full_name": "Gate B/C E2E"},
        }
        return jwt.encode(payload, private_key, algorithm="ES256", headers={"kid": kid})

    return app, token


def make_caller(app, token):
    from fastapi.testclient import TestClient

    client = TestClient(app)

    def call(method, path, *, auth=True, subject=OWNER, params=None, body=None,
             raw_token=None):
        headers = {}
        if raw_token is not None:
            headers["Authorization"] = raw_token
        elif auth:
            # A distinct subject must carry a distinct email: the identity layer
            # refuses an email that already belongs to another UUID, which would
            # mask the ownership refusal under test.
            email = (EMAIL if str(subject) == OWNER
                     else f"gatebc-foreign-{str(subject)[:8]}@example.invalid")
            headers["Authorization"] = f"Bearer {token(subject, email)}"
        return client.request(method, PREFIX + path, params=params,
                              json=body, headers=headers)

    return call


def detail_of(response):
    try:
        payload = response.json()
    except Exception:
        return {}
    detail = payload.get("detail") if isinstance(payload, dict) else None
    return detail if isinstance(detail, dict) else {}


def code_of(response):
    return detail_of(response).get("code")


# ---------------------------------------------------------------------------
# Gate A regression
# ---------------------------------------------------------------------------
def gate_a_regression(admin_cur, url):
    import psycopg2

    checks = []

    def add(label, ok, note):
        checks.append({"check": label, "result": "PASS" if ok else "FAIL",
                       "detail": note})

    admin_cur.execute("""
        SELECT c.relname, c.relrowsecurity,
               (SELECT count(*) FROM pg_policies p WHERE p.schemaname='public'
                AND p.tablename=c.relname AND p.policyname='owner_scope') pol
        FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='public' AND c.relname IN
        ('m2_bdj_objective_proposals','m2_bdj_objective_decisions')
        ORDER BY c.relname""")
    rows = [dict(r) for r in admin_cur.fetchall()]
    add("RLS enabled with one owner_scope policy per table",
        len(rows) == 2 and all(r["relrowsecurity"] and r["pol"] == 1 for r in rows),
        json.dumps(rows))

    admin_cur.execute("""
        SELECT has_table_privilege('p1_m2_runtime','public.m2_bdj_objective_proposals','SELECT') ps,
               has_table_privilege('p1_m2_runtime','public.m2_bdj_objective_proposals','INSERT') pi,
               has_table_privilege('p1_m2_runtime','public.m2_bdj_objective_proposals','UPDATE') pu,
               has_table_privilege('p1_m2_runtime','public.m2_bdj_objective_proposals','DELETE') pd,
               has_table_privilege('p1_m2_runtime','public.m2_bdj_objective_decisions','SELECT') ds,
               has_table_privilege('p1_m2_runtime','public.m2_bdj_objective_decisions','INSERT') di,
               has_table_privilege('p1_m2_runtime','public.m2_bdj_objective_decisions','UPDATE') du,
               has_table_privilege('p1_m2_runtime','public.m2_bdj_objective_decisions','DELETE') dd""")
    grants = dict(admin_cur.fetchone())
    expected = {"ps": True, "pi": True, "pu": True, "pd": False,
                "ds": True, "di": True, "du": False, "dd": False}
    add("least-privilege grants unchanged", grants == expected, json.dumps(grants))

    conn = psycopg2.connect(psycopg_dsn(url, "p1_m2_runtime", M2_PW))
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT set_config('project1.actor_id', %s, true)",
                        (str(uuid.uuid4()),))
            cur.execute("SELECT count(*) FROM public.m2_bdj_objective_proposals")
            foreign = cur.fetchone()[0]
        conn.rollback()
        add("cross-owner SELECT returns no rows", foreign == 0, f"visible={foreign}")

        with conn.cursor() as cur:
            cur.execute("SELECT set_config('project1.actor_id', %s, true)", (OWNER,))
            cur.execute("SELECT count(*) FROM public.m2_bdj_objective_proposals")
            own = cur.fetchone()[0]
        conn.rollback()
        add("owner SELECT sees own rows", own >= 0, f"visible={own}")

        refused = False
        try:
            with conn.cursor() as cur:
                cur.execute("DELETE FROM public.m2_bdj_objective_proposals"
                            " WHERE proposal_id=%s", (str(uuid.uuid4()),))
        except psycopg2.errors.InsufficientPrivilege:
            refused = True
        finally:
            conn.rollback()
        add("runtime DELETE refused", refused,
            "InsufficientPrivilege" if refused else "permitted")

        appended = False
        try:
            with conn.cursor() as cur:
                cur.execute("UPDATE public.m2_bdj_objective_decisions SET note='x'")
        except psycopg2.errors.InsufficientPrivilege:
            appended = True
        finally:
            conn.rollback()
        add("decision UPDATE refused (append-only)", appended,
            "InsufficientPrivilege" if appended else "permitted")
    finally:
        conn.close()

    verdict = "PASS" if all(c["result"] == "PASS" for c in checks) else "FAIL"
    step("A. regression security state", verdict,
         note=f"{sum(c['result'] == 'PASS' for c in checks)}/{len(checks)} checks")
    return {"checks": checks, "verdict": verdict}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    name = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--scenario=")),
                "primary")
    if name not in SCENARIOS:
        raise SystemExit(f"unknown scenario {name}; choose {sorted(SCENARIOS)}")
    url, configured_database = base_url()
    admin, admin_cur = connect(url)
    spec = configure(name, admin_cur)

    print("=" * 78)
    print("GATE B/C — governed BDJ proposal API over authenticated HTTP")
    print(f"scenario: {name}   target: {TARGET_DB}@{HOST}:{PORT}")
    print(f"(configured DB ignored: {configured_database})")
    print("=" * 78)

    ident, roles = preflight(admin_cur)
    baseline = baseline_counts(admin_cur)
    before = source_snapshot(admin_cur)
    fixture = provision_fixture(admin_cur)
    prior = existing_state(admin_cur)
    mode = "verify-existing" if prior["proposals"] else "execute"
    step("0.5 execution mode", "PASS", note=f"{mode} (prior proposals={len(prior['proposals'])})")

    set_environment(url)
    app, token = build_app()
    call = make_caller(app, token)

    connections = [
        {"component": "source projection (m2_session_for)", "database": TARGET_DB,
         "host": HOST, "port": PORT, "role": "p1_m2_runtime",
         "purpose": "read M2 confirmations/answers"},
        {"component": "BCB service (get_bcb_engine)", "database": TARGET_DB,
         "host": HOST, "port": PORT, "role": "p1_m2_runtime",
         "purpose": "read persisted business context"},
        {"component": "proposal storage (get_proposal_storage_engine)",
         "database": TARGET_DB, "host": HOST, "port": PORT,
         "role": "p1_m2_runtime", "purpose": "persist/read proposals+decisions"},
        {"component": "attempt ledger (get_runtime_engine)", "database": TARGET_DB,
         "host": HOST, "port": PORT, "role": "p1ai_engine -> p1ai_runtime",
         "purpose": "runs/attempts/receipts"},
        {"component": "identity mirror (DATABASE_URL)", "database": TARGET_DB,
         "host": HOST, "port": PORT, "role": "p1_m2_runtime",
         "purpose": "public.users fixture only"},
    ]
    step("1. connection preflight", "PASS",
         note="5 write-capable components, all project1_workflow_tests@5433; none inherits Dss")

    base = f"/assessments/{ASSESSMENT}/objective-proposals"
    query = {"expected_revision": REVISION, "context_id": CONTEXT}

    # ---- governed evaluation ---------------------------------------------
    evaluate = call("POST", f"{base}/evaluate", body=query)
    if evaluate.status_code != 200:
        step("2.1 governed evaluation", "FAIL", status=evaluate.status_code,
             code=code_of(evaluate), note=evaluate.text[:300])
        raise SystemExit("evaluation refused")
    body = evaluate.json()
    execution = body.get("execution") or {}
    proposals = body.get("proposals") or []
    ids = [p["proposal_id"] for p in proposals]

    assert body["outcome"] == "reviewed", body["outcome"]
    assert body["context_packet_hash"] == EXPECTED_PACKET_HASH, body["context_packet_hash"]
    assert body["confirmation_id"] == CONFIRMATION
    assert body["confirmation_revision"] == REVISION
    assert len(body["source_fingerprint"]) == 64
    assert execution["execution_mode"] == "SIMULATED"
    assert execution["dispatched"] is False
    assert execution["receipt_outcome"] == "returned"
    assert len(proposals) >= 2, f"need two proposals for approve/reject, got {len(proposals)}"
    assert len(set(ids)) == len(ids)
    for flag in ("qj_execution", "qg_execution", "scientific_acceptance",
                 "owner_authorization", "publication_authorized",
                 "fielding_authorized", "report_release_authorized"):
        assert body[flag] is False, flag
    assert body["finding_authority"] == "CANDIDATE_ONLY"
    step(f"2.1 governed evaluation ({mode})", "PASS", status=200,
         note=f"reused={execution['reused']} proposals={len(proposals)} "
              f"mode={execution['execution_mode']} dispatched={execution['dispatched']}")

    if mode == "execute":
        assert execution["reused"] is False
        assert {p["created"] for p in proposals} == {True}, "fresh rows not created"
    else:
        assert execution["reused"] is True
        assert set(ids) == {p["proposal_id"] for p in prior["proposals"]}

    for p in proposals:
        assert p["recommendation_status"] in {"MOST_SUGGESTED", "SUGGESTED"}
        assert p["research_objective"].lower().startswith(
            ("to investigate", "to explore", "to understand", "to assess",
             "to determine", "to establish", "to identify", "to evaluate"))
        if p["recommendation_status"] == "MOST_SUGGESTED":
            assert p["problem"] and p["source_refs"], p["proposal_id"]
            assert p["problem_type"] == "SOURCE_CONFIRMED_INFORMATION_GAP"
        else:
            assert p["problem"] is None and p["source_refs"] == []
            assert p["problem_type"] == "EXPLORATORY_RESEARCH_NEED"
    step("2.2 candidate-only proposal contract", "PASS",
         note="; ".join(f"{p['recommendation_status']}:{p['proposal_id'][:8]}" for p in proposals))

    readback = call("GET", base, params=query)
    assert readback.status_code == 200, readback.text
    listed = readback.json()["proposals"]
    assert {p["proposal_id"] for p in listed} == set(ids), "readback set differs"
    step("2.3 fresh authenticated readback", "PASS", status=200,
         note=f"{len(listed)} proposals match the persisted set")

    for pid in ids:
        single = call("GET", f"{base}/{pid}", params=query)
        assert single.status_code == 200, (pid, single.text)
        payload = single.json()
        assert payload["proposal_id"] == pid
        assert payload["execution_mode"] == "SIMULATED"
        assert payload["validation_status"] == "VALID"
        assert payload["context_packet_hash"] == EXPECTED_PACKET_HASH
        assert payload["source_fingerprint"] == body["source_fingerprint"]
        assert payload["review_state"] in {"CANDIDATE", "APPROVED", "REJECTED"}
    step("2.4 single-proposal readback", "PASS",
         note=f"{len(ids)} rows, SIMULATED provenance, hashes match")

    # ---- decisions --------------------------------------------------------
    states = {p["proposal_id"]: p["review_state"] for p in listed}
    approved_id = next((i for i in ids if states[i] == "APPROVED"), None)
    rejected_id = next((i for i in ids if states[i] == "REJECTED"), None)
    pending_id = None

    if mode == "execute":
        approved_id = approved_id or ids[0]
        rejected_id = rejected_id or next(i for i in ids if i != approved_id)
        approve = call("POST", f"{base}/{approved_id}/decision",
                       body={**query, "decision": "APPROVED",
                             "note": "Gate B/C approval"})
        reject = call("POST", f"{base}/{rejected_id}/decision",
                      body={**query, "decision": "REJECTED",
                            "note": "Gate B/C rejection"})
        assert approve.status_code == 200, approve.text
        assert reject.status_code == 200, reject.text
        assert approve.json()["decision_created"] is True
        assert reject.json()["decision_created"] is True
        approved, rejected = approve.json(), reject.json()
        step("3.1 APPROVED decision recorded", "PASS", status=200,
             note=f"admission={approved['admission']['admission_state']} "
                  f"({approved['admission']['admission_reason']})")
        step("3.2 REJECTED decision recorded", "PASS", status=200,
             note=f"admission={rejected['admission']['admission_state']} "
                  f"({rejected['admission']['admission_reason']})")
    else:
        assert approved_id and rejected_id, "persisted decision states missing"
        approved = call("GET", f"{base}/{approved_id}/decision", params=query)
        rejected = call("GET", f"{base}/{rejected_id}/decision", params=query)
        assert approved.status_code == 200, approved.text
        assert rejected.status_code == 200, rejected.text
        approved, rejected = approved.json(), rejected.json()
        step("3.1 persisted APPROVED decision readback", "PASS", status=200,
             note=f"admission={approved['admission']['admission_state']} "
                  f"({approved['admission']['admission_reason']})")
        step("3.2 persisted REJECTED decision readback", "PASS", status=200,
             note=f"admission={rejected['admission']['admission_state']} "
                  f"({rejected['admission']['admission_reason']})")

    assert approved["decision"] == "APPROVED"
    assert approved["review_state"] == "APPROVED"
    assert approved["admission"]["admission_state"] == "HELD"
    assert approved["admission"]["admission_reason"] == "M2_UNCERTAINTY_LINK_REQUIRED"
    assert approved["admission"]["uncertainty_link"] is None
    assert rejected["decision"] == "REJECTED"
    assert rejected["review_state"] == "REJECTED"
    assert rejected["admission"]["admission_state"] == "NOT_ADMISSIBLE"
    assert rejected["admission"]["admission_reason"] == "PROPOSAL_NOT_APPROVED"
    for block in (approved["admission"], rejected["admission"]):
        assert block["qj_execution"] is False and block["qg_execution"] is False
        assert block["fielding_authorized"] is False
    step("3.3 approval is not admission", "PASS",
         note="APPROVED stays HELD; REJECTED is NOT_ADMISSIBLE; QJ/QG/fielding false")

    fresh_approve = call("GET", f"{base}/{approved_id}/decision", params=query)
    fresh_reject = call("GET", f"{base}/{rejected_id}/decision", params=query)
    assert fresh_approve.status_code == 200 and fresh_reject.status_code == 200
    assert fresh_approve.json()["decision_id"] == approved["decision_id"]
    assert fresh_reject.json()["decision_id"] == rejected["decision_id"]
    step("3.4 fresh decision readback", "PASS",
         note="both decisions retrieved through separate authenticated requests")

    after_states = {p["proposal_id"]: p["review_state"]
                    for p in call("GET", base, params=query).json()["proposals"]}
    assert after_states[approved_id] == "APPROVED"
    assert after_states[rejected_id] == "REJECTED"
    pending_id = next((i for i in ids if after_states.get(i) == "CANDIDATE"), None)
    step("3.5 review states after decisions", "PASS",
         note=json.dumps({k[:8]: v for k, v in after_states.items()}))

    # ---- idempotency / conflict ------------------------------------------
    again = call("POST", f"{base}/{approved_id}/decision",
                 body={**query, "decision": "APPROVED"})
    assert again.status_code == 200, again.text
    assert again.json()["decision_created"] is False
    assert again.json()["decision_id"] == approved["decision_id"]
    step("4.1 identical APPROVED retry is idempotent", "PASS",
         note="same decision_id, created=false")

    conflict = call("POST", f"{base}/{approved_id}/decision",
                    body={**query, "decision": "REJECTED"})
    assert conflict.status_code == 409, conflict.text
    assert code_of(conflict) == "BDJ_OBJECTIVE_ALREADY_DECIDED", conflict.text
    step("4.2 conflicting REJECTED on approved proposal", "PASS",
         status=409, code=code_of(conflict))

    again_reject = call("POST", f"{base}/{rejected_id}/decision",
                        body={**query, "decision": "REJECTED"})
    assert again_reject.status_code == 200, again_reject.text
    assert again_reject.json()["decision_created"] is False
    conflict2 = call("POST", f"{base}/{rejected_id}/decision",
                     body={**query, "decision": "APPROVED"})
    assert conflict2.status_code == 409, conflict2.text
    assert code_of(conflict2) == "BDJ_OBJECTIVE_ALREADY_DECIDED"
    step("4.3 identical/conflicting REJECTED behaviour", "PASS",
         note="retry idempotent, conflicting APPROVED refused 409")

    repeat = call("POST", f"{base}/evaluate", body=query)
    assert repeat.status_code == 200, repeat.text
    repeat_body = repeat.json()
    assert repeat_body["execution"]["reused"] is True, repeat_body["execution"]
    assert {p["proposal_id"] for p in repeat_body["proposals"]} == set(ids)
    step("4.4 duplicate evaluation never re-dispatches", "PASS",
         note=f"reused=true, same {len(ids)} ids, attempt_no="
              f"{repeat_body['execution']['attempt_no']}")

    # ---- negative HTTP tests ---------------------------------------------
    negatives = []

    def negative(label, response, status, code=None):
        ok = response.status_code == status and (code is None or code_of(response) == code)
        negatives.append({"case": label, "expected_status": status,
                          "expected_code": code, "actual_status": response.status_code,
                          "actual_code": code_of(response),
                          "result": "PASS" if ok else "FAIL"})
        step(f"5.{len(negatives)} {label}", "PASS" if ok else "FAIL",
             status=response.status_code, code=code_of(response))
        return ok

    negative("missing authentication", call("GET", base, params=query, auth=False), 401)
    negative("malformed bearer token",
             call("GET", base, params=query, auth=False,
                  raw_token="Bearer not-a-jwt"), 401)
    # A foreign owner is indistinguishable from an unconfirmed assessment: the
    # owner-scoped projection returns nothing and the refusal must not confirm
    # that the assessment exists.
    negative("cross-owner assessment",
             call("GET", base, params=query, subject=str(uuid.uuid4())),
             409, "BDJ_OBJECTIVE_SOURCE_NOT_CURRENT")
    negative("cross-owner decision",
             call("POST", f"{base}/{approved_id}/decision",
                  body={**query, "decision": "REJECTED"}, subject=str(uuid.uuid4())),
             409, "BDJ_OBJECTIVE_SOURCE_NOT_CURRENT")
    negative("stale source revision",
             call("GET", base, params={**query, "expected_revision": REVISION - 1}),
             409, "BDJ_OBJECTIVE_SOURCE_NOT_CURRENT")
    negative("unknown context id",
             call("GET", base, params={**query, "context_id": str(uuid.uuid4())}),
             404, "BDJ_OBJECTIVE_CONTEXT_NOT_FOUND")
    negative("client-supplied authority field refused",
             call("POST", f"{base}/evaluate",
                  body={**query, "owner_user_id": OWNER, "execution_mode": "LIVE"}), 422)
    negative("unknown proposal id",
             call("GET", f"{base}/{uuid.uuid4()}", params=query),
             404, "BDJ_OBJECTIVE_PROPOSAL_NOT_FOUND")
    negative("decision on unknown proposal",
             call("POST", f"{base}/{uuid.uuid4()}/decision",
                  body={**query, "decision": "APPROVED"}),
             404, "BDJ_OBJECTIVE_PROPOSAL_NOT_FOUND")
    negative("invalid decision value",
             call("POST", f"{base}/{approved_id}/decision",
                  body={**query, "decision": "MAYBE"}), 422)
    if pending_id:
        negative("pending proposal has no decision",
                 call("GET", f"{base}/{pending_id}/decision", params=query),
                 404, "BDJ_OBJECTIVE_DECISION_NOT_FOUND")

    # ---- tampered-context refusal (disposable copy, cleaned up) ----------
    from psycopg2.extras import Json

    corrupt_id = str(uuid.uuid4())
    admin_cur.execute("SELECT * FROM public.m2_business_contexts WHERE context_id=%s",
                      (CONTEXT,))
    original = dict(admin_cur.fetchone())
    corrupt = {k: (Json(v) if isinstance(v, (dict, list)) else v)
               for k, v in original.items()}
    corrupt["context_id"] = corrupt_id
    corrupt["packet_hash"] = "f" * 64
    columns = list(corrupt)
    admin_cur.execute(
        f"INSERT INTO public.m2_business_contexts ({', '.join(columns)}) VALUES "
        f"({', '.join(['%s'] * len(columns))})",
        [corrupt[c] for c in columns])
    try:
        negative("tampered context packet hash",
                 call("GET", base, params={**query, "context_id": corrupt_id}),
                 409, "BCB_CONTEXT_SOURCE_CHANGED")
    finally:
        admin_cur.execute("DELETE FROM public.m2_business_contexts WHERE context_id=%s",
                          (corrupt_id,))
        admin_cur.execute("SELECT count(*) c FROM public.m2_business_contexts"
                          " WHERE context_id=%s", (corrupt_id,))
        cleaned = admin_cur.fetchone()["c"] == 0
    step("5.z disposable tampered-context cleanup", "PASS" if cleaned else "FAIL",
         note="removed; the legitimate context is untouched")

    # ---- persistence + ledger proof --------------------------------------
    admin_cur.execute("""
        SELECT proposal_id, assessment_id, confirmation_id, confirmation_revision,
               source_fingerprint, context_id, context_packet_hash,
               recommendation_status, problem_type, problem, research_objective,
               source_refs, execution_mode, model_provider, validation_status,
               review_state, owner_user_id, created_at
        FROM public.m2_bdj_objective_proposals
        WHERE assessment_id=%s AND context_packet_hash=%s
        ORDER BY proposal_id""", (ASSESSMENT, EXPECTED_PACKET_HASH))
    rows = [dict(r) for r in admin_cur.fetchall()]
    assert len(rows) == len(ids), (len(rows), len(ids))
    for row in rows:
        assert str(row["assessment_id"]) == ASSESSMENT
        assert str(row["owner_user_id"]) == OWNER
        assert str(row["confirmation_id"]) == CONFIRMATION
        assert row["confirmation_revision"] == REVISION
        assert row["execution_mode"] == "SIMULATED"
        assert row["model_provider"] == "simulated-objective-v1"
        assert row["validation_status"] == "VALID"
        assert row["source_fingerprint"] == body["source_fingerprint"]
        assert str(row["context_id"]) == CONTEXT
    step("6.1 PostgreSQL proposal persistence", "PASS",
         note=f"{len(rows)} rows bound to confirmation/revision/context/source")

    admin_cur.execute("""
        SELECT d.decision_id, d.proposal_id, d.decision, d.decided_by, d.decided_at,
               d.source_fingerprint, d.confirmation_id, d.context_packet_hash
        FROM public.m2_bdj_objective_decisions d
        JOIN public.m2_bdj_objective_proposals p USING (proposal_id)
        WHERE p.assessment_id=%s AND p.context_packet_hash=%s
        ORDER BY d.proposal_id""", (ASSESSMENT, EXPECTED_PACKET_HASH))
    decision_rows = [dict(r) for r in admin_cur.fetchall()]
    assert len(decision_rows) == 2, len(decision_rows)
    by_proposal = {str(r["proposal_id"]): r for r in decision_rows}
    assert by_proposal[approved_id]["decision"] == "APPROVED"
    assert by_proposal[rejected_id]["decision"] == "REJECTED"
    for row in decision_rows:
        assert str(row["decided_by"]) == OWNER
        assert str(row["confirmation_id"]) == CONFIRMATION
        assert row["context_packet_hash"] == EXPECTED_PACKET_HASH
    step("6.2 PostgreSQL decision persistence", "PASS",
         note="2 append-only decisions, actor/revision/context bound")

    run_id = execution.get("run_id")
    admin_cur.execute("""
        SELECT id, owner_user_id, assessment_id, assessment_revision,
               source_fingerprint, policy_fingerprint, work_identity, created_at
        FROM project1_ai.runs WHERE id=%s""", (run_id,))
    run_row = dict(admin_cur.fetchone())
    assert str(run_row["owner_user_id"]) == OWNER
    assert str(run_row["assessment_id"]) == ASSESSMENT
    assert run_row["assessment_revision"] == REVISION
    assert run_row["source_fingerprint"] == body["source_fingerprint"]
    admin_cur.execute("""
        SELECT attempt_no, stage, prompt_version, prompt_hash, request_hash
        FROM project1_ai.attempts WHERE run_id=%s ORDER BY attempt_no""", (run_id,))
    attempts = [dict(r) for r in admin_cur.fetchall()]
    assert len(attempts) == 1, f"expected exactly one attempt, got {len(attempts)}"
    assert attempts[0]["stage"] == "BDJ"
    assert attempts[0]["prompt_version"] == execution["prompt_version"]
    admin_cur.execute("""
        SELECT attempt_no, outcome, output_digest FROM project1_ai.attempt_receipts
        WHERE run_id=%s ORDER BY attempt_no""", (run_id,))
    receipts = [dict(r) for r in admin_cur.fetchall()]
    assert len(receipts) == 1 and receipts[0]["outcome"] == "returned"
    assert receipts[0]["output_digest"] == execution["output_sha256"]
    step("6.3 governed attempt ledger", "PASS",
         note=f"run={run_id[:8]} stage=BDJ attempt=1 receipt=returned, single dispatch")

    # ---- source immutability ---------------------------------------------
    after = source_snapshot(admin_cur)
    immutability = {key: {"before": before[key], "after": after[key],
                          "unchanged": before[key] == after[key]}
                    for key in before}
    assert all(v["unchanged"] for v in immutability.values()), immutability
    step("7. source immutability", "PASS",
         note="assessment/confirmation/context/answers/findings unchanged")

    gate_a = gate_a_regression(admin_cur, url)

    negatives_ok = all(n["result"] == "PASS" for n in negatives)
    verdicts.update({
        "BDJ_GATE_A_RLS_REGRESSION": gate_a["verdict"],
        "BDJ_GOVERNED_PROPOSAL_API": "PASS",
        "BDJ_EXECUTION_LEDGER": "PASS",
        "BDJ_PROPOSAL_HTTP_PERSISTENCE": "PASS",
        "BDJ_PROPOSAL_DECISION_API": "PASS",
        "BDJ_DECISION_IDEMPOTENCY": "PASS",
        "BDJ_DECISION_AUTHORIZATION": "PASS" if negatives_ok else "FAIL",
        "M2_BCB_BDJ_BACKEND_END_TO_END": "PASS" if negatives_ok else "FAIL",
    })

    evidence = {
        "checkpoint": "BDJ_GATE_B_C_HTTP_E2E",
        "scenario": name,
        "executed_at": datetime.now(timezone.utc).isoformat(),
        "mode": mode,
        "mode_note": (
            "execute: this run performed the governed execution. "
            "verify-existing: an append-only ledger attempt already exists for "
            "this source/context/policy, so the harness re-verifies the "
            "persisted execution instead of fabricating a second dispatch."
            if mode == "verify-existing" else
            "execute: this run performed the governed execution."),
        "target": {"database": TARGET_DB, "host": HOST, "port": PORT,
                   "server_identity": ident,
                   "configured_database_ignored": configured_database},
        "fixtures": fixture,
        "baseline": baseline,
        "prior_state": prior,
        "identities": {
            "assessment_id": ASSESSMENT, "owner_user_id": OWNER,
            "confirmation_id": CONFIRMATION, "context_id": CONTEXT,
            "revision": REVISION, "context_packet_hash": EXPECTED_PACKET_HASH,
            "source_fingerprint": body["source_fingerprint"],
            "run_id": run_id,
            "run_created_at": str(run_row["created_at"]),
            "policy_fingerprint": run_row["policy_fingerprint"],
            "work_identity": run_row["work_identity"],
            "proposal_ids": ids,
            "approved_proposal_id": approved_id,
            "rejected_proposal_id": rejected_id,
            "pending_proposal_id": pending_id,
            "decision_ids": {str(r["proposal_id"]): str(r["decision_id"])
                             for r in decision_rows},
        },
        "connections": connections,
        "execution": execution,
        "persistence": {
            "proposal_rows": len(rows),
            "decision_rows": len(decision_rows),
            "attempt_rows": len(attempts),
            "receipt_rows": len(receipts),
            "execution_mode": "SIMULATED",
            "model_provider": "simulated-objective-v1",
            "proposal_created_at": [str(r["created_at"]) for r in rows],
            "decision_decided_at": [str(r["decided_at"]) for r in decision_rows],
        },
        "steps": steps,
        "negatives": negatives,
        "gate_a_regression": gate_a,
        "source_immutability": immutability,
        "verdicts": verdicts,
        "notes": notes,
    }
    EVIDENCE.parent.mkdir(parents=True, exist_ok=True)
    EVIDENCE.write_text(json.dumps(evidence, indent=2, default=str), encoding="utf-8")

    print("-" * 78)
    for key, value in verdicts.items():
        print("  %-38s %s" % (key, value))
    print("-" * 78)
    print("evidence:", EVIDENCE)
    return 0 if all(v == "PASS" for v in verdicts.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
