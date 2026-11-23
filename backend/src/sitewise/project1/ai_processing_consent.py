"""Explicit external-AI-processing permission, recorded with the confirmation.

An M2 declaration confirmation deliberately grants nothing downstream: its
snapshot carries ``confirmation_scope: M2_DECLARATIONS_ONLY`` and pins
``qj_handoff_authorized: false``. Sending those declarations to a cloud model is
a *different* act from confirming them, so it needs its own disclosure and its
own affirmative decision rather than being inferred from a business
confirmation. Reinterpreting a historical confirmation as cloud permission is
therefore impossible by construction: v3 snapshots simply have no
``ai_processing`` block.

This module owns the canonical disclosure terms. They are never taken from the
client: the client may only *echo* what it was shown, and any disagreement is
refused. A caller cannot widen the disclosure, change the provider, or claim a
purpose the product does not have.

Versioned on purpose. Adding a term or changing a purpose requires a new
``ai-processing-consent/N``; older grants keep their own version and are
refused once the contract they described no longer exists.
"""
from __future__ import annotations

import hashlib
import json
from uuid import UUID

from sitewise.project1.contracts import WorkflowHeld

#: Bumped whenever the disclosed terms change. A grant recorded under an older
#: version is not silently reinterpreted as consent to the new terms.
CONSENT_VERSION = 'ai-processing-consent/1'

PROVIDER = 'tokenharbor'
GRANTED = 'GRANTED'
NOT_GRANTED = 'NOT_GRANTED'

PURPOSE = ('Derive research objectives for this assessment from its confirmed '
           'business declarations, using an external AI model.')

#: The objective route sends the whole context packet to the model
#: (``provider.py``: ``prompt.messages(packet, ...)``), so the disclosure names
#: every information-bearing section rather than implying a subset.
DATA_SHARED = (
    'm2_answers',
    'business_description',
    'sections',
    'confirmed_uncertainty',
    'unknowns',
    'supporting_sources',
    'geography',
    'identity',
)
ENTIRE_CONTEXT_PACKET = True

#: The one attempt a synthetic trial grant covers. Never widened by a caller.
MAX_ATTEMPTS = 1


def _canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def consent_digest(block: dict) -> str:
    """Digest of a consent block, excluding the digest itself."""
    body = {k: v for k, v in block.items() if k != 'consent_digest'}
    return hashlib.sha256(_canonical(body).encode('utf-8')).hexdigest()


def build_consent(*, request, endpoint: str, model: str, owner_id) -> dict:
    """Turn an explicit client decision into the canonical consent block.

    ``request`` is only an *echo* of what the interface showed. Every term is
    re-derived from the canonical constants above, so a client that omits,
    renames or rewrites a term produces a refusal rather than a wider grant.
    """
    if request is None:
        return not_granted()
    if getattr(request, 'granted', None) is not True:
        return not_granted()
    shown = {
        'disclosure_version': CONSENT_VERSION,
        'provider': PROVIDER,
        'purpose': PURPOSE,
        'endpoint': endpoint,
        'model': model,
    }
    for key, value in shown.items():
        if getattr(request, key, None) != value:
            # The interface showed something other than what this release
            # discloses. Refusing is the only safe reading: the owner did not
            # agree to these terms, whatever they agreed to.
            raise WorkflowHeld('AI_PROCESSING_DISCLOSURE_MISMATCH')
    return {
        'contract_version': CONSENT_VERSION,
        'decision': GRANTED,
        'provider': PROVIDER,
        'endpoint': endpoint,
        'model': model,
        'purpose': PURPOSE,
        'data_shared': list(DATA_SHARED),
        'entire_context_packet': ENTIRE_CONTEXT_PACKET,
        'single_attempt': True,
        'max_attempts': MAX_ATTEMPTS,
        'granted_by': str(owner_id),
        'consent_digest': consent_digest({
            'contract_version': CONSENT_VERSION, 'decision': GRANTED,
            'provider': PROVIDER, 'endpoint': endpoint, 'model': model,
            'purpose': PURPOSE, 'data_shared': list(DATA_SHARED),
            'entire_context_packet': ENTIRE_CONTEXT_PACKET,
            'single_attempt': True, 'max_attempts': MAX_ATTEMPTS,
            'granted_by': str(owner_id)}),
    }


def not_granted() -> dict:
    """Explicit absence. Never omitted, so a reader cannot mistake it for v3."""
    return {
        'contract_version': CONSENT_VERSION,
        'decision': NOT_GRANTED,
        'provider': PROVIDER,
        'endpoint': None,
        'model': None,
        'purpose': PURPOSE,
        'data_shared': [],
        'entire_context_packet': False,
        'single_attempt': True,
        'max_attempts': 0,
        'granted_by': None,
        'consent_digest': None,
    }


def verify_consent(block, *, endpoint: str, model: str, owner_id) -> dict:
    """Return the block only when it is a genuine, current, matching grant."""
    if not isinstance(block, dict):
        raise WorkflowHeld('AI_PROCESSING_CONSENT_REQUIRED')
    if block.get('decision') != GRANTED:
        raise WorkflowHeld('AI_PROCESSING_CONSENT_REQUIRED')
    if block.get('contract_version') != CONSENT_VERSION:
        raise WorkflowHeld('AI_PROCESSING_CONSENT_VERSION_UNSUPPORTED')
    if block.get('consent_digest') != consent_digest(block):
        # A grant whose own digest does not cover its terms is not evidence of
        # anything: refuse rather than read the unverified fields.
        raise WorkflowHeld('AI_PROCESSING_CONSENT_TAMPERED')
    if block.get('provider') != PROVIDER:
        raise WorkflowHeld('AI_PROCESSING_CONSENT_PROVIDER_MISMATCH')
    if block.get('endpoint') != endpoint:
        raise WorkflowHeld('AI_PROCESSING_CONSENT_ENDPOINT_MISMATCH')
    if block.get('model') != model:
        raise WorkflowHeld('AI_PROCESSING_CONSENT_MODEL_MISMATCH')
    if block.get('purpose') != PURPOSE:
        raise WorkflowHeld('AI_PROCESSING_CONSENT_PURPOSE_MISMATCH')
    if list(block.get('data_shared') or []) != list(DATA_SHARED):
        raise WorkflowHeld('AI_PROCESSING_CONSENT_SCOPE_MISMATCH')
    if block.get('single_attempt') is not True or block.get('max_attempts') != MAX_ATTEMPTS:
        raise WorkflowHeld('AI_PROCESSING_CONSENT_ATTEMPTS_MISMATCH')
    if block.get('granted_by') != str(owner_id):
        # Consent belongs to the owner who gave it; a different actor cannot
        # inherit it.
        raise WorkflowHeld('AI_PROCESSING_CONSENT_OWNER_MISMATCH')
    return block


def disclosure(block: dict) -> dict:
    """The human-facing disclosure the interface must show before consent."""
    return {
        'contract_version': CONSENT_VERSION,
        'provider': PROVIDER,
        'purpose': PURPOSE,
        'data_shared': list(DATA_SHARED),
        'entire_context_packet': ENTIRE_CONTEXT_PACKET,
        'max_attempts': MAX_ATTEMPTS,
        'note': ('This permission is separate from confirming your business '
                 'declarations. Declining it does not affect your confirmation.'),
    }
