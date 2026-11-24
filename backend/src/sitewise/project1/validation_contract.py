"""One structured result type for every PROJECT1 eligibility check.

Why this exists
---------------
The admission, measurement and Direct-QG gates each already refuse correctly, but
each refuses by raising ``WorkflowHeld(<code>)``. A single exception is enough to
stop an operation and it is *not* enough to explain one: a caller cannot tell
which of seven admission requirements failed, cannot see the source versions it
was judged against, and cannot distinguish "this is definitively wrong" from "we
could not verify it".

This module adds that explanation without adding a second decision mechanism.
It does not decide anything. It records what an existing verifier concluded, so
the same conclusion can be reported to an operator and enforced by
:meth:`ValidationReport.require`.

Three statuses, and the distinction that matters
------------------------------------------------
``PASS``       the requirement was satisfied by the records examined.
``FAIL``       the requirement is definitively not satisfied.
``UNVERIFIED`` the requirement could not be established from available records.

``UNVERIFIED`` is deliberately not a soft ``PASS``. It exists for the case that
actually occurs in this system: a policy that has not been adopted, or a
measurement specification that does not exist. Treating those as failures would
misreport them as defects; treating them as passes would manufacture authority.
Both ``FAIL`` and ``UNVERIFIED`` block the protected operation, so the caller
never has to interpret the difference — only the operator does.

What this module must never become
----------------------------------
A check does not create an approval, an admission, a measurement, an attempt or
an authorisation record. :meth:`ValidationReport.require` can only *stop* work.
Nothing here returns ``ADMITTED``, and nothing here writes.
"""
from __future__ import annotations

from typing import Literal

from sitewise.project1.contracts import StrictModel, WorkflowHeld

#: The three statuses. ``UNVERIFIED`` reuses the vocabulary already present in
#: ``project1.question_bank`` so the codebase keeps one word for "no decision was
#: derived", rather than growing a second synonym.
PASS = 'PASS'
FAIL = 'FAIL'
UNVERIFIED = 'UNVERIFIED'
STATUSES = (PASS, FAIL, UNVERIFIED)

Status = Literal['PASS', 'FAIL', 'UNVERIFIED']


class ValidationCheck(StrictModel):
    """One independently verifiable condition.

    ``reason_code`` is empty exactly when ``status`` is ``PASS``: a passing check
    has nothing to explain, and an empty code on a blocking check would be a
    reporting defect rather than a lenient result.
    """

    check_id: str
    title: str
    status: Status
    reason_code: str = ''
    #: The identifiers and versions the verifier actually read. Free strings so a
    #: check can name a proposal id, an objective id, a context hash or an
    #: attempt number without a union type.
    sources: list[str] = []
    #: Bounded, JSON-safe facts that justify the status. Never raw provider
    #: output and never an exception message.
    evidence: dict = {}
    policy_version: str = ''

    def blocks(self) -> bool:
        """A check blocks unless it passed.

        ``UNVERIFIED`` blocks on purpose: an unverifiable prerequisite is not
        weaker than a failed one for the purpose of authorising work.
        """
        return self.status != PASS


class ValidationReport(StrictModel):
    """The checks for one decision, plus the aggregate they imply."""

    subject: str
    policy_version: str = ''
    checks: list[ValidationCheck] = []

    @property
    def status(self) -> str:
        """Aggregate status over the checks.

        Any ``FAIL`` dominates, because a definite failure is more informative
        than an unknown. With no ``FAIL``, any ``UNVERIFIED`` yields
        ``UNVERIFIED``. All ``PASS`` (including an empty list) yields ``PASS``.
        """
        if any(check.status == FAIL for check in self.checks):
            return FAIL
        if any(check.status == UNVERIFIED for check in self.checks):
            return UNVERIFIED
        return PASS

    def blocking(self) -> list[ValidationCheck]:
        return [check for check in self.checks if check.blocks()]

    def first_reason(self) -> str:
        """The reason code a refusal should carry.

        The first blocking check in declaration order wins, so the code a caller
        sees is stable and matches the order an operator reads the matrix in.
        """
        blocking = self.blocking()
        if not blocking:
            return ''
        return blocking[0].reason_code or f'{blocking[0].check_id}_UNVERIFIED'

    def require(self, *, fallback: str = 'ELIGIBILITY_NOT_ESTABLISHED') -> None:
        """Refuse unless every check passed.

        Raises the existing ``WorkflowHeld`` so this composes with every guard
        already written against that exception. The code is the failing check's
        own stable code, never a generic one, so the caller keeps the ability to
        tell the conditions apart.
        """
        blocking = self.blocking()
        if not blocking:
            return
        raise WorkflowHeld(self.first_reason() or fallback)

    def as_dict(self) -> dict:
        return {
            'subject': self.subject,
            'policy_version': self.policy_version,
            'status': self.status,
            'checks': [check.model_dump() for check in self.checks],
        }


def check(check_id: str, title: str, *, status: str, reason_code: str = '',
          sources: list[str] | None = None, evidence: dict | None = None,
          policy_version: str = '') -> ValidationCheck:
    """Construct one check, rejecting an unexplained blocking result.

    The guard is here rather than in the model because a ``PASS`` legitimately
    has no code while a blocking check without one is a defect: it would make
    :meth:`ValidationReport.require` raise a code the caller cannot interpret.
    """
    if status not in STATUSES:
        raise ValueError(f'Unknown validation status {status!r}.')
    if status != PASS and not reason_code:
        raise ValueError(
            f'Check {check_id} is {status} but names no reason code.')
    if status == PASS and reason_code:
        raise ValueError(
            f'Check {check_id} passed but carries reason {reason_code!r}.')
    return ValidationCheck(
        check_id=check_id, title=title, status=status, reason_code=reason_code,
        sources=list(sources or []), evidence=dict(evidence or {}),
        policy_version=policy_version)


def passed(check_id: str, title: str, *, sources: list[str] | None = None,
           evidence: dict | None = None, policy_version: str = '') -> ValidationCheck:
    return check(check_id, title, status=PASS, sources=sources,
                 evidence=evidence, policy_version=policy_version)


def failed(check_id: str, title: str, reason_code: str, *,
           sources: list[str] | None = None, evidence: dict | None = None,
           policy_version: str = '') -> ValidationCheck:
    return check(check_id, title, status=FAIL, reason_code=reason_code,
                 sources=sources, evidence=evidence, policy_version=policy_version)


def unverified(check_id: str, title: str, reason_code: str, *,
               sources: list[str] | None = None, evidence: dict | None = None,
               policy_version: str = '') -> ValidationCheck:
    return check(check_id, title, status=UNVERIFIED, reason_code=reason_code,
                 sources=sources, evidence=evidence, policy_version=policy_version)


__all__ = ['PASS', 'FAIL', 'UNVERIFIED', 'STATUSES', 'ValidationCheck',
           'ValidationReport', 'check', 'passed', 'failed', 'unverified']
