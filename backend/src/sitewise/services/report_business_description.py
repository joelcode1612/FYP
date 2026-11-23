"""RP-13 — the confirmed business description, as the report may show it.

The report's section 02 used to be assembled from the marketplace's own Step-2
preference blob, which meant it could only ever say what the entrepreneur typed
into *this* workspace. The confirmed Business Context packet (BCB) is a
different and better source: it is version-bound to one M2 confirmation, it
carries a per-field source reference, and its integrity is re-verified on every
read.

This module is the read-only bridge between them. It never builds a packet, never
persists one, and never infers a value:

* no M2 link            → ``NO_M2_LINK``
* no persisted context  → ``NO_CONFIRMED_BUSINESS_CONTEXT``
* packet refuses        → ``BUSINESS_CONTEXT_HELD`` (with the service's own code)
* packet verified       → ``AVAILABLE`` with the description rows

The distinction matters: "this assessment never confirmed a business" and "this
assessment's confirmation no longer reproduces" are different states, and a
report that collapsed them into one blank section would be hiding the reason.

Nothing here grants report admission. The description is the entrepreneur's own
confirmed declaration, presented as such; it is not independently verified and
the packet's own limitations are carried through verbatim.
"""

from __future__ import annotations

from uuid import UUID

from sitewise.services.assessment_link_service import AssessmentLinkError
from sitewise.services.persisted_business_context_service import (
    ContextOperationHeld, PersistedBusinessContextService,
)
from sitewise.services.ports.business_context_store_port import ContextActor

CONTRACT_VERSION = 'report-business-description/1'

#: Display order and heading for each BCB V1.2.1 business-description section.
#: The order is the report's, not the packet's: a dict has no presentation
#: order, and letting one leak through would make the section reorder itself
#: whenever the builder changed.
SECTIONS: tuple[tuple[str, str], ...] = (
    ('concept_title', 'Concept'),
    ('concept_details', 'Concept description'),
    ('product_categories', 'Products and services'),
    ('service_format', 'Service format'),
    ('offered_service_formats', 'Offered service formats'),
    ('customer_groups', 'Intended customer groups'),
    ('primary_customer_group', 'Primary customer group'),
    ('customer_occasion', 'Customer occasion'),
    ('concept_emphasis', 'Planned emphasis'),
    ('business_stage', 'Business stage'),
    ('study_area', 'Study area'),
    ('concept_review_status', 'Concept review status'),
)

#: Source-reference keys carried from each section's ``ref``. Only the ones that
#: identify the answer; a UI needs the item and the revision, not the digest.
REF_KEYS = ('item_key', 'item_version_id', 'answer_revision_id', 'source_hash',
            'confirmation_id', 'answer_state')


def _held(status: str, code: str | None, *, detail: str | None = None) -> dict:
    return {
        'contract_version': CONTRACT_VERSION,
        'status': status,
        'reason_code': code,
        'detail': detail,
        'source': None,
        'rows': [],
        'uncertainty': None,
        'limitations': [],
        'evidence_class': None,
    }


def _value_text(value) -> str | None:
    """The section's value as display text, or ``None`` when it has none.

    Never synthesises a placeholder: a missing value stays missing so the report
    can omit the row instead of printing "not provided" for every unasked item.
    """
    if isinstance(value, str):
        text = value.strip()
        return text or None
    if isinstance(value, dict):
        parts = [str(value[k]).strip() for k in ('stage', 'decision_explanation')
                 if isinstance(value.get(k), str) and value[k].strip()]
        return ' · '.join(parts) or None
    if isinstance(value, (list, tuple)):
        items = [str(item).strip() for item in value if str(item).strip()]
        return ', '.join(items) or None
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return str(value)
    return None


def _row(key: str, heading: str, section) -> dict:
    if not isinstance(section, dict):
        return {'key': key, 'label': heading, 'present': False, 'text': None,
                'code': None, 'source': None}
    value = section.get('value')
    text = _value_text(value)
    label = section.get('label')
    ref = section.get('ref') if isinstance(section.get('ref'), dict) else {}
    return {
        'key': key,
        'label': heading,
        # A section that carries a code but no display text is still "present":
        # the entrepreneur answered, the answer just has no prose form.
        'present': bool(text or label),
        'text': text,
        # The option label, when the answer is a coded single choice. Kept
        # separate from the free-text value so the report never conflates the
        # instrument's own caption with something the entrepreneur wrote.
        'code': label.strip() if isinstance(label, str) and label.strip() else None,
        'source': {k: ref.get(k) for k in REF_KEYS if ref.get(k) is not None} or None,
    }


class ReportBusinessDescriptionService:
    """Read the confirmed BCB description for a marketplace assessment."""

    def __init__(self, links, contexts: PersistedBusinessContextService):
        self.links, self.contexts = links, contexts

    def for_assessment(self, *, marketplace_assessment_id: UUID, user_id: UUID,
                       role: str, verified_email: str | None) -> dict:
        from sitewise.domain import rbac

        # 1. The link proves marketplace ownership *before* anything M2 is read,
        #    so an unauthorised caller cannot learn whether a link exists.
        try:
            link = self.links.resolve(
                marketplace_assessment_id=marketplace_assessment_id,
                user_id=user_id,
                verified_email=verified_email,
                create_if_missing=False,
            )
        except AssessmentLinkError as exc:
            return _held('NO_M2_LINK', exc.code,
                         detail='No confirmed M2 research record is linked to this assessment.')

        m2_assessment_id = link.m2_assessment_id
        actor = ContextActor(user_id, rbac.canonical_role(role))

        # 2. The newest persisted context, owner-scoped. A caller never supplies
        #    a context id here: it could then name another revision's packet.
        try:
            context_id = self.contexts.latest_context_id(m2_assessment_id, actor)
        except ContextOperationHeld as exc:
            return _held('BUSINESS_CONTEXT_HELD', exc.code)
        if context_id is None:
            return _held('NO_CONFIRMED_BUSINESS_CONTEXT', None,
                         detail='This assessment has no persisted business context yet.')

        # 3. Full readback: re-derives the packet, re-verifies packet_hash and
        #    canonical_body, and refuses a superseded revision rather than
        #    showing a description the confirmation no longer supports.
        try:
            envelope = self.contexts.retrieve(m2_assessment_id, context_id, actor)
        except ContextOperationHeld as exc:
            return _held('BUSINESS_CONTEXT_HELD', exc.code)

        packet = envelope['packet']
        description = packet.get('business_description') or {}
        sections = description.get('sections') or {}
        rows = [_row(key, heading, sections.get(key)) for key, heading in SECTIONS]
        concept = packet.get('concept') or {}
        uncertainty = packet.get('confirmed_uncertainty')

        return {
            'contract_version': CONTRACT_VERSION,
            'status': 'AVAILABLE',
            'reason_code': None,
            'detail': None,
            'source': {
                'm2_assessment_id': str(m2_assessment_id),
                'context_id': str(envelope['context_id']),
                'confirmation_id': str(envelope['confirmation_id']),
                'assessment_revision': envelope['assessment_revision'],
                'lifecycle_status': envelope['lifecycle_status'],
                'builder_version': (packet.get('context_version')
                                    or packet.get('builder_version')),
                'schema_version': packet.get('schema_version'),
                'packet_hash': packet.get('packet_hash'),
                'concept_version': concept.get('version'),
                'concept_status': concept.get('status'),
                'concept_source_hash': concept.get('source_hash'),
                'confirmed_at': envelope.get('created_at'),
            },
            # Only rows that actually carry a value. A heading with nothing
            # behind it is omitted rather than rendered empty.
            'rows': [row for row in rows if row['present']],
            'uncertainty': (
                {'id': str(uncertainty.get('id')),
                 'text': uncertainty.get('exact_text')}
                if isinstance(uncertainty, dict) and uncertainty.get('exact_text') else None),
            'limitations': list(packet.get('limitations') or []),
            'evidence_class': 'ENTREPRENEUR_CONFIRMED',
        }
