"""Web Location Assessment Workspace orchestration.

Five decision-support stages, each backed by a persisted timestamp rather than
a client-side flag:

1. select_property          - the catalogue listing exists and was chosen
2. business_requirements    - validated requirements were stored
3. location_evidence        - analysed evidence exists and was reviewed
4. ai_explanation           - a trained model can explain its recommendation
5. assessment_report        - a report was actually generated

Stages 4 and 5 are capability-gated by runtime probes (model artifact, ``shap``
dependency, report generator). While those probes fail the API refuses to mark
the stages complete, so progress can never exceed what the backend can really
do. No score, explanation or report is fabricated to fill the gap.

This service is web-only. The Flutter mobile data-collection workflow keeps its
own session store and never calls it.
"""

from __future__ import annotations

import importlib.util
import json
import math
import uuid
from datetime import UTC, datetime
from typing import Any

from sqlmodel import Session

from sitewise.core.exceptions import AssessmentError, ModelUnavailableError
from sitewise.core.logging import logger
from sitewise.db.models.assessment import Assessment
from sitewise.ml.model_loader import ModelLoader
from sitewise.repositories.assessment_repository import AssessmentRepository
from sitewise.repositories.catalog_repository import CatalogRepository
from sitewise.services.report_service import ReportService

# (key, title, timestamp column) in workflow order.
STAGES: tuple[tuple[str, str, str], ...] = (
    ("select_property", "Select property", "property_selected_at"),
    ("business_requirements", "Business requirements", "requirements_saved_at"),
    ("location_evidence", "Location evidence", "evidence_reviewed_at"),
    ("ai_explanation", "AI recommendation explanation", "explanation_reviewed_at"),
    ("assessment_report", "Assessment report", "report_generated_at"),
)
STAGE_KEYS = tuple(key for key, _, _ in STAGES)
TOTAL_STAGES = len(STAGES)

_MAX_TEXT = 240
_MAX_LIST_ITEMS = 20


def _now() -> datetime:
    return datetime.now(UTC)


def _iso(value: datetime | None) -> str | None:
    return value.isoformat() if value else None


def _model_capability() -> dict:
    """Probe the real artifact loader instead of asserting a fixed boolean.

    The loader's own message names an absolute server path, so it is logged
    server-side and replaced with a client-safe reason.
    """
    try:
        loaded = ModelLoader().load("pu_model")
    except ModelUnavailableError as exc:
        logger.info("Suitability model unavailable: %s", exc)
        contract_problem = "feature contract" in str(exc)
        return {
            "available": False,
            "reason": (
                "The trained model artifact is present but its feature contract "
                "is missing or mismatched, so it cannot be run."
                if contract_problem
                else "No trained suitability model artifact is installed. The "
                "backend will not produce a score or a model-based explanation "
                "until one exists."
            ),
        }
    except Exception as exc:  # noqa: BLE001 - a corrupt artifact must not 500 the workspace
        logger.exception("Suitability model artifact could not be loaded")
        return {
            "available": False,
            "reason": f"The trained model artifact could not be loaded: {type(exc).__name__}.",
        }
    return {
        "available": True,
        "reason": None,
        "model_version": (loaded.meta or {}).get("version"),
    }


def decision_support_capabilities(property_id: str, session: Session) -> dict:
    """Availability of the two stages that need real model output."""
    model = _model_capability()
    shap_installed = importlib.util.find_spec("shap") is not None

    if not model["available"]:
        explanation = {"available": False, "reason": model["reason"]}
    elif not shap_installed:
        explanation = {
            "available": False,
            "reason": (
                "The 'shap' package is not installed, so per-feature "
                "contributions cannot be computed for the trained model."
            ),
        }
    else:
        explanation = {"available": True, "reason": None}

    if not model["available"]:
        report = {"available": False, "reason": model["reason"]}
    else:
        # Only reached once a model exists: ask the generator itself whether it
        # produces a report rather than duplicating its readiness rule here.
        generated = ReportService(session).generate_property_report(property_id)
        implemented = generated.get("report") != "not implemented"
        report = {
            "available": implemented,
            "reason": None
            if implemented
            else (
                "The assessment report generator is not implemented, so no "
                "report can be produced for this property yet."
            ),
        }

    return {"model": model, "explanation": explanation, "report": report}


# ---------------------------------------------------------------------------
# Requirements validation
# ---------------------------------------------------------------------------

_TEXT_FIELDS = {
    "business_type": 120,
    "property_type": 60,
    "target_market": _MAX_TEXT,
    "seating_model": 60,
}
_REQUIRED_TEXT = ("business_type", "property_type")
_NUMBER_FIELDS = (
    "min_budget_rm",
    "max_budget_rm",
    "min_size_sqft",
    "max_size_sqft",
)
_LIST_FIELDS = ("requirements", "preferred_areas")


def validate_requirements(raw: Any) -> dict:
    """Normalise and validate the business-requirements payload.

    Raises ``AssessmentError`` (422) listing every problem at once, so the form
    can show all field errors rather than one per round trip.
    """
    if not isinstance(raw, dict):
        raise AssessmentError(
            "Business requirements must be an object.",
            code="invalid_requirements",
            status_code=422,
        )

    problems: list[str] = []
    clean: dict[str, Any] = {}

    for field, limit in _TEXT_FIELDS.items():
        value = raw.get(field, "")
        if value is None:
            value = ""
        if not isinstance(value, str):
            problems.append(f"{field} must be text.")
            continue
        value = value.strip()
        if field in _REQUIRED_TEXT and not value:
            problems.append(f"{field} is required.")
        if len(value) > limit:
            problems.append(f"{field} must be {limit} characters or fewer.")
        clean[field] = value

    for field in _NUMBER_FIELDS:
        value = raw.get(field)
        if value is None or value == "":
            if field in ("max_budget_rm", "max_size_sqft"):
                problems.append(f"{field} is required.")
            else:
                clean[field] = 0.0
            continue
        if isinstance(value, bool) or not isinstance(value, (int, float, str)):
            problems.append(f"{field} must be a number.")
            continue
        try:
            number = float(value)
        except (TypeError, ValueError):
            problems.append(f"{field} must be a number.")
            continue
        if not math.isfinite(number):
            problems.append(f"{field} must be a finite number.")
            continue
        if number < 0:
            problems.append(f"{field} cannot be negative.")
            continue
        if field in ("max_budget_rm", "max_size_sqft") and number <= 0:
            problems.append(f"{field} must be greater than zero.")
            continue
        clean[field] = number

    for field in _LIST_FIELDS:
        value = raw.get(field, [])
        if value is None:
            value = []
        if not isinstance(value, list) or any(not isinstance(v, str) for v in value):
            problems.append(f"{field} must be a list of text values.")
            clean[field] = []
            continue
        items = [v.strip() for v in value if v.strip()]
        if len(items) > _MAX_LIST_ITEMS:
            problems.append(f"{field} accepts at most {_MAX_LIST_ITEMS} entries.")
        if any(len(v) > 120 for v in items):
            problems.append(f"{field} entries must be 120 characters or fewer.")
        clean[field] = items[:_MAX_LIST_ITEMS]

    if (
        "min_budget_rm" in clean
        and "max_budget_rm" in clean
        and clean["min_budget_rm"] > clean["max_budget_rm"]
    ):
        problems.append("Minimum monthly rent cannot exceed the maximum.")
    if (
        "min_size_sqft" in clean
        and "max_size_sqft" in clean
        and clean["min_size_sqft"] > clean["max_size_sqft"]
    ):
        problems.append("Minimum floor area cannot exceed the maximum.")

    if problems:
        raise AssessmentError(" ".join(problems), code="invalid_requirements", status_code=422)
    return clean


# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------


class AssessmentService:
    def __init__(self, session: Session, analytics_session: Session):
        self.session = session
        self.repo = AssessmentRepository(session)
        self.catalog = CatalogRepository(analytics_session)

    # -- reads --------------------------------------------------------------

    def get_owned(self, assessment_id: uuid.UUID, user_id: uuid.UUID) -> Assessment:
        assessment = self.repo.get_by_id(assessment_id)
        if assessment is None:
            raise AssessmentError(
                "That assessment does not exist.",
                code="assessment_not_found",
                status_code=404,
            )
        if assessment.user_id != user_id:
            # 403 rather than 404: the id is well-formed, the caller simply has
            # no claim on it. Never return another user's record.
            raise AssessmentError(
                "This assessment belongs to another account.",
                code="assessment_forbidden",
                status_code=403,
            )
        return assessment

    def find_by_property(self, user_id: uuid.UUID, property_id: str) -> Assessment | None:
        return self.repo.get_by_user_and_property(user_id, property_id)

    def create_or_resume(self, user_id: uuid.UUID, property_id: str) -> tuple[Assessment, bool]:
        prop = self.catalog.get_property(property_id)
        if prop is None:
            raise AssessmentError(
                f"No property with id '{property_id}' exists in the catalogue.",
                code="property_not_found",
                status_code=404,
            )
        existing = self.repo.get_by_user_and_property(user_id, property_id)
        if existing is not None:
            return existing, False
        now = _now()
        assessment = Assessment(
            user_id=user_id,
            property_id=property_id,
            status="in_progress",
            property_selected_at=now,
            created_at=now,
            updated_at=now,
        )
        return self.repo.create(assessment), True

    def update(
        self,
        assessment: Assessment,
        *,
        requirements: Any = None,
        complete_stage: str | None = None,
    ) -> Assessment:
        changed = False
        if requirements is not None:
            clean = validate_requirements(requirements)
            assessment.requirements = json.dumps(clean, ensure_ascii=False)
            changed = True

        if complete_stage is not None:
            self._complete_stage(assessment, complete_stage)
            changed = True

        if changed:
            assessment.updated_at = _now()
            assessment.status = (
                "completed"
                if all(getattr(assessment, col) is not None for _, _, col in STAGES)
                else "in_progress"
            )
            assessment = self.repo.save(assessment)
        return assessment

    def _complete_stage(self, assessment: Assessment, stage_key: str) -> None:
        if stage_key not in STAGE_KEYS:
            raise AssessmentError(
                f"Unknown stage '{stage_key}'.",
                code="unknown_stage",
                status_code=422,
            )
        index = STAGE_KEYS.index(stage_key)
        for prior_key, _, prior_column in STAGES[:index]:
            if getattr(assessment, prior_column) is None:
                raise AssessmentError(
                    f"Complete '{prior_key}' before '{stage_key}'.",
                    code="stage_order",
                )

        if stage_key == "business_requirements":
            if not assessment.requirements:
                raise AssessmentError(
                    "Save your business requirements before completing this stage.",
                    code="requirements_missing",
                )
            # Re-validate what is stored: a record written before a rule
            # tightened must not silently pass.
            validate_requirements(json.loads(assessment.requirements))
        elif stage_key == "location_evidence":
            evidence = self.catalog.get_evidence(assessment.property_id)
            if not evidence.get("available"):
                raise AssessmentError(
                    evidence.get("reason") or "Location evidence is unavailable for this property.",
                    code="evidence_unavailable",
                )
        elif stage_key in ("ai_explanation", "assessment_report"):
            capabilities = decision_support_capabilities(assessment.property_id, self.session)
            capability = (
                capabilities["explanation"]
                if stage_key == "ai_explanation"
                else capabilities["report"]
            )
            if not capability["available"]:
                raise AssessmentError(
                    capability["reason"],
                    code=f"{stage_key}_unavailable",
                )

        setattr(assessment, STAGES[index][2], _now())

    # -- serialization ------------------------------------------------------

    def payload(
        self,
        assessment: Assessment,
        *,
        prop: dict | None = None,
        capabilities: dict | None = None,
    ) -> dict:
        if prop is None:
            prop = self.catalog.get_property(assessment.property_id)
        if capabilities is None:
            capabilities = decision_support_capabilities(assessment.property_id, self.session)

        requirements = None
        if assessment.requirements:
            try:
                requirements = json.loads(assessment.requirements)
            except (TypeError, ValueError):
                logger.warning(
                    "Assessment %s has unreadable requirements text",
                    assessment.assessment_id,
                )

        completed = sum(1 for _, _, column in STAGES if getattr(assessment, column) is not None)
        current_index = next(
            (i for i, (_, _, column) in enumerate(STAGES) if getattr(assessment, column) is None),
            TOTAL_STAGES - 1,
        )

        stages = []
        for i, (key, title, column) in enumerate(STAGES):
            done_at = getattr(assessment, column)
            reason = None
            if done_at is not None:
                status = "complete"
            else:
                status = "current" if i == current_index else "incomplete"
                if key == "location_evidence":
                    evidence = self.catalog.get_evidence(assessment.property_id)
                    if not evidence.get("available"):
                        status, reason = "unavailable", evidence.get("reason")
                elif key == "ai_explanation":
                    if not capabilities["explanation"]["available"]:
                        status, reason = "unavailable", capabilities["explanation"]["reason"]
                elif key == "assessment_report":
                    if not capabilities["report"]["available"]:
                        status, reason = "unavailable", capabilities["report"]["reason"]
            stages.append(
                {
                    "key": key,
                    "number": i + 1,
                    "title": title,
                    "status": status,
                    "completed_at": _iso(done_at),
                    "unavailable_reason": reason,
                }
            )

        return {
            "assessment_id": str(assessment.assessment_id),
            "user_id": str(assessment.user_id),
            "property_id": assessment.property_id,
            "status": assessment.status,
            "current_stage": current_index + 1,
            "current_stage_key": STAGE_KEYS[current_index],
            "completed_stages": completed,
            "total_stages": TOTAL_STAGES,
            "progress_percent": round(completed / TOTAL_STAGES * 100),
            "report_available": assessment.report_generated_at is not None,
            "requirements": requirements,
            "stages": stages,
            "capabilities": capabilities,
            "next_action": self._next_action(stages, current_index, completed),
            "property": prop,
            "created_at": _iso(assessment.created_at),
            "updated_at": _iso(assessment.updated_at),
        }

    @staticmethod
    def _next_action(stages: list[dict], current_index: int, completed: int) -> dict:
        if completed == TOTAL_STAGES:
            return {
                "kind": "view_report",
                "stage_key": "assessment_report",
                "label": "Open assessment report",
                "reason": None,
            }
        stage = stages[current_index]
        if stage["status"] == "unavailable":
            return {
                "kind": "blocked",
                "stage_key": stage["key"],
                "label": stage["title"],
                "reason": stage["unavailable_reason"],
            }
        return {
            "kind": "continue",
            "stage_key": stage["key"],
            "label": stage["title"],
            "reason": None,
        }

    def history_payload(self, user_id: uuid.UUID, limit: int = 50, offset: int = 0) -> dict:
        records = self.repo.list_by_user(user_id, limit=limit, offset=offset)
        properties = self.catalog.get_properties([r.property_id for r in records])
        # Model availability is a server-wide property, so probe it once for the
        # page rather than once per row.
        capabilities = decision_support_capabilities(
            records[0].property_id if records else "", self.session
        )
        return {
            "data": [
                self.payload(
                    r,
                    prop=properties.get(r.property_id),
                    capabilities=capabilities,
                )
                for r in records
            ],
            "meta": {
                "total": self.repo.count_by_user(user_id),
                "limit": limit,
                "offset": offset,
            },
        }
