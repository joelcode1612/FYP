"""Candidate English display labels for the governed Q01-Q13 option codes.

Status
------
``CANDIDATE_SYNTHETIC_TEST_ONLY``. The owner authorised these mappings on
2026-11-25 as respondent-facing wording **for controlled synthetic technical
testing**, explicitly *not* as scientifically approved production wording. Nothing
here grants fielding, publication or report-release authority.

What is preserved, absolutely
-----------------------------
No internal code is renamed, added or removed; no response category is
introduced or dropped; no routing rule and no measurement definition changes.
The mapping is a ``code -> English text`` table and nothing else. Coverage is
asserted to equal the governed code set exactly, so a typo that drops a code
fails loudly instead of silently shrinking the questionnaire.

Provenance, per code
--------------------
``GOVERNED``
    The label is read verbatim from a governed artifact. Only Q02 qualifies:
    ``candidate_c0c1_v1.json`` ``q02_distinct_day_labels``.
``DOCUMENTED``
    The code is a standard instrument literal whose meaning is fixed by its own
    construct and the wording of the stem (``PREFER_NOT_TO_ANSWER``,
    ``CANNOT_JUDGE``, ``DINE_IN``...). The text is a rendering of that literal.
``REVIEW``
    The code encodes a *band* or an ambiguous scope, so its meaning depends on a
    reading of the band rather than on the literal. These are listed in
    ``REVIEW_REQUIRED`` for the owner and must not be treated as settled.

The band codes in Q13 are the only genuinely load-bearing case: ``RM8_TO_1199``
can be read as "RM 8 to RM 11.99" (a price band) or as a malformed "8 to 1199".
The ladder is consistent with the former, and Q04's ``TWO_THREE``/``FOUR_SEVEN``
follow the same convention, so the mapping adopts the band reading and flags it.
"""
from __future__ import annotations

import hashlib
import json

CONTRACT_VERSION = 'cq-option-labels/1'
STATUS = 'CANDIDATE_SYNTHETIC_TEST_ONLY'
LOCALE = 'EN'

#: Read verbatim from ``candidate_c0c1_v1.json`` -> ``q02_distinct_day_labels``.
_GOVERNED_Q02 = {
    'NONE': '0 days',
    'DAYS_1_3': '1–3 days',
    'DAYS_4_10': '4–10 days',
    'DAYS_11_20': '11–20 days',
    'DAYS_GT_20': '21–28 days',
    'PREFER_NOT_TO_ANSWER': 'Prefer not to answer',
}

_SHARED = {
    'PREFER_NOT_TO_ANSWER': 'Prefer not to answer',
    'CANNOT_JUDGE': 'Cannot judge',
    'NOT_SURE': 'Not sure',
    'NONE': 'None of these',
}

LABELS: dict[str, dict[str, str]] = {
    'Q01': {
        'LIVE': 'I live here',
        'WORK': 'I work here',
        'STUDY': 'I study here',
        'RUN_BUSINESS': 'I run a business here',
        'VISIT_PURPOSE': 'I visit for a specific purpose',
        'PASS_THROUGH': 'I pass through on the way elsewhere',
        'RARELY': 'Rarely',
        'NEVER': 'Never',
        'NOT_SURE': 'Not sure',
    },
    'Q02': dict(_GOVERNED_Q02),
    'Q03': {
        'HOME': 'From home',
        'WORKPLACE': 'From my workplace',
        'STUDY_LOCATION': 'From my place of study',
        'OTHER_ACTIVITY': 'From another activity',
        'VARIES': 'It varies',
        'DECLINE': 'Prefer not to say',
        'NOT_SURE': 'Not sure',
    },
    'Q04': {
        'ZERO': 'None',
        'ONE': 'Once',
        'TWO_THREE': '2–3 times',
        'FOUR_SEVEN': '4–7 times',
        'EIGHT_PLUS': '8 or more times',
        'CANNOT_REMEMBER': 'Cannot remember',
        'PREFER_NOT_TO_ANSWER': 'Prefer not to answer',
    },
    'Q05': {
        'DEF_NO': 'Definitely would not',
        'PROB_NO': 'Probably would not',
        'UNSURE': 'Unsure',
        'PROB_YES': 'Probably would',
        'DEF_YES': 'Definitely would',
        'CANNOT_JUDGE': 'Cannot judge',
        'PREFER_NOT_TO_ANSWER': 'Prefer not to answer',
    },
    'Q06': {
        'COFFEE_ESPRESSO': 'Espresso-based coffee',
        'NON_COFFEE': 'Non-coffee drinks',
        'BAKED_PASTRY': 'Baked goods and pastries',
        'LIGHT_MEALS': 'Light meals',
        'DESSERTS': 'Desserts',
        'RETAIL': 'Retail items to take home',
        'UNLISTED_CATEGORY_REPORTED': 'A category not listed here',
        'NONE': 'None of these',
        'NOT_SURE': 'Not sure',
        'PREFER_NOT_TO_ANSWER': 'Prefer not to answer',
    },
    'Q07': {
        'VERY_UNACCEPTABLE': 'Very unacceptable',
        'SOMEWHAT_UNACCEPTABLE': 'Somewhat unacceptable',
        'NEITHER': 'Neither acceptable nor unacceptable',
        'SOMEWHAT_ACCEPTABLE': 'Somewhat acceptable',
        'VERY_ACCEPTABLE': 'Very acceptable',
        'CANNOT_JUDGE': 'Cannot judge',
        'PREFER_NOT_TO_ANSWER': 'Prefer not to answer',
    },
    'Q08': {
        'WORK_BREAK': 'A break from work',
        'STUDY': 'A break from study',
        'SOCIAL': 'Meeting other people',
        'ON_THE_GO': 'On the way somewhere',
        'UNLISTED_OCCASION_REPORTED': 'An occasion not listed here',
        'CANNOT_REMEMBER': 'Cannot remember',
        'PREFER_NOT_TO_ANSWER': 'Prefer not to answer',
    },
    'Q09': {
        'WORK_BREAK': 'A break from work',
        'STUDY': 'A break from study',
        'SOCIAL': 'Meeting other people',
        'ON_THE_GO': 'On the way somewhere',
        'UNLISTED_OCCASION_REPORTED': 'An occasion not listed here',
        'NONE': 'None of these',
        'CANNOT_JUDGE': 'Cannot judge',
        'PREFER_NOT_TO_ANSWER': 'Prefer not to answer',
    },
    'Q10': {
        'NOT_AT_ALL_IMPORTANT': 'Not at all important',
        'SLIGHTLY_IMPORTANT': 'Slightly important',
        'MODERATELY_IMPORTANT': 'Moderately important',
        'VERY_IMPORTANT': 'Very important',
        'EXTREMELY_IMPORTANT': 'Extremely important',
        'NOT_APPLICABLE': 'Not applicable to me',
        'CANNOT_JUDGE': 'Cannot judge',
        'PREFER_NOT_TO_ANSWER': 'Prefer not to answer',
    },
    'Q11': {
        'DINE_IN': 'Eat and drink in',
        'TAKEAWAY': 'Take away',
        'EITHER_EQUALLY': 'Either, equally',
        'CANNOT_JUDGE': 'Cannot judge',
        'PREFER_NOT_TO_ANSWER': 'Prefer not to answer',
    },
    'Q12': {
        'WALK': 'Walk',
        'MOTORCYCLE': 'Motorcycle',
        'CAR': 'Car',
        'PUBLIC_TRANSPORT': 'Public transport',
        'OTHER': 'Other',
        'NOT_SURE': 'Not sure',
        'PREFER_NOT_TO_ANSWER': 'Prefer not to answer',
    },
    'Q13': {
        'LT_RM8': 'Less than RM 8',
        'RM8_TO_1199': 'RM 8 to RM 11.99',
        'RM12_TO_1499': 'RM 12 to RM 14.99',
        'RM15_TO_1799': 'RM 15 to RM 17.99',
        'GE_RM18': 'RM 18 or more',
        'NOT_SURE': 'Not sure',
        'PREFER_NOT_TO_ANSWER': 'Prefer not to answer',
    },
}

#: Codes whose reading is a convention rather than a governed string.
REVIEW_REQUIRED: list[dict[str, str]] = [
    {'question_id': 'Q13', 'code': 'RM8_TO_1199',
     'reason': 'Band or malformed literal. Read as RM 8.00-11.99; '
               'the RM12/RM15/GE18 ladder is contiguous only on that reading.'},
    {'question_id': 'Q13', 'code': 'RM12_TO_1499',
     'reason': 'Band literal; read as RM 12.00-14.99.'},
    {'question_id': 'Q13', 'code': 'RM15_TO_1799',
     'reason': 'Band literal; read as RM 15.00-17.99.'},
    {'question_id': 'Q04', 'code': 'TWO_THREE',
     'reason': 'Count band; read as 2-3 occasions.'},
    {'question_id': 'Q04', 'code': 'FOUR_SEVEN',
     'reason': 'Count band; read as 4-7 occasions.'},
    {'question_id': 'Q06', 'code': 'RETAIL',
     'reason': '"Retail" scope is not defined in the frozen contract; '
               'read as packaged goods to take home.'},
    {'question_id': 'Q03', 'code': 'VARIES',
     'reason': '"Varies" does not name a journey origin.'},
]


def provenance(question_id: str, code: str) -> str:
    if question_id == 'Q02' and code in _GOVERNED_Q02:
        return 'GOVERNED'
    if any(r['question_id'] == question_id and r['code'] == code
           for r in REVIEW_REQUIRED):
        return 'REVIEW'
    return 'DOCUMENTED'


def labels_for(question_id: str, codes: list[str]) -> dict[str, str]:
    """The label map for one question, requiring exact code coverage.

    A missing code raises rather than being dropped: a shortened map would still
    satisfy the key-set test in ``verify_release`` only by accident.
    """
    table = LABELS.get(question_id)
    if table is None:
        raise KeyError(f'no label mapping for {question_id}')
    missing = [c for c in codes if c not in table]
    extra = [c for c in table if c not in codes]
    if missing or extra:
        raise ValueError(
            f'{question_id} label coverage mismatch: missing={missing} extra={extra}')
    return {c: table[c] for c in codes}


def canonical() -> dict:
    """The exact document that is fingerprinted."""
    return {
        'contract_version': CONTRACT_VERSION,
        'status': STATUS,
        'locale': LOCALE,
        'labels': {qid: {c: table[c] for c in sorted(table)}
                   for qid, table in sorted(LABELS.items())},
        'review_required': sorted(REVIEW_REQUIRED,
                                  key=lambda r: (r['question_id'], r['code'])),
    }


def fingerprint() -> str:
    """sha256 over the canonical mapping, so drift is detectable and pinnable."""
    payload = json.dumps(canonical(), sort_keys=True, ensure_ascii=False,
                         separators=(',', ':'))
    return hashlib.sha256(payload.encode('utf-8')).hexdigest()


__all__ = [
    'CONTRACT_VERSION', 'LABELS', 'LOCALE', 'REVIEW_REQUIRED', 'STATUS',
    'canonical', 'fingerprint', 'labels_for', 'provenance',
]
