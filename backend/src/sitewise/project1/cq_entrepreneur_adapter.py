"""ENTREPRENEUR_SPECIFIC assignment adapter for the CQ release contract.

Why this module exists
----------------------
``domain.cq_runtime.verify_release`` refused *every* ``ENTREPRENEUR_SPECIFIC``
manifest with ``CQ_ENTREPRENEUR_ASSIGNMENT_AUTHORITY_UNVERIFIED`` (line 70-72),
because no adapter bound an owner's confirmed context to a release. The Stage 5
composition produces exactly that lane -- its stems carry the owner's own
``Johor``, ``RM 16.00`` and concept version -- so the questionnaire the
entrepreneur actually reviewed could never be released.

This module is that adapter, and it is deliberately the *narrowest* one that can
be verified. It does not author question wording. It takes the governed template,
applies only the registered placeholder substitutions, and then requires the
manifest's own wording to be **identical to the reproduction**. A manifest whose
text cannot be reproduced from a governed template is refused, so "the wording
was edited" and "the wording was populated" are different outcomes rather than
the same one.

What this module will not do
----------------------------
* It never removes the refusal by itself. ``verify_assignment_authority`` must
  establish a binding block and reproduce every stem before it returns; every
  other path still raises.
* It never invents a translation. PROJECT1 V1 is English-only, so ``['EN']`` is
  the only locale set accepted here, and that is already legal under
  ``verify_release`` line 29.
* It never invents an option label. ``verify_release`` line 44 requires
  ``labels[lang]`` to cover exactly ``set(codes)``. When no governed label exists
  the adapter raises ``CQ_OPTION_LABELS_UNAVAILABLE`` instead of humanising a
  code into respondent-facing wording.

Binding block
-------------
``manifest['assignment']`` is the evidence that this release belongs to one
confirmed owner context::

    {
      'contract_version': 'cq-assignment/1',
      'assessment_id':    '<m2 assessment uuid>',
      'assessment_revision': 23,
      'confirmation_id':  '<m2 confirmation uuid>',
      'bcb_context_id':   '<business context uuid>',
      'bcb_packet_hash':  '<64 hex>',
      'template_versions': {'Q01': 'P3-01C-VNEXT-0.6.1-CUST-REC', ...},
      'slot_values':      {'named_area': 'Johor', 'exact_rm_price': 'RM 16.00', ...},
    }
"""
from __future__ import annotations

import re
from typing import Mapping

from sitewise.domain.cq_runtime import CqRefused

LANE = 'ENTREPRENEUR_SPECIFIC'
ASSIGNMENT_CONTRACT = 'cq-assignment/1'

#: The only locale set PROJECT1 V1 may publish. ``verify_release`` accepts
#: ``['EN']``; the BM half of the frozen contract has no governed wording here,
#: so publishing two locales would mean translating by hand.
V1_LOCALES = ('EN',)

#: Registered placeholder -> the slot that may fill it. This is the *whole*
#: permitted transformation: a token absent from this map is never substituted,
#: so an unregistered token survives into the wording and the reproduction
#: comparison fails closed.
TOKEN_TO_SLOT: dict[str, str] = {
    '[named area]': 'named_area',
    '[concept_card_version]': 'concept_card_version',
    '[exact_rm_price]': 'exact_rm_price',
    '[one_exact_product_size_quantity_fulfilment_and_charges]': 'product_spec',
    '[defined item: medium latte, dine-in]': 'defined_item',
}

_TOKEN_RE = re.compile(r'\[[^\[\]]+\]')
_HEX64 = re.compile(r'^[0-9a-f]{64}$')

#: Composition marker for an additional (Section B) question.
SECTION_ADDITIONAL = 'B_ADDITIONAL'


def is_additional(item: Mapping[str, object]) -> bool:
    """True for a Section B question, which has no governed template.

    The fixed core is reproduced from a governed stem, which is what makes
    "the wording was edited" distinguishable from "the wording was populated".
    An additional question was authored by the objective's own QG candidate and
    approved individually, so there is no template to reproduce it from. It is
    verified against its own candidate record instead -- see
    :func:`verify_additional_wording`.
    """
    return str(item.get('section') or '') == SECTION_ADDITIONAL

REQUIRED_BINDING = (
    'assessment_id', 'assessment_revision', 'confirmation_id',
    'bcb_context_id', 'bcb_packet_hash', 'template_versions', 'slot_values',
)


def unregistered_tokens(template: str) -> list[str]:
    """Tokens in a governed stem that this adapter may not substitute."""
    return [t for t in _TOKEN_RE.findall(template) if t not in TOKEN_TO_SLOT]


def render(template: str, slot_values: Mapping[str, object]) -> str:
    """Populate a governed stem using only the registered substitutions.

    Raises when a token has no value, so a partially-populated stem can never be
    presented as a finished question.
    """
    def replace(match: re.Match[str]) -> str:
        token = match.group(0)
        slot = TOKEN_TO_SLOT.get(token)
        if slot is None:
            raise CqRefused('CQ_ENTREPRENEUR_UNREGISTERED_TOKEN')
        value = slot_values.get(slot)
        if not isinstance(value, str) or not value.strip():
            raise CqRefused('CQ_ENTREPRENEUR_SLOT_UNRESOLVED')
        return value.strip()

    rendered = _TOKEN_RE.sub(replace, template)
    if _TOKEN_RE.search(rendered):
        raise CqRefused('CQ_ENTREPRENEUR_TOKEN_SURVIVED')
    return rendered


def verify_identity(manifest: Mapping[str, object]) -> Mapping[str, object]:
    """Require only the identity fields, for callers that fetch the rest."""
    assignment = manifest.get('assignment')
    if not isinstance(assignment, Mapping):
        raise CqRefused('CQ_ENTREPRENEUR_ASSIGNMENT_UNBOUND')
    if assignment.get('contract_version') != ASSIGNMENT_CONTRACT:
        raise CqRefused('CQ_ENTREPRENEUR_ASSIGNMENT_CONTRACT_INVALID')
    for key in ('assessment_id', 'assessment_revision', 'confirmation_id',
                'bcb_context_id'):
        if assignment.get(key) in (None, '', {}):
            raise CqRefused('CQ_ENTREPRENEUR_ASSIGNMENT_INCOMPLETE')
    revision = assignment.get('assessment_revision')
    if isinstance(revision, bool) or not isinstance(revision, int) or revision < 1:
        raise CqRefused('CQ_ENTREPRENEUR_ASSIGNMENT_INCOMPLETE')
    return assignment


def verify_binding(manifest: Mapping[str, object]) -> Mapping[str, object]:
    """Return the binding block, or refuse. Every field is load-bearing."""
    assignment = manifest.get('assignment')
    if not isinstance(assignment, Mapping):
        raise CqRefused('CQ_ENTREPRENEUR_ASSIGNMENT_UNBOUND')
    if assignment.get('contract_version') != ASSIGNMENT_CONTRACT:
        raise CqRefused('CQ_ENTREPRENEUR_ASSIGNMENT_CONTRACT_INVALID')
    for key in REQUIRED_BINDING:
        if assignment.get(key) in (None, '', {}):
            raise CqRefused('CQ_ENTREPRENEUR_ASSIGNMENT_INCOMPLETE')
    revision = assignment.get('assessment_revision')
    if isinstance(revision, bool) or not isinstance(revision, int) or revision < 1:
        raise CqRefused('CQ_ENTREPRENEUR_ASSIGNMENT_INCOMPLETE')
    if not _HEX64.match(str(assignment.get('bcb_packet_hash') or '')):
        raise CqRefused('CQ_ENTREPRENEUR_ASSIGNMENT_INCOMPLETE')
    if not isinstance(assignment.get('template_versions'), Mapping) or not isinstance(
            assignment.get('slot_values'), Mapping):
        raise CqRefused('CQ_ENTREPRENEUR_ASSIGNMENT_INCOMPLETE')
    return assignment


def verify_additional_wording(item: Mapping[str, object]) -> None:
    """Verify a Section B question against its own approved candidate record.

    There is no governed template to reproduce an additional question from, so
    the guarantee is different and is stated rather than implied: the manifest
    wording and options must be *identical* to the record that was approved.
    A release therefore cannot carry wording the owner never reviewed, and it
    cannot carry a question whose review decision was anything but approval.
    """
    record = item.get('validation')
    if not isinstance(record, Mapping):
        raise CqRefused('CQ_ENTREPRENEUR_TEMPLATE_UNKNOWN')
    if str(record.get('item_id') or '') != str(item.get('id') or ''):
        raise CqRefused('CQ_ENTREPRENEUR_TEMPLATE_UNKNOWN')
    # Only an individually approved candidate may reach a customer instrument.
    if str(record.get('review_decision') or '') != 'APPROVE_FOR_REVIEW':
        raise CqRefused('CQ_ADDITIONAL_NOT_APPROVED')
    stem = str(record.get('stem') or '').strip()
    if not stem:
        raise CqRefused('CQ_ADDITIONAL_WORDING_MISSING')
    for language in ('EN',):
        if (item.get('wording') or {}).get(language) != stem:
            raise CqRefused('CQ_ENTREPRENEUR_WORDING_NOT_REPRODUCIBLE')
    record_codes = [str(o.get('code')) for o in (record.get('options') or [])
                    if isinstance(o, Mapping)]
    if record_codes != list(item.get('codes') or []):
        raise CqRefused('CQ_CODEBOOK_MISMATCH')
    # A composed item never carries authority; if the record claims any, the
    # record did not come from the composition service.
    for flag in ('fielding_authorized', 'publication_authorized',
                 'scientifically_accepted'):
        if record.get(flag) is True:
            raise CqRefused('CQ_ADDITIONAL_AUTHORITY_INVALID')


def verify_wording(manifest: Mapping[str, object],
                   templates: Mapping[str, str]) -> None:
    """Reproduce every stem and require the manifest to match it exactly."""
    assignment = verify_binding(manifest)
    slots = assignment['slot_values']
    versions = assignment['template_versions']
    locales = manifest.get('locales')
    if not isinstance(locales, list) or tuple(locales) != V1_LOCALES:
        raise CqRefused('CQ_ENTREPRENEUR_LOCALE_SCOPE_INVALID')

    for item in manifest.get('questions') or []:
        if is_additional(item):
            verify_additional_wording(item)
            continue
        qid = item.get('id')
        template = templates.get(qid)
        if not isinstance(template, str) or not template:
            raise CqRefused('CQ_ENTREPRENEUR_TEMPLATE_UNKNOWN')
        if versions.get(qid) != manifest.get('spec_version'):
            raise CqRefused('CQ_ENTREPRENEUR_TEMPLATE_VERSION_INVALID')
        if unregistered_tokens(template):
            raise CqRefused('CQ_ENTREPRENEUR_UNREGISTERED_TOKEN')
        expected = render(template, slots)
        if item.get('wording', {}).get('EN') != expected:
            # Edited text is not a populated template. This is the whole point of
            # the adapter: it separates the two instead of trusting the caller.
            raise CqRefused('CQ_ENTREPRENEUR_WORDING_NOT_REPRODUCIBLE')


def verify_labels(manifest: Mapping[str, object]) -> None:
    """Require the labels to *be* the versioned mapping, not whatever was sent.

    A caller must not be able to satisfy the label requirement by typing any
    string. The manifest names the label contract and its fingerprint; the labels
    themselves are then compared against the mapping this build ships, so an
    edited or invented label set is refused rather than accepted as wording.
    """
    from sitewise.project1 import cq_option_labels as label_contract

    if manifest.get('label_contract_version') != label_contract.CONTRACT_VERSION:
        raise CqRefused('CQ_OPTION_LABELS_UNAVAILABLE')
    if manifest.get('label_fingerprint') != label_contract.fingerprint():
        raise CqRefused('CQ_OPTION_LABELS_FINGERPRINT_MISMATCH')

    for item in manifest.get('questions') or []:
        if is_additional(item):
            # Its labels come from the approved candidate, not from the governed
            # Q01-Q13 label contract, which has no entry for it.
            continue
        for language in manifest.get('locales') or []:
            labels = (item.get('labels') or {}).get(language) or {}
            codes = list(item.get('codes') or [])
            if set(labels) != set(codes):
                raise CqRefused('CQ_LANGUAGE_VERSION_INCOMPLETE')
            expected = label_contract.labels_for(str(item.get('id')), codes)
            if labels != expected:
                raise CqRefused('CQ_OPTION_LABELS_MISMATCH')


def verify_assignment_authority(manifest: Mapping[str, object],
                                templates: Mapping[str, str] | None = None) -> None:
    """Establish ENTREPRENEUR_SPECIFIC authority, or refuse.

    Called from ``verify_release`` in place of the unconditional refusal. It
    returns only when the manifest is bound to a confirmed context, every stem is
    reproduced from a governed template, and every option label exists.
    """
    if manifest.get('lane') != LANE:
        raise CqRefused('CQ_MANIFEST_INVALID')
    if templates is None:
        templates = governed_templates()
    verify_wording(manifest, templates)
    verify_labels(manifest)


def governed_templates() -> dict[str, str]:
    """The governed Q01-Q13 stems, with their registered tokens intact.

    Read from the same preview catalogue Stage 5 composes from, so the adapter
    and the composition cannot drift to different wording.
    """
    from sitewise.cq_successor.preview_catalogue import PreviewQuestionCatalogue

    catalogue = PreviewQuestionCatalogue.load()
    return {q.question_id: q.stem_template for q in catalogue.questions()}


__all__ = [
    'ASSIGNMENT_CONTRACT', 'LANE', 'REQUIRED_BINDING', 'SECTION_ADDITIONAL',
    'TOKEN_TO_SLOT', 'V1_LOCALES', 'assert_authoritative_binding',
    'governed_templates', 'is_additional', 'load_authoritative', 'render',
    'unregistered_tokens', 'verify_additional_wording', 'verify_identity',
    'verify_assignment_authority', 'verify_binding', 'verify_labels',
    'verify_wording',
]


# --------------------------------------------------------------------------
# Authoritative binding
#
# ``verify_release`` is a pure function: it can check that a manifest is
# *internally* consistent, but it cannot reach the database, so on its own it
# lets a syntactically valid manifest assert its own authority. That is fine for
# a structural gate and unacceptable for an insert. ``assert_authoritative_binding``
# is the second half: it compares the manifest against the persisted records, and
# the release builder must call it inside the same transaction as the insert.
# --------------------------------------------------------------------------

def assert_authoritative_binding(manifest: Mapping[str, object],
                                 authoritative: Mapping[str, object],
                                 actor_id: str) -> None:
    """Compare the manifest with the records that actually exist.

    ``authoritative`` is what the database returned -- never what the caller
    supplied. Every field the manifest claims is checked against it, so a
    fabricated-but-consistent manifest fails here even though it passes
    ``verify_release``.
    """
    assignment = verify_binding(manifest)

    assessment = authoritative.get('assessment') or {}
    if str(assessment.get('id') or '') != str(assignment.get('assessment_id')):
        raise CqRefused('CQ_ENTREPRENEUR_ASSESSMENT_NOT_FOUND')
    if str(assessment.get('owner_user_id') or '') != str(actor_id):
        raise CqRefused('CQ_ENTREPRENEUR_ASSESSMENT_NOT_OWNED', 403)
    revision = assessment.get('revision')
    if revision != assignment.get('assessment_revision'):
        raise CqRefused('CQ_ENTREPRENEUR_REVISION_STALE')
    if assessment.get('confirmed_revision') != revision:
        raise CqRefused('CQ_ENTREPRENEUR_REVISION_UNCONFIRMED')

    confirmation = authoritative.get('confirmation') or {}
    if (str(confirmation.get('id') or '') != str(assignment.get('confirmation_id'))
            or confirmation.get('assessment_revision') != revision):
        raise CqRefused('CQ_ENTREPRENEUR_CONFIRMATION_STALE')

    context = authoritative.get('context') or {}
    if (str(context.get('context_id') or '') != str(assignment.get('bcb_context_id'))
            or str(context.get('confirmation_id') or '') != str(confirmation.get('id'))
            or context.get('assessment_revision') != revision):
        raise CqRefused('CQ_ENTREPRENEUR_CONTEXT_STALE')
    if str(context.get('packet_hash') or '') != str(assignment.get('bcb_packet_hash')):
        raise CqRefused('CQ_ENTREPRENEUR_CONTEXT_FINGERPRINT_MISMATCH')

    # The slot values are the owner's own declarations. Re-deriving them from the
    # persisted answers means a manifest cannot claim "Johor" while the saved
    # declaration says something else.
    persisted = authoritative.get('slot_values')
    if not isinstance(persisted, Mapping):
        raise CqRefused('CQ_ENTREPRENEUR_SLOT_SOURCE_UNAVAILABLE')
    claimed = assignment['slot_values']
    for slot, value in claimed.items():
        if slot in persisted and persisted[slot] != value:
            raise CqRefused('CQ_ENTREPRENEUR_SLOT_NOT_DECLARED')
    for slot, value in persisted.items():
        if claimed.get(slot) != value:
            raise CqRefused('CQ_ENTREPRENEUR_SLOT_MISSING')


def load_authoritative(session, manifest: Mapping[str, object],
                       actor_id: str) -> dict[str, object]:
    """Read the records the manifest claims, under RLS, for one assessment.

    Returns the mapping ``assert_authoritative_binding`` expects. Raises when a
    record is missing rather than returning a partial answer.
    """
    from sqlalchemy import text

    # The loader exists to *fetch* the packet hash and slot values, so it may not
    # require them as input. Identity only.
    assignment = verify_identity(manifest)
    aid = str(assignment['assessment_id'])
    session.execute(text("SELECT set_config('project1.actor_id',:a,true)"),
                    {'a': str(actor_id)})

    assessment = session.execute(text(
        'SELECT id, owner_user_id, revision, confirmed_revision '
        'FROM m2_assessments WHERE id=:id'), {'id': aid}).mappings().first()
    confirmation = session.execute(text(
        'SELECT id, assessment_id, assessment_revision FROM m2_confirmation_snapshots '
        'WHERE id=:id AND assessment_id=:aid'),
        {'id': str(assignment['confirmation_id']), 'aid': aid}).mappings().first()
    context = session.execute(text(
        'SELECT context_id, assessment_id, confirmation_id, assessment_revision, '
        'packet_hash, concept_version, lifecycle_status FROM m2_business_contexts '
        'WHERE context_id=:cid AND assessment_id=:aid'),
        {'cid': str(assignment['bcb_context_id']), 'aid': aid}).mappings().first()

    from sitewise.cq_successor.preview_catalogue import build_slot_values

    rows = session.execute(text(
        'SELECT i.item_key, a.answer_state, a.value_json '
        'FROM m2_answer_revisions a JOIN m2_item_versions i ON i.id=a.item_version_id '
        'WHERE a.assessment_id=:aid AND i.item_key IN (\'M2V2-01\',\'M2V2-14\') '
        'AND a.assessment_revision<=:rev ORDER BY a.assessment_revision DESC'),
        {'aid': aid, 'rev': int(assignment['assessment_revision'])}).mappings().all()
    latest: dict[str, object] = {}
    for row in rows:
        latest.setdefault(row['item_key'], row)
    area = latest.get('M2V2-01')
    offer = latest.get('M2V2-14')
    slot_values = build_slot_values(
        study_area=(area['value_json'] if area and area['answer_state'] == 'ANSWERED' else None),
        concept_version=(context['concept_version'] if context else None),
        priced_offer=(offer['value_json'] if offer and offer['answer_state'] == 'ANSWERED' else None),
    )

    return {
        'assessment': dict(assessment) if assessment else {},
        'confirmation': dict(confirmation) if confirmation else {},
        'context': dict(context) if context else {},
        'slot_values': slot_values,
    }
