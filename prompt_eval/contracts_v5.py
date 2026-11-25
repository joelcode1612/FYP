"""Additive contract `bdj-objective-proposal/2` for the V5 candidate.

Why a new contract version and not a wider v1
---------------------------------------------
`bdj-objective-proposal/1` has seven fields. The V5 brief requires ten, and four
of them (business decision, customer-research suitability, measurement construct,
measurement approach, expected evidence, interpretation limitations) have no home
in v1. Adding them to v1 in place would silently widen a contract that historical
ledger rows were validated against, so v1 is left exactly as it is and v2 sits
beside it -- the same additive move `bdj-objective-proposal/1` itself made
against `bdj-output/1`.

Field names map onto v1 wherever v1 already had a field, so a diff between a v1
and a v2 record is readable:

    v1 `problem`             -> v2 `business_uncertainty`
    v1 `reason`              -> v2 `research_justification`
    v1 `source_refs`         -> unchanged
    v1 `research_objective`  -> unchanged

Six fields are new: `business_decision`, `customer_research_suitability`,
`measurement_construct`, `measurement_approach`, `expected_evidence`,
`interpretation_limitations`. One field is new for governance:
`linked_fixed_objective`, which names O1-O6 or NONE and is the only way a
proposal may refer to a fixed objective.

This module validates structure and source binding only. It does not judge
research quality -- that is CP-08, and it is done by a human-readable rubric, not
by asking the model to grade itself.
"""
from __future__ import annotations

import re
import sys
import pathlib
from typing import Literal

from pydantic import Field

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend' / 'src'))

from sitewise.project1.contracts import StrictModel, WorkflowHeld, digest  # noqa: E402
from sitewise.project1.objective_proposal import (  # noqa: E402
    ALLOWED_OPENERS,
    CLAIM_PHRASES,
    PROBLEM_TYPE_FOR_STATUS,
    ObjectiveSourceRef,
    _establishes_uncertainty,
    _normalise,
)
from sitewise.project1.objective_registry import OBJECTIVES  # noqa: E402

CONTRACT_VERSION_V2 = 'bdj-objective-proposal/2'
MAX_RECOMMENDATIONS_V2 = 3

SUITABILITY = ('SUITABLE', 'PARTIALLY_SUITABLE', 'NOT_SUITABLE')
FIXED_OBJECTIVE_IDS = tuple(o.objective_id for o in OBJECTIVES)  # O1..O6
LINK_TARGETS = FIXED_OBJECTIVE_IDS + ('NONE',)

#: Per-field character ceilings. Generous on purpose: these reject an essay, not
#: a careful sentence. A rejection here is a prompt-adherence failure the
#: comparison should count, not a quality judgement.
CAPS = {
    'business_uncertainty': 400,
    'research_objective': 500,
    'research_justification': 600,
    'business_decision': 400,
    'customer_research_suitability': 300,
    'measurement_construct': 120,
    'measurement_approach': 600,
    'expected_evidence': 400,
    'interpretation_limitations': 400,
}

_CONSTRUCT = re.compile(r'^STATED_[A-Z0-9_]{3,80}$')
_FIXED_CONSTRUCTS = {_normalise(o.construct) for o in OBJECTIVES}


class RecommendationV2(StrictModel):
    recommendation_status: Literal['MOST_SUGGESTED', 'SUGGESTED']
    problem_type: Literal['SOURCE_CONFIRMED_INFORMATION_GAP',
                          'EXPLORATORY_RESEARCH_NEED']

    # -- the ten required fields ------------------------------------------
    business_uncertainty: str | None = Field(max_length=CAPS['business_uncertainty'])
    source_refs: list[ObjectiveSourceRef] = Field(max_length=8)
    research_objective: str = Field(min_length=12, max_length=CAPS['research_objective'])
    research_justification: str = Field(min_length=1,
                                        max_length=CAPS['research_justification'])
    business_decision: str = Field(min_length=1, max_length=CAPS['business_decision'])
    customer_research_suitability: str = Field(
        min_length=1, max_length=CAPS['customer_research_suitability'])
    measurement_construct: str = Field(min_length=4,
                                       max_length=CAPS['measurement_construct'])
    measurement_approach: str = Field(min_length=1,
                                      max_length=CAPS['measurement_approach'])
    expected_evidence: str = Field(min_length=1, max_length=CAPS['expected_evidence'])
    interpretation_limitations: str = Field(
        min_length=1, max_length=CAPS['interpretation_limitations'])

    # -- governance --------------------------------------------------------
    linked_fixed_objective: Literal[LINK_TARGETS] = 'NONE'
    authority: Literal['CANDIDATE_ONLY'] = 'CANDIDATE_ONLY'


class ObjectiveProposalV2(StrictModel):
    contract_version: Literal['bdj-objective-proposal/2']
    recommendations: list[RecommendationV2] = Field(max_length=MAX_RECOMMENDATIONS_V2)


def _require_non_blank(value, field_name: str) -> None:
    if not str(value or '').strip():
        raise WorkflowHeld(f'BDJ_V2_FIELD_EMPTY:{field_name}')


def validate_objective_proposal_v2(raw, packet: dict) -> ObjectiveProposalV2:
    """Fail-closed validation of a V5 candidate against the source packet.

    Every v1 rule that still applies is re-applied here, so a V5 proposal cannot
    pass by being structurally newer while being source-unsound. The v2-only
    rules are marked [v2].
    """
    output = ObjectiveProposalV2.model_validate(raw)
    sources = {d['item_key']: d for d in packet.get('declarations', [])}
    seen_constructs: set[tuple] = set()
    seen_objectives: set[str] = set()

    for rec in output.recommendations:
        # -- v1 rules, unchanged -----------------------------------------
        if rec.problem_type != PROBLEM_TYPE_FOR_STATUS[rec.recommendation_status]:
            raise WorkflowHeld('BDJ_OBJECTIVE_PROBLEM_TYPE_MISMATCH')

        low = _normalise(rec.research_objective)
        if any(phrase in low for phrase in CLAIM_PHRASES):
            raise WorkflowHeld('BDJ_OBJECTIVE_CLAIM_NOT_ALLOWED')
        if low.endswith('?'):
            raise WorkflowHeld('BDJ_OBJECTIVE_PHRASING_INVALID')
        if not low.startswith(ALLOWED_OPENERS):
            raise WorkflowHeld('BDJ_OBJECTIVE_PHRASING_INVALID')

        if rec.recommendation_status == 'MOST_SUGGESTED':
            _require_non_blank(rec.business_uncertainty, 'business_uncertainty')
            if not rec.source_refs:
                raise WorkflowHeld('BDJ_OBJECTIVE_SOURCE_REQUIRED')
            establishing = False
            for ref in rec.source_refs:
                source = sources.get(ref.item_key)
                if (source is None or source.get('answer_state') != 'ANSWERED' or
                        source.get('answer_revision_id') != ref.answer_revision_id or
                        source.get('item_version_id') != ref.item_version_id):
                    raise WorkflowHeld('BDJ_OBJECTIVE_SOURCE_INVALID')
                if _establishes_uncertainty(ref.item_key, source.get('value')):
                    establishing = True
            if not establishing:
                raise WorkflowHeld('BDJ_OBJECTIVE_SOURCE_NOT_SUPPORTING')
        else:
            if rec.business_uncertainty is not None:
                raise WorkflowHeld('BDJ_OBJECTIVE_PROBLEM_NOT_ALLOWED')
            if rec.source_refs:
                raise WorkflowHeld('BDJ_OBJECTIVE_SOURCE_NOT_ALLOWED')

        # -- [v2] every field present, not just structurally valid -------
        for name in ('research_justification', 'business_decision',
                     'customer_research_suitability', 'measurement_construct',
                     'measurement_approach', 'expected_evidence',
                     'interpretation_limitations'):
            _require_non_blank(getattr(rec, name), name)

        # -- [v2] suitability must lead with a registered verdict --------
        verdict = _normalise(rec.customer_research_suitability).split(' ')[0]
        if verdict not in {s.lower() for s in SUITABILITY}:
            raise WorkflowHeld('BDJ_V2_SUITABILITY_UNRECOGNISED')
        # A construct the entrepreneur must decide is not a customer question.
        if verdict == 'not_suitable' and rec.recommendation_status == 'MOST_SUGGESTED':
            raise WorkflowHeld('BDJ_V2_UNSUITABLE_PROPOSED_AS_GAP')

        # -- [v2] construct is a named construct, not prose --------------
        if not _CONSTRUCT.match(rec.measurement_construct.strip()):
            raise WorkflowHeld('BDJ_V2_CONSTRUCT_NOT_NAMED')
        # Underscores are the construct's own separator, the registry uses spaces.
        # Comparing them without translating meant a proposal could restate a
        # fixed construct verbatim in SCREAMING_SNAKE and pass.
        if _normalise(rec.measurement_construct.replace('_', ' ')) in _FIXED_CONSTRUCTS:
            raise WorkflowHeld('BDJ_V2_CONSTRUCT_COLLIDES_WITH_FIXED_OBJECTIVE')

        # -- [v2] no fixed objective may be restated as a new one --------
        if low in _FIXED_CONSTRUCTS:
            raise WorkflowHeld('BDJ_V2_RESTATES_FIXED_OBJECTIVE')

        # -- [v2] no claim smuggled into the decision or evidence fields -
        # `interpretation_limitations` is deliberately NOT scanned. A limitation
        # has to be able to name what a result is *not*, and the canonical
        # wording for that ("not a maximum willingness to pay") contains a
        # prohibited phrase. Scanning it rejected the most honest sentence in
        # the response -- the same false positive the production QG validator
        # exhibits on `construct_interpretation` (see
        # prompt_eval/results/DEFECTS_FOUND_20261125.md, DEF-02).
        joined = _normalise(' '.join((rec.business_decision, rec.expected_evidence)))
        for phrase in CLAIM_PHRASES:
            if phrase in joined:
                raise WorkflowHeld('BDJ_OBJECTIVE_CLAIM_NOT_ALLOWED')

        # -- [v2] dedupe on construct + source, not on wording -----------
        key = (rec.measurement_construct.strip().upper(),
               tuple(sorted(ref.item_key for ref in rec.source_refs)))
        if key in seen_constructs:
            raise WorkflowHeld('BDJ_V2_DUPLICATE_CONSTRUCT')
        seen_constructs.add(key)

        signature = digest({'status': rec.recommendation_status, 'objective': low})
        if signature in seen_objectives:
            raise WorkflowHeld('BDJ_OBJECTIVE_DUPLICATE_RECOMMENDATION')
        seen_objectives.add(signature)

    return output


def field_length_report(raw) -> dict:
    """Measure verbosity without rejecting it.

    CP-06 asks whether the brevity budgets are being met. Recording the length is
    the honest way to answer that: a budget is guidance, and a run that exceeds
    one is slower, not invalid.
    """
    report = {}
    for rec in (raw.get('recommendations') or []) if isinstance(raw, dict) else []:
        for name, cap in CAPS.items():
            value = rec.get(name)
            if isinstance(value, str):
                report.setdefault(name, []).append({'chars': len(value), 'cap': cap,
                                                    'within': len(value) <= cap})
    return report


__all__ = ['CAPS', 'CONTRACT_VERSION_V2', 'LINK_TARGETS', 'ObjectiveProposalV2',
           'RecommendationV2', 'SUITABILITY', 'field_length_report',
           'validate_objective_proposal_v2']
