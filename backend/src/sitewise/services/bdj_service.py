"""Version-pinned deterministic candidate findings and Business Understanding view.

No LLM or externally verified data. Rules never edit entrepreneur answers.
An evaluation receipt proves software execution, not scientific validity.
"""
from uuid import UUID

from sitewise.core.exceptions import NotFoundError
from sitewise.domain.bdj_candidate_rules import (
    RULE_VERSION, RULE_CATALOGUE, evaluate_candidate_issues,
    interpretation_notices,
)
from sitewise.services.ports.m2_repository_port import M2RepositoryPort


class BDJService:
    def __init__(self, repository: M2RepositoryPort):
        self.repo = repository

    def evaluate(self, assessment_id: UUID, actor_id: UUID) -> dict:
        try:
            # Owner-scoped lock closes edit/evaluate races on PostgreSQL.
            assessment = self.repo.get_assessment_for_update(assessment_id, actor_id)
            if assessment is None:
                raise NotFoundError("Assessment not found.")
            rev = assessment["revision"]
            answers = self.repo.get_latest_answers(assessment_id, rev)
            for proposal in evaluate_candidate_issues(answers):
                if self.repo.find_current_finding(
                    assessment_id, rev, proposal["rule_id"], RULE_VERSION
                ) is None:
                    self.repo.create_finding(assessment_id, rev, proposal)
            if self.repo.get_evaluation(assessment_id, rev, RULE_VERSION) is None:
                self.repo.add_evaluation(assessment_id, rev, RULE_VERSION)
            self.repo.commit()
        except Exception:
            self.repo.rollback()
            raise
        return self.read_worksheet(assessment_id, actor_id)

    def read_worksheet(self, assessment_id: UUID, actor_id: UUID) -> dict:
        assessment = self.repo.get_assessment(assessment_id, actor_id)
        if assessment is None:
            raise NotFoundError("Assessment not found.")
        rev = assessment["revision"]
        answers = self.repo.get_latest_answers(assessment_id, rev)
        items = self.repo.list_items(assessment["instrument_id"])
        instrument = self.repo.get_instrument(assessment["instrument_id"])
        # A prior ruleset's findings may remain in the same assessment revision.
        # Do not silently mix those findings into the current review/confirmation.
        active_findings = [f for f in self.repo.get_findings(assessment_id, rev)
                           if f["rule_version"] == RULE_VERSION]
        eval_record = self.repo.get_evaluation(assessment_id, rev, RULE_VERSION)
        current_decisions = self.repo.latest_clarifications(assessment_id, rev)
        active_ids = {str(f["id"]) for f in active_findings}
        return {
            "assessment_id": str(assessment_id),
            "revision": rev,
            "instrument_id": str(assessment["instrument_id"]),
            "instrument_version": instrument["version_tag"] if instrument else None,
            "rule_version": RULE_VERSION,
            "evaluation_state": "EVALUATED_CANDIDATE" if eval_record else "NOT_EVALUATED",
            "business_description": answers.get("M2-04", {}).get("value_json")
                if answers.get("M2-04", {}).get("answer_state") == "ANSWERED" else None,
            "declared_m2_answers": [
                {"item_key": item["item_key"], "question": item["question_text"],
                 "answer_state": answers[item["item_key"]]["answer_state"],
                 "value": answers[item["item_key"]]["value_json"],
                 "source_answer_revision_id": str(answers[item["item_key"]]["id"]),
                 "source_item_version_id": str(item["id"])}
                for item in items if item["item_key"] in answers and item["lifecycle"] == "ACTIVE"
                and item["answer_kind"] != "ACTION"
            ],
            "findings": active_findings,
            "interpretation_notices": interpretation_notices(answers),
            "clarification_decisions": {k: v for k, v in current_decisions.items() if k in active_ids},
            "no_issue_interpretation": (
                "NO_CANDIDATE_ISSUE_FROM_CHECKED_RULES; NOT A VIABILITY OR COMPLETENESS JUDGMENT"
                if eval_record and not active_findings else None
            ),
            "rule_catalogue": list(RULE_CATALOGUE),
            "claims_boundary": "Entrepreneur declarations only. No verified demand, viability or computed financial result.",
            "publication_authorized": False,
            "qj_handoff_authorized": False,
        }
