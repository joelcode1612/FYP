"""Build the Q01–Q13 explanation registry from the reconciled sources.

Single source of truth. The registry is generated, never hand-edited, so the
prose, the codes and the authority state cannot drift apart. Dart holds no copy:
explanations are rendered on the server, and the chart reads its own contract.

Inputs (all read-only, none modified):

1. ``backend/src/sitewise/customer_contracts/reference/CUST_RECOVERY_20261027/
   CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_CONTRACT.json``
   — the frozen recovery-candidate instrument: types, codes, substantive codes,
   display order, ordinal meaning, numerator rules, gating, permitted claims.
2. ``backend/docs/cq_runtime/QUESTION_CONTRACT_MATRIX.json``
   — the repository's own contract matrix: response types, max selections,
   exclusive codes, candidate gates, and **draft EN/BM option labels** (the only
   label bank in the repository).
3. ``deliverables/_cq13_handoff/…/QUESTION_OBJECTIVES_AND_FALLBACKS.json``
   — the owner-prepared question objectives, fallback text, permitted claims,
   prohibited inferences and coverage limitations. Used verbatim; never rewritten.

    backend/.venv/Scripts/python.exe scripts/build_explanation_registry.py
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
REPO = BACKEND.parent

CUST_PATH = (BACKEND / 'src' / 'sitewise' / 'customer_contracts' / 'reference'
             / 'CUST_RECOVERY_20261027'
             / 'CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_CONTRACT.json')
MATRIX_PATH = BACKEND / 'docs' / 'cq_runtime' / 'QUESTION_CONTRACT_MATRIX.json'
HANDOFF_PATH = (REPO / 'deliverables' / '_cq13_handoff' / 'PROJECT1_CQ13_RESEARCH_AND_QUERY_HANDOFF'
                / 'reports' / 'QUESTION_OBJECTIVES_AND_FALLBACKS.json')

OUT = REPO / 'deliverables' / 'PROJECT1_Q01_Q13_EXPLANATION_REGISTRY.json'
RECEIPT = REPO / 'deliverables' / 'PROJECT1_Q01_Q13_CONFLICT_RECEIPT.json'
#: The runtime copy. The generator writes the package path first and mirrors it to
#: ``deliverables/``, so the two are byte-identical and there is still only one
#: authored file.
RUNTIME_OUT = (BACKEND / 'src' / 'sitewise' / 'project1' / 'data'
               / 'q01_q13_explanation_registry.json')

#: Structural scaffolding shared by every item. This is deliberately separate
#: from the owner's item prose: it contains no claim, no figure and no finding,
#: only the connectives needed to place quoted prose into the six output fields.
FRAMING = {
    'headline': '{question_id} — {state_label}',
    'state_labels': {
        'NOT_AUTHORIZED': 'withheld, instrument not authorised',
        'BLOCKED_SOURCE': 'withheld, source unresolved',
        'MISSING_APPROVED_STIMULUS': 'withheld, approved stimulus absent',
        'MISSING_APPROVED_BANK': 'withheld, approved bank absent',
        'WITHDRAWN_OR_NO_CONSENT': 'withheld, consent or retention not established',
        'NO_ADMISSIBLE_RESPONSES': 'not estimable, no admissible responses',
        'NOT_SHOWN_APPROVED_ROUTE': 'not shown under the recorded routing rule',
        'UNKNOWN_ROUTE': 'withheld, applicability unverified',
        'NON_SUBSTANTIVE_ONLY': 'not estimable, no substantive answer',
        'REFUSED_OR_CANNOT_JUDGE': 'not estimable, refused or could not judge',
        'LOW_VALID_BASE': 'estimated on a small valid base',
        'VALID_APPROVED': 'substantive result',
    },
    'research_permitted_prefix': 'Permitted claim for {question_id}: ',
    'research_no_claim': ('No claim from {question_id} can be made in this state, so no '
                          'research conclusion is offered.'),
    'planning_withheld': ('No planning implication follows from a measurement that is '
                          'not available.'),
    'planning_valid': ('Stated responses are a planning input only; they are not a '
                       'forecast, price recommendation or viability assessment.'),
    'limitation_prefix': 'Item limitation: ',
    'limitation_coverage_prefix': 'Coverage limitation: ',
    'summary_withheld': ('The measurement for {question_id} is not reportable in this '
                         'state, so no interpretation is offered.'),
    'summary_valid': ('This explanation restates supplied figures for {question_id} '
                      'without recalculation, aggregation or rounding.'),
    'note': ('Structural scaffolding only. Contains no claim, figure, finding or '
             'measurement; every substantive sentence comes from the item templates or '
             'the owner-prepared state sentences.'),
}

#: Items whose show gate is itself unresolved. When the gate is not adopted, whether
#: the item should have been presented cannot be established, so the routing
#: evidence is unknown rather than merely absent.
UNRESOLVED_ROUTING = frozenset({'Q02', 'Q08', 'Q09', 'Q10'})

#: ``QUESTION_CONTRACT_MATRIX.json`` stores 15 labels whose en-dash was decoded as
#: cp1252 (``â€“`` instead of ``–``). This is a source encoding defect, not a
#: wording choice. It is repaired on read — a lossless, reversible transcoding of a
#: known corruption — and every repaired label keeps its raw form so the defect
#: stays visible. Nothing else about the label is altered.
MOJIBAKE_MARKER = '\u00e2\u20ac\u201c'

#: The same fault for U+00E9: ``C3 A9`` read as cp1252 becomes ``U+00C3 U+00A9``.
MOJIBAKE_E_ACUTE = '\u00c3\u00a9'


def repair_label(text: str | None) -> tuple[str | None, str | None]:
    """Return ``(label, repair_note)``; repair only the known en-dash corruption."""
    if not isinstance(text, str) or MOJIBAKE_MARKER not in text:
        return text, None
    try:
        recovered = text.encode('cp1252').decode('utf-8')
    except (UnicodeEncodeError, UnicodeDecodeError):
        # Unexpected bytes: keep the original and let the caller fall back to the
        # code rather than guess at a replacement.
        return text, 'UNREPAIRED_ENCODING_DEFECT'
    if '\u2013' not in recovered:
        return text, 'UNREPAIRED_ENCODING_DEFECT'
    return recovered, 'CP1252_UTF8_EN_DASH_RECOVERED'


#: The fields a draft option label may live in. CX-17 is only ever about these.
LABEL_FIELDS = ('draft_en_label', 'draft_bm_label')


def label_bank_defects(matrix: list) -> list[dict]:
    """Every draft label in the contract matrix that still carries the CX-17 defect.

    CX-17 is described in the registry as a *source* defect. Once the source is
    repaired that description would be false, so the conflict record is computed
    from the file rather than asserted. This function is the only place that
    decides whether the source is still defective.
    """
    found: list[dict] = []
    for item in matrix:
        for cell in (item.get('codes_and_candidate_labels') or []):
            for field in LABEL_FIELDS:
                value = cell.get(field)
                if isinstance(value, str) and MOJIBAKE_MARKER in value:
                    found.append({
                        'question_id': item.get('question_id'),
                        'source_code': cell.get('source_code'),
                        'field': field,
                        'value': value,
                    })
    return found

REGISTRY_VERSION = 'q01-q13-explanation/1'

#: The six mandatory project-level objectives. These are NOT the thirteen
#: question-level objectives, and a question is never counted as covering an
#: objective merely because it is related to one.
OBJECTIVES = [
    {'objective_id': 'O1', 'name': 'Concept Interest', 'closest_question': 'Q05',
     'adequacy': ('Stated likelihood, not observed demand; source BLOCKED_MEASUREMENT'),
     'covered_by_an_approved_measure': False},
    {'objective_id': 'O2', 'name': 'Product Preference', 'closest_question': 'Q06',
     'adequacy': ('Category interest, not pairwise preference; source BLOCKED_MEASUREMENT'),
     'covered_by_an_approved_measure': False},
    {'objective_id': 'O3', 'name': 'Price Acceptability', 'closest_question': 'Q07',
     'adequacy': ('Exact approved offer absent; source BLOCKED_MEASUREMENT'),
     'covered_by_an_approved_measure': False},
    {'objective_id': 'O4', 'name': 'Service Preference', 'closest_question': 'Q11',
     'adequacy': ('Optional context and owner-blocked; not yet mandatory O4 evidence'),
     'covered_by_an_approved_measure': False},
    {'objective_id': 'O5', 'name': 'Experience Preference', 'closest_question': 'Q10',
     'adequacy': ('Feature bank pending; cannot derive valid feature scores'),
     'covered_by_an_approved_measure': False},
    {'objective_id': 'O6', 'name': 'Segment Interest', 'closest_question': None,
     'adequacy': ('No dedicated approved measure; Q01 area affiliation is not a '
                  'customer-segment classifier'),
     'covered_by_an_approved_measure': False},
]

#: Which question is the *closest existing* measure for an objective. Recorded so
#: the mapping is explicit; it is never read as coverage.
OBJECTIVE_PROXIMITY = {'Q05': ['O1'], 'Q06': ['O2'], 'Q07': ['O3'],
                       'Q11': ['O4'], 'Q10': ['O5']}

RESPONSE_KIND = {
    'multi_select_with_exclusive_terminals': 'MULTI_SELECT',
    'multi_select': 'MULTI_SELECT',
    'ordinal_single': 'ORDINAL',
    'nominal_single': 'SINGLE_SELECT',
    'ordinal_matrix': 'MATRIX',
}

#: CUST03.report_availability states that may render a *measurement*. An
#: administrative section (``requires_V: false``) is renderable but is not
#: evidence, so it never authorises a substantive finding.
MEASUREMENT_RENDERABLE_STATES = frozenset()
ADMINISTRATIVE_STATES = frozenset({'RENDERABLE_ADMINISTRATIVE'})

#: The evidence states this registry recognises.
#:
#: Split into two axes because they answer different questions. An *instrument
#: gate* says whether the item may be measured at all; an *evidence state* says
#: what the collected data currently supports. Keeping them separate means a
#: governance block never hides a data condition, and every one of the twelve
#: cases stays reachable and testable.
INSTRUMENT_GATES = [
    'NOT_AUTHORIZED',
    'BLOCKED_SOURCE',
    'MISSING_APPROVED_STIMULUS',
    'MISSING_APPROVED_BANK',
]

EVIDENCE_STATES = [
    'WITHDRAWN_OR_NO_CONSENT',
    'NO_ADMISSIBLE_RESPONSES',
    'NOT_SHOWN_APPROVED_ROUTE',
    'UNKNOWN_ROUTE',
    'NON_SUBSTANTIVE_ONLY',
    'REFUSED_OR_CANNOT_JUDGE',
    'LOW_VALID_BASE',
    'VALID_APPROVED',
]

#: Owner-prepared state sentences, quoted verbatim from the handoff's "Report
#: fallback decision rules" table. These are the generic clauses; the item-level
#: ``templates.withheld`` text is the item-specific clause appended to them.
STATE_TEMPLATES = {
    'NOT_AUTHORIZED': (
        'Findings for {question_id} are withheld because the instrument, source or '
        'required stimulus has not been approved. No quantitative conclusion is issued.'),
    'BLOCKED_SOURCE': (
        'Findings for {question_id} are withheld because the instrument, source or '
        'required stimulus has not been approved. No quantitative conclusion is issued.'),
    'MISSING_APPROVED_STIMULUS': (
        'Findings for {question_id} are withheld because the instrument, source or '
        'required stimulus has not been approved. No quantitative conclusion is issued.'),
    'MISSING_APPROVED_BANK': (
        'Findings for {question_id} are withheld because the instrument, source or '
        'required stimulus has not been approved. No quantitative conclusion is issued.'),
    'NO_ADMISSIBLE_RESPONSES': (
        'No admissible respondent answers were available for {question_id}; the result '
        'is not estimable, not zero.'),
    'NOT_SHOWN_APPROVED_ROUTE': (
        '{question_id} was not presented to these respondents under the recorded routing '
        'rule; absence of an answer is not a negative response.'),
    'UNKNOWN_ROUTE': (
        "The question's applicability could not be established from approved routing "
        'evidence. Findings remain withheld pending verification.'),
    'REFUSED_OR_CANNOT_JUDGE': (
        '{count} of {shown} shown respondents declined or could not judge; these answers '
        'were not treated as substantive choices.'),
    'NON_SUBSTANTIVE_ONLY': (
        '{count} of {shown} shown respondents declined or could not judge; these answers '
        'were not treated as substantive choices.'),
    'LOW_VALID_BASE': (
        'Only {V} valid responses were available. Percentages, if displayed, describe '
        'this small group and should not be generalized.'),
    'WITHDRAWN_OR_NO_CONSENT': (
        'Responses excluded from analysis because valid consent or retention authority '
        'was not established.'),
    'VALID_APPROVED': None,  # rendered from the item's own ``templates.valid``
}

#: Which instrument gate an item's contract status implies. ``None`` means the
#: status is not an instrument gate and the data states apply.
STATUS_TO_GATE = {
    'BLOCKED_SOURCE': 'BLOCKED_SOURCE',
    'BLOCKED_OWNER': 'NOT_AUTHORIZED',
    'BLOCKED_MEASUREMENT': 'NOT_AUTHORIZED',
    'SCIENTIFIC_APPROVAL_PENDING': 'NOT_AUTHORIZED',
    'G06_APPROVAL_PENDING': 'MISSING_APPROVED_BANK',
    'AUTHORIZED': None,
    'APPROVED': None,
}

#: Items whose contract status is generic but whose specific gate is known.
ITEM_GATE_OVERRIDE = {
    'Q05': 'MISSING_APPROVED_STIMULUS',
    'Q06': 'MISSING_APPROVED_BANK',
    'Q07': 'MISSING_APPROVED_STIMULUS',
    'Q10': 'MISSING_APPROVED_BANK',
}

#: Instrument statuses that are a source defect rather than an approval gap.
SOURCE_BLOCKED_STATUSES = frozenset({'BLOCKED_SOURCE'})


def _measurement_rule(item: dict, kind: str) -> dict:
    """The EE-01 measurement rule for an item.

    Q05 is the only item carrying a predeclared numerator rule. Every other item
    is a plain per-code count over the item-specific V; recording that explicitly
    stops a later reader from inventing a numerator.
    """
    declared = item.get('numerator_rule')
    if declared:
        return {
            'rule_id': f"{item['id']}-NR-1",
            'basis': 'PREDECLARED_IN_CONTRACT',
            'numerator': list(declared.get('numerator_categories') or []),
            'denominator': declared.get('denominator'),
            'formula': declared.get('formula'),
            'applied_only_when': declared.get('applied_only_when'),
            'output_label': declared.get('output_label'),
            'expressly_not': list(declared.get('expressly_not') or []),
            'authority': declared.get('authority'),
        }
    per_code = kind in ('MULTI_SELECT', 'ORDINAL', 'SINGLE_SELECT')
    return {
        'rule_id': f"{item['id']}-NR-DEFAULT",
        'basis': 'STRUCTURAL_DEFAULT_NO_DECLARED_NUMERATOR',
        'numerator': (['each substantive code independently'] if per_code
                      else ['PER_FEATURE_DENOMINATOR_UNSUPPORTED']),
        'denominator': 'V for this item, version and stimulus',
        'formula': '100 * x[code] / V' if per_code else None,
        'applied_only_when': 'V > 0',
        'output_label': 'count and share per response code',
        'expressly_not': ['any aggregate score', 'any ranking across items',
                          'any conversion to demand, revenue or visits'],
        'authority': 'NO_DECLARED_NUMERATOR — only per-code counts are permitted',
    }


def _report_admission(cust: dict, sections: list[str]) -> dict:
    """Map the item's report sections onto CUST03's render availability.

    A substantive finding needs at least one section that may render a
    *measurement*. No section in this instrument qualifies, so the computed
    result is ``False`` for every item — derived here, never asserted.
    """
    availability = cust['report_availability']
    per_section = {}
    for section in sections:
        entry = availability.get(section) or {'state': 'NOT_DECLARED'}
        per_section[section] = {
            'state': entry.get('state'),
            'blocking_gates': list(entry.get('blocking_gates') or []),
            'reason': entry.get('reason'),
            'scope_qualifier': entry.get('scope_qualifier'),
            'may_render_measurement': entry.get('state') in MEASUREMENT_RENDERABLE_STATES,
            'administrative_only': entry.get('state') in ADMINISTRATIVE_STATES,
        }
    substantive = any(v['may_render_measurement'] for v in per_section.values())
    if not sections:
        requirement = ('No report section is assigned, so no section-level admission can '
                       'be requested. The item is unrenderable by construction.')
    elif substantive:
        requirement = 'At least one assigned section may render a measurement.'
    else:
        requirement = ('Every assigned section is held: none may render a measurement '
                       'until its blocking gates are closed and an adopted '
                       'ReportAdmission contract issues ADMITTED.')
    return {
        'sections': per_section,
        'any_section_may_render_measurement': substantive,
        'requirement': requirement,
        'suppression_controls': ['COMPLEMENTARY_SUPPRESSION',
                                 'CROSS_VIEW_DIFFERENCING_CHECK',
                                 'RESIDUAL_BUCKET_REQUIRED'],
        'suppression_floor': 'NOT_APPROVED — SD-11 Owner decision outstanding',
    }

#: Conflicts found while reconciling the three sources. Each cites both sides and
#: the later authority. ``resolution`` is only ever a *recorded* outcome; an
#: unresolved conflict is never silently decided by this build.
CONFLICTS = [
    {
        'conflict_id': 'CX-01', 'question_id': 'Q01', 'field': 'eligibility_effect',
        'source_a': {'artifact': 'CUST03 items[Q01].eligibility_effect',
                     'value': 'RARELY/NEVER -> AREA_OUTSIDE, NOT_SURE -> AREA_UNKNOWN, '
                              'default ELIGIBLE (a respondent-level screen-out)'},
        'source_b': {'artifact': 'QUESTION_OBJECTIVES_AND_FALLBACKS.md (Q01)',
                     'value': 'No respondent is declared ineligible solely from Q01'},
        'later_authority': {
            'artifact': 'CUST03 screening_architecture_decision + authority_directions.SD-09',
            'status': 'OWNER_DIRECTION_FOUND_FORMAL_APPROVAL_PENDING / OPEN_SD09',
            'value': 'candidate A direction recorded in chat 2026-10-27; not a formal '
                     'controlled spine amendment'},
        'resolution': 'UNRESOLVED_SCREEN_OUT_NOT_ADOPTED',
        'blocking_decision': 'SD-09 formal adoption of the screening architecture',
        'consequence': ('Q01 eligibility is not computed, so any gate of the form '
                        'Q01_ELIGIBLE is itself unresolved. No respondent is screened out.'),
    },
    {
        'conflict_id': 'CX-02', 'question_id': 'Q02', 'field': 'item_show_gate',
        'source_a': {'artifact': 'CUST03 routing_model.item_show_gate_decisions.Q02',
                     'value': 'ALWAYS (second pre-screen item)'},
        'source_b': {'artifact': 'CUST03 routing_model.item_show_gate_decisions.Q02.why',
                     'value': 'flips S_pre/Q_pre semantics; SD-C/SD-I territory; WS2-NEW-15 '
                              'requires a dated scope act and remains REMAINS_OPEN'},
        'later_authority': {'artifact': 'CUST03 (same field)',
                            'status': 'PROPOSED_PENDING_SD_C_SD_I (Scientific + Owner; NOT adopted)',
                            'value': 'gate value kept as a proposal only'},
        'resolution': 'UNRESOLVED_GATE_NOT_ADOPTED',
        'blocking_decision': 'SD-C / SD-I dated scope act',
        'consequence': 'Q02 show gate is recorded, never applied.',
    },
    {
        'conflict_id': 'CX-03', 'question_id': 'Q04', 'field': 'recall_period',
        'source_a': {'artifact': 'CUST03 items[Q04] stem',
                     'value': 'In the past 30 days, on how many occasions…'},
        'source_b': {'artifact': 'CUST03 items[Q04].coverage_limitation',
                     'value': 'The 30-day window is A10\'s; the 7-day item was the '
                              'pre-registered one. Recall validity for 30 days is untested.'},
        'later_authority': {'artifact': 'CUST03 items[Q04].disposition',
                            'status': 'NON_EQUIVALENT_REWRITE',
                            'value': 'recorded as a non-equivalent rewrite, not a silent edit'},
        'resolution': 'RECORDED_NOT_INTERCHANGEABLE',
        'blocking_decision': 'none for presentation; measurement approval outstanding',
        'consequence': ('The 30-day band is the only item that exists. A 7-day figure may '
                        'never be derived from it, and the two may never be pooled.'),
    },
    {
        'conflict_id': 'CX-04', 'question_id': 'Q05', 'field': 'stimulus',
        'source_a': {'artifact': 'CUST03 items[Q05] stem',
                     'value': 'the café described in [concept_card_version]'},
        'source_b': {'artifact': 'CUST03 items[Q05].gate_dependencies',
                     'value': 'G03, G04, G05, G06'},
        'later_authority': {'artifact': 'CUST03 items[Q05].status',
                            'status': 'BLOCKED_MEASUREMENT',
                            'value': 'no approved concept stimulus exists'},
        'resolution': 'UNRESOLVED_STIMULUS_ABSENT',
        'blocking_decision': 'concept-card approval (G03–G06)',
        'consequence': 'A Q05 measurement cannot be admitted without an approved stimulus.',
    },
    {
        'conflict_id': 'CX-05', 'question_id': 'Q06', 'field': 'codebook',
        'source_a': {'artifact': 'CUST03 items[Q06].codes',
                     'value': 'six substantive categories + UNLISTED_CATEGORY_REPORTED'},
        'source_b': {'artifact': 'CUST03 items[Q06].coverage_limitation',
                     'value': "M2-06 includes an 'Other' category that cannot be fielded as a "
                              'closed content code; only its presence is captured'},
        'later_authority': {'artifact': 'CUST03 items[Q06].status',
                            'status': 'BLOCKED_MEASUREMENT',
                            'value': 'menu codebook not approved'},
        'resolution': 'UNRESOLVED_CODEBOOK_NOT_APPROVED',
        'blocking_decision': 'menu codebook approval',
        'consequence': ('UNLISTED_CATEGORY_REPORTED is a presence flag, not a category. It '
                        'must never be presented as an interest category.'),
    },
    {
        'conflict_id': 'CX-06', 'question_id': 'Q07', 'field': 'exact_offer_stimulus',
        'source_a': {'artifact': 'CUST03 items[Q07].stem',
                     'value': '[exact_rm_price] for [one_exact_product_size_quantity_'
                              'fulfilment_and_charges]'},
        'source_b': {'artifact': 'CUST03 items[Q07].coverage_limitation',
                     'value': "No approved M2 offer exists. M2-10 admits 'latte/americano' "
                              "(two products) while CS-07 fixes 'latte'."},
        'later_authority': {'artifact': 'CUST03 items[Q07].status',
                            'status': 'BLOCKED_MEASUREMENT',
                            'value': 'stimulus_required=true, stimulus_absent_outcome=NOT_SHOWN'},
        'resolution': 'UNRESOLVED_STIMULUS_ABSENT',
        'blocking_decision': 'one exact approved offer and price',
        'consequence': ('Q07 stays WITHHELD. It is not chartable, not estimable and not '
                        'substitutable by Q13.'),
    },
    {
        'conflict_id': 'CX-07', 'question_id': 'Q08', 'field': 'show_gate_dependency',
        'source_a': {'artifact': 'QUESTION_CONTRACT_MATRIX.json Q08.candidate_gate',
                     'value': 'Q01_ELIGIBLE_AND_Q04_SUBSTANTIVE_NONZERO'},
        'source_b': {'artifact': 'CX-01 (Q01 eligibility is not adopted)',
                     'value': 'the Q01_ELIGIBLE half of this gate has no adopted definition'},
        'later_authority': {'artifact': 'CUST03 authority_directions.SD-09',
                            'status': 'OWNER_SELECTION_REQUIRED',
                            'value': 'screening architecture not formally adopted'},
        'resolution': 'UNRESOLVED_DEPENDENCY_UNRESOLVED',
        'blocking_decision': 'SD-09',
        'consequence': ('The Q04 half is well defined (substantive non-zero). The Q01 half '
                        'is not, so Q08 applicability is only partly determined.'),
    },
    {
        'conflict_id': 'CX-08', 'question_id': 'Q09', 'field': 'show_gate',
        'source_a': {'artifact': 'CUST03 routing_model.open_decisions.ROUTING-01',
                     'value': "class CONDITIONAL_R07 (grouped with Q08)"},
        'source_b': {'artifact': 'CUST03 inherited show_rule prose',
                     'value': 'Shown after the versioned concept card. Independent of Q04.'},
        'later_authority': {'artifact': 'CUST03 routing_model.open_decisions.ROUTING-01',
                            'status': 'NOT_SETTLED_BY_THIS_CORRECTION (WS2 scientific + Owner)',
                            'value': 'author_default Q01_ELIGIBLE_AND_Q04_SUBSTANTIVE_NONZERO, '
                                     'recorded as a default only'},
        'resolution': 'UNRESOLVED_ROUTING_CONFLICT',
        'blocking_decision': 'WS2 scientific + Owner ruling on ROUTING-01',
        'consequence': "R07's D05B denominator changes by the Q04=ZERO group depending on the ruling.",
    },
    {
        'conflict_id': 'CX-09', 'question_id': 'Q10', 'field': 'show_gate',
        'source_a': {'artifact': 'CUST03 routing_model.open_decisions.ROUTING-02',
                     'value': 'class CONDITIONAL_R07 with no gate of any kind'},
        'source_b': {'artifact': 'CUST03 routing_model.items_with_open_show_gate',
                     'value': 'Q09 and Q10 listed as having an open show gate'},
        'later_authority': {'artifact': 'CUST03 routing_model.open_decisions.ROUTING-02',
                            'status': 'NOT_SETTLED_BY_THIS_CORRECTION (WS2 scientific + Owner)',
                            'value': 'author_default recorded, not adopted'},
        'resolution': 'UNRESOLVED_ROUTING_CONFLICT',
        'blocking_decision': 'WS2 scientific + Owner ruling on ROUTING-02',
        'consequence': 'Q10 applicability is undetermined.',
    },
    {
        'conflict_id': 'CX-10', 'question_id': 'Q10', 'field': 'feature_bank',
        'source_a': {'artifact': 'CUST03 items[Q10].feature_bank.approved_bank',
                     'value': 'null'},
        'source_b': {'artifact': 'CUST03 items[Q10].feature_bank.author_proposal',
                     'value': "A10 v0.3:344 'Examples:' is a drafted example set, not an "
                              'approved exhaustive bank; F<=6 is an author burden cap'},
        'later_authority': {'artifact': 'CUST03 items[Q10].feature_bank.gate',
                            'status': 'G06_APPROVAL_PENDING',
                            'value': 'no approved bank'},
        'resolution': 'UNRESOLVED_BANK_ABSENT',
        'blocking_decision': 'G06 feature-bank approval',
        'consequence': ('There is no item-level V for Q10 and no pooling of features. No '
                        'Q10 chart, composite score or weight may be produced.'),
    },
    {
        'conflict_id': 'CX-11', 'question_id': 'Q10', 'field': 'denominator',
        'source_a': {'artifact': 'CUST03 items[Q10].per_feature_record',
                     'value': 'V_feature per feature; independent_per_feature=true; no pooling'},
        'source_b': {'artifact': 'EE-01 category cells',
                     'value': 'one V per snapshot, not per feature'},
        'later_authority': {'artifact': 'CUST03 items[Q10].per_feature_record.note',
                            'status': 'RECORDED',
                            'value': 'There is no item-level V for Q10'},
        'resolution': 'UNSUPPORTED_BY_CURRENT_ENGINE',
        'blocking_decision': 'a per-feature EE-01 measurement rule',
        'consequence': ('EE-01 cannot express V_feature, so Q10 is not chartable even if a '
                        'bank were approved. Recorded rather than approximated.'),
    },
    {
        'conflict_id': 'CX-12', 'question_id': 'Q11', 'field': 'report_authorization',
        'source_a': {'artifact': 'CUST03 items[Q11].status', 'value': 'BLOCKED_OWNER'},
        'source_b': {'artifact': 'CUST03 items[Q11].report_sections', 'value': '[] (empty)'},
        'later_authority': {'artifact': 'CUST03 items[Q11].permitted_claim',
                            'status': 'NONE_UNTIL_REGISTERED_AND_OWNER_DECIDES',
                            'value': 'None in a report until the construct is registered and '
                                     'an Owner decision authorises a section'},
        'resolution': 'BLOCKED_OWNER',
        'blocking_decision': 'Owner registration and section authorization',
        'consequence': 'Q11 has no report section and cannot be charted or explained as a finding.',
    },
    {
        'conflict_id': 'CX-13', 'question_id': 'Q12', 'field': 'no_usual_trip',
        'source_a': {'artifact': 'CUST03 items[Q12].codes',
                     'value': 'WALK, MOTORCYCLE, CAR, PUBLIC_TRANSPORT, OTHER, NOT_SURE, '
                              'PREFER_NOT_TO_ANSWER — there is no "no usual trip" code'},
        'source_b': {'artifact': 'CUST03 items[Q12].option_to_state_map',
                     'value': "OTHER -> ANSWERED_NON_SUBSTANTIVE, NOT_SURE -> "
                              'ANSWERED_NON_SUBSTANTIVE, PREFER_NOT_TO_ANSWER -> REFUSED'},
        'later_authority': {'artifact': 'CUST03 items[Q12].coverage_limitation',
                            'status': 'RECORDED',
                            'value': 'OTHER has no coding scheme and is not treated as a category'},
        'resolution': 'RECORDED_NO_DEDICATED_CODE',
        'blocking_decision': 'none for presentation',
        'consequence': ('A respondent with no usual trip has no dedicated code and is recorded '
                        'as OTHER or NOT_SURE. Neither may be reported as a travel mode.'),
    },
    {
        'conflict_id': 'CX-14', 'question_id': 'Q13', 'field': 'report_authorization',
        'source_a': {'artifact': 'CUST03 items[Q13].status', 'value': 'BLOCKED_OWNER'},
        'source_b': {'artifact': 'CUST03 items[Q13].report_sections', 'value': '[] (empty)'},
        'later_authority': {'artifact': 'CUST03 items[Q13].disposition',
                            'status': 'BLOCKED_OWNER',
                            'value': 'RESTORED_FROM_ORIGINAL_AS_SEPARATE_CONSTRUCT'},
        'resolution': 'BLOCKED_OWNER',
        'blocking_decision': 'Owner decision and a final exact item definition',
        'consequence': 'Q13 is not a Q07 substitute and has no report section.',
    },
    {
        'conflict_id': 'CX-15', 'question_id': '*', 'field': 'A_definition',
        'source_a': {'artifact': 'CUST03 funnel_rules.a_definition_authority',
                     'value': 'operative P3-01C-VNEXT-0.6.1-CUST-REC; A = answer events '
                              '(ANSWERED_SUBSTANTIVE, ANSWERED_NON_SUBSTANTIVE, INVALID, '
                              'REFUSED); V = ANSWERED_SUBSTANTIVE'},
        'source_b': {'artifact': 'backend/src/sitewise/services/ee01_service.py',
                     'value': "A = sum over ('ANSWERED_SUBSTANTIVE','ANSWERED_NON_SUBSTANTIVE',"
                              "'REFUSED','INVALID'); V = ANSWERED_SUBSTANTIVE"},
        'later_authority': {'artifact': 'CUST03 funnel_rules.a_definition_authority.rule',
                            'status': 'RESOLVED_IN_IMPLEMENTATION',
                            'value': 'exactly one A-definition is operative'},
        'resolution': 'RESOLVED_ENGINE_MATCHES_CONTRACT',
        'blocking_decision': 'none',
        'consequence': 'EE-01 already implements the operative A and V definitions. No change needed.',
    },
    {
        'conflict_id': 'CX-16', 'question_id': '*', 'field': 'option_code_bank',
        'source_a': {'artifact': 'CUST03 items[*].codes'},
        'source_b': {'artifact': 'QUESTION_CONTRACT_MATRIX.json codes_and_candidate_labels '
                                 '+ handoff answer_codes'},
        'later_authority': {'artifact': 'this build (see reconciliation report §2)',
                            'status': 'VERIFIED_IDENTICAL',
                            'value': 'all 13 code banks and all 13 response types are '
                                     'identical across the three sources'},
        'resolution': 'RESOLVED_NO_CONFLICT',
        'blocking_decision': 'none',
        'consequence': ('The "old Q01 codes" warning in the handoff refers to a pre-recovery '
                        'bank that is not present in this workspace; it does not describe a '
                        'conflict between the three sources used here.'),
    },
    {
        'conflict_id': 'CX-18', 'question_id': '*', 'field': 'ordinal_scale',
        'source_a': {'artifact': 'CUST03 items[Q02, Q04, Q07, Q13].type',
                     'value': 'all four are declared ordinal_single'},
        'source_b': {'artifact': 'CUST03 items[Q02, Q04, Q07, Q13].ordinal_meaning',
                     'value': 'null for all four; only Q05 declares a scale '
                              '(DEF_NO=1 .. DEF_YES=5)'},
        'later_authority': {'artifact': 'CUST03 items[Q05].ordinal_meaning.note',
                            'status': 'RECORDED',
                            'value': '"Display order is presentation. Ordinal meaning is '
                                     'the declared mapping."'},
        'resolution': 'UNRESOLVED_SCALE_UNDECLARED',
        'blocking_decision': 'declaration of the ordinal scale for Q02, Q04, Q07, Q13',
        'consequence': ('These items are typed ordinal but carry no scale mapping, so a '
                        'chart presents ordered categories with no ordinal value and no '
                        'interval claim. Display order is never read as a scale.'),
    },
]


def cx17_label_encoding(matrix: list) -> dict:
    """The CX-17 record, derived from the current state of the label bank.

    CX-17 is a claim about the *source file*. Hardcoding it would let the registry
    keep asserting a defect after the source was repaired, or hide one that
    reappeared. Both directions are checked here, and the provenance artifact is
    named so a reader can verify the repair rather than trust this record.
    """
    defective = label_bank_defects(matrix)
    if defective:
        examples = ', '.join(repr(d['value']) for d in defective[:3])
        return {
            'conflict_id': 'CX-17', 'question_id': '*', 'field': 'label_bank_encoding',
            'source_a': {'artifact': 'QUESTION_CONTRACT_MATRIX.json '
                                     'codes_and_candidate_labels[]',
                         'value': f"{len(defective)} draft labels carry the cp1252 "
                                  f"mis-decode of an en-dash, e.g. {examples}"},
            'source_b': {'artifact': 'the same file read as UTF-8',
                         'value': 'the bytes are a cp1252 mis-decode of a UTF-8 en-dash '
                                  '(U+2013), not a wording choice'},
            'later_authority': {'artifact': 'this build (repaired on read)',
                                'status': 'REPAIRED_ON_READ_SOURCE_STILL_DEFECTIVE',
                                'value': 'labels are transcoded back to U+2013; the raw '
                                         'string is preserved per code so the defect '
                                         'stays visible'},
            'resolution': 'UNRESOLVED_SOURCE_ENCODING_DEFECT',
            'blocking_decision': 'correction of the label bank at source',
            'consequence': ('Presentation uses the recovered character, but the source '
                            'file remains defective until it is re-issued. A repaired '
                            'label is still a draft and is never presented as approved '
                            'wording.'),
        }
    return {
        'conflict_id': 'CX-17', 'question_id': '*', 'field': 'label_bank_encoding',
        'source_a': {'artifact': 'QUESTION_CONTRACT_MATRIX.json '
                                 'codes_and_candidate_labels[]',
                     'value': 'no draft label carries the cp1252 mis-decode; every label '
                              'is stored as U+2013 where a range separator is intended'},
        'source_b': {'artifact': 'the same file read as UTF-8',
                     'value': 'the bytes decode as U+2013 directly; no transcoding is '
                              'applied on read'},
        'later_authority': {'artifact': 'PROJECT1_CX17_LABEL_ENCODING_PROVENANCE.json',
                            'status': 'REPAIRED_AT_SOURCE',
                            'value': ('fifteen labels in Q02, Q04 and Q13 were repaired by '
                                      'a byte substitution of the corrupted sequence with '
                                      'U+2013; the original file and both hashes are '
                                      'preserved in the provenance artifact')},
        'resolution': 'RESOLVED_SOURCE_ENCODING_REPAIRED',
        'blocking_decision': 'none',
        'consequence': ('The character-level defect is closed: the source now stores '
                        'U+2013 and no transcoding happens on read. This does NOT approve '
                        'the wording — every repaired label is still draft option text and '
                        'is presented as a draft, never as approved wording. Approval of '
                        'the option bank remains an open gate (MISSING_APPROVED_BANK) and '
                        'is not settled by this conflict.'),
    }


def cx19_wording_encoding(matrix: list, cust: dict) -> dict:
    """CX-19 — e-acute encoding in the instrument wording, derived from the sources.

    The matrix's ``wording_source`` is a copy of the frozen CUST03 ``stem``. The
    frozen instrument encodes ``café`` correctly; the matrix copy carried the
    cp1252 mis-decode. Whether this conflict is open is decided by comparing the
    two, so the record cannot outlive the defect or hide its return.
    """
    stems = {item['id']: (item.get('stem') or '') for item in cust.get('items', [])}
    corrupted = 0
    clean = 0
    for item in matrix:
        wording = item.get('wording_source')
        if not isinstance(wording, str):
            continue
        if MOJIBAKE_E_ACUTE in wording:
            corrupted += 1
        elif MOJIBAKE_E_ACUTE not in (stems.get(item.get('question_id')) or ''):
            clean += 1

    if corrupted:
        return {
            'conflict_id': 'CX-19', 'question_id': '*', 'field': 'wording_encoding',
            'source_a': {'artifact': 'QUESTION_CONTRACT_MATRIX.json wording_source',
                         'value': f'{corrupted} wording fields carry the cp1252 '
                                  f'mis-decode of U+00E9 (e acute)'},
            'source_b': {'artifact': 'CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_'
                                     'CONTRACT.json items[*].stem',
                         'value': 'the frozen instrument encodes the same stems '
                                  'correctly'},
            'later_authority': {'artifact': 'PROJECT1_CX17_LABEL_ENCODING_PROVENANCE.json',
                                'status': 'REPAIRED_ON_READ_SOURCE_STILL_DEFECTIVE',
                                'value': 'the matrix copy is the corrupted derivative'},
            'resolution': 'UNRESOLVED_SOURCE_ENCODING_DEFECT',
            'blocking_decision': 'correction of the wording encoding at source',
            'consequence': ('Reported wording would render as mojibake. The frozen '
                            'instrument is authoritative and is not modified.'),
        }
    return {
        'conflict_id': 'CX-19', 'question_id': '*', 'field': 'wording_encoding',
        'source_a': {'artifact': 'QUESTION_CONTRACT_MATRIX.json wording_source',
                     'value': f'{clean} wording fields encode U+00E9 directly and '
                              f'match the frozen stem byte for byte'},
        'source_b': {'artifact': 'CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_'
                                 'CONTRACT.json items[*].stem',
                     'value': 'the frozen instrument encodes the same stems the same way'},
        'later_authority': {'artifact': 'PROJECT1_CX17_LABEL_ENCODING_PROVENANCE.json',
                            'status': 'REPAIRED_AT_SOURCE',
                            'value': ('twenty occurrences across eighteen wording fields '
                                      'were repaired by a byte substitution; every stem '
                                      'is now byte-identical to the frozen instrument')},
        'resolution': 'RESOLVED_SOURCE_ENCODING_REPAIRED',
        'blocking_decision': 'none',
        'consequence': ('The wording now matches the frozen instrument exactly. This is a '
                        'restoration, not a wording change: the stem text, its language '
                        'version and its candidate status are untouched.'),
    }


def conflicts_for(matrix: list, cust: dict | None = None) -> list[dict]:
    """The conflict register with CX-17 and CX-19 computed, in stable CX order."""
    computed = [cx17_label_encoding(matrix)]
    if cust is not None:
        computed.append(cx19_wording_encoding(matrix, cust))
    merged = [c for c in CONFLICTS
              if c['conflict_id'] not in {c_['conflict_id'] for c_ in computed}]
    merged += computed
    return sorted(merged, key=lambda c: c['conflict_id'])


#: Who must actually settle each conflict. Recorded explicitly rather than
#: inferred from prose, so a reconciliation can never assign itself authority.
DECISION_OWNER = {
    'CX-01': 'OWNER',
    'CX-02': 'SCIENTIFIC_AND_OWNER',
    'CX-03': 'NONE_FOR_PRESENTATION',
    'CX-04': 'SCIENTIFIC',
    'CX-05': 'SCIENTIFIC',
    'CX-06': 'SCIENTIFIC_AND_OWNER',
    'CX-07': 'OWNER',
    'CX-08': 'SCIENTIFIC_AND_OWNER',
    'CX-09': 'SCIENTIFIC_AND_OWNER',
    'CX-10': 'SCIENTIFIC',
    'CX-11': 'ENGINEERING',
    'CX-12': 'OWNER',
    'CX-13': 'NONE_FOR_PRESENTATION',
    'CX-14': 'OWNER',
    'CX-15': 'NONE',
    'CX-16': 'NONE',
    'CX-17': 'OWNER',
    'CX-18': 'SCIENTIFIC_AND_OWNER',
    'CX-19': 'OWNER',
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def digest(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=True,
                                     separators=(',', ':')).encode()).hexdigest()


def build() -> dict:
    cust = json.loads(CUST_PATH.read_text(encoding='utf-8'))
    matrix = json.loads(MATRIX_PATH.read_text(encoding='utf-8'))
    handoff = json.loads(HANDOFF_PATH.read_text(encoding='utf-8'))

    items = {i['id']: i for i in cust['items']}
    mats = {q['question_id']: q for q in matrix}
    hands = {q['question_id']: q for q in handoff['questions']}
    objectives = {o['objective_id']: o for o in OBJECTIVES}
    conflicts = conflicts_for(matrix, cust)

    questions = []
    for qid in sorted(items):
        item, mat, hand = items[qid], mats[qid], hands[qid]
        kind = RESPONSE_KIND[item['type']]
        labels = {c['source_code']: c.get('draft_en_label')
                  for c in (mat.get('codes_and_candidate_labels') or [])}
        admission = _report_admission(cust, list(hand['report_sections']))
        proximity = OBJECTIVE_PROXIMITY.get(qid, [])

        # Coverage is a property of the objective table, never of proximity. An
        # objective is covered only when an approved measure exists, and none
        # does, so this stays False without being hardcoded per item.
        covers = any(objectives[o]['covered_by_an_approved_measure'] for o in proximity)

        # A template may carry a substantive finding only when the instrument is
        # report-authorised *and* a section may render a measurement.
        usable = bool(admission['any_section_may_render_measurement']
                      and hand['source_status'] in ('AUTHORIZED', 'APPROVED'))

        entry = {
            'question_id': qid,
            'group': hand['group'],
            # --- chain link 2: question identity and version -------------------
            'instrument_version': handoff['source_version'],
            'instrument_sha256': handoff['source_sha256'],
            'instrument_status': hand['source_status'],
            'source_fingerprint': digest(item),
            # --- chain link 3: construct and response codes --------------------
            'construct_id': item['construct'],
            'construct_id_handoff': hand['construct_id'],
            'response_kind': kind,
            'instrument_type': item['type'],
            'max_selections': item.get('max_selections'),
            'exclusive_codes': list(item.get('exclusive_codes') or []),
            'codes': [
                {
                    'code': code,
                    'label_en': repair_label(labels.get(code))[0],
                    'label_raw': (labels.get(code)
                                  if repair_label(labels.get(code))[1] else None),
                    'label_repair': repair_label(labels.get(code))[1],
                    'label_source': ('CONTRACT_OPTION_BANK_DRAFT' if labels.get(code)
                                     else 'CODE_FALLBACK'),
                }
                for code in (item.get('codes') or [])
            ],
            'substantive_codes': list(item.get('substantive_codes') or []),
            'non_substantive_codes': list(item.get('non_substantive_codes') or []),
            'display_order': list(item.get('display_order') or item.get('codes') or []),
            # A code-array fallback is NOT a declared presentation order. Recording
            # the provenance stops the fallback from being read as a decision.
            'display_order_source': ('DECLARED_IN_CONTRACT' if item.get('display_order')
                                     else 'CODE_ARRAY_FALLBACK_UNDECLARED'),
            'ordinal_meaning': item.get('ordinal_meaning'),
            'ordinal_meaning_source': ('DECLARED_IN_CONTRACT'
                                       if item.get('ordinal_meaning')
                                       else 'UNDECLARED'),
            'ordinal_only_rationale': item.get('ordinal_only_rationale'),
            # --- chain link 1: research objective ------------------------------
            'research_objective': hand['objective'],
            # --- chain link 4: EE-01 measurement rule --------------------------
            'required_measurement': hand['measure'],
            'analysis_plan': hand['analysis'],
            'ee01_measurement_rule': _measurement_rule(item, kind),
            # --- chain link 5: permitted claim and its prohibitions ------------
            'permitted_claim': hand['source_permitted_claim'],
            'prohibited_inference': hand['source_forbidden_inference'],
            'coverage_limitation': hand['source_coverage_limitation'],
            'limitation': hand['limitation'],
            # --- chain link 6: the existing deterministic templates ------------
            'templates': {
                'withheld': {'template_id': f'FB-{qid}-WITHHELD', 'text': hand['fallback'],
                             'placeholders': []},
                'valid': {'template_id': f'VD-{qid}-APPROVED', 'text': hand['valid'],
                          'placeholders': sorted({p.split('}')[0]
                                                  for p in hand['valid'].split('{')[1:]})},
                'limitation': {'template_id': f'LM-{qid}-LIMIT', 'text': hand['limitation'],
                               'placeholders': []},
            },
            # --- chain link 7: report sections ---------------------------------
            'report_sections': list(hand['report_sections']),
            # --- chain link 8: ReportAdmission requirement ---------------------
            'report_admission': admission,
            # --- evidence-state resolution --------------------------------------
            'instrument_gate': ITEM_GATE_OVERRIDE.get(
                qid, STATUS_TO_GATE.get(hand['source_status'], 'NOT_AUTHORIZED')),
            'routing_resolved': qid not in UNRESOLVED_ROUTING,
            # --- authorization --------------------------------------------------
            'authorization': {
                'instrument_status': hand['source_status'],
                'report_authorized': usable,
                'basis': ('report_authorized requires an AUTHORIZED/APPROVED instrument '
                          'and at least one section that may render a measurement; '
                          'neither holds'),
                'scientific_approval': mat.get('scientific_approval'),
                'owner_authorization': mat.get('owner_authorization'),
                'fielding': mat.get('fielding'),
                'candidate_gate': mat.get('candidate_gate'),
                'authority_granted_by_this_registry': 'NONE',
            },
            'template_usable_for_substantive_report': usable,
            # --- objectives ------------------------------------------------------
            'objective_proximity': proximity,
            'covers_objective': covers,
            # --- reconciliation --------------------------------------------------
            'conflict_ids': [c['conflict_id'] for c in conflicts
                             if c['question_id'] in (qid, '*')],
            'open_decisions': sorted({c['blocking_decision'] for c in conflicts
                                      if c['question_id'] in (qid, '*')
                                      and c['blocking_decision'] != 'none'}),
        }
        questions.append(entry)

    return {
        'registry_version': REGISTRY_VERSION,
        'instrument_version': handoff['source_version'],
        'instrument_sha256': handoff['source_sha256'],
        'approval': handoff['approval'],
        'authority_granted_by_this_registry': 'NONE',
        'instrument_gates': INSTRUMENT_GATES,
        'evidence_states': EVIDENCE_STATES,
        'state_templates': STATE_TEMPLATES,
        'state_template_source': (
            'QUESTION_OBJECTIVES_AND_FALLBACKS.md, "Report fallback decision rules" '
            'table — quoted verbatim; placeholders {question_id}, {count}, {shown}, '
            '{V} are filled only from server-held EE-01 values'),
        'state_template_note': (
            'NOT_AUTHORIZED, BLOCKED_SOURCE, MISSING_APPROVED_STIMULUS and '
            'MISSING_APPROVED_BANK share one owner sentence because the handoff groups '
            'them into a single row; they remain distinct state codes so the reason is '
            'recorded even when the prose is identical.'),
        'framing': FRAMING,
        'source_artifacts': {
            'CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_CONTRACT.json': sha256(CUST_PATH),
            'QUESTION_CONTRACT_MATRIX.json': sha256(MATRIX_PATH),
            'QUESTION_OBJECTIVES_AND_FALLBACKS.json': sha256(HANDOFF_PATH),
        },
        'handoff_package_sha256': sha256(
            REPO / 'deliverables' / '_cq13_handoff'
            / 'PROJECT1_CQ13_RESEARCH_AND_QUERY_HANDOFF' / 'SHA256SUMS.txt'),
        'handoff_package_sha256_basis': 'SHA-256 of the extracted SHA256SUMS.txt manifest',
        'handoff_zip_sha256': (
            'fcc1cf0c1a1c35da1fdcfe61242b6d4abd5228dcd3c3687f381356b9c6f21478'),
        'handoff_zip_sha256_basis': ('SHA-256 of '
                                     'PROJECT1_CQ13_RESEARCH_AND_QUERY_HANDOFF_20261122.zip '
                                     '(37,735 bytes, 11 files; all 10 manifest hashes '
                                     'verified OK)'),
        'objectives': OBJECTIVES,
        'conflicts': [{**c, 'decision_owner': DECISION_OWNER[c['conflict_id']]}
                      for c in conflicts],
        'questions': questions,
    }


def receipt(registry: dict) -> dict:
    """Conflict-resolution receipt: what was decided, by whom, and what is owed.

    The receipt is a *record*, not an approval. It separates the conflicts this
    reconciliation could settle from the ones that only an owner or a scientific
    decision can settle, and it names the decision each open item waits on.
    """
    settled, open_owner, open_science, open_engineering = [], [], [], []
    for conflict in registry['conflicts']:
        resolution = conflict['resolution']
        record = {
            'conflict_id': conflict['conflict_id'],
            'question_id': conflict['question_id'],
            'field': conflict['field'],
            'resolution': resolution,
            'decision_owner': conflict['decision_owner'],
            'blocking_decision': conflict['blocking_decision'],
            'consequence': conflict['consequence'],
        }
        if resolution.startswith(('RESOLVED_', 'RECORDED_')):
            settled.append(record)
        elif conflict['decision_owner'] == 'OWNER':
            open_owner.append(record)
        elif conflict['decision_owner'] == 'SCIENTIFIC_AND_OWNER':
            open_science.append(record)
        else:
            open_engineering.append(record)

    return {
        'receipt_version': 'q01-q13-conflict-receipt/1',
        'registry_version': registry['registry_version'],
        'registry_sha256': sha256(OUT) if OUT.exists() else None,
        'authority_granted_by_this_receipt': 'NONE',
        'statement': ('This receipt records how the three available sources were reconciled. '
                      'It approves nothing, amends no instrument and settles no scientific '
                      'question. An UNRESOLVED_* resolution means the conflict is documented '
                      'and deliberately left open, not that it was decided by the '
                      'reconciliation.'),
        'counts': {
            'total': len(registry['conflicts']),
            'settled_or_recorded': len(settled),
            'open_owner_decision': len(open_owner),
            'open_scientific_and_owner_decision': len(open_science),
            'open_engineering_decision': len(open_engineering),
        },
        'settled_or_recorded': settled,
        'open_owner_decision': open_owner,
        'open_scientific_and_owner_decision': open_science,
        'open_engineering_decision': open_engineering,
        'objectives': {
            'total': len(registry['objectives']),
            'covered_by_an_approved_measure':
                sum(o['covered_by_an_approved_measure'] for o in registry['objectives']),
            'detail': registry['objectives'],
        },
        'template_availability': {
            'questions': len(registry['questions']),
            'usable_for_substantive_report':
                sum(q['template_usable_for_substantive_report']
                    for q in registry['questions']),
            'usable_question_ids': [q['question_id'] for q in registry['questions']
                                    if q['template_usable_for_substantive_report']],
        },
    }


def main() -> int:
    registry = build()
    payload = json.dumps(registry, indent=2, ensure_ascii=False) + '\n'
    for path in (RUNTIME_OUT, OUT):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(payload, encoding='utf-8')
    if RUNTIME_OUT.read_bytes() != OUT.read_bytes():
        print('runtime and published registry differ', file=sys.stderr)
        return 3
    rec = receipt(registry)
    RECEIPT.write_text(json.dumps(rec, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    print(f'wrote {RUNTIME_OUT}')
    print(f'wrote {OUT}')
    print(f'wrote {RECEIPT}')
    print(f'questions: {len(registry["questions"])}  conflicts: {len(registry["conflicts"])}')
    print(f'sha256 registry: {sha256(OUT)}')
    print(f'sha256 receipt : {sha256(RECEIPT)}')
    print('conflict counts:', rec['counts'])
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
