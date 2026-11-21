"""Candidate-only EE-01 explanation contract and deterministic evidence guards.

The model output is a CANDIDATE. Authority markers live in the HTTP envelope,
never inside this contract (prompt spec section 10: "no extra fields").

One deliberate exception to that section: ``origin``. A consumer that persists
only the candidate cannot otherwise tell deterministic template prose from model
prose, because both carry the same ``insufficient_evidence``/``used_claim_ids``
shape. Its default is ``DETERMINISTIC_TEMPLATE``, so a candidate that omits the
field can never be mistaken for model output.

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
    """The V1.0 prompt output contract plus the CP-07 provenance discriminator."""
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
    # Provenance. Defaults to the template so an unattributed candidate never
    # claims model origin by omission.
    origin: Literal['DETERMINISTIC_TEMPLATE', 'LLM'] = 'DETERMINISTIC_TEMPLATE'


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


# The deterministic template is a fallback renderer, not a synthesiser: it restates
# supplied figures per claim. Past this many claims a faithful restatement no longer
# fits the field limits, so the service refuses instead of silently truncating.
MAX_TEMPLATE_FINDINGS = 4


def _template_label(finding: dict) -> str:
    """Embed a supplied label only when it cannot itself breach a narrative guard.

    A label is server data, but it still travels through ``validate_candidate``
    as prose. A label carrying a banned phrase, a numeral or a quantity word is
    replaced by a neutral phrase rather than poisoning the whole template.
    """
    for key in ('label', 'construct'):
        value = finding.get(key)
        if not isinstance(value, str):
            continue
        text = value.strip()
        if not text or len(text) > 80:
            continue
        flat = normalise(text)
        if any(normalise(phrase) in flat for phrase in BANNED_PHRASES):
            continue
        if _NUMBER_RE.search(text) or _QUANTITY_WORD_RE.search(text):
            continue
        return text
    return 'the measured response'


def _figure_clause(finding: dict) -> str:
    """Copy supplied figures verbatim. Nothing here is computed or rounded."""
    count = finding.get('count')
    denominator = finding.get('denominator')
    percentage = finding.get('percentage')
    parts = []
    if count is not None and denominator is not None:
        parts.append(f'{count} of {denominator} qualifying responses')
    elif count is not None:
        parts.append(f'{count} qualifying responses')
    elif denominator is not None:
        parts.append(f'a qualifying denominator of {denominator}')
    if percentage is not None:
        parts.append(f'{percentage}% of that denominator')
    return ', '.join(parts)


def authorized_finding_output(*, context_id: str, snapshot_id: str, task_mode: str,
                              findings: list[dict], missing: list[str]) -> ExplanationOutput:
    """Deterministic explanation of authorized findings, rendered without a model.

    This is the path that must work when no model explanation is available: every
    figure is copied from the finding mapping (counts, denominators, percentages,
    claim ids, labels, reference periods) and nothing is computed, rounded or
    aggregated. ``origin`` is left at its template default on purpose.
    """
    claims, seen = [], set()
    for finding in findings:
        claim_id = finding.get('claim_id')
        if claim_id and claim_id not in seen:
            seen.add(claim_id)
            claims.append(finding)
    ids = [str(finding['claim_id']) for finding in claims]

    observations, research = [], []
    for finding in claims:
        claim_id = str(finding['claim_id'])
        label = _template_label(finding)
        figures = _figure_clause(finding)
        supplied = f' as {figures}' if figures else ' without a supplied figure'
        observations.append(
            f'The authorized measurement for {claim_id} reports {label}{supplied}. '
            'EE-01 supplied every figure here; this candidate restates it without '
            'recalculation or aggregation.')
        period = finding.get('reference_period')
        window = (f' for the supplied reference period {period}'
                  if isinstance(period, str) and period.strip() else '')
        research.append(
            f'The finding {claim_id} describes recorded responses{window} within the '
            'measured response set. It reports stated responses rather than observed '
            'purchasing behaviour, and it supports no conclusion about demand, '
            'revenue or viability.')

    if len(claims) == 1:
        headline = f'Authorized finding {ids[0]}: {_template_label(claims[0])}'
    else:
        headline = 'Authorized findings for this snapshot'
    summary = (f'Authorized evidence for {", ".join(ids)} is explained from supplied '
               'figures only. ')
    summary += ('What remains uncertain is every requirement listed in '
                'missing_evidence_references.' if missing else
                'No further admission requirement was supplied with this packet.')

    return ExplanationOutput(
        schema_version=SCHEMA_VERSION,
        task_mode=task_mode,
        context_id=context_id,
        snapshot_id=snapshot_id,
        used_claim_ids=ids,
        headline=headline,
        observation_interpretation=' '.join(observations),
        research_interpretation=' '.join(research),
        planning_implication=(
            'Treat the explained finding as a planning input only. It is a candidate '
            'interpretation, not an instruction, forecast, price recommendation or '
            'viability assessment.'),
        limitations=(
            'This explanation was rendered by the deterministic EE-01 template without '
            'a language model, so no model prose is present. The finding and this '
            'explanation are candidates: neither is scientifically accepted, validated '
            'or report-authorised, and the template adds no measurement beyond the '
            'supplied figures.'),
        summary=summary,
        insufficient_evidence=False,
        missing_evidence_references=list(missing),
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
