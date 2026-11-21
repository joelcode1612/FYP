"""Pure contract tests for the synthetic-only disclosure predicate.

These run without a database on purpose. `validate_synthetic()` exists so the
*whole* disclosure decision can be made before a `project1_ai.runs` row is
created; if these tests needed a clone they would skip in CI and the ordering
guarantee would be untested exactly where it matters.

The ordering matters because `project1_ai.runs` is append-only
(`deny_mutation()` refuses DELETE): a disclosure refusal that happens after
provisioning leaves an orphan row that no later code can remove. Before this
predicate existed, only two of the ten conditions were checked pre-provisioning
and the other eight fired at dispatch — after the row already existed.
"""
import pytest

from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.disclosure import (
    QG_PURPOSE, QG_SCHEMA_VERSION, SyntheticBdjAuthorization,
    SyntheticBdjDisclosure, SyntheticQgAuthorization, SyntheticQgDisclosure,
    validate_synthetic,
)
from sitewise.project1.provider import ENDPOINT, MODEL

PACKET = {
    'schema_version': 'project1-m2-projection/1-candidate',
    'source_fingerprint': 'f' * 64,
}

VALID = dict(
    data_class='SYNTHETIC_NONHUMAN',
    purpose='SYNTHETIC_BDJ_DIAGNOSTIC',
    stage='BDJ',
    endpoint=ENDPOINT,
    model=MODEL,
    max_attempts=1,
    operator_receipt='CP04A-TEST-RECEIPT',
    source_fingerprint='f' * 64,
    packet=PACKET,
)


def refusal(**overrides):
    """The code `validate_synthetic` raises for these overrides, or None."""
    kwargs = {**VALID, **overrides}
    try:
        validate_synthetic(**kwargs)
    except WorkflowHeld as exc:
        return str(exc)
    return None


def test_valid_authorization_is_accepted():
    assert refusal() is None


def test_real_data_is_refused():
    assert refusal(data_class='REAL_PERSONAL') == 'DISCLOSURE_REAL_DATA_NOT_AUTHORIZED'


def test_wrong_purpose_is_refused():
    assert refusal(purpose='MARKETING') == 'DISCLOSURE_PURPOSE_MISMATCH'


def test_wrong_stage_is_refused():
    assert refusal(stage='CQ') == 'DISCLOSURE_STAGE_NOT_AUTHORIZED'


def test_wrong_expected_stage_is_refused():
    # The dispatch site passes its own stage; a mismatch either way is refused.
    assert refusal(expected_stage='CQ') == 'DISCLOSURE_STAGE_NOT_AUTHORIZED'


def test_wrong_endpoint_is_refused():
    assert refusal(endpoint='https://elsewhere.example/v1') == 'DISCLOSURE_ENDPOINT_MISMATCH'


def test_wrong_model_is_refused():
    assert refusal(model='some-other-model') == 'DISCLOSURE_MODEL_MISMATCH'


def test_budget_other_than_one_is_refused():
    assert refusal(max_attempts=2) == 'DISCLOSURE_BUDGET_INVALID'


def test_missing_receipt_is_refused():
    assert refusal(operator_receipt='') == 'DISCLOSURE_RECEIPT_REQUIRED'


def test_short_receipt_is_refused():
    assert refusal(operator_receipt='short') == 'DISCLOSURE_RECEIPT_REQUIRED'


def test_non_candidate_projection_is_refused():
    packet = {**PACKET, 'schema_version': 'project1-m2-projection/2-final'}
    assert refusal(packet=packet) == 'DISCLOSURE_SOURCE_CLASS_INVALID'


def test_missing_schema_version_is_refused():
    assert refusal(packet={'source_fingerprint': 'f' * 64}) == \
        'DISCLOSURE_SOURCE_CLASS_INVALID'


def test_fingerprint_mismatch_is_refused():
    assert refusal(source_fingerprint='a' * 64) == 'DISCLOSURE_SOURCE_MISMATCH'


def test_all_ten_codes_are_reachable_from_this_predicate():
    """Every DISCLOSURE_* code the system can raise is decided here.

    If a code is added to the disclosure path without being added to
    `validate_synthetic`, it becomes a post-provisioning refusal again and this
    test is the only thing that notices.
    """
    reached = {
        refusal(data_class='REAL_PERSONAL'),
        refusal(purpose='X'),
        refusal(stage='X'),
        refusal(endpoint='X'),
        refusal(model='X'),
        refusal(max_attempts=9),
        refusal(operator_receipt=''),
        refusal(packet={'source_fingerprint': 'f' * 64}),
        refusal(source_fingerprint='a' * 64),
    }
    assert reached == {
        'DISCLOSURE_REAL_DATA_NOT_AUTHORIZED',
        'DISCLOSURE_PURPOSE_MISMATCH',
        'DISCLOSURE_STAGE_NOT_AUTHORIZED',
        'DISCLOSURE_ENDPOINT_MISMATCH',
        'DISCLOSURE_MODEL_MISMATCH',
        'DISCLOSURE_BUDGET_INVALID',
        'DISCLOSURE_RECEIPT_REQUIRED',
        'DISCLOSURE_SOURCE_CLASS_INVALID',
        'DISCLOSURE_SOURCE_MISMATCH',
    }


# --- the dispatch port must not accept an unbound authorization -------------
def _authorization(run_id):
    return SyntheticBdjAuthorization(
        run_id=run_id, source_fingerprint='f' * 64,
        operator_receipt='CP04A-TEST-RECEIPT')


def test_dispatch_refuses_an_unbound_authorization():
    disclosure = SyntheticBdjDisclosure(_authorization(''))
    try:
        disclosure.require_current('BDJ', PACKET, ENDPOINT, MODEL)
    except WorkflowHeld as exc:
        assert str(exc) == 'DISCLOSURE_AUTHORIZATION_INVALID'
    else:
        raise AssertionError('an unbound authorization was accepted at dispatch')


def test_dispatch_accepts_a_bound_authorization():
    disclosure = SyntheticBdjDisclosure(_authorization('run-1'))
    disclosure.require_current('BDJ', PACKET, ENDPOINT, MODEL)


def test_dispatch_refuses_the_same_conditions_as_the_preflight():
    """require_current delegates, so preflight and dispatch cannot drift."""
    disclosure = SyntheticBdjDisclosure(_authorization('run-1'))
    packet = {**PACKET, 'schema_version': 'project1-m2-projection/2-final'}
    try:
        disclosure.require_current('BDJ', packet, ENDPOINT, MODEL)
    except WorkflowHeld as exc:
        assert str(exc) == 'DISCLOSURE_SOURCE_CLASS_INVALID'
    else:
        raise AssertionError('dispatch accepted a non-candidate projection')


# --- CP-08: a separately identified QG disclosure -------------------------
QG_PACKET = {
    'schema_version': QG_SCHEMA_VERSION,
    'source_fingerprint': 'f' * 64,
}


def _qg_authorization(run_id='run-qg-1', **overrides):
    kwargs = dict(run_id=run_id, source_fingerprint='f' * 64,
                  operator_receipt='CP08-TEST-RECEIPT')
    kwargs.update(overrides)
    return SyntheticQgAuthorization(**kwargs)


def _qg_disclosure(**overrides):
    return SyntheticQgDisclosure(_qg_authorization(**overrides))


def test_valid_qg_authorization_is_accepted():
    _qg_disclosure().require_current('QG', QG_PACKET, ENDPOINT, MODEL)


def test_qg_stage_is_authoritative_on_both_sides():
    """A QG authorization must not be dispatched as BDJ, or vice versa."""
    with pytest.raises(WorkflowHeld, match='DISCLOSURE_STAGE_NOT_AUTHORIZED'):
        _qg_disclosure().require_current('BDJ', QG_PACKET, ENDPOINT, MODEL)
    with pytest.raises(WorkflowHeld, match='DISCLOSURE_STAGE_NOT_AUTHORIZED'):
        _qg_disclosure(stage='BDJ').require_current('QG', QG_PACKET, ENDPOINT, MODEL)


@pytest.mark.parametrize('stage', ['BDJ', 'QJ'])
def test_qg_disclosure_refuses_a_non_qg_stage(stage):
    """The dispatch stage is bound to QG; BDJ and QJ are refused."""
    with pytest.raises(WorkflowHeld, match='DISCLOSURE_STAGE_NOT_AUTHORIZED'):
        _qg_disclosure().require_current(stage, QG_PACKET, ENDPOINT, MODEL)


def test_qg_disclosure_refuses_real_data():
    with pytest.raises(WorkflowHeld, match='DISCLOSURE_REAL_DATA_NOT_AUTHORIZED'):
        _qg_disclosure(data_class='REAL_PERSONAL').require_current(
            'QG', QG_PACKET, ENDPOINT, MODEL)


def test_qg_disclosure_refuses_a_non_research_purpose():
    with pytest.raises(WorkflowHeld, match='DISCLOSURE_PURPOSE_MISMATCH'):
        _qg_disclosure(purpose='MARKETING').require_current(
            'QG', QG_PACKET, ENDPOINT, MODEL)


def test_qg_disclosure_refuses_a_bdj_projection_schema():
    """A BDJ M2 projection cannot be relabelled as QG input."""
    with pytest.raises(WorkflowHeld, match='DISCLOSURE_SOURCE_CLASS_INVALID'):
        _qg_disclosure().require_current('QG', PACKET, ENDPOINT, MODEL)


def test_qg_disclosure_refuses_a_fingerprint_mismatch():
    with pytest.raises(WorkflowHeld, match='DISCLOSURE_SOURCE_MISMATCH'):
        _qg_disclosure(source_fingerprint='a' * 64).require_current(
            'QG', QG_PACKET, ENDPOINT, MODEL)


def test_qg_dispatch_refuses_an_unbound_authorization():
    with pytest.raises(WorkflowHeld, match='DISCLOSURE_AUTHORIZATION_INVALID'):
        SyntheticQgDisclosure(_qg_authorization(run_id='')).require_current(
            'QG', QG_PACKET, ENDPOINT, MODEL)


def test_qg_dispatch_refuses_a_bdj_authorization_type():
    """require_current validates the authorization type exactly like the BDJ port."""
    with pytest.raises(WorkflowHeld, match='DISCLOSURE_AUTHORIZATION_INVALID'):
        SyntheticQgDisclosure(_authorization('run-bdj')).require_current(
            'QG', QG_PACKET, ENDPOINT, MODEL)


def test_a_bdj_disclosure_cannot_authorize_a_qg_packet():
    """With a matching BDJ purpose, the schema check still blocks a QG packet."""
    with pytest.raises(WorkflowHeld, match='DISCLOSURE_SOURCE_CLASS_INVALID'):
        SyntheticBdjDisclosure(_authorization('run-bdj')).require_current(
            'BDJ', QG_PACKET, ENDPOINT, MODEL)


def test_a_bdj_disclosure_cannot_borrow_the_qg_purpose():
    """The purpose check alone blocks a BDJ authorization carrying QG purpose."""
    auth = SyntheticBdjAuthorization(
        run_id='run-bdj', source_fingerprint='f' * 64,
        operator_receipt='CP04A-TEST-RECEIPT', purpose=QG_PURPOSE)
    with pytest.raises(WorkflowHeld, match='DISCLOSURE_PURPOSE_MISMATCH'):
        SyntheticBdjDisclosure(auth).require_current('BDJ', QG_PACKET, ENDPOINT, MODEL)


def test_a_qg_disclosure_cannot_authorize_a_bdj_packet():
    """With a matching QG purpose, the schema check still blocks a BDJ packet."""
    with pytest.raises(WorkflowHeld, match='DISCLOSURE_SOURCE_CLASS_INVALID'):
        _qg_disclosure().require_current('QG', PACKET, ENDPOINT, MODEL)


def test_a_qg_disclosure_cannot_borrow_the_bdj_purpose():
    with pytest.raises(WorkflowHeld, match='DISCLOSURE_PURPOSE_MISMATCH'):
        _qg_disclosure(purpose='SYNTHETIC_BDJ_DIAGNOSTIC').require_current(
            'QG', PACKET, ENDPOINT, MODEL)


def test_qg_from_facts_sends_the_packet_keys_the_disclosure_binds():
    """The two new keys are exactly what _qg_from_facts puts in qg_input.

    The disclosure can only bind a packet that carries the QG schema version and
    the fingerprint of the confirmed facts. This test captures the real payload
    from `_qg_from_facts` and feeds it straight into `SyntheticQgDisclosure`.
    """
    from types import SimpleNamespace

    from sitewise.project1.measurement_policy import lab_authority
    from sitewise.project1.qg_contract import facts_from_packet
    from sitewise.project1.research import ResearchWorkflow

    packet = {
        'schema_version': 'business-context-package/1.1',
        'assessment_id': 'SYN-ASSESS-QG',
        'confirmation': {'status': 'CURRENT_CONFIRMED',
                         'id': 'b2c3d4e5-0000-4000-8000-000000000000', 'revision': 1},
        'confirmed_uncertainty': {
            'id': 'a1b2c3d4-0000-4000-8000-000000000000',
            'confirmation_id': 'b2c3d4e5-0000-4000-8000-000000000000',
            'actor_user_id': 'c3d4e5f6-0000-4000-8000-000000000000',
            'exact_text': ('Would eligible customers find RM13 acceptable for a 12 oz '
                           'takeaway iced latte?')},
        'geography': None,
        'permissions': {'qj_execution': False},
        'm2_answers': [{'answer_revision_id': 'SYN-A1', 'item_key': 'M2-04',
                        'value': 'takeaway only'}],
        'supporting_sources': [],
    }
    packet['packet_hash'] = digest(packet)

    seen = {}

    def runner(stage, payload, output_type, **kwargs):
        seen.update(payload)
        return {'decision': 'ABSTAIN_NEEDS_REVIEW', 'question': '',
                'justification': 'No confirmed price.',
                'missing_business_facts': ['PRICE'], 'used_confirmed_facts': []}

    workflow = ResearchWorkflow(
        SimpleNamespace(get_context=lambda _: packet),
        lab_authority(), SimpleNamespace(), runner)
    workflow.execute_qg_from_facts(None)

    assert seen['schema_version'] == QG_SCHEMA_VERSION
    assert seen['source_fingerprint'] == facts_from_packet(packet).fingerprint

    # The captured payload binds cleanly, proving the emitted keys are the ones
    # the disclosure actually consumes (no re-labelling needed).
    SyntheticQgDisclosure(_qg_authorization(
        source_fingerprint=seen['source_fingerprint'])).require_current(
            'QG', seen, ENDPOINT, MODEL)
