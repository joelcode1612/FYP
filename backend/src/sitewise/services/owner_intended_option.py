"""Owner-intended option policy for additional research questions.

What this is
------------
When an additional question is approved for review, the owner may record which
option they *expect* respondents to choose. That record is entrepreneur-only
metadata. It is not a respondent answer, it is never written to a
customer-response table, and it must never be preselected in a respondent-facing
questionnaire or read by an EE-01 customer measurement.

Why a policy table instead of "always require a selection"
----------------------------------------------------------
The requirement is not "every question has an intended answer". It is "the
contract correctly represents the requirement, and the constraint is respected".
Those differ by response format:

====================================  ==============  =========  ============
response format                       applicable      max values  mandatory
====================================  ==============  =========  ============
``SINGLE_SELECT`` / ``*_single``      yes             1          no
``MULTI_SELECT`` / ``multi_select``   yes             see below  no
``numeric``                           **no**          0          no
unknown / missing                     **no**          0          no
====================================  ==============  =========  ============

Nothing is mandatory. Forcing an intended answer where the measurement contract
does not ask for one would fabricate an expectation the owner never formed.

The multi-select limitation, stated plainly
-------------------------------------------
``public.m2_qg_candidate_reviews.expected_option_code`` is a single ``text``
column, so the storage can hold **one** intended option. A multi-select question
whose measurement permits several selections therefore cannot fully represent
the owner's intent. Rather than silently truncate an intent to its first value,
the policy reports ``supports_multiple_values=False`` so every caller can see the
capability, and the API refuses a second distinct value instead of overwriting
the first. Widening this needs a schema change and is tracked as DD-031.
"""
from __future__ import annotations

from typing import Mapping

#: Not applicable: the response format has no option set to choose from.
NOT_APPLICABLE = 'NOT_APPLICABLE'
SINGLE = 'SINGLE'
MULTI = 'MULTI'

#: The persisted vocabulary, taken from
#: ``m2_qg_candidates_response_format_check``. This is the authority: a format
#: outside this list cannot be stored, so it cannot reach this module from the
#: database. The older snake_case names are accepted as aliases because the
#: Stage 4 frontend still speaks them.
_SINGLE_FORMATS = frozenset({
    'SINGLE_CHOICE', 'BINARY_CHOICE', 'ORDERED_SCALE', 'NUMERIC_RANGE_OPTIONS',
    'SINGLE_SELECT', 'SINGLE', 'nominal_single', 'ordinal_single', 'ORDINAL_SINGLE',
})
_MULTI_FORMATS = frozenset({'MULTIPLE_CHOICE', 'MULTI_SELECT', 'MULTI', 'multi_select'})

#: Every format this module can classify. Anything outside it is treated as not
#: applicable rather than guessed into single-select.
KNOWN_FORMATS = _SINGLE_FORMATS | _MULTI_FORMATS

#: Refusal codes. Named so a caller branches on the reason, not on a string.
CODE_OPTION_NOT_AVAILABLE = 'QG_CANDIDATE_OPTION_NOT_AVAILABLE'
CODE_NOT_APPLICABLE = 'EXPECTED_ANSWER_NOT_APPLICABLE'
CODE_MULTI_VALUE_UNSUPPORTED = 'EXPECTED_ANSWER_MULTI_VALUE_UNSUPPORTED'
CODE_STALE_CANDIDATE = 'QG_CANDIDATE_REVISION_STALE'


class OwnerIntendedOptionError(Exception):
    """Raised with a stable code when a selection cannot be represented."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def policy_for(response_format: object) -> dict:
    """Classify one response format.

    Returns ``applicable``, ``selection``, ``max_values``, ``mandatory`` and
    ``supports_multiple_values``. The last is a *storage* capability, not a
    measurement rule: it is False for every format because the current column
    holds a single code.
    """
    fmt = str(response_format or '')
    if fmt in _SINGLE_FORMATS:
        return {
            'response_format': fmt,
            'applicable': True,
            'selection': SINGLE,
            'max_values': 1,
            'mandatory': False,
            'supports_multiple_values': False,
        }
    if fmt in _MULTI_FORMATS:
        return {
            'response_format': fmt,
            'applicable': True,
            'selection': MULTI,
            # The measurement may allow more, but this storage holds one.
            'max_values': 1,
            'mandatory': False,
            'supports_multiple_values': False,
            'limitation': (
                'The measurement permits multiple selections but the persisted '
                'contract holds a single code; one intended option is the most '
                'this record can state (DD-031).'
            ),
        }
    return {
        'response_format': fmt,
        'applicable': False,
        'selection': NOT_APPLICABLE,
        'max_values': 0,
        'mandatory': False,
        'supports_multiple_values': False,
        'limitation': 'This response format has no option set to select from.',
    }


def validate_selection(*, response_format: object, option_codes,
                       selected: str | None) -> dict:
    """Check one intended-option selection against its candidate.

    ``option_codes`` must be the codes of the **current** candidate version; the
    caller reads them from the same row it is about to write against, so a
    selection can never be validated against a stale option set.

    ``selected=None`` clears the record and is always allowed: clearing is how an
    owner withdraws an expectation, and it is not a selection.
    """
    policy = policy_for(response_format)
    if selected is None:
        return {'policy': policy, 'cleared': True}

    if not policy['applicable']:
        raise OwnerIntendedOptionError(CODE_NOT_APPLICABLE)

    allowed = {str(code) for code in (option_codes or ())}
    if not allowed:
        # No option set at all: nothing can be selected, and guessing is worse
        # than refusing.
        raise OwnerIntendedOptionError(CODE_OPTION_NOT_AVAILABLE)
    if str(selected) not in allowed:
        raise OwnerIntendedOptionError(CODE_OPTION_NOT_AVAILABLE)

    return {'policy': policy, 'cleared': False, 'selected': str(selected)}


def is_respondent_visible(_metadata: Mapping | None = None) -> bool:
    """Owner-intended options are never respondent-visible.

    A function rather than a constant so the answer cannot be changed by editing
    one literal in a payload; any caller that needs it gets the same False.
    """
    return False


__all__ = [
    'CODE_MULTI_VALUE_UNSUPPORTED',
    'CODE_NOT_APPLICABLE',
    'CODE_OPTION_NOT_AVAILABLE',
    'CODE_STALE_CANDIDATE',
    'KNOWN_FORMATS',
    'MULTI',
    'NOT_APPLICABLE',
    'OwnerIntendedOptionError',
    'SINGLE',
    'is_respondent_visible',
    'policy_for',
    'validate_selection',
]
