"""Strict candidate contracts; source code and provider data confer no authority."""
from __future__ import annotations

import hashlib
import json
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


def canonical(value) -> str:
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"),
                      allow_nan=False)


def digest(value) -> str:
    return hashlib.sha256(canonical(value).encode('utf-8')).hexdigest()


class WorkflowHeld(ValueError):
    """Safe fixed reason only; never include raw provider/source exceptions."""


class StrictModel(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True, serialize_by_alias=True)


class SourceRef(StrictModel):
    item_key: str = Field(pattern=r'^M2-(?:\d{2}|O-0[12])$')
    answer_revision_id: str = Field(min_length=1, max_length=64)
    item_version_id: str = Field(min_length=1, max_length=64)
    quote: str = Field(min_length=1, max_length=4000)


class Finding(StrictModel):
    rule_id: str = Field(min_length=1, max_length=64)
    kind: Literal['SOURCE_CONFLICT', 'UNSUPPORTED_ASSERTION', 'INFORMATION_GAP']
    source_refs: list[SourceRef] = Field(min_length=1, max_length=8)
    observed_condition: str = Field(min_length=1, max_length=1000)
    counterargument: str = Field(min_length=1, max_length=1000)
    justification: str = Field(min_length=1, max_length=1000)
    next_action: str = Field(min_length=1, max_length=500)


class BDJOutput(StrictModel):
    issues: list[Finding] = Field(max_length=20)
    overall_note: str = Field(min_length=1, max_length=1000)


class Measurement(StrictModel):
    uncertainty_version: str = Field(min_length=1, max_length=100)
    construct_name: str = Field(alias='construct', min_length=1, max_length=500)
    population: str = Field(min_length=1, max_length=500)
    timeframe: str = Field(min_length=1, max_length=500)
    stimulus: str = Field(min_length=1, max_length=2000)
    response_options: list[str] = Field(min_length=2, max_length=12)
    response_codes: list[str] = Field(min_length=2, max_length=12)
    routing: dict[str, str]
    denominator: str = Field(min_length=1, max_length=500)
    source_refs: list[str] = Field(min_length=1, max_length=20)
    limitations: str = Field(min_length=1, max_length=1000)


class QJOutput(StrictModel):
    route: Literal['CUSTOMER_SURVEY_CANDIDATE', 'SCENARIO_ANALYSIS_REQUIRED',
                   'EXTERNAL_EVIDENCE_REQUIRED', 'HOLD']
    justification: str = Field(min_length=1, max_length=1000)
    measurement: Measurement | None


class QGOutput(StrictModel):
    decision: Literal['DRAFT', 'ABSTAIN_NEEDS_REVIEW']
    question: str = Field(max_length=2000)
    measurement: Measurement
    justification: str = Field(min_length=1, max_length=1000)


def no_authority() -> dict:
    # Deliberately do not persist proposed SCI/OWN/FIELD/WF enums as deployed codes.
    return {'scientific_acceptance': False, 'owner_authorization': False,
            'publication_authorized': False, 'fielding_authorized': False,
            'report_release_authorized': False}
