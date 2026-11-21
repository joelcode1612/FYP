"""Item 4: persist the validated three-rule BDJ evaluation and read it back.

Reuses the pinned ruleset artifact UNMODIFIED — its SHA-256 is verified against
``SYNTHETIC_M2V1_RULESET_SHA256`` and the file is never edited here. A caller-side
discovery-signal map is applied because ``propose()`` omits the field; that gap is
recorded as evidence, not hidden.

Mock provider only: no network, no cloud call, no original Dss access. The
disposable cluster and its test-only policies are created by run_isolated.py.

Run:
    .venv/Scripts/python.exe -B tests/m2_bcb/run_isolated.py --suite bdj-output \
        --candidate-port 56442 --output ../artifacts/stage34_integration_20261121/g2_output_connected
"""
import hashlib
import hmac
import json
import os
import secrets
import time
from pathlib import Path
from types import SimpleNamespace
from uuid import UUID, uuid4

import httpx
import pytest
from pydantic import SecretStr
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

from test_postgres_api import lab, answer

# Required discovery_signal per rule, taken from the validator's own table in
# bdj_discovery_candidate.validate_information_gap_trial_v101. `propose()` does
# not emit this field, so the caller supplies it and that omission is recorded.
RULE_SIGNAL = {
    'M2V1_EXPLICIT_PLANNING_UNDECIDED': 'EXPLICIT_UNCERTAINTY',
    'M2V1_EVIDENCE_INVENTORY_UNKNOWN': 'EVIDENCE_LIMITATION',
    'M2V1_RESEARCH_PURPOSE_UNSURE': 'EXPLICIT_UNCERTAINTY',
}


def _assertion(actor, key, ttl=30):
    """Signed identity assertion matching project1_identity.verified_actor().

    A bare ``project1.actor_id`` setting is NOT sufficient under the protected
    policies: verified_actor() returns NULL unless the token carries a valid
    HMAC over ``actor|expiry|nonce``. The G1 test read zero rows for exactly
    that reason, so the readback here signs a real short-lived assertion.
    """
    expiry = int(time.time()) + ttl
    nonce = secrets.token_hex(16)          # exactly 32 hex characters
    payload = f'{actor}|{expiry}|{nonce}'
    sig = hmac.new(key, payload.encode('utf-8'), hashlib.sha256).hexdigest()
    return f'{payload}|{sig}'

# Exactly one source per rule, so the output has three findings and no rule
# fires twice. M2V1-05 and M2V1-10 are derived from 04 / 09 and carry a value
# inside the derived allowance.
#
# M2V1-01 is GEO and the approved versioned GEO catalogue is unavailable in this
# environment, so the endpoint refuses any named area ("no area reference can be
# invented") and UNDECIDED is the only admissible value. Rule 1 therefore fires
# on M2V1-01, and M2V1-02 must stay definite or the rule would fire twice and
# collide with uq_m2_bdj_rule_revision at persistence.
ANSWERS = {
    'M2V1-01': 'UNDECIDED',          # rule 1 (GEO catalogue unavailable)
    'M2V1-02': 'HYBRID',
    'M2V1-03': ['COFFEE'],
    'M2V1-04': ['STUDENTS'],
    'M2V1-05': 'STUDENTS',
    'M2V1-06': 'QUALITY',
    'M2V1-07': 'STUDY_WORK',
    'M2V1-08': ['UNKNOWN'],          # rule 2
    'M2V1-09': ['CONCEPT_INTEREST'],
    'M2V1-10': 'CONCEPT_INTEREST',
    'M2V1-11': 'UNSURE',             # rule 3
}


def test_g2_three_rule_output_persisted_and_read_back(lab, monkeypatch):
    from scripts.register_m2_v1 import register
    from sitewise.api.v1 import project1_workflow as api
    from sitewise.core.config import settings
    from sitewise.db import m2_session
    from sitewise.project1.bdj import (BDJEngine, SYNTHETIC_M2V1_RULESET,
                                       SYNTHETIC_M2V1_RULESET_SHA256)
    from sitewise.project1.bdj_discovery_candidate import DiscoveryOutputCandidate
    from sitewise.project1.contracts import digest
    from sitewise.project1.prompts import Prompt
    from sitewise.project1.provider import ModelRunner, TokenHarbor, ENDPOINT, MODEL
    from sitewise.services.bdj_synthetic_execution import prepare_registered_trial

    root = Path(__file__).resolve().parents[2]
    dburl = make_url(os.environ['DATABASE_URL'])
    assert dburl.database == 'project1_m2_bcb_test'
    assert dburl.port == int(os.environ['M2_BCB_PRIVATE_PORT']) and dburl.port != 5432

    # ---- 1. Pinned artifact must be byte-identical; never edited ----------
    artifact = root / 'tools/cp13_verification/v2/bdj_m2v1_information_gap_proposal.py'
    artifact_sha = hashlib.sha256(artifact.read_bytes()).hexdigest()
    assert artifact_sha == SYNTHETIC_M2V1_RULESET_SHA256

    key, password = secrets.token_bytes(32), secrets.token_hex(24)
    migrations = ['20261111_01_candidate_ledger.sql', '20261117_01_execution_principal.sql',
                  '20261117_02_finding_provenance.sql', '20261117_03_bdj_result_persistence.sql']
    raw = lab['db'].raw_connection()
    try:
        cur = raw.cursor()
        cur.execute("SET project1.migration_target='project1_m2_bcb_test'; "
                    "SET project1.migration_receipt='MOCK-G2-PRIVATE-ONLY'")
        for name in migrations:
            sql = (root / 'migrations/project1_ai' / name).read_text(encoding='utf-8')
            cur.execute(sql.replace("'project1_workflow_tests'", "'project1_m2_bcb_test'"))
        cur.execute("SET project1.identity_test_receipt='PRIVATE-SYNTHETIC-ONLY'")
        cur.execute((root / 'migrations/m2/20261121_01_protected_identity_private_rehearsal.sql')
                    .read_text(encoding='utf-8'))
        raw.commit()
    finally:
        raw.close()

    # D3 must be in force for a finding to carry a source identity and for the
    # 5-column key to admit more than one finding per rule. Raw DBAPI cursor:
    # the file contains '%' inside RAISE EXCEPTION, and psycopg2 only treats '%'
    # as a placeholder when parameters are supplied — SQLAlchemy always supplies
    # an (empty) param mapping, which breaks the parse.
    with lab['db'].raw_connection() as rc:
        rc.autocommit = True
        cur = rc.cursor()
        cur.execute("SET project1.m2_bcb_migration_target='project1_m2_bcb_test'")
        cur.execute("SET project1.m2_bcb_migration_receipt='MOCK-G2-PRIVATE-ONLY'")
        cur.execute((root / 'migrations/m2/20261121_02_finding_source_identity.sql')
                    .read_text(encoding='utf-8'))
        cur.close()
    with lab['db'].begin() as c:
        c.execute(text('INSERT INTO project1_identity.private_key VALUES (1,:key)'), {'key': key})
        c.exec_driver_sql((Path(__file__).parent / 'protected_review_private_policies.sql')
                          .read_text(encoding='utf-8'))
        c.exec_driver_sql("ALTER ROLE p1_m2_runtime PASSWORD '" + password + "'")
        c.exec_driver_sql("ALTER ROLE p1ai_engine PASSWORD '" + password + "'")
        c.exec_driver_sql('GRANT USAGE ON SCHEMA project1_identity TO p1ai_runtime')
        c.exec_driver_sql('GRANT EXECUTE ON FUNCTION project1_identity.verified_actor() TO p1ai_runtime')
        rows = c.execute(text("SELECT tablename FROM pg_policies WHERE schemaname='project1_ai' "
                              "AND policyname='owner_scope'")).scalars().all()
        for table in rows:
            assert table.replace('_', '').isalnum()
            c.exec_driver_sql(f'ALTER POLICY owner_scope ON project1_ai.{table} USING '
                              '(owner_user_id=project1_identity.verified_actor()) WITH CHECK '
                              '(owner_user_id=project1_identity.verified_actor())')
        c.exec_driver_sql('CREATE TABLE project1_ai.synthetic_trial_authority '
                          '(run_id uuid PRIMARY KEY REFERENCES project1_ai.runs(id), owner_user_id uuid NOT NULL, '
                          'authorization_json jsonb NOT NULL)')
        c.exec_driver_sql('REVOKE ALL ON project1_ai.synthetic_trial_authority FROM PUBLIC')
        c.exec_driver_sql('GRANT SELECT ON project1_ai.synthetic_trial_authority TO p1ai_runtime')
        c.exec_driver_sql('ALTER TABLE project1_ai.synthetic_trial_authority ENABLE ROW LEVEL SECURITY')
        c.exec_driver_sql('CREATE POLICY owner_scope ON project1_ai.synthetic_trial_authority '
                          'FOR SELECT USING (owner_user_id=project1_identity.verified_actor())')

    source_url = dburl.set(username='p1_m2_runtime', password=password)
    runtime_url = dburl.set(username='p1ai_engine', password=password)
    runtime = create_engine(runtime_url, hide_parameters=True)
    monkeypatch.setattr(settings, 'm2_database_url', SecretStr(source_url.render_as_string(hide_password=False)))
    monkeypatch.setattr(settings, 'project1_runtime_database_url', SecretStr(runtime_url.render_as_string(hide_password=False)))
    monkeypatch.setattr(settings, 'm2_protected_identity_enabled', True)
    monkeypatch.setattr(settings, 'm2_identity_assertion_key', SecretStr(key.hex()))
    monkeypatch.setattr(settings, 'project1_isolated_database_name', dburl.database)
    monkeypatch.setattr(settings, 'project1_isolated_database_port', dburl.port)
    monkeypatch.setattr(settings, 'project1_synthetic_bdj_trial_enabled', True)
    monkeypatch.setattr(settings, 'tokenharbor_enabled', True)
    monkeypatch.setattr(settings, 'project1_key_custody_dir',
                        str(Path(os.environ['M2_BCB_PRIVATE_CLUSTER']) / 'keys'))
    prompt_path = root.parent / 'artifacts/stage34_integration_20261119/bdj_synthetic_trial_v1_0_1_prompt.txt'
    monkeypatch.setattr(settings, 'project1_synthetic_bdj_prompt_path', str(prompt_path))
    monkeypatch.setattr(settings, 'project1_synthetic_bdj_prompt_sha256',
                        hashlib.sha256(prompt_path.read_bytes()).hexdigest())
    prompt = Prompt('BDJ-M2V1-INFO-GAP-TEST-1.0.1',
                    'You are a bounded business declaration reviewer.',
                    prompt_path.read_bytes().decode('utf-8'))

    hits, outputs = [], []

    def transport(request):
        hits.append(request.content)
        return httpx.Response(200, json={'model': MODEL, 'choices': [{'finish_reason': 'stop',
            'message': {'role': 'assistant', 'content': json.dumps(outputs[-1])}}]})

    def runner_factory(ledger, disclosure, prompts):
        return ModelRunner(TokenHarbor(SecretStr('mock-not-a-credential'), enabled=True,
            transport=httpx.MockTransport(transport)), ledger, prompts, disclosure=disclosure)

    monkeypatch.setattr(api, 'configured_runner', runner_factory)
    lab['app'].dependency_overrides[api.get_runner_factory] = lambda: runner_factory
    iid = register(lab['db'], apply=True, expected_database=dburl.database)['instrument_id']

    evidence = {'artifact_sha256': artifact_sha, 'ruleset_version': SYNTHETIC_M2V1_RULESET}
    try:
        mid = lab['request']('POST', '/assessments', 201,
                             json={'instrument_version_id': iid}).json()['id']
        for rev, (item, value) in enumerate(ANSWERS.items()):
            answer(lab, mid, item, value, rev)
        lab['request']('POST', f'/assessments/{mid}/review', json={'expected_revision': 11})
        confirmation = lab['request']('POST', f'/assessments/{mid}/confirm',
            json={'expected_revision': 11, 'acknowledged_issue_ids': []}).json()

        uid = SimpleNamespace(user_id=lab['actor'])
        with m2_session.m2_session_for(lab['actor']) as s:
            envelope = api.source(s, uid, UUID(mid), 11, include_inventory=True)
        packet = envelope['projection']
        run_id = uuid4()
        record = {'run_id': str(run_id), 'owner_id': str(lab['actor']), 'assessment_id': mid,
            'revision': 11, 'confirmation_id': confirmation['id'],
            'source_fingerprint': packet['source_fingerprint'], 'endpoint': ENDPOINT, 'model': MODEL,
            'rules_sha256': SYNTHETIC_M2V1_RULESET_SHA256, 'prompt_fingerprint': prompt.fingerprint,
            'request_sha256': '0' * 64, 'approval_receipt': 'MOCK-G2-NONHUMAN-NO-NETWORK-ONLY',
            'data_class': 'SYNTHETIC_NONHUMAN', 'decision': 'APPROVED', 'max_attempts': 1,
            'output_schema_sha256': digest(DiscoveryOutputCandidate.model_json_schema()),
            'inventory_fingerprint': envelope['item_inventory']['inventory_fingerprint']}
        with lab['db'].begin() as c:
            c.execute(text('INSERT INTO project1_ai.runs(id,owner_user_id,assessment_id,assessment_revision,'
                'source_fingerprint,policy_fingerprint,work_identity) VALUES (:r,:o,:a,11,:f,:p,:w)'),
                {'r': run_id, 'o': lab['actor'], 'a': UUID(mid), 'f': packet['source_fingerprint'],
                 'p': 'd' * 64, 'w': hashlib.sha256(run_id.bytes).hexdigest()})
            c.execute(text('INSERT INTO project1_ai.synthetic_trial_authority VALUES (:r,:o,CAST(:v AS jsonb))'),
                {'r': run_id, 'o': lab['actor'], 'v': json.dumps(record)})

        with m2_session.m2_session_for(lab['actor']) as s:
            prepared = prepare_registered_trial(session=s, user=uid, assessment_id=UUID(mid), revision=11,
                packet_source=api.source, runtime=runtime, runner_factory=runner_factory)
            model_packet, _ = BDJEngine(prepared['rules']).prepare_discovery_trial(packet,
                item_definitions=prepared['item_definitions'],
                recheck_current=prepared['current_fingerprint'],
                inventory_envelope=envelope, registered_disclosure=prepared['runner'].disclosure)
            messages = prompt.messages(model_packet, DiscoveryOutputCandidate.model_json_schema())
            body = httpx.Request('POST', ENDPOINT,
                json=prepared['runner'].provider.prepare_payload(messages, DiscoveryOutputCandidate)).content

        # ---- 2. Output produced by the pinned ruleset, not hand-authored ----
        # Evaluate the original projection: model_packet carries rule_catalogue,
        # which is not part of the hashed content, so its fingerprint no longer
        # matches and verify_projection() would refuse it.
        raw = prepared['rules'].propose(packet)
        assert sorted(i['rule_id'] for i in raw['issues']) == sorted(RULE_SIGNAL), \
            [i['rule_id'] for i in raw['issues']]
        issues = [{**i, 'discovery_signal': RULE_SIGNAL[i['rule_id']]} for i in raw['issues']]
        evaluated = {'contract_version': 'bdj-discovery-output/1-candidate',
                     'issues': issues, 'overall_note': raw['overall_note']}

        record['request_sha256'] = hashlib.sha256(body).hexdigest()
        with lab['db'].begin() as c:
            c.execute(text('UPDATE project1_ai.synthetic_trial_authority '
                           'SET authorization_json=CAST(:v AS jsonb) WHERE run_id=:r'),
                      {'r': run_id, 'v': json.dumps(record)})

        # ---- 3. Actual FastAPI BDJ endpoint ---------------------------------
        outputs.append(evaluated)
        result = lab['request']('POST', f'/assessments/{mid}/bdj/evaluate', 200,
                                json={'expected_revision': 11}).json()
        assert hits[-1] == body, 'provider body drifted from the authorised request'
        # The M2 answers must actually BE in the BDJ request, not merely produce a
        # body that matches one we built. Assert every answer revision id is present.
        body_text = body.decode('utf-8')
        absent = [d['item_key'] for d in packet['declarations']
                  if d['answer_revision_id'] not in body_text]
        assert not absent, f'M2 answers absent from the BDJ request: {absent}'
        assert all(d['item_key'] in body_text for d in packet['declarations']), \
            'item keys absent from the BDJ request'
        assert result['validation_status'] == 'valid'
        assert len(result['findings']) == 3

        read = lab['request']('GET', f'/assessments/{mid}/bdj/current',
            params={'confirmation_id': confirmation['id'], 'expected_revision': 11}).json()
        assert read['status'] == 'COMPLETED_WITH_FINDINGS'
        assert read['result']['result_id'] == result['result_id']

        # ---- 3b. D1: materialise findings and link them ----------------------
        from sitewise.services.bdj_finding_admission import admit_and_link
        with m2_session.m2_session_for(lab['actor']) as s:
            admission = admit_and_link(
                m2_session=s, runtime_engine=runtime, actor_id=lab['actor'],
                assessment_id=UUID(mid), revision=11, result=read['result'],
                ruleset_version=SYNTHETIC_M2V1_RULESET,
                identity_assertion=_assertion(lab['actor'], key))
            s.commit()
        assert len(admission['finding_ids']) == 3, admission
        assert len(set(admission['finding_ids'])) == 3, 'finding ids must be distinct'

        # ---- 4. Fresh restricted-role readback -------------------------------
        # Two independent reads on a NEW engine/connection:
        #   (a) raw SQL as p1ai_runtime — proves the row is visible under RLS and
        #       that the payload is SEALED, so findings cannot leak from a SELECT;
        #   (b) the custody readback — proves the sealed payload opens to exactly
        #       the three findings that were evaluated.
        from sitewise.project1.key_custody import LocalKeyCustody
        from sitewise.project1.result_store import results_for_assessment

        fresh = create_engine(runtime_url, hide_parameters=True)
        try:
            with fresh.connect() as c:
                c.exec_driver_sql('SET ROLE p1ai_runtime')
                c.execute(text("SELECT set_config('project1.identity_assertion', :t, false)"),
                          {'t': _assertion(lab['actor'], key)})
                row = c.execute(text('SELECT result_id, finding_count, validation_status, '
                    'source_fingerprint, result_payload FROM project1_ai.bdj_results WHERE run_id=:r'),
                    {'r': run_id}).mappings().one()
                sources = c.scalar(text('SELECT count(*) FROM project1_ai.bdj_result_sources '
                                        'WHERE result_id=:r'), {'r': UUID(result['result_id'])})
                links = c.scalar(text('SELECT count(*) FROM project1_ai.bdj_result_findings '
                                      'WHERE result_id=:r'), {'r': UUID(result['result_id'])})
                source_rows = [dict(r) for r in c.execute(text(
                    'SELECT source_rank, source_id, source_version, locator '
                    'FROM project1_ai.bdj_result_sources '
                    'WHERE result_id=:r ORDER BY source_rank'),
                    {'r': UUID(result['result_id'])}).mappings()]
                attempts = [dict(r) for r in c.execute(text(
                    'SELECT a.attempt_no, a.stage, r.outcome FROM project1_ai.attempts a '
                    'LEFT JOIN project1_ai.attempt_receipts r '
                    '  ON r.run_id=a.run_id AND r.attempt_no=a.attempt_no '
                    'WHERE a.run_id=:r'), {'r': run_id}).mappings()]
            history = results_for_assessment(
                fresh, lab['actor'], UUID(mid), payload_custody=LocalKeyCustody(),
                expected_revision=11, expected_fingerprint=packet['source_fingerprint'],
                include_finding_refs=True)
        finally:
            fresh.dispose()

        assert str(row['result_id']) == result['result_id']
        assert row['finding_count'] == 3 and row['validation_status'] == 'valid'
        assert row['source_fingerprint'] == packet['source_fingerprint']
        assert sources == 11
        # (a) the stored payload is sealed, not plaintext findings
        assert '__payload_envelope__' in row['result_payload']
        assert 'findings' not in row['result_payload']
        # (b) the sealed payload opens to exactly what was evaluated
        assert len(history) == 1, history
        assert str(history[0]['result_id']) == result['result_id']
        assert history[0]['source_fingerprint'] == packet['source_fingerprint']
        stored_rules = sorted(i['rule_id'] for i in history[0]['findings'])
        assert stored_rules == sorted(RULE_SIGNAL), stored_rules
        stored_sources = sorted(i['source_refs'][0]['item_key'] for i in history[0]['findings'])
        assert stored_sources == ['M2V1-01', 'M2V1-08', 'M2V1-11'], stored_sources

        # ---- 3. All 11 item identities and exact triggering revisions --------
        declarations = {d['item_key']: d for d in packet['declarations']}
        assert len(source_rows) == 11, source_rows
        # locator carries the item identity: "<item_key>@<item_version_id>"
        assert sorted(r['locator'].split('@')[0] for r in source_rows) == sorted(ANSWERS), \
            sorted(r['locator'] for r in source_rows)
        # source_id carries the exact answer revision that was evaluated
        assert sorted(r['source_id'] for r in source_rows) == sorted(
            declarations[k]['answer_revision_id'] for k in ANSWERS), \
            sorted(r['source_id'] for r in source_rows)
        # source_version carries the exact item version
        assert sorted(r['source_version'] for r in source_rows) == sorted(
            declarations[k]['item_version_id'] for k in ANSWERS)
        with lab['db'].connect() as c:
            for finding in history[0]['findings']:
                ref = finding['source_refs'][0]
                key = ref['item_key']
                # the triggering revision is the one recorded on the declaration
                assert ref['answer_revision_id'] == declarations[key]['answer_revision_id'], key
                assert ref['item_version_id'] == declarations[key]['item_version_id'], key
                # and it resolves to a real persisted answer row
                assert c.scalar(text('SELECT count(*) FROM m2_answer_revisions WHERE id=:i'),
                                {'i': UUID(ref['answer_revision_id'])}) == 1, key

        # ---- 4. Attempt record exists and is classified deterministic --------
        assert len(attempts) == 1, attempts
        classification = {
            'output_provenance': 'DETERMINISTIC_RULE_ENGINE',
            'producer': 'bdj_m2v1_information_gap_proposal.propose()',
            'transport': 'MOCKED_NO_NETWORK',
            'model_called': False,
            'network_used': False,
            'attempt_rows': len(attempts),
            'attempt_no': attempts[0]['attempt_no'],
            'attempt_stage': attempts[0]['stage'],
            'attempt_outcome': attempts[0]['outcome'],
            'note': ('The attempt row proves one execution went through the guarded trial. The '
                     'transport is a mock inside the test process, so no model request left the '
                     'process and the finding content was produced by the rule engine, not a model.'),
        }
        # D1 closed: each of the three findings now has a durable row and a link.
        assert links == 3, f'expected 3 finding links, got {links}'
        assert row['finding_count'] == 3

        # ---- 5. D3 behaviour: two sources per rule allowed, replay refused ---
        from sqlalchemy.exc import IntegrityError
        two_sources_allowed = False
        with lab['db'].connect() as c:
            tx = c.begin_nested()
            try:
                insert = text('INSERT INTO m2_bdj_findings '
                    '(id,assessment_id,assessment_revision,rule_id,rule_version,source_answer_ids,'
                    'issue_type,explanation,not_proven,next_action,review_state) '
                    "VALUES (:id,:assessment,11,'M2V1_PROBE_RULE','PROBE-1',"
                    "CAST(:sources AS json),'INFORMATION_GAP',"
                    "'synthetic','synthetic','synthetic','CANDIDATE')")
                c.execute(insert, {'id': uuid4(), 'assessment': UUID(mid),
                                   'sources': json.dumps(['probe-a'])})
                # second finding, same rule, different source -> must be accepted
                c.execute(insert, {'id': uuid4(), 'assessment': UUID(mid),
                                   'sources': json.dumps(['probe-b'])})
                # replay of the same source -> must still be refused
                with pytest.raises(IntegrityError) as collision:
                    c.execute(insert, {'id': uuid4(), 'assessment': UUID(mid),
                                       'sources': json.dumps(['probe-a'])})
                assert collision.value.orig.pgcode == '23505'
                two_sources_allowed = True
            finally:
                tx.rollback()

        # ---- 5b. Deliverable artefacts + authorised readback comparison ------
        http_cmp = sorted((f['rule_id'], f['source_refs'][0]['item_key'],
                           f['source_refs'][0]['answer_revision_id'])
                          for f in read['result']['findings'])
        db_cmp = sorted((f['rule_id'], f['source_refs'][0]['item_key'],
                         f['source_refs'][0]['answer_revision_id'])
                        for f in history[0]['findings'])
        assert http_cmp == db_cmp, (http_cmp, db_cmp)

        evidence_dir = Path(os.environ['M2_BCB_EVIDENCE'])
        (evidence_dir / '01_input_packet.json').write_text(
            json.dumps(packet, indent=2, sort_keys=True, default=str), encoding='utf-8')
        (evidence_dir / '02_evaluated_output.json').write_text(
            json.dumps(evaluated, indent=2, sort_keys=True), encoding='utf-8')
        # The exact bytes the transport received: this is what a model would see.
        (evidence_dir / '06_bdj_request.json').write_text(
            json.dumps(json.loads(body_text), indent=2, sort_keys=True), encoding='utf-8')
        (evidence_dir / '03_database_evidence.json').write_text(json.dumps({
            'result': {k: str(v) for k, v in dict(row).items() if k != 'result_payload'},
            'payload_sealed': '__payload_envelope__' in row['result_payload'],
            'payload_has_plaintext_findings': 'findings' in row['result_payload'],
            'bdj_result_sources': source_rows,
            'bdj_result_findings_count': links,
            'admission': admission,
            'attempts': attempts,
            'classification': classification,
        }, indent=2, sort_keys=True, default=str), encoding='utf-8')
        (evidence_dir / '04_readback_comparison.json').write_text(json.dumps({
            'http_readback': [{'rule_id': a, 'item_key': b, 'answer_revision_id': c}
                              for a, b, c in http_cmp],
            'restricted_connection_custody_readback': [{'rule_id': a, 'item_key': b,
                                                        'answer_revision_id': c}
                                                       for a, b, c in db_cmp],
            'match': http_cmp == db_cmp,
            'source_fingerprint_match': row['source_fingerprint'] == packet['source_fingerprint'],
            'finding_count_match': row['finding_count'] == len(evaluated['issues']) == 3,
            'validation_status': row['validation_status'],
        }, indent=2, sort_keys=True, default=str), encoding='utf-8')

        (evidence_dir / '05_queries.sql').write_text(
            "-- Read-only queries for this run. The disposable cluster is stopped when\n"
            "-- the suite ends, so these must be run while it is still up.\n"
            "-- RLS applies: connect as the cluster superuser, or set a valid\n"
            "-- project1.identity_assertion signed for the owner before reading.\n"
            f"-- result_id = {result['result_id']}\n"
            f"-- run_id    = {run_id}\n"
            f"-- owner     = {lab['actor']}\n\n"
            "-- 1. The persisted evaluation record\n"
            "SELECT result_id, run_id, assessment_id, assessment_revision,\n"
            "       validation_status, review_outcome, execution_outcome,\n"
            "       finding_count, ruleset_version, source_fingerprint\n"
            "FROM project1_ai.bdj_results\n"
            f"WHERE result_id = '{result['result_id']}';\n\n"
            "-- 2. All 11 source identities + exact answer revisions\n"
            "SELECT source_rank, source_id AS answer_revision_id,\n"
            "       source_version AS item_version_id, locator\n"
            "FROM project1_ai.bdj_result_sources\n"
            f"WHERE result_id = '{result['result_id']}'\n"
            "ORDER BY source_rank;\n\n"
            "-- 3. Execution attempt and its receipt\n"
            "SELECT a.attempt_no, a.stage, a.prompt_version, r.outcome\n"
            "FROM project1_ai.attempts a\n"
            "LEFT JOIN project1_ai.attempt_receipts r\n"
            "       ON r.run_id = a.run_id AND r.attempt_no = a.attempt_no\n"
            f"WHERE a.run_id = '{run_id}';\n\n"
            "-- 4. Individual finding links (expected 3 after admission)\n"
            "SELECT count(*) AS finding_links\n"
            "FROM project1_ai.bdj_result_findings\n"
            f"WHERE result_id = '{result['result_id']}';\n\n"
            "-- 5. The stored payload is SEALED: this returns an envelope, not findings.\n"
            "--    Use the custody readback (results_for_assessment) to open it.\n"
            "SELECT result_payload FROM project1_ai.bdj_results\n"
            f"WHERE result_id = '{result['result_id']}';\n\n"
            "-- 6. Run authorisation record\n"
            "SELECT decision, data_class, approval_receipt, rules_sha256,\n"
            "       request_sha256, source_fingerprint\n"
            "FROM project1_ai.synthetic_trial_authority\n"
            f"WHERE run_id = '{run_id}';\n",
            encoding='utf-8')

        # ---- 6. Replay is refused; nothing consumed twice -------------------
        before = len(hits)
        lab['request']('POST', f'/assessments/{mid}/bdj/evaluate', 409, json={'expected_revision': 11})
        assert len(hits) == before

        evidence.update({
            'confirmation_id': confirmation['id'], 'assessment_id': mid, 'revision': 11,
            'run_id': str(run_id), 'result_id': result['result_id'],
            'request_sha256': record['request_sha256'],
            'source_fingerprint': packet['source_fingerprint'],
            'inventory_fingerprint': envelope['item_inventory']['inventory_fingerprint'],
            'finding_count': 3,
            'rules': [{'rule_id': i['rule_id'], 'discovery_signal': i['discovery_signal'],
                       'source_item_key': i['source_refs'][0]['item_key'],
                       'source_answer_revision_id': i['source_refs'][0]['answer_revision_id'],
                       'source_item_version_id': i['source_refs'][0]['item_version_id'],
                       'quote': i['source_refs'][0]['quote']} for i in evaluated['issues']],
            'persisted': {'bdj_result_sources': sources, 'bdj_result_findings': links,
                          'finding_count': row['finding_count'],
                          'validation_status': row['validation_status']},
            'duplicate_rule_constraint': ('TWO_SOURCES_ALLOWED_REPLAY_BLOCKED'
                                         if two_sources_allowed else 'NOT_TRIGGERED'),
            'classification': classification,
            'request_carries_all_11_answers': True,
            'attempts': attempts,
            'provider': 'MOCKED_NO_NETWORK',
            'evaluation_level_persistence': True,
            'finding_level_integration': True,
            'admission': admission,
            'finding_level_note': 'Each finding now has a durable m2_bdj_findings row at '
                                  'CANDIDATE and a bdj_result_findings link. Authority stays '
                                  'candidate: no review, approval or verification is claimed.',
        })
    finally:
        (Path(os.environ['M2_BCB_EVIDENCE']) / 'g2_output_evidence.json').write_text(
            json.dumps(evidence, indent=2, default=str), encoding='utf-8')
        lab['app'].dependency_overrides.pop(api.get_runner_factory, None)
        runtime.dispose()
