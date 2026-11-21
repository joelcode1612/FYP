"""Phase 4: production M2-backed BCB bindings, exercised in the private lab.

Every test here runs against the disposable PostgreSQL cluster created by
``run_isolated.py`` and the real FastAPI/JWT profile checks. Instrument, users and
answers are synthetic fixtures; the *bindings* are no longer fixtures — they are
resolved from persisted M2 rows by ``M2ContextBindings``.

These functions are imported by ``test_postgres_api.py`` so the existing isolated
runner executes them without changing its invocation.
"""
import json
import os
import socket
from datetime import timedelta
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.orm import Session

from test_postgres_api import answer, bind, build, confirmed, create, lab  # noqa: F401


def production_resolver(lab):
    """Use the wired factory instead of the test receipt resolver, then restore."""
    from sitewise import dependencies as deps

    class _Scope:
        def __enter__(self):
            self.override = lab['app'].dependency_overrides.pop(
                deps.get_bcb_bindings_resolver_factory)
            return lab

        def __exit__(self, *exc):
            lab['app'].dependency_overrides[deps.get_bcb_bindings_resolver_factory] = self.override
            return False

    return _Scope()


def rows(lab, statement, params):
    with lab['db'].connect() as connection:
        return [dict(row) for row in connection.execute(text(statement), params).mappings()]


def test_PG40_production_confirmed_M2_creates_context_without_fixture_bindings(lab):
    mid, cid, uid = confirmed(lab, 'We guarantee profit.')
    with production_resolver(lab):
        response = build(lab, mid, cid)
    assert response.status_code == 201
    packet = response.json()['packet']
    from sitewise.services.business_context_v1 import (
        CURRENT_CONTEXT_VERSION, GEO_EXCLUDED_SCHEMA_VERSION,
    )
    assert packet['context_version'] == CURRENT_CONTEXT_VERSION
    assert packet['schema_version'] == GEO_EXCLUDED_SCHEMA_VERSION
    assert packet['identity'] == {
        'assessment_id': mid, 'tenant_id': 'm2-owner:' + str(lab['actor']),
        'owner_id': str(lab['actor'])}
    assert packet['confirmation']['id'] == cid
    assert packet['confirmation']['revision'] == 3
    assert packet['confirmation']['status'] == 'CURRENT_CONFIRMED'
    assert packet['concept']['status'] == 'ENTREPRENEUR_CONFIRMED'
    assert packet['concept']['version'].startswith('M2-CONFIRMED-3-')
    assert packet['concept']['content']['description'] == 'We guarantee profit.'
    assert packet['business_description']['item_key'] == 'M2-04'
    assert packet['business_description']['value'] == 'We guarantee profit.'
    assert packet['business_description']['evidence_class'] == 'ENTREPRENEUR_DECLARED'
    assert all(value is False for value in packet['permissions'].values())
    stored = rows(lab, 'SELECT builder_version,tenant_id,concept_version FROM m2_business_contexts '
        'WHERE confirmation_id=:cid', {'cid': cid})
    assert len(stored) == 1
    assert stored[0]['builder_version'] == CURRENT_CONTEXT_VERSION
    assert stored[0]['tenant_id'] == 'm2-owner:' + str(lab['actor'])
    assert stored[0]['concept_version'] == packet['concept']['version']


def test_PG41_production_applicable_BDJ_findings_are_bound(lab):
    mid, cid, uid = confirmed(lab, 'We guarantee profit.')
    with production_resolver(lab):
        packet = build(lab, mid, cid).json()['packet']
    persisted = rows(lab, 'SELECT id::text,rule_id,rule_version,issue_type,explanation,'
        'not_proven,next_action,review_state FROM m2_bdj_findings WHERE assessment_id=:mid '
        'AND assessment_revision=3 ORDER BY id', {'mid': mid})
    assert persisted and len(packet['findings']) == len(persisted)
    assert [(f['id'], f['rule_id'], f['rule_version'], f['issue_type'], f['explanation'],
             f['not_proven'], f['next_action'], f['review_state']) for f in packet['findings']] == [
        (row['id'], row['rule_id'], row['rule_version'], row['issue_type'], row['explanation'],
         row['not_proven'], row['next_action'], row['review_state']) for row in persisted]
    for finding in packet['findings']:
        assert finding['review_state'] == 'CANDIDATE'
        assert finding['authority_reference'] is None
        assert finding['business_facts_verified'] is False
        assert finding['report_admitted'] is False
    assert packet['provenance']['bindings_hash']


def test_PG42_production_confirmed_uncertainty_is_bound_from_its_own_record(lab):
    mid, cid, uid = confirmed(lab, 'We guarantee profit.')
    with production_resolver(lab):
        packet = build(lab, mid, cid).json()['packet']
    persisted = rows(lab, 'SELECT id::text,confirmation_id::text,actor_user_id::text,exact_text '
        'FROM m2_confirmed_uncertainties WHERE confirmation_id=:cid', {'cid': cid})
    assert len(persisted) == 1 and persisted[0]['id'] == uid
    assert packet['confirmed_uncertainty'] == persisted[0]
    assert packet['confirmed_uncertainty']['exact_text'].startswith('SYNTHETIC confirmed')


def test_PG43_business_description_template_is_deterministic_and_needs_no_provider(monkeypatch):
    """The template is pure: it must work with no model and no network."""
    from sitewise.services.business_context_v1 import current_business_description

    def option(code, label):
        return {'code': code, 'label': label}

    def item(key, kind, options, requiredness='OPTIONAL'):
        return {'id': 'item-' + key, 'item_key': key, 'question_text': key,
                'requiredness': requiredness, 'answer_kind': kind,
                'option_values': {'options': options, 'rules': {}},
                'allowed_states': ['ANSWERED', 'UNDECIDED'], 'lifecycle': 'ACTIVE',
                'sort_order': 1}

    items = [
        item('M2V1-01', 'SINGLE', [option('JOHOR', 'Johor')], 'REQUIRED'),
        item('M2V1-02', 'SINGLE', [option('DINE_IN', 'Primarily dine-in')], 'REQUIRED'),
        item('M2V1-03', 'MULTI', [option('COFFEE', 'Coffee and espresso beverages'),
                                  option('BAKED_GOODS', 'Pastries and baked goods')], 'REQUIRED'),
        item('M2V1-04', 'MULTI', [option('STUDENTS', 'Students'),
                                  option('RESIDENTS', 'Local residents')], 'REQUIRED'),
        item('M2V1-05', 'SINGLE', [option('STUDENTS', 'Students')], 'CONDITIONAL'),
        item('M2V1-06', 'SINGLE', [option('AMBIENCE', 'Ambience')], 'REQUIRED'),
        item('M2V1-07', 'SINGLE', [option('STUDY_WORK', 'Studying or working')], 'OPTIONAL'),
    ]
    answers = {
        'M2V1-01': {'answer_state': 'ANSWERED', 'value_json': {'jurisdiction': 'JOHOR'}},
        'M2V1-02': {'answer_state': 'ANSWERED', 'value_json': 'DINE_IN'},
        'M2V1-03': {'answer_state': 'ANSWERED', 'value_json': ['COFFEE', 'BAKED_GOODS']},
        'M2V1-04': {'answer_state': 'ANSWERED', 'value_json': ['STUDENTS', 'RESIDENTS']},
        'M2V1-05': {'answer_state': 'ANSWERED', 'value_json': 'STUDENTS'},
        'M2V1-06': {'answer_state': 'ANSWERED', 'value_json': 'AMBIENCE'},
        'M2V1-07': {'answer_state': 'ANSWERED', 'value_json': 'STUDY_WORK'},
    }
    # Any outbound socket during rendering is a failure: the template must not
    # depend on a model provider or a GEO service.
    monkeypatch.setattr(socket, 'socket', lambda *a, **k: pytest.fail('network access attempted'))
    first = current_business_description(items, answers)
    second = current_business_description(items, answers)
    assert first == second
    assert first['template_version'] == 'V1' and first['source'] == 'CONFIRMED_M2'
    assert first['text'] == ('The entrepreneur plans to establish a café in Johor, using a '
        'Primarily dine-in service model. The planned product categories include Coffee and '
        'espresso beverages, Pastries and baked goods. The intended customers include Students, '
        'Local residents, with Students as the primary intended audience. The café intends to '
        'emphasize Ambience. The intended customer occasion is Studying or working.')
    assert first['source_question_ids'] == ['M2V1-01', 'M2V1-02', 'M2V1-03', 'M2V1-04',
                                            'M2V1-05', 'M2V1-06', 'M2V1-07']
    # Only declared values are rendered: an undecided answer contributes nothing.
    answers['M2V1-07'] = {'answer_state': 'UNDECIDED', 'value_json': None}
    reduced = current_business_description(items, answers)
    assert 'customer occasion' not in reduced['text']
    assert 'M2V1-07' not in reduced['source_question_ids']


def test_PG44_non_geographic_context_succeeds_without_geo_authority(lab):
    mid, cid, uid = confirmed(lab, 'We guarantee profit.')
    with production_resolver(lab):
        packet = build(lab, mid, cid).json()['packet']
    from sitewise.services.business_context_v1 import (
        CONTRACTS, CONTEXT_VERSION, CURRENT_CONTEXT_VERSION,
    )
    assert packet['geography'] is None
    assert any('outside V1 scope' in line for line in packet['limitations'])
    assert not any('approved context identity' in line for line in packet['limitations'])
    # The change is a version bump, not a silent relaxation of the old contract.
    assert CONTRACTS[CONTEXT_VERSION][1] is True
    assert CONTRACTS[CURRENT_CONTEXT_VERSION][1] is False
    # No GEO catalogue, approval or geometry is fabricated to fill the slot.
    assert 'GEO_V1' not in json.dumps(packet)


def test_PG45_production_authorization_refuses_cross_owner_and_wrong_role(lab):
    mid, cid, uid = confirmed(lab, 'We guarantee profit.')
    payload = {'confirmation_id': cid, 'expected_revision': 3}
    path = f'/assessments/{mid}/business-context'
    with production_resolver(lab):
        lab['request']('POST', path, 401, uid=None, json=payload)
        lab['request']('POST', path, 403, uid=lab['staff'], json=payload)
        lab['request']('POST', path, 403, uid=lab['suspended'], json=payload)
        lab['request']('POST', path, 404, uid=lab['other'], json=payload)
        lab['request']('POST', path, 422, json={**payload, 'owner_id': str(lab['other']),
                                                'tenant_id': 'forged-tenant'})
        assert rows(lab, 'SELECT count(*) AS n FROM m2_business_contexts WHERE confirmation_id=:cid',
                    {'cid': cid})[0]['n'] == 0
        # The owner is still served: refusal is about authorization, not breakage.
        assert build(lab, mid, cid).status_code == 201


def test_PG46_production_stale_revision_is_refused(lab):
    mid, cid, uid = confirmed(lab, 'We guarantee profit.')
    with production_resolver(lab):
        context_id = build(lab, mid, cid).json()['context_id']
        answer(lab, mid, 'M2-04', 'A corrected declaration after confirmation.', 3)
        refused = build(lab, mid, cid, 409)
        assert isinstance(refused.json()['detail'], str)
        lab['request']('GET', f'/assessments/{mid}/business-contexts/{context_id}', 409)
        status = lab['request']('GET',
            f'/assessments/{mid}/confirmations/{cid}/business-context-status').json()
        assert status['source_is_current'] is False and status['status'] == 'PERSISTED'
    assert rows(lab, 'SELECT count(*) AS n FROM m2_business_contexts WHERE confirmation_id=:cid',
                {'cid': cid})[0]['n'] == 1


def test_PG47_production_missing_confirmed_description_holds(lab):
    mid = create(lab)
    answer(lab, mid, 'M2-01', 'SYNTHETIC_A', 0)
    answer(lab, mid, 'M2-05', 'TAKEAWAY_FOCUSED', 1)
    findings = lab['request']('POST', f'/assessments/{mid}/bdj/evaluate',
        json={'expected_revision': 2}).json()['findings']
    for finding in findings:
        lab['request']('POST', f"/assessments/{mid}/findings/{finding['id']}/decisions", json={
            'expected_revision': 2, 'request_id': str(uuid4()), 'decision': 'KEEP_ORIGINAL'})
    lab['request']('POST', f'/assessments/{mid}/review', json={'expected_revision': 2})
    cid = lab['request']('POST', f'/assessments/{mid}/confirm', json={
        'expected_revision': 2, 'acknowledged_issue_ids': [f['id'] for f in findings]}).json()['id']
    with production_resolver(lab):
        response = build(lab, mid, cid, 503, revision=2)
    assert response.json()['detail']['code'] == 'CONCEPT_DESCRIPTION_UNAVAILABLE'
    status = lab['request']('GET',
        f'/assessments/{mid}/confirmations/{cid}/business-context-status').json()
    assert status['status'] == 'HELD' and status['context_id'] is None
    assert status['last_code'] == 'CONCEPT_DESCRIPTION_UNAVAILABLE'
    assert rows(lab, 'SELECT count(*) AS n FROM m2_business_contexts WHERE confirmation_id=:cid',
                {'cid': cid})[0]['n'] == 0


def test_PG48_production_repeated_builds_are_idempotent(lab):
    mid, cid, uid = confirmed(lab, 'We guarantee profit.')
    with production_resolver(lab):
        first = build(lab, mid, cid).json()
        second = build(lab, mid, cid, 200).json()
        retrieved = lab['request']('GET',
            f"/assessments/{mid}/business-contexts/{first['context_id']}").json()
    assert second['replayed'] is True
    assert second['context_id'] == first['context_id'] == retrieved['context_id']
    assert second['created_at'] == first['created_at']
    assert second['packet'] == first['packet'] == retrieved['packet']
    assert rows(lab, 'SELECT count(*) AS n FROM m2_business_contexts WHERE confirmation_id=:cid',
                {'cid': cid})[0]['n'] == 1


# ---------------------------------------------------------------------------
# Task A: RLS-scoped restricted principal. Every test below drives the actual
# resolver; the session starts as the harness login and the resolver itself
# must switch to p1_m2_runtime before the first source read.
# ---------------------------------------------------------------------------

def _selection(mid, cid, revision=3):
    from sitewise.services.ports.business_context_store_port import ContextSelection
    return ContextSelection(UUID(mid), UUID(cid), revision)


def _actor(lab, uid=None):
    from sitewise.services.ports.business_context_store_port import ContextActor
    return ContextActor(uid or lab['actor'], 'entrepreneur')


def _resolver(session):
    # 90 days here is an explicit TEST value, not a product rule: production
    # composition has no default and refuses when the basis is absent.
    from sitewise.repositories.m2_context_bindings import M2ContextBindings
    return M2ContextBindings(session, validity=timedelta(days=90))


def test_PG49_restricted_principal_owner_reads_own_rows(lab):
    mid, cid, uid = confirmed(lab, 'We guarantee profit.')
    with Session(lab['db']) as session:
        before = session.execute(text('SELECT current_user')).scalar()
        assert before != 'p1_m2_runtime'  # harness login, not the runtime role
        inputs = _resolver(session).resolve(_selection(mid, cid), _actor(lab))
        current_user, rolsuper, rolbypassrls = session.execute(text(
            "SELECT current_user,"
            "(SELECT rolsuper FROM pg_roles WHERE rolname=current_user),"
            "(SELECT rolbypassrls FROM pg_roles WHERE rolname=current_user)")).one()
        # Evidence: the authorized owner read happened as the restricted role.
        assert current_user == 'p1_m2_runtime'
        assert rolsuper is False and rolbypassrls is False
        assert inputs.bindings['concept']['content']['description'] == 'We guarantee profit.'
        horizon = inputs.bindings['concept']['valid_until']
        assert isinstance(horizon, str) and horizon
        assert inputs.decision['valid_until'] == horizon
        evidence = {'session_user_before': before, 'current_user_during_resolve': current_user,
                    'rolsuper': rolsuper, 'rolbypassrls': rolbypassrls,
                    'principal': 'p1_m2_runtime', 'valid_until': horizon,
                    'scope': 'PRIVATE_SYNTHETIC_ONLY'}
    (Path(os.environ['M2_BCB_EVIDENCE']) / 'rls_principal_evidence.json').write_text(
        json.dumps(evidence, indent=2), encoding='utf-8')


def test_PG50_restricted_principal_other_owner_sees_zero_rows(lab):
    from sitewise.services.business_context_v1 import ContextRefused
    mid, cid, uid = confirmed(lab, 'We guarantee profit.')
    with Session(lab['db']) as session:
        with pytest.raises(ContextRefused) as refused:
            _resolver(session).resolve(_selection(mid, cid), _actor(lab, lab['other']))
        assert refused.value.code == 'ACCESS_DENIED'
        # The RLS predicate, not an application filter, is what hides the row.
        assert session.execute(text('SELECT count(*) FROM m2_assessments WHERE id=:id'),
                               {'id': mid}).scalar_one() == 0
        assert session.execute(text(
            'SELECT count(*) FROM m2_business_contexts WHERE confirmation_id=:id'),
            {'id': cid}).scalar_one() == 0


def test_PG51_role_without_grants_is_refused(lab):
    from sitewise.services.business_context_v1 import ContextRefused
    mid, cid, uid = confirmed(lab)
    with lab['db'].begin() as connection:
        connection.execute(text(
            'CREATE ROLE m2_bcb_no_grants NOLOGIN NOSUPERUSER NOBYPASSRLS'))
        connection.execute(text('GRANT USAGE ON SCHEMA public TO m2_bcb_no_grants'))
    with Session(lab['db']) as session:
        # A superuser session_user can always SET ROLE, so impersonate a real
        # non-superuser login here; membership is then enforced against it.
        session.execute(text('SET SESSION AUTHORIZATION m2_bcb_no_grants'))
        with pytest.raises(DBAPIError):  # no table grant: privilege denied
            session.execute(text('SELECT count(*) FROM m2_assessments'))
        session.rollback()
    with Session(lab['db']) as session:
        session.execute(text('SET SESSION AUTHORIZATION m2_bcb_no_grants'))
        with pytest.raises(ContextRefused) as refused:
            _resolver(session).resolve(_selection(mid, cid), _actor(lab))
        assert refused.value.code == 'RESTRICTED_PRINCIPAL_REQUIRED'


def test_PG52_privileged_effective_principal_is_refused(lab):
    from sitewise.services.business_context_v1 import ContextRefused
    mid, cid, uid = confirmed(lab)
    with lab['db'].begin() as connection:
        connection.execute(text('ALTER ROLE p1_m2_runtime BYPASSRLS'))
    try:
        with Session(lab['db']) as session:
            with pytest.raises(ContextRefused) as refused:
                _resolver(session).resolve(_selection(mid, cid), _actor(lab))
            assert refused.value.code == 'RESTRICTED_PRINCIPAL_REQUIRED'
        # The composed production path refuses too instead of building a
        # context through a privileged principal.
        with production_resolver(lab):
            response = build(lab, mid, cid, 503)
        assert response.json()['detail']['code'] == 'BCB_PERSISTENCE_UNAVAILABLE'
    finally:
        with lab['db'].begin() as connection:
            connection.execute(text('ALTER ROLE p1_m2_runtime NOBYPASSRLS'))


# ---------------------------------------------------------------------------
# Task B: the validity window is an explicit input, never an invented default.
# ---------------------------------------------------------------------------

def test_PG53_absent_validity_basis_fails_closed(lab):
    from sitewise import dependencies as deps
    from sitewise.repositories.m2_context_bindings import M2ContextBindings
    mid, cid, uid = confirmed(lab)
    override = lab['app'].dependency_overrides.pop(deps.get_bcb_bindings_resolver_factory)
    lab['app'].dependency_overrides[deps.get_bcb_bindings_resolver_factory] = (
        lambda: M2ContextBindings)  # no validity basis supplied
    try:
        response = build(lab, mid, cid, 409)
        assert response.json()['detail']['code'] == 'VALIDITY_BASIS_UNAUTHORIZED'
        status = lab['request']('GET',
            f'/assessments/{mid}/confirmations/{cid}/business-context-status').json()
        assert status['status'] == 'HELD' and status['context_id'] is None
        assert status['last_code'] == 'VALIDITY_BASIS_UNAUTHORIZED'
        assert rows(lab, 'SELECT count(*) AS n FROM m2_business_contexts '
                    'WHERE confirmation_id=:cid', {'cid': cid})[0]['n'] == 0
    finally:
        lab['app'].dependency_overrides[deps.get_bcb_bindings_resolver_factory] = override


def test_PG54_freshness_refusals_still_fire(lab):
    mid, cid, uid = confirmed(lab)
    bindings = bind(lab, mid, cid, uid)
    context_id = build(lab, mid, cid).json()['context_id']

    def store(value):
        with lab['db'].begin() as connection:
            connection.execute(text('UPDATE test_bcb_bindings SET bindings_json=CAST(:b AS jsonb) '
                'WHERE confirmation_id=:id'), {'b': json.dumps(value), 'id': cid})

    expired_concept = json.loads(json.dumps(bindings))
    expired_concept['concept']['valid_until'] = '2000-01-01T00:00:00+00:00'
    store(expired_concept)
    refused = lab['request']('GET', f'/assessments/{mid}/business-contexts/{context_id}', 409)
    assert refused.json()['detail']['code'] == 'CONCEPT_STALE'

    template = json.loads((Path(__file__).parents[1] / 'project1/bcb/fixtures/'
                           'valid_confirmed.json').read_text())['bindings']['sources'][0]
    expired_source = json.loads(json.dumps(bindings))
    template.update(tenant_id=bindings['concept']['tenant_id'], assessment_id=mid,
                    allowed_viewers=[str(lab['actor'])],
                    valid_until='2000-01-01T00:00:00+00:00')
    expired_source['sources'] = [template]
    store(expired_source)
    refused = lab['request']('GET', f'/assessments/{mid}/business-contexts/{context_id}', 409)
    assert refused.json()['detail']['code'] == 'SOURCE_STALE'
    store(bindings)


def test_PG55_confirmation_not_current_is_still_refused(lab):
    from sitewise.repositories.m2_context_bindings import M2OwnershipAuthorization
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    from sitewise.services.ports.business_context_v1_port import ContextRequest
    mid, cid, uid = confirmed(lab)
    with Session(lab['db']) as session:
        authorization = M2OwnershipAuthorization(
            SqlModelM2Repository(session), validity=timedelta(days=90))
        decision = authorization.authorize(ContextRequest(
            viewer_id=lab['actor'], tenant_id='m2-owner:' + str(lab['actor']),
            role='entrepreneur', assessment_id=UUID(mid), purpose='EXPLANATION',
            confirmation_id=UUID(cid), confirmed_revision=2,
            concept_version='M2-CONFIRMED-2-synthetic'))
    assert decision == {'allowed': False, 'reason': 'CONFIRMATION_NOT_CURRENT'}
