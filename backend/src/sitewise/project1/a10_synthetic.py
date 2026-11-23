"""Synthetic admission fixture: a complete, test-only policy and register set.

Purpose
-------
The adapter cannot be verified against the real registers, because none of them
can produce ``ADMITTED`` — that is the point of the real registers. So the
adapter's *logic* is verified here, against inputs that are unmistakably fake:

* every claim carries ``SYNTHETIC_TEST_ONLY`` in its authority basis;
* every gate closure carries the same marker;
* the policy version is ``a10-synthetic-policy/1`` and ``test_only=True``;
* the evaluator must be constructed with ``environment='SYNTHETIC'``.

Why this cannot leak into production
------------------------------------
Three independent barriers, so one mistake is not enough:

1. ``AdmissionEvaluator`` refuses a test-only policy when constructed for
   ``PRODUCTION``.
2. The resulting status is ``ADMITTED_SYNTHETIC`` — a different string from
   ``ADMITTED`` — so no consumer that checks for ``ADMITTED`` treats it as real.
3. ``chart_admission_from_decision`` maps ``ADMITTED_SYNTHETIC`` to ``HELD`` with
   the gate ``A10_SYNTHETIC_NOT_REPORTABLE``, so no bar can render from it.

The fixture also never touches the database: it builds snapshots from literal
counts. There is no code path here that reads or writes a table.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass, replace
from datetime import datetime, timedelta, timezone

from sitewise.project1.a10 import (
    AdmissionPolicy,
    AdmissionRequest,
    Actor,
    EvidenceSnapshot,
    REFUSAL_CODES,
)
from sitewise.project1.a10_claims import AdoptedClaimRegister, Claim
from sitewise.project1.chart_spec import MeasurementCounts

#: The marker every synthetic artifact carries. A grep for it finds exactly the
#: test surface and nothing else.
SYNTHETIC_TEST_IDENTITY = 'A10_SYNTHETIC_TEST_ONLY'
SYNTHETIC_POLICY_VERSION = 'a10-synthetic-policy/1'
#: A synthetic floor. Explicitly NOT a recommendation for SD-11/D-02: it exists
#: so the suppression controls can be exercised, and it is never read by a
#: production evaluator.
SYNTHETIC_FLOOR = 5


def _evidence(label: str) -> str:
    return hashlib.sha256(f'{SYNTHETIC_TEST_IDENTITY}:{label}'.encode()).hexdigest()


@dataclass(frozen=True)
class SyntheticGate:
    gate: str
    closed: bool = True


class SyntheticGateProvider:
    """Reports every gate closed except those named in ``leave_open``.

    ``leave_open`` takes gate *identifiers* (``G04``), because that is what
    ``report_availability`` references.
    """

    def __init__(self, *, leave_open: tuple[str, ...] = ()):
        self._open = frozenset(leave_open)

    def open_gates_for_section(self, section_id: str) -> tuple:
        from sitewise.project1 import a10_gates
        section = a10_gates.section_map().get(section_id)
        if section is None:
            return ()
        return tuple(SyntheticGate(gid) for gid in section.blocking_gate_ids
                     if gid in self._open)


@dataclass(frozen=True)
class SyntheticSection:
    section: str
    state: str
    items: tuple[str, ...]
    blocking_gates: tuple[str, ...] = ()
    requires_v: bool | None = True

    @property
    def reportable_with_valid_evidence(self) -> bool:
        return self.state == 'REPORTABLE_WITH_VALID_EVIDENCE'


class SyntheticSectionProvider:
    """Makes chosen sections reportable, leaving the rest as the contract has them."""

    def __init__(self, *, reportable: dict[str, tuple[str, ...]] | None = None):
        self._reportable = dict(reportable or {'R03': ('Q05',)})

    def section_map(self) -> dict:
        from sitewise.project1 import a10_gates
        out: dict[str, SyntheticSection] = {}
        for section in a10_gates.sections():
            items = self._reportable.get(section.section)
            if items is not None:
                out[section.section] = SyntheticSection(
                    section=section.section,
                    state='REPORTABLE_WITH_VALID_EVIDENCE',
                    items=tuple(items),
                    blocking_gates=section.blocking_gate_ids,
                    requires_v=True)
            else:
                out[section.section] = SyntheticSection(
                    section=section.section, state=section.state,
                    items=section.items, blocking_gates=section.blocking_gate_ids,
                    requires_v=section.requires_v)
        return out


def synthetic_policy(*, floor: int | None = SYNTHETIC_FLOOR,
                     cohort_scope: str = 'SYNTHETIC_COHORT',
                     max_snapshot_age_days: int | None = None) -> AdmissionPolicy:
    return AdmissionPolicy(
        policy_version=SYNTHETIC_POLICY_VERSION,
        floor_value=floor,
        test_only=True,
        test_identity=SYNTHETIC_TEST_IDENTITY,
        expected_cohort_scope=cohort_scope,
        max_snapshot_age_days=max_snapshot_age_days)


def synthetic_claim(*, claim_id: str = 'CLM-Q05-R03', question_id: str = 'Q05',
                    section_id: str = 'R03',
                    construct_id: str = 'D01_CONCEPT_INTENT') -> Claim:
    """An approved-looking claim whose authority basis says it is not real."""
    return Claim(
        claim_id=claim_id,
        question_id=question_id,
        construct_id=construct_id,
        section_id=section_id,
        permitted_claim='Five-category ordinal distribution of stated visit intention.',
        prohibited_inference=('Calibrated probability', 'predicted visits', 'revenue'),
        response_kind='ORDINAL',
        approved=True,
        authority_basis=f'{SYNTHETIC_TEST_IDENTITY}:claim-approval',
        evidence_hash=_evidence(claim_id))


def synthetic_claims() -> AdoptedClaimRegister:
    """Two approved-looking claims: the ordinal item and the matrix item."""
    return AdoptedClaimRegister.from_adoption([
        synthetic_claim(),
        synthetic_claim(claim_id='CLM-Q10-R07', question_id='Q10',
                        section_id='R07', construct_id='D04_FEATURE_IMPORTANCE'),
    ])


def synthetic_snapshot(*, question_id: str = 'Q05', v: int = 40,
                       counts: dict[str, int] | None = None,
                       owner_id: str = 'synthetic-owner',
                       consent_scope: str = 'RESEARCH_REPORT_PUBLICATION',
                       cohort_scope: str = 'SYNTHETIC_COHORT',
                       context_hash: str | None = None,
                       feature_slot: str | None = None) -> EvidenceSnapshot:
    """A snapshot built from literal counts. Never from a database."""
    from sitewise.project1.explanation_registry import load_registry
    reg = load_registry()
    if counts is None:
        # A deterministic five-bucket split of ``v`` with one deliberately small
        # cell, so the suppression controls have something to act on. Derived
        # from ``v`` rather than hardcoded, so a small denominator still yields a
        # distribution that sums to it.
        small = max(0, v // 10)
        rest = v - small
        parts = [rest // 4 + (1 if i < rest % 4 else 0) for i in range(4)]
        counts = dict(zip(('DEF_YES', 'PROB_YES', 'NEUTRAL', 'PROB_NO'), parts))
        counts['DEF_NO'] = small
    option_counts = dict(counts)
    total = sum(option_counts.values())
    if total > v:
        raise ValueError('SYNTHETIC_OPTION_COUNTS_EXCEED_V')
    return EvidenceSnapshot(
        snapshot_id=f'synthetic-snapshot-{question_id}',
        fingerprint=_evidence(f'fingerprint:{question_id}'),
        context_hash=context_hash or _evidence(f'context:{question_id}'),
        question_id=question_id,
        question_version=reg.instrument_version,
        instrument_version=reg.instrument_version,
        instrument_sha256=reg.instrument_sha256,
        option_bank_version='synthetic-bank/1',
        stimulus_hash=_evidence('stimulus'),
        concept_version='synthetic-concept/1',
        cohort_id='synthetic-cohort',
        cohort_scope=cohort_scope,
        cutoff=datetime(2026, 11, 1, tzinfo=timezone.utc),
        measurement=MeasurementCounts(I='UNKNOWN_NOT_ENUMERABLE', Q=v + 10,
                                      S=v + 6, A=v + 2, V=v),
        owner_id=owner_id,
        assessment_id='synthetic-assessment',
        consent_scope=consent_scope,
        research_mode='SYNTHETIC',
        ruleset_id='synthetic-ruleset/1',
        ruleset_hash=_evidence('ruleset'),
        option_counts=option_counts,
        feature_slot=feature_slot)


def synthetic_actor(*, roles: frozenset[str] | None = None,
                    expires_at: datetime | None = None) -> Actor:
    return Actor(
        actor_id='synthetic-admission-officer',
        roles=roles or frozenset({'REPORT_ADMISSION'}),
        authority_basis=f'{SYNTHETIC_TEST_IDENTITY}:actor',
        expires_at=expires_at)


def synthetic_request(*, section_id: str = 'R03', claim_id: str = 'CLM-Q05-R03',
                      snapshot: EvidenceSnapshot | None = None,
                      policy: AdmissionPolicy | None = None,
                      actor: Actor | None = None,
                      **overrides) -> AdmissionRequest:
    """A complete synthetic request. ``overrides`` mutate one field at a time."""
    snapshot = snapshot or synthetic_snapshot()
    policy = policy or synthetic_policy()
    request = AdmissionRequest(
        section_id=section_id,
        claim_id=claim_id,
        snapshot=snapshot,
        actor=actor or synthetic_actor(),
        requesting_owner_id=snapshot.owner_id,
        policy=policy,
        synthetic_test_identity=SYNTHETIC_TEST_IDENTITY,
        expected_context_hash=snapshot.context_hash)
    return replace(request, **overrides) if overrides else request


def synthetic_evaluator(**kwargs):
    """An evaluator wired entirely to synthetic registers."""
    from sitewise.project1.a10 import AdmissionEvaluator
    return AdmissionEvaluator(
        claims=kwargs.pop('claims', None) or synthetic_claims(),
        policy=kwargs.pop('policy', None) or synthetic_policy(),
        gate_provider=kwargs.pop('gate_provider', None) or SyntheticGateProvider(),
        section_provider=kwargs.pop('section_provider', None) or SyntheticSectionProvider(),
        environment='SYNTHETIC',
        **kwargs)


def future(minutes: int = 60) -> datetime:
    return datetime.now(timezone.utc) + timedelta(minutes=minutes)


def past(minutes: int = 60) -> datetime:
    return datetime.now(timezone.utc) - timedelta(minutes=minutes)


__all__ = [
    'REFUSAL_CODES', 'SYNTHETIC_FLOOR', 'SYNTHETIC_POLICY_VERSION',
    'SYNTHETIC_TEST_IDENTITY', 'SyntheticGate', 'SyntheticGateProvider',
    'SyntheticSection', 'SyntheticSectionProvider', 'future', 'past',
    'synthetic_actor', 'synthetic_claim', 'synthetic_claims', 'synthetic_evaluator',
    'synthetic_policy', 'synthetic_request', 'synthetic_snapshot',
]
