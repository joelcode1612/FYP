"""Candidate-only EE-01 explanation contract and deterministic evidence guards.

The model output is a CANDIDATE. Authority markers live in the HTTP envelope,
never inside this 12-field contract (prompt spec section 10: "no extra fields").
No number, claim id or destination may be invented here; all are checked against
the server-held packet before a candidate is returned.
"""
from __future__ import annotations

import re
import unicodedata
from typing import Literal

from pydantic import Field

from sitewise.project1.contracts import StrictModel, WorkflowHeld

SCHEMA_VERSION = 'ee01-explanation/1'

TASK_MODES = ('CLAIM_EXPLANATION', 'REPORT_SYNTHESIS')

# Prompt spec section 9. Checked on a normalised form so punctuation/case
# changes cannot smuggle a prohibited conclusion through.
BANNED_PHRASES = (
    'high market demand',
    'guaranteed business success',
    'profitable location',
    'customers will definitely purchase',
    'the business is viable',
    'the survey proves market demand',
)

# Prompt spec sections 3-4 and 8. Narrative may not carry a number that was not
# supplied by EE-01, and these statuses are never evidence of zero/negative demand.
NON_EVIDENCE_STATUSES = ('NOT_SHOWN', 'NOT_ESTIMABLE', 'WITHHELD_NOT_AUTHORIZED',
                         'HOLD_INVALID_EVIDENCE')
# Standalone numerals only: identifiers like "A10", "V1.0", "Q05" are labels,
# not measurements. The alternation covers decimals, thousands separators and
# scientific notation (1e5 / 2.5E-10); identifiers stay excluded by the edges.
_NUMBER_RE = re.compile(
    r'(?<![A-Za-z0-9.\-])'
    r'(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?(?:[eE][+-]?\d+)?'
    r'(?![A-Za-z0-9.\-])'
)
# Number words used as a quantity ("several thousand respondents") are as much
# an invented measurement as a bare numeral under spec section 4.
_QUANTITY_WORD_RE = re.compile(
    r'\b(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|'
    r'several|many|few|hundreds?|thousands?|millions?)\b', re.IGNORECASE)


def normalise(text: str) -> str:
    """Unicode-normalised lowercase: defeats fullwidth/diacritic/homoglyph evasion."""
    folded = unicodedata.normalize('NFKD', text)
    folded = ''.join(c for c in folded if not unicodedata.combining(c))
    # Common Greek/Cyrillic homoglyphs used to disguise Latin letters.
    homoglyphs = str.maketrans({'Α': 'A', 'Β': 'B', 'Ε': 'E', 'Ο': 'O', 'Ρ': 'P',
                                'Τ': 'T', 'Χ': 'X', 'а': 'a', 'е': 'e', 'о': 'o',
                                'р': 'p', 'с': 'c', 'х': 'x', 'у': 'y', 'і': 'i'})
    folded = folded.translate(homoglyphs)
    return re.sub(r'[^a-z0-9]+', ' ', folded.lower()).strip()


class ExplanationOutput(StrictModel):
    """Exactly the 12 fields required by the V1.0 prompt output contract."""
    schema_version: str = Field(pattern=r'^ee01-explanation/1$')
    task_mode: Literal['CLAIM_EXPLANATION', 'REPORT_SYNTHESIS']
    context_id: str = Field(min_length=1, max_length=128)
    snapshot_id: str = Field(min_length=1, max_length=64)
    used_claim_ids: list[str] = Field(max_length=32)
    headline: str = Field(min_length=1, max_length=300)
    observation_interpretation: str = Field(min_length=1, max_length=2000)
    research_interpretation: str = Field(min_length=1, max_length=2000)
    planning_implication: str = Field(min_length=1, max_length=2000)
    limitations: str = Field(min_length=1, max_length=2000)
    summary: str = Field(min_length=1, max_length=2000)
    insufficient_evidence: bool = Field(strict=True)
    missing_evidence_references: list[str] = Field(max_length=32)


def insufficient_evidence_output(*, context_id: str, snapshot_id: str,
                                 task_mode: str, missing: list[str]) -> ExplanationOutput:
    """Prompt spec section 8, produced locally. No LLM call for an empty claim set."""
    return ExplanationOutput(
        schema_version=SCHEMA_VERSION,
        task_mode=task_mode,
        context_id=context_id,
        snapshot_id=snapshot_id,
        used_claim_ids=[],
        headline='Insufficient authorized evidence',
        observation_interpretation=(
            'No admitted findings were supplied for this snapshot. EE-01 supplies the '
            'numerical measurements; none were authorized for interpretation here.'),
        research_interpretation=(
            'No conclusion about the cohort can be drawn. A withheld, unestimable or '
            'not-shown result is not a zero response and is not negative demand.'),
        planning_implication=(
            'No planning consideration can be grounded in authorized evidence. Further '
            'research would require an admitted measurement, not a re-reading of held data.'),
        limitations=(
            'Report findings are withheld pending an adopted scientific/admission adapter. '
            'The explanation itself is a candidate and is not scientifically accepted, '
            'validated or report-authorised.'),
        summary=(
            'The evidence supports no interpretation at this time. What remains uncertain '
            'is every claim listed in missing_evidence_references.'),
        insufficient_evidence=True,
        missing_evidence_references=missing,
    )


def validate_candidate(output: ExplanationOutput, *, packet: dict,
                       allowed_claim_ids: set[str], allowed_numbers: set[str]) -> None:
    """Fail closed on echo-back, claim authority, numbers and prohibited phrasing."""
    if output.schema_version != SCHEMA_VERSION:
        raise WorkflowHeld('EXPLANATION_SCHEMA_VERSION_MISMATCH')
    if (output.task_mode != packet['task_mode'] or
            output.context_id != packet['context_id'] or
            output.snapshot_id != packet['snapshot_id']):
        raise WorkflowHeld('EXPLANATION_ECHO_BACK_MISMATCH')
    if not set(output.used_claim_ids) <= allowed_claim_ids:
        raise WorkflowHeld('EXPLANATION_UNAUTHORIZED_CLAIM_ID')
    if len(set(output.used_claim_ids)) != len(output.used_claim_ids):
        raise WorkflowHeld('EXPLANATION_DUPLICATE_CLAIM_ID')
    if output.insufficient_evidence:
        if output.used_claim_ids:
            raise WorkflowHeld('EXPLANATION_INSUFFICIENT_WITH_CLAIMS')
        if not output.missing_evidence_references:
            raise WorkflowHeld('EXPLANATION_MISSING_EVIDENCE_REFERENCES')
    elif not output.used_claim_ids:
        raise WorkflowHeld('EXPLANATION_SUFFICIENT_WITHOUT_CLAIMS')
    if not set(output.missing_evidence_references) <= set(packet['reference_universe']):
        raise WorkflowHeld('EXPLANATION_UNKNOWN_EVIDENCE_REFERENCE')

    narrative = ' '.join((output.headline, output.observation_interpretation,
                          output.research_interpretation, output.planning_implication,
                          output.limitations, output.summary))
    flat = normalise(narrative)
    if any(normalise(phrase) in flat for phrase in BANNED_PHRASES):
        raise WorkflowHeld('EXPLANATION_PROHIBITED_CLAIM')
    if any(number not in allowed_numbers for number in _NUMBER_RE.findall(narrative)):
        raise WorkflowHeld('EXPLANATION_UNSOURCED_NUMBER')
    if _QUANTITY_WORD_RE.search(narrative):
        raise WorkflowHeld('EXPLANATION_UNSOURCED_QUANTITY')
