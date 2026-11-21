"""Connected chain: Confirmed M2 -> deterministic BDJ -> BCB -> QJ interface.

Every function here runs inside the disposable PostgreSQL cluster created by
``run_isolated.py`` and is imported by ``test_postgres_api.py`` so the existing
runner executes it unchanged.

What is production-real in this module
--------------------------------------
* the assessment, answers, findings, confirmation and uncertainty rows are real
  PostgreSQL rows written through the FastAPI surface;
* reads are executed as ``p1_m2_runtime`` (NOSUPERUSER / NOBYPASSRLS) with
  ``project1.actor_id`` set, so the owner policies actually apply;
* ``BDJEngine`` is driven by the real ``sitewise.domain.bdj_candidate_rules``
  module and its sha256 fingerprint is asserted, with no model runner;
* ``BusinessContextBuilderV1`` builds and persists the packet under the real
  ``BCB-V1-1.1.0`` contract;
* ``sitewise.project1.research.checked_context`` is the real QJ admission gate.

What is a harness double (and is labelled as such at the call site)
------------------------------------------------------------------
* the BDJ "adoption receipt" string -- it only satisfies the load gate; the
  ruleset identity is established by the sha256 fingerprint;
* QJ's ``authority``, ``bank`` and ``runner`` ports -- no research approval, no
  QJ model call, no bank adoption is claimed or exercised;
* the QJ builder adapter wraps an already-persisted packet instead of
  re-entering the HTTP route.
"""
import json
import os
from pathlib import Path
from types import SimpleNamespace
from uuid import UUID

import pytest
from sqlalchemy import text
from sqlalchemy.orm import Session

from test_postgres_api import answer, bind, build, confirmed, create, lab  # noqa: F401
from production_binding_checks import (  # noqa: F401
    _actor, _resolver, _selection, production_resolver, rows,
)

#: The ruleset the product code path actually imports (``bdj_service`` imports
#: this module by name) and the fingerprint its loader pins.
RULESET_VERSION = 'BDJ-RULESET-0.2-CAND'
RULESET_SHA256 = '42f7fef3bf2bb48255ab8eac406dfb8232923b76789dd065d693732e8bf2a061'

#: The owner-policy principal and the schema version under test.
RESTRICTED_ROLE = 'p1_m2_runtime'
BCB_CONTRACT = 'BCB-V1-1.1.0'
BCB_SCHEMA = 'business-context-package/1.1'

#: Declarations that make the real ruleset fire exactly one candidate.
PROFIT_CLAIM = 'We guarantee profit.'
#: Declarations the real ruleset legitimately leaves alone (zero findings).
NEUTRAL_CLAIM = 'A fictional cafe serving drinks.'


def _evidence(name, payload):
    """Write lab evidence beside the other runner artefacts (never inside backend)."""
    path = Path(os.environ['M2_BCB_EVIDENCE']) / name
    path.write_text(json.dumps(payload, indent=2, default=str), encoding='utf-8')
    return payload


def _restricted_identity(session, actor):
    """Switch this transaction to the restricted principal and set the owner GUC."""
    from sitewise.repositories.m2_context_bindings import bind_restricted_principal
    bind_restricted_principal(session, actor)
    return session.execute(text(
        "SELECT current_user,"
        "(SELECT rolsuper FROM pg_roles WHERE rolname=current_user),"
        "(SELECT rolbypassrls FROM pg_roles WHERE rolname=current_user)")).one()


def _projection(lab, mid, actor, revision):
    """Read the real M2 source packet as the restricted principal."""
    from sitewise.project1.projection import M2SourceProjection
    from sitewise.repositories.m2_repository import SqlModelM2Repository
    with Session(lab['db']) as session:
        _restricted_identity(session, actor)
        return M2SourceProjection(SqlModelM2Repository(session)).read(
            UUID(mid), actor, revision)


def _deterministic_bdj(lab, mid, actor, revision):
    """Evaluate the packet with the real ruleset. No model runner is supplied."""
    from sitewise.project1.bdj import BDJEngine, load_rules
    # The receipt is a TEST string: it only satisfies the loader gate. The
    # ruleset identity itself is the sha256 fingerprint asserted below.
    rules = load_rules(RULESET_VERSION, RULESET_SHA256, 'SYNTHETIC-PRIVATE-LAB-ONLY')
    packet = _projection(lab, mid, actor, revision)
    result = BDJEngine(rules=rules).review(
        packet,
        # A genuine re-read of the persisted revision, not a constant stub.
        recheck_current=lambda: _projection(lab, mid, actor, revision)['source_fingerprint'])
    return packet, result, rules


def _qj_builder(packet):
    """HARNESS DOUBLE: QJ's builder port over an already-persisted packet."""
    return SimpleNamespace(get_context=lambda _request: packet)


def _qj_ports(uncertainty_id, measurement):
    """Authority, bank and runner ports for QJ/measurement only.

    The authority is the real versioned policy (``measurement_policy.lab_authority``),
    not a no-op double: since the receipt-verification change, a survey candidate
    cannot be produced without a verifiable validation receipt, so a double here
    would only prove the refusal path. The bank remains a double, because no
    production bank exists yet (BD-01 Option B is prepared, not applied).

    No research approval, QJ model call, QG drafting or bank adoption happens.
    """
    from sitewise.project1.measurement_policy import lab_authority

    authority = lab_authority()

    class Bank:
        def lookup(self, *_args):
            return {'outcome': 'verified_equivalent', 'item_version': 'SYNTHETIC-Q1@1',
                    'approval_receipt': 'SYNTHETIC-PRIVATE-LAB-ONLY',
                    'scope': 'SYNTHETIC_PRIVATE_LAB_ONLY'}

        def verify_receipt(self, *_args):
            pass

    calls = []

    def runner(stage, _packet, _output_type):
        calls.append(stage)
        assert stage == 'QJ'
        return {'route': 'CUSTOMER_SURVEY_CANDIDATE',
                'justification': 'SYNTHETIC lab fixture; not a research decision.',
                'measurement': measurement}

    return authority, Bank(), runner, calls


# ---------------------------------------------------------------------------
# CC1: a confirmed M2 assessment is readable by its owner as p1_m2_runtime.
# ---------------------------------------------------------------------------

def test_CC1_confirmed_M2_is_owner_readable_under_restricted_principal(lab):
    mid, cid, uid = confirmed(lab, PROFIT_CLAIM)
    with Session(lab['db']) as session:
        before = session.execute(text('SELECT current_user')).scalar()
        current_user, rolsuper, rolbypassrls = _restricted_identity(session, lab['actor'])
        assessment = session.execute(text(
            'SELECT id::text, owner_user_id::text, revision, confirmed_revision '
            'FROM m2_assessments WHERE id=:id'), {'id': mid}).mappings().first()
        confirmation = session.execute(text(
            'SELECT id::text, assessment_revision, snapshot_digest '
            'FROM m2_confirmation_snapshots WHERE id=:id'), {'id': cid}).mappings().first()
        revisions = session.execute(text(
            'SELECT count(*) FROM m2_answer_revisions WHERE assessment_id=:id'),
            {'id': mid}).scalar_one()
        findings = session.execute(text(
            'SELECT count(*) FROM m2_bdj_findings WHERE assessment_id=:id '
            'AND assessment_revision=3'), {'id': mid}).scalar_one()
        # Evidence first: the read really happened as the restricted role.
        assert current_user == RESTRICTED_ROLE
        assert rolsuper is False and rolbypassrls is False
        assert before != RESTRICTED_ROLE  # harness login, not the runtime role
        assert assessment is not None
        assert assessment['owner_user_id'] == str(lab['actor'])
        assert (assessment['revision'], assessment['confirmed_revision']) == (3, 3)
        assert confirmation is not None and confirmation['assessment_revision'] == 3
        assert len(confirmation['snapshot_digest']) == 64
        assert revisions == 3 and findings == 1
        _evidence('connected_chain_cc1.json', {
            'session_user_before': before, 'current_user': current_user,
            'rolsuper': rolsuper, 'rolbypassrls': rolbypassrls,
            'principal': RESTRICTED_ROLE, 'assessment_id': mid, 'confirmation_id': cid,
            'assessment_revision': 3, 'confirmed_revision': 3,
            'answer_revisions': revisions, 'bdj_findings_at_revision': findings,
            'scope': 'PRIVATE_SYNTHETIC_ONLY'})


# ---------------------------------------------------------------------------
# CC2: deterministic BDJ over that confirmed data with the real ruleset.
# ---------------------------------------------------------------------------

def test_CC2_deterministic_BDJ_evaluates_confirmed_data_with_real_ruleset(lab):
    import hashlib
    from sitewise.domain import bdj_candidate_rules as rules_module
    from sitewise.project1.bdj import validate_candidates

    assert hashlib.sha256(Path(rules_module.__file__).read_bytes()).hexdigest() == RULESET_SHA256
    assert rules_module.RULE_VERSION == RULESET_VERSION

    mid, cid, uid = confirmed(lab, PROFIT_CLAIM)
    packet, result, rules = _deterministic_bdj(lab, mid, lab['actor'], 3)
    assert result['outcome'] == 'reviewed'
    checkpoints = {e['checkpoint']: e for e in result['checkpoints']}
    assert checkpoints[1]['outcome'] == 'verified'
    assert checkpoints[2]['outcome'] == 'checked'
    assert checkpoints[2]['rule_version'] == RULESET_VERSION
    # No model runner was supplied: the engine's own deterministic output stands.
    assert checkpoints[3]['outcome'] == 'not_called'
    assert checkpoints[4]['outcome'] == 'checked'
    assert checkpoints[5]['outcome'] == 'review_required'
    assert result['finding_authority'] == 'CANDIDATE_ONLY'

    findings = result['findings']
    assert len(findings) == 1
    assert findings[0]['rule_id'] == 'UNSUPPORTED_PROFIT_GUARANTEE'
    assert findings[0]['kind'] == 'UNSUPPORTED_ASSERTION'
    assert [r['item_key'] for r in findings[0]['source_refs']] == ['M2-04']

    # The engine's output is re-admitted through the real validator against the
    # ruleset's own registered vocabulary.
    answers = {d['item_key']: {'id': d['answer_revision_id'],
                              'answer_state': d['answer_state'], 'value_json': d['value']}
               for d in packet['declarations']}
    allowed = {p['rule_id'] for p in rules.evaluate_candidate_issues(answers)}
    assert allowed == {'UNSUPPORTED_PROFIT_GUARANTEE'}
    validated = validate_candidates(
        {'issues': findings, 'overall_note': 'Deterministic candidate checks only.'},
        packet, allowed)
    assert [i.rule_id for i in validated.issues] == ['UNSUPPORTED_PROFIT_GUARANTEE']

    # The deterministic result agrees with what the product path persisted.
    persisted = rows(lab, 'SELECT rule_id, rule_version, issue_type FROM m2_bdj_findings '
                          'WHERE assessment_id=:mid AND assessment_revision=3 ORDER BY rule_id',
                     {'mid': mid})
    assert persisted == [{'rule_id': 'UNSUPPORTED_PROFIT_GUARANTEE',
                          'rule_version': RULESET_VERSION,
                          'issue_type': 'CLAIM_REQUIRES_VERIFICATION'}]

    # Zero findings is a real, reachable outcome of the same ruleset.
    quiet_mid, quiet_cid, quiet_uid = confirmed(lab, NEUTRAL_CLAIM)
    _, quiet, _ = _deterministic_bdj(lab, quiet_mid, lab['actor'], 3)
    assert quiet['outcome'] == 'reviewed' and quiet['findings'] == []
    assert {e['checkpoint']: e['outcome'] for e in quiet['checkpoints']}[5] == 'bounded_no_issue'

    _evidence('connected_chain_cc2.json', {
        'ruleset_version': RULESET_VERSION, 'ruleset_sha256': RULESET_SHA256,
        'model_runner': 'absent', 'assessment_id': mid, 'revision': 3,
        'outcome': result['outcome'], 'finding_count': len(findings),
        'finding_rule_ids': [f['rule_id'] for f in findings],
        'persisted_findings': persisted,
        'zero_finding_control': {'assessment_id': quiet_mid,
                                 'outcome': quiet['outcome'],
                                 'finding_count': len(quiet['findings'])}})


# ---------------------------------------------------------------------------
# CC3: BCB builds a 1.1 context from the same revision and carries the findings.
# ---------------------------------------------------------------------------

def test_CC3_BCB_builds_contract_1_1_context_without_geo_and_with_findings(lab):
    mid, cid, uid = confirmed(lab, PROFIT_CLAIM)
    _, deterministic, _ = _deterministic_bdj(lab, mid, lab['actor'], 3)
    with production_resolver(lab):
        response = build(lab, mid, cid)
    assert response.status_code == 201
    body = response.json()
    packet = body['packet']
    assert packet['context_version'] == BCB_CONTRACT
    assert packet['schema_version'] == BCB_SCHEMA
    assert packet['confirmation']['status'] == 'CURRENT_CONFIRMED'
    assert packet['confirmation']['id'] == cid
    assert packet['identity'] == {'assessment_id': mid,
                                  'tenant_id': 'm2-owner:' + str(lab['actor']),
                                  'owner_id': str(lab['actor'])}
    # BCB-V1-1.1.0 excludes GEO: the slot is null and no catalogue is bound.
    assert packet['geography'] is None
    assert 'GEO_V1' not in json.dumps(packet)
    assert not any('approved context identity' in line for line in packet['limitations'])
    # The contract itself, not a caller convention, is what drops GEO authority.
    from sitewise.services.business_context_v1 import CONTRACTS, CURRENT_CONTEXT_VERSION
    assert CURRENT_CONTEXT_VERSION == BCB_CONTRACT
    assert CONTRACTS[BCB_CONTRACT][1] is False  # requires_geography
    assert all(value is False for value in packet['permissions'].values())
    # The context carries exactly the deterministic findings for this revision.
    assert len(packet['findings']) == len(deterministic['findings']) == 1
    assert [f['rule_id'] for f in packet['findings']] == [
        f['rule_id'] for f in deterministic['findings']]
    for finding in packet['findings']:
        assert finding['rule_version'] == RULESET_VERSION
        assert finding['review_state'] == 'CANDIDATE'
        assert finding['authority_reference'] is None
        assert finding['business_facts_verified'] is False
        assert finding['report_admitted'] is False
    assert packet['provenance']['bindings_hash']
    stored = rows(lab, 'SELECT builder_version, schema_version, tenant_id, concept_version, '
                       'packet_hash FROM m2_business_contexts WHERE confirmation_id=:cid',
                  {'cid': cid})
    assert len(stored) == 1
    assert stored[0]['builder_version'] == BCB_CONTRACT
    assert stored[0]['schema_version'] == BCB_SCHEMA
    assert stored[0]['packet_hash'] == packet['packet_hash']
    _evidence('connected_chain_cc3.json', {
        'context_id': body['context_id'], 'context_version': packet['context_version'],
        'schema_version': packet['schema_version'], 'geography': packet['geography'],
        'finding_rule_ids': [f['rule_id'] for f in packet['findings']],
        'finding_count': len(packet['findings']),
        'stored': stored[0]})


# ---------------------------------------------------------------------------
# CC4: QJ's checked_context accepts that real BCB context (interface only).
# ---------------------------------------------------------------------------

def test_CC4_qj_checked_context_accepts_real_BCB_context_interface_only(lab):
    from sitewise.project1.contracts import no_authority
    from sitewise.project1.research import ResearchWorkflow, checked_context

    mid, cid, uid = confirmed(lab, PROFIT_CLAIM)
    with production_resolver(lab):
        packet = build(lab, mid, cid).json()['packet']

    # The real admission gate accepts the real packet and returns it unchanged.
    accepted = checked_context(_qj_builder(packet), None)
    assert accepted is packet
    assert accepted['confirmation']['status'] == 'CURRENT_CONFIRMED'
    assert accepted['confirmed_uncertainty']['id'] == uid
    # No restricted item is present, so QJ's membership guard is not what blocks.
    assert not {a['item_key'] for a in accepted['m2_answers']} & {
        'M2-11', 'M2-15', 'M2-20', 'M2-21'}

    # HARNESS DOUBLES below: authority, bank and runner. The measurement step
    # uses the real validate_measurement() against the real packet.
    measurement = {
        'uncertainty_version': uid, 'construct': 'stated preference',
        'population': 'adults in the planned trade area', 'timeframe': 'next month',
        'stimulus': 'the proposed cafe format', 'response_options': ['Prefer', 'Unsure'],
        'response_codes': ['P', 'U'], 'routing': {'P': 'END', 'U': 'END'},
        'denominator': 'all eligible respondents', 'source_refs': [uid],
        'limitations': 'SYNTHETIC interface fixture; no fielding is authorised.'}
    authority, bank, runner, calls = _qj_ports(uid, measurement)
    workflow = ResearchWorkflow(_qj_builder(packet), authority, bank, runner)
    result = workflow.execute(None)

    assert calls == ['QJ']  # the QJ code path was entered exactly once
    assert result['qj']['route'] == 'CUSTOMER_SURVEY_CANDIDATE'
    assert result['source_fingerprint'] == packet['packet_hash']
    assert result['bank'] == 'verified_equivalent'
    assert result['qg'] == {'decision': 'REUSE_CANDIDATE', 'item_version': 'SYNTHETIC-Q1@1'}
    # No authority is conferred by passing the gate.
    denied = no_authority()
    assert all(result[key] is False for key in denied)

    _evidence('connected_chain_cc4.json', {
        'qj_input': 'BCB packet persisted under ' + packet['context_version'],
        'checked_context': 'ACCEPTED', 'qj_route': result['qj']['route'],
        'runner_calls': calls, 'bank_outcome': result['bank'],
        'qg_decision': result['qg']['decision'],
        'authority': 'HARNESS DOUBLE - no research approval claimed',
        'bank': 'HARNESS DOUBLE - no bank adoption claimed',
        'runner': 'HARNESS DOUBLE - no QJ model call made',
        'packet_hash': packet['packet_hash']})


# ---------------------------------------------------------------------------
# CC5: QJ refuses when the confirmed uncertainty is absent (fail-closed).
# ---------------------------------------------------------------------------

def test_CC5_qj_refuses_when_confirmed_uncertainty_is_absent(lab):
    from sitewise.project1.contracts import WorkflowHeld
    from sitewise.project1.research import ResearchWorkflow, checked_context

    mid, cid, uid = confirmed(lab, PROFIT_CLAIM, uncertainty=False)
    assert uid is None
    assert rows(lab, 'SELECT count(*) AS n FROM m2_confirmed_uncertainties '
                     'WHERE confirmation_id=:cid', {'cid': cid})[0]['n'] == 0
    with production_resolver(lab):
        packet = build(lab, mid, cid).json()['packet']
    # BCB legitimately builds and records the gap instead of inventing a text.
    assert packet['confirmed_uncertainty'] is None
    assert any(u['code'] == 'UNCERTAINTY_NOT_CONFIRMED' for u in packet['unknowns'])

    with pytest.raises(WorkflowHeld) as refused:
        checked_context(_qj_builder(packet), None)
    assert str(refused.value) == 'UNCERTAINTY_NOT_CONFIRMED'

    # The whole workflow refuses before QJ is ever dispatched.
    authority, bank, runner, calls = _qj_ports(str(UUID(int=0)), None)
    workflow = ResearchWorkflow(_qj_builder(packet), authority, bank, runner)
    with pytest.raises(WorkflowHeld) as stopped:
        workflow.execute(None)
    assert str(stopped.value) == 'UNCERTAINTY_NOT_CONFIRMED'
    assert calls == []
    _evidence('connected_chain_cc5.json', {
        'assessment_id': mid, 'confirmation_id': cid,
        'confirmed_uncertainty_rows': 0, 'packet_confirmed_uncertainty': None,
        'refusal_code': str(stopped.value), 'runner_calls': calls})


# ---------------------------------------------------------------------------
# CC6: cross-owner isolation holds across the whole chain.
# ---------------------------------------------------------------------------

def test_CC6_cross_owner_cannot_reach_assessment_context_or_qj_input(lab):
    from sitewise.services.business_context_v1 import ContextRefused

    mid, cid, uid = confirmed(lab, PROFIT_CLAIM)
    with production_resolver(lab):
        body = build(lab, mid, cid).json()
    context_id = body['context_id']
    packet_hash = body['packet']['packet_hash']

    # Application surface: another owner is indistinguishable from a non-owner.
    lab['request']('GET', f'/assessments/{mid}', 404, uid=lab['other'])
    lab['request']('GET', f'/assessments/{mid}/business-contexts/{context_id}', 404,
                   uid=lab['other'])
    lab['request']('POST', f'/assessments/{mid}/business-context', 404, uid=lab['other'],
                   json={'confirmation_id': cid, 'expected_revision': 3})
    # The owner is still served: refusal is authorization, not breakage.
    assert lab['request']('GET', f'/assessments/{mid}').status_code == 200

    # The QJ input port itself refuses: no context can be resolved for another owner.
    with Session(lab['db']) as session:
        with pytest.raises(ContextRefused) as refused:
            _resolver(session).resolve(_selection(mid, cid), _actor(lab, lab['other']))
        assert refused.value.code == 'ACCESS_DENIED'

    # Row-level security, not an application filter, is what hides the chain.
    # Each probe targets the real key of its own row, so a zero is an RLS result
    # rather than a lookup that could never have matched.
    probes = {
        'm2_assessments': ('SELECT count(*) FROM m2_assessments WHERE id=:key', mid),
        'm2_answer_revisions': (
            'SELECT count(*) FROM m2_answer_revisions WHERE assessment_id=:key', mid),
        'm2_confirmation_snapshots': (
            'SELECT count(*) FROM m2_confirmation_snapshots WHERE id=:key', cid),
        'm2_confirmed_uncertainties': (
            'SELECT count(*) FROM m2_confirmed_uncertainties WHERE id=:key', uid),
        'm2_business_contexts': (
            'SELECT count(*) FROM m2_business_contexts WHERE assessment_id=:key', mid),
    }
    with Session(lab['db']) as session:
        current_user, rolsuper, rolbypassrls = _restricted_identity(session, lab['other'])
        hidden = {name: session.execute(text(statement), {'key': key}).scalar_one()
                  for name, (statement, key) in probes.items()}
        assert hidden == dict.fromkeys(probes, 0), hidden
        assert current_user == RESTRICTED_ROLE
        assert rolsuper is False and rolbypassrls is False
        # The rows do exist for the owner, so the zeroes above are RLS, not absence.
        _restricted_identity(session, lab['actor'])
        owner_counts = {name: session.execute(text(statement), {'key': key}).scalar_one()
                        for name, (statement, key) in probes.items()}
        assert owner_counts == {'m2_assessments': 1, 'm2_answer_revisions': 3,
                               'm2_confirmation_snapshots': 1,
                               'm2_confirmed_uncertainties': 1,
                               'm2_business_contexts': 1}, owner_counts
    _evidence('connected_chain_cc6.json', {
        'other_owner': str(lab['other']), 'owner': str(lab['actor']),
        'assessment_id': mid, 'context_id': context_id, 'packet_hash': packet_hash,
        'hidden_for_other': hidden, 'visible_for_owner': owner_counts,
        'qj_input_refusal': 'ACCESS_DENIED', 'principal': RESTRICTED_ROLE})
