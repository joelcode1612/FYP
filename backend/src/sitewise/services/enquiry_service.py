"""Property enquiries — real, database-backed messages about a listing.

There was no enquiry storage anywhere in the project. The retired Agent web
page documented the absence and rendered demonstration rows, and the retired
performance page listed "Enquiries" as a stage nothing could write to. This
module adds the minimum a working provider inbox needs: ONE table plus the
create / list / update operations. No leads are invented, no quality score is
manufactured, and no contact event is simulated.

Lifecycle
---------
An enquiry starts as ``new`` and a provider moves it forward:

    new -> read -> replied -> closed

``new`` is the initial state, not a target: a provider cannot "un-read" a
message, so it is rejected as an update value rather than silently accepted.
``replied`` carries the provider's answer, which is what makes the transition
mean something.
"""

from __future__ import annotations

import logging
from typing import Any

from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.exceptions import ConflictError, NotFoundError, ValidationError

logger = logging.getLogger("sitewise.enquiries")

#: Initial state plus the three forward transitions a provider may set.
ENQUIRY_STATUSES: tuple[str, ...] = ("new", "read", "replied", "closed")
#: The states a provider is allowed to move an enquiry INTO.
PROVIDER_SETTABLE_STATUSES: tuple[str, ...] = ("read", "replied", "closed")

MESSAGE_MIN = 10
MESSAGE_MAX = 2000
REPLY_MIN = 2
REPLY_MAX = 2000

_DDL_STATEMENTS: tuple[str, ...] = (
    """
    CREATE TABLE IF NOT EXISTS fyp.property_enquiry (
        enquiry_id BIGSERIAL PRIMARY KEY,
        property_id BIGINT NOT NULL
            REFERENCES fyp.rental_properties(id) ON DELETE CASCADE,
        enquirer_user_id UUID
            REFERENCES public.users(user_id) ON DELETE SET NULL,
        enquirer_name TEXT NOT NULL,
        enquirer_email TEXT NOT NULL,
        message TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'new',
        provider_reply TEXT,
        replied_by UUID,
        replied_at TIMESTAMPTZ,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        CONSTRAINT ck_property_enquiry_status
            CHECK (status IN ('new','read','replied','closed'))
    )
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_property_enquiry_property
        ON fyp.property_enquiry (property_id)
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_property_enquiry_status
        ON fyp.property_enquiry (status)
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_property_enquiry_created
        ON fyp.property_enquiry (created_at DESC)
    """,
)

#: The property columns an inbox row needs to name the listing it concerns.
_ENQUIRY_SELECT = """
SELECT e.enquiry_id, e.property_id, e.enquirer_name, e.enquirer_email,
       e.message, e.status, e.provider_reply, e.created_at, e.updated_at,
       e.replied_at,
       p.name AS property_name, p.address, p.city, p.state,
       p.verification_status, p.is_published
FROM fyp.property_enquiry e
JOIN fyp.rental_properties p ON p.id = e.property_id
"""


def _iso(value: Any) -> str | None:
    if value is None:
        return None
    return value.isoformat() if hasattr(value, "isoformat") else str(value)


def _row_payload(row: Any) -> dict[str, Any]:
    address = ", ".join(
        part
        for part in (row["address"], row["city"], row["state"])
        if part not in (None, "")
    )
    name = (row["property_name"] or "").strip()
    return {
        "id": int(row["enquiry_id"]),
        "property_id": int(row["property_id"]),
        "property_title": name or f"Listing L-{int(row['property_id'])}",
        "property_address": address,
        "property_published": bool(row["is_published"])
        and row["verification_status"] == "approved",
        "enquirer_name": row["enquirer_name"],
        "enquirer_email": row["enquirer_email"],
        "message": row["message"],
        "status": row["status"],
        "provider_reply": row["provider_reply"],
        "created_at": _iso(row["created_at"]),
        "updated_at": _iso(row["updated_at"]),
        "replied_at": _iso(row["replied_at"]),
    }


def ensure_schema(session: Session) -> None:
    """Create the enquiry table. Every statement is idempotent."""
    for statement in _DDL_STATEMENTS:
        session.execute(text(statement))
    session.commit()


class EnquiryService:
    """Create, read and progress property enquiries.

    Every read takes the caller's managed property ids (see
    :mod:`sitewise.services.provider_scope`) and filters on them, so one
    provider can never reach another provider's inbox.
    """

    def __init__(self, session: Session):
        self.session = session

    # ---------------------------------------------------------------- create

    def create(
        self,
        *,
        property_id: int,
        enquirer_user_id: Any,
        enquirer_name: str,
        enquirer_email: str,
        message: str,
    ) -> dict[str, Any]:
        """Record one enquiry against a published listing.

        The listing must be publicly reachable (``is_published`` AND
        ``approved``): an unpublished draft is not something a prospective
        tenant can find, so a 404 here also prevents probing the catalogue by
        id.
        """
        ensure_schema(self.session)
        body = (message or "").strip()
        if len(body) < MESSAGE_MIN:
            raise ValidationError(
                f"Please write at least {MESSAGE_MIN} characters so the "
                "provider knows what you are asking about."
            )
        if len(body) > MESSAGE_MAX:
            raise ValidationError(
                f"Please keep the enquiry under {MESSAGE_MAX} characters."
            )
        name = (enquirer_name or "").strip()
        email = (enquirer_email or "").strip()
        if not name:
            raise ValidationError("A contact name is required.")
        if "@" not in email or len(email) < 5:
            raise ValidationError("A valid contact email is required.")

        exists = self.session.execute(
            text(
                """
                SELECT 1 FROM fyp.rental_properties
                WHERE id = :pid AND is_published AND verification_status = 'approved'
                """
            ),
            {"pid": int(property_id)},
        ).first()
        if exists is None:
            raise NotFoundError("That listing is not available.")

        row = self.session.execute(
            text(
                """
                INSERT INTO fyp.property_enquiry (
                    property_id, enquirer_user_id, enquirer_name,
                    enquirer_email, message
                ) VALUES (
                    :pid, :uid, :name, :email, :message
                )
                RETURNING enquiry_id
                """
            ),
            {
                "pid": int(property_id),
                "uid": str(enquirer_user_id) if enquirer_user_id else None,
                "name": name[:160],
                "email": email[:255],
                "message": body,
            },
        ).first()
        self.session.commit()
        enquiry_id = int(row[0])
        logger.info(
            "property enquiry recorded enquiry=%s property=%s", enquiry_id, property_id
        )
        return self.get(enquiry_id, property_ids=None) or {"id": enquiry_id}

    # ------------------------------------------------------------------ read

    def get(
        self, enquiry_id: int, *, property_ids: list[int] | None
    ) -> dict[str, Any] | None:
        """One enquiry, or ``None`` when it is outside the caller's scope.

        Out-of-scope and non-existent are deliberately the same answer: the
        caller learns nothing about another provider's inbox.
        """
        ensure_schema(self.session)
        row = self.session.execute(
            text(_ENQUIRY_SELECT + " WHERE e.enquiry_id = :eid"),
            {"eid": int(enquiry_id)},
        ).mappings().first()
        if row is None:
            return None
        if property_ids is not None and int(row["property_id"]) not in property_ids:
            return None
        return _row_payload(row)

    def list_for_provider(
        self,
        *,
        property_ids: list[int] | None,
        status: str | None = None,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        """Every enquiry received for the properties the caller manages."""
        ensure_schema(self.session)
        clauses: list[str] = []
        params: dict[str, Any] = {}
        if property_ids is not None:
            if not property_ids:
                return []
            names = [f"__pid_{i}" for i in range(len(property_ids))]
            clauses.append(
                "e.property_id IN ("
                + ", ".join(f":{name}" for name in names)
                + ")"
            )
            params.update(
                dict(zip(names, (int(v) for v in property_ids), strict=True))
            )
        wanted = (status or "").strip()
        if wanted:
            if wanted not in ENQUIRY_STATUSES:
                raise ValidationError(
                    "status must be one of: " + ", ".join(ENQUIRY_STATUSES)
                )
            clauses.append("e.status = :status")
            params["status"] = wanted
        where = (" WHERE " + " AND ".join(clauses)) if clauses else ""
        params["limit"] = max(1, min(int(limit), 500))
        rows = self.session.execute(
            text(
                _ENQUIRY_SELECT
                + where
                + " ORDER BY e.created_at DESC, e.enquiry_id DESC LIMIT :limit"
            ),
            params,
        ).mappings().all()
        return [_row_payload(row) for row in rows]

    # ---------------------------------------------------------------- update

    def set_status(
        self,
        enquiry_id: int,
        *,
        status: str,
        property_ids: list[int] | None,
        actor_user_id: Any,
        reply: str | None = None,
    ) -> dict[str, Any]:
        """Progress one enquiry. Refuses any change outside the caller's scope.

        Only the three forward transitions are accepted: see
        ``PROVIDER_SETTABLE_STATUSES``.
        """
        ensure_schema(self.session)
        wanted = (status or "").strip().lower()
        if wanted not in PROVIDER_SETTABLE_STATUSES:
            raise ValidationError(
                "An enquiry can be marked "
                + ", ".join(PROVIDER_SETTABLE_STATUSES)
                + ". 'new' is the state a message arrives in, not a state you "
                "can set."
            )
        current = self.get(enquiry_id, property_ids=property_ids)
        if current is None:
            raise NotFoundError("That enquiry is not in your inbox.")

        answer = (reply or "").strip()
        if wanted == "replied":
            if len(answer) < REPLY_MIN:
                raise ValidationError(
                    "Write a reply so the enquirer has an answer."
                )
            if len(answer) > REPLY_MAX:
                raise ValidationError(
                    f"Please keep the reply under {REPLY_MAX} characters."
                )
        if current["status"] == "closed" and wanted != "closed":
            raise ConflictError(
                "This enquiry is closed. Closed enquiries are kept for your "
                "records and are not re-opened."
            )

        self.session.execute(
            text(
                """
                UPDATE fyp.property_enquiry
                   SET status = :status,
                       provider_reply = CASE
                           WHEN :reply IS NULL THEN provider_reply
                           ELSE :reply END,
                       replied_by = CASE
                           WHEN :reply IS NULL THEN replied_by
                           ELSE :actor END,
                       replied_at = CASE
                           WHEN :reply IS NULL THEN replied_at
                           ELSE now() END,
                       updated_at = now()
                 WHERE enquiry_id = :eid
                """
            ),
            {
                "status": wanted,
                "reply": answer or None,
                "actor": str(actor_user_id),
                "eid": int(enquiry_id),
            },
        )
        self.session.commit()
        updated = self.get(enquiry_id, property_ids=property_ids)
        if updated is None:  # pragma: no cover - row cannot vanish mid-request
            raise NotFoundError("That enquiry is not in your inbox.")
        return updated

    # --------------------------------------------------------------- metrics

    def metrics(self, *, property_ids: list[int] | None) -> dict[str, Any]:
        """Counts over the caller's own enquiries — arithmetic, never estimate."""
        ensure_schema(self.session)
        params: dict[str, Any] = {}
        where = ""
        if property_ids is not None:
            if not property_ids:
                return {
                    "total": 0,
                    "by_status": {name: 0 for name in ENQUIRY_STATUSES},
                    "last_received_at": None,
                }
            names = [f"__pid_{i}" for i in range(len(property_ids))]
            where = (
                " WHERE property_id IN ("
                + ", ".join(f":{name}" for name in names)
                + ")"
            )
            params.update(
                dict(zip(names, (int(v) for v in property_ids), strict=True))
            )
        rows = self.session.execute(
            text(
                "SELECT status, count(*)::int AS n FROM fyp.property_enquiry"
                + where
                + " GROUP BY status"
            ),
            params,
        ).mappings().all()
        by_status = {name: 0 for name in ENQUIRY_STATUSES}
        for row in rows:
            if row["status"] in by_status:
                by_status[row["status"]] = int(row["n"])
        latest = self.session.execute(
            text(
                "SELECT max(created_at) AS last FROM fyp.property_enquiry" + where
            ),
            params,
        ).mappings().first()
        return {
            "total": sum(by_status.values()),
            "by_status": by_status,
            "last_received_at": _iso(latest["last"]) if latest else None,
        }
