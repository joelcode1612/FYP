"""Structured measurement-resolution validation (MV-01 … MV-11).

``measurement_library.resolve`` already decides which measurement applies and
refuses to invent one. Its answer is a single ``outcome`` plus a ``reason``. This
module reports the requirements that produced that answer, separately and with
the specification they were judged against.

Four outcomes are kept apart, because they mean four different things to the
person reading them:

``REUSE``             an approved specification applies — measurement authorised.
``REUSE_SYNTHETIC``   only a ``SYNTHETIC_TEST``-scoped approval applies. It can
                      drive a lab candidate; it is not scientific approval and it
                      does not authorise fielding.
``PROPOSE``           no approved specification applies. A draft extension may be
                      proposed, but a draft is not a measurement and must never
                      self-approve.
``ABSTAIN``           a required stimulus is missing. For a parameter the policy
                      forbids inventing this is a business decision, not a gap in
                      the code.

Nothing here approves a measurement, writes a specification, or fills in a
parameter. ``draft_candidate_spec`` remains the only producer of a draft, and a
draft still requires an owner decision before it becomes applicable.
"""
from __future__ import annotations

from sitewise.project1.measurement_library import (
    ABSTAIN,
    CANDIDATE_FORMATS,
    PROPOSE,
    REQUIRED_PARAMETERS,
    REUSE,
    REUSE_SYNTHETIC,
)
from sitewise.project1.validation_contract import (
    ValidationReport,
    failed,
    passed,
    unverified,
)

REPORT_VERSION = 'P1-MEASUREMENT-VALIDATION-1.0'

#: Formats that carry an ordered or numeric boundary set. A specification in one
#: of these formats describes an amount or a position, so an absent reference
#: period makes the answer uninterpretable rather than merely imprecise.
_PERIOD_SENSITIVE = frozenset({'NUMERIC_RANGE_OPTIONS', 'ORDERED_SCALE'})

_APPLIES = (REUSE, REUSE_SYNTHETIC)


def _text(spec, name, default=''):
    value = getattr(spec, name, None)
    return value if isinstance(value, str) else default


def _spec_body(spec) -> dict:
    body = getattr(spec, 'spec', None)
    return body if isinstance(body, dict) else {}


def evaluate(resolution: dict, spec, *, supported_formats=frozenset(CANDIDATE_FORMATS),
             period_required: bool = False) -> ValidationReport:
    """Evaluate the eleven measurement requirements.

    ``resolution`` is the dict returned by ``measurement_library.resolve`` and
    ``spec`` is the ``MeasurementSpec`` it selected (``None`` when it selected
    none). Pure: no I/O, no writes.
    """
    objective_id = str(resolution.get('objective_id') or '')
    outcome = str(resolution.get('outcome') or '')
    resolver_version = str(resolution.get('resolver_version') or '')
    sources = [objective_id] if objective_id else []
    if spec is not None:
        sources.append(f'{_text(spec, "measurement_id")}@'
                       f'{_text(spec, "measurement_version")}')
    checks = []

    # MV-01 — an applicable specification exists.
    considered = resolution.get('considered_specifications') or []
    if outcome in _APPLIES:
        checks.append(passed(
            'MV-01', 'Applicable measurement specification exists',
            sources=sources, evidence={'outcome': outcome},
            policy_version=resolver_version))
    elif outcome == ABSTAIN:
        checks.append(failed(
            'MV-01', 'Applicable measurement specification exists',
            'MEASUREMENT_NOT_RESOLVED_STIMULUS_MISSING', sources=sources,
            evidence={'outcome': outcome,
                      'missing_parameters': resolution.get('missing_parameters') or [],
                      'invented_parameter_refused':
                          resolution.get('invented_parameter_refused') or []},
            policy_version=resolver_version))
    elif not considered:
        checks.append(failed(
            'MV-01', 'Applicable measurement specification exists',
            'MEASUREMENT_NOT_FOUND', sources=sources,
            evidence={'outcome': outcome, 'considered': 0},
            policy_version=resolver_version))
    else:
        checks.append(failed(
            'MV-01', 'Applicable measurement specification exists',
            'MEASUREMENT_NOT_APPROVED', sources=sources,
            evidence={'outcome': outcome, 'considered': len(considered)},
            policy_version=resolver_version))

    # MV-02 — the specification measures the construct the objective names.
    if spec is None:
        checks.append(unverified(
            'MV-02', 'Measurement construct matches the objective',
            'MEASUREMENT_CONSTRUCT_UNAVAILABLE', sources=sources,
            policy_version=resolver_version))
    else:
        construct = _text(spec, 'construct')
        spec_objective = _text(spec, 'objective_id')
        if not construct:
            checks.append(failed(
                'MV-02', 'Measurement construct matches the objective',
                'MEASUREMENT_CONSTRUCT_MISSING', sources=sources,
                policy_version=resolver_version))
        elif spec_objective and spec_objective != objective_id:
            checks.append(failed(
                'MV-02', 'Measurement construct matches the objective',
                'MEASUREMENT_OBJECTIVE_MISMATCH', sources=sources,
                evidence={'spec_objective': spec_objective},
                policy_version=resolver_version))
        else:
            checks.append(passed(
                'MV-02', 'Measurement construct matches the objective',
                sources=sources, evidence={'construct': construct},
                policy_version=resolver_version))

    # MV-03 — the intended respondent population is defined. A measurement with
    # no population cannot say who was asked, so its answer is not evidence.
    population = _text(spec, 'population') if spec is not None else ''
    if spec is None:
        checks.append(unverified(
            'MV-03', 'Intended respondent population defined',
            'MEASUREMENT_POPULATION_UNAVAILABLE', sources=sources,
            policy_version=resolver_version))
    elif not population.strip():
        checks.append(failed(
            'MV-03', 'Intended respondent population defined',
            'MEASUREMENT_POPULATION_MISSING', sources=sources,
            policy_version=resolver_version))
    else:
        checks.append(passed(
            'MV-03', 'Intended respondent population defined', sources=sources,
            evidence={'population': population}, policy_version=resolver_version))

    # MV-04 — the fixed-option response format is one the candidate path can
    # author. Structural capability is not fielding authority: the respondent
    # round trip is a separate, still-empty gate.
    response_format = _text(spec, 'response_format') if spec is not None else ''
    if spec is None:
        checks.append(unverified(
            'MV-04', 'Supported fixed-option response format',
            'MEASUREMENT_FORMAT_UNAVAILABLE', sources=sources,
            policy_version=resolver_version))
    elif response_format not in supported_formats:
        checks.append(failed(
            'MV-04', 'Supported fixed-option response format',
            'MEASUREMENT_FORMAT_UNSUPPORTED', sources=sources,
            evidence={'response_format': response_format,
                      'supported': sorted(supported_formats)},
            policy_version=resolver_version))
    else:
        checks.append(passed(
            'MV-04', 'Supported fixed-option response format', sources=sources,
            evidence={'response_format': response_format},
            policy_version=resolver_version))

    # MV-05 — the specification has a source identity. The content digest is what
    # binds the reviewed text to the bytes that are used.
    digest = _text(spec, 'content_digest') if spec is not None else ''
    if spec is None:
        checks.append(unverified(
            'MV-05', 'Measurement-source reference recorded',
            'MEASUREMENT_SOURCE_UNAVAILABLE', sources=sources,
            policy_version=resolver_version))
    elif not digest:
        checks.append(failed(
            'MV-05', 'Measurement-source reference recorded',
            'MEASUREMENT_SOURCE_MISSING', sources=sources,
            policy_version=resolver_version))
    else:
        checks.append(passed(
            'MV-05', 'Measurement-source reference recorded', sources=sources,
            evidence={'content_digest': digest}, policy_version=resolver_version))

    # MV-06 — every business-context parameter the policy requires is present.
    # A missing required value is an abstention, never a substituted guess.
    missing = resolution.get('missing_parameters') or []
    required = list(REQUIRED_PARAMETERS.get(objective_id, ())) if objective_id else []
    if missing:
        checks.append(unverified(
            'MV-06', 'Required business-context parameters supplied',
            'MEASUREMENT_PARAMETERS_MISSING', sources=sources,
            evidence={'missing_parameters': list(missing),
                      'required_parameters': required},
            policy_version=resolver_version))
    else:
        checks.append(passed(
            'MV-06', 'Required business-context parameters supplied',
            sources=sources, evidence={'required_parameters': required},
            policy_version=resolver_version))

    # MV-07 — a reference period, where the format makes one necessary.
    body = _spec_body(spec)
    reference_period = str(body.get('reference_period') or '')
    needs_period = period_required or response_format in _PERIOD_SENSITIVE
    if spec is None:
        checks.append(unverified(
            'MV-07', 'Reference period recorded where applicable',
            'MEASUREMENT_PERIOD_UNAVAILABLE', sources=sources,
            policy_version=resolver_version))
    elif needs_period and not reference_period.strip():
        checks.append(unverified(
            'MV-07', 'Reference period recorded where applicable',
            'MEASUREMENT_REFERENCE_PERIOD_MISSING', sources=sources,
            evidence={'response_format': response_format},
            policy_version=resolver_version))
    else:
        checks.append(passed(
            'MV-07', 'Reference period recorded where applicable', sources=sources,
            evidence={'reference_period': reference_period or None},
            policy_version=resolver_version))

    # MV-08 — interpretation limitations are stated. A specification that does
    # not say what its result cannot support invites over-reading it later.
    limitations = str(body.get('limitations') or '')
    if spec is None:
        checks.append(unverified(
            'MV-08', 'Interpretation limitations recorded',
            'MEASUREMENT_LIMITATIONS_UNAVAILABLE', sources=sources,
            policy_version=resolver_version))
    elif not limitations.strip():
        checks.append(unverified(
            'MV-08', 'Interpretation limitations recorded',
            'MEASUREMENT_LIMITATIONS_MISSING', sources=sources,
            policy_version=resolver_version))
    else:
        checks.append(passed(
            'MV-08', 'Interpretation limitations recorded', sources=sources,
            policy_version=resolver_version))

    # MV-09 — selection constraints are coherent. A maximum below the minimum, or
    # a maximum above the number of options, describes a question nobody can
    # answer as written.
    if spec is None:
        checks.append(unverified(
            'MV-09', 'Selection constraints coherent',
            'MEASUREMENT_CONSTRAINTS_UNAVAILABLE', sources=sources,
            policy_version=resolver_version))
    else:
        low = body.get('min_selections')
        high = body.get('max_selections')
        if low is None or high is None:
            # Absent constraints are the common single-choice case, not a defect.
            checks.append(passed(
                'MV-09', 'Selection constraints coherent', sources=sources,
                evidence={'min_selections': low, 'max_selections': high},
                policy_version=resolver_version))
        elif not isinstance(low, int) or not isinstance(high, int) or low > high:
            checks.append(failed(
                'MV-09', 'Selection constraints coherent',
                'MEASUREMENT_SELECTION_CONSTRAINTS_INVALID', sources=sources,
                evidence={'min_selections': low, 'max_selections': high},
                policy_version=resolver_version))
        else:
            checks.append(passed(
                'MV-09', 'Selection constraints coherent', sources=sources,
                evidence={'min_selections': low, 'max_selections': high},
                policy_version=resolver_version))

    # MV-10 — the scientific approval state. This is the check that separates an
    # applicable measurement from a lab-only one, and it is the one that is
    # currently unmet for every objective.
    approved = resolution.get('scientifically_approved') is True
    synthetic = resolution.get('synthetic_test_scope') is True
    if outcome in _APPLIES and approved:
        checks.append(passed(
            'MV-10', 'Scientific approval state',
            sources=sources, evidence={'scientifically_approved': True},
            policy_version=resolver_version))
    elif outcome == REUSE_SYNTHETIC or synthetic:
        checks.append(unverified(
            'MV-10', 'Scientific approval state',
            'MEASUREMENT_SYNTHETIC_SCOPE_ONLY', sources=sources,
            evidence={'scientifically_approved': False,
                      'synthetic_test_scope': True},
            policy_version=resolver_version))
    else:
        checks.append(unverified(
            'MV-10', 'Scientific approval state',
            'MEASUREMENT_SCIENTIFIC_APPROVAL_ABSENT', sources=sources,
            evidence={'scientifically_approved': False},
            policy_version=resolver_version))

    # MV-11 — the version is bound, so a later revision cannot be substituted
    # for the one that was reviewed.
    version = _text(spec, 'measurement_version') if spec is not None else ''
    if spec is None:
        checks.append(unverified(
            'MV-11', 'Measurement version bound',
            'MEASUREMENT_VERSION_UNAVAILABLE', sources=sources,
            policy_version=resolver_version))
    elif not version:
        checks.append(failed(
            'MV-11', 'Measurement version bound',
            'MEASUREMENT_VERSION_MISSING', sources=sources,
            policy_version=resolver_version))
    else:
        checks.append(passed(
            'MV-11', 'Measurement version bound', sources=sources,
            evidence={'measurement_version': version},
            policy_version=resolver_version))

    return ValidationReport(subject='measurement_resolution',
                            policy_version=resolver_version, checks=checks)


def resolve_and_evaluate(store, objective_id: str, *, stimulus: dict | None = None,
                         supported_formats=frozenset(CANDIDATE_FORMATS),
                         allow_synthetic_test_approval: bool = False,
                         period_required: bool = False) -> ValidationReport:
    """Run the existing resolver, then report its requirements.

    The resolver stays the single decision-maker: this function selects the
    specification the resolver selected rather than choosing one itself.
    """
    from sitewise.project1.measurement_library import resolve

    resolution = resolve(store, objective_id, stimulus=stimulus,
                         supported_formats=supported_formats,
                         allow_synthetic_test_approval=allow_synthetic_test_approval)
    chosen = None
    measurement_id = resolution.get('measurement_id')
    if measurement_id:
        for candidate in store.specs(objective_id):
            if (candidate.measurement_id == measurement_id
                    and candidate.measurement_version
                    == resolution.get('measurement_version')):
                chosen = candidate
                break
    return evaluate(resolution, chosen, supported_formats=supported_formats,
                    period_required=period_required)


__all__ = ['REPORT_VERSION', 'evaluate', 'resolve_and_evaluate']
