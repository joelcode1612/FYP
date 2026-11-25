"""Versioned M2-20 review, explicit issue decisions, M2-21 confirmation.

BDJ findings and original entrepreneur declarations remain distinct. Neither a
KEEP_ORIGINAL event nor an acknowledged finding proves that a conflict is
resolved. No QJ, QG, questionnaire launch or reporting activation occurs here.
"""
import hashlib
import json
from uuid import UUID

from sitewise.core.exceptions import ConflictError, NotFoundError
from sitewise.modules.decision_engine.domain.m2_rules import missing_required_items, validate_m2_answer, resolve_m2_items, derived_m2_selections
from sitewise.domain.bdj_candidate_rules import RULE_VERSION
from sitewise.domain.m2_provenance import (
    declaration_pins, DECLARATION_SNAPSHOT_VERSIONS, M2ConfirmationConflict,
    SNAPSHOT_VERSION,
)
from sitewise.project1.ai_processing_consent import not_granted as not_granted_consent
from sitewise.project1.ai_processing_consent import not_granted_qg as not_granted_qg_consent
from sitewise.services.instrument_authorization import instrument_is_usable
from sitewise.services.ports.m2_repository_port import M2RepositoryPort


# Candidate UI actions; these do not replace source-governed review states.
CLARIFICATION_ACTIONS = frozenset({"KEEP_ORIGINAL", "REVIEW_LATER"})

#: The three items that carry an entrepreneur's research intention, per
#: instrument version: (topics, priority, decision status). M2V2 asks the same
#: three questions as M2V1 under its own item keys, so the objective path is
#: keyed on the instrument rather than pinned to one version. An instrument
#: absent from this map has no adopted research intention and cannot produce an
#: entrepreneur objective -- the refusal is explicit, never a silent default.
RESEARCH_INTENTION_ITEMS: dict[str, tuple[str, str, str]] = {
    "M2V1-20261114-1": ("M2V1-09", "M2V1-10", "M2V1-11"),
    "M2V2-20261122-1": ("M2V2-09", "M2V2-10", "M2V2-11"),
}


def admitted_objective_refusal(row, *, confirmation_id, assessment_id, revision):
    """Why an admission may not become a research objective, or ``None``.

    Pure: no I/O, no session, no clock. Every refusal carries its own code so a
    caller can tell an unapproved proposal from a stale one from a foreign one —
    a single "cannot admit" would hide which action is actually missing.

    ``row`` is the admission joined to its proposal. ``None`` means the row was
    not visible to this owner, which is deliberately the same answer as "does
    not exist" so an id cannot be probed for existence.
    """
    if row is None:
        return ('BDJ_ADMISSION_NOT_FOUND',
                'Admission not found for this owner.')
    if (str(row['confirmation_id']) != str(confirmation_id) or
            int(row['confirmation_revision']) != int(revision) or
            str(row['assessment_id']) != str(assessment_id)):
        return ('BDJ_ADMISSION_CONFIRMATION_MISMATCH',
                'The admission belongs to a different confirmation or revision.')
    if row['admission_decision'] != 'ADMITTED':
        return ('BDJ_ADMISSION_NOT_ADMITTED',
                'The owner has not admitted this objective.')
    if row['review_state'] != 'APPROVED':
        return ('BDJ_PROPOSAL_NOT_APPROVED',
                'The proposal is not approved, so no objective can be recorded.')
    if row['objective_id'] is None:
        return ('BDJ_ADMISSION_BINDS_NO_FIXED_OBJECTIVE',
                'The admission binds no fixed objective, so it cannot become a '
                'measurement target. Register the objective before admitting it.')
    if row['policy_disposition'] == 'ENTREPRENEUR_CLARIFICATION':
        return ('BDJ_ADMISSION_CLARIFICATION_PENDING',
                'The policy still requires an entrepreneur clarification.')
    from sitewise.project1.objective_admission import proposal_hash
    if row['proposal_hash'] != proposal_hash(dict(row)):
        return ('BDJ_ADMISSION_PROPOSAL_CHANGED',
                'The proposal changed after it was admitted; reload and re-review.')
    if not (row.get('research_objective') or '').strip():
        return ('BDJ_ADMISSION_OBJECTIVE_EMPTY',
                'The admitted proposal carries no research objective.')
    return None


class ConfirmationService:
    def __init__(self, repository: M2RepositoryPort):
        self.repo = repository

    def _declarations(self, assessment):
        """The same saved, applicable declaration validation for review/confirm."""
        instrument = self.repo.get_instrument(assessment['instrument_id'])
        if not instrument_is_usable(instrument):
            raise M2ConfirmationConflict('M2_INSTRUMENT_UNAUTHORIZED',
                'An authorized instrument version is required before confirmation.')
        items = self.repo.list_items(assessment['instrument_id'])
        answers = self.repo.get_latest_answers(assessment['id'], assessment['revision'])
        item_map = {item['item_key']: item for item in resolve_m2_items(items, answers)}
        if not items or len(item_map) != len(items):
            raise M2ConfirmationConflict('M2_ITEM_BINDING_INVALID', 'The questionnaire definitions could not be verified.')
        for key, answer in answers.items():
            item = item_map.get(key)
            if (item is None or answer['item_version_id'] != item['id'] or
                    answer['assessment_id'] != assessment['id'] or
                    not 0 < answer['assessment_revision'] <= assessment['revision']):
                raise M2ConfirmationConflict('M2_ANSWER_BINDING_INVALID', 'A saved answer has an invalid source binding.')
            # Previously applicable answers remain immutable history; only
            # active declarations are eligible inputs to this confirmation.
            if item.get('applicable') is not False:
                validate_m2_answer(item, answer['answer_state'], answer['value_json'])
        if missing_required_items(items, answers):
            raise M2ConfirmationConflict('M2_REQUIRED_DECLARATIONS_MISSING',
                'Complete and save the required applicable M2 declarations before reviewing or confirming.')
        return instrument, items, answers

    def record_finding_decision(
        self, assessment_id: UUID, actor_id: UUID, *,
        finding_id: UUID, expected_revision: int,
        decision: str, request_id: UUID,
    ) -> dict:
        """Append an explicit review action; never edit M2 or mark an issue fixed."""
        if decision not in CLARIFICATION_ACTIONS:
            raise ValueError("Unsupported clarification action.")
        try:
            assessment = self.repo.get_assessment_for_update(assessment_id, actor_id)
            if assessment is None:
                raise NotFoundError("Assessment not found.")
            # A replay after a successful request must not duplicate history.
            replay = self.repo.get_clarification_by_request(assessment_id, request_id)
            if replay is not None:
                if (replay["assessment_revision"] != expected_revision or
                    replay["finding_id"] != finding_id or
                    replay["actor_user_id"] != actor_id or
                    replay["decision"] != decision):
                    raise ConflictError("The clarification request ID was previously used for another action.")
                self.repo.commit()
                return {"event": replay, "answer_changed": False,
                        "finding_resolved": False, "replayed": True}
            if assessment["revision"] != expected_revision:
                raise ConflictError("Assessment changed; reload findings before deciding.")
            if assessment["confirmed_revision"] == expected_revision:
                raise ConflictError("This revision is confirmed; review changes require a new revision.")
            finding = self.repo.get_finding(assessment_id, expected_revision, finding_id)
            if finding is None or finding["rule_version"] != RULE_VERSION:
                raise NotFoundError("Current assessment finding for this BDJ ruleset not found.")
            event = self.repo.add_clarification_event(
                assessment_id, expected_revision, finding_id,
                actor_id, decision, request_id)
            self.repo.commit()
            return {"event": event, "answer_changed": False,
                    "finding_resolved": False, "replayed": False}
        except Exception:
            self.repo.rollback()
            raise

    def record_review(self, assessment_id: UUID, actor_id: UUID, expected_revision: int,
                      *, marketplace_assessment_id: UUID | None = None) -> dict:
        try:
            assessment = self.repo.get_assessment_for_update(assessment_id, actor_id)
            if assessment is None:
                raise NotFoundError("Assessment not found.")
            if marketplace_assessment_id is not None and not self.repo.lock_active_marketplace_binding(
                    assessment_id, actor_id, marketplace_assessment_id):
                raise ConflictError('The linked assessment changed; reload before reviewing.')
            if assessment["revision"] != expected_revision:
                raise M2ConfirmationConflict('M2_REVISION_STALE', 'Assessment changed; reload the current revision before reviewing.')
            self._declarations(assessment)
            review = self.repo.get_review(assessment_id, expected_revision)
            if review is None:
                review = self.repo.add_review(assessment_id, expected_revision, actor_id)
            self.repo.commit()
            return review
        except Exception:
            self.repo.rollback()
            raise

    def confirm(self, assessment_id: UUID, actor_id: UUID, *, expected_revision: int,
                acknowledged_issue_ids: list[str], marketplace_assessment_id: UUID | None = None,
                ai_processing: dict | None = None,
                ai_processing_qg: dict | None = None) -> dict:
        try:
            assessment = self.repo.get_assessment_for_update(assessment_id, actor_id)
            if assessment is None:
                raise NotFoundError("Assessment not found.")
            if marketplace_assessment_id is not None and not self.repo.lock_active_marketplace_binding(
                    assessment_id, actor_id, marketplace_assessment_id):
                raise ConflictError('The linked assessment changed; reload before confirming.')
            if assessment["revision"] != expected_revision:
                raise M2ConfirmationConflict('M2_REVISION_STALE', 'Assessment changed; reload before confirming.')
            instrument, items, answers = self._declarations(assessment)
            if acknowledged_issue_ids:
                raise M2ConfirmationConflict('M2_DECLARATION_FINDING_ACK_NOT_ALLOWED',
                    'Confirm declarations separately from later BDJ finding review. Reload this questionnaire.')
            review = self.repo.get_review(assessment_id, expected_revision)
            if review is None:
                raise M2ConfirmationConflict('M2_DECLARATION_REVIEW_REQUIRED', 'Review the current saved M2 declarations first.')
            if (review['assessment_id'] != assessment_id or review['assessment_revision'] != expected_revision
                    or review['actor_user_id'] != actor_id):
                raise M2ConfirmationConflict('M2_DECLARATION_REVIEW_BINDING_INVALID', 'The declaration review does not match this owner and revision.')
            snapshot = {
                "derived_selections": derived_m2_selections(items, answers),
                "inactive_answer_keys": [q['item_key'] for q in resolve_m2_items(items, answers)
                                         if q.get('applicable') is False and q['item_key'] in answers],
                **declaration_pins(review, items),
                "assessment_id": str(assessment_id),
                "instrument_id": str(assessment["instrument_id"]),
                "instrument_version": instrument["version_tag"],
                "instrument_digest": instrument["schema_digest"],
                "assessment_revision": expected_revision,
                "answer_revisions": [
                    {"item_key": k, "answer_revision_id": str(a["id"]),
                     "item_version_id": str(a["item_version_id"]),
                     "answer_state": a["answer_state"], "value": a["value_json"]}
                    for k, a in sorted(answers.items())
                ],
                "unresolved_candidate_findings": [],
                "finding_decision_event_refs": {},
                "research_uncertainty_confirmed": False,
                "qj_handoff_authorized": False,
                # Explicit and always present. A confirmation that does not
                # carry a grant records that absence, so no reader can mistake
                # a v4 declaration confirmation for cloud permission, and no
                # v3 row can be reinterpreted as one either.
                "ai_processing": ai_processing or not_granted_consent(),
                # A *second*, separately versioned permission. Generating
                # candidate questions is a different act from deriving
                # objectives, so it has its own block and its own digest. A
                # snapshot written before this contract existed simply has no
                # such key, and a QG dispatch against it is refused rather than
                # inheriting the objective grant.
                "ai_processing_qg": ai_processing_qg or not_granted_qg_consent(),
            }
            digest = hashlib.sha256(json.dumps(
                snapshot, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")).hexdigest()
            if not self.repo.mark_confirmed(assessment_id, expected_revision):
                raise M2ConfirmationConflict('M2_ALREADY_CONFIRMED_OR_CHANGED', 'Assessment was edited or already confirmed; reload saved confirmation.')
            result = self.repo.create_confirmation(
                assessment_id, expected_revision, actor_id, snapshot, digest,
                [])
            self.repo.commit()
            return result
        except Exception:
            self.repo.rollback()
            raise

    def confirm_uncertainty(self, confirmation_id: UUID, actor_id: UUID, exact_text: str) -> dict:
        """Separate entrepreneur intent confirmation; never calls QJ."""
        text = exact_text.strip()
        if not text or len(text) > 1000:
            raise ValueError("Research uncertainty must be 1–1000 characters.")
        try:
            record = self.repo.get_confirmation(confirmation_id, actor_id)
            if record is None:
                raise NotFoundError('Confirmation snapshot not found.')
            assessment = self.repo.get_assessment_for_update(record['assessment_id'], actor_id)
            if assessment is None or self.repo.get_confirmation(confirmation_id, actor_id) is None:
                raise ConflictError('The confirmation changed; reload before confirming uncertainty.')
            result = self.repo.create_uncertainty(confirmation_id, actor_id, text)
            self.repo.commit()
            return result
        except Exception:
            self.repo.rollback()
            raise

    def confirm_objective(self, confirmation_id, actor_id, revision, objective, origin, finding_id):
        if not objective.strip():
            raise ValueError("Supply a research objective.")
        try:
            record = self.repo.get_confirmation(confirmation_id, actor_id)
            if record is None:
                raise NotFoundError("Current confirmation not found.")
            # Verify the full immutable snapshot, including its digest, answer
            # versions and review pins. This read releases its lock on exit;
            # reacquire and compare the same identity below before writing.
            from sitewise.services.m2_service import M2Service
            with M2Service(self.repo).locked_confirmed_source(
                    record['assessment_id'], actor_id,
                    confirmation_id=confirmation_id, expected_revision=revision) as verified:
                verified_digest = verified['snapshot_digest']
            assessment = self.repo.get_assessment_for_update(record["assessment_id"], actor_id)
            record = self.repo.get_confirmation(confirmation_id, actor_id)
            if (not assessment or not record or record["assessment_revision"] != revision or
                    assessment['revision'] != revision or assessment['confirmed_revision'] != revision or
                    record['snapshot_digest'] != verified_digest):
                raise ConflictError("Reload the current confirmation.")
            snapshot = record["snapshot_json"]
            if snapshot.get('snapshot_contract_version') in DECLARATION_SNAPSHOT_VERSIONS and origin == 'BDJ':
                # Declaration confirmation is not a confirmed BDJ uncertainty.
                # No post-confirmation finding-authority adapter is adopted yet.
                raise M2ConfirmationConflict('M2_UNCERTAINTY_LINK_REQUIRED',
                    'A source-linked BDJ finding review is not available yet. '
                    'No research objective has been confirmed; review and confirmation '
                    'must be recorded before proceeding.')
            source = {"origin": origin, "confirmation_id": str(confirmation_id),
                      "assessment_id": str(record["assessment_id"]), "assessment_revision": revision,
                      "snapshot_digest": record["snapshot_digest"]}
            if origin == "BDJ":
                fid = str(finding_id)
                decision = snapshot["finding_decision_event_refs"].get(fid)
                if not decision or fid not in snapshot["unresolved_candidate_findings"]:
                    raise ConflictError("Finding does not belong to this confirmation.")
                source.update(finding_id=fid, finding_decision_id=decision)
            else:
                # The research intention is three items, not three fixed keys:
                # M2V2 carries the same questions as M2V1 under its own item
                # keys. Before this map existed the branch was pinned to M2V1 by
                # instrument version, so an M2V2 declaration could not record a
                # research objective at all and stage 3 was unreachable for every
                # M2V2 assessment. The validation below is unchanged -- priority
                # must be one of the selected topics, NONE is refused, and a
                # decision status must be present.
                keys = RESEARCH_INTENTION_ITEMS.get(snapshot.get("instrument_version"))
                if finding_id or keys is None:
                    raise ValueError(
                        "Entrepreneur objectives require an adopted research intention "
                        "for this instrument.")
                topics_key, priority_key, decision_key = keys
                rows = {a["item_key"]: a for a in snapshot["answer_revisions"]
                        if a["item_key"] in set(keys) and a["answer_state"] == "ANSWERED"
                        and a["item_key"] not in snapshot["inactive_answer_keys"]}
                derived = [d for d in snapshot["derived_selections"]
                           if d["item_key"] == priority_key]
                topics = rows.get(topics_key, {}).get("value", [])
                priority = (derived[0]["value"] if derived
                            else rows.get(priority_key, {}).get("value"))
                if priority not in topics or "NONE" in topics or decision_key not in rows:
                    raise ConflictError("Confirm an active research priority and decision status.")
                source.update(answer_revisions=rows, derived_selections=derived,
                              priority=priority,
                              research_intention_items=list(keys))
            result = self.repo.create_uncertainty(confirmation_id, actor_id, objective)
            # The ID identifies this immutable objective version. Record the
            # explicit owner action only for newly confirmed records; never
            # infer a decision for historical rows.
            if origin == 'ENTREPRENEUR':
                from hashlib import sha256
                source.update(objective_contract='entrepreneur-objective/1',
                              objective_version=str(result['id']),
                              owner_user_id=str(actor_id), owner_decision='CONFIRMED',
                              approval_status='CONFIRMED_BY_OWNER',
                              objective_text_sha256=sha256(objective.encode('utf-8')).hexdigest())
            self.repo.save_objective_source(result["id"], source)
            self.repo.commit()
            return {**result, "source": source, "qj_execution_authorized": False}
        except Exception:
            self.repo.rollback()
            raise

    #: Provenance contract for an objective recorded from a BDJ admission.
    #:
    #: A new version rather than a change to ``entrepreneur-objective/1``: the
    #: authority being consumed is different in kind. An entrepreneur objective
    #: is confirmed from M2V1 declarations; this one is admitted from a proposal
    #: review, so a reader must be able to tell them apart without inferring it.
    ADMITTED_OBJECTIVE_CONTRACT = 'bdj-admitted-objective/1'

    def confirm_admitted_objective(self, confirmation_id, actor_id, revision, *,
                                   admission_id):
        """Record a research objective from an ADMITTED BDJ objective.

        The declaration path cannot confirm a BDJ objective. ``m2-confirmation/3``
        and ``/4`` pin ``unresolved_candidate_findings = []`` and
        ``finding_decision_event_refs = {}`` by contract, so there is no finding
        link to verify — ``confirm_objective(origin='BDJ')`` refuses for exactly
        that reason, and it is right to.

        This adapter does not invent the missing link, and it does not
        manufacture a legacy M2 V1 uncertainty. It consumes the authority the
        workflow already records: an ``ADMITTED`` row in
        ``public.m2_bdj_objective_admissions`` that binds a fixed objective.
        Every identity the admission carries is re-checked against the
        confirmation being written, and nothing here authorises QG, fielding or
        publication.
        """
        from sqlalchemy import text

        if not admission_id:
            raise ValueError('Supply the admission that authorises this objective.')
        try:
            record = self.repo.get_confirmation(confirmation_id, actor_id)
            if record is None:
                raise NotFoundError("Current confirmation not found.")
            from sitewise.services.m2_service import M2Service
            with M2Service(self.repo).locked_confirmed_source(
                    record['assessment_id'], actor_id,
                    confirmation_id=confirmation_id, expected_revision=revision) as verified:
                verified_digest = verified['snapshot_digest']
            record = self.repo.get_confirmation(confirmation_id, actor_id)
            if (record is None or record['assessment_revision'] != revision or
                    record['snapshot_digest'] != verified_digest):
                raise ConflictError("Reload the current confirmation.")

            row = self.repo.session.execute(text("""
                SELECT a.admission_id, a.decision AS admission_decision,
                       a.proposal_id, a.assessment_id, a.confirmation_id,
                       a.confirmation_revision, a.source_fingerprint,
                       a.context_packet_hash, a.objective_id,
                       a.policy_disposition, a.policy_version, a.proposal_hash,
                       p.recommendation_status, p.problem_type, p.problem,
                       p.research_objective, p.reason, p.source_refs,
                       p.review_state, p.owner_user_id
                FROM public.m2_bdj_objective_admissions a
                JOIN public.m2_bdj_objective_proposals p USING (proposal_id)
                WHERE a.admission_id = :aid AND a.actor_user_id = :uid
            """), {'aid': str(admission_id), 'uid': str(actor_id)}).mappings().one_or_none()
            if row is None:
                # Absent or another owner's: the two are deliberately
                # indistinguishable, so an id cannot be probed for existence.
                raise NotFoundError("Admission not found for this owner.")

            refusal = admitted_objective_refusal(
                dict(row), confirmation_id=confirmation_id,
                assessment_id=record['assessment_id'], revision=revision)
            if refusal is not None:
                raise M2ConfirmationConflict(refusal[0], refusal[1])

            objective_text = row['research_objective'] or ''

            refs = row['source_refs']
            if isinstance(refs, (str, bytes)):
                refs = json.loads(refs)

            source = {
                'origin': 'BDJ_ADMISSION',
                'objective_contract': self.ADMITTED_OBJECTIVE_CONTRACT,
                'confirmation_id': str(confirmation_id),
                'assessment_id': str(record['assessment_id']),
                'assessment_revision': int(revision),
                'snapshot_digest': record['snapshot_digest'],
                # The authority: an explicit owner admission, not a finding link.
                'admission_id': str(row['admission_id']),
                'proposal_id': str(row['proposal_id']),
                'objective_id': row['objective_id'],
                'policy_version': row['policy_version'],
                'policy_disposition': row['policy_disposition'],
                'source_fingerprint': row['source_fingerprint'],
                'context_packet_hash': row['context_packet_hash'],
                'source_refs': refs if refs is not None else [],
                # Named explicitly so no reader mistakes this for a legacy link.
                'finding_id': None,
                'owner_user_id': str(actor_id),
                'owner_decision': 'CONFIRMED',
                'approval_status': 'CONFIRMED_BY_OWNER',
                'objective_text_sha256':
                    hashlib.sha256(objective_text.encode('utf-8')).hexdigest(),
            }
            result = self.repo.create_uncertainty(
                confirmation_id, actor_id, objective_text)
            source['objective_version'] = str(result['id'])
            self.repo.save_objective_source(result['id'], source)
            self.repo.commit()
            return {**result, "source": source,
                    "qj_execution_authorized": False,
                    "qg_execution_authorized": False,
                    "fielding_authorized": False,
                    "publication_authorized": False}
        except Exception:
            self.repo.rollback()
            raise

    def qj_context(self, objective_id, actor_id, revision):
        record = self.repo.read_current_objective(objective_id, actor_id, revision)
        if record is None:
            raise NotFoundError("Current research objective not found.")
        return {"contract_version": "qj-objective-context/1", "objective_id": str(record["id"]),
                "objective": record["exact_text"], "source": record["provenance"],
                "qj_execution_authorized": False}

    def revise_objective(self, objective_id, actor_id, revision, action, clarification):
        try:
            context = self.qj_context(objective_id, actor_id, revision)
            source = dict(context["source"])
            self.repo.get_assessment_for_update(UUID(source["assessment_id"]), actor_id)
            self.qj_context(objective_id, actor_id, revision)
            limit = self.repo.objective_limitation(objective_id)
            if not limit or limit["child_id"]:
                raise ConflictError("Current unresolved research limitation required.")
            if action == "EXPLORE":
                if clarification is not None or source.get("exploration_used") or not limit["broader_objective"]:
                    raise ConflictError("No eligible exploratory proposal.")
                objective = limit["broader_objective"]
                source["exploration_used"] = True
            else:
                if not clarification or not clarification.strip():
                    raise ValueError("Supply the missing research detail.")
                objective = context["objective"]
                source["clarification"] = clarification.strip()
            source.update(parent_objective_id=str(objective_id), action=action, limitation=limit["limitation"])
            child = self.repo.create_uncertainty(UUID(source["confirmation_id"]), actor_id, objective)
            self.repo.save_objective_source(child["id"], source)
            self.repo.link_objective_revision(objective_id, child["id"], action)
            self.repo.commit()
            return {**child, "source": source, "qj_execution_authorized": False}
        except Exception:
            self.repo.rollback()
            raise

    def question_for_review(self, version, actor_id, revision):
        question = self.repo.review_question(version)
        if question is None:
            raise NotFoundError("Current question version not found.")
        self.qj_context(question["objective_id"], actor_id, revision)
        return question

    def select_desired_option(self, version, actor_id, revision, code):
        try:
            question = self.question_for_review(version, actor_id, revision)
            context = self.qj_context(question["objective_id"], actor_id, revision)
            self.repo.get_assessment_for_update(UUID(context["source"]["assessment_id"]), actor_id)
            question = self.question_for_review(version, actor_id, revision)
            if code is not None and code not in {o["code"] for o in question["options"] if o["eligible"] is True}:
                raise ValueError("Select an eligible option of the current question.")
            self.repo.set_desired_option(version, actor_id, code)
            self.repo.commit()
            return {"question_version": version, "desired_option": code}
        except Exception:
            self.repo.rollback()
            raise

    def record_qj_limitation(self, objective_id, actor_id, revision, limitation, proposal):
        try:
            context = self.qj_context(objective_id, actor_id, revision)
            self.repo.get_assessment_for_update(UUID(context["source"]["assessment_id"]), actor_id)
            self.qj_context(objective_id, actor_id, revision)
            if context["source"].get("exploration_used"):
                proposal = None
            self.repo.record_qj_limitation(objective_id, limitation, proposal)
            self.repo.commit()
        except Exception:
            self.repo.rollback()
            raise

    def persist_candidate(self, objective_id, actor_id, revision, context, result, evidence, supersedes=None):
        from uuid import uuid5, NAMESPACE_URL
        from sitewise.project1.contracts import digest
        try:
            self.repo.get_assessment_for_update(UUID(context["source"]["assessment_id"]), actor_id)
            if self.qj_context(objective_id, actor_id, revision) != context:
                raise ConflictError("Research source changed.")
            receipt = {"context": context, "evaluation": result, "candidate": evidence}
            version = uuid5(NAMESPACE_URL, digest(receipt))
            self.repo.persist_candidate(version, objective_id, receipt, supersedes=supersedes)
            self.repo.commit()
            return str(version)
        except Exception:
            self.repo.rollback()
            raise

    def record_owner_review(self, version, reviewer, decision, rationale):
        try:
            rationale = rationale.strip()
            if not rationale:
                rationale = "No rationale provided by reviewer."
            if len(rationale) > 1000:
                raise ValueError("Review rationale must not exceed 1000 characters.")
            row = self.repo.record_owner_review(version, reviewer, decision, rationale)
            if row is None:
                raise NotFoundError("No current pending review assignment.")
            self.repo.commit()
            return {**row, "fielding_authorized": False, "scientific_acceptance": False}
        except Exception:
            self.repo.rollback()
            raise
