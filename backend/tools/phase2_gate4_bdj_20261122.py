"""Gate 4 re-verification — persisted BCB to BDJ source binding.

Reads only from the disposable project1_workflow_tests@localhost:5433 target.
BDJ uses a local simulated runner; no provider, DDL, or data writes occur.
The persisted BCB service and source projection are read under the restricted
M2 principal. The evidence file is dated 2026-11-22 so prior evidence remains.
"""
import hashlib
import json
import os
import re
from pathlib import Path
import uuid

BACKEND = Path(__file__).resolve().parents[1]
TARGET_DB = 'project1_workflow_tests'
TARGET_HOST = 'localhost'
PORT = 5433
ASSESSMENT = uuid.UUID('d82b78ff-dad0-41d8-afa4-0205ad199a20')
CONFIRMATION = uuid.UUID('658dfcc7-75e6-4f76-b245-71678459ba60')
REVISION = 11
CONTEXT_ID = uuid.UUID('79151dfe-c411-54d9-b03c-47b19ce44ecb')
ROLE = 'p1_m2_runtime'
ROLE_PW = os.environ.get('PHASE2_M2_ROLE_PW', 'm2_runtime_dev_only')


def install_process_environment():
    """Read the base URL, retarget only this process to the disposable clone."""
    from sqlalchemy.engine import make_url

    env_path = BACKEND / '.env'
    lines = env_path.read_text(encoding='utf-8', errors='ignore').splitlines()
    base = next((line.split('=', 1)[1].strip() for line in lines
                 if line.startswith('DATABASE_URL=')), None)
    if not base:
        raise RuntimeError('DATABASE_URL_MISSING')
    base_url = make_url(base)
    if (base_url.get_backend_name() != 'postgresql' or
            base_url.host not in {'localhost', '127.0.0.1'}):
        raise RuntimeError('DISPOSABLE_SOURCE_HOST_REFUSED')
    # Do not expose or connect to the configured original database. Derive a
    # separate local clone URL and verify its host, port, and database first.
    target_url = base_url.set(port=PORT, database=TARGET_DB)
    if (target_url.host not in {'localhost', '127.0.0.1'} or
            target_url.port != PORT or target_url.database != TARGET_DB or
            target_url.database in {'Dss', 'Final_Location_Analysis'}):
        raise RuntimeError('DISPOSABLE_TARGET_REFUSED')
    app_url = target_url.render_as_string(hide_password=False)
    host_and_database = f'{target_url.host}:{target_url.port}/{target_url.database}'
    runtime_url = target_url.set(username=ROLE, password=ROLE_PW).render_as_string(
        hide_password=False)
    os.environ['DATABASE_URL'] = app_url
    os.environ['M2_DATABASE_URL'] = runtime_url
    os.environ['M2_EXPECTED_DATABASE'] = TARGET_DB
    os.environ['PROJECT1_BCB_CONFIRMATION_VALIDITY_DAYS'] = '1'
    return app_url, runtime_url, host_and_database


APP_URL, M2_URL, TARGET_LABEL = install_process_environment()


def libpq(dsn):
    return dsn.replace('postgresql+psycopg2://', 'postgresql://', 1)


def _safe_detail(exc):
    code = getattr(exc, 'code', None)
    if isinstance(code, str) and re.fullmatch(r'[A-Z0-9_]{3,96}', code):
        return f'{type(exc).__name__}: {code}'
    text = str(exc)
    if re.fullmatch(r'[A-Z0-9_]{3,96}', text):
        return f'{type(exc).__name__}: {text}'
    if isinstance(exc, AssertionError):
        return f'AssertionError: {text[:160]}'
    return f'{type(exc).__name__}: unexpected exception (details withheld)'


def main():
    import psycopg2
    from sqlalchemy import text
    from sqlalchemy.orm import Session

    from sitewise.core.config import settings
    from sitewise.project1.bdj import BDJEngine
    from sitewise.project1.contracts import digest
    from sitewise.project1.objective_proposal import CONTRACT_VERSION
    from sitewise.project1.projection import M2SourceProjection, verify_projection
    from sitewise.project1.rules import bdj_m2v1_ig_proposal as rules
    from sitewise.repositories.business_context_repository import SqlBusinessContextStore
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    from sitewise.services.business_context_v1 import canonical_bytes, json_value, source_hash
    from sitewise.services.m2_service import M2Service
    from sitewise.services.persisted_business_context_service import PersistedBusinessContextService
    from sitewise.db.m2_session import get_bcb_engine
    from sitewise.dependencies import get_bcb_bindings_resolver_factory

    if settings.m2_expected_database != TARGET_DB:
        raise RuntimeError('M2_EXPECTED_DATABASE_MISMATCH')
    if settings.project1_bcb_confirmation_validity_days != 1:
        raise RuntimeError('TEST_VALIDITY_CONFIGURATION_MISMATCH')

    checks = []
    state = {}

    def check(label, fn):
        try:
            detail = str(fn())
            checks.append({'check': label, 'result': 'PASS', 'detail': detail})
        except Exception as exc:
            checks.append({'check': label, 'result': 'FAIL', 'detail': _safe_detail(exc)})
        print('  %-4s %-54s %s' % (
            checks[-1]['result'], label, checks[-1]['detail'][:74]))

    # This identity probe is the first SQL operation. It confirms the server
    # address and database actually accepted the disposable connection.
    admin = psycopg2.connect(libpq(APP_URL))
    admin.autocommit = True
    with admin.cursor() as cur:
        cur.execute('SELECT current_database(), inet_server_port()')
        target = cur.fetchone()
        if target != (TARGET_DB, PORT):
            admin.close()
            raise RuntimeError('DISPOSABLE_SERVER_IDENTITY_MISMATCH')
        cur.execute('SELECT owner_user_id FROM public.m2_assessments WHERE id=%s',
                    (str(ASSESSMENT),))
        owner_row = cur.fetchone()
    if owner_row is None:
        admin.close()
        raise RuntimeError('PINNED_ASSESSMENT_NOT_FOUND')
    owner = uuid.UUID(str(owner_row[0]))

    context_store = SqlBusinessContextStore(
        get_bcb_engine(), get_bcb_bindings_resolver_factory())

    def read_persisted_context_readonly():
        """Read and integrity-check the persisted row without build-table DML.

        PersistedBusinessContextService.retrieve() reauthorizes/rebuilds safely,
        but its selection helper calls ensure_build() (an INSERT ... ON CONFLICT
        inside a transaction later rolled back by the store). The Gate 4 harness
        is intended to be strictly read-only, so read the owner-scoped persisted
        row directly and use the service's integrity-only response validator.
        Currentness is established independently by the same RR transaction's
        pinned confirmation and exact M2-to-BCB field comparison below.
        """
        with context_store.open(owner) as unit:
            row = unit.read_context(CONTEXT_ID, owner)
            if row is None or row['assessment_id'] != ASSESSMENT:
                raise AssertionError('persisted context not visible to restricted owner')
            return PersistedBusinessContextService._response(row)

    def read_authoritative_state():
        """Read the M2 projection and persisted BCB under one RR M2 transaction."""
        engine = get_bcb_engine()
        with engine.connect().execution_options(isolation_level='REPEATABLE READ') as connection:
            with Session(connection, autoflush=False) as session:
                try:
                    principal = session.execute(text(
                        'SELECT session_user,current_user,current_database(),inet_server_port(),'
                        '(SELECT rolsuper FROM pg_roles WHERE rolname=current_user),'
                        '(SELECT rolbypassrls FROM pg_roles WHERE rolname=current_user)')).one()
                    if principal != (ROLE, ROLE, TARGET_DB, PORT, False, False):
                        raise AssertionError('restricted database identity mismatch')
                    session.execute(text(
                        "SELECT set_config('project1.actor_id', :actor, true)"),
                        {'actor': str(owner)})

                    stored_row = session.execute(text(
                        'SELECT context_id,assessment_id,owner_user_id,confirmation_id,'
                        'assessment_revision,packet_hash,canonical_body,schema_version '
                        'FROM public.m2_business_contexts WHERE context_id=:context'),
                        {'context': str(CONTEXT_ID)}).mappings().one_or_none()
                    if stored_row is None:
                        raise AssertionError('persisted context not visible to restricted owner')
                    stored_row = dict(stored_row)
                    if (str(stored_row['context_id']) != str(CONTEXT_ID) or
                            str(stored_row['assessment_id']) != str(ASSESSMENT) or
                            str(stored_row['owner_user_id']) != str(owner) or
                            str(stored_row['confirmation_id']) != str(CONFIRMATION) or
                            stored_row['assessment_revision'] != REVISION or
                            stored_row['schema_version'] != 'business-context-package/1.1'):
                        raise AssertionError('persisted context identity mismatch')

                    bcb_packet = json.loads(stored_row['canonical_body'])
                    bcb_packet['packet_hash'] = str(stored_row['packet_hash'])
                    if source_hash({k: v for k, v in bcb_packet.items()
                                    if k != 'packet_hash'}) != str(stored_row['packet_hash']):
                        raise AssertionError('persisted BCB canonical hash mismatch')

                    repo = SqlModelM2Repository(session)
                    # Keep the assessment lock and RR snapshot through the BCB
                    # row read and projection. These read-only use cases normally
                    # roll back in finally; the harness owns the transaction and
                    # rolls it back once, after the complete snapshot is captured.
                    original_rollback = repo.rollback
                    repo.rollback = lambda: None
                    try:
                        with M2Service(repo).locked_confirmed_source(
                                ASSESSMENT, owner, confirmation_id=CONFIRMATION,
                                expected_revision=REVISION) as confirmed:
                            if (str(confirmed['confirmation_id']) != str(CONFIRMATION) or
                                    confirmed['assessment_revision'] != REVISION or
                                    confirmed['source_status'] != 'CURRENT_CONFIRMED_SOURCE' or
                                    str(confirmed['snapshot_digest']) != str(
                                        bcb_packet['confirmation']['digest'])):
                                raise AssertionError('locked confirmation identity mismatch')
                            packet = M2SourceProjection(repo).read(
                                ASSESSMENT, owner, REVISION)
                            packet['confirmation'] = {
                                'confirmation_id': str(confirmed['confirmation_id']),
                                'snapshot_digest': str(confirmed['snapshot_digest']),
                            }
                            packet['source_fingerprint'] = digest({
                                k: v for k, v in packet.items()
                                if k != 'source_fingerprint'})
                            verify_projection(packet)
                    finally:
                        repo.rollback = original_rollback

                    answer_rows = session.execute(text(
                        'SELECT a.id,a.assessment_id,i.item_key,a.item_version_id,'
                        'a.assessment_revision,a.answer_state,a.value_json '
                        'FROM public.m2_answer_revisions a '
                        'JOIN public.m2_item_versions i ON i.id=a.item_version_id '
                        'WHERE a.assessment_id=:assessment ORDER BY a.id'),
                        {'assessment': str(ASSESSMENT)}).mappings().all()
                    if len(answer_rows) < len(packet['declarations']):
                        raise AssertionError('restricted answer snapshot is incomplete')

                    stable_snapshot = {
                        'answers': [json_value(dict(row)) for row in answer_rows],
                        'context': json_value({k: stored_row[k] for k in (
                            'context_id', 'assessment_id', 'owner_user_id',
                            'confirmation_id', 'assessment_revision', 'packet_hash',
                            'canonical_body', 'schema_version')}),
                    }
                    return {
                        'packet': packet,
                        'bcb_packet': bcb_packet,
                        'snapshot_hash': digest(stable_snapshot),
                        'answer_row_count': len(answer_rows),
                        'confirmation_id': str(confirmed['confirmation_id']),
                        'confirmation_digest': str(confirmed['snapshot_digest']),
                    }
                finally:
                    session.rollback()

    initial_context = read_persisted_context_readonly()
    initial_state = read_authoritative_state()
    packet = initial_state['packet']
    bcb_packet = initial_state['bcb_packet']
    packet_hash = str(bcb_packet['packet_hash'])
    if (initial_context.get('lifecycle_status') != 'PERSISTED' or
            str(initial_context.get('context_id')) != str(CONTEXT_ID) or
            str(initial_context.get('packet', {}).get('packet_hash')) != packet_hash or
            initial_context.get('qj_execution_authorized') is not False or
            initial_context.get('qg_execution_authorized') is not False):
        raise RuntimeError('PERSISTED_CONTEXT_RETRIEVAL_OR_ELIGIBILITY_FAILED')

    print('=' * 78)
    print('GATE 4 — persisted BCB context → BDJ proposals (2026-11-22)')
    print('=' * 78)
    print('target:', TARGET_LABEL, '| context:', CONTEXT_ID,
          '| context hash:', packet_hash[:12])
    print('confirmation:', CONFIRMATION, '| revision:', REVISION,
          '| source fingerprint:', packet['source_fingerprint'][:12])

    def persisted_context():
        body = {k: v for k, v in bcb_packet.items() if k != 'packet_hash'}
        if source_hash(body) != packet_hash:
            raise AssertionError('canonical body does not hash to persisted packet_hash')
        if (str(initial_context['confirmation_id']) != str(CONFIRMATION) or
                initial_context['assessment_revision'] != REVISION or
                initial_context['packet'].get('schema_version') != 'business-context-package/1.1'):
            raise AssertionError('persisted service readback identity mismatch')
        return 'restricted persisted readback, canonical hash and pinned identity verified'

    def current_m2_source():
        if (packet.get('schema_version') != 'project1-m2-projection/1-candidate' or
                packet.get('confirmed') is not True or
                str(packet.get('assessment_id')) != str(ASSESSMENT) or
                packet.get('assessment_revision') != REVISION or
                str(packet.get('confirmation', {}).get('confirmation_id')) != str(CONFIRMATION) or
                len(packet.get('declarations', [])) != 11):
            raise AssertionError('M2 source or confirmation is not current')
        verify_projection(packet)
        if initial_state['confirmation_digest'] != str(bcb_packet['confirmation']['digest']):
            raise AssertionError('M2 and BCB confirmation digest mismatch')
        return 'current revision 11, 11 declarations, source fingerprint verified'

    def source_alignment():
        m2 = {row['item_key']: row for row in packet['declarations']}
        bcb = {row['item_key']: row for row in bcb_packet.get('m2_answers', [])}
        if len(m2) != 11 or len(bcb) != 11 or set(m2) != set(bcb):
            missing = sorted(set(m2) ^ set(bcb))
            raise AssertionError(f'first mismatch: m2_answers.item_key membership {missing[:1]}')
        fields = ('item_key', 'answer_revision_id', 'item_version_id', 'answer_state', 'value')
        for key in sorted(m2):
            for field in fields:
                if canonical_bytes(m2[key].get(field)) != canonical_bytes(bcb[key].get(field)):
                    raise AssertionError(f'first mismatch: m2_answers[{key}].{field}')
        return '11 item keys, answer revisions, item versions, states and canonical values match'

    def rec(key, status='MOST_SUGGESTED'):
        declaration = next(row for row in packet['declarations'] if row['item_key'] == key)
        return {
            'recommendation_status': status,
            'problem_type': ('SOURCE_CONFIRMED_INFORMATION_GAP'
                             if status == 'MOST_SUGGESTED' else 'EXPLORATORY_RESEARCH_NEED'),
            'problem': (f'The confirmed answer to {key} is {declaration["value"]}.'
                        if status == 'MOST_SUGGESTED' else None),
            'research_objective': f'To investigate what {key} leaves unresolved.',
            'source_refs': ([{
                'item_key': key,
                'answer_revision_id': declaration['answer_revision_id'],
                'item_version_id': declaration['item_version_id'],
            }] if status == 'MOST_SUGGESTED' else []),
            'reason': 'Restates the confirmed uncertainty.',
            'authority': 'CANDIDATE_ONLY',
        }

    proposal_payload = {
        'contract_version': CONTRACT_VERSION,
        'recommendations': [rec('M2V1-01'), rec('M2V1-11', 'SUGGESTED')],
    }
    runner = lambda stage, value, output_type, **kwargs: json.loads(
        json.dumps(proposal_payload))
    state = {}

    def recheck_live_source():
        try:
            latest = read_authoritative_state()
            context = read_persisted_context_readonly()
        except Exception:
            return None
        if (str(context.get('packet', {}).get('packet_hash')) != packet_hash or
                str(latest['bcb_packet'].get('packet_hash')) != packet_hash):
            return None
        return latest['packet'].get('source_fingerprint')

    def execute():
        result = BDJEngine(rules, model_runner=runner).propose_objectives(
            packet, recheck_current=recheck_live_source,
            context_packet=bcb_packet, context_id=str(CONTEXT_ID))
        state['out'] = result
        if (result['outcome'] != 'reviewed' or len(result['proposals']) != 2 or
                result.get('source_fingerprint') != packet['source_fingerprint']):
            reason = next((row.get('reason') for row in result.get('checkpoints', [])
                           if row.get('reason')), None)
            raise AssertionError(f'{result["outcome"]} / {len(result["proposals"])} / {reason}')
        return 'simulated BDJ execution reviewed two source-bound candidates'

    def execution_binding():
        result = state['out']
        if (str(result.get('context_id')) != str(CONTEXT_ID) or
                str(result.get('context_packet_hash')) != packet_hash or
                result.get('source_fingerprint') != packet['source_fingerprint'] or
                result.get('findings') != [] or
                result.get('finding_authority') != 'CANDIDATE_ONLY'):
            raise AssertionError('execution receipt source/context binding mismatch')
        return 'execution receipt carries current source + persisted context hashes; findings=[]'

    def contracts():
        proposals = state['out']['proposals']
        statuses = [row['recommendation_status'] for row in proposals]
        if statuses != ['MOST_SUGGESTED', 'SUGGESTED']:
            raise AssertionError(f'proposal categories mismatch: {statuses}')
        if any(row.get('authority') != 'CANDIDATE_ONLY' for row in proposals):
            raise AssertionError('proposal authority is not candidate-only')
        source = next(row for row in packet['declarations']
                      if row['item_key'] == 'M2V1-01')
        if (proposals[0]['source_refs'][0]['answer_revision_id'] != source['answer_revision_id'] or
                proposals[0]['source_refs'][0]['item_version_id'] != source['item_version_id']):
            raise AssertionError('proposal source reference differs from confirmed M2')
        return 'both recommendation categories; exact source refs; candidate-only'

    def zero_recommendations():
        empty_payload = {'contract_version': CONTRACT_VERSION, 'recommendations': []}
        result = BDJEngine(rules, model_runner=lambda *args, **kwargs: empty_payload).propose_objectives(
            packet, recheck_current=recheck_live_source,
            context_packet=bcb_packet, context_id=str(CONTEXT_ID))
        cp5 = next(row for row in result['checkpoints'] if row.get('checkpoint') == 5)
        if result['outcome'] != 'reviewed' or result['proposals'] or \
                cp5.get('outcome') != 'bounded_no_recommendation':
            raise AssertionError('zero-recommendation outcome was not bounded')
        return 'valid zero-recommendation result is bounded and reviewed'

    def wrong_context_hash():
        bad = json.loads(json.dumps(bcb_packet))
        bad['packet_hash'] = '0' * 64
        result = BDJEngine(rules, model_runner=runner).propose_objectives(
            packet, recheck_current=lambda: packet['source_fingerprint'],
            context_packet=bad, context_id=str(CONTEXT_ID))
        checkpoint = next(row for row in result['checkpoints'] if row.get('checkpoint') == 4)
        if result['outcome'] != 'rejected' or \
                checkpoint.get('reason') != 'BDJ_OBJECTIVE_CONTEXT_HASH_INVALID':
            raise AssertionError(f'wrong context hash refusal mismatch: {checkpoint}')
        return 'wrong context hash refused with BDJ_OBJECTIVE_CONTEXT_HASH_INVALID'

    def stale_source():
        result = BDJEngine(rules, model_runner=runner).propose_objectives(
            packet, recheck_current=lambda: '0' * 64,
            context_packet=bcb_packet, context_id=str(CONTEXT_ID))
        cp5 = next(row for row in result['checkpoints'] if row.get('checkpoint') == 5)
        if result['outcome'] != 'stale' or cp5.get('outcome') != 'stale' or result['proposals']:
            raise AssertionError('stale M2 source was not refused at checkpoint 5')
        return 'stale source refused; proposals discarded at checkpoint 5'

    def mismatched_source_reference():
        bad = json.loads(json.dumps(bcb_packet))
        row = next(item for item in bad['m2_answers'] if item['item_key'] == 'M2V1-01')
        row['answer_revision_id'] = str(uuid.uuid4())
        bad['packet_hash'] = source_hash({k: v for k, v in bad.items()
                                         if k != 'packet_hash'})
        result = BDJEngine(rules, model_runner=runner).propose_objectives(
            packet, recheck_current=lambda: packet['source_fingerprint'],
            context_packet=bad, context_id=str(CONTEXT_ID))
        checkpoint = next(item for item in result['checkpoints'] if item.get('checkpoint') == 4)
        if result['outcome'] != 'rejected' or \
                checkpoint.get('reason') != 'BDJ_OBJECTIVE_CONTEXT_SOURCE_MISMATCH':
            raise AssertionError(f'source reference refusal mismatch: {checkpoint}')
        return 'mismatched source revision refused with BDJ_OBJECTIVE_CONTEXT_SOURCE_MISMATCH'

    def immutable_sources():
        current = read_authoritative_state()
        current_context = read_persisted_context_readonly()
        if current['snapshot_hash'] != initial_state['snapshot_hash']:
            raise AssertionError('restricted M2 answer/context canonical snapshot changed')
        if (current['packet']['source_fingerprint'] != packet['source_fingerprint'] or
                str(current['bcb_packet']['packet_hash']) != packet_hash or
                str(current_context['packet']['packet_hash']) != packet_hash):
            raise AssertionError('M2 source fingerprint or persisted BCB hash changed')
        return (f'{current["answer_row_count"]} restricted answer rows + BCB canonical content '
                'unchanged under the same owner/RLS path')

    checks_to_run = [
        ('1. persisted BCB readback, hash and identity', persisted_context),
        ('2. current M2 confirmation and source fingerprint', current_m2_source),
        ('3. exact M2 to BCB reference/value alignment', source_alignment),
        ('4. simulated BDJ proposal execution', execute),
        ('5. execution receipt binds source and context', execution_binding),
        ('6. both categories and candidate-only contract', contracts),
        ('7. zero recommendations are bounded', zero_recommendations),
        ('8. wrong context hash refusal code', wrong_context_hash),
        ('9. stale source and mismatched refs refused', lambda: (
            stale_source(), mismatched_source_reference())),
        ('10. M2 and BCB canonical data unchanged', immutable_sources),
    ]
    for label, fn in checks_to_run:
        check(label, fn)

    admin.close()
    passed = sum(row['result'] == 'PASS' for row in checks)
    evidence = {
        'gate': 4,
        'target': f'{TARGET_DB}@{TARGET_HOST}:{PORT}',
        'context_id': str(CONTEXT_ID),
        'packet_hash': packet_hash,
        'confirmation': str(CONFIRMATION),
        'revision': REVISION,
        'source_fingerprint': packet['source_fingerprint'],
        'restricted_answer_row_count': initial_state['answer_row_count'],
        'provider': 'simulated_local_runner',
        'database_writes': False,
        'checks': checks,
        'passed': passed,
        'total': len(checks),
        'verdict': 'PASS' if passed == len(checks) else 'FAIL',
    }
    out_path = BACKEND.parent / 'deliverables/phase2/BDJ_GATE4_BINDING_20261122.json'
    out_path.write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding='utf-8')
    print('\n  %d/%d checks passed' % (passed, len(checks)))
    print('  evidence:', out_path)
    print('  VERDICT:', evidence['verdict'])
    return 0 if evidence['verdict'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
