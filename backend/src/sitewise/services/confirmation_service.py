"""Versioned M2-20 review, explicit issue decisions, M2-21 confirmation.

BDJ findings and original entrepreneur declarations remain distinct. Neither a
KEEP_ORIGINAL event nor an acknowledged finding proves that a conflict is
resolved. No QJ, QG, questionnaire launch or reporting activation occurs here.
"""
import hashlib
import json
from uuid import UUID

from sitewise.core.exceptions import ConflictError, NotFoundError
from sitewise.domain.m2_rules import missing_required_items, validate_m2_answer, resolve_m2_items, derived_m2_selections
from sitewise.domain.bdj_candidate_rules import RULE_VERSION
from sitewise.domain.m2_provenance import confirmation_pins
from sitewise.services.ports.m2_repository_port import M2RepositoryPort


# Candidate UI actions; these do not replace source-governed review states.
CLARIFICATION_ACTIONS = frozenset({"KEEP_ORIGINAL", "REVIEW_LATER"})


class ConfirmationService:
    def __init__(self, repository: M2RepositoryPort):
        self.repo = repository

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

    def record_review(self, assessment_id: UUID, actor_id: UUID, expected_revision: int) -> dict:
        try:
            assessment = self.repo.get_assessment_for_update(assessment_id, actor_id)
            if assessment is None:
                raise NotFoundError("Assessment not found.")
            if assessment["revision"] != expected_revision:
                raise ConflictError("Assessment changed; review the current revision.")
            if self.repo.get_evaluation(assessment_id, expected_revision, RULE_VERSION) is None:
                raise ConflictError("The current revision must receive a BDJ evaluation before review.")
            review = self.repo.get_review(assessment_id, expected_revision)
            if review is None:
                review = self.repo.add_review(assessment_id, expected_revision, actor_id)
            self.repo.commit()
            return review
        except Exception:
            self.repo.rollback()
            raise

    def confirm(self, assessment_id: UUID, actor_id: UUID, *, expected_revision: int,
                acknowledged_issue_ids: list[str]) -> dict:
        try:
            assessment = self.repo.get_assessment_for_update(assessment_id, actor_id)
            if assessment is None:
                raise NotFoundError("Assessment not found.")
            instrument = self.repo.get_instrument(assessment["instrument_id"])
            if instrument is None or instrument["approval_state"] != "AUTHORIZED":
                raise ConflictError("No authorized instrument version may be confirmed.")
            if assessment["revision"] != expected_revision:
                raise ConflictError("Assessment changed; reload before confirming.")
            evaluation = self.repo.get_evaluation(assessment_id, expected_revision, RULE_VERSION)
            if evaluation is None:
                raise ConflictError("The current revision has not been evaluated by BDJ.")
            review = self.repo.get_review(assessment_id, expected_revision)
            if review is None:
                raise ConflictError("Review the current answer revision (M2-20) first.")
            items = self.repo.list_items(assessment["instrument_id"])
            answers = self.repo.get_latest_answers(assessment_id, expected_revision)
            item_map = {item['item_key']: item for item in resolve_m2_items(items, answers)}
            for key, answer in answers.items():
                item = item_map.get(key)
                if item is None or answer['item_version_id'] != item['id']:
                    raise ConflictError('An answer has an invalid instrument item binding.')
                if item.get('applicable') is not False:
                    validate_m2_answer(item, answer['answer_state'], answer['value_json'])
            missing = missing_required_items(items, answers)
            if missing:
                raise ConflictError("Required answers are missing for this instrument version: " + ", ".join(missing))
            current_findings = [f for f in self.repo.get_findings(assessment_id, expected_revision)
                                if f["rule_version"] == RULE_VERSION]
            current_issues = {str(f["id"]) for f in current_findings}
            answer_ids = {str(answer['id']) for answer in answers.values()}
            if any(not finding['source_answer_ids'] or
                   not set(finding['source_answer_ids']).issubset(answer_ids)
                   for finding in current_findings):
                raise ConflictError('A finding has an invalid source answer binding.')
            if (set(acknowledged_issue_ids) != current_issues or
                len(acknowledged_issue_ids) != len(current_issues)):
                raise ConflictError("Acknowledge exactly the current candidate findings.")
            decisions = self.repo.latest_clarifications(assessment_id, expected_revision)
            if any(fid not in decisions or decisions[fid]["decision"] != "KEEP_ORIGINAL"
                   for fid in current_issues):
                raise ConflictError("Each current finding needs a persisted KEEP_ORIGINAL decision; REVIEW_LATER is not confirmation.")
            snapshot = {
                "derived_selections": derived_m2_selections(items, answers),
                "inactive_answer_keys": [q['item_key'] for q in resolve_m2_items(items, answers)
                                         if q.get('applicable') is False and q['item_key'] in answers],
                **confirmation_pins(RULE_VERSION,evaluation,review,current_findings,items),
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
                "unresolved_candidate_findings": sorted(current_issues),
                "finding_decision_event_refs": {
                    fid: str(decisions[fid]["id"]) for fid in sorted(current_issues)
                },
                "research_uncertainty_confirmed": False,
                "qj_handoff_authorized": False,
            }
            digest = hashlib.sha256(json.dumps(
                snapshot, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")).hexdigest()
            if not self.repo.mark_confirmed(assessment_id, expected_revision):
                raise ConflictError("Assessment was edited or already confirmed; reload.")
            result = self.repo.create_confirmation(
                assessment_id, expected_revision, actor_id, snapshot, digest,
                sorted(current_issues))
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
        objective = objective.strip()
        if not objective:
            raise ValueError("Supply a research objective.")
        try:
            record = self.repo.get_confirmation(confirmation_id, actor_id)
            if record is None:
                raise NotFoundError("Current confirmation not found.")
            assessment = self.repo.get_assessment_for_update(record["assessment_id"], actor_id)
            record = self.repo.get_confirmation(confirmation_id, actor_id)
            if not assessment or not record or record["assessment_revision"] != revision:
                raise ConflictError("Reload the current confirmation.")
            snapshot = record["snapshot_json"]
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
                if finding_id or snapshot["instrument_version"] != "M2V1-20261114-1":
                    raise ValueError("Entrepreneur objectives require a current M2V1 research intention.")
                keys = {"M2V1-09", "M2V1-10", "M2V1-11"}
                rows = {a["item_key"]: a for a in snapshot["answer_revisions"]
                        if a["item_key"] in keys and a["answer_state"] == "ANSWERED"
                        and a["item_key"] not in snapshot["inactive_answer_keys"]}
                derived = [d for d in snapshot["derived_selections"] if d["item_key"] == "M2V1-10"]
                topics = rows.get("M2V1-09", {}).get("value", [])
                priority = derived[0]["value"] if derived else rows.get("M2V1-10", {}).get("value")
                if priority not in topics or "NONE" in topics or "M2V1-11" not in rows:
                    raise ConflictError("Confirm an active research priority and decision status.")
                source.update(answer_revisions=rows, derived_selections=derived, priority=priority)
            result = self.repo.create_uncertainty(confirmation_id, actor_id, objective)
            self.repo.save_objective_source(result["id"], source)
            self.repo.commit()
            return {**result, "source": source, "qj_execution_authorized": False}
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

    def persist_candidate(self, objective_id, actor_id, revision, context, result, evidence):
        from uuid import uuid5, NAMESPACE_URL
        from sitewise.project1.contracts import digest
        try:
            self.repo.get_assessment_for_update(UUID(context["source"]["assessment_id"]), actor_id)
            if self.qj_context(objective_id, actor_id, revision) != context:
                raise ConflictError("Research source changed.")
            receipt = {"context": context, "evaluation": result, "candidate": evidence}
            version = uuid5(NAMESPACE_URL, digest(receipt))
            self.repo.persist_candidate(version, objective_id, receipt)
            self.repo.commit()
            return str(version)
        except Exception:
            self.repo.rollback()
            raise

    def record_owner_review(self, version, reviewer, decision, rationale):
        try:
            rationale = rationale.strip()
            if not rationale:
                raise ValueError("Supply a review rationale.")
            row = self.repo.record_owner_review(version, reviewer, decision, rationale)
            if row is None:
                raise NotFoundError("No current pending review assignment.")
            self.repo.commit()
            return {**row, "fielding_authorized": False, "scientific_acceptance": False}
        except Exception:
            self.repo.rollback()
            raise
