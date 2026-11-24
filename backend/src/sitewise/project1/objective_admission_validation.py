"""Structured objective-admission validation (OA-01 … OA-07).

The admission decision itself already exists and is authoritative:
``objective_admission.policy_binding`` derives the disposition, the resolution and
the fixed objective a proposal may bind, and ``objective_admission.record_admission``
is the only writer. This module does not re-derive any of that. It evaluates the
facts those functions already produced and reports each requirement separately, so
a refusal can name *which* requirement failed.

The distinction the report preserves
------------------------------------
``policy_binding`` returns one ``reason`` string. That is enough to refuse and not
enough to explain, because several requirements can fail at once and their order
is not meaningful. The report keeps them apart:

* an unapproved proposal is a different situation from an unadopted policy;
* a proposal that is suitable but binds no fixed objective is different from one
  whose classification is ambiguous;
* clarification-pending is not a failure at all — it is a valid owner decision
  whose downstream question is legitimately blocked.

Nothing here approves, admits or writes. ``ValidationReport.require`` can only
stop work; it cannot start any.
"""
from __future__ import annotations

import json

from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.objective_admission import (
    CLARIFICATION_PENDING,
    NOT_RESEARCH_SUITABLE,
    RESEARCH_SUITABLE,
    proposal_hash,
)
from sitewise.project1.validation_contract import (
    PASS,
    UNVERIFIED,
    ValidationReport,
    failed,
    passed,
    unverified,
)

#: The admission policy identity this report is evaluated under. It is read from
#: the issue-resolution policy rather than restated, so a policy version change
#: cannot leave the report quoting a stale identity.
REPORT_VERSION = 'P1-ADMISSION-VALIDATION-1.0'

_APPROVED = 'APPROVED'


def _refs(row: dict) -> list:
    refs = row.get('source_refs')
    if isinstance(refs, (str, bytes)):
        try:
            refs = json.loads(refs)
        except (ValueError, TypeError):
            return []
    return refs if isinstance(refs, list) else []


def evaluate(row: dict | None, *, binding: dict, confirmation_id: str,
             assessment_id: str, revision: int, context_current: bool,
             policy_adopted: bool) -> ValidationReport:
    """Evaluate the seven admission requirements against already-loaded facts.

    Pure: no I/O, no writes. ``binding`` is the dict returned by
    ``objective_admission.policy_binding``; ``context_current`` is the caller's
    verified statement that the BCB context is persisted and source-current.

    Every argument is required, including ``policy_adopted``. Defaulting it would
    let a caller silently evaluate under an adopted policy that does not exist.
    """
    policy_version = str(binding.get('policy_version') or '')
    checks = []

    # OA-01 — the proposal exists, its content still hashes to what was admitted,
    # and it cites at least one declaration. A proposal whose cited sources are
    # absent cannot be traced to the entrepreneur's own words.
    if row is None:
        checks.append(failed(
            'OA-01', 'Current validated BDJ proposal and provenance',
            'BDJ_ADMISSION_NOT_FOUND', policy_version=policy_version))
    else:
        stored = row.get('proposal_hash')
        recomputed = proposal_hash(dict(row))
        sources = [str(row.get('proposal_id') or '')]
        if stored and str(stored) != recomputed:
            checks.append(failed(
                'OA-01', 'Current validated BDJ proposal and provenance',
                'BDJ_ADMISSION_PROPOSAL_CHANGED', sources=sources,
                evidence={'stored_hash': str(stored),
                          'recomputed_hash': recomputed},
                policy_version=policy_version))
        elif not _refs(row):
            checks.append(failed(
                'OA-01', 'Current validated BDJ proposal and provenance',
                'BDJ_PROPOSAL_SOURCE_UNVERIFIED', sources=sources,
                evidence={'source_ref_count': 0},
                policy_version=policy_version))
        else:
            checks.append(passed(
                'OA-01', 'Current validated BDJ proposal and provenance',
                sources=sources + [str(row.get('source_fingerprint') or '')],
                evidence={'source_ref_count': len(_refs(row)),
                          'proposal_hash': recomputed},
                policy_version=policy_version))

    # OA-02 — an explicit owner approval. The review state and the decision row
    # must agree; disagreement is not an approval, it is an unreadable record.
    if row is None:
        checks.append(unverified(
            'OA-02', 'Explicit entrepreneur approval',
            'BDJ_APPROVAL_UNAVAILABLE', policy_version=policy_version))
    else:
        state = str(row.get('review_state') or '')
        decision = row.get('decision')
        sources = [str(row.get('proposal_id') or '')]
        if state != _APPROVED:
            checks.append(failed(
                'OA-02', 'Explicit entrepreneur approval',
                'BDJ_PROPOSAL_NOT_APPROVED', sources=sources,
                evidence={'review_state': state}, policy_version=policy_version))
        elif decision is not None and str(decision) != _APPROVED:
            checks.append(unverified(
                'OA-02', 'Explicit entrepreneur approval',
                'BDJ_APPROVAL_INCONSISTENT', sources=sources,
                evidence={'review_state': state, 'decision': str(decision)},
                policy_version=policy_version))
        else:
            checks.append(passed(
                'OA-02', 'Explicit entrepreneur approval', sources=sources,
                evidence={'review_state': state,
                          'decision': None if decision is None else str(decision)},
                policy_version=policy_version))

    disposition = binding.get('disposition')

    # OA-03 — customer-research suitability. The five-way distinction is kept
    # intact: "not suitable" fails, "clarification pending" is a valid decision
    # that cannot proceed, "suitable" passes.
    if disposition in NOT_RESEARCH_SUITABLE:
        checks.append(failed(
            'OA-03', 'Customer-research suitability',
            f'ADMISSION_NOT_RESEARCH_SUITABLE_{disposition}',
            evidence={'disposition': disposition},
            policy_version=policy_version))
    elif disposition in CLARIFICATION_PENDING:
        checks.append(unverified(
            'OA-03', 'Customer-research suitability',
            'ADMISSION_CLARIFICATION_PENDING',
            evidence={'disposition': disposition},
            policy_version=policy_version))
    elif disposition in RESEARCH_SUITABLE:
        checks.append(passed(
            'OA-03', 'Customer-research suitability',
            evidence={'disposition': disposition},
            policy_version=policy_version))
    else:
        # No coded item rule fired: the text resolution carries the decision.
        text = binding.get('text_resolution') or {}
        resolution = str(text.get('resolution') or '')
        if resolution and resolution != 'NOT_CUSTOMER_RESEARCH_SUITABLE':
            checks.append(passed(
                'OA-03', 'Customer-research suitability',
                evidence={'disposition': None, 'resolution': resolution},
                policy_version=policy_version))
        else:
            checks.append(failed(
                'OA-03', 'Customer-research suitability',
                'ADMISSION_NOT_RESEARCH_SUITABLE_NO_ANCHOR',
                evidence={'disposition': None, 'resolution': resolution or None},
                policy_version=policy_version))

    # OA-04 — a clear research purpose and an identified measurement construct.
    # "Purpose" is the objective text; "construct" is the objective the policy
    # matched. An empty purpose can never be measured, whatever else is true.
    objective_text = str((row or {}).get('research_objective') or '').strip()
    bound = binding.get('objective_id')
    text = binding.get('text_resolution') or {}
    if not objective_text:
        checks.append(failed(
            'OA-04', 'Clear research purpose and measurement construct',
            'BDJ_ADMISSION_OBJECTIVE_EMPTY', policy_version=policy_version))
    elif bound:
        checks.append(passed(
            'OA-04', 'Clear research purpose and measurement construct',
            sources=[str(bound)],
            evidence={'construct': str(bound),
                      'text_resolution': text.get('resolution')},
            policy_version=policy_version))
    else:
        checks.append(unverified(
            'OA-04', 'Clear research purpose and measurement construct',
            'ADMISSION_CONSTRUCT_UNRESOLVED',
            evidence={'text_resolution': text.get('resolution'),
                      'text_reason': text.get('reason')},
            policy_version=policy_version))

    # OA-05 — duplicate coverage against O1–O6. Two disagreeing sources about
    # which objective is being admitted is a decision for a human, not an
    # inference for this code, so both the conflict and the ambiguity are held.
    reason = str(binding.get('reason') or '')
    candidates = binding.get('candidate_objectives') or []
    if reason == 'ADMISSION_OBJECTIVE_CONFLICT':
        checks.append(failed(
            'OA-05', 'Duplicate coverage against O1–O6',
            'ADMISSION_OBJECTIVE_CONFLICT',
            sources=[str(item) for item in candidates],
            evidence={'candidate_objectives': [str(item) for item in candidates]},
            policy_version=policy_version))
    elif reason == 'ADMISSION_OBJECTIVE_AMBIGUOUS':
        checks.append(unverified(
            'OA-05', 'Duplicate coverage against O1–O6',
            'ADMISSION_OBJECTIVE_AMBIGUOUS',
            sources=[str(item) for item in candidates],
            evidence={'candidate_objectives': [str(item) for item in candidates]},
            policy_version=policy_version))
    elif bound:
        checks.append(passed(
            'OA-05', 'Duplicate coverage against O1–O6',
            sources=[str(bound)],
            evidence={'covered_by': str(bound)},
            policy_version=policy_version))
    elif disposition == 'NEW_OPTIONAL_CANDIDATE':
        # Survey-suitable but not one of the six fixed objectives: it cannot be
        # admitted as a measurement target until a human registers it.
        checks.append(unverified(
            'OA-05', 'Duplicate coverage against O1–O6',
            'ADMISSION_BINDS_NO_FIXED_OBJECTIVE',
            evidence={'disposition': disposition},
            policy_version=policy_version))
    else:
        checks.append(unverified(
            'OA-05', 'Duplicate coverage against O1–O6',
            'ADMISSION_COVERAGE_UNRESOLVED',
            evidence={'disposition': disposition},
            policy_version=policy_version))

    # OA-06 — the confirmation, revision and BCB binding are the current ones.
    if row is None:
        checks.append(unverified(
            'OA-06', 'Current source references, confirmation and BCB binding',
            'ADMISSION_BINDING_UNAVAILABLE', policy_version=policy_version))
    else:
        row_confirmation = str(row.get('confirmation_id') or '')
        row_assessment = str(row.get('assessment_id') or '')
        row_revision = row.get('confirmation_revision')
        try:
            row_revision = int(row_revision)
        except (TypeError, ValueError):
            row_revision = None
        sources = [row_confirmation, row_assessment]
        if (row_confirmation != str(confirmation_id)
                or row_assessment != str(assessment_id)
                or row_revision != int(revision)):
            checks.append(failed(
                'OA-06', 'Current source references, confirmation and BCB binding',
                'BDJ_ADMISSION_CONFIRMATION_MISMATCH', sources=sources,
                evidence={'proposal_revision': row_revision,
                          'expected_revision': int(revision)},
                policy_version=policy_version))
        elif not context_current:
            checks.append(unverified(
                'OA-06', 'Current source references, confirmation and BCB binding',
                'ADMISSION_CONTEXT_STALE', sources=sources,
                policy_version=policy_version))
        else:
            checks.append(passed(
                'OA-06', 'Current source references, confirmation and BCB binding',
                sources=sources,
                evidence={'confirmation_revision': row_revision},
                policy_version=policy_version))

    # OA-07 — an owner-adopted admission policy. The classification policy in
    # this repository is a candidate (`POLICY_ADOPTED = False`), so this check is
    # the one that legitimately blocks every admission today.
    if policy_adopted:
        checks.append(passed(
            'OA-07', 'Applicable owner-adopted admission policy',
            sources=[policy_version], policy_version=policy_version))
    else:
        checks.append(unverified(
            'OA-07', 'Applicable owner-adopted admission policy',
            'ADMISSION_POLICY_NOT_ADOPTED', sources=[policy_version],
            evidence={'policy_adopted': False},
            policy_version=policy_version))

    return ValidationReport(subject='objective_admission',
                            policy_version=policy_version, checks=checks)


def build_report(conn, proposal_id, *, confirmation_id, assessment_id,
                 revision, context_current, actor_id=None) -> ValidationReport:
    """Load one proposal and evaluate it. Read-only.

    ``objective_admission.policy_binding`` is the evaluator; this function only
    fetches the row and supplies the caller's verified context statement. It
    never records an admission and never commits.
    """
    from sitewise.project1.objective_admission import _load_proposal, policy_binding

    row = _load_proposal(conn, proposal_id)
    if row is None:
        return evaluate(None, binding={}, confirmation_id=confirmation_id,
                        assessment_id=assessment_id, revision=revision,
                        context_current=context_current, policy_adopted=False)

    binding = policy_binding(conn, row)
    stored = _stored_hash(conn, proposal_id)
    if stored:
        row = {**row, 'proposal_hash': stored}
    adopted = bool(binding.get('policy_adopted'))
    return evaluate(row, binding=binding, confirmation_id=confirmation_id,
                    assessment_id=assessment_id, revision=revision,
                    context_current=context_current, policy_adopted=adopted)


def _stored_hash(conn, proposal_id) -> str | None:
    """The hash recorded when the admission was written, if any.

    Absent when no admission row exists yet — which is not a failure of OA-01,
    because the check is about the proposal's current content, not about whether
    an admission was already recorded.
    """
    from sqlalchemy import text
    try:
        row = conn.execute(text("""
            SELECT proposal_hash FROM public.m2_bdj_objective_admissions
            WHERE proposal_id = :pid
            -- The operative admission, not an arbitrary one: a re-admission is
            -- appended, so the newest row is the one whose hash must match.
            ORDER BY created_at DESC
            LIMIT 1
        """), {'pid': str(proposal_id)}).mappings().first()
    except Exception:  # pragma: no cover - schema absence is reported by OA-07
        return None
    return str(row['proposal_hash']) if row and row.get('proposal_hash') else None


def require_admissible(conn, proposal_id, *, confirmation_id, assessment_id,
                       revision, context_current, actor_id=None) -> ValidationReport:
    """Build the report and refuse unless every requirement passed.

    Refusal reuses ``WorkflowHeld`` with the first blocking check's own code, so
    the caller can distinguish "not approved" from "policy not adopted".
    """
    report = build_report(
        conn, proposal_id, confirmation_id=confirmation_id,
        assessment_id=assessment_id, revision=revision,
        context_current=context_current, actor_id=actor_id)
    report.require(fallback='ADMISSION_NOT_ESTABLISHED')
    return report


__all__ = ['REPORT_VERSION', 'evaluate', 'build_report', 'require_admissible']
