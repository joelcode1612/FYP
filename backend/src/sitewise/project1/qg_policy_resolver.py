"""The production fixed-policy resolver Direct-QG requires — as an interface.

``DirectQgService.prepare_candidate`` refuses to run without a
``fixed_policy_resolver``. It cannot verify that the objective it was handed is
the one an owner approved against the context it just retrieved, so it holds.
Until now nothing supplied one, and the service failed closed with
``QG_FIXED_OPTION_ADMISSION_UNAVAILABLE`` — correct, but it hid *which*
prerequisite was missing.

This module supplies the interface and a resolver assembled only from records
that already exist. It cannot manufacture authority:

* the objective must come from an ``ADMITTED`` admission that binds a fixed
  O1–O6 objective — a novel candidate binds ``objective_id = NULL`` and is
  refused here rather than quietly promoted;
* the admission must belong to the same assessment, confirmation revision and
  context packet the caller retrieved, and to the same owner;
* the measurement must resolve to an approved specification. With zero of six
  objectives scientifically approved, this refuses with
  ``QG_MEASUREMENT_NOT_APPROVED`` instead of proceeding.

``objective_approved`` in the returned policy is not a new grant: it restates
the owner admission that was read. ``fielding_authorized`` and
``policy_adopted`` stay false in every case, and nothing here writes a record.
"""
from __future__ import annotations

from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.objective_registry import OBJECTIVE_IDS

#: Version of this resolver's output. A behavioural change is a new version,
#: because the policy dict is stored beside a candidate that was drafted from it.
POLICY_CONTRACT = 'P1-QG-POLICY-1.0'

#: Refusals, each naming one missing prerequisite. A caller must be able to tell
#: "no admission" from "stale context" from "no approved measurement" — a single
#: generic code would send the reader to the wrong repair.
ADMISSION_REQUIRED = 'QG_POLICY_ADMISSION_REQUIRED'
ADMISSION_NOT_ADMITTED = 'QG_POLICY_ADMISSION_NOT_ADMITTED'
NO_FIXED_OBJECTIVE = 'QG_POLICY_NO_FIXED_OBJECTIVE'
UNKNOWN_OBJECTIVE = 'QG_POLICY_UNKNOWN_OBJECTIVE'
OBJECTIVE_MISMATCH = 'QG_POLICY_OBJECTIVE_MISMATCH'
ASSESSMENT_MISMATCH = 'QG_POLICY_ASSESSMENT_MISMATCH'
CONTEXT_ASSESSMENT_MISMATCH = 'QG_POLICY_CONTEXT_ASSESSMENT_MISMATCH'
CONTEXT_STALE = 'QG_POLICY_CONTEXT_STALE'
REVISION_STALE = 'QG_POLICY_REVISION_STALE'
OWNER_MISMATCH = 'QG_POLICY_OWNER_MISMATCH'
MEASUREMENT_NOT_APPROVED = 'QG_MEASUREMENT_NOT_APPROVED'


def _confirmation_revision(packet: dict):
    confirmation = (packet or {}).get('confirmation') or {}
    return confirmation.get('revision')


def build_policy(*, admission, assessment_id, context_id, actor, objective,
                 packet, measurement) -> dict:
    """Assemble the policy ``DirectQgService`` verifies, or raise ``WorkflowHeld``.

    Pure: every input is supplied, nothing is read and nothing is written. The
    order is deliberate — identity first, then authority, then the measurement —
    so the first failure names the earliest missing prerequisite rather than a
    later one that merely happens to be checked first.
    """
    packet = packet or {}
    objective = objective or {}

    if not admission:
        raise WorkflowHeld(ADMISSION_REQUIRED)
    if admission.get('decision') != 'ADMITTED':
        raise WorkflowHeld(ADMISSION_NOT_ADMITTED)

    bound = admission.get('objective_id')
    if bound is None:
        # A novel candidate is not one of the six fixed objectives; admitting it
        # is valid, but it is not a measurement target until a human registers it.
        raise WorkflowHeld(NO_FIXED_OBJECTIVE)
    if bound not in OBJECTIVE_IDS:
        raise WorkflowHeld(UNKNOWN_OBJECTIVE)
    if str(objective.get('objective_id')) != str(bound):
        raise WorkflowHeld(OBJECTIVE_MISMATCH)

    if str(admission.get('assessment_id')) != str(assessment_id):
        raise WorkflowHeld(ASSESSMENT_MISMATCH)
    packet_assessment = (packet.get('assessment_id')
                         or (packet.get('identity') or {}).get('assessment_id'))
    if str(packet_assessment) != str(assessment_id):
        raise WorkflowHeld(CONTEXT_ASSESSMENT_MISMATCH)

    packet_hash = packet.get('packet_hash')
    if not packet_hash or admission.get('context_packet_hash') != packet_hash:
        raise WorkflowHeld(CONTEXT_STALE)

    revision = _confirmation_revision(packet)
    if (revision is None
            or int(admission.get('confirmation_revision')) != int(revision)):
        raise WorkflowHeld(REVISION_STALE)

    owner = getattr(actor, 'user_id', None)
    if owner is None or str(admission.get('actor_user_id')) != str(owner):
        raise WorkflowHeld(OWNER_MISMATCH)

    if not measurement or measurement.get('scientifically_approved') is not True:
        # The decisive gate. A candidate question drafted from an unapproved
        # measurement would look authorised without being authorised.
        raise WorkflowHeld(MEASUREMENT_NOT_APPROVED)

    return {
        'policy_contract': POLICY_CONTRACT,
        'assessment_id': str(assessment_id),
        'owner_id': str(owner),
        'objective_id': str(bound),
        # Restates the admission; it is not a second grant.
        'objective_approved': True,
        'authority_reference': str(admission.get('admission_id')),
        'admission_id': str(admission.get('admission_id')),
        'context_id': str(context_id),
        'context_hash': packet_hash,
        'assessment_revision': int(revision),
        'measurement_id': measurement.get('measurement_id'),
        'measurement_version': measurement.get('measurement_version'),
        'scientifically_approved': True,
        # Never true here, in any case.
        'fielding_authorized': False,
        'publication_authorized': False,
        'policy_adopted': False,
    }


def make_fixed_policy_resolver(*, load_admission, measurement_resolver):
    """Build a callable with the signature ``DirectQgService`` expects.

    The two inputs are injected so this module performs no I/O: a caller supplies
    how to read the admission and how to resolve the measurement, and the policy
    logic above stays testable with synthetic fixtures.
    """

    def resolve(assessment_id, context_id, actor, objective, packet):
        objective_id = (objective or {}).get('objective_id')
        admission = load_admission(assessment_id, getattr(actor, 'user_id', None),
                                   objective_id)
        measurement = measurement_resolver(assessment_id, objective, packet)
        return build_policy(
            admission=admission, assessment_id=assessment_id,
            context_id=context_id, actor=actor, objective=objective,
            packet=packet, measurement=measurement)

    resolve.policy_contract = POLICY_CONTRACT  # type: ignore[attr-defined]
    return resolve


__all__ = [
    'ADMISSION_NOT_ADMITTED', 'ADMISSION_REQUIRED', 'ASSESSMENT_MISMATCH',
    'CONTEXT_ASSESSMENT_MISMATCH', 'CONTEXT_STALE', 'MEASUREMENT_NOT_APPROVED',
    'NO_FIXED_OBJECTIVE', 'OBJECTIVE_MISMATCH', 'OWNER_MISMATCH',
    'POLICY_CONTRACT', 'REVISION_STALE', 'UNKNOWN_OBJECTIVE', 'build_policy',
    'make_fixed_policy_resolver',
]
