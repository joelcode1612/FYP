"""Versioned M2-20 review, explicit issue decisions, M2-21 confirmation.

BDJ findings and original entrepreneur declarations remain distinct. Neither a
KEEP_ORIGINAL event nor an acknowledged finding proves that a conflict is
resolved. No QJ, QG, questionnaire launch or reporting activation occurs here.
"""
import hashlib
import json
from uuid import UUID

from sitewise.core.exceptions import ConflictError, NotFoundError
from sitewise.domain.m2_rules import missing_required_items
from sitewise.domain.bdj_rules import RULE_VERSION
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
            if self.repo.get_evaluation(assessment_id, expected_revision, RULE_VERSION) is None:
                raise ConflictError("The current revision has not been evaluated by BDJ.")
            if self.repo.get_review(assessment_id, expected_revision) is None:
                raise ConflictError("Review the current answer revision (M2-20) first.")
            items = self.repo.list_items(assessment["instrument_id"])
            answers = self.repo.get_latest_answers(assessment_id, expected_revision)
            missing = missing_required_items(items, answers)
            if missing:
                raise ConflictError("Required answers are missing for this instrument version: " + ", ".join(missing))
            current_findings = [f for f in self.repo.get_findings(assessment_id, expected_revision)
                                if f["rule_version"] == RULE_VERSION]
            current_issues = {str(f["id"]) for f in current_findings}
            if (set(acknowledged_issue_ids) != current_issues or
                len(acknowledged_issue_ids) != len(current_issues)):
                raise ConflictError("Acknowledge exactly the current candidate findings.")
            decisions = self.repo.latest_clarifications(assessment_id, expected_revision)
            if any(fid not in decisions or decisions[fid]["decision"] != "KEEP_ORIGINAL"
                   for fid in current_issues):
                raise ConflictError("Each current finding needs a persisted KEEP_ORIGINAL decision; REVIEW_LATER is not confirmation.")
            snapshot = {
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
        record = self.repo.get_confirmation(confirmation_id, actor_id)
        if record is None:
            raise NotFoundError("Confirmation snapshot not found.")
        text = exact_text.strip()
        if not text or len(text) > 1000:
            raise ValueError("Research uncertainty must be 1–1000 characters.")
        try:
            result = self.repo.create_uncertainty(confirmation_id, actor_id, text)
            self.repo.commit()
            return result
        except Exception:
            self.repo.rollback()
            raise
