"""Versioned dual-population successor route-preview contracts.

SYNTHETIC ONLY. This module is a successor CANDIDATE, not an approved
replacement for the frozen CUST03 contract (`ec2b5494...`). It is additive:
nothing here is imported by `sitewise.main` or `sitewise.api.v1.router`.

Authority model: the client request carries NO authority-granting booleans.
Identity, tenant, consent and version approval are all server-side.
"""

from dataclasses import dataclass

from pydantic import BaseModel, ConfigDict, Field

INSTRUMENT_VERSION = "SYN-CUST03-SUCCESSOR-1"
ROUTING_POLICY_VERSION = "SD-CQ-AREA-01-SYNTHETIC-PROPOSAL-1"
QUESTION_BANK_VERSION = "SYN-QBANK-V1"
CONCEPT_VERSION = "SYN-CONCEPT-1"
M2_CONTEXT_VERSION = "SYN-M2-V1"

Q01_AFFILIATIONS = frozenset(
    {"LIVE", "WORK", "STUDY", "RUN_BUSINESS", "VISIT_PURPOSE", "PASS_THROUGH"}
)
Q01_LEGACY_FREQUENCY = frozenset({"RARELY", "NEVER", "NOT_SURE"})
Q01_SUCCESSOR_NO_CONNECTION = "NO_CURRENT_CONNECTION"
Q02_CODES = frozenset(
    {"NONE", "DAYS_1_3", "DAYS_4_10", "DAYS_11_20", "DAYS_GT_20", "PREFER_NOT_TO_ANSWER"}
)
Q04_NONZERO = frozenset({"ONE", "TWO_THREE", "FOUR_SEVEN", "EIGHT_PLUS"})
Q04_CODES = frozenset({"ZERO", *Q04_NONZERO, "CANNOT_REMEMBER", "PREFER_NOT_TO_ANSWER"})
QUESTION_IDS = tuple(f"Q{i:02d}" for i in range(1, 14))
ALLOWED_STATES = frozenset(
    {"ELIGIBLE_TO_SHOW", "NOT_SHOWN", "PENDING_DEPENDENCY", "BLOCKED"}
)


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class RoutePreviewRequest(StrictModel):
    """Integration-layer request.

    DELIBERATE DIVERGENCE from the pure-Python oracle's `QuestionnaireContext`:
    `completed_ids`, `viewer_authorized`, `consented` and every
    `*_approved_in_fixture` flag are intentionally ABSENT. A client may declare
    version refs and answers, never authority. `displayed_ids` / `answered_ids`
    are non-authoritative correlation hints only; the server recomputes route
    state from its own history.
    """

    assessment_id: str = Field(min_length=1, max_length=128)
    tenant_id: str = Field(min_length=1, max_length=128)
    q01_codes: list[str] = Field(default_factory=list)
    q02_code: str | None = None
    q04_code: str | None = None
    q05_code: str | None = None
    instrument_version: str = INSTRUMENT_VERSION
    routing_policy_version: str = ROUTING_POLICY_VERSION
    question_bank_version: str = QUESTION_BANK_VERSION
    concept_version: str = CONCEPT_VERSION
    m2_context_version: str = M2_CONTEXT_VERSION
    expected_revision: int = Field(default=0, ge=0)


class PreviewPermission(BaseModel):
    item_id: str
    state: str
    reason: str


class RoutePreviewResponse(BaseModel):
    """Field-for-field with the oracle's RoutePreview, plus provenance."""

    mode: str = "SYNTHETIC_ONLY"
    assessment_id: str
    instrument_version: str
    routing_policy_version: str
    connection_group: str
    route_state: str
    next_question_id: str | None
    preview_permissions: list[PreviewPermission]
    q10_feature_ids: tuple[str, ...] = ()
    packet_digest: str
    actual_display_logged: bool = False
    production_fielding_authorized: bool = False
    report_release_authorized: bool = False


@dataclass(frozen=True)
class Principal:
    """Server-derived identity. Never constructed from a request body."""

    actor_ref: str
    tenant_id: str
    authenticated: bool = False
    roles: tuple[str, ...] = ()
    jurisdiction: str = "JOHOR"


@dataclass(frozen=True)
class ConsentSnapshot:
    """Server-derived consent. Defaults DENY."""

    consented: bool = False
    withdrawn: bool = False
    consent_version: str = ""


class PrincipalPort:
    """Injected server-side identity source; default denies."""

    def resolve(self, assessment_id: str) -> Principal:
        return Principal(actor_ref="", tenant_id="", authenticated=False)


class ConsentPort:
    """Injected server-side consent source; default denies."""

    def resolve(self, assessment_id: str) -> ConsentSnapshot:
        return ConsentSnapshot()


class StaticPrincipalPort(PrincipalPort):
    def __init__(self, principal: Principal) -> None:
        self._principal = principal

    def resolve(self, assessment_id: str) -> Principal:
        return self._principal


class StaticConsentPort(ConsentPort):
    def __init__(self, consent: ConsentSnapshot) -> None:
        self._consent = consent

    def resolve(self, assessment_id: str) -> ConsentSnapshot:
        return self._consent
