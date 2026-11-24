"""N04-C §5-§7 — issue ONE assessment-bound authorization, then dispatch at most
one real TokenHarbour QG attempt through the governed adapter.

Design rules this tool obeys
----------------------------
* Every identifier is read from an authoritative record. Nothing is invented.
* The on-disk artifact is written to a NEW path; the historical artifact is left
  untouched, so no historical authorization is edited to match.
* ``TOKENHARBOR_ENABLED`` is set in this process only. No config file changes.
* The authorization is inserted once. A second run finds it and refuses.
* A provider failure is reported as a failure. No simulated substitute.
"""
from __future__ import annotations

import json
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Enable the provider for THIS process only, before settings are imported.
os.environ['TOKENHARBOR_ENABLED'] = 'true'

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))

import psycopg2  # noqa: E402
from sqlalchemy import create_engine, text  # noqa: E402

from sitewise.project1 import measurement_library as ml  # noqa: E402
from sitewise.project1.disclosure import QG_PURPOSE  # noqa: E402
from sitewise.project1.objective_admission import admission_state  # noqa: E402
from sitewise.project1.objective_registry import get as objective_get  # noqa: E402
from sitewise.project1.prompts import PROMPTS  # noqa: E402
from sitewise.project1.qg_candidate_adapter import (  # noqa: E402
    LIVE_SCOPE, QgCandidateAdapter, facts_from_objective,
)
from sitewise.project1.qg_live import QgLiveRunner  # noqa: E402
from sitewise.project1.qg_live_candidate import live_fixed_option_generator  # noqa: E402

DSN = "host=127.0.0.1 port=5433 dbname=project1_workflow_tests user=postgres password=123456"
M2_URL = ("postgresql+psycopg2://p1_m2_runtime:m2_runtime_dev_only"
          "@127.0.0.1:5433/project1_workflow_tests")
# The attempt ledger and run registry live in project1_ai and require the
# restricted execution principal. The M2 role cannot reach them, and a refusal
# there happens before any budget slot or socket is opened.
RUNTIME_URL = ("postgresql+psycopg2://p1ai_engine:p1ai_engine_dev_only"
               "@127.0.0.1:5433/project1_workflow_tests")

ASSESSMENT = "053b3768-145b-4d4a-a880-e98174adcd94"
PROPOSAL = "662b8518-89a2-56a5-940f-5d44adcc86d4"
ADMISSION = "ea8d9d6b-70b6-4bfc-b882-a0fa95a6e97e"
CONTEXT = "fa3cb714-5145-57e9-97cd-0af92da80f46"
ACTOR = "b9e62014-b7bc-426e-a950-a95b25965639"
OBJECTIVE = "O1"
SCOPE = 'LIVE_PROVIDER_CANDIDATE_TEST'
COST_CEILING_USD = 0.50          # nonzero, bounded, one small call
ARTIFACT = BACKEND / 'var' / 'n04c_qg_authorization.json'


def binding_set(engine) -> dict:
    """Read every binding from the record that owns it."""
    with psycopg2.connect(DSN) as conn, conn.cursor() as cur:
        cur.execute("select source_fingerprint from m2_bdj_objective_proposals "
                    "where proposal_id=%s", (PROPOSAL,))
        source_fp = cur.fetchone()[0]
        cur.execute("select context_packet_hash, confirmation_id, "
                    "confirmation_revision, policy_version "
                    "from m2_bdj_objective_admissions where admission_id=%s",
                    (ADMISSION,))
        packet_hash, confirmation_id, revision, policy_version = cur.fetchone()
        cur.execute("select packet_json from m2_business_contexts where context_id=%s",
                    (CONTEXT,))
        packet = cur.fetchone()[0]

    objective = objective_get(OBJECTIVE)
    facts = facts_from_objective(packet, objective_id=OBJECTIVE,
                                 objective_text=objective.construct,
                                 admission_id=ADMISSION)
    store = ml.PostgresMeasurementStore(engine, ACTOR)
    measurement = ml.resolve(store, OBJECTIVE,
                             stimulus={'concept_name': 'Slow Bar'},
                             supported_formats=ml.CANDIDATE_FORMATS,
                             allow_synthetic_test_approval=True)
    state = admission_state(engine, PROPOSAL, source_fingerprint=source_fp,
                            actor_id=ACTOR)
    prompt = PROMPTS['QG_FIXED_OPTION']
    return {
        'assessment_id': ASSESSMENT,
        'confirmation_id': confirmation_id,
        'assessment_revision': revision,
        'source_fingerprint': source_fp,
        'context_id': CONTEXT,
        'context_packet_hash': packet_hash,
        'objective_id': OBJECTIVE,
        'objective_admission_id': state.get('admission_id') or ADMISSION,
        'measurement': measurement,
        'admission': state,
        'prompt': prompt,
        'facts': facts,
        'packet': packet,
        'objective_text': objective.construct,
        'policy_version': policy_version,
    }


def authorization_id_for(b: dict) -> str:
    """Deterministic, so a re-run cannot mint a second authorization."""
    return str(uuid.uuid5(uuid.NAMESPACE_URL, '|'.join([
        'n04c-qg-auth', b['assessment_id'], b['context_packet_hash'],
        b['objective_admission_id'], b['measurement']['measurement_id'],
        b['measurement']['measurement_version'], b['prompt'].version,
        b['prompt'].fingerprint])))


def issue(engine, b: dict, authorization_id: str) -> dict:
    """Insert the authorization once, or report the existing row."""
    prompt = b['prompt']
    expires = datetime.now(timezone.utc) + timedelta(hours=24)
    from sitewise.repositories.m2_context_bindings import bind_restricted_principal
    with engine.begin() as conn:
        bind_restricted_principal(conn, ACTOR)
        existing = conn.execute(text(
            "SELECT authorization_id, consumed_at, expires_at "
            "FROM public.m2_qg_authorizations WHERE authorization_id=:id"),
            {'id': authorization_id}).mappings().one_or_none()
        if existing is not None:
            return {'created': False, **dict(existing)}
        conn.execute(text("""
            INSERT INTO public.m2_qg_authorizations (
                authorization_id, assessment_id, confirmation_id,
                assessment_revision, source_fingerprint, context_id,
                context_packet_hash, objective_id, objective_admission_id,
                measurement_id, measurement_version, prompt_version,
                prompt_sha256, issued_by, issued_at, expires_at, request_id)
            VALUES (
                :id, :assessment, :confirmation, :revision, :source, :context,
                :context_hash, :objective, :admission, :measurement,
                :measurement_version, :prompt_version, :prompt_sha, :issued_by,
                :issued_at, :expires_at, :request)
        """), {
            'id': authorization_id, 'assessment': b['assessment_id'],
            'confirmation': b['confirmation_id'],
            'revision': b['assessment_revision'],
            'source': b['source_fingerprint'], 'context': b['context_id'],
            'context_hash': b['context_packet_hash'],
            'objective': b['objective_id'],
            'admission': b['objective_admission_id'],
            'measurement': b['measurement']['measurement_id'],
            'measurement_version': b['measurement']['measurement_version'],
            'prompt_version': prompt.version, 'prompt_sha': prompt.fingerprint,
            'issued_by': ACTOR,
            'issued_at': datetime.now(timezone.utc), 'expires_at': expires,
            'request': str(uuid.uuid4()),
        })
    return {'created': True, 'authorization_id': authorization_id,
            'consumed_at': None, 'expires_at': expires}


def write_artifact(b: dict) -> dict:
    """A NEW artifact. The historical one is not touched."""
    payload = {
        'purpose': QG_PURPOSE,
        'source_fingerprint': b['facts'].fingerprint,
        'operator_receipt': 'N04C-OWNER-AUTHORIZED-SYNTHETIC-LIVE-TEST',
        'assessment_id': b['assessment_id'],
        'actor_id': ACTOR,
        'max_attempts': 1,
        'evaluation_id': 'N04C-QG-LIVE-1',
        'prompt_version': b['prompt'].version,
        'prompt_sha256': b['prompt'].fingerprint,
        'cost_ceiling_usd': COST_CEILING_USD,
        'scope': SCOPE,
        'issued_at': datetime.now(timezone.utc).isoformat(),
    }
    ARTIFACT.write_text(json.dumps(payload, indent=2), encoding='utf-8')
    return payload


def main() -> int:
    engine = create_engine(M2_URL)
    b = binding_set(engine)

    print("=== binding set (all from authoritative records) ===")
    for key in ('assessment_id', 'confirmation_id', 'assessment_revision',
                'source_fingerprint', 'context_id', 'context_packet_hash',
                'objective_id', 'objective_admission_id'):
        print(f"  {key:24} {b[key]}")
    print(f"  {'measurement':24} {b['measurement']['measurement_id']}"
          f"@{b['measurement']['measurement_version']}")
    print(f"  {'measurement outcome':24} {b['measurement']['outcome']}")
    print(f"  {'admission_state':24} {b['admission']['admission_state']}")
    print(f"  {'prompt_version':24} {b['prompt'].version}")
    print(f"  {'prompt_sha256':24} {b['prompt'].fingerprint}")
    print(f"  {'facts.fingerprint':24} {b['facts'].fingerprint}")

    authorization_id = authorization_id_for(b)
    issued = issue(engine, b, authorization_id)
    print(f"\n=== authorization ===")
    print(f"  authorization_id         {authorization_id}")
    print(f"  created                  {issued['created']}")
    if not issued['created'] and issued.get('consumed_at'):
        print("  REFUSING: this authorization is already consumed.")
        return 2

    artifact = write_artifact(b)
    print(f"  artifact                 {ARTIFACT}")
    print(f"  cost_ceiling_usd         {artifact['cost_ceiling_usd']}")
    print(f"  max_attempts             {artifact['max_attempts']}")

    runtime_engine = create_engine(RUNTIME_URL)
    runner = QgLiveRunner(engine=runtime_engine, authorization_path=ARTIFACT)
    generate = live_fixed_option_generator(runner, policy_version=b['policy_version'])
    adapter = QgCandidateAdapter(engine=engine, actor_id=ACTOR,
                                 store=ml.PostgresMeasurementStore(engine, ACTOR),
                                 admission_lookup=lambda proposal_id, fingerprint:
                                     admission_state(engine, proposal_id,
                                                     source_fingerprint=fingerprint,
                                                     actor_id=ACTOR),
                                 generate=generate, scope=LIVE_SCOPE)

    if '--dry-run' in sys.argv:
        print("\n=== dry run: authorization and artifact prepared, nothing dispatched ===")
        print(f"  adapter scope            {adapter.scope}")
        print(f"  adapter execution_mode   {adapter.execution_mode}")
        print(f"  provider                 {type(runner.provider).__name__}")
        print(f"  provider enabled         {runner.provider.enabled}")
        print(f"  dispatch_calls           {adapter.dispatch_calls}")
        engine.dispose()
        runtime_engine.dispose()
        return 0

    print("\n=== dispatch (exactly one attempt) ===")
    try:
        envelope = adapter.prepare(
            assessment_id=b['assessment_id'],
            confirmation_id=b['confirmation_id'],
            assessment_revision=b['assessment_revision'],
            source_fingerprint=b['source_fingerprint'],
            context_id=b['context_id'],
            context_packet_hash=b['context_packet_hash'],
            objective_id=b['objective_id'],
            objective_text=b['objective_text'],
            proposal_id=PROPOSAL,
            packet=b['packet'],
            stimulus={'concept_name': 'Slow Bar'},
            authorization_id=authorization_id,
            prompt_version=b['prompt'].version,
            prompt_sha256=b['prompt'].fingerprint,
            population=b['measurement']['population'],
        )
    except Exception as exc:  # noqa: BLE001 - report the genuine outcome
        print(f"  DISPATCH REFUSED/FAILED: {type(exc).__name__}: {exc}")
        engine.dispose()
        return 3

    for key in ('outcome', 'dispatched', 'candidate_id', 'candidate_state',
                'candidate_persisted', 'authorization_consumed', 'output_sha256',
                'response_format'):
        print(f"  {key:24} {envelope.get(key)}")
    print(f"  {'execution':24} {json.dumps(envelope.get('execution'), indent=2)}")
    print(f"  {'question':24} {envelope.get('question')}")
    print(f"  {'response_codes':24} {envelope.get('response_codes')}")
    engine.dispose()
    return 0 if envelope.get('dispatched') else 4


if __name__ == "__main__":
    raise SystemExit(main())
