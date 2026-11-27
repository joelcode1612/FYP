"""Section A measurement annotations: level, analysis methods, interpretation limits.

Why this module exists
----------------------
The thirteen governed Section A questions (``governed_q01_q13_preview.json``)
already carry a construct, a response format, response codes, selection rules and
a substantive / non-substantive code split. Three attributes a measurement
specification needs are **not** in that artifact:

* the measurement level,
* the applicable analysis methods (and the analyses that are not admissible),
* the interpretation limitations.

This module supplies exactly those three, as a versioned, read-only annotation.
It changes no stem, no routing, no response code and no historical measurement
semantics, because it never writes to the governed catalogue. It is a separate
artifact bound to the catalogue by digest, the same mechanism
``measurement_estimator`` uses for a frozen ``Measurement``.

Response format is not measurement level
----------------------------------------
The catalogue's ``type`` field is a *presentation* format, and it does not
determine the level. This is not hypothetical: ``ordinal_single`` appears five
times in the same file and covers two different levels.

* Q07 ``VERY_UNACCEPTABLE … VERY_ACCEPTABLE`` is genuinely **ordinal** — the
  points are ordered and their distances are not equal.
* Q02, Q04 and Q13 are **grouped ratio**: ``ZERO / ONE / TWO_THREE /
  FOUR_SEVEN / EIGHT_PLUS`` are bins of a count, and ``LT_RM8 / RM8_TO_1199 /
  …`` are bins of a price. A count and a price have a true zero and equal units;
  only the observation is binned.

Reading ``ordinal_single`` as "ordinal" would therefore misdescribe four of the
five questions it labels, and would license the wrong analyses. The level is
recorded per question, with the basis stated, rather than derived from ``type``.

What this is not
----------------
It is **not** an approval, a scientific receipt, a fielding right or a
publication right. Every entry says so, and ``authority()`` returns that fact
rather than leaving a caller to infer it. The annotations are deterministic and
derived from the governed codes; they are candidate material for the scientific
review, not a substitute for it.
"""
from __future__ import annotations

import json
from pathlib import Path

from sitewise.project1.contracts import WorkflowHeld, digest

#: Version of this annotation contract (not of any question).
SECTION_A_MEASUREMENT_VERSION = 'P1-SECTION-A-MEASUREMENT-0.1'

NOMINAL = 'NOMINAL'
ORDINAL = 'ORDINAL'
GROUPED_RATIO = 'GROUPED_RATIO'

LEVELS = (NOMINAL, ORDINAL, GROUPED_RATIO)

#: The governed record each annotation was written against. A catalogue edit that
#: changes any of these is a change to the measurement and must be reviewed, so
#: the annotation refuses rather than silently describing a record it has not
#: seen. This is a binding check, not a cache key.
GOVERNED_DIGESTS = {
    'Q01': 'eaea44629e782d9a68f77f3bc333ab2087e908dec9b0da07d10540794555d712',
    'Q02': 'f03acb85b6f43a720037d44b2cfad5a701aa00fa6ce38e4b33a542a06ab4fd3d',
    'Q03': 'b54830754dafd1ac4d84043277d07421ec8d06eab1731150afba89d9500d9754',
    'Q04': '310d6e964852f296c5dbba4daeddf538fa0195b37108308867b56e67f4204b80',
    'Q05': '6818a74281046223da3eeddaf9dd4fecbd9feac13b7b7cb5c1f21d5e8ebd4aca',
    'Q06': 'bf324dda11b06b02e488807aab0c0a8544ebcee37316308ce9578aff45decfda',
    'Q07': 'a566e96c45febec073a046e304cb501e3b01384acec2520044089cf1ec76b417',
    'Q08': '454f3f53e87ca6d0dcb68ec046b5a23ddc14089f788ea6a0a70ef79d2f90f7f7',
    'Q09': '0924605e92bc9ac399588d72e6e3877d36b521e6de436f734169b82956a3605e',
    'Q10': 'a072d8abf7a852c82d82ee21b794a6545e388185d867f575df7ed2797a78b07c',
    'Q11': '2f559614514f87fc2f4da79c33548d3df03b37235eb87427facd7c74cc4a4ed5',
    'Q12': '75ce3e2e5530c28369753052fa653d75f9df832dfe5953013b0104500b5e3828',
    'Q13': '2d17234afabb4bb552dd4fa0dfceef6acc0995e657e4a4a4f4853bf687ac50d9',
}

#: Analyses admissible for each level, and the ones that are not. Written once per
#: level so a question cannot acquire a bespoke rule that contradicts its level.
_BY_LEVEL = {
    NOMINAL: {
        'analysis': ('frequency and proportion per code',
                     'cross-tabulation with an independence test when groups are independent'),
        'prohibited': ('arithmetic mean', 'median or any order statistic',
                       'standard deviation', 'ranking of codes'),
        'limitations': ('Codes are unordered, so no code is greater than another.',
                        'Shares describe composition only; they carry no magnitude.'),
    },
    ORDINAL: {
        'analysis': ('frequency and proportion per code',
                     'median and interquartile range',
                     'rank-based comparison between groups'),
        'prohibited': ('arithmetic mean', 'standard deviation',
                       'parametric tests that assume equal intervals'),
        'limitations': ('Adjacent points are ordered but not equally spaced, so a '
                        'difference between two points has no common unit.',
                        'The median is the appropriate centre; the mean would imply '
                        'a distance the scale does not define.'),
    },
    GROUPED_RATIO: {
        'analysis': ('frequency and proportion per band',
                     'median band and cumulative distribution across bands'),
        'prohibited': ('arithmetic mean over band labels',
                       'any statistic requiring values inside a band',
                       'parametric inference that assumes equal spacing between bands'),
        'limitations': ('The underlying quantity has a true zero and equal units, but '
                        'only bands were observed, so within-band variation is lost.',
                        'A mean is admissible only if band midpoints are adopted as an '
                        'explicit, disclosed convention; it is not derivable from the codes.'),
    },
}

#: Per-question annotations. ``level_basis`` states why the level is what it is,
#: in terms of the governed codes, so the judgement can be checked rather than
#: trusted.
_ANNOTATIONS = {
    'Q01': {
        'level': NOMINAL,
        'level_basis': 'Affiliation categories (LIVE, WORK, STUDY, …) have no order.',
        'extra_prohibited': (),
        'extra_limitations': (
            'RARELY, NEVER and NOT_SURE are exclusive terminals: a respondent who '
            'selects one selects no affiliation, so affiliation shares need not sum to 100%.',
        ),
    },
    'Q02': {
        'level': GROUPED_RATIO,
        'level_basis': ('Days present in the last four weeks are a count; NONE / '
                        'DAYS_1_3 / DAYS_4_10 / DAYS_11_20 / DAYS_GT_20 are bins of it.'),
        'extra_prohibited': (),
        'extra_limitations': (
            'DAYS_GT_20 is open-ended, so the upper tail is unbounded and a mean '
            'would understate it.',
        ),
    },
    'Q03': {
        'level': NOMINAL,
        'level_basis': 'Origin types are unordered categories.',
        'extra_prohibited': (),
        'extra_limitations': (),
    },
    'Q04': {
        'level': GROUPED_RATIO,
        'level_basis': ('Purchase occasions in the past 30 days are a count; ZERO / ONE / '
                        'TWO_THREE / FOUR_SEVEN / EIGHT_PLUS are bins of it.'),
        'extra_prohibited': (),
        'extra_limitations': (
            'EIGHT_PLUS is open-ended, so the upper tail is unbounded and a mean '
            'would understate it.',
        ),
    },
    'Q05': {
        'level': ORDINAL,
        'level_basis': ('DEF_NO … DEF_YES is a five-point ordered likelihood scale '
                        'with UNSURE as its midpoint, not a measured quantity.'),
        'extra_prohibited': (),
        'extra_limitations': (
            'UNSURE is a substantive midpoint, not nonresponse: excluding it would '
            'shift the distribution toward a decision the respondent did not give.',
        ),
    },
    'Q06': {
        'level': NOMINAL,
        'level_basis': 'Menu categories are unordered; selection is multiple.',
        'extra_prohibited': (),
        'extra_limitations': (
            'NONE is logically exclusive with the category codes even though it is '
            'classified substantive, so a category share and the NONE share are not '
            'independent.',
            'UNLISTED_CATEGORY_REPORTED is a residual, so the closed list understates '
            'demand for categories it does not name.',
        ),
    },
    'Q07': {
        'level': ORDINAL,
        'level_basis': ('VERY_UNACCEPTABLE … VERY_ACCEPTABLE is a five-point ordered '
                        'acceptability scale with NEITHER as its midpoint.'),
        'extra_prohibited': (),
        'extra_limitations': (
            'Acceptability is not willingness to pay: a favourable rating does not '
            'establish that the stated price would be paid.',
        ),
    },
    'Q08': {
        'level': NOMINAL,
        'level_basis': 'Occasion types are unordered; selection is multiple.',
        'extra_prohibited': (),
        'extra_limitations': (
            'Shares are of respondents, not of occasions: a respondent selecting three '
            'occasions contributes once to each, so the shares do not sum to 100%.',
        ),
    },
    'Q09': {
        'level': NOMINAL,
        'level_basis': 'Planned occasion types are unordered; selection is multiple.',
        'extra_prohibited': (),
        'extra_limitations': (
            'A stated plan is an intention, not an observed visit; it is not a forecast '
            'of behaviour without a separate conversion assumption.',
        ),
    },
    'Q10': {
        'level': ORDINAL,
        'level_basis': ('NOT_AT_ALL_IMPORTANT … EXTREMELY_IMPORTANT is a five-point '
                        'ordered importance scale, rated per feature.'),
        'extra_prohibited': (
            'averaging across features into a single score without an adopted scale',
        ),
        'extra_limitations': (
            'Each row is its own ordinal item; a composite importance score would '
            'require a validated scale, which this instrument does not establish.',
            'NOT_APPLICABLE is nonresponse, not "unimportant".',
        ),
    },
    'Q11': {
        'level': NOMINAL,
        'level_basis': 'Service formats are unordered alternatives.',
        'extra_prohibited': (),
        'extra_limitations': (
            'A forced single choice among formats cannot show how formats would trade '
            'off against each other if more than one were offered.',
        ),
    },
    'Q12': {
        'level': NOMINAL,
        'level_basis': 'Transport modes are unordered categories.',
        'extra_prohibited': (),
        'extra_limitations': (
            'OTHER is classified non-substantive, so modes outside the closed list are '
            'excluded from the distribution rather than reported as a residual share.',
        ),
    },
    'Q13': {
        'level': GROUPED_RATIO,
        'level_basis': ('An expected price is a monetary quantity; LT_RM8 / RM8_TO_1199 / '
                        '… are bins of it.'),
        'extra_prohibited': (),
        'extra_limitations': (
            'GE_RM18 is open-ended, so the upper tail is unbounded and a mean would '
            'understate it.',
            'An expected price is not a willingness to pay and is not evidence that the '
            'price would be accepted.',
        ),
    },
}


def _denominator_rule(record: dict) -> dict:
    """State the denominator from the record's own code split.

    The split already exists in the governed artifact, so it is read rather than
    restated: a copied list would drift from the codes it describes.
    """
    substantive = list(record.get('substantive_codes') or [])
    non_substantive = list(record.get('non_substantive_codes') or [])
    return {
        'basis': 'respondents whose answer is one of the substantive codes',
        'substantive_codes': substantive,
        'excluded_codes': non_substantive,
        'rule': ('A response outside the substantive codes is reported separately and '
                 'counted in neither the numerator nor the denominator.'),
    }


def authority() -> dict:
    """What this annotation is entitled to assert: nothing beyond description."""
    return {
        'scientifically_approved': False,
        'fielding_authorized': False,
        'publication_authorized': False,
        'report_release_authorized': False,
        'annotation_authority': 'DERIVED_DESCRIPTION_ONLY',
    }


def annotate(record: dict) -> dict:
    """Return the measurement annotation for one governed question record.

    Refuses when the record is not the one the annotation was written for. A
    changed record may carry a changed code list, and an annotation that silently
    described it anyway would assert a level for codes it has never seen.
    """
    question_id = record.get('question_id')
    if question_id not in _ANNOTATIONS:
        raise WorkflowHeld('SECTION_A_MEASUREMENT_UNKNOWN_QUESTION')
    if digest(record) != GOVERNED_DIGESTS[question_id]:
        raise WorkflowHeld('SECTION_A_MEASUREMENT_DIGEST_MISMATCH')

    entry = _ANNOTATIONS[question_id]
    level = entry['level']
    if level not in LEVELS:
        # A level outside the vocabulary would make the analysis rules below
        # silently inapplicable, so it is refused rather than passed through.
        raise WorkflowHeld('SECTION_A_MEASUREMENT_LEVEL_INVALID')

    rules = _BY_LEVEL[level]
    return {
        'annotation_contract_version': SECTION_A_MEASUREMENT_VERSION,
        'question_id': question_id,
        'governed_digest': GOVERNED_DIGESTS[question_id],
        'construct': record.get('construct'),
        'response_format': record.get('type'),
        'measurement_level': level,
        'level_basis': entry['level_basis'],
        # Stated explicitly so a reader cannot mistake format for level.
        'level_is_derived_from_format': False,
        'analysis_methods': list(rules['analysis']),
        'prohibited_analyses': list(rules['prohibited']) + list(entry['extra_prohibited']),
        'denominator': _denominator_rule(record),
        'interpretation_limitations': (list(rules['limitations'])
                                       + list(entry['extra_limitations'])),
        'authority': authority(),
    }


def annotations_for(path: str | Path | None = None) -> list[dict]:
    """Annotate the whole governed catalogue, in file order.

    Read-only: the catalogue is loaded and never written.
    """
    catalogue = (Path(path) if path is not None
                 else Path(__file__).resolve().parents[1]
                 / 'cq_successor' / 'data' / 'governed_q01_q13_preview.json')
    payload = json.loads(catalogue.read_text(encoding='utf-8'))
    records = payload.get('questions') or []
    annotated = [annotate(record) for record in records]
    ids = [item['question_id'] for item in annotated]
    if ids != list(GOVERNED_DIGESTS):
        # Order and completeness are part of the binding: a missing or reordered
        # question means this annotation no longer describes the questionnaire.
        raise WorkflowHeld('SECTION_A_MEASUREMENT_CATALOGUE_MISMATCH')
    return annotated


__all__ = ['SECTION_A_MEASUREMENT_VERSION', 'LEVELS', 'NOMINAL', 'ORDINAL',
           'GROUPED_RATIO', 'GOVERNED_DIGESTS', 'authority', 'annotate',
           'annotations_for']
