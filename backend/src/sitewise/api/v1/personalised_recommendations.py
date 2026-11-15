"""Personalised AI recommendation pipeline (Layer 2 + Layer 3) endpoints.

Additive router mounted at the SAME ``/recommendations`` prefix as the existing
recommendations module. Keeping it in a separate file means the pre-existing,
uncommitted ``/search`` and ``/facets`` work in ``recommendations.py`` is not
touched, overwritten or swept into this integration's commit.

Route collision policy
======================
The existing router already owns ``GET /me``, ``GET /``, ``POST /``,
``GET /user/{user_id}`` and ``DELETE /{result_id}`` (and, in separate work in
progress, ``GET /facets`` / ``POST /search``). This router therefore uses only:

* ``POST /generate``              - no dynamic POST route exists.
* ``GET  /me/generated``          - a distinct, longer static path than /me.
* ``GET  /{result_id}/explanation`` - a two-segment path; it cannot swallow
  /me, /facets or any other one-segment static path.

``result_id`` is parsed as a UUID, so a non-UUID path fails with 422 instead of
being mistaken for a property id or a static route. Static paths are declared
first in this module as well, for defence in depth.

Identity: every handler takes the entrepreneur from the verified token via
``require_entrepreneur``. There is NO ``user_id`` in any request body, and any
client-supplied ``user_id`` is ignored by Pydantic and never reaches the store.
"""
from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlmodel import Session

from sitewise.db.analytics_session import get_analytics_db
from sitewise.db.session import get_db
from sitewise.dependencies import AuthenticatedUser, require_entrepreneur
from sitewise.services.property_management_service import (
    resolve_listings,
    resolve_management,
)
from sitewise.services.recommendation_generation_service import (
    RecommendationGenerationService,
)

router = APIRouter()

EntrepreneurUser = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]
AppSession = Annotated[Session, Depends(get_db)]
AnalyticsSession = Annotated[Session, Depends(get_analytics_db)]


def _no_operational_listing() -> dict:
    """A catalogue record with no verified operational listing behind it.

    Reported as unresolved rather than given an invented manager: the research
    catalogue row exists, but no property in ``fyp.rental_properties`` is linked
    to it, so no owner or agent relationship can be read.
    """
    from sitewise.services.recommendation_management_service import (
        unassigned_management,
    )

    return unassigned_management()


def _attach_management(session: Session, payload: dict) -> dict:
    """Add the derived management state to every ranked result.

    The listing reference lives on the nested property block; results without a
    verified link keep an explicit unresolved state. One batch lookup serves the
    whole page — no per-card database or Supabase call.
    """
    rows = payload.get("results") or []
    if not rows:
        return payload
    listing_ids: list[int] = []
    for row in rows:
        ref = ((row.get("property") or {}).get("listing_ref")) or {}
        if ref.get("listing_id") is not None:
            listing_ids.append(int(ref["listing_id"]))
    management = resolve_listings(session, listing_ids) if listing_ids else {}
    for row in rows:
        ref = ((row.get("property") or {}).get("listing_ref")) or {}
        listing_id = ref.get("listing_id")
        row["management"] = (
            management.get(int(listing_id))
            if listing_id is not None
            else _no_operational_listing()
        )
    return payload


class GenerateRequest(BaseModel):
    """Generation options only. NEVER an identity.

    ``user_id`` is deliberately absent. Pydantic ignores unknown keys by
    default, so even a client that sends one cannot influence ownership - the
    authenticated identity is the sole owner of every generated result.
    """

    limit: int = Field(default=20, ge=1, le=100)
    state: str | None = Field(default=None, max_length=120)
    property_ids: list[str] | None = Field(default=None, max_length=20)


@router.post("/generate")
def generate_recommendations(
    body: GenerateRequest,
    user: EntrepreneurUser,
    app_session: AppSession,
    analytics_session: AnalyticsSession,
) -> dict:
    """Rank eligible research-catalogue properties for the signed-in entrepreneur.

    Reads saved preferences, obtains real Layer 1 PU association scores, applies
    eligibility filters and the versioned rule-based Layer 2 engine, then
    returns a deterministic ranked batch. Each result carries a ``result_id``
    for ``GET /{result_id}/explanation``.

    PU scores are research association indices, not success probabilities.
    Layer 2 is rule-based, not a trained recommender. Availability is
    UNKNOWN_NOT_VERIFIED for the research catalogue and is never presented as
    confirmed.
    """
    try:
        return _attach_management(
            app_session,
            RecommendationGenerationService(app_session, analytics_session).generate(
                user.user_id,
                limit=body.limit,
                state=body.state,
                property_ids=body.property_ids,
            ),
        )
    except Exception as exc:  # database / repository failure, not a bad request
        # Fail closed: never substitute demonstration results when the real
        # catalogue or the real PU score cannot be read.
        raise HTTPException(
            status_code=503,
            detail={
                "code": "recommendation_generation_unavailable",
                "message": f"{type(exc).__name__}: {exc}",
            },
        ) from exc


@router.get("/me/generated")
def own_generated_recommendations(
    user: EntrepreneurUser,
    app_session: AppSession,
    analytics_session: AnalyticsSession,
) -> dict:
    """The caller's most recent generated batch (additive to legacy ``/me``).

    ``GET /me`` in the existing router keeps returning the stored legacy
    ``RecommendationResult`` rows unchanged; this endpoint returns the new
    Layer 2 pipeline's results instead. Both are ownership-scoped.
    """
    return _attach_management(
        app_session,
        RecommendationGenerationService(app_session, analytics_session).latest(
            user.user_id
        ),
    )


@router.get("/{result_id}/explanation")
def recommendation_explanation(
    result_id: uuid.UUID,
    user: EntrepreneurUser,
    app_session: AppSession,
    analytics_session: AnalyticsSession,
) -> dict:
    """Two clearly separated explanations for one owned result.

    ``sections.pu_research_explanation`` is SHAP over the research PU model
    (with a verified baseline + contributions = score reconstruction).
    ``sections.personalised_recommendation_explanation`` is the Layer 2 rule
    engine's own reasons, evidence and cautions. SHAP never explains the rules.

    If SHAP cannot be produced, ``explanation.shap`` is ``null`` with an
    explicit ``shap_status.reason``; the rule-based explanation and the
    recommendation still work.
    """
    result = RecommendationGenerationService(app_session, analytics_session).explain(
        result_id, user.user_id
    )
    if result is None:
        # Ownership-scoped miss: a foreign result is indistinguishable from a
        # missing one, so this endpoint cannot be used to enumerate results.
        raise HTTPException(status_code=404, detail="Recommendation result not found")
    # Management responsibility for the property this explanation describes.
    # Catalogue ids resolve through the operational listing_id, which is how a
    # research record is tied to the property that would actually be managed.
    canonical = (result.get("property") or {}).get("canonical_property_id")
    result["management"] = (
        resolve_management(app_session, catalogue_id=str(canonical))
        if canonical
        else _no_operational_listing()
    )
    return result
