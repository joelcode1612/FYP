"""One controlled live TokenHarbor dispatch, behind an explicit two-key gate.

This script is the only place in the repository that can make a paid provider
call outside the HTTP route. It is deliberately hard to run by accident:

  * it refuses unless `--dispatch` is passed AND `--confirm` equals the value of
    the `CP04A_LIVE_DISPATCH_APPROVAL` environment variable, which must be set
    for that one invocation;
  * it re-checks every configuration gate and prints them before dispatching;
  * it refuses to touch `Dss` — the database name is forced to the clone;
  * it sends a packet marked `SYNTHETIC_NONHUMAN`, built from literal values in
    this file, so no entrepreneur answer leaves the machine;
  * it makes exactly one attempt. `ModelRunner` reserves the attempt before
    dispatch and `TokenHarbor` never repeats a POST.

Usage:
    # inspect the gates only; never dispatches
    python scripts/cp04a_live_dispatch_probe.py --check

    # the paid call (requires your approval token in the environment)
    CP04A_LIVE_DISPATCH_APPROVAL=<token> python scripts/cp04a_live_dispatch_probe.py \
        --dispatch --confirm <token>

A successful response is a *candidate*. It is not an authorised BDJ finding, not
workflow acceptance and not scientific approval. The script prints the persisted
row's `finding_authority` to make that visible.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from uuid import uuid4

from sqlalchemy.engine import make_url

CLONE = 'project1_workflow_tests'
ENV_PATH = Path(__file__).resolve().parents[1] / '.env'

# Literal synthetic declarations. Nothing here is copied from a real assessment.
SYNTHETIC_DECLARATIONS = [
    {'item_key': 'M2-04', 'question': 'Describe the service format.',
     'item_version_id': 'probe-04-v1', 'definition_digest': '1' * 64,
     'answer_revision_id': 'probe-04-r1', 'answer_revision': 1,
     'answer_state': 'ANSWERED', 'value': 'PROBE-TAKEAWAY-ONLY',
     'trust_class': 'ENTREPRENEUR_DECLARED'},
    {'item_key': 'M2-05', 'question': 'Select the service format.',
     'item_version_id': 'probe-05-v1', 'definition_digest': '2' * 64,
     'answer_revision_id': 'probe-05-r1', 'answer_revision': 1,
     'answer_state': 'ANSWERED', 'value': 'PROBE_DINE_IN',
     'trust_class': 'ENTREPRENEUR_DECLARED'},
]

REQUIRED_ENV = (
    'TOKENHARBOR_API_KEY', 'TOKENHARBOR_ENABLED', 'PROJECT1_WORKFLOW_ENABLED',
    'PROJECT1_RULES_VERSION', 'PROJECT1_RULES_SHA256', 'PROJECT1_RULES_ADOPTION_RECEIPT',
)


def read_env() -> dict[str, str]:
    if not ENV_PATH.is_file():
        sys.exit(f'probe: {ENV_PATH} not found')
    values = {}
    for line in ENV_PATH.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, _, value = line.partition('=')
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def effective_env() -> dict[str, str]:
    """The values the application will actually see.

    `Settings` reads `.env` relative to the working directory, so a gate that
    parses the file directly can pass while the app loads defaults. Publishing
    the merged view into the process environment removes that divergence:
    process env wins over `env_file` in pydantic-settings, so what is gated is
    what is loaded, from any working directory.
    """
    merged = read_env()
    for key in list(merged):
        if key in os.environ:
            merged[key] = os.environ[key]
        else:
            os.environ[key] = merged[key]
    return merged


def clone_url(raw: str) -> str:
    rewritten, count = re.subn(r'(postgresql(?:\+\w+)?://[^:]+:[^@]+@[^:/]+:\d+)/[^?]+',
                               rf'\1/{CLONE}', raw)
    if count != 1:
        sys.exit('probe: could not rewrite a database URL to the clone')
    return rewritten


def gates(env: dict[str, str], packet: dict) -> list[tuple[str, bool, str]]:
    """Every condition between this script and a real dispatch.

    Each gate is measured, never asserted. G7 reads the packet this run will
    actually send; G8 reads the database name the runtime URL will actually
    resolve to after rewriting, so a mislabelled gate cannot pass by accident.
    """
    truthy = {'1', 'true', 'yes', 'on'}
    key = env.get('TOKENHARBOR_API_KEY', '')
    version = env.get('PROJECT1_RULES_VERSION', '')
    sha = env.get('PROJECT1_RULES_SHA256', '')
    receipt = env.get('PROJECT1_RULES_ADOPTION_RECEIPT', '')
    runtime = env.get('PROJECT1_RUNTIME_DATABASE_URL', '')
    try:
        resolved_db = make_url(clone_url(runtime)).database if runtime else None
    except Exception:                                           # noqa: BLE001 — reported as a gate
        resolved_db = None
    return [
        ('G1 PROJECT1_WORKFLOW_ENABLED', env.get('PROJECT1_WORKFLOW_ENABLED', '').lower() in truthy,
         'not set or false'),
        ('G5 TOKENHARBOR_ENABLED', env.get('TOKENHARBOR_ENABLED', '').lower() in truthy,
         'not set or false'),
        ('G5b TOKENHARBOR_API_KEY', bool(key), 'empty'),
        ('G6a PROJECT1_RULES_VERSION', bool(version), 'empty'),
        ('G6b PROJECT1_RULES_SHA256', bool(re.fullmatch(r'[a-f0-9]{64}', sha)), 'not a 64-hex digest'),
        ('G6c PROJECT1_RULES_ADOPTION_RECEIPT', bool(receipt), 'empty'),
        ('G7 packet is synthetic',
         packet.get('data_class') == 'SYNTHETIC_NONHUMAN'
         and packet.get('purpose') == 'SYNTHETIC_BDJ_DIAGNOSTIC',
         'packet would not be refused as real data'),
        ('G8 resolved runtime database is the clone', resolved_db == CLONE,
         f'PROJECT1_RUNTIME_DATABASE_URL resolves to {resolved_db!r}, not {CLONE!r}'),
        ('G9 DATABASE_URL present for the admin fixture rows', bool(env.get('DATABASE_URL')),
         'unset'),
    ]


def print_gates(rows) -> bool:
    ok = True
    for name, passed, why in rows:
        print(f'  {"PASS" if passed else "FAIL"}  {name}' + ('' if passed else f'  ({why})'))
        ok = ok and passed
    return ok


def build_packet():
    from sitewise.project1.contracts import digest
    content = {
        'schema_version': 'project1-m2-projection/1-candidate',
        'assessment_id': str(uuid4()),
        'assessment_revision': 1,
        'instrument_id': str(uuid4()),
        'instrument_version': 'PROBE-SYNTHETIC-1',
        'instrument_digest': '0' * 64,
        'declarations': SYNTHETIC_DECLARATIONS,
        'governance_items': [],
        'excluded_items': {},
        'confirmed': True,
        'facts_independently_verified': False,
        'data_class': 'SYNTHETIC_NONHUMAN',
        'purpose': 'SYNTHETIC_BDJ_DIAGNOSTIC',
    }
    return {**content, 'source_fingerprint': digest(content)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--check', action='store_true', help='print gates only')
    parser.add_argument('--dispatch', action='store_true', help='make the one paid call')
    parser.add_argument('--confirm', default='', help='must equal CP04A_LIVE_DISPATCH_APPROVAL')
    args = parser.parse_args()

    if not (args.check or args.dispatch):
        parser.error('choose --check or --dispatch')

    env = effective_env()
    packet = build_packet()
    print('Gate status:')
    passed = print_gates(gates(env, packet))
    print(f'\nOverall: {"READY" if passed else "NOT READY"}')

    if args.check or not passed:
        if args.dispatch and not passed:
            print('\nRefusing to dispatch: a gate is unmet. No provider call was made.')
        return 0 if passed else 1

    approval = os.environ.get('CP04A_LIVE_DISPATCH_APPROVAL', '')
    if not approval or args.confirm != approval:
        print('\nRefusing to dispatch: --confirm must equal CP04A_LIVE_DISPATCH_APPROVAL.')
        print('No provider call was made.')
        return 2

    # Import after the gates so a misconfigured environment cannot half-load.
    from sqlalchemy import create_engine, text
    from sqlalchemy.orm import Session

    from sitewise.project1.model_assisted import run_model_assisted
    from sitewise.project1.provider import configured_runner

    admin = create_engine(clone_url(env['DATABASE_URL']), hide_parameters=True)
    runtime = create_engine(clone_url(env['PROJECT1_RUNTIME_DATABASE_URL']),
                            hide_parameters=True)
    actor, instrument, assessment = uuid4(), uuid4(), packet['assessment_id']

    with admin.begin() as conn:
        conn.execute(text(
            "INSERT INTO public.users(user_id,email,role,account_status,email_verified,"
            "created_at,updated_at) VALUES (:id,:email,'entrepreneur','active',true,now(),now())"),
            {'id': actor, 'email': f'cp04a.probe.{actor.hex}@example.test'})
        conn.execute(text(
            "INSERT INTO public.m2_instrument_versions(id,code,version_tag,approval_state,"
            "schema_digest) VALUES (:id,:code,'PROBE-V1','AUTHORIZED',:h)"),
            {'id': instrument, 'code': 'PROBE-' + instrument.hex[:12], 'h': 'b' * 64})
        conn.execute(text(
            'INSERT INTO public.m2_assessments(id,owner_user_id,instrument_id,revision)'
            ' VALUES (:a,:o,:i,1)'), {'a': assessment, 'o': actor, 'i': instrument})

    print(f'\nDispatching ONE attempt as {actor} …')
    try:
        body = run_model_assisted(
            packet=packet, actor_id=actor, runtime_engine=runtime,
            runner_factory=configured_runner,
            current_fingerprint=lambda: packet['source_fingerprint'])
    except Exception as exc:                                    # noqa: BLE001 — reported verbatim
        print(f'Outcome: HELD — {type(exc).__name__}: {exc}')
        print('The attempt was recorded by the ledger before dispatch; it is not retried.')
        return 3
    finally:
        admin.dispose()
        runtime.dispose()

    print(f"Outcome: {body.get('review_outcome')} / {body.get('execution_outcome')}"
          f" / {body.get('validation_status')}")
    print(f"finding_authority: {body.get('finding_authority')}   "
          f"findings: {len(body.get('findings') or [])}")
    print('This is a CANDIDATE. It is not an authorised finding, not workflow '
          'acceptance and not scientific approval.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
