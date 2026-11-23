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
from sitewise.core.exceptions import AssessmentError
from sitewise.services.assessment_service import (
    _validate_v1, requirements_version_of, validate_requirements,
)


# sitewise-expanded-user-preferences-v1
# Account settings are independent of the v1/v2/v3 assessment vocabulary.
# The existing account row remains authoritative; no new table is required.
_SETTINGS_ENUMS = {
    "search_radius_m": (500, 1000),
    "default_sort": ("best_match", "rent_asc", "rent_desc", "size_asc", "size_desc", "pu_desc"),
    "transit_max_m": (None, 500, 1000),
    "nearby_parking_min": (None, 1, 3, 5),
    "fnb_competition_max": (None, 5, 10, 20),
}
_SETTINGS_TEXT = ("preferred_state", "preferred_city")
_SETTINGS_BOOL = ("use_current_location", "notification_updates")
_LEGACY_PROFILE_KEYS = frozenset({
    "property_type", "target_market", "seating_model", "min_budget_rm",
    "max_budget_rm", "min_size_sqft", "max_size_sqft", "requirements", "preferred_areas",
})


def _invalid_settings(message: str):
    raise AssessmentError(message, code="invalid_requirements", status_code=422)


def _merge_user_settings(previous: Any, changes: Any) -> dict:
    if not isinstance(changes, dict):
        _invalid_settings("User settings must be an object.")
    # Keep unchanged, recognised settings. Never persist arbitrary keys from
    # a request, and never use these flags as an OS permission grant.
    allowed = set(_SETTINGS_ENUMS) | set(_SETTINGS_TEXT) | set(_SETTINGS_BOOL)
    if set(changes) - allowed:
        _invalid_settings("Unknown user settings field.")
    merged = {**(previous if isinstance(previous, dict) else {}), **changes}
    clean = {}
    for key, value in merged.items():
        if key in _SETTINGS_TEXT:
            if not isinstance(value, str) or len(value.strip()) > 120:
                _invalid_settings(f"{key} must be text up to 120 characters.")
            clean[key] = value.strip()
        elif key in _SETTINGS_BOOL:
            if type(value) is not bool:
                _invalid_settings(f"{key} must be true or false.")
            clean[key] = value
        elif key in _SETTINGS_ENUMS:
            if isinstance(value, bool) or value not in _SETTINGS_ENUMS[key]:
                _invalid_settings(f"Unsupported {key} value.")
            if key != "default_sort" and value is not None and type(value) is not int:
                _invalid_settings(f"{key} must be an integer.")
            clean[key] = value
    return clean


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
        previous = self._decode(record)
        merged = {**previous, **changes}
        # Settings are partial-merged and validated separately so the assessment
        # schema cannot strip them or mistake them for questionnaire answers.
        settings_present = "user_settings" in previous or "user_settings" in changes
        settings = _merge_user_settings(
            previous.get("user_settings"), changes.get("user_settings", {})
        )
        merged.pop("user_settings", None)
        # Business category is no longer a recommendation preference: there
        # is no separate F&B category suitability score. Drop a historical
        # value instead of carrying it invisibly into new saves. Assessment
        # questionnaire validation still requires it when appropriate.
        merged.pop('business_type', None)
        clean = validate_requirements(
            merged, require_business_type=False
        )
        clean.pop('business_type', None)
        # A v2/v3 questionnaire may coexist with the general property criteria.
        # Validate the legacy fields independently rather than losing them when
        # the questionnaire validator returns only its own vocabulary.
        if requirements_version_of(merged) in (2, 3):
            legacy = {k: merged[k] for k in _LEGACY_PROFILE_KEYS if k in merged}
            if {"property_type", "max_budget_rm", "max_size_sqft"} <= legacy.keys():
                profile = _validate_v1(legacy, require_business_type=False)
                profile.pop("business_type", None)
                clean.update(profile)
        if settings_present:
            clean["user_settings"] = settings

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
        # Hide any older category value without migrating or deleting the
        # user's other saved preferences. The next save removes the old
        # field from the persisted JSON.
        stored.pop('business_type', None)
        return {
            "preferences": stored or None,
            "saved": bool(stored),
            "updated_at": _iso(record.updated_at) if record is not None else None,
        }
