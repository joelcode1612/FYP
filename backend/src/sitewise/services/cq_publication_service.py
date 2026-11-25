"""Entrepreneur publication of their own questionnaire (DD-096).

What this module is
-------------------
The secured, application-level publication operation. An authenticated
entrepreneur asks it to publish the questionnaire for an assessment they own;
it builds the ``cq-manifest/1`` document from that assessment's confirmed
declarations, verifies it, writes the bank version, the release and the
assignments, and binds the campaign that makes the release reachable by a
respondent -- in one transaction, as ``p1_cq_publisher``.

It adds no questionnaire engine. Construction, authorisation, fingerprinting
and persistence are ``services.cq_release_builder``; the authoritative
comparison is ``project1.cq_entrepreneur_adapter``; the structural gate is
``domain.cq_runtime.verify_release``. What is new here is *who* may run them and
*on whose behalf*, which is the whole of DD-096.

Why a separate principal, and what it buys
------------------------------------------
Before this module the only executable publisher was the database operator:
every policy on the four release tables was ``TO p1_ee01_runtime``, so granting
the application the ability to publish meant granting the *respondent runtime*
the ability to mint the instrument it answers. ``cq/20261125_02`` created
``p1_cq_publisher`` instead. Consequences, all enforced by the database and not
by this code:

* the publisher holds no privilege on ``cq_sessions``, ``cq_answer_revisions``,
  ``cq_effective_answers``, ``cq_submission_receipts`` or any other
  respondent-scoped relation, so a publication transaction cannot read or
  write respondent evidence even if this module is wrong;
* the publisher holds no UPDATE, DELETE or TRUNCATE anywhere, so publication
  cannot rewrite a release that already exists;
* ``cq_publisher_release_insert`` requires the manifest to name an assessment
  the bound actor owns, so publishing against somebody else's assessment is
  refused by the row policy, not by a branch in this file.

What publication does not authorise
-----------------------------------
Publication is not fielding. ``source_class`` is derived here -- never supplied
by a caller -- and is ``SYNTHETIC_FIXTURE`` for as long as customer fielding is
disabled, which keeps ``CustomerQuestionnaireService._release`` in
``ISOLATED_TEST`` and makes ``PRODUCTION`` scope unreachable
(``customer_questionnaire_service.py:41`` requires ``source_class='ADOPTED'``).
``cq_runtime_enabled`` is not consulted and is not changed: the respondent
route keeps answering ``503 PRODUCTION_FIELDING_HOLD`` after a successful
publication.

The one refusal that is a finding, not a fault
----------------------------------------------
An assessment already has at most one campaign (``UNIQUE(assessment_id)``), and
the campaign is bound to one release id. Because a release id is the digest of
its manifest, republishing after anything in the manifest changes produces a
*different* release id, and binding it to the existing campaign would be
supersession -- which needs a migration that has not been authorised. So
publication refuses with ``CQ_PUBLICATION_RELEASE_SUPERSEDED`` and reports the
comparison rather than silently rebinding. That is DD-095's residual, stated
where an operator will actually meet it.
"""
from __future__ import annotations

from uuid import UUID

from sqlalchemy import text

from sitewise.core.config import settings
from sitewise.domain.cq_runtime import CqRefused
from sitewise.domain.customer_questionnaire import digest
from sitewise.repositories.cq_repository import (
    PUBLICATION_ROLE, PostgresCqStore, get_publication_engine,
)
from sitewise.services import cq_release_builder as builder

CONTRACT_VERSION = 'cq-publication/1'

#: The release class this path produces while customer fielding is disabled.
#: Derived, never accepted from a request: ``ADOPTED`` would unlock
#: ``PRODUCTION`` scope in ``customer_questionnaire_service``.
SOURCE_CLASS = 'SYNTHETIC_FIXTURE'

#: Fixed for the same reason. A publication that could set its own consent text
#: could describe a synthetic instrument as a customer one.
CONSENT_VERSION = 'consent/1'
CONSENT_TEXT = 'Synthetic isolated test. No customer fielding.'


def _bank_version(assessment_id: str, revision: int) -> str:
    """Content-addressed bank version, derived exactly as the operator path.

    Reproducing the operator script's string (``CQ-ENTREP-<short>-r<rev>-
    cq-manifest-1``) matters: a different bank version is a different manifest
    hash, which is a different release id, which would make every already
    published release look superseded.
    """
    return f'CQ-ENTREP-{assessment_id[:8]}-r{revision}-cq-manifest-1'


def _title(slots) -> str:
    return (f"Entrepreneur-specific questionnaire — {slots['named_area']}, "
            f"{slots['exact_rm_price']}")


#: Slots without which no questionnaire can be rendered. ``[named area]`` and
#: ``[exact_rm_price]`` appear in the governed stems, so a release built without
#: them would carry unresolved placeholders into respondent-facing wording.
REQUIRED_SLOTS = ('named_area', 'exact_rm_price', 'product_spec',
                  'defined_item', 'concept_card_version')


class PublicationService:
    """Publication bound to one store. Every method is owner-scoped by RLS."""

    def __init__(self, store: PostgresCqStore | None = None):
        self.store = store or PostgresCqStore(get_publication_engine())

    # -- composition ------------------------------------------------------

    def _authoritative(self, unit, assessment_id: str, actor_id: str) -> dict:
        """The records the release must agree with, read as the publisher.

        Mirrors ``scripts/publish_cq_entrepreneur_release.authoritative`` and
        keeps DD-093 Option A: the build receipt for the confirmed revision
        names the authoritative context, because ``ORDER BY
        assessment_revision DESC`` breaks ties arbitrarily among the several
        PERSISTED rows a revision accumulates. The fallback exists only for a
        confirmation built before the receipt table did.

        Reads as the publisher on purpose. ``m2_*`` policies are ``TO public``
        and owner-scoped on ``project1_actor()``, so this returns the bound
        actor's rows and nothing else -- the grant widened who may ask, not
        which rows answer.
        """
        session = unit.session
        assessment = session.execute(text(
            'SELECT id, owner_user_id, revision, confirmed_revision '
            'FROM m2_assessments WHERE id = :id'), {'id': assessment_id}).mappings().first()
        if assessment is None:
            # The publisher's RLS makes "not yours" indistinguishable from
            # "does not exist", which is the correct amount to disclose.
            raise CqRefused('CQ_PUBLICATION_ASSESSMENT_NOT_FOUND', 404)
        if str(assessment['owner_user_id']) != str(actor_id):
            raise CqRefused('CQ_PUBLICATION_ASSESSMENT_NOT_FOUND', 404)
        if assessment['revision'] != assessment['confirmed_revision']:
            raise CqRefused('CQ_PUBLICATION_REVISION_UNCONFIRMED', 409)

        revision = int(assessment['revision'])
        context = self._select_context(session, assessment_id, revision)
        if context is None:
            raise CqRefused('CQ_PUBLICATION_CONTEXT_UNAVAILABLE', 409)
        if context['assessment_revision'] != revision:
            raise CqRefused('CQ_PUBLICATION_CONTEXT_STALE', 409)

        confirmation = session.execute(text(
            'SELECT id, assessment_id, assessment_revision '
            'FROM m2_confirmation_snapshots WHERE id = :id'),
            {'id': str(context['confirmation_id'])}).mappings().first()
        if confirmation is None:
            raise CqRefused('CQ_PUBLICATION_CONTEXT_UNAVAILABLE', 409)

        from sitewise.cq_successor.preview_catalogue import build_slot_values

        rows = session.execute(text(
            "SELECT i.item_key, a.answer_state, a.value_json "
            "  FROM m2_answer_revisions a JOIN m2_item_versions i ON i.id = a.item_version_id "
            " WHERE a.assessment_id = :aid AND i.item_key IN ('M2V2-01','M2V2-14') "
            "   AND a.assessment_revision <= :rev ORDER BY a.assessment_revision DESC"),
            {'aid': assessment_id, 'rev': revision}).mappings().all()
        latest: dict[str, object] = {}
        for row in rows:
            latest.setdefault(row['item_key'], row)
        area, offer = latest.get('M2V2-01'), latest.get('M2V2-14')
        slots = build_slot_values(
            study_area=(area['value_json'] if area and area['answer_state'] == 'ANSWERED' else None),
            concept_version=context['concept_version'],
            priced_offer=(offer['value_json'] if offer and offer['answer_state'] == 'ANSWERED' else None),
        )
        return {
            'assessment': dict(assessment),
            'confirmation': dict(confirmation),
            'context': {k: v for k, v in dict(context).items() if k != 'packet_json'},
            'packet': context['packet_json'],
            'slot_values': slots,
        }

    def _select_context(self, session, assessment_id: str, revision: int):
        """Which business context this release binds to -- deterministically.

        DD-093 Option A said the build receipt is the authority, because
        ``ORDER BY assessment_revision DESC`` over ``m2_business_contexts``
        breaks ties arbitrarily among the several PERSISTED rows a revision
        accumulates. The receipt query, however, inherited the same defect one
        level down: ``m2_business_context_builds`` has **no** uniqueness on
        ``(assessment_id, assessment_revision)``, so ``... WHERE
        assessment_revision = :rev ... LIMIT 1`` with no ``ORDER BY`` also
        breaks ties arbitrarily. Measured on 2026-11-25: revision 23 of
        ``df15adf3`` carries three PERSISTED builds with three distinct packet
        hashes (``48e3d217`` BCB-V1-1.1.0, ``265cd868`` and ``e4d47d47``
        BCB-V1-1.2.1), and the published release binds ``48e3d217`` while the
        unordered query returns ``265cd868``. That is DD-110: the same inputs
        produced two different release identities.

        Two rules, in order, and both are stated rather than inferred:

        1. **Stability.** If this assessment already has a release, the context
           *that release bound* is the authority for this assessment. The
           instrument a respondent may already be answering is not swapped for
           a rebuild of the same revision under a different package version --
           which is what supersession would be, and supersession is a migration
           decision (DD-095), not something pressing Publish may do.
        2. **Determinism.** Otherwise the most recent PERSISTED build for the
           confirmed revision, ordered explicitly.

        Neither rule invents a context: both select an existing PERSISTED row.
        """
        bound = session.execute(text(
            "SELECT manifest_json -> 'assignment' ->> 'bcb_context_id' AS cid "
            "  FROM cq_manifest_releases "
            " WHERE manifest_json -> 'assignment' ->> 'assessment_id' = :aid "
            " ORDER BY created_at LIMIT 1"), {'aid': assessment_id}).scalar()
        if bound:
            row = session.execute(text(
                "SELECT c.context_id, c.confirmation_id, c.assessment_revision, "
                "       c.packet_hash, c.concept_version, c.lifecycle_status, c.packet_json "
                "  FROM m2_business_contexts c "
                " WHERE c.context_id = :cid AND c.assessment_id = :aid "
                "   AND c.lifecycle_status = 'PERSISTED'"),
                {'cid': str(bound), 'aid': assessment_id}).mappings().first()
            if row is not None:
                return row
            # The bound context is no longer PERSISTED. Falling through to a
            # different context would silently change the instrument, so stop.
            raise CqRefused('CQ_PUBLICATION_BOUND_CONTEXT_UNAVAILABLE', 409)

        return session.execute(text(
            "SELECT c.context_id, c.confirmation_id, c.assessment_revision, "
            "       c.packet_hash, c.concept_version, c.lifecycle_status, c.packet_json "
            "  FROM m2_business_context_builds b "
            "  JOIN m2_business_contexts c ON c.context_id = b.context_id "
            " WHERE b.assessment_id = :aid AND b.assessment_revision = :rev "
            "   AND b.status = 'PERSISTED' AND c.assessment_id = :aid "
            "   AND c.lifecycle_status = 'PERSISTED' "
            " ORDER BY b.created_at DESC, c.context_id DESC LIMIT 1"),
            {'aid': assessment_id, 'rev': revision}).mappings().first()

    def _compose(self, records: dict, contract, policy) -> tuple[dict, dict, dict]:
        """Composition, binding block and stimuli -- the operator path verbatim."""
        from sitewise.cq_successor.preview_catalogue import PreviewQuestionCatalogue
        from sitewise.project1 import cq_entrepreneur_adapter as adapter

        slots = records['slot_values']
        populated = PreviewQuestionCatalogue.load().populate(slots)
        items = [{
            'item_id': row.question.question_id,
            'stem': row.populated_stem,
            'stem_template': row.question.stem_template,
            'response_format': row.question.response_type,
            'population_status': row.population_status,
            'unresolved_slots': [{'slot': u.slot, 'required': u.required}
                                 for u in row.unresolved],
        } for row in populated.questions]
        composed = {'items': items, 'declarations': {'slot_values': dict(slots)}}

        assessment, context = records['assessment'], records['context']
        assignment = {
            'contract_version': adapter.ASSIGNMENT_CONTRACT,
            'assessment_id': str(assessment['id']),
            'assessment_revision': int(assessment['revision']),
            'confirmation_id': str(records['confirmation']['id']),
            'bcb_context_id': str(context['context_id']),
            'bcb_packet_hash': str(context['packet_hash']),
            'template_versions': {q['id']: str(contract['spec_version'])
                                  for q in contract['items']},
            'slot_values': dict(slots),
        }

        concept = (records['packet'] or {}).get('concept') or {}
        stimuli = {
            'concept': {'version': str(context['concept_version']),
                        'text': {'EN': str((concept.get('content') or {}).get('description') or '')}},
            'offer': {'version': f"M2V2-14@r{assessment['revision']}",
                      'text': {'EN': f"{slots['product_spec']} at {slots['exact_rm_price']}"}},
        }
        return composed, assignment, stimuli

    def _prepare(self, unit, assessment_id: str, actor_id: str) -> dict:
        """Everything up to (not including) the write."""
        from sitewise.services.customer_questionnaire_candidate import load_sources

        contract, policy, reference = load_sources()
        records = self._authoritative(unit, assessment_id, actor_id)
        # A stem the owner has not resolved cannot be published. The builder
        # would report each affected question as SLOT_UNRESOLVED and persist a
        # release with no authorised question; refusing here names the missing
        # declarations instead, which is what the entrepreneur can act on.
        missing = [s for s in REQUIRED_SLOTS if not records['slot_values'].get(s)]
        if missing:
            raise CqRefused('CQ_PUBLICATION_SLOTS_UNRESOLVED', 409)
        composed, assignment, stimuli = self._compose(records, contract, policy)
        revision = int(records['assessment']['revision'])
        manifest = builder.build_manifest(
            composed, contract=contract, policy=policy, assignment=assignment,
            stimuli=stimuli,
            bank_version=_bank_version(assessment_id, revision),
            version='1', title=_title(records['slot_values']),
            consent_version=CONSENT_VERSION, consent_text=CONSENT_TEXT)
        plan = builder.plan(manifest, composed, contract, policy)
        return {'contract': contract, 'policy': policy, 'reference': reference,
                'records': records, 'composed': composed, 'manifest': manifest,
                'plan': plan}

    # -- read -------------------------------------------------------------

    def preview(self, assessment_id: str, actor_id: str) -> dict:
        """What publishing would do, without writing anything.

        The button calls this first so the entrepreneur sees the instrument they
        are about to publish -- question count, authorised count, the release
        id, and whether it is already published -- rather than a spinner and a
        receipt.
        """
        self._require_enabled()
        aid, actor = self._identities(assessment_id, actor_id)
        with self.store.open(actor, role=PUBLICATION_ROLE) as unit:
            prepared = self._prepare(unit, aid, str(actor))
            return self._report(unit, prepared, aid, actor, state='PREVIEW')

    # -- write ------------------------------------------------------------

    def publish(self, assessment_id: str, actor_id: str, *,
                optional_context: bool = False, mode: str = 'C0',
                q02_policy: str = 'UNDECIDED') -> dict:
        """Publish, then bind the campaign, in one transaction.

        Order is deliberate and is the builder's: verify the manifest, compare
        it against the persisted M2/BCB records *inside this transaction*, and
        only then write. A refusal at any point leaves no bank version, no
        release and no assignment, because the store rolls back and no commit
        happened.
        """
        self._require_enabled()
        aid, actor = self._identities(assessment_id, actor_id)
        from sitewise.project1 import cq_entrepreneur_adapter as adapter

        with self.store.open(actor, role=PUBLICATION_ROLE) as unit:
            prepared = self._prepare(unit, aid, str(actor))
            if optional_context or mode != 'C0' or q02_policy != 'UNDECIDED':
                # The builder takes these as arguments with fail-closed defaults
                # and refuses to choose them on the owner's behalf. Until the
                # owner decides, a caller asking for a non-default is refused
                # rather than quietly given the default.
                raise CqRefused('CQ_PUBLICATION_OPTIONS_UNAUTHORISED', 409)

            plan = prepared['plan']
            if plan['authorized_count'] < 1:
                # A release with no authorised question is not a questionnaire.
                # The builder would happily persist it; refusing here keeps an
                # empty instrument out of the release table.
                raise CqRefused('CQ_PUBLICATION_NO_AUTHORIZED_QUESTIONS', 409)

            published = builder.publish(
                unit, prepared['manifest'], prepared['policy'],
                contract=prepared['contract'], reference=prepared['reference'],
                actor_id=str(actor), source_class=SOURCE_CLASS,
                templates=adapter.governed_templates())
            campaign = self._bind_campaign(unit, aid, actor, published['release']['id'])
            unit.commit()
            return self._report(unit, prepared, aid, actor, state=published['state'],
                                published=published, campaign=campaign)

    # -- helpers ----------------------------------------------------------

    def _bind_campaign(self, unit, assessment_id: str, actor: UUID, release_id) -> dict:
        """Bind the release to the assessment's one campaign, or refuse.

        ``UNIQUE(assessment_id)`` means a republish reuses the campaign that
        already exists. A campaign pointing at a *different* release is refused,
        not adopted: adopting it would rebind a questionnaire that may already
        have respondents to a different instrument, and supersession is a
        migration decision (DD-095), not a side effect of pressing Publish.
        """
        existing = unit.campaign_for_assessment(assessment_id)
        if existing is not None:
            if str(existing['release_id']) == str(release_id):
                return existing
            raise CqRefused('CQ_PUBLICATION_RELEASE_SUPERSEDED', 409)
        campaign = unit.create_campaign(assessment_id, actor, release_id)
        if campaign is None:
            # `create_campaign` inserts ON CONFLICT DO NOTHING and re-reads. A
            # None means the row exists but the publisher's policy cannot see
            # it -- i.e. it belongs to another owner. Refuse rather than report
            # a phantom success.
            raise CqRefused('CQ_PUBLICATION_CAMPAIGN_UNAVAILABLE', 409)
        return campaign

    def _report(self, unit, prepared, assessment_id, actor, *, state,
                published=None, campaign=None) -> dict:
        plan, manifest = prepared['plan'], prepared['manifest']
        release_id = builder.release_id_for(plan['manifest_hash'])
        stored = unit.release_by_manifest_hash(plan['manifest_hash'])
        existing_campaign = unit.campaign_for_assessment(assessment_id)
        report = {
            'contract_version': CONTRACT_VERSION,
            'state': state,
            'assessment_id': assessment_id,
            'actor_id': str(actor),
            'principal': PUBLICATION_ROLE,
            'release_id': str(release_id),
            'manifest_hash': plan['manifest_hash'],
            'already_published': stored is not None,
            'question_count': plan['question_count'],
            'authorized_count': plan['authorized_count'],
            'excluded_count': plan['excluded_count'],
            'authorized_question_ids': manifest['authorized_question_ids'],
            'exclusions': [{'question_id': q['question_id'], 'reasons': q['reasons']}
                           for q in plan['questions'] if not q['authorized']],
            'stimuli': plan['stimuli'],
            'source_class': SOURCE_CLASS,
            'bank_version': manifest['bank_version'],
            'binding': {
                'assessment_revision': manifest['assignment']['assessment_revision'],
                'confirmation_id': manifest['assignment']['confirmation_id'],
                'bcb_context_id': manifest['assignment']['bcb_context_id'],
                'bcb_packet_hash': manifest['assignment']['bcb_packet_hash'],
            },
            # Stated so a caller cannot read this as fielding authority.
            'production_fielding_authorized': False,
            'runtime_activated': False,
        }
        if existing_campaign is not None:
            report['campaign'] = {
                'campaign_id': str(existing_campaign['id']),
                'release_id': str(existing_campaign['release_id']),
                'release_matches': str(existing_campaign['release_id']) == str(release_id),
            }
        if campaign is not None:
            report['campaign'] = {
                'campaign_id': str(campaign['id']),
                'release_id': str(campaign['release_id']),
                'release_matches': True,
            }
        if published is not None:
            report['assignments'] = len(published['assignments'])
            report['release_state'] = published['state']
        return report

    @staticmethod
    def _require_enabled() -> None:
        if not settings.cq_publication_enabled:
            raise CqRefused('CQ_PUBLICATION_DISABLED', 503)

    @staticmethod
    def _identities(assessment_id, actor_id) -> tuple[str, UUID]:
        try:
            aid = str(UUID(str(assessment_id)))
        except (ValueError, TypeError):
            raise CqRefused('CQ_PUBLICATION_ASSESSMENT_INVALID', 400) from None
        if not isinstance(actor_id, UUID):
            try:
                actor_id = UUID(str(actor_id))
            except (ValueError, TypeError):
                raise CqRefused('CQ_ACTOR_REQUIRED', 401) from None
        return aid, actor_id


__all__ = ['CONTRACT_VERSION', 'CONSENT_TEXT', 'CONSENT_VERSION',
           'PublicationService', 'SOURCE_CLASS']
