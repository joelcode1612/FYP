"""Compose the existing governed cloud-BDJ path for the M2 route.

Only the server-side source projection supplies the data class. In particular,
this bridge never adds a synthetic marker to entrepreneur declarations.
"""
from sitewise.api.v1 import project1_workflow as workflow
from sitewise.project1.result_store import results_for_assessment
from sitewise.project1.key_custody import LocalKeyCustody
from sitewise.core.exceptions import ConflictError


def execute_confirmed_bdj(service, user, assessment_id, revision):
    session = service.repo.session
    # Keep the existing workflow, restricted-principal, model and rules gates.
    workflow.configuration_gate(session)
    workflow.model_assisted_gate()
    result = workflow.execute_model_assisted_source(
        session=session, user=user, assessment_id=assessment_id, revision=revision,
        packet_source=workflow.source, runtime=workflow.get_runtime_engine(),
        runner_factory=workflow.configured_runner)
    # D1: a validated result alone leaves findings inside the sealed payload with
    # no identity. Materialise them and link them so review can point at them.
    # Authority stays 'candidate'; this is not an approval.
    if result and result.get('findings'):
        from sitewise.services.bdj_finding_admission import admit_and_link
        result['finding_admission'] = admit_and_link(
            m2_session=session, runtime_engine=workflow.get_runtime_engine(),
            actor_id=user.user_id, assessment_id=assessment_id, revision=revision,
            result=result)
    return result



def read_current_bdj(service, user, assessment_id, confirmation_id, revision):
    """Read only rows matching the current confirmed source fingerprint."""
    session = service.repo.session
    packet = workflow.source(session, user, assessment_id, revision)
    if packet.get('confirmation', {}).get('confirmation_id') != str(confirmation_id):
        raise ConflictError('The selected confirmation is no longer current.')
    fingerprint = packet['source_fingerprint']
    rows = results_for_assessment(
        workflow.get_runtime_engine(), user.user_id, assessment_id,
        payload_custody=LocalKeyCustody(), expected_revision=revision,
        expected_fingerprint=fingerprint, include_finding_refs=True,
    )
    current = workflow.source(session, user, assessment_id, revision)
    if (current['source_fingerprint'] != fingerprint or
            current.get('confirmation', {}).get('confirmation_id') != str(confirmation_id)):
        raise ConflictError('The confirmed source changed during result retrieval.')
    # Do not combine results from different executions or claim a provider
    # identity that the stored receipt did not establish.
    result = rows[0] if rows else None
    if result is None:
        status = 'NO_CURRENT_RESULT'
    elif result['execution_outcome'] == 'unknown':
        status = 'UNKNOWN_OUTCOME'
    elif result['review_outcome'] == 'stale':
        status = 'STALE_RESULT'
    elif result['validation_status'] != 'valid':
        status = 'VALIDATION_FAILED'
    elif result['review_outcome'] == 'reviewed' and result['execution_outcome'] == 'returned':
        status = 'COMPLETED_WITH_FINDINGS' if result['finding_count'] else 'COMPLETED_ZERO_FINDINGS'
    else:
        status = 'RESULT_UNAVAILABLE'
    return {'contract_version': 'sitewise-bdj-current/1',
            'assessment_id': str(assessment_id), 'confirmation_id': str(confirmation_id),
            'assessment_revision': revision, 'source_fingerprint': fingerprint,
            'status': status, 'execution_origin': 'UNVERIFIED',
            'result': result if status in ('COMPLETED_WITH_FINDINGS', 'COMPLETED_ZERO_FINDINGS') else None}
