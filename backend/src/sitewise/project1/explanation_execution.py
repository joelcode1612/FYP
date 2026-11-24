"""Governed EXPLANATION execution: preflight, dispatch, V01–V09, fallback.

What this module is for
-----------------------
``Ee01ExplanationService`` renders a candidate and refuses to touch any store. That
is the right posture for a renderer, and it left three things unimplemented:

* nothing bound an AI candidate to the ledger's ``EXPLANATION`` stage, so an
  authorised cloud call would have produced no attempt row;
* the V01–V09 categories in the directive were only partly expressible through
  ``validate_candidate``, with V03, V06 and V08 having no check at all;
* the failure/fallback table had no representation, so "provider timed out with an
  unknown outcome" was indistinguishable from "the model returned rubbish".

This module adds exactly those three things and nothing else. It does not
re-render prose, does not compute a measurement and does not decide admission.

Two things it deliberately does not do
--------------------------------------
**It does not invent an AI run.** A deterministic explanation is the authoritative
baseline and is audited as such. When no dispatch occurs, no attempt row, no
receipt and no provider identity is fabricated; the record says
``execution_kind='DETERMINISTIC_ONLY'``.

**It does not retry an unknown outcome.** ``E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN``
and ``E_PROVIDER_RESPONSE_DECODE_OUTCOME_UNKNOWN`` mean the provider may have run
and may have billed. The outcome is recorded as unresolved and the caller is told
``retry_authorized=False``. Treating that as a definite failure would both
misreport the ledger and invite a double charge.

Prompt binding
--------------
``prompts.PROMPTS['EXPLANATION']`` is version ``EE01-EXPLANATION-1-CAND`` while
``disclosure.EXPLANATION_PROMPT_VERSION`` is ``EE01-EXPLANATION-2-CAND``, and
``validate_synthetic`` never compares the dispatched prompt's version to the
authorisation's. Dispatching the registered prompt would therefore write
``1-CAND`` into ``project1_ai.attempts.prompt_version`` under a ``2-CAND``
authorisation — an audit trail naming a prompt the disclosure never approved.
``ExplanationPromptAdapter`` binds the dispatched prompt to
``explanation_prompt.PROMPT_VERSION`` so the ledger records what was actually
authorised, and ``require_prompt_binding`` fails closed if they ever diverge.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

from sitewise.project1.contracts import WorkflowHeld, canonical, digest
from sitewise.project1.explanation_contracts import (
    BANNED_PHRASES,
    ExplanationOutput,
    extract_numbers,
    normalise,
    validate_candidate,
)
from sitewise.project1.explanation_prompt import (
    PROMPT_VERSION,
    messages as explanation_messages,
    prompt_fingerprint,
    system_prompt,
)

# ---------------------------------------------------------------------------
# Vocabulary
# ---------------------------------------------------------------------------

DETERMINISTIC_ONLY = 'DETERMINISTIC_ONLY'
AI_VALIDATED = 'AI_VALIDATED'
AI_REJECTED_FELL_BACK = 'AI_REJECTED_FELL_BACK'
AI_UNAVAILABLE_FELL_BACK = 'AI_UNAVAILABLE_FELL_BACK'
AI_OUTCOME_UNKNOWN = 'AI_OUTCOME_UNKNOWN'
HELD_INVALID_EVIDENCE = 'HELD_INVALID_EVIDENCE'
HELD_UNSUPPORTED_RULE = 'HELD_UNSUPPORTED_RULE'
WITHHELD_ADMISSION = 'WITHHELD_ADMISSION'

#: Outcomes that leave the provider's effect genuinely unknown. Never retried
#: here, and never reported as a definite failure.
UNCERTAIN_OUTCOMES = frozenset({
    'E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN',
    'E_PROVIDER_RESPONSE_DECODE_OUTCOME_UNKNOWN',
})

#: The only admission state this module will execute under. It refuses anything
#: else rather than discovering admission later.
EXECUTABLE_ADMISSION_STATE = 'REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE'

VALIDATION_RULES = ('V01', 'V02', 'V03', 'V04', 'V05', 'V06', 'V07', 'V08', 'V09')

#: Minimum share of the deterministic baseline's limitation vocabulary that an AI
#: candidate must retain. Rephrasing is allowed; deleting the caveat is not. This
#: is a lexical floor, not a semantic judgement, and is documented as such: it
#: catches omission, not mis-statement (V04 catches that).
LIMITATION_RECALL_FLOOR = 0.5

_CODE_RE = re.compile(r'\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b')
_WORD_RE = re.compile(r'[a-z]{4,}')

_STOPWORDS = frozenset({
    'that', 'this', 'with', 'from', 'were', 'have', 'been', 'they', 'their',
    'which', 'than', 'then', 'also', 'such', 'into', 'only', 'does', 'does',
    'these', 'those', 'there', 'when', 'where', 'what', 'will', 'would',
    'should', 'could', 'must', 'more', 'most', 'less', 'some', 'each', 'other',
    'about', 'after', 'before', 'under', 'over', 'between', 'because', 'while',
    'cannot', 'never', 'nothing', 'without',
})


@dataclass(frozen=True)
class ValidationFinding:
    """One V-rule outcome, in the project's existing status vocabulary."""
    rule_id: str
    passed: bool
    code: str | None = None
    detail: str = ''

    def as_record(self) -> dict:
        return {'rule_id': self.rule_id, 'passed': self.passed,
                'code': self.code, 'detail': self.detail}


def _content_words(text: str) -> set[str]:
    """Content vocabulary for the limitation-retention check."""
    return {word for word in _WORD_RE.findall(normalise(text))
            if word not in _STOPWORDS}


# ---------------------------------------------------------------------------
# V01–V09
# ---------------------------------------------------------------------------

def _v01_schema(candidate: ExplanationOutput, packet: dict) -> ValidationFinding:
    try:
        # Re-validate the shape through the contract itself. A candidate that was
        # mutated after parsing fails here rather than downstream.
        ExplanationOutput.model_validate(candidate.model_dump())
    except Exception as exc:  # pydantic ValidationError
        return ValidationFinding('V01', False, 'EXPLANATION_SCHEMA_INVALID', str(exc)[:200])
    return ValidationFinding('V01', True)


def _v02_numerical(candidate: ExplanationOutput, *, allowed_numbers: set[str],
                   registry_literals: frozenset[str] | None) -> ValidationFinding:
    narrative = _narrative(candidate)
    allowed = set(allowed_numbers) | set(registry_literals or ())
    unsourced = sorted(n for n in extract_numbers(narrative) if n not in allowed)
    if unsourced:
        return ValidationFinding('V02', False, 'EXPLANATION_UNSOURCED_NUMBER',
                                 f'unsourced numerals: {", ".join(unsourced)}')
    return ValidationFinding('V02', True)


def _v03_question_meaning(candidate: ExplanationOutput, *, packet: dict,
                          own_tokens: set[str],
                          registry_literals: frozenset[str] | None) -> ValidationFinding:
    """No code-shaped token from another item may appear in the narrative.

    ``validate_semantics`` already refuses unknown codes against the request's own
    label set. This is the same idea at candidate level, widened to allow tokens
    the packet or the pinned registry legitimately carries (A10, M2-10, CS-07),
    so an owner-prepared limitation is not mistaken for cross-item contamination.
    """
    narrative = _narrative(candidate)
    allowed = set(own_tokens)
    allowed |= {str(x) for x in (packet.get('reference_universe') or [])}
    allowed |= set(registry_literals or ())
    foreign = sorted({t for t in _CODE_RE.findall(narrative) if t not in allowed})
    if foreign:
        return ValidationFinding('V03', False, 'EXPLANATION_SEMANTIC_UNKNOWN_CODE',
                                 f'foreign item codes: {", ".join(foreign)}')
    return ValidationFinding('V03', True)


def _v04_claim_boundary(candidate: ExplanationOutput) -> ValidationFinding:
    flat = normalise(_narrative(candidate))
    hits = [phrase for phrase in BANNED_PHRASES if normalise(phrase) in flat]
    if hits:
        return ValidationFinding('V04', False, 'EXPLANATION_PROHIBITED_CLAIM',
                                 f'prohibited phrasing: {", ".join(hits)}')
    return ValidationFinding('V04', True)


def _v05_provenance(candidate: ExplanationOutput, *, allowed_claim_ids: set[str],
                    packet: dict) -> ValidationFinding:
    if not set(candidate.used_claim_ids) <= set(allowed_claim_ids):
        return ValidationFinding('V05', False, 'EXPLANATION_UNAUTHORIZED_CLAIM_ID',
                                 'candidate cites a claim it was not given')
    universe = set(packet.get('reference_universe') or [])
    unknown = sorted(set(candidate.missing_evidence_references) - universe)
    if unknown:
        return ValidationFinding('V05', False, 'EXPLANATION_UNKNOWN_EVIDENCE_REFERENCE',
                                 f'unknown references: {", ".join(unknown)}')
    return ValidationFinding('V05', True)


def _v06_privacy(candidate: ExplanationOutput, *, effective_state: str,
                 allowed_numbers: set[str],
                 registry_literals: frozenset[str] | None) -> ValidationFinding:
    """A non-substantive state may not disclose a share.

    The suppression unit in this instrument is the percentage of a valid base. A
    refusal count or a valid-base count is a funnel figure the owner's own
    templates print deliberately (``Only {V} valid responses were available``);
    a percentage of a suppressed distribution is not. So the check is on ``%``
    and on any numeral outside the packet, not on digits in general.
    """
    if effective_state == 'VALID_APPROVED':
        return ValidationFinding('V06', True)
    narrative = _narrative(candidate)
    if '%' in narrative or 'percent' in narrative.lower():
        return ValidationFinding('V06', False, 'EXPLANATION_PRIVACY_PERCENTAGE_DISCLOSED',
                                 'a percentage was disclosed for a non-substantive state')
    allowed = set(allowed_numbers) | set(registry_literals or ())
    stray = sorted(n for n in extract_numbers(narrative) if n not in allowed)
    if stray:
        return ValidationFinding('V06', False, 'EXPLANATION_PRIVACY_COUNT_DISCLOSED',
                                 f'counts outside the packet: {", ".join(stray)}')
    return ValidationFinding('V06', True)


def _v07_version_freshness(candidate: ExplanationOutput, *, packet: dict,
                           prompt_version: str) -> ValidationFinding:
    if (candidate.context_id != packet.get('context_id')
            or candidate.snapshot_id != packet.get('snapshot_id')
            or candidate.task_mode != packet.get('task_mode')):
        return ValidationFinding('V07', False, 'EXPLANATION_ECHO_BACK_MISMATCH',
                                 'candidate is bound to a different context or snapshot')
    if prompt_version != PROMPT_VERSION:
        return ValidationFinding('V07', False, 'EXPLANATION_PROMPT_VERSION_MISMATCH',
                                 f'{prompt_version} != {PROMPT_VERSION}')
    return ValidationFinding('V07', True)


def _v08_completeness(candidate: ExplanationOutput, *,
                      baseline: ExplanationOutput) -> ValidationFinding:
    """The mandatory caveat may be rephrased but not removed.

    Recall of the baseline's limitation vocabulary. A model that restates the same
    caveats in different words passes; one that deletes them fails.
    """
    required = _content_words(baseline.limitations)
    if not required:
        return ValidationFinding('V08', True)
    kept = _content_words(candidate.limitations)
    recall = len(required & kept) / len(required)
    if recall < LIMITATION_RECALL_FLOOR:
        return ValidationFinding(
            'V08', False, 'EXPLANATION_LIMITATION_REMOVED',
            f'limitation vocabulary recall {recall:.2f} < {LIMITATION_RECALL_FLOOR}')
    return ValidationFinding('V08', True)


def _v09_admission(candidate: ExplanationOutput, *, admission_state: str,
                   authority_markers: dict) -> ValidationFinding:
    if admission_state != EXECUTABLE_ADMISSION_STATE:
        return ValidationFinding('V09', False, 'EXPLANATION_ADMISSION_STATE_CHANGED',
                                 f'admission state {admission_state} is not executable')
    if any(authority_markers.values()):
        return ValidationFinding('V09', False, 'EXPLANATION_AUTHORITY_ASSERTED',
                                 'a candidate asserted authority it cannot hold')
    return ValidationFinding('V09', True)


def _narrative(candidate: ExplanationOutput) -> str:
    return ' '.join((candidate.headline, candidate.observation_interpretation,
                     candidate.research_interpretation, candidate.planning_implication,
                     candidate.limitations, candidate.summary))


def narrative_codes(candidate: ExplanationOutput) -> set[str]:
    """Code-shaped tokens already present in a deterministic baseline.

    The hash-pinned registry legitimately names response labels such as
    ``CANNOT_JUDGE``. When that baseline is rendered by the registry, those tokens
    are part of the approved vocabulary rather than foreign item codes. Only a
    caller that has verified the producer may add them to ``own_tokens``.
    """
    return set(_CODE_RE.findall(_narrative(candidate)))


#: Error codes belonging to the historical ``validate_candidate`` contract. The
#: V-rule that owns each code is recorded here so the governed path preserves the
#: code an older caller already handles instead of replacing it with a weaker V-id.
LEGACY_CODE_RULES = {
    'EXPLANATION_SCHEMA_VERSION_MISMATCH': 'V01',
    'EXPLANATION_ECHO_BACK_MISMATCH': 'V07',
    'EXPLANATION_UNAUTHORIZED_CLAIM_ID': 'V05',
    'EXPLANATION_DUPLICATE_CLAIM_ID': 'V05',
    'EXPLANATION_INSUFFICIENT_WITH_CLAIMS': 'V08',
    'EXPLANATION_MISSING_EVIDENCE_REFERENCES': 'V08',
    'EXPLANATION_SUFFICIENT_WITHOUT_CLAIMS': 'V08',
    'EXPLANATION_UNKNOWN_EVIDENCE_REFERENCE': 'V05',
    'EXPLANATION_PROHIBITED_CLAIM': 'V04',
    'EXPLANATION_UNSOURCED_NUMBER': 'V02',
    'EXPLANATION_UNSOURCED_QUANTITY': 'V02',
}


def validate_v01_v09(candidate: ExplanationOutput, *, packet: dict,
                     baseline: ExplanationOutput, effective_state: str,
                     allowed_claim_ids: set[str], allowed_numbers: set[str],
                     own_tokens: set[str],
                     registry_literals: frozenset[str] | None = None,
                     prompt_version: str = PROMPT_VERSION,
                     admission_state: str = EXECUTABLE_ADMISSION_STATE,
                     authority_markers: dict | None = None) -> list[ValidationFinding]:
    """Every V-rule, in order, without short-circuiting.

    All nine run so the audit record shows the full picture rather than only the
    first thing that went wrong. The caller rejects the candidate if any failed.
    """
    markers = authority_markers or {}
    return [
        _v01_schema(candidate, packet),
        _v02_numerical(candidate, allowed_numbers=allowed_numbers,
                       registry_literals=registry_literals),
        _v03_question_meaning(candidate, packet=packet, own_tokens=own_tokens,
                              registry_literals=registry_literals),
        _v04_claim_boundary(candidate),
        _v05_provenance(candidate, allowed_claim_ids=allowed_claim_ids, packet=packet),
        _v06_privacy(candidate, effective_state=effective_state,
                     allowed_numbers=allowed_numbers,
                     registry_literals=registry_literals),
        _v07_version_freshness(candidate, packet=packet, prompt_version=prompt_version),
        _v08_completeness(candidate, baseline=baseline),
        _v09_admission(candidate, admission_state=admission_state,
                       authority_markers=markers),
    ]


def validate_authoritative(candidate: ExplanationOutput, *, packet: dict,
                           baseline: ExplanationOutput, effective_state: str,
                           allowed_claim_ids: set[str], allowed_numbers: set[str],
                           own_tokens: set[str],
                           registry_literals: frozenset[str] | None = None,
                           prompt_version: str = PROMPT_VERSION,
                           admission_state: str = EXECUTABLE_ADMISSION_STATE,
                           authority_markers: dict | None = None) -> list[ValidationFinding]:
    """The single validation policy for Explanation Module execution.

    ``validate_v01_v09`` contributes the governed audit dimensions (privacy,
    limitation retention, admission, prompt binding and cross-item codes). The
    historical ``validate_candidate`` contributes stricter contract checks that
    are not expressed by those nine rules (duplicate claim IDs, quantity words,
    and the insufficient/sufficient invariant).

    Every finding is retained, and a legacy failure is recorded under the V-rule
    that owns it with the original code, so an older caller still sees the error
    code it handles. This is a compatibility adapter, not a deletion of either
    validator.
    """
    findings = validate_v01_v09(
        candidate, packet=packet, baseline=baseline, effective_state=effective_state,
        allowed_claim_ids=allowed_claim_ids, allowed_numbers=allowed_numbers,
        own_tokens=own_tokens, registry_literals=registry_literals,
        prompt_version=prompt_version, admission_state=admission_state,
        authority_markers=authority_markers)
    by_rule = {finding.rule_id: finding for finding in findings}
    try:
        validate_candidate(
            candidate, packet=packet, allowed_claim_ids=allowed_claim_ids,
            allowed_numbers=allowed_numbers, registry_literals=registry_literals)
    except WorkflowHeld as exc:
        code = str(exc)
        rule_id = LEGACY_CODE_RULES.get(code)
        if rule_id is None:
            # Unknown code: fail the record rather than silently ignoring a new
            # guard that was added to the historical contract.
            raise
        previous = by_rule[rule_id]
        by_rule[rule_id] = ValidationFinding(
            rule_id, False, code,
            (previous.detail + '; ' if previous.detail else '') + 'legacy contract guard failed')
    return [by_rule[rule_id] for rule_id in VALIDATION_RULES]


# ---------------------------------------------------------------------------
# Prompt binding
# ---------------------------------------------------------------------------

class ExplanationPromptAdapter:
    """Presents ``explanation_prompt`` through the ``Prompt`` interface.

    ``ModelRunner`` expects an object with ``version``, ``fingerprint`` and
    ``messages(source, schema)``. ``explanation_prompt`` exposes the same content
    under different names, and — critically — under the version the disclosure
    adapter authorises. Adapting it here keeps one source of truth for the
    instruction text while making the ledger record the authorised version.
    """

    version = PROMPT_VERSION
    role = 'PROJECT1 Evidence Explanation Interpreter'
    supports_prompt_key = True

    def __init__(self, entry: dict | None = None):
        self.entry = entry

    @property
    def fingerprint(self) -> str:
        return prompt_fingerprint(self.entry)

    def messages(self, source: dict, schema: dict) -> list[dict]:
        # The registry entry is part of the system message, not the user turn, so
        # an item rule cannot be smuggled in as data.
        return explanation_messages(source, self.entry)


def require_prompt_binding(authorization_version: str, *,
                           prompt_version: str = PROMPT_VERSION) -> None:
    """Fail closed unless the dispatched prompt is the one that was authorised."""
    if prompt_version != authorization_version:
        raise WorkflowHeld('EXPLANATION_PROMPT_BINDING_MISMATCH')


# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

@dataclass
class ExecutionResult:
    outcome: str
    candidate: ExplanationOutput | None
    baseline: ExplanationOutput
    validation: list[ValidationFinding] = field(default_factory=list)
    ai_candidate: ExplanationOutput | None = None
    rejection_code: str | None = None
    retry_authorized: bool = False
    report_usable: bool = False
    ledger: dict | None = None
    detail: str = ''

    @property
    def execution_kind(self) -> str:
        """``DETERMINISTIC_ONLY`` when no provider attempt was reserved."""
        return DETERMINISTIC_ONLY if self.ledger is None else 'AI_ATTEMPTED'

    def as_record(self) -> dict:
        return {
            'outcome': self.outcome,
            'execution_kind': self.execution_kind,
            'rejection_code': self.rejection_code,
            'retry_authorized': self.retry_authorized,
            'report_usable': self.report_usable,
            'validation': [f.as_record() for f in self.validation],
            'validation_failed': [f.rule_id for f in self.validation if not f.passed],
            'ledger': self.ledger,
            'detail': self.detail,
            'baseline_sha256': digest(self.baseline.model_dump()),
            'candidate_sha256': (digest(self.candidate.model_dump())
                                 if self.candidate is not None else None),
        }


class ExplanationExecutionService:
    """Runs one explanation under the existing disclosure, ledger and validator.

    ``dispatch`` is the governed callable — normally a ``ModelRunner`` bound to
    ``EXPLANATION``, and in tests a lambda that returns or raises. It is never a
    raw provider client here.
    """

    def __init__(self, *, dispatch=None, prompt_version: str = PROMPT_VERSION):
        self.dispatch = dispatch
        self.prompt_version = prompt_version

    def execute(self, *, packet: dict, baseline: ExplanationOutput,
                effective_state: str, allowed_claim_ids: set[str],
                allowed_numbers: set[str], own_tokens: set[str],
                registry_literals: frozenset[str] | None = None,
                admission_state: str = EXECUTABLE_ADMISSION_STATE,
                execution_authorized: bool = False,
                authorized_prompt_version: str | None = None,
                rule_available: bool = True,
                authority_markers: dict | None = None,
                dispatch=None) -> ExecutionResult:
        # An explicit per-call dispatch is allowed so one governed service can be
        # shared by deterministic and deliberately authorised synthetic flows.
        # It is still the governed callable, never a raw provider client.
        if dispatch is not None:
            self.dispatch = dispatch
        # --- preflight: these hold before anything is dispatched -----------
        if admission_state != EXECUTABLE_ADMISSION_STATE:
            return ExecutionResult(WITHHELD_ADMISSION, None, baseline,
                                   detail='admission state is not executable')
        if not rule_available:
            return ExecutionResult(HELD_UNSUPPORTED_RULE, None, baseline,
                                   detail='no approved explanation rule for this item')
        if (effective_state == 'VALID_APPROVED'
                and baseline.insufficient_evidence is False and not allowed_claim_ids):
            # A substantive baseline with no authorised claim cannot be explained.
            # A non-substantive registry state may legitimately have no claim: its
            # withheld prose is the evidence state, not an interpretation of data.
            return ExecutionResult(HELD_INVALID_EVIDENCE, None, baseline,
                                   detail='substantive evidence without an authorised claim')

        if self.dispatch is None or not execution_authorized:
            # Deterministic baseline only. No attempt row is fabricated.
            return ExecutionResult(DETERMINISTIC_ONLY, baseline, baseline,
                                   report_usable=True,
                                   detail='no authorised dispatch; deterministic baseline used')

        # --- prompt binding, before anything leaves the process -------------
        # EX-04 GATE 1: `require_prompt_binding` existed but had no caller, so
        # the "defence in depth" guarded nothing. A dispatch must now name the
        # prompt version its authorization covers, and the version actually being
        # sent must be that one. Both checks raise rather than returning a held
        # result: a mismatch is a configuration error, not a measurement outcome,
        # and the outcome vocabulary deliberately has no value for it.
        if authorized_prompt_version is None:
            raise WorkflowHeld('EXPLANATION_PROMPT_BINDING_ABSENT')
        require_prompt_binding(authorized_prompt_version,
                              prompt_version=self.prompt_version)

        # --- dispatch ------------------------------------------------------
        try:
            ai = self.dispatch(packet)
        except WorkflowHeld as exc:
            code = str(exc)
            if code in UNCERTAIN_OUTCOMES:
                # Unknown outcome: not a definite failure, and never auto-retried.
                return ExecutionResult(AI_OUTCOME_UNKNOWN, baseline, baseline,
                                       rejection_code=code, retry_authorized=False,
                                       report_usable=True,
                                       ledger=self._ledger_snapshot(code),
                                       detail='provider outcome unknown; outcome unresolved')
            return ExecutionResult(AI_UNAVAILABLE_FELL_BACK, baseline, baseline,
                                   rejection_code=code, retry_authorized=False,
                                   report_usable=True,
                                   ledger=self._ledger_snapshot(code),
                                   detail='provider unavailable; deterministic baseline used')

        # --- validate ------------------------------------------------------
        try:
            ai = ExplanationOutput.model_validate(ai)
        except Exception as exc:
            return ExecutionResult(AI_REJECTED_FELL_BACK, baseline, baseline,
                                   rejection_code='EXPLANATION_SCHEMA_INVALID',
                                   ledger=self._ledger_snapshot('returned'),
                                   detail=str(exc)[:200])

        findings = validate_authoritative(
            ai, packet=packet, baseline=baseline, effective_state=effective_state,
            allowed_claim_ids=allowed_claim_ids, allowed_numbers=allowed_numbers,
            own_tokens=own_tokens, registry_literals=registry_literals,
            prompt_version=self.prompt_version, admission_state=admission_state,
            authority_markers=authority_markers)
        failed = [f for f in findings if not f.passed]
        if failed:
            return ExecutionResult(AI_REJECTED_FELL_BACK, baseline, baseline,
                                   validation=findings, ai_candidate=ai,
                                   rejection_code=failed[0].code,
                                   ledger=self._ledger_snapshot('returned'),
                                   detail=f'failed {", ".join(f.rule_id for f in failed)}')

        # A validated candidate is still only a candidate: admission is unchanged.
        return ExecutionResult(AI_VALIDATED, ai, baseline, validation=findings,
                               ai_candidate=ai, report_usable=True,
                               ledger=self._ledger_snapshot('returned'))

    def _ledger_snapshot(self, receipt_outcome: str) -> dict:
        """The ledger facts of the attempt that just ran, when a runner provides them."""
        execution = getattr(self.dispatch, 'last_execution', None) or {}
        return {
            'stage': execution.get('stage', 'EXPLANATION'),
            # EX-04: the run identity was missing from this snapshot, so every
            # AI_ATTEMPTED record was produced with run_id=None. That made the
            # record unstorable: `explanation_results_ai_names_its_run` rejects
            # it, and the store refuses it, because the attempts FK needs the
            # run to exist. An AI attempt that cannot name its run is not
            # traceable, so it must not be recordable either.
            'run_id': execution.get('run_id'),
            'attempt_no': execution.get('attempt_no'),
            'prompt_version': execution.get('prompt_version'),
            'prompt_sha256': execution.get('prompt_sha256'),
            'request_sha256': execution.get('request_sha256'),
            'receipt_recorded': bool(execution.get('receipt_recorded')),
            'receipt_outcome': execution.get('receipt_outcome', receipt_outcome),
            'model_requested': execution.get('model_requested'),
            'model_returned': execution.get('model_returned'),
        }


def result_record(*, result: ExecutionResult, packet: dict,
                  assessment_id: str, campaign_id: str,
                  snapshot_id: str, question_id: str | None,
                  ruleset_version: str, registry_version: str,
                  registry_sha256: str) -> dict:
    """The explanation-result audit record, shaped for the result table.

    Deterministic-only executions get a record too, with ``run_id``/``attempt_no``
    left ``None``. That is the point: a deterministic explanation is traceable
    without pretending a cloud call happened.
    """
    ledger = result.ledger or {}
    record = {
        'assessment_id': assessment_id,
        'campaign_id': campaign_id,
        'snapshot_id': snapshot_id,
        'question_id': question_id,
        'ruleset_version': ruleset_version,
        'registry_version': registry_version,
        'registry_sha256': registry_sha256,
        'source_fingerprint': packet.get('snapshot_hash'),
        'context_id': packet.get('context_id'),
        'execution_kind': result.execution_kind,
        'outcome': result.outcome,
        'run_id': ledger.get('run_id'),
        'attempt_no': ledger.get('attempt_no'),
        'prompt_version': ledger.get('prompt_version'),
        'prompt_sha256': ledger.get('prompt_sha256'),
        'request_sha256': ledger.get('request_sha256'),
        'model_requested': ledger.get('model_requested'),
        'model_returned': ledger.get('model_returned'),
        'validation_status': (
            'not_validated' if not result.validation
            else 'valid' if all(f.passed for f in result.validation) else 'invalid'),
        'validation_rules': [f.rule_id for f in result.validation],
        'validation_failures': [f.as_record() for f in result.validation if not f.passed],
        'rejection_code': result.rejection_code,
        'fallback_outcome': result.outcome,
        'retry_authorized': result.retry_authorized,
        'authority': 'CANDIDATE_UNVERIFIED',
        'admitted': False,
        'deterministic_baseline_sha256': digest(result.baseline.model_dump()),
        'candidate_sha256': (digest(result.candidate.model_dump())
                             if result.candidate is not None else None),
    }
    # Fail here rather than at the insert: an AI record whose runner did not
    # report its run cannot satisfy the attempts foreign key, so writing it is
    # impossible by construction. Saying so at the point the record is built
    # names the missing fact; letting the insert fail would report a constraint
    # violation instead.
    if record['execution_kind'] == 'AI_ATTEMPTED' and record['run_id'] is None:
        raise WorkflowHeld('EXPLANATION_AI_RESULT_WITHOUT_RUN')
    if record['execution_kind'] == 'DETERMINISTIC_ONLY' and record['run_id'] is not None:
        raise WorkflowHeld('EXPLANATION_DETERMINISTIC_RESULT_NAMES_A_RUN')
    return record
