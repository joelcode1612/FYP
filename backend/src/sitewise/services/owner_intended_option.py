"""Owner-intended option policy for additional research questions.

What this is
------------
When an additional (Section B) question is approved for review, the owner records
which option or options they expect respondents to choose. That record is
entrepreneur-only metadata: it is not a respondent answer, it is never written to
a customer-response table, it is never read by a CQ or EE-01 calculation, and it
must never be preselected in, or disclosed by, a respondent-facing questionnaire.

Why it is mandatory
-------------------
An approval and an intention are one act. The intention exists so the report
generator can later compare what the entrepreneur expected with what customers
actually chose; an approved question without one is a question whose comparison
can never be computed, and the omission is invisible afterwards — the record
looks complete and is not. So the requirement is enforced at three layers:

* the write path refuses an approval with no valid selection (this module);
* the review table refuses the row at all, by trigger, so the guarantee is about
  the data rather than about one code path (migration ``20261125_07``);
* composition refuses to publish an approved question that carries none
  (``questionnaire_composition.classify_candidate``).

Why the number of values varies
-------------------------------
The intention must be answerable in the same shape as the question. A
``SINGLE_CHOICE`` question takes exactly one option; a ``MULTIPLE_CHOICE``
question takes between its own ``min_selections`` and ``max_selections``. Asking
for one value on a multi-select question would record an intention the
respondent is not being asked for.

The multi-value history
-----------------------
``m2_qg_candidate_reviews.expected_option_code`` holds one code, and DD-031
recorded that a multi-select intention therefore could not be represented. That
limitation is now removed: ``expected_option_codes`` (migration ``20261125_07``)
holds the selection as a set, and the singular column is kept in step for
single-selection formats so existing readers keep working.
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
#: Kept for callers that branch on it. No longer raised: the storage can now
#: represent a set, so a second value is a cardinality question, not a
#: capability refusal.
CODE_MULTI_VALUE_UNSUPPORTED = 'EXPECTED_ANSWER_MULTI_VALUE_UNSUPPORTED'
CODE_STALE_CANDIDATE = 'QG_CANDIDATE_REVISION_STALE'
CODE_INTENTION_REQUIRED = 'QG_OWNER_INTENTION_REQUIRED'
#: DD-171, owner decision 2026-11-26: clearing the intended option is refused
#: while the question remains approved. Distinct from ``CODE_INTENTION_REQUIRED``
#: because the two describe different situations — one is "you cannot approve
#: without an intention", the other is "this question is already approved, so its
#: intention stays". A caller that needs to tell an owner which of the two
#: happened cannot do that from one code.
CODE_LOCKED_BY_APPROVAL = 'QG_OWNER_INTENTION_LOCKED_BY_APPROVAL'
CODE_CARDINALITY = 'QG_OWNER_INTENTION_CARDINALITY'
CODE_DUPLICATE = 'QG_OWNER_INTENTION_DUPLICATE'
CODE_EXCLUSIVE_VIOLATED = 'QG_OWNER_INTENTION_EXCLUSIVE_VIOLATED'


class OwnerIntendedOptionError(Exception):
    """Raised with a stable code when a selection cannot be represented."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def policy_for(response_format: object, *, min_selections: object = None,
               max_selections: object = None) -> dict:
    """Classify one response format, and how many values an intention may hold.

    ``min_selections``/``max_selections`` come from the candidate's own
    ``fixed_measurement``. They are read from the row being written, never from
    the request, so an intention cannot widen the question's own constraints.
    """
    fmt = str(response_format or '')
    if fmt in _SINGLE_FORMATS:
        return {
            'response_format': fmt,
            'applicable': True,
            'selection': SINGLE,
            'min_values': 1,
            'max_values': 1,
            'mandatory': True,
            'supports_multiple_values': True,
        }
    if fmt in _MULTI_FORMATS:
        low = 1 if min_selections is None else int(min_selections)
        high = 1 if max_selections is None else int(max_selections)
        return {
            'response_format': fmt,
            'applicable': True,
            'selection': MULTI,
            'min_values': low,
            'max_values': high,
            'mandatory': True,
            'supports_multiple_values': True,
        }
    return {
        'response_format': fmt,
        'applicable': False,
        'selection': NOT_APPLICABLE,
        'min_values': 0,
        'max_values': 0,
        'mandatory': False,
        'supports_multiple_values': True,
        'limitation': 'This response format has no option set to select from.',
    }


def validate_selection_set(*, response_format: object, option_codes,
                           selected, min_selections: object = None,
                           max_selections: object = None,
                           exclusive_codes=(), required: bool = True) -> dict:
    """Check an intended-option selection against its candidate.

    ``option_codes`` must be the codes of the **current** candidate version; the
    caller reads them from the same row it is about to write against, so a
    selection can never be validated against a stale option set.

    ``selected`` is a sequence of codes, or ``None``. ``None`` clears the record:
    clearing is how an owner withdraws an intention before deciding, and it is
    not a selection. It is refused when ``required`` is true, because an
    approval must carry one.
    """
    policy = policy_for(response_format, min_selections=min_selections,
                        max_selections=max_selections)

    chosen = [] if selected is None else [str(code) for code in selected]

    if not chosen:
        if required:
            raise OwnerIntendedOptionError(CODE_INTENTION_REQUIRED)
        return {'policy': policy, 'cleared': True, 'selected': []}

    if not policy['applicable']:
        raise OwnerIntendedOptionError(CODE_NOT_APPLICABLE)

    allowed = {str(code) for code in (option_codes or ())}
    if not allowed:
        # No option set at all: nothing can be selected, and guessing is worse
        # than refusing.
        raise OwnerIntendedOptionError(CODE_OPTION_NOT_AVAILABLE)
    unknown = [code for code in chosen if code not in allowed]
    if unknown:
        raise OwnerIntendedOptionError(CODE_OPTION_NOT_AVAILABLE)

    if len(set(chosen)) != len(chosen):
        raise OwnerIntendedOptionError(CODE_DUPLICATE)

    if not (policy['min_values'] <= len(chosen) <= policy['max_values']):
        raise OwnerIntendedOptionError(CODE_CARDINALITY)

    exclusive = set(chosen) & {str(code) for code in (exclusive_codes or ())}
    if exclusive and len(chosen) > 1:
        # "None of these" plus another option is a contradiction, not a
        # preference, and storing it would make the later comparison meaningless.
        raise OwnerIntendedOptionError(CODE_EXCLUSIVE_VIOLATED)

    return {'policy': policy, 'cleared': False, 'selected': chosen}


def validate_selection(*, response_format: object, option_codes,
                       selected: str | None, **kwargs) -> dict:
    """Single-value form of :func:`validate_selection_set`.

    Kept because existing callers and tests speak one code. It forwards to the
    set form so the two can never diverge in what they accept.
    """
    return validate_selection_set(
        response_format=response_format, option_codes=option_codes,
        selected=None if selected is None else [selected], **kwargs)


def is_respondent_visible(_metadata: Mapping | None = None) -> bool:
    """Owner-intended options are never respondent-visible.

    A function rather than a constant so the answer cannot be changed by editing
    one literal in a payload; any caller that needs it gets the same False.
    """
    return False


__all__ = [
    'CODE_CARDINALITY',
    'CODE_DUPLICATE',
    'CODE_EXCLUSIVE_VIOLATED',
    'CODE_INTENTION_REQUIRED',
    'CODE_LOCKED_BY_APPROVAL',
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
    'validate_selection_set',
]
