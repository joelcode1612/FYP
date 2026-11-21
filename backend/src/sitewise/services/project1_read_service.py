"""Read availability at the verified boundary between workspace and research.

The existing property assessment is not an M2 confirmation or a CQ campaign.
No adopted persisted binding exists. Report that gap without querying unrelated
property reports, inventing empty successful histories or granting fielding.
"""
from typing import Literal, Protocol, Any
from uuid import UUID

from pydantic import BaseModel, ConfigDict


class OwnedAssessmentReader(Protocol):
    def get_owned(self, assessment_id: UUID, user_id: UUID) -> Any: ...


class HeldArtifact(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)
    state: Literal["held"] = "held"
    code: str
    message: str


class Project1Readiness(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)
    contract_version: Literal["project1-readiness/1"] = "project1-readiness/1"
    assessment_id: UUID | None
    property_id: str | None
    review: HeldArtifact
    questionnaire: HeldArtifact
    report: HeldArtifact
    activity: HeldArtifact
    fielding_authorized: Literal[False] = False
    report_release_authorized: Literal[False] = False


class Project1ReadService:
    def __init__(self, assessments: OwnedAssessmentReader):
        self.assessments = assessments

    def read(self, assessment_id: UUID | None, actor_id: UUID) -> Project1Readiness:
        record = self.assessments.get_owned(assessment_id, actor_id) if assessment_id else None
        return Project1Readiness(
            assessment_id=record.assessment_id if record is not None else None,
            property_id=record.property_id if record is not None else None,
            review=HeldArtifact(code="M2_BINDING_REQUIRED", message=
                "Business review is held until this workspace is linked to its verified M2 confirmation."),
            questionnaire=HeldArtifact(code="QUESTIONNAIRE_AUTHORIZATION_REQUIRED", message=
                "Customer questionnaires are held pending an approved instrument, consent, routing and fielding authorization."),
            report=HeldArtifact(code="REPORT_ADMISSION_REQUIRED", message=
                "No admitted R01–R12 report snapshot is available. Verified measurements, sources and report admission are required."),
            activity=HeldArtifact(code="RESEARCH_AUDIT_BINDING_REQUIRED", message=
                "Research activity history is unavailable until its authoritative records are linked. No activity count is inferred."),
        )
