"""Versioned measurement specifications and the approved-measurement resolver.

The problem this solves
-----------------------
Direct-QG 2.0 generates a candidate from confirmed facts and does not require a
measurement (``qg_contract.py``). That is correct for *drafting*, but it leaves
one question unanswered: what makes a drafted question **fieldable**? Without an
answer, any model output looks equally usable, and "the JSON validated" silently
becomes "the measurement is approved".

This module answers it with three states and one rule:

* ``REUSE_APPROVED_MEASUREMENT`` — an approved specification exists for the
  objective, its declared stimulus parameters are all present in the verified
  source, and its response format is supported. Only this state may proceed to a
  QG eligibility check.
* ``PROPOSE_MEASUREMENT_EXTENSION`` — the objective is relevant but no approved
  specification exists. A **candidate** specification may be drafted for
  scientific review. A candidate is never fieldable and never raises coverage.
* ``ABSTAIN_NO_VALID_MEASUREMENT`` — the measurement cannot be specified safely,
  because a mandatory stimulus is missing and inventing it is forbidden (the
  canonical case is an exact price that the entrepreneur has not decided).

Approval is derived, never declared
-----------------------------------
A specification's ``status`` column is a lifecycle label. Fieldability is
computed from ``m2_measurement_decisions``: a ``PRODUCTION`` ``APPROVE`` by a
``SCIENTIFIC_REVIEWER`` whose stored ``content_digest`` still matches the
specification. A ``SYNTHETIC_TEST`` decision never counts — that would be the
exact "simulated success presented as approval" failure the directive forbids.

Coverage on the disposable cluster is therefore **0 of 6**, and this module
reports that as a count rather than an opinion.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Protocol

from sqlalchemy import text

from sitewise.project1.contracts import WorkflowHeld, digest

#: Version of the resolver rule set. Changing an outcome rule is a new version.
RESOLVER_VERSION = 'P1-MEASUREMENT-RESOLVER-1.0'

#: Version of the specification contract (matches
#: ``contracts/measurement_spec_candidate.example.json``).
SPEC_CONTRACT_VERSION = 'project1-measurement-spec/1-candidate'

#: The five structured formats this phase can author a candidate in. Structural
#: capability is not fielding authorization: ``qg_fixed_options`` keeps
#: ``VERIFIED_RESPONDENT_FORMATS`` empty until a respondent round trip is
#: actually verified.
CANDIDATE_FORMATS = frozenset({
    'SINGLE_CHOICE', 'BINARY_CHOICE', 'MULTIPLE_CHOICE',
    'ORDERED_SCALE', 'NUMERIC_RANGE_OPTIONS',
})

REUSE = 'REUSE_APPROVED_MEASUREMENT'
#: A measurement approved **only** at ``SYNTHETIC_TEST`` scope. It may drive a
#: lab candidate so the adapter can be exercised end to end, and it never counts
#: as scientific coverage or authorises fielding.
REUSE_SYNTHETIC = 'REUSE_SYNTHETIC_TEST_MEASUREMENT'
PROPOSE = 'PROPOSE_MEASUREMENT_EXTENSION'
ABSTAIN = 'ABSTAIN_NO_VALID_MEASUREMENT'
OUTCOMES = (REUSE, REUSE_SYNTHETIC, PROPOSE, ABSTAIN)

#: Which verified stimulus parameters each objective's measurement requires
#: before a question may be drafted. These are *requirements*, not values: a
#: missing entry causes an abstention, never a default.
REQUIRED_PARAMETERS: dict[str, tuple[str, ...]] = {
    'O1': (),
    'O2': ('product_name',),
    'O3': ('product_name', 'size_description', 'price_myr'),
    'O4': ('service_modes',),
    'O5': ('experience_features',),
    'O6': (),
}

#: Parameters that must never be invented. Named separately from
#: ``REQUIRED_PARAMETERS`` because the *reason* for the abstention is part of
#: the answer: a missing price is a business decision, not a modelling gap.
NEVER_INVENTED = frozenset({'price_myr', 'location', 'market_size'})


@dataclass(frozen=True)
class MeasurementSpec:
    measurement_id: str
    measurement_version: str
    objective_id: str
    construct: str
    population: str
    status: str
    response_format: str
    allowed_parameter_names: tuple[str, ...]
    spec: dict
    content_digest: str
    owner_user_id: str

    @property
    def key(self) -> tuple[str, str]:
        return (self.measurement_id, self.measurement_version)


class MeasurementStore(Protocol):
    """Read port. Implementations must not be able to approve anything."""

    def specs(self, objective_id: str) -> list[MeasurementSpec]: ...

    def decisions(self, measurement_id: str,
                  measurement_version: str) -> list[dict]: ...


class InMemoryMeasurementStore:
    """Test double. Explicitly labelled so it cannot be mistaken for the DB."""

    scope = 'IN_MEMORY_TEST_DOUBLE'

    def __init__(self, specs=(), decisions=()):
        self._specs = list(specs)
        self._decisions = list(decisions)

    def specs(self, objective_id: str) -> list[MeasurementSpec]:
        return [s for s in self._specs if s.objective_id == objective_id]

    def decisions(self, measurement_id: str, measurement_version: str) -> list[dict]:
        return [d for d in self._decisions
                if d['measurement_id'] == measurement_id
                and d['measurement_version'] == measurement_version]


class PostgresMeasurementStore:
    """Owner-scoped read of ``public.m2_measurement_specs`` / ``..._decisions``."""

    scope = 'POSTGRES'

    def __init__(self, engine, actor_id):
        self.engine = engine
        self.actor_id = actor_id

    def _bind(self, conn):
        from sitewise.repositories.m2_context_bindings import bind_restricted_principal
        from sitewise.services.business_context_v1 import ContextRefused
        try:
            bind_restricted_principal(conn, self.actor_id)
        except ContextRefused as exc:
            raise WorkflowHeld(exc.code) from None

    def specs(self, objective_id: str) -> list[MeasurementSpec]:
        with self.engine.connect() as conn:
            self._bind(conn)
            rows = conn.execute(text("""
                SELECT measurement_id, measurement_version, objective_id, construct,
                       population, status, response_format, allowed_parameter_names,
                       spec_json, content_digest, owner_user_id
                FROM public.m2_measurement_specs
                WHERE objective_id = :o AND owner_user_id = :owner
                ORDER BY created_at DESC
            """), {'o': objective_id, 'owner': str(self.actor_id)}).mappings().all()
        return [_spec_from_row(row) for row in rows]

    def decisions(self, measurement_id: str, measurement_version: str) -> list[dict]:
        with self.engine.connect() as conn:
            self._bind(conn)
            rows = conn.execute(text("""
                SELECT decision, authority, actor_user_id, scope, content_digest,
                       rationale, decided_at
                FROM public.m2_measurement_decisions
                WHERE measurement_id = :m AND measurement_version = :v
                ORDER BY decided_at
            """), {'m': measurement_id, 'v': measurement_version}).mappings().all()
        return [dict(row) for row in rows]


def _spec_from_row(row) -> MeasurementSpec:
    raw = row['spec_json']
    spec = json.loads(raw) if isinstance(raw, str) else raw
    params = row['allowed_parameter_names']
    if isinstance(params, str):
        params = [p for p in params.strip('{}').split(',') if p]
    return MeasurementSpec(
        measurement_id=row['measurement_id'],
        measurement_version=row['measurement_version'],
        objective_id=row['objective_id'],
        construct=row['construct'],
        population=row['population'],
        status=row['status'],
        response_format=row['response_format'],
        allowed_parameter_names=tuple(params or ()),
        spec=spec,
        content_digest=row['content_digest'],
        owner_user_id=str(row['owner_user_id']),
    )


def approval_state(spec: MeasurementSpec, decisions: list[dict],
                   *, synthetic_scope: bool = False) -> dict:
    """Derive fieldability from decision records, never from the label.

    A specification is fieldable only when:

    * a ``PRODUCTION`` ``APPROVE`` exists from a ``SCIENTIFIC_REVIEWER``,
    * the digest that decision was made about still matches the specification,
    * no later ``PRODUCTION`` ``RETIRE`` exists,
    * and an ``OWNER_APPROVER`` has also approved it (two distinct authorities).

    ``synthetic_scope`` additionally recognises a ``SYNTHETIC_TEST`` reviewer
    plus owner approval, which is enough to *exercise the engineering path* and
    never enough to claim scientific coverage. That distinction is returned as
    ``synthetic_only`` so a caller cannot confuse the two.
    """
    production = [d for d in decisions if d['scope'] == 'PRODUCTION']
    reviewer = [d for d in production
                if d['authority'] == 'SCIENTIFIC_REVIEWER'
                and d['decision'] == 'APPROVE'
                and str(d['content_digest']) == spec.content_digest]
    owner = [d for d in production
             if d['authority'] == 'OWNER_APPROVER'
             and d['decision'] == 'APPROVE'
             and str(d['content_digest']) == spec.content_digest]
    retired = [d for d in production if d['decision'] == 'RETIRE']
    synthetic_only = bool(decisions) and not production
    approved = bool(reviewer) and bool(owner) and not retired

    lab_reviewer = [d for d in decisions
                    if d['scope'] == 'SYNTHETIC_TEST'
                    and d['authority'] == 'SCIENTIFIC_REVIEWER'
                    and d['decision'] == 'APPROVE'
                    and str(d['content_digest']) == spec.content_digest]
    lab_owner = [d for d in decisions
                 if d['scope'] == 'SYNTHETIC_TEST'
                 and d['authority'] == 'OWNER_APPROVER'
                 and d['decision'] == 'APPROVE'
                 and str(d['content_digest']) == spec.content_digest]
    lab_approved = (not approved and bool(lab_reviewer) and bool(lab_owner)
                    and synthetic_scope)

    if approved:
        reason = 'SCIENTIFIC_AND_OWNER_APPROVED'
    elif lab_approved:
        reason = 'SYNTHETIC_TEST_APPROVAL_LAB_ONLY'
    elif synthetic_only:
        reason = 'SYNTHETIC_TEST_DECISION_DOES_NOT_APPROVE'
    elif reviewer and not owner:
        reason = 'OWNER_APPROVAL_MISSING'
    elif retired:
        reason = 'MEASUREMENT_RETIRED'
    elif not decisions:
        reason = 'NO_APPROVAL_DECISION'
    else:
        reason = 'APPROVAL_DIGEST_MISMATCH'
    return {
        'scientifically_approved': approved,
        'synthetic_test_approved': lab_approved,
        'approval_reason': reason,
        'reviewer_decision_count': len(reviewer),
        'owner_decision_count': len(owner),
        'synthetic_only': synthetic_only,
    }


def _missing_parameters(objective_id: str, stimulus: dict) -> list[str]:
    required = REQUIRED_PARAMETERS.get(objective_id, ())
    return [name for name in required
            if stimulus.get(name) in (None, '')]


def resolve(store: MeasurementStore, objective_id: str, *,
            stimulus: dict | None = None,
            supported_formats: frozenset[str] = CANDIDATE_FORMATS,
            allow_synthetic_test_approval: bool = False) -> dict:
    """Resolve one objective to a measurement outcome.

    Ordered so the most specific refusal wins: an objective that cannot be
    measured safely abstains even if an approved specification exists, because
    generating a question with an invented stimulus would be worse than
    generating nothing.

    ``allow_synthetic_test_approval`` is only ever set by the synthetic lab
    adapter. It permits a ``SYNTHETIC_TEST``-approved specification to drive a
    candidate and returns ``REUSE_SYNTHETIC`` so the caller can label it. It does
    not change ``scientifically_approved``, which stays false.
    """
    stimulus = dict(stimulus or {})
    missing = _missing_parameters(objective_id, stimulus)
    specs = store.specs(objective_id)
    considered = []
    for spec in specs:
        state = approval_state(spec, store.decisions(*spec.key),
                              synthetic_scope=allow_synthetic_test_approval)
        considered.append({
            'measurement_id': spec.measurement_id,
            'measurement_version': spec.measurement_version,
            'status': spec.status,
            'response_format': spec.response_format,
            **state,
        })

    if missing:
        # A required stimulus is absent. For a never-invent parameter this is a
        # business decision, so it is an abstention rather than a proposal.
        blocking = [m for m in missing if m in NEVER_INVENTED]
        return {
            'resolver_version': RESOLVER_VERSION,
            'objective_id': objective_id,
            'outcome': ABSTAIN,
            'reason': ('REQUIRED_STIMULUS_NOT_INVENTED' if blocking
                       else 'REQUIRED_STIMULUS_MISSING'),
            'missing_parameters': missing,
            'invented_parameter_refused': blocking,
            'measurement_id': None,
            'measurement_version': None,
            'scientifically_approved': False,
            'considered_specifications': considered,
            'fielding_authorized': False,
        }

    for spec in specs:
        state = approval_state(spec, store.decisions(*spec.key),
                              synthetic_scope=allow_synthetic_test_approval)
        if not (state['scientifically_approved']
                or state['synthetic_test_approved']):
            continue
        if spec.response_format not in supported_formats:
            continue
        return {
            'resolver_version': RESOLVER_VERSION,
            'objective_id': objective_id,
            'outcome': (REUSE if state['scientifically_approved']
                        else REUSE_SYNTHETIC),
            'reason': state['approval_reason'],
            'missing_parameters': [],
            'measurement_id': spec.measurement_id,
            'measurement_version': spec.measurement_version,
            'content_digest': spec.content_digest,
            'response_format': spec.response_format,
            'allowed_parameter_names': list(spec.allowed_parameter_names),
            'population': spec.population,
            'construct': spec.construct,
            'spec': spec.spec,
            'scientifically_approved': state['scientifically_approved'],
            'synthetic_test_scope': not state['scientifically_approved'],
            'considered_specifications': considered,
            # Even an approved measurement does not authorise fielding here;
            # publication and fielding are separate owner gates.
            'fielding_authorized': False,
        }

    return {
        'resolver_version': RESOLVER_VERSION,
        'objective_id': objective_id,
        'outcome': PROPOSE,
        'reason': ('NO_APPROVED_MEASUREMENT' if not considered
                   else 'NO_APPLICABLE_APPROVED_MEASUREMENT'),
        'missing_parameters': [],
        'measurement_id': None,
        'measurement_version': None,
        'scientifically_approved': False,
        'considered_specifications': considered,
        'candidate_extension_allowed': True,
        'fielding_authorized': False,
    }


def draft_candidate_spec(objective_id: str, *, construct: str, population: str,
                         response_format: str,
                         allowed_parameter_names=(),
                         response: dict | None = None,
                         stimulus: dict | None = None,
                         limitations: str = '') -> dict:
    """Author a **candidate** specification for scientific review.

    ``not_approved`` and ``scientific_approval_receipt = None`` are not
    decoration: they are the fields a later reader checks to see that this
    document confers nothing. No parameter is filled in from anything except
    ``stimulus``, and a missing one stays missing.
    """
    if response_format not in CANDIDATE_FORMATS:
        raise WorkflowHeld('UNSUPPORTED_FORMAT')
    if not construct.strip() or not population.strip():
        raise WorkflowHeld('QG_MEASUREMENT_CONTEXT_REQUIRED')
    stimulus = dict(stimulus or {})
    unknown = set(allowed_parameter_names) - set(REQUIRED_PARAMETERS.get(objective_id, ())) \
        - {'product_name', 'size_description', 'price_myr', 'service_modes',
           'experience_features', 'concept_name'}
    if unknown:
        # A parameter slot the policy does not declare is a way to smuggle an
        # undeclared substitution into an approved measurement.
        raise WorkflowHeld('MEASUREMENT_PARAMETER_UNDECLARED')
    body = {
        'contract_version': SPEC_CONTRACT_VERSION,
        'status': 'CANDIDATE_REVIEW',
        'not_approved': True,
        'objective_id': objective_id,
        'construct': construct,
        'population': population,
        'response_format': response_format,
        'allowed_parameter_names': list(allowed_parameter_names),
        'stimulus_values_supplied': {k: stimulus[k] for k in stimulus
                                     if k in allowed_parameter_names},
        'response': response,
        'limitations': limitations,
        'pretest_receipt': None,
        'scientific_approval_receipt': None,
        'privacy_note': ('Candidate specification only. No respondent data, no '
                         'fielding authorization and no scientific acceptance '
                         'is represented.'),
    }
    return body


def spec_digest(spec_body: dict) -> str:
    """Canonical digest used as ``content_digest`` on insert."""
    return digest(spec_body)


__all__ = ['ABSTAIN', 'CANDIDATE_FORMATS', 'InMemoryMeasurementStore',
           'MeasurementSpec', 'MeasurementStore', 'NEVER_INVENTED', 'OUTCOMES',
           'PROPOSE', 'PostgresMeasurementStore', 'REQUIRED_PARAMETERS', 'REUSE',
           'RESOLVER_VERSION', 'SPEC_CONTRACT_VERSION', 'approval_state',
           'draft_candidate_spec', 'resolve', 'spec_digest']
