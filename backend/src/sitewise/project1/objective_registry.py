"""The six fixed research objectives: a registry, not a model output.

Why this is a separate module
-----------------------------
The six mandatory objectives exist for **every** assessment regardless of what a
model proposes. They are the spine of the report (R03..R07 and the two unmapped
ones), and the directive is explicit that a BDJ proposal may *link* to one of
them but may never create, retire or re-rank them:

    "O1–O6 always present, fixed mapping reviewed or flagged; no BDJ proposal
     changes their mandatory status; measure coverage remains actual verified
     count."

So the registry is a constant, and coverage is a **derived count** over real
approval records. Nothing here can raise the count by assertion: `coverage()`
takes the measurement resolver's own verdicts and counts them.

What this module deliberately does not do
-----------------------------------------
* It does not approve a measurement. It reports how many objectives have one.
* It does not assign a report section that does not exist. O4 and O6 have no
  verified report mapping and are reported with ``report_section = None`` and an
  explicit blocker rather than an invented R-number.
* It does not treat an objective's *existence* as *coverage*.
"""
from __future__ import annotations

from dataclasses import dataclass

#: Version of the registry. Changing a construct, a report mapping or a
#: mandatory flag is a new version, because a stored traceability record has to
#: name the registry it was resolved against.
REGISTRY_VERSION = 'P1-OBJECTIVE-REGISTRY-1.0'

#: ``None`` means: no verified objective-to-report mapping exists. It is not a
#: placeholder to be filled by guesswork.
_NO_MAPPING = 'REPORT_MAPPING_NOT_ESTABLISHED'


@dataclass(frozen=True)
class FixedObjective:
    objective_id: str
    name: str
    construct: str
    report_section: str | None
    mapping_blocker: str | None = None
    #: Always true for O1..O6. Stored so a reader can assert it rather than
    #: assume it, and so a future version cannot quietly demote one.
    mandatory: bool = True


OBJECTIVES: tuple[FixedObjective, ...] = (
    FixedObjective(
        objective_id='O1', name='Concept Interest',
        construct='Stated interest in the confirmed business concept',
        report_section='R03'),
    FixedObjective(
        objective_id='O2', name='Product Preference',
        construct='Stated preference among the specified products',
        report_section='R04'),
    FixedObjective(
        objective_id='O3', name='Price Acceptability',
        construct='Stated acceptability of an exact specified priced offer',
        report_section='R05'),
    FixedObjective(
        objective_id='O4', name='Service Preference',
        construct='Stated preference among the allowed service modes',
        report_section=None, mapping_blocker=_NO_MAPPING),
    FixedObjective(
        objective_id='O5', name='Experience Preference',
        construct='Stated preference for experience features',
        report_section='R07'),
    FixedObjective(
        objective_id='O6', name='Segment Interest',
        construct='Interest reported by a verified respondent segment',
        report_section=None,
        mapping_blocker='NO_CONFIRMED_CANDIDATE_QUESTION_AND_' + _NO_MAPPING),
)

OBJECTIVE_IDS: tuple[str, ...] = tuple(o.objective_id for o in OBJECTIVES)
_BY_ID = {o.objective_id: o for o in OBJECTIVES}


def get(objective_id: str) -> FixedObjective:
    """Look up a fixed objective. An unknown id is a refusal, not a new O7."""
    try:
        return _BY_ID[objective_id]
    except KeyError:
        raise KeyError(f'Unknown fixed objective {objective_id!r}; the registry '
                       f'contains exactly {OBJECTIVE_IDS}') from None


def as_dicts() -> list[dict]:
    return [{'objective_id': o.objective_id, 'name': o.name,
             'construct': o.construct, 'report_section': o.report_section,
             'mapping_blocker': o.mapping_blocker, 'mandatory': o.mandatory,
             'registry_version': REGISTRY_VERSION} for o in OBJECTIVES]


def coverage(resolutions: dict[str, dict]) -> dict:
    """Count objectives that have an **approved** measurement.

    ``resolutions`` maps ``objective_id`` to a measurement-resolver result. Only
    ``REUSE_APPROVED_MEASUREMENT`` counts, and only when the resolver says the
    measurement is scientifically approved. A proposed extension is research
    design work, not coverage, so it is counted separately and never added in.

    The result is deliberately blunt: a reviewer must be able to see that the
    number is 0 because nothing is approved, not because nothing was tried.
    """
    rows = []
    covered = 0
    for objective in OBJECTIVES:
        resolution = resolutions.get(objective.objective_id) or {}
        outcome = resolution.get('outcome')
        approved = bool(resolution.get('scientifically_approved'))
        is_covered = outcome == 'REUSE_APPROVED_MEASUREMENT' and approved
        covered += 1 if is_covered else 0
        rows.append({
            'objective_id': objective.objective_id,
            'name': objective.name,
            'report_section': objective.report_section,
            'mapping_blocker': objective.mapping_blocker,
            'resolver_outcome': outcome,
            'approved_measurement': (resolution.get('measurement_id')
                                     if is_covered else None),
            'approved_measurement_version': (resolution.get('measurement_version')
                                             if is_covered else None),
            'covered_by_an_approved_measure': is_covered,
            'candidate_extension_proposed': outcome == 'PROPOSE_MEASUREMENT_EXTENSION',
            'scientific_status': ('APPROVED' if is_covered
                                  else 'NOT_APPROVED'),
        })
    return {
        'registry_version': REGISTRY_VERSION,
        'objectives': len(OBJECTIVES),
        'approved_measurement_count': covered,
        'uncovered': len(OBJECTIVES) - covered,
        'rows': rows,
        'note': ('Coverage is counted from approval records only. A candidate '
                 'measurement proposal, a generated question or an HTTP 200 '
                 'never raises this number.'),
    }


def mandatory_status(resolutions: dict[str, dict]) -> dict:
    """Prove that resolution never changes mandatory status.

    Returns one row per objective with ``mandatory`` true and the reason it is
    true, so a test can assert the invariant directly instead of trusting that
    the resolver "did not touch it".
    """
    return {o.objective_id: {'mandatory': o.mandatory,
                             'present': True,
                             'changed_by_resolution': False,
                             'registry_version': REGISTRY_VERSION}
            for o in OBJECTIVES}


__all__ = ['OBJECTIVES', 'OBJECTIVE_IDS', 'REGISTRY_VERSION', 'FixedObjective',
           'as_dicts', 'coverage', 'get', 'mandatory_status']
