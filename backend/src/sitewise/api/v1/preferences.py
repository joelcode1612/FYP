"""Entrepreneur recommendation preferences (Jaspr web).

Scoped to the authenticated entrepreneur: the owner id comes from the verified
token, never from the request body, and there is no route that reads another
account's preferences. Validation is the assessment workspace's own
``validate_requirements``, so the two surfaces share one vocabulary and one rule
set instead of competing preference systems.

The Flutter mobile data-collection workflow builds ``BusinessPreferences``
in-session and does not call these routes.
"""

from __future__ import annotations

from typing import Annotated, Any

from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlmodel import Session

from sitewise.db.session import get_db
from sitewise.dependencies import AuthenticatedUser, require_entrepreneur
from sitewise.services.preferences_service import PreferencesService

router = APIRouter()

EntrepreneurUser = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]
AppSession = Annotated[Session, Depends(get_db)]


class SavePreferencesRequest(BaseModel):
    """A partial or complete preferences payload.

    Only the fields present are changed; anything omitted keeps its stored
    value. The merged result is what gets validated and written.
    """

    preferences: dict[str, Any]


@router.get("/me")
def get_own_preferences(session: AppSession, user: EntrepreneurUser) -> dict:
    """The caller's stored preferences.

    Never having saved any is a normal empty state, not an error: 200 with
    ``saved: false`` and a null payload, so the form shows its own defaults
    rather than values the server invented.
    """
    return PreferencesService(session).payload(user.user_id)


@router.patch("/me")
def save_own_preferences(
    body: SavePreferencesRequest,
    session: AppSession,
    user: EntrepreneurUser,
) -> dict:
    """Merge, validate and persist the caller's preferences.

    A 422 carries every validation problem at once and writes nothing. The
    response is the normalised payload the server actually stored, so the client
    can only confirm a save against persisted values.
    """
    service = PreferencesService(session)
    service.save(user.user_id, body.preferences)
    return service.payload(user.user_id)
