"""The four persisted outcome dimensions of a cloud BDJ result, and nothing else.

This module is the only place that knows how a `BDJEngine.review()` verdict and
a ledger transport outcome become a `project1_ai.bdj_results` row. It imports no
web framework, opens no connection and writes nothing: the boundary it owns is
naming and classification, so that a vocabulary cannot drift between Python and
the migration that stores it.

The four dimensions are independent. None is derived from another by translation
and none may be substituted for another:

  D1 execution_outcome    did the provider call complete?
                          Owner: project1_ai.attempts.outcome, written by
                          ledger.finish(). Copied verbatim, never inferred.
  D2 validation_status    did the returned object pass validate_candidates()?
                          Owner: none in Python -- it is a generated column on
                          project1_ai.bdj_results, derived from D3.
  D3 review_outcome       the engine's verdict.
                          Owner: BDJEngine.review() return value.
  D4 finding_authority    may this result claim authority over a finding?
                          Owner: finding_authority on the result (bdj.py:144),
                          constrained to candidate_only in the database.

A single 'returned' transport outcome can legitimately coexist with 'reviewed',
'rejected' or 'stale'. That is not an inconsistency: the call worked and the
result was then judged. Code that maps one dimension onto the other destroys
exactly the information these four columns exist to keep apart.
"""
from sitewise.project1.contracts import WorkflowHeld

# `digest` is deliberately NOT imported here. The only digest a result row
# carries is the ledger's digest of the provider output (provider.py:140), which
# this module receives rather than recomputes -- recomputing it over the engine
# verdict would produce a different hash over a different object and silently
# break constraint C5.

# D1. Owner: project1_ai.attempts.outcome + attempt_receipts, via ledger.finish().
# 'unknown_outcome' is not 'timed_out': a provider timeout leaves it unknown
# whether the request was processed, and the call may still have been billed.
EXECUTION_OUTCOMES = ('returned', 'rejected', 'unknown_outcome')

# D3. Owner: BDJEngine.review() (bdj.py:136/128/133). Persisted as nullable.
# 'held' is deliberately absent -- see HELD below for why it cannot be stored.
REVIEW_OUTCOMES = ('reviewed', 'rejected', 'stale')

# D2. Owner: the generated column project1_ai.bdj_results.validation_status.
# No application writes these; they are read back.
VALIDATION_STATUSES = ('not_validated', 'invalid', 'valid')

# D4. Owner: bdj_results.finding_authority, single-value CHECK. A cloud result
# can never be 'verified': that needs independent review, which BCB enforces
# outside this table (finding_hash + confirmation_id + review_event_id).
FINDING_AUTHORITIES = ('candidate_only',)

# The engine's verdict when no ruleset is adopted, returned at bdj.py:70-73
# before ledger.reserve(). It has no attempt row, so the composite FK to
# attempts(run_id, owner_user_id, attempt_no) has no target and the value is
# unrepresentable in bdj_results. It stays in the response body only.
HELD = 'held'

# bdj.py:144 emits the upper-case form of D4. The database stores the lower-case
# token, so the two must be reconciled at this boundary -- and reconciled by
# checking, not by lowering, so a future 'VERIFIED' claim fails closed.
_ENGINE_FINDING_AUTHORITY = 'CANDIDATE_ONLY'


def classify(review_result: dict | None, execution_outcome: str, *,
             output_digest: str | None = None) -> dict:
    """Map an engine verdict plus a ledger outcome to a `bdj_results` row body.

    Total over its declared domain: every combination of the three D1 values and
    the four D3 values (reviewed / rejected / stale / None) either returns a row
    body or raises `WorkflowHeld('RESULT_OUTCOME_UNCLASSIFIED')`. There is no
    default and no branch that falls through to 'reviewed'.

    `review_result` is None when no review happened at all -- the attempt was
    reserved and the provider failed. That is D3 NULL, and it is the state a
    caller holds when `ModelRunner` raised.

    `output_digest` is the digest the ledger already recorded for a returned
    response (`provider.py:140`). It is supplied by the caller because it is not
    derivable from the engine verdict, and it is required exactly when
    execution_outcome='returned' (constraint C1). D1 is copied verbatim from the
    ledger, so the row can never disagree with its receipt (C5).

    Only the outcome dimensions are returned. Provenance columns (run_id, owner,
    attempt_no, assessment id/revision, fingerprint, versions) belong to the
    caller, which is the only party that holds them.
    """
    if execution_outcome not in EXECUTION_OUTCOMES:
        raise WorkflowHeld('RESULT_OUTCOME_UNCLASSIFIED')

    if review_result is None:
        # No response, therefore no validation and no review. C1 also forbids a
        # digest here: ledger.finish() passes None for both failure outcomes.
        if execution_outcome == 'returned' or output_digest is not None:
            raise WorkflowHeld('RESULT_OUTCOME_UNCLASSIFIED')
        return {'execution_outcome': execution_outcome,
                'review_outcome': None,
                'output_digest': None,
                'result_payload': None,
                'finding_authority': 'candidate_only',
                'finding_count': 0}

    # A review exists only if something came back to review.
    if execution_outcome != 'returned':
        raise WorkflowHeld('RESULT_OUTCOME_UNCLASSIFIED')
    if output_digest is None:
        raise WorkflowHeld('RESULT_OUTCOME_UNCLASSIFIED')
    if not isinstance(output_digest, str) or len(output_digest) != 64:
        raise WorkflowHeld('RESULT_OUTCOME_UNCLASSIFIED')

    if 'outcome' not in review_result or 'findings' not in review_result:
        raise WorkflowHeld('RESULT_OUTCOME_UNCLASSIFIED')
    outcome, findings = review_result['outcome'], review_result['findings']
    if not isinstance(findings, list):
        raise WorkflowHeld('RESULT_OUTCOME_UNCLASSIFIED')

    if 'finding_authority' not in review_result:
        raise WorkflowHeld('RESULT_OUTCOME_UNCLASSIFIED')
    if review_result['finding_authority'] != _ENGINE_FINDING_AUTHORITY:
        # D4 is checked, not lowered: a result claiming anything else -- in any
        # spelling -- is not a candidate-only result and must not be stored.
        raise WorkflowHeld('RESULT_OUTCOME_UNCLASSIFIED')

    if outcome == 'reviewed':
        # 'reviewed' means the engine completed, never that a finding is true.
        # An empty list is a real, representable outcome: it is the derived
        # state NO_ADMISSIBLE_FINDING, not a failure and not an admission.
        review_outcome, payload = 'reviewed', {'findings': findings}
    elif outcome == 'rejected':
        # validate_candidates() raised. Nothing survives validation, so a
        # finding list here would be evidence the engine cannot produce.
        if findings:
            raise WorkflowHeld('RESULT_OUTCOME_UNCLASSIFIED')
        review_outcome, payload = 'rejected', None
    elif outcome == 'stale':
        # The fingerprint changed after validation. The engine drops the
        # findings it had already validated (bdj.py:131-133); whatever it
        # hands back is what is stored, verbatim.
        review_outcome, payload = 'stale', {'findings': findings}
    else:
        # 'held' (pre-dispatch, no attempt row) and anything unregistered.
        raise WorkflowHeld('RESULT_OUTCOME_UNCLASSIFIED')

    return {'execution_outcome': execution_outcome,
            'review_outcome': review_outcome,
            'output_digest': output_digest,
            'result_payload': payload,
            'finding_authority': 'candidate_only',
            'finding_count': len(findings)}


def derived_admission(row: dict) -> str:
    """Presentation label for a result. NEVER persisted; no column stores it.

    `no_admissible_finding` is exactly `review_outcome='reviewed'` with zero
    findings. `admitted` means only "there is a candidate finding to show" --
    it is not business admission, which a cloud result can never grant.

    A stored row can never yield 'held': the engine returns that verdict before
    any attempt exists, so no row is written. That is the only label readable
    from a live engine result -- a caller holding one of the other three
    verdicts must persist it first and label the row, because 'admitted' and
    'no_admissible_finding' depend on the stored finding count.
    """
    if 'review_outcome' in row:
        outcome = row['review_outcome']
        if outcome is None:
            return 'not_reviewed'
        if outcome == 'rejected':
            return 'rejected'
        if outcome == 'stale':
            return 'stale'
        if outcome == 'reviewed':
            if 'finding_count' not in row:
                raise WorkflowHeld('RESULT_OUTCOME_UNCLASSIFIED')
            count = row['finding_count']
            if not isinstance(count, int) or isinstance(count, bool) or count < 0:
                raise WorkflowHeld('RESULT_OUTCOME_UNCLASSIFIED')
            return 'admitted' if count > 0 else 'no_admissible_finding'
        raise WorkflowHeld('RESULT_OUTCOME_UNCLASSIFIED')
    if 'outcome' in row and row['outcome'] == HELD:
        return 'held'
    raise WorkflowHeld('RESULT_OUTCOME_UNCLASSIFIED')
