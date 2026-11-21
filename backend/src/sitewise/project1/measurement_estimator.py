"""Additive, versioned estimator facts for an already-frozen ``Measurement``.

Why this is a *separate* contract
---------------------------------
``sitewise.project1.contracts.Measurement`` is deployed. Live captures and stored
receipts were produced against exactly its eleven fields, and it is a strict
model (``extra='forbid'``, ``strict=True``). Adding even one required field
there would:

* reject every measurement that is already stored, because the stored dicts do
  not carry the new key;
* reject every live capture whose runner still emits the deployed shape;
* silently change the meaning of ``digest(measurement)``, so every receipt that
  binds a measurement by digest would stop matching the measurement it
  describes.

A frozen contract therefore cannot grow required fields. The estimator facts a
governance review found missing -- numerator codes, denominator codes, excluded
nonresponse states, an eligibility predicate, a reference period distinct from
``timeframe``, and prohibitions as data -- are carried here instead, in a
versioned *annotation* that points at one specific measurement.

Why the digest binding exists
-----------------------------
An estimator is only meaningful for the measurement it was written for. If an
estimator could be attached to any measurement, a numerator and denominator
compiled for one instrument would silently define a share over a different
stimulus or population -- the numbers would look computed and mean nothing.
``attach_estimator`` therefore refuses unless the estimator's
``measurement_digest`` equals ``digest(measurement)``. The binding is the
identity of the pair, not a convenience check.

What this module is not
-----------------------
It confers no authority. ``validate_estimator`` returns
``ESTIMATOR_TEST_SCOPED_VALID`` with ``scientific_accepted=False`` and
``production_eligible=False``. It is not a bank receipt, not a fielding right and
not a scientific acceptance, and no code path here can promote it.
"""
from __future__ import annotations

from pydantic import Field

from sitewise.project1.contracts import StrictModel, WorkflowHeld, digest

#: Version of the estimator annotation contract (not of any measurement).
ESTIMATOR_CONTRACT_VERSION = 'P1-ESTIMATOR-0.1'


class EstimatorContract(StrictModel):
    """Machine-readable estimand facts the deployed ``Measurement`` cannot carry.

    ``measurement_digest`` is ``digest()`` of the canonical ``Measurement`` dict
    this annotation describes. It is required, so an unattached estimator is not
    representable.
    """

    estimator_version: str = Field(min_length=1, max_length=100)
    measurement_digest: str = Field(min_length=1, max_length=64)
    numerator_codes: list[str] = Field(min_length=1, max_length=12)
    denominator_codes: list[str] = Field(min_length=1, max_length=12)
    excluded_response_states: list[str] = Field(min_length=1, max_length=12)
    eligibility_predicate: str = Field(min_length=1, max_length=1000)
    reference_period: str = Field(min_length=1, max_length=500)
    prohibited_interpretations: list[str] = Field(min_length=1, max_length=20)
    permitted_interpretation: str = Field(min_length=1, max_length=1000)


def attach_estimator(measurement: dict, estimator: EstimatorContract) -> dict:
    """Bind an estimator to the exact measurement it annotates.

    Binding only: the combined artifact is returned if and only if the digest
    matches. Semantic checks are a separate, explicit step
    (``validate_estimator``), so a caller cannot mistake a successful bind for a
    successful validation.
    """
    if estimator.measurement_digest != digest(measurement):
        raise WorkflowHeld('ESTIMATOR_MEASUREMENT_DIGEST_MISMATCH')
    return {'estimator_contract_version': ESTIMATOR_CONTRACT_VERSION,
            'measurement': dict(measurement),
            'measurement_digest': estimator.measurement_digest,
            'estimator': estimator.model_dump()}


def validate_estimator(estimator: EstimatorContract, measurement: dict) -> dict:
    """Check the estimand is computable and nonresponse is not inside it.

    Every refusal is one fixed machine code; no free text and no provider input
    reaches the reason. The checks are ordered so the first failure names the
    actual defect: an unbound estimator is reported as unbound, a numerator that
    is not a code is reported as a coding defect rather than as a subset defect.
    """
    if estimator.measurement_digest != digest(measurement):
        # An estimator validated against a measurement it does not describe would
        # produce a receipt whose digest claim is false.
        raise WorkflowHeld('ESTIMATOR_MEASUREMENT_DIGEST_MISMATCH')

    response_codes = set(measurement.get('response_codes') or [])
    numerator = set(estimator.numerator_codes)
    denominator = set(estimator.denominator_codes)
    excluded = set(estimator.excluded_response_states)

    if not numerator <= response_codes:
        raise WorkflowHeld('ESTIMATOR_NUMERATOR_NOT_IN_CODES')
    if not denominator <= response_codes:
        raise WorkflowHeld('ESTIMATOR_DENOMINATOR_NOT_IN_CODES')
    # Strict subset: a numerator equal to its denominator would make every
    # reported share 100%, which is a denominator that measures nothing.
    if not numerator < denominator:
        raise WorkflowHeld('ESTIMATOR_NOT_A_SUBSET_OF_DENOMINATOR')
    # Nonresponse must sit outside the denominator, so "don't know" can never be
    # counted as an answer in either direction.
    if not denominator.isdisjoint(excluded):
        raise WorkflowHeld('ESTIMATOR_NONRESPONSE_NOT_SEPARATE')
    # Every declared response state is either counted or explicitly excluded.
    # An unclassified state is silently dropped from the denominator, which
    # inflates the share without changing any visible number.
    if not (response_codes - denominator) <= excluded:
        raise WorkflowHeld('ESTIMATOR_UNCLASSIFIED_RESPONSE_STATE')

    if not estimator.prohibited_interpretations:
        raise WorkflowHeld('ESTIMATOR_PROHIBITIONS_MISSING')
    if not estimator.permitted_interpretation.strip():
        raise WorkflowHeld('ESTIMATOR_PERMITTED_INTERPRETATION_MISSING')
    if not estimator.estimator_version.strip():
        raise WorkflowHeld('ESTIMATOR_VERSION_MISSING')

    return {'status': 'ESTIMATOR_TEST_SCOPED_VALID',
            'estimator_contract_version': ESTIMATOR_CONTRACT_VERSION,
            'estimator_version': estimator.estimator_version,
            'estimator_digest': digest(estimator.model_dump()),
            'measurement_digest': digest(measurement),
            'scientific_accepted': False,
            'production_eligible': False}
