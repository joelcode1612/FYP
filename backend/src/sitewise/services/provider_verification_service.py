"""Provider (account) verification — distinct from property listing verification.

Two different questions are asked in SiteWise and they must never be merged:

* **Provider verification** (this module) — *is this account a real property
  owner / agency we are willing to have listing properties?* It is about the
  person or business behind the account, and it is what the Owner / Agent
  workspace's Verification screen reports.
* **Property listing verification** (``services/property_verification_service``)
  — *is this ONE listing accurate, and does the submitter own it?* It is per
  ``fyp.rental_properties`` row and already exists.

Before this module there was no provider-level record at all, so the workspace
route had nowhere to read from. One table plus a submit / read / decide
lifecycle is the minimum that makes the screen real. Nothing is pre-approved:
a submission enters ``pending`` and only an administrator with a completed
second factor can decide it.
"""

from __future__ import annotations

import logging
import re
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.exceptions import ConflictError, NotFoundError, ValidationError

logger = logging.getLogger("sitewise.provider_verification")

#: Wire statuses the workspace renders. ``unsubmitted`` is the absence of a row.
PROVIDER_VERIFICATION_STATUSES: tuple[str, ...] = (
    "unsubmitted",
    "pending",
    "approved",
    "rejected",
)

#: What the provider has to supply, published so the screen and the server
#: explain the same requirements instead of two drifting copies.
REQUIREMENTS: tuple[dict[str, Any], ...] = (
    {
        "key": "business_name",
        "label": "Name you list under",
        "required": True,
        "help": "Your own name, or the agency you represent.",
    },
    {
        "key": "contact_phone",
        "label": "Contact phone",
        "required": True,
        "help": "The number a reviewer can reach you on.",
    },
    {
        "key": "registration_no",
        "label": "Business registration number",
        "required": False,
        "help": "Speeds up review when you are listing on behalf of a company.",
    },
    {
        "key": "submission_note",
        "label": "What you manage",
        "required": False,
        "help": "Which properties you own or represent, and in which areas.",
    },
)

_PHONE_RE = re.compile(r"^[0-9+\-\s()]{7,20}$")

_DDL_STATEMENTS: tuple[str, ...] = (
    """
    CREATE TABLE IF NOT EXISTS public.provider_verification (
        user_id UUID PRIMARY KEY
            REFERENCES public.users(user_id) ON DELETE CASCADE,
        provider_role TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        business_name TEXT NOT NULL,
        contact_phone TEXT NOT NULL,
        registration_no TEXT,
        submission_note TEXT,
        decision_note TEXT,
        submitted_at TIMESTAMPTZ,
        reviewed_at TIMESTAMPTZ,
        reviewed_by UUID,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        CONSTRAINT ck_provider_verification_status
            CHECK (status IN ('pending','approved','rejected')),
        CONSTRAINT ck_provider_verification_role
            CHECK (provider_role IN ('owner','agent'))
    )
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_provider_verification_status
        ON public.provider_verification (status)
    """,
)

_SELECT = """
SELECT v.user_id, v.provider_role, v.status, v.business_name, v.contact_phone,
       v.registration_no, v.submission_note, v.decision_note,
       v.submitted_at, v.reviewed_at, v.updated_at,
       u.full_name, u.email, u.role, u.account_status
FROM public.provider_verification v
LEFT JOIN public.users u ON u.user_id = v.user_id
"""


def _iso(value: Any) -> str | None:
    if value is None:
        return None
    return value.isoformat() if hasattr(value, "isoformat") else str(value)


def ensure_schema(session: Session) -> None:
    """Create the provider-verification table. Statements are idempotent."""
    for statement in _DDL_STATEMENTS:
        session.execute(text(statement))
    session.commit()


def provider_role_for(role: str) -> str:
    """Which provider relationship the account acts under.

    This returns the *relationship side* of the provider workspace, not an
    ``AppRole``. An ``agent`` account is the agent side; the owner side is taken
    by ``owner`` and — for accounts provisioned before the role split — by
    ``entrepreneur``. Which records either side reaches is decided by
    ``provider_scope`` from ownership and assignment rows, never from this label.
    """
    return "agent" if (role or "").strip().lower() == "agent" else "owner"


def _payload(row: Any) -> dict[str, Any]:
    return {
        "status": row["status"] or "unsubmitted",
        "provider_role": row["provider_role"],
        "details": {
            "business_name": row["business_name"] or "",
            "contact_phone": row["contact_phone"] or "",
            "registration_no": row["registration_no"] or "",
            "submission_note": row["submission_note"] or "",
        },
        "decision_note": row["decision_note"],
        "submitted_at": _iso(row["submitted_at"]),
        "reviewed_at": _iso(row["reviewed_at"]),
        "updated_at": _iso(row["updated_at"]),
    }


def _unsubmitted(role: str) -> dict[str, Any]:
    return {
        "status": "unsubmitted",
        "provider_role": provider_role_for(role),
        "details": {
            "business_name": "",
            "contact_phone": "",
            "registration_no": "",
            "submission_note": "",
        },
        "decision_note": None,
        "submitted_at": None,
        "reviewed_at": None,
        "updated_at": None,
    }


class ProviderVerificationService:
    """Read, submit and decide the account-level provider verification."""

    def __init__(self, session: Session):
        self.session = session

    # ------------------------------------------------------------------ read

    def status_for(self, *, user_id: Any, role: str) -> dict[str, Any]:
        """The caller's own verification state. Never invents a decision."""
        ensure_schema(self.session)
        row = self.session.execute(
            text(_SELECT + " WHERE v.user_id = :uid"),
            {"uid": str(user_id)},
        ).mappings().first()
        if row is None:
            return _unsubmitted(role)
        return _payload(row)

    # ---------------------------------------------------------------- submit

    def submit(
        self,
        *,
        user_id: Any,
        role: str,
        business_name: str,
        contact_phone: str,
        registration_no: str | None,
        submission_note: str | None,
    ) -> dict[str, Any]:
        """Enter (or re-enter) the review queue.

        The status is decided here, never by the caller: a submission is
        ``pending`` and nothing else. An approved account cannot re-submit
        (there is nothing left to verify); a pending one cannot either, since
        a second submission would only move the reviewer's target.
        """
        ensure_schema(self.session)
        current = self.status_for(user_id=user_id, role=role)
        if current["status"] == "approved":
            raise ConflictError("This account is already verified.")
        if current["status"] == "pending":
            raise ConflictError(
                "This verification is already with an administrator for review."
            )

        name = (business_name or "").strip()
        if len(name) < 2:
            raise ValidationError("Enter the name you list properties under.")
        if len(name) > 160:
            raise ValidationError("Keep the name under 160 characters.")
        phone = (contact_phone or "").strip()
        if not _PHONE_RE.match(phone):
            raise ValidationError(
                "Enter a contact phone number a reviewer can reach you on."
            )
        registration = (registration_no or "").strip()
        if len(registration) > 60:
            raise ValidationError("Keep the registration number under 60 characters.")
        note = (submission_note or "").strip()
        if len(note) > 2000:
            raise ValidationError("Keep the note under 2000 characters.")

        self.session.execute(
            text(
                """
                INSERT INTO public.provider_verification (
                    user_id, provider_role, status, business_name,
                    contact_phone, registration_no, submission_note,
                    submitted_at, updated_at
                ) VALUES (
                    :uid, :role, 'pending', :name, :phone,
                    NULLIF(:registration, ''), NULLIF(:note, ''),
                    now(), now()
                )
                ON CONFLICT (user_id) DO UPDATE SET
                    provider_role = EXCLUDED.provider_role,
                    status = 'pending',
                    business_name = EXCLUDED.business_name,
                    contact_phone = EXCLUDED.contact_phone,
                    registration_no = EXCLUDED.registration_no,
                    submission_note = EXCLUDED.submission_note,
                    decision_note = NULL,
                    reviewed_at = NULL,
                    reviewed_by = NULL,
                    submitted_at = now(),
                    updated_at = now()
                """
            ),
            {
                "uid": str(user_id),
                "role": provider_role_for(role),
                "name": name,
                "phone": phone,
                "registration": registration,
                "note": note,
            },
        )
        self.session.commit()
        logger.info("provider verification submitted user=%s", user_id)
        return self.status_for(user_id=user_id, role=role)

    # ---------------------------------------------------- invitation evidence

    def verify_from_invitation(
        self,
        *,
        user_id: Any,
        role: str,
        full_name: str = "",
        contact_phone: str = "",
    ) -> dict[str, Any]:
        """Approve an invited agent from accepted-invitation evidence.

        An agent whose official invitation was accepted and whose activation
        has completed is verified without a submission — the invitation
        lifecycle is stronger evidence than the self-submission the review
        queue exists for. Trusted backend paths only (``complete_onboarding``
        and the reconciliation read); nothing here is reachable by client
        input. Idempotent: ``user_id`` is the primary key so repeated
        completions can never create duplicate records, and the update arm
        refuses to overwrite a ``rejected`` decision an administrator made.
        """
        ensure_schema(self.session)
        self.session.execute(
            text(
                """
                INSERT INTO public.provider_verification (
                    user_id, provider_role, status, business_name,
                    contact_phone, updated_at
                ) VALUES (
                    :uid, :role, 'approved', :name, :phone, now()
                )
                ON CONFLICT (user_id) DO UPDATE SET
                    status = 'approved',
                    updated_at = now()
                WHERE public.provider_verification.status IN ('pending', 'approved')
                """
            ),
            {
                "uid": str(user_id),
                "role": provider_role_for(role),
                "name": (full_name or "").strip(),
                "phone": (contact_phone or "").strip(),
            },
        )
        self.session.commit()
        logger.info("provider verification approved via invitation user=%s", user_id)
        return self.status_for(user_id=user_id, role=role)

    # ----------------------------------------------------------------- admin

    def queue(
        self, *, status: str | None = None, limit: int = 100, offset: int = 0
    ) -> dict[str, Any]:
        """Administrator view of submissions, newest first."""
        ensure_schema(self.session)
        params: dict[str, Any] = {
            "limit": max(1, min(int(limit), 200)),
            "offset": max(0, int(offset)),
        }
        where = ""
        wanted = (status or "").strip()
        if wanted:
            if wanted not in PROVIDER_VERIFICATION_STATUSES or wanted == "unsubmitted":
                raise ValidationError(
                    "status must be one of: pending, approved, rejected"
                )
            where = " WHERE v.status = :status"
            params["status"] = wanted
        rows = self.session.execute(
            text(
                _SELECT
                + where
                + " ORDER BY v.submitted_at DESC NULLS LAST, v.updated_at DESC"
                + " LIMIT :limit OFFSET :offset"
            ),
            params,
        ).mappings().all()
        return {
            "data": [
                {
                    **_payload(row),
                    "user_id": str(row["user_id"]),
                    "full_name": row["full_name"],
                    "email": row["email"],
                    "role": row["role"],
                    "account_status": row["account_status"],
                }
                for row in rows
            ]
        }

    def decide(
        self,
        *,
        user_id: Any,
        decision: str,
        note: str | None,
        admin_user_id: Any,
    ) -> dict[str, Any]:
        """Approve or reject exactly one submission.

        Only a ``pending`` submission can be decided, so a replayed request
        cannot overwrite an existing decision.
        """
        ensure_schema(self.session)
        wanted = (decision or "").strip().lower()
        if wanted not in ("approve", "reject"):
            raise ValidationError("decision must be approve or reject.")
        reason = (note or "").strip()
        if wanted == "reject" and not reason:
            raise ValidationError("Give a reason so the provider can correct it.")
        if len(reason) > 2000:
            raise ValidationError("Keep the note under 2000 characters.")

        row = self.session.execute(
            text(_SELECT + " WHERE v.user_id = :uid"),
            {"uid": str(user_id)},
        ).mappings().first()
        if row is None:
            raise NotFoundError("That account has no verification submission.")
        if row["status"] != "pending":
            raise ConflictError(
                f"This submission is already {row['status']} and cannot be "
                "decided again."
            )

        self.session.execute(
            text(
                """
                UPDATE public.provider_verification
                   SET status = :status,
                       decision_note = NULLIF(:note, ''),
                       reviewed_at = now(),
                       reviewed_by = :admin,
                       updated_at = now()
                 WHERE user_id = :uid
                """
            ),
            {
                "status": "approved" if wanted == "approve" else "rejected",
                "note": reason,
                "admin": str(admin_user_id),
                "uid": str(user_id),
            },
        )
        self.session.commit()
        logger.info(
            "provider verification %s user=%s by=%s", wanted, user_id, admin_user_id
        )
        updated = self.session.execute(
            text(_SELECT + " WHERE v.user_id = :uid"),
            {"uid": str(user_id)},
        ).mappings().first()
        return _payload(updated) if updated else {}
