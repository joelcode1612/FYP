"""Entrepreneur recommendation preferences.

The stored payload uses exactly the vocabulary ``validate_requirements`` defines
for the web assessment's business-requirements stage, and validation is that
same function rather than a second rule set. One vocabulary means the workspace
can seed its draft from the stored preferences (and the preferences page can
read back what an assessment saved) with no translation layer, so the two
surfaces cannot drift apart into competing preference systems.

Web-only. The Flutter mobile data-collection workflow builds
``BusinessPreferences`` in-session and never calls this service.
"""

from __future__ import annotations

import json
import uuid
from datetime import UTC, datetime
from typing import Any

from sqlmodel import Session

from sitewise.core.logging import logger
from sitewise.db.models.entrepreneur_preferences import EntrepreneurPreferences
from sitewise.repositories.preferences_repository import PreferencesRepository
from sitewise.services.assessment_service import validate_requirements


def _now() -> datetime:
    return datetime.now(UTC)


def _iso(value: datetime | None) -> str | None:
    return value.isoformat() if value else None


class PreferencesService:
    def __init__(self, session: Session):
        self.repo = PreferencesRepository(session)

    @staticmethod
    def _decode(record: EntrepreneurPreferences | None) -> dict:
        # Unreadable text reads as "not stored" rather than raising, so a
        # corrupt row cannot lock the entrepreneur out of the form.
        if record is None or not record.preferences:
            return {}
        try:
            parsed = json.loads(record.preferences)
        except (TypeError, ValueError):
            logger.warning("Entrepreneur %s has unreadable preferences text", record.user_id)
            return {}
        return parsed if isinstance(parsed, dict) else {}

    def save(self, user_id: uuid.UUID, changes: Any) -> EntrepreneurPreferences:
        """Merge [changes] over what is stored, validate, then write.

        Validation runs on the merged result, so a partial update can never
        leave a stored payload that the assessment stage would reject. Nothing
        is written when it raises.
        """
        record = self.repo.get_by_user(user_id)
        clean = validate_requirements({**self._decode(record), **changes})

        now = _now()
        if record is None:
            # Both timestamps are passed explicitly: the model's own defaults
            # are naive ``datetime.utcnow``, which this service does not use.
            record = EntrepreneurPreferences(
                user_id=user_id, created_at=now, updated_at=now
            )
        record.preferences = json.dumps(clean, ensure_ascii=False)
        record.updated_at = now
        return self.repo.save(record)

    def payload(self, user_id: uuid.UUID) -> dict:
        """What the client renders.

        ``saved`` keeps "never stored" distinguishable from "stored": an
        entrepreneur with no record gets a null payload and the form shows its
        own defaults, rather than the server inventing values it never held.
        """
        record = self.repo.get_by_user(user_id)
        stored = self._decode(record)
        return {
            "preferences": stored or None,
            "saved": bool(stored),
            "updated_at": _iso(record.updated_at) if record is not None else None,
        }
