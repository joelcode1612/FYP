"""Derive the exact cloud-dispatch authorization from recorded owner permission.

The operator no longer has to compose terms by hand and re-decide them for each
attempt. Those terms are now a function of two things that already exist:

  * the owner's affirmative decision, recorded immutably inside the confirmation
    snapshot (``ai_processing``), and
  * the current, reproducible BCB context for that confirmation.

Deriving is a **pure read**. It writes nothing, so an execution principal can
only ever *observe* a permission that the owner recorded; it cannot create one.
Materialising a record into the isolated trial registry remains a separate act
by a principal that holds write access there — which the execution principal
provably does not (``synthetic_trial_registry`` refuses a writer).

Revocation is not a flag anyone sets. The grant is bound to the exact revision,
confirmation, source fingerprint and context packet hash it was given for, so
any movement in the source revokes it by making the binding fail.
"""
from __future__ import annotations

from sitewise.project1.ai_processing_consent import verify_consent
from sitewise.project1.contracts import WorkflowHeld

#: Recorded permission is the authority; the registry row only mirrors it.
SOURCE = 'OWNER_CONSENT'


class ConsentAuthorization:
    """Assessment-bound authorization derived from the owner's own decision."""

    STAGE = 'BDJ_OBJECTIVE'
    DATA_CLASS = 'SYNTHETIC_NONHUMAN'

    def __init__(self, *, read_confirmation, current_source, owner_id, assessment_id,
                 revision, confirmation_id, source_fingerprint, context_packet_hash,
                 prompt, endpoint, model, context_status=None):
        self.read_confirmation = read_confirmation
        self.current_source = current_source
        self.context_status = context_status
        self.endpoint = endpoint
        self.model = model
        self.expected = {
            'stage': self.STAGE,
            'data_class': self.DATA_CLASS,
            'decision': 'APPROVED',
            'max_attempts': 1,
            'owner_id': str(owner_id),
            'assessment_id': str(assessment_id),
            'revision': revision,
            'confirmation_id': str(confirmation_id),
            'source_fingerprint': source_fingerprint,
            'context_packet_hash': context_packet_hash,
            'prompt_version': prompt.version,
            'prompt_fingerprint': prompt.fingerprint,
            'endpoint': endpoint,
            'model': model,
        }

    def derive(self) -> dict:
        """The exact record, or a refusal. Never a partial or widened grant."""
        snapshot = self.read_confirmation()
        if not isinstance(snapshot, dict):
            raise WorkflowHeld('AI_PROCESSING_CONSENT_REQUIRED')
        block = verify_consent(snapshot.get('ai_processing'),
                               endpoint=self.endpoint, model=self.model,
                               owner_id=self.expected['owner_id'])
        # The grant must still describe the source it was given for. A moved
        # revision, confirmation or fingerprint revokes it.
        current = self.current_source()
        if not isinstance(current, dict) or any(
                current.get(key) != self.expected[key] for key in
                ('owner_id', 'assessment_id', 'revision', 'confirmation_id',
                 'source_fingerprint')):
            raise WorkflowHeld('DISCLOSURE_CURRENT_SOURCE_REQUIRED')
        # The context the grant is bound to must still be the usable current one.
        if self.context_status is not None:
            status = self.context_status()
            if not isinstance(status, dict):
                raise WorkflowHeld('DISCLOSURE_CONTEXT_UNAVAILABLE')
            if status.get('context_compatible') is not True:
                raise WorkflowHeld('DISCLOSURE_CONTEXT_NOT_REPRODUCIBLE')
            if status.get('source_is_current') is not True:
                raise WorkflowHeld('DISCLOSURE_CONTEXT_NOT_CURRENT')
            if str(status.get('context_id')) and self.expected['context_packet_hash'] is None:
                raise WorkflowHeld('DISCLOSURE_CONTEXT_UNAVAILABLE')
        return {
            **self.expected,
            'authorization_source': SOURCE,
            'consent_version': block['contract_version'],
            'consent_digest': block['consent_digest'],
            'purpose': block['purpose'],
            'data_shared': list(block['data_shared']),
            'entire_context_packet': block['entire_context_packet'],
        }
