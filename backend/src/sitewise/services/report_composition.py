"""Report composition: the nine report sections, their availability and sources.

Why this module exists
----------------------
The reporting pipeline had evidence retrieval (``report_measurement``), claim
construction (``report_service``), admission (``project1.a10``) and chart mapping
(``project1.chart_spec``) — but no responsibility that decided *which sections
exist for this assessment and what state each one is in*. That decision was made
in the Jaspr view, which assembled section availability from three separate
HTTP responses. A presentation layer was therefore the only authority on report
composition: a second consumer (export, PDF, an audit read) could not obtain the
same answer, and the A10 section contract was never consulted when deciding
whether a section could render.

This module is that responsibility, and only that responsibility. It does not
retrieve evidence, does not construct claims, does not decide admission and does
not draw charts. It reads the outputs of those existing responsibilities and
composes an ordered, machine-readable document skeleton:

* the A10 section contract (``project1.a10_gates``) for state and blocking gates,
* the measurement association (``services.report_measurement``) for section 05,
* the confirmed business description for section 02,
* the report payload for sections 07–09,
* the additional-research candidates for section 06.

What it deliberately does not do
--------------------------------
* It never invents a number. ``counts_disclosed`` is true **only** when a slot
  carries an ``ADMITTED`` admission state, which nothing in this checkout does:
  no report-admission decision is adopted and every measurement the store holds
  is ``ISOLATED_TEST``. The flag is therefore computed, not hard-coded — a
  document that could only ever say "withheld" could not show an admitted
  measurement even if one existed.
* It never upgrades an evidence state. ``ADMITTED_SYNTHETIC`` is not
  ``ADMITTED``, a renderable administrative section is not a finding, and an
  entrepreneur declaration is not verified market evidence.
* It never raises. A report must not fail because one source is unreachable:
  every failure degrades to a named state, and "could not read" stays distinct
  from "read it and there was nothing".
"""
from __future__ import annotations

from datetime import UTC, datetime
from typing import Any, Mapping, Sequence

CONTRACT_VERSION = 'report-composition/1'

# -- availability vocabulary ------------------------------------------------
#: Evidence is present and the section renders its content.
AVAILABLE = 'AVAILABLE'
#: The section renders its own administrative metadata. It carries no finding.
ADMINISTRATIVE = 'ADMINISTRATIVE'
#: Some of the section's required evidence is present, some is not.
PARTIAL = 'PARTIAL'
#: Evidence will exist only after upstream fielding or measurement completes.
PENDING = 'PENDING_MEASUREMENT'
#: A required source does not exist for this assessment.
UNAVAILABLE = 'UNAVAILABLE'
#: Evidence exists and the report is not authorized to show it.
WITHHELD = 'WITHHELD'
#: The section does not apply to this kind of assessment.
NOT_APPLICABLE = 'NOT_APPLICABLE'

#: Every state a section can report. A consumer may switch on this set; adding a
#: state is a contract change, so the tuple is exhaustive on purpose.
AVAILABILITY_STATES = (
    AVAILABLE, ADMINISTRATIVE, PARTIAL, PENDING, UNAVAILABLE, WITHHELD,
    NOT_APPLICABLE,
)

# -- measurement state vocabulary (section 05) ------------------------------
#: A measurement exists, admission is withheld. Not a zero.
MEASUREMENT_WITHHELD = 'WITHHELD_NOT_AUTHORIZED'
#: The slot produced no measurement at all. Explicitly not a zero result.
MEASUREMENT_NOT_SHOWN = 'NOT_SHOWN'
#: The approved stimulus needed to measure this slot is absent.
MEASUREMENT_UNAVAILABLE = 'UNAVAILABLE_MISSING_APPROVED_STIMULUS'
#: The measurement could not be read while the report was composed.
MEASUREMENT_UNREADABLE = 'MEASUREMENT_STORE_UNAVAILABLE'
#: No measurement line exists for the slot yet.
MEASUREMENT_ABSENT = 'NO_MEASUREMENT'
#: An A10 admission decision for this slot carries ``ADMITTED``. The only state
#: in which a number may be disclosed. Reachable only when the store, the
#: admission evaluator and the chart bridge all say so — never inferred here.
MEASUREMENT_ADMITTED = 'ADMITTED'

#: Every measurement state the composer can emit. Exhaustive on purpose: a
#: consumer may switch on it, so a new state is a contract change.
MEASUREMENT_STATES = (
    MEASUREMENT_ADMITTED, MEASUREMENT_WITHHELD, MEASUREMENT_NOT_SHOWN,
    MEASUREMENT_UNAVAILABLE, MEASUREMENT_UNREADABLE, MEASUREMENT_ABSENT,
)

# -- chart state vocabulary -------------------------------------------------
CHART_WITHHELD = 'WITHHELD'
CHART_UNAVAILABLE = 'UNAVAILABLE'
CHART_NONE = 'NONE'
#: A chart may be drawn, because an admission decision authorised this exact
#: measurement and named the ``ChartSpec`` that describes it. The composition
#: references that spec; it never builds a second one.
CHART_ADMITTED = 'ADMITTED'

# -- section 03 finding states ---------------------------------------------
#: No evaluation and no finding row exists for this assessment.
FINDINGS_NOT_RECORDED = 'NO_FINDINGS_RECORDED'
#: An evaluation was requested or is running but produced no result. Not a zero.
FINDINGS_NOT_EXECUTED = 'EVALUATION_NOT_EXECUTED'
#: The evaluation ran and validly produced zero findings. A real, reportable
#: result — and emphatically not the same thing as "not executed".
FINDINGS_ZERO_VALID = 'ZERO_FINDINGS_VALID'
#: Findings were produced and accepted for research, but no admission decision
#: releases them to this report.
FINDINGS_ACCEPTED_WITHHELD = 'FINDINGS_ACCEPTED_WITHHELD'
#: Findings were produced and are withheld because no authorized source exists.
FINDINGS_WITHHELD = 'FINDINGS_WITHHELD'
#: The report could not establish whether findings exist. The honest default:
#: absence of a readback is not evidence that a finding exists.
FINDINGS_UNESTABLISHED = 'FINDINGS_STATE_UNESTABLISHED'

#: Every finding state. ``FINDINGS_UNESTABLISHED`` is the default, not a
#: fallback to "present": a report may not assert a finding it did not read.
FINDING_STATES = (
    FINDINGS_NOT_RECORDED, FINDINGS_NOT_EXECUTED, FINDINGS_ZERO_VALID,
    FINDINGS_ACCEPTED_WITHHELD, FINDINGS_WITHHELD, FINDINGS_UNESTABLISHED,
)

# -- section 06 admission stage --------------------------------------------
#: A candidate exists and has no review decision. Presented, nothing more.
STAGE_PRESENTED = 'CANDIDATE_PRESENTED'
#: The generator abstained on this candidate: there is no question to field.
STAGE_ABSTAINED = 'CANDIDATE_ABSTAINED'
#: The candidate was rejected at review.
STAGE_REJECTED = 'CANDIDATE_REJECTED'
#: The owner approved the candidate *for review*. This is the owner's own
#: action on their own question; it is not an objective admission, not a
#: questionnaire approval and not a release.
STAGE_SUBMITTED_FOR_REVIEW = 'CANDIDATE_SUBMITTED_FOR_REVIEW'
#: An ``m2_bdj_objective_admissions`` row admits the objective. The admission
#: row is what mints the objective identity.
STAGE_OBJECTIVE_ADMITTED = 'OBJECTIVE_ADMITTED'
#: The question is approved into the instrument.
STAGE_QUESTION_APPROVED = 'QUESTION_APPROVED'
#: The question is in a released questionnaire version.
STAGE_QUESTION_RELEASED = 'QUESTION_RELEASED'
#: A measurement for the item is admitted. The only stage a result may appear.
STAGE_MEASURED = 'MEASURED'

#: Ordered by authority. A section may claim only the highest stage an item
#: actually reached, and the counts are per stage, never a single total.
ADMISSION_STAGES = (
    STAGE_PRESENTED, STAGE_ABSTAINED, STAGE_REJECTED, STAGE_SUBMITTED_FOR_REVIEW,
    STAGE_OBJECTIVE_ADMITTED, STAGE_QUESTION_APPROVED, STAGE_QUESTION_RELEASED,
    STAGE_MEASURED,
)

#: Stages that mean "this is a research question the owner has put forward".
#: An abstained or rejected candidate is never in this set: counting it as an
#: admitted question would overstate what exists.
_ADMITTED_STAGES = frozenset({
    STAGE_OBJECTIVE_ADMITTED, STAGE_QUESTION_APPROVED, STAGE_QUESTION_RELEASED,
    STAGE_MEASURED,
})

#: Evidence classes kept apart. A methodological source explains why an analysis
#: is appropriate; it is never evidence that a business claim is true.
ENTREPRENEUR_DECLARATION = 'ENTREPRENEUR_DECLARATION'
ENTREPRENEUR_HYPOTHESIS = 'ENTREPRENEUR_HYPOTHESIS'
AI_CANDIDATE = 'AI_GENERATED_CANDIDATE'
METHODOLOGICAL_GUIDANCE = 'METHODOLOGICAL_GUIDANCE'
CUSTOMER_MEASUREMENT = 'CUSTOMER_RESEARCH_EVIDENCE'
GEOGRAPHIC_EVIDENCE = 'GEOGRAPHIC_PROPERTY_EVIDENCE'
MODEL_OUTPUT = 'MODEL_OUTPUT'
ADMINISTRATIVE_SOURCE = 'ADMINISTRATIVE_RECORD'

#: The nine sections, in document order. ``id`` matches the DOM anchor the Jaspr
#: view already uses, so the composed order and the rendered order cannot drift
#: without a test failing. ``a10`` lists the A10 sections a section draws on.
SECTIONS: tuple[tuple[str, str, str, str, tuple[str, ...]], ...] = (
    ('01', 'asw-rpt-overview', 'Assessment overview',
     'What this report covers and what it can safely conclude.', ('R02', 'R12')),
    ('02', 'asw-rpt-business', 'Business description',
     'The business you confirmed, at the version this report used.', ('R02',)),
    ('03', 'asw-rpt-findings', 'Business findings and uncertainties',
     'Finding decisions recorded for this assessment.', ('R09', 'R10')),
    ('04', 'asw-rpt-decisions', 'Research and question decisions',
     'The research objective and every question decision in this session.',
     ('R12',)),
    ('05', 'asw-rpt-questionnaire', 'Customer questionnaire',
     'Fielded customer responses admitted to this report.',
     ('R03', 'R04', 'R05', 'R06', 'R07', 'R08')),
    ('06', 'asw-rpt-extras', 'Additional questions',
     'Questions added beyond the fixed core, and whether they were measured.',
     ()),
    ('07', 'asw-rpt-evidence', 'Evidence and scoring',
     'Measured location evidence, the requirement checks and the model output.',
     ('R12',)),
    ('08', 'asw-rpt-coverage', 'Report coverage',
     'Which report sections the backend could actually fill for this record.',
     ('R02', 'R12')),
    ('09', 'asw-rpt-sources', 'Sources and limitations',
     'Where each section came from, and what is still missing.', ()),
)

#: A10 states that forbid rendering a measurement in that section.
_NO_MEASUREMENT_STATES = frozenset({
    'NEVER', 'NOT_A_CUSTOMER_SECTION', 'SEPARATE_INPUT_PUBLISHER',
    'SEPARATE_INPUT_ENTREPRENEUR_PLAN', 'UNAVAILABLE_MISSING_APPROVED_STIMULUS',
})


def _now_iso() -> str:
    return datetime.now(UTC).isoformat()


def _evidence(
    *, claim_id: str, section: str, source_type: str, source_ref: Mapping | None,
    evidence_status: str, admission_status: str,
    limitations: Sequence[str] = (), **identity: Any,
) -> dict:
    """One traceable claim. Every field a reader needs to find the source again.

    ``identity`` carries the optional provenance slots (assessment id, revision,
    question id, snapshot id, analysis method). They are emitted as ``None``
    rather than omitted so a consumer always sees the same shape and cannot
    mistake a missing key for "not applicable".
    """
    return {
        'claim_id': claim_id,
        'section': section,
        'source_type': source_type,
        'source_ref': dict(source_ref or {}),
        'assessment_id': identity.get('assessment_id'),
        'assessment_revision': identity.get('assessment_revision'),
        'question_id': identity.get('question_id'),
        'measurement_snapshot_id': identity.get('measurement_snapshot_id'),
        'analysis_method': identity.get('analysis_method'),
        'evidence_status': evidence_status,
        'admission_status': admission_status,
        'limitations': [str(x) for x in limitations if x],
    }


def _section(
    *, index: str, dom_id: str, title: str, purpose: str,
    availability: str, reason_code: str, detail: str,
    a10_states: Sequence[Mapping], evidence: Sequence[Mapping],
    chart: Mapping | None = None, items: Sequence[Mapping] = (),
    measurement_state: str | None = None,
    extra: Mapping | None = None,
) -> dict:
    section = {
        'index': index,
        'dom_id': dom_id,
        'title': title,
        'purpose': purpose,
        'availability': availability,
        'reason_code': reason_code,
        'detail': detail,
        'measurement_state': measurement_state,
        'a10': list(a10_states),
        'evidence': list(evidence),
        'chart': dict(chart) if chart is not None else None,
        'items': list(items),
    }
    if extra:
        # Section-specific machine-readable state. Added rather than merged into
        # ``detail`` so a consumer never has to parse prose.
        section.update({str(k): v for k, v in extra.items()})
    return section


def _a10_states(section_ids: Sequence[str], section_map: Mapping) -> list[dict]:
    """The A10 contract state of each section this report section draws on.

    ``may_render_a_measurement`` is deliberately **not** the contract's own
    structural flag passed through. The contract's flag answers "does this
    section kind ever carry a measurement", which is true for R03–R08 even
    while every one of them is blocked by open gates. Read on its own it looks
    like authorization, and that misreading is what this function removes: the
    flag is only true when the section is actually reportable and no gate is
    open. The structural fact survives as ``contract_permits_measurement``, and
    ``render_authorized`` stays false because no admission decision is adopted.
    """
    out: list[dict] = []
    for section_id in section_ids:
        section = section_map.get(section_id)
        if section is None:
            out.append({'section': section_id, 'state': 'UNKNOWN',
                        'blocking_gate_ids': [], 'requires_v': None,
                        'may_render_a_measurement': False,
                        'contract_permits_measurement': False,
                        'render_authorized': False,
                        'authorization_basis': 'SECTION_UNKNOWN'})
            continue
        blocking = list(section.blocking_gate_ids)
        reportable = bool(getattr(section, 'reportable_with_valid_evidence', False))
        unblocked = reportable and not blocking
        out.append({
            'section': section_id,
            'state': section.state,
            'blocking_gate_ids': blocking,
            'requires_v': section.requires_v,
            'may_render_a_measurement': bool(
                unblocked and section.may_render_a_measurement),
            'contract_permits_measurement': bool(section.may_render_a_measurement),
            'render_authorized': False,
            'authorization_basis': (
                'SECTION_BLOCKED_BY_OPEN_GATES' if blocking
                else 'SECTION_NOT_REPORTABLE' if not reportable
                else 'NO_ADOPTED_ADMISSION_DECISION'),
        })
    return out


def _measurement_state(entry: Mapping) -> str:
    """Map one stored admission state onto the report's own vocabulary.

    ``ADMITTED`` passes through unchanged, because it is the one state that
    authorises a number. ``ADMITTED_SYNTHETIC`` is mapped to ``WITHHELD``: a
    synthetic test admission is a different value by design, and a report that
    treated it as ``ADMITTED`` would publish a test fixture as a finding.
    """
    raw = str(entry.get('admission_state') or '').upper()
    if raw == MEASUREMENT_ADMITTED:
        return MEASUREMENT_ADMITTED
    if raw.startswith('WITHHELD') or raw == 'ADMITTED_SYNTHETIC':
        return MEASUREMENT_WITHHELD
    if raw == 'NOT_SHOWN':
        return MEASUREMENT_NOT_SHOWN
    if raw.startswith('UNAVAILABLE'):
        return MEASUREMENT_UNAVAILABLE
    if raw in ('', 'NONE'):
        return MEASUREMENT_ABSENT
    return MEASUREMENT_WITHHELD


def _slot_chart(state: str, decision: Mapping | None = None) -> dict:
    """The chart state for one slot.

    A chart is drawn only from an ``ADMITTED`` measurement, and only by
    *referencing* the ``ChartSpec`` the admission decision named. The
    composition never builds a spec of its own: two chart builders would be two
    answers to "what may this chart show".
    """
    if state == MEASUREMENT_ADMITTED:
        decision = decision or {}
        return {
            'status': CHART_ADMITTED,
            'chart_spec_id': decision.get('chart_spec_id'),
            'chart_schema_version': decision.get('chart_schema_version'),
            'authority': decision.get('authority'),
            'admission_decision_id': decision.get('decision_id'),
            'reason': 'An admission decision authorized this measurement and '
                      'named the chart specification that describes it.',
        }
    if state == MEASUREMENT_WITHHELD:
        return {'status': CHART_WITHHELD,
                'reason': 'The measurement exists and its numbers are withheld; '
                          'a chart would publish them.'}
    if state == MEASUREMENT_UNAVAILABLE:
        return {'status': CHART_UNAVAILABLE,
                'reason': 'The approved stimulus for this slot is missing, so '
                          'there is no measurement to chart.'}
    return {'status': CHART_NONE,
            'reason': 'This slot has no measurement to chart. Not a zero result.'}


# -- additional research (Section B) ---------------------------------------

def _admission_stage(item: Mapping) -> str:
    """How far one Section B item actually got, from the record alone.

    The five things a reader might otherwise conflate, in increasing authority:
    a candidate was presented, an objective was admitted, a question was
    approved into the instrument, a questionnaire version was released, and a
    measurement was admitted. ``APPROVE_FOR_REVIEW`` sits at the *first* of
    these — it is the owner approving their own candidate for review, and it
    admits nothing.
    """
    # ``measurement_id`` names the metric the item *would* be measured by; it is
    # not evidence that a result exists. Only the measurement state says that.
    if str(item.get('measurement_state') or '').upper() == 'MEASURED':
        return STAGE_MEASURED
    if item.get('fielding_authorized'):
        return STAGE_QUESTION_RELEASED
    if item.get('objective_admission_id'):
        return STAGE_OBJECTIVE_ADMITTED
    structural = str(item.get('structural_status') or '').upper()
    review = str(item.get('review_decision') or '').upper()
    if structural == 'ABSTAINED':
        return STAGE_ABSTAINED
    if review in ('REJECT', 'REJECTED', 'DECLINE', 'DECLINED'):
        return STAGE_REJECTED
    if review == 'APPROVE_FOR_REVIEW':
        return STAGE_SUBMITTED_FOR_REVIEW
    return STAGE_PRESENTED


def summarise_additional(raw: Mapping | None) -> dict:
    """Reduce the Section B loader output to what the report may say.

    The loader returns the owner's own question-design records: admitted
    objectives and Direct-QG candidates with their review decisions. None of it
    is respondent evidence, and no candidate carries a measurement, so every
    item is reported at the *stage it actually reached* and marked unmeasured.
    The measurement attributes the report cannot obtain (level, method,
    denominator) are reported as ``UNESTABLISHED`` rather than guessed.

    The counts are per stage. A single "additional questions" total is what let
    an abstained candidate be described as admitted, so there is no such total.
    """
    if not raw:
        return {
            'status': 'NOT_RESOLVED',
            'reason_code': 'ADDITIONAL_RESEARCH_NOT_READ',
            'detail': 'The additional-research source was not read for this '
                      'report, so nothing is claimed about Section B.',
            'objectives': [],
            'items': [],
            'counts': _stage_counts([]),
        }

    if raw.get('status') == 'UNAVAILABLE':
        return {
            'status': 'UNAVAILABLE',
            'reason_code': raw.get('reason_code') or 'ADDITIONAL_RESEARCH_UNAVAILABLE',
            'detail': raw.get('detail')
                      or 'The additional-research store could not be read.',
            'objectives': [], 'items': [], 'counts': _stage_counts([]),
        }

    objectives = [dict(o) for o in (raw.get('objectives') or [])]
    items = [dict(i) for i in (raw.get('items') or [])]
    for item in items:
        item['admission_stage'] = _admission_stage(item)
    counts = _stage_counts([i['admission_stage'] for i in items])
    counts['objectives'] = len(objectives)
    counts['objectives_admitted'] = sum(
        1 for o in objectives if o.get('objective_id')
        and not str(o.get('objective_id')).startswith('proposal:'))
    return {
        'status': 'AVAILABLE',
        'reason_code': None,
        'detail': None,
        'objectives': objectives,
        'items': items,
        'counts': counts,
    }


def _stage_counts(stages: Sequence[str]) -> dict:
    """Per-stage counts, plus the one figure that may be called 'admitted'."""
    by_stage = {stage: 0 for stage in ADMISSION_STAGES}
    for stage in stages:
        by_stage[stage] = by_stage.get(stage, 0) + 1
    return {
        'candidates_presented': len(stages),
        'by_stage': by_stage,
        'admitted_research_questions': sum(
            1 for stage in stages if stage in _ADMITTED_STAGES),
        'not_admitted': sum(
            1 for stage in stages
            if stage in (STAGE_ABSTAINED, STAGE_REJECTED, STAGE_PRESENTED,
                         STAGE_SUBMITTED_FOR_REVIEW)),
        'measured': by_stage.get(STAGE_MEASURED, 0),
    }


# -- composition ------------------------------------------------------------

def compose(
    *,
    assessment: Mapping | None,
    report: Mapping | None,
    measurement: Mapping | None,
    business_description: Mapping | None = None,
    additional: Mapping | None = None,
    findings: Mapping | None = None,
    section_map: Mapping | None = None,
    a10_counts: Mapping | None = None,
    decision_counts: Mapping | None = None,
    adopted_decision_count: int = 0,
    embed_report: bool = False,
) -> dict:
    """Compose the nine-section document skeleton for one assessment.

    Every argument is optional and every missing one degrades to a named state.
    ``section_map``/``a10_counts``/``decision_counts`` default to the live A10
    contract so production cannot silently diverge from it, while a test can
    pass a fixed map.
    """
    if section_map is None or a10_counts is None or decision_counts is None:
        from sitewise.project1 import a10_decisions, a10_gates

        section_map = section_map if section_map is not None else a10_gates.section_map()
        a10_counts = a10_counts if a10_counts is not None else a10_gates.counts()
        decision_counts = (decision_counts if decision_counts is not None
                           else a10_decisions.counts())

    assessment_id = str((assessment or {}).get('assessment_id') or '') or None
    revision = (assessment or {}).get('requirements_version')
    m2 = ((assessment or {}).get('m2_confirmation') or {}) if assessment else {}
    m2_id = m2.get('m2_assessment_id')

    sections: list[dict] = []

    # -- 01 overview -------------------------------------------------------
    sections.append(_section(
        index='01', dom_id='asw-rpt-overview', title='Assessment overview',
        purpose='What this report covers and what it can safely conclude.',
        availability=ADMINISTRATIVE if assessment_id else UNAVAILABLE,
        reason_code='REPORT_SUBJECT_RESOLVED' if assessment_id else 'ASSESSMENT_NOT_FOUND',
        detail=(
            'Administrative summary of this report. It states what the '
            'document contains and what it does not conclude; it is not itself '
            'a finding.'
            if assessment_id else
            'No assessment record was supplied, so no report subject exists.'
        ),
        a10_states=_a10_states(('R02', 'R12'), section_map),
        evidence=[_evidence(
            claim_id='S01-C01', section='01',
            source_type=ADMINISTRATIVE_SOURCE,
            source_ref={'assessment_status': (assessment or {}).get('status'),
                        'requirements_version': revision},
            evidence_status='PRESENT' if assessment_id else 'ABSENT',
            admission_status='NOT_REQUIRED',
            assessment_id=assessment_id, assessment_revision=revision,
        )],
    ))

    # -- 02 business description ------------------------------------------
    description = business_description or {}
    desc_status = str(description.get('status') or 'NOT_RESOLVED')
    if desc_status == 'AVAILABLE':
        source = description.get('source') or {}
        sections.append(_section(
            index='02', dom_id='asw-rpt-business', title='Business description',
            purpose='The business you confirmed, at the version this report used.',
            availability=AVAILABLE,
            reason_code='BUSINESS_DESCRIPTION_CONFIRMED',
            detail='The confirmed business description, read back at the '
                   'revision this report used. It is entrepreneur-provided '
                   'information, not independently verified market evidence.',
            a10_states=_a10_states(('R02',), section_map),
            evidence=[_evidence(
                claim_id='S02-C01', section='02',
                source_type=ENTREPRENEUR_DECLARATION,
                source_ref={
                    'm2_assessment_id': source.get('m2_assessment_id'),
                    'context_id': source.get('context_id'),
                    'confirmation_id': source.get('confirmation_id'),
                    'packet_hash': source.get('packet_hash'),
                    'concept_version': source.get('concept_version'),
                    'concept_status': source.get('concept_status'),
                    'row_count': len(description.get('rows') or []),
                },
                evidence_status='PRESENT',
                admission_status='NOT_REQUIRED',
                limitations=list(description.get('limitations') or []) + [
                    'Entrepreneur-confirmed declaration. Not a verified finding '
                    'about the market.',
                ],
                assessment_id=assessment_id,
                assessment_revision=source.get('assessment_revision', revision),
            )],
        ))
    else:
        detail = description.get('detail') or (
            'No confirmed business description is bound to this assessment, so '
            'section 02 states the absence rather than showing an empty '
            'declaration.')
        sections.append(_section(
            index='02', dom_id='asw-rpt-business', title='Business description',
            purpose='The business you confirmed, at the version this report used.',
            availability=UNAVAILABLE,
            reason_code=desc_status,
            detail=detail,
            a10_states=_a10_states(('R02',), section_map),
            evidence=[_evidence(
                claim_id='S02-C01', section='02',
                source_type=ENTREPRENEUR_DECLARATION,
                source_ref={'reason_code': desc_status},
                evidence_status='ABSENT', admission_status='NOT_REQUIRED',
                assessment_id=assessment_id, assessment_revision=revision,
            )],
        ))

    # -- 03 findings -------------------------------------------------------
    sections.append(_findings_section(
        assessment_id=assessment_id, revision=revision, findings=findings,
        section_map=section_map))

    # -- 04 research and question decisions --------------------------------
    requirements = (assessment or {}).get('requirements') or {}
    decision_items = requirements.get('question_decisions') or []
    sections.append(_section(
        index='04', dom_id='asw-rpt-decisions',
        title='Research and question decisions',
        purpose='The research objective and every question decision in this session.',
        availability=ADMINISTRATIVE,
        reason_code='DECISION_REGISTER_RENDERED',
        detail='The research objective and the question decisions recorded for '
               'this assessment. These are design decisions, not findings.',
        a10_states=_a10_states(('R12',), section_map),
        evidence=[_evidence(
            claim_id='S04-C01', section='04',
            source_type=ADMINISTRATIVE_SOURCE,
            source_ref={'question_decision_count': len(decision_items),
                        'requirements_version': revision},
            evidence_status='PRESENT' if decision_items else 'ABSENT',
            admission_status='NOT_REQUIRED',
            assessment_id=assessment_id, assessment_revision=revision,
        )],
    ))

    # -- 05 customer questionnaire ----------------------------------------
    sections.append(_questionnaire_section(
        assessment_id=assessment_id, revision=revision, measurement=measurement,
        section_map=section_map))

    # -- 06 additional questions (Section B) -------------------------------
    sections.append(_additional_section(
        assessment_id=assessment_id, revision=revision, additional=additional))

    # -- 07 evidence and scoring ------------------------------------------
    report = report or {}
    categories = report.get('evidence_categories') or {}
    association = report.get('research_association') or {}
    evidence_available = bool(categories.get('available'))
    model_available = bool(association.get('available'))
    availability = (AVAILABLE if (evidence_available or model_available)
                    else UNAVAILABLE)
    sections.append(_section(
        index='07', dom_id='asw-rpt-evidence', title='Evidence and scoring',
        purpose='Measured location evidence, the requirement checks and the model output.',
        availability=availability,
        reason_code=('EVIDENCE_RENDERED' if evidence_available
                     else 'NO_ANALYSED_LOCATION_EVIDENCE'),
        detail=('Location evidence, requirement checks and the research-model '
                'association for this property. The model score is a research '
                'index, never a success probability.'
                if availability == AVAILABLE else
                str(categories.get('reason')
                    or 'No analysed location evidence exists for this property.')),
        a10_states=_a10_states(('R12',), section_map),
        evidence=[
            _evidence(
                claim_id='S07-C01', section='07',
                source_type=GEOGRAPHIC_EVIDENCE,
                source_ref={'available': evidence_available,
                            'group_count': len(categories.get('groups') or [])},
                evidence_status='PRESENT' if evidence_available else 'ABSENT',
                admission_status='NOT_REQUIRED',
                limitations=['Location evidence describes the surrounding area; '
                             'it is not a demand measurement.'],
                assessment_id=assessment_id, assessment_revision=revision,
            ),
            _evidence(
                claim_id='S07-C02', section='07',
                source_type=MODEL_OUTPUT,
                source_ref={'available': model_available,
                            'model': (report.get('model_information') or {}).get('model'),
                            'feature_set': (report.get('model_information')
                                            or {}).get('feature_set')},
                evidence_status='PRESENT' if model_available else 'ABSENT',
                admission_status='NOT_REQUIRED',
                limitations=['Model output is a research positive-label '
                             'association, not a business success probability.'],
                assessment_id=assessment_id, assessment_revision=revision,
            ),
        ],
    ))

    # -- 08 coverage -------------------------------------------------------
    # The tally covers all nine sections, so sections 08 and 09 are counted
    # before they are built. The earlier version tallied the first seven only,
    # which made the document contradict itself: four sections rendered
    # ADMINISTRATIVE while ``counts`` said two.
    tally = _tally([*sections, {'availability': ADMINISTRATIVE},
                    {'availability': ADMINISTRATIVE}])
    sections.append(_section(
        index='08', dom_id='asw-rpt-coverage', title='Report coverage',
        purpose='Which report sections the backend could actually fill for this record.',
        availability=ADMINISTRATIVE,
        reason_code='COVERAGE_COMPUTED',
        detail=(
            f"Across the nine sections: {tally[AVAILABLE]} carry evidence, "
            f"{tally[ADMINISTRATIVE]} are administrative (this one included), "
            f"{tally[WITHHELD]} withheld, {tally[UNAVAILABLE]} unavailable and "
            f"{tally[PENDING]} pending measurement. Coverage is a statement "
            'about this document, not about the business.'
        ),
        a10_states=_a10_states(('R02', 'R12'), section_map),
        evidence=[_evidence(
            claim_id='S08-C01', section='08',
            source_type=ADMINISTRATIVE_SOURCE,
            source_ref={'coverage': tally,
                        'counts_scope': 'ALL_NINE_SECTIONS',
                        'a10_gates_closed': a10_counts.get('gates_closed'),
                        'a10_gate_identities': a10_counts.get('gate_identities_total'),
                        'a10_decisions_adopted': adopted_decision_count},
            evidence_status='PRESENT', admission_status='NOT_REQUIRED',
            assessment_id=assessment_id, assessment_revision=revision,
        )],
        extra={'coverage': tally},
    ))

    # -- 09 sources and limitations ---------------------------------------
    all_evidence = [e for s in sections for e in s['evidence']]
    missing = report.get('missing_information') or []
    sections.append(_section(
        index='09', dom_id='asw-rpt-sources', title='Sources and limitations',
        purpose='Where each section came from, and what is still missing.',
        availability=ADMINISTRATIVE,
        reason_code='SOURCE_TRAIL_RENDERED',
        detail='The source trail for every claim in this document, and the '
               'information that is still missing.',
        a10_states=(),
        evidence=[_evidence(
            claim_id='S09-C01', section='09',
            source_type=ADMINISTRATIVE_SOURCE,
            source_ref={'claim_count': len(all_evidence),
                        'missing_information_count': len(missing)},
            evidence_status='PRESENT', admission_status='NOT_REQUIRED',
            assessment_id=assessment_id, assessment_revision=revision,
        )],
    ))

    admitted_slots = sum(int(s.get('admitted_slots') or 0) for s in sections)
    counts_disclosed = admitted_slots > 0

    return {
        'contract_version': CONTRACT_VERSION,
        'assessment_id': assessment_id,
        'm2_assessment_id': m2_id,
        # Kept for wire compatibility. It is *not* a revision counter: see
        # ``revisions.marketplace_requirements_form_version``.
        'assessment_revision': revision,
        'assessment_revision_semantics': 'REQUIREMENTS_FORM_VERSION_NOT_A_REVISION',
        'revisions': _revisions(assessment, revision, m2_id, m2),
        'generated_at': _now_iso(),
        'counts_disclosed': counts_disclosed,
        'instrument': {
            'a10_contract_version': _contract_version(section_map),
            'gate_identities_total': a10_counts.get('gate_identities_total'),
            'gates_closed': a10_counts.get('gates_closed'),
            'undefined_gate_ids': a10_counts.get('undefined_gate_ids'),
            'decisions_total': decision_counts.get('total'),
            'decisions_adopted': adopted_decision_count,
        },
        'sections': sections,
        'counts': tally,
        # The report body this composition describes, embedded so a client can
        # read one document instead of issuing two requests that each rebuild
        # the same evidence. ``/report`` keeps serving it on its own.
        **({'report': report} if embed_report else {}),
        'admission': {
            'report_release_authorized': False,
            'counts_disclosed': counts_disclosed,
            'admitted_measurement_slots': admitted_slots,
            'disclosure_scope': ('PER_MEASUREMENT_ADMISSION' if counts_disclosed
                                 else 'NONE'),
            'reason_code': (
                'REPORT_RELEASE_NOT_AUTHORIZED' if counts_disclosed
                else 'REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE'),
            'detail': (
                'An A10 admission decision authorises the measurement it names, '
                'so that measurement is disclosed. Releasing the report as a '
                'whole is a separate act and remains unauthorized.'
                if counts_disclosed else
                'No A10 admission decision is adopted for any measurement in '
                'this assessment, so this document composes states and sources '
                'only. It never publishes a measurement.'
            ),
        },
    }


def _revisions(
    assessment: Mapping | None, form_version: Any, m2_id: str | None,
    m2: Mapping,
) -> dict:
    """Every revision-like number in this document, named for what it is.

    The report previously emitted one key, ``assessment_revision``, holding
    ``requirements_version`` — which is not a revision at all. It is a
    form-schema generation marker where 0 means "no requirements stored". Read
    beside an M2 confirmation at revision 23 it looked like "revision 0 of 23",
    a reconciliation of two counters that were never comparable.
    """
    instrument_version = None
    try:
        from sitewise.project1.explanation_registry import load_registry

        instrument_version = load_registry().instrument_version
    except Exception:  # noqa: BLE001 - a version string is never worth a 500
        instrument_version = None

    return {
        'marketplace_requirements_form_version': form_version,
        'marketplace_requirements_form_version_semantics': (
            '0 = no requirements stored; 1 = legacy criteria form; 2 = '
            'eight-question form; 3 = five-question V3 form. A form-schema '
            'generation marker, not a revision counter.'),
        'm2_confirmation_revision': m2.get('assessment_revision'),
        'm2_confirmation_id': m2.get('confirmation_id'),
        'm2_assessment_id': m2_id,
        'instrument_version': instrument_version,
        'report_revision': None,
        'report_revision_semantics': (
            'No report versioning or snapshot store exists, so a report has no '
            'revision identity of its own.'),
    }


def _contract_version(section_map: Mapping) -> str | None:
    try:
        from sitewise.project1 import a10_gates

        return a10_gates.contract_version()
    except Exception:  # noqa: BLE001 - a version string is never worth a 500
        return None


def _tally(sections: Sequence[Mapping]) -> dict:
    tally = {state: 0 for state in AVAILABILITY_STATES}
    for section in sections:
        state = str(section.get('availability'))
        tally[state] = tally.get(state, 0) + 1
    return tally


# -- section 03: finding existence ----------------------------------------

#: How each finding state renders. ``availability``, ``reason_code``,
#: ``evidence_status`` and ``admission_status`` — in that order.
_FINDING_PRESENTATION: dict[str, tuple[str, str, str, str]] = {
    FINDINGS_NOT_RECORDED: (
        UNAVAILABLE, 'NO_FINDINGS_RECORDED', 'ABSENT', 'NOT_ADMITTED'),
    FINDINGS_NOT_EXECUTED: (
        PENDING, 'EVALUATION_NOT_EXECUTED', 'UNEXECUTED', 'NOT_ADMITTED'),
    FINDINGS_ZERO_VALID: (
        AVAILABLE, 'ZERO_FINDINGS_VALID', 'PRESENT_ZERO_FINDINGS', 'NOT_REQUIRED'),
    FINDINGS_ACCEPTED_WITHHELD: (
        WITHHELD, 'FINDINGS_ACCEPTED_WITHHELD', 'PRESENT', 'WITHHELD'),
    FINDINGS_WITHHELD: (
        WITHHELD, 'REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE', 'PRESENT',
        'WITHHELD'),
    FINDINGS_UNESTABLISHED: (
        UNAVAILABLE, 'FINDINGS_STATE_UNESTABLISHED', 'UNESTABLISHED',
        'NOT_ADMITTED'),
}

_FINDING_DETAIL: dict[str, str] = {
    FINDINGS_NOT_RECORDED: (
        'No finding evaluation and no finding record exist for this '
        'assessment, so there is nothing to withhold and nothing to report.'),
    FINDINGS_NOT_EXECUTED: (
        'The finding evaluation has not run to a result for this assessment. '
        'This is not a finding of zero: no evaluation means no evidence '
        'either way.'),
    FINDINGS_ZERO_VALID: (
        'The evaluation ran and produced no finding. A valid zero is a result, '
        'not an absence: the rules were applied and none fired.'),
    FINDINGS_ACCEPTED_WITHHELD: (
        'Findings were produced and accepted for research, and are withheld '
        'from this report because no admission decision releases them. '
        'Withheld is not "no finding".'),
    FINDINGS_WITHHELD: (
        'Findings are recorded for this assessment and withheld from the '
        'entrepreneur report: no authorized evidence source exists to release '
        'them. Withheld is not "no finding".'),
    FINDINGS_UNESTABLISHED: (
        'The report could not establish whether business findings exist for '
        'this assessment, so it asserts neither their presence nor their '
        'absence.'),
}


def normalise_findings(findings: Mapping | None) -> dict:
    """Reduce a finding read to the one state the report may claim.

    An unrecognised or absent read is ``FINDINGS_UNESTABLISHED``. It is never
    upgraded to "findings exist": the earlier composition did exactly that —
    it emitted ``evidence_status: PRESENT`` with a null readback state, which
    told a reader that withheld findings were there when nothing had been read.
    """
    if not findings:
        return {
            'state': FINDINGS_UNESTABLISHED,
            'evaluation_id': None,
            'run_id': None,
            'attempt_id': None,
            'finding_count': None,
            'accepted_count': None,
            'readback_state': None,
            'source_fingerprint': None,
        }
    state = str(findings.get('state') or '').upper()
    if state not in _FINDING_PRESENTATION:
        state = FINDINGS_UNESTABLISHED
    return {
        'state': state,
        'evaluation_id': findings.get('evaluation_id'),
        'run_id': findings.get('run_id'),
        'attempt_id': findings.get('attempt_id'),
        'finding_count': findings.get('finding_count'),
        'accepted_count': findings.get('accepted_count'),
        'readback_state': findings.get('readback_state'),
        'source_fingerprint': findings.get('source_fingerprint'),
    }


def _findings_section(
    *, assessment_id: str | None, revision: Any, findings: Mapping | None,
    section_map: Mapping,
) -> dict:
    """Section 03. Existence first, admission second, and never a guess.

    The distinction this section has to keep: *no finding* is a result,
    *no evaluation* is an absence of result, and *withheld* is a result the
    report is not allowed to show. Collapsing any two of them misinforms the
    reader in a different direction.
    """
    resolved = normalise_findings(findings)
    state = resolved['state']
    availability, reason, evidence_status, admission_status = \
        _FINDING_PRESENTATION[state]

    count = resolved['finding_count']
    if count is not None and state in (FINDINGS_WITHHELD,
                                       FINDINGS_ACCEPTED_WITHHELD):
        # The count is deliberately not disclosed here; it is carried in the
        # source reference for an audit read, not printed as a finding.
        count_note = 'The number of findings is not disclosed in this report.'
    else:
        count_note = None

    limitations = [text for text in (
        count_note,
        'Withheld is not "no finding".' if state == FINDINGS_WITHHELD else None,
        'No evaluation is not a zero result.'
        if state == FINDINGS_NOT_EXECUTED else None,
    ) if text]

    return _section(
        index='03', dom_id='asw-rpt-findings',
        title='Business findings and uncertainties',
        purpose='Finding decisions recorded for this assessment.',
        availability=availability,
        reason_code=reason,
        detail=_FINDING_DETAIL[state],
        a10_states=_a10_states(('R09', 'R10'), section_map),
        evidence=[_evidence(
            claim_id='S03-C01', section='03',
            source_type=CUSTOMER_MEASUREMENT,
            source_ref={
                'finding_state': state,
                'readback_state': resolved['readback_state'],
                'evaluation_id': resolved['evaluation_id'],
                'run_id': resolved['run_id'],
                'attempt_id': resolved['attempt_id'],
                'finding_count': count,
                'accepted_count': resolved['accepted_count'],
                'source_fingerprint': resolved['source_fingerprint'],
            },
            evidence_status=evidence_status,
            admission_status=admission_status,
            limitations=limitations,
            assessment_id=assessment_id, assessment_revision=revision,
        )],
        extra={'finding_state': state,
               'finding_count': count,
               'finding_count_disclosed': False},
    )


def _questionnaire_section(
    *, assessment_id: str | None, revision: Any,
    measurement: Mapping | None, section_map: Mapping,
) -> dict:
    """Section 05. Identity, admission, and — only when admitted — a number."""
    measurement = measurement or {}
    status = str(measurement.get('status') or 'NOT_RESOLVED')
    slots = list(measurement.get('slots') or [])
    identity = measurement.get('identity') or {}
    decisions = measurement.get('admission_decisions') or {}

    states = [_measurement_state(slot) for slot in slots]
    admitted = sum(1 for state in states if state == MEASUREMENT_ADMITTED)
    withheld = sum(1 for state in states if state == MEASUREMENT_WITHHELD)

    if slots and admitted and not withheld:
        availability, reason = AVAILABLE, 'MEASUREMENT_ADMITTED'
        detail = ('Every measured slot in this section carries an A10 admission '
                  'decision, so its result is shown. The decision, not this '
                  'report, is what authorises the number.')
    elif slots and admitted:
        availability, reason = PARTIAL, 'MEASUREMENT_PARTIALLY_ADMITTED'
        detail = (f'{admitted} measured slot(s) are admitted and shown; '
                  f'{withheld} are withheld. The two states are never merged '
                  'into one figure.')
    elif status == 'ADMITTED' and not admitted:
        # An association that claims admission while no slot carries one is a
        # contradiction, and the safe reading is "not admitted". This is what a
        # synthetic test admission looks like from here.
        availability, reason = WITHHELD, 'A10_SYNTHETIC_NOT_REPORTABLE'
        detail = ('The measurement association reports an admission, but no '
                  'slot carries an ADMITTED verdict. A synthetic test admission '
                  'is a different value from ADMITTED, so nothing is disclosed.')
    elif status == 'HELD' and slots:
        availability = WITHHELD
        reason = str(measurement.get('reason_code')
                     or 'REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE')
        detail = str(measurement.get('reason') or (
            'A questionnaire measurement exists for this assessment and is '
            'held. Its counts are not published in this report.'))
    elif status == 'HELD' and not slots:
        availability, reason = PENDING, 'NO_MEASUREMENT'
        detail = 'A questionnaire campaign exists but has produced no snapshot.'
    elif status == 'NO_M2_LINK':
        availability, reason = UNAVAILABLE, 'NO_M2_LINK'
        detail = str(measurement.get('reason') or
                     'This assessment has no confirmed M2 research record.')
    elif status == 'NO_CAMPAIGN':
        availability, reason = PENDING, 'NO_CAMPAIGN'
        detail = str(measurement.get('reason') or
                     'The confirmed M2 assessment has no questionnaire campaign.')
    elif status == 'UNAVAILABLE':
        availability, reason = UNAVAILABLE, str(measurement.get('reason_code')
                                                or MEASUREMENT_UNREADABLE)
        detail = str(measurement.get('reason') or
                     'The questionnaire store could not be read. This is not a '
                     'measured zero.')
    else:
        availability, reason = UNAVAILABLE, 'MEASUREMENT_NOT_RESOLVED'
        detail = ('No measurement association was resolved for this report, so '
                  'nothing is claimed about customer evidence.')

    evidence = []
    slot_charts = []
    for position, slot in enumerate(slots, start=1):
        state = _measurement_state(slot)
        decision = decisions.get(str(slot.get('slot_id'))) or {}
        chart = _slot_chart(state, decision)
        slot_charts.append({'slot_id': slot.get('slot_id'), 'state': state,
                            'chart': chart})
        evidence.append(_evidence(
            claim_id=f'S05-C{position:02d}', section='05',
            source_type=CUSTOMER_MEASUREMENT,
            source_ref={
                'slot_id': slot.get('slot_id'),
                'snapshot_id': slot.get('snapshot_id'),
                'question_version': slot.get('question_version'),
                'cutoff': slot.get('cutoff'),
                'admission_state': slot.get('admission_state'),
                'admission_decision_id': decision.get('decision_id'),
                'campaign_id': identity.get('campaign_id'),
                'release_id': identity.get('release_id'),
            },
            evidence_status=('PRESENT' if state in (MEASUREMENT_WITHHELD,
                                                    MEASUREMENT_ADMITTED)
                             else 'ABSENT' if state == MEASUREMENT_NOT_SHOWN
                             else 'UNESTABLISHED'),
            admission_status=('ADMITTED' if state == MEASUREMENT_ADMITTED
                              else 'WITHHELD' if state == MEASUREMENT_WITHHELD
                              else 'NOT_ADMITTED'),
            limitations=[
                'The measurement is admitted; its numbers are disclosed under '
                'that decision.' if state == MEASUREMENT_ADMITTED else
                'The measurement exists; its counts are withheld from the '
                'ordinary report.' if state == MEASUREMENT_WITHHELD else
                'No measurement was produced for this slot. That is not a '
                'measured zero.' if state == MEASUREMENT_NOT_SHOWN else
                'The approved stimulus required to measure this slot is absent.'
            ],
            assessment_id=assessment_id, assessment_revision=revision,
            question_id=slot.get('slot_id'),
            measurement_snapshot_id=slot.get('snapshot_id'),
        ))

    if not evidence:
        evidence.append(_evidence(
            claim_id='S05-C00', section='05', source_type=CUSTOMER_MEASUREMENT,
            source_ref={'reason_code': reason},
            evidence_status='ABSENT', admission_status='NOT_ADMITTED',
            assessment_id=assessment_id, assessment_revision=revision,
        ))

    primary = states[0] if states else None
    # A chart is drawn for the first admitted slot, because that is the only
    # slot a chart is allowed to describe. Falling back to the focus slot would
    # put a WITHHELD chart on a section that does have an admitted result.
    chart_index = next((i for i, state in enumerate(states)
                        if state == MEASUREMENT_ADMITTED), None)
    if chart_index is not None:
        slot = slots[chart_index]
        chart = _slot_chart(MEASUREMENT_ADMITTED,
                            decisions.get(str(slot.get('slot_id'))) or {})
    elif primary:
        chart = _slot_chart(primary)
    else:
        chart = {'status': CHART_UNAVAILABLE,
                 'reason': 'No measurement slot exists, so there is no chart to draw.'}

    return _section(
        index='05', dom_id='asw-rpt-questionnaire', title='Customer questionnaire',
        purpose='Fielded customer responses admitted to this report.',
        availability=availability, reason_code=reason, detail=detail,
        a10_states=_a10_states(
            ('R03', 'R04', 'R05', 'R06', 'R07', 'R08'), section_map),
        evidence=evidence,
        chart=chart,
        measurement_state=primary,
        extra={'admitted_slots': admitted, 'withheld_slots': withheld,
               'slot_charts': slot_charts},
    )


_STAGE_LABEL = {
    STAGE_PRESENTED: 'presented with no review decision',
    STAGE_ABSTAINED: 'abstained by the generator',
    STAGE_REJECTED: 'rejected at review',
    STAGE_SUBMITTED_FOR_REVIEW: 'submitted for review',
    STAGE_OBJECTIVE_ADMITTED: 'admitted as a research objective',
    STAGE_QUESTION_APPROVED: 'approved into the questionnaire',
    STAGE_QUESTION_RELEASED: 'in a released questionnaire',
    STAGE_MEASURED: 'measured',
}


def _stage_phrase(by_stage: Mapping) -> str:
    """Only the stages that actually occurred, so a zero is not implied to exist."""
    parts = [f'{by_stage[stage]} {_STAGE_LABEL[stage]}'
             for stage in ADMISSION_STAGES if by_stage.get(stage)]
    return ', '.join(parts) if parts else 'none recorded'


def _additional_section(
    *, assessment_id: str | None, revision: Any, additional: Mapping | None,
) -> dict:
    """Section 06. The only place a Section B result may appear.

    The fixed registry maps Q01–Q13 into R02–R08. A generated additional
    question has no registry entry, so it cannot enter those sections — and it
    must not be hard-coded into the registry to make it display. Section 06 is
    the existing extension point: it lists what was added, the stage each item
    actually reached, and whether a measurement exists. Today none has one,
    because the Section B measurement contract is not defined upstream; that is
    reported as ``UNESTABLISHED``, never as a zero.
    """
    summary = summarise_additional(additional)
    items = list(summary['items'])
    objectives = list(summary['objectives'])
    counts = summary['counts']

    if summary['status'] == 'AVAILABLE' and items:
        availability, reason = PARTIAL, 'ADDITIONAL_CANDIDATES_NOT_ADMITTED'
        detail = (
            f'{counts["candidates_presented"]} candidate question(s) are '
            f'recorded ({_stage_phrase(counts["by_stage"])}). '
            f'{counts["admitted_research_questions"]} reached an admitted stage. '
            'A candidate submitted for review is not an admitted research '
            'question, not an approved questionnaire item and not a release.'
        )
        if counts['admitted_research_questions']:
            reason = 'ADDITIONAL_ITEMS_UNMEASURED'
            detail += (
                ' Section B measurement attributes (level, method, denominator) '
                'are not yet defined upstream, so no result is shown.')
    elif summary['status'] == 'AVAILABLE':
        availability, reason = NOT_APPLICABLE, 'SECTION_B_EMPTY'
        detail = (
            'No additional question was admitted for this assessment, so the '
            'questionnaire is the fixed core only. An empty Section B is a '
            'legitimate state and does not block the rest of the report.'
        )
    elif summary['status'] == 'UNAVAILABLE':
        availability, reason = UNAVAILABLE, str(summary['reason_code'])
        detail = str(summary['detail'])
    else:
        availability, reason = UNAVAILABLE, 'ADDITIONAL_RESEARCH_NOT_READ'
        detail = str(summary['detail'])

    evidence = []
    for position, item in enumerate(items, start=1):
        stage = item.get('admission_stage') or _admission_stage(item)
        evidence.append(_evidence(
            claim_id=f'S06-C{position:02d}', section='06',
            source_type=AI_CANDIDATE,
            source_ref={
                'candidate_id': item.get('candidate_id'),
                'objective_id': item.get('objective_id'),
                'objective_admission_id': item.get('objective_admission_id'),
                'admission_stage': stage,
                'review_decision': item.get('review_decision'),
                'structural_status': item.get('structural_status'),
                'semantic_status': item.get('semantic_status'),
                'measurement_id': item.get('measurement_id'),
                'measurement_version': item.get('measurement_version'),
                'fielding_authorized': item.get('fielding_authorized'),
            },
            evidence_status=('ABSENT' if stage == STAGE_ABSTAINED else 'PRESENT'),
            admission_status=('ADMITTED' if stage == STAGE_MEASURED
                              else 'NOT_ADMITTED'),
            limitations=[
                'AI-generated question candidate, not respondent evidence.',
                'No measurement exists for this item, so it has no result.',
                f'Admission stage: {_STAGE_LABEL.get(stage, stage)}.',
            ],
            assessment_id=assessment_id, assessment_revision=revision,
            question_id=item.get('candidate_id'),
            analysis_method=item.get('measurement_id'),
        ))
    if not evidence:
        evidence.append(_evidence(
            claim_id='S06-C00', section='06', source_type=AI_CANDIDATE,
            source_ref={'reason_code': reason},
            evidence_status='ABSENT', admission_status='NOT_ADMITTED',
            assessment_id=assessment_id, assessment_revision=revision,
        ))

    return _section(
        index='06', dom_id='asw-rpt-extras', title='Additional questions',
        purpose='Questions added beyond the fixed core, and whether they were measured.',
        availability=availability, reason_code=reason, detail=detail,
        a10_states=(), evidence=evidence, items=items,
        chart={'status': CHART_NONE,
               'reason': 'Section B has no measurement contract, so no chart can '
                         'be specified for an additional item.'},
        extra={'additional_counts': counts,
               'objectives': objectives},
    )
