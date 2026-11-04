"""Suitability scoring rules (domain layer).

Verified status (2026-11-04): the repository contains **no approved scoring
specification** and **no trained model artifact** for either

1. location suitability (the intended PU-Learning model), or
2. premises suitability (property-characteristic scoring).

The previous implementation returned ``{"score": 0.0}`` unconditionally,
which fabricated a valid-looking prediction. It now returns an explicit
"unavailable" assessment naming the missing prerequisites, so clients can
distinguish "no data" from "score is zero" and the integration can be
completed the moment a real artifact or approved specification lands.

Concept separation (kept explicit for the future implementation):

1. **Location suitability** - PU-Learning model output over geospatial
   features (requires a trained artifact, e.g. ``ml/artifacts/pu_model.pkl``).
2. **Premises suitability** - property-characteristic scoring (requires an
   approved specification: weights, benchmarks, normalisation ranges).
3. **Business requirement matching** - entrepreneur preferences vs listing
   attributes (requires the approved matching rules).
4. **Final recommendation ranking** - combination policy (domain.ranking).
"""

from __future__ import annotations

from dataclasses import dataclass, field

_MISSING_PREREQUISITES = (
    "approved suitability scoring specification (weights / benchmarks / "
    "normalisation ranges) reviewed by the project supervisor",
    "trained PU-Learning model artifact for location suitability "
    "(e.g. ml/artifacts/pu_model.pkl) with its feature list",
    "feature-extraction pipeline that maps a property_id to the model's "
    "expected geospatial features in the correct order",
)


@dataclass
class SuitabilityAssessment:
    """Result envelope for a suitability assessment.

    ``available=False`` means no validated scoring path exists yet; ``score``
    is then always ``None`` (never a fabricated number, never 0.0).
    """

    property_id: int
    available: bool
    score: float | None
    reason: str
    components: dict = field(default_factory=dict)
    prerequisites: tuple[str, ...] = ()


def assess_premises(property_id: int, preferences: dict | None) -> SuitabilityAssessment:
    """Return the honest assessment for a property.

    When an approved specification or trained artifact becomes available,
    this is the single place where the real computation replaces the
    unavailable envelope.
    """
    return SuitabilityAssessment(
        property_id=property_id,
        available=False,
        score=None,
        reason=(
            "No validated suitability scoring path is available: there is no "
            "approved scoring specification and no trained model artifact in "
            "the repository. No score is produced rather than returning a "
            "fabricated value."
        ),
        components={
            "location_suitability": "unavailable (no trained PU-Learning artifact)",
            "premises_suitability": "unavailable (no approved specification)",
            "business_requirement_matching": "unavailable (no approved rules)",
        },
        prerequisites=_MISSING_PREREQUISITES,
    )
