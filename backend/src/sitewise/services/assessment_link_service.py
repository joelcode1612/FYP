"""Assessment → M2 link service (CP-10 P4).

One responsibility: given a **marketplace** assessment id and the authenticated
entrepreneur, return the **M2** assessment that belongs to it — creating that M2
assessment and its binding only when no link exists.

What this service deliberately does **not** do
----------------------------------------------
* It never adopts an existing unlinked M2 assessment. Not by owner, not by
  recency, not by instrument. An unlinked record is left untouched, because
  ownership is not evidence that two records describe the same business decision.
* It never spans both databases in one transaction. `public.assessment` lives in
  `Final_Location_Analysis`; `m2_assessments` and `m2_assessment_links` live in
  `Dss`. PostgreSQL cannot make that atomic, so the service is written for
  partial failure instead of pretending otherwise (see ``resolve``).
* It never creates a CQ campaign, a confirmation, a BDJ evaluation or anything
  downstream. Creating an assessment must not start research.

Identity contract
-----------------
The caller's identity is the verified token subject (``sub``), already resolved
to a UUID by ``dependencies.get_current_user``. This service does **not** read the
token. It does compare the stored Dss email against the caller's verified email
when one is supplied, and refuses on mismatch with ``IDENTITY_COLLISION`` rather
than overwriting a profile.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from uuid import UUID, uuid4

from sqlalchemy import text
from sqlalchemy.engine import Engine
from sqlalchemy.exc import IntegrityError, SQLAlchemyError

#: The instrument the questionnaire is built from. Selected by code + approval
#: state, never by "most recent instrument".
INSTRUMENT_CODE = "M2V1"


class AssessmentLinkError(Exception):
    """A refusal with a stable code the API layer can map to a status."""

    def __init__(self, code: str, message: str, status_code: int = 409):
        self.code = code
        self.status_code = status_code
        super().__init__(message)


@dataclass(frozen=True)
class LinkResult:
    marketplace_assessment_id: UUID
    m2_assessment_id: UUID
    revision: int
    instrument_version_id: UUID
    created: bool
    identity_check: str = "FK_ONLY"

    def as_dict(self) -> dict[str, Any]:
        return {
            "marketplace_assessment_id": str(self.marketplace_assessment_id),
            "m2_assessment_id": str(self.m2_assessment_id),
            "revision": self.revision,
            "instrument_version_id": str(self.instrument_version_id),
            "created": self.created,
            "identity_check": self.identity_check,
        }


class AssessmentLinkService:
    def __init__(self, *, marketplace_engine: Engine, m2_engine: Engine):
        self._marketplace = marketplace_engine
        self._m2 = m2_engine
        #: "VERDICT" when m2_identity_status() is installed, "FK_ONLY" otherwise.
        #: Reported on every result so the caller can tell which guarantee held.
        self.identity_check = "FK_ONLY"

    # ---------------------------------------------------------------- public

    def resolve(
        self,
        *,
        marketplace_assessment_id: UUID,
        user_id: UUID,
        verified_email: str | None = None,
        create_if_missing: bool = True,
    ) -> LinkResult:
        """Return the M2 assessment linked to this marketplace assessment.

        Order of checks matters: ownership is proven *before* anything is read
        from `Dss`, so an unauthorised caller cannot learn whether a link exists.
        """
        self._require_marketplace_ownership(marketplace_assessment_id, user_id)
        self._require_m2_identity(user_id, verified_email)

        existing = self._read_link(marketplace_assessment_id, user_id)
        if existing is not None:
            m2_id, revision = existing
            return LinkResult(
                marketplace_assessment_id=marketplace_assessment_id,
                m2_assessment_id=m2_id,
                revision=revision,
                instrument_version_id=self._instrument_id(),
                created=False,
                identity_check=self.identity_check,
            )

        if not create_if_missing:
            raise AssessmentLinkError(
                "ASSESSMENT_NOT_LINKED",
                "This assessment has no M2 research record yet.",
                status_code=404,
            )
        return self._create_and_link(marketplace_assessment_id, user_id)

    # ----------------------------------------------------------- marketplace

    def _require_marketplace_ownership(self, assessment_id: UUID, user_id: UUID) -> None:
        """The marketplace row is the authority for 'this is the entrepreneur's
        assessment'. It cannot be FK-enforced from `Dss`, so it is checked here,
        every call, before any Dss read."""
        try:
            with self._marketplace.connect() as conn:
                row = conn.execute(
                    text(
                        "select user_id from public.assessment where assessment_id = :aid"
                    ),
                    {"aid": str(assessment_id)},
                ).mappings().first()
                conn.rollback()
        except SQLAlchemyError as exc:
            raise AssessmentLinkError(
                "MARKETPLACE_UNAVAILABLE",
                "The assessment service could not be reached.",
                status_code=503,
            ) from exc

        if row is None:
            raise AssessmentLinkError(
                "ASSESSMENT_NOT_FOUND",
                "No such assessment.",
                status_code=404,
            )
        if str(row["user_id"]) != str(user_id):
            # Same response as "not found" would leak less, but the workspace
            # already knows the id; an explicit 403 is clearer to the UI.
            raise AssessmentLinkError(
                "ASSESSMENT_NOT_OWNED",
                "This assessment belongs to another account.",
                status_code=403,
            )

    # -------------------------------------------------------------- identity

    def _require_m2_identity(self, user_id: UUID, verified_email: str | None) -> None:
        """Verify the stored identity, or fall back to database-enforced verification.

        Two modes, and the mode actually used is reported on the result:

        ``VERDICT``
            ``public.m2_identity_status(expected_email)`` answers
            ``MATCH`` / ``COLLISION`` / ``MISSING``. Preferred: it catches an
            identity collision (same subject, different stored email) before any
            row is written.

        ``FK_ONLY``
            The verdict function is not installed. Authenticity still comes from
            the verified JWT subject, and existence/ownership are still enforced —
            by ``fk_m2_owner_user`` on insert, which the database checks itself.
            What is *lost* is collision detection: a subject whose stored email
            differs from the token's would not be refused here.

            This mode reads nothing from ``public.users``. It is not a bypass of
            authenticity or ownership; it is the absence of one optional
            data-quality guard, and it is recorded as such rather than hidden.
        """
        self.identity_check = "FK_ONLY"
        with self._m2.connect() as conn:
            conn.execute(
                text("select set_config('project1.actor_id', :actor, true)"),
                {"actor": str(user_id)},
            )
            try:
                verdict = conn.execute(
                    text("select public.m2_identity_status(:email)"),
                    {"email": verified_email or ""},
                ).scalar()
            except SQLAlchemyError as exc:
                conn.rollback()
                # 42883 = undefined_function. Anything else is a real failure.
                if getattr(getattr(exc, "orig", None), "pgcode", None) == "42883":
                    return  # FK_ONLY
                raise AssessmentLinkError(
                    "IDENTITY_CHECK_UNAVAILABLE",
                    "The M2 identity cannot be verified with the current "
                    "database privileges.",
                    status_code=503,
                ) from exc
            conn.rollback()

        self.identity_check = "VERDICT"
        if verdict == "MISSING":
            raise AssessmentLinkError(
                "M2_IDENTITY_MISSING",
                "This account has no M2 identity yet. Identity provisioning is a "
                "separately authorised step.",
                status_code=409,
            )
        if verdict == "COLLISION":
            raise AssessmentLinkError(
                "IDENTITY_COLLISION",
                "This account's M2 identity does not match the signed-in identity.",
                status_code=409,
            )
        if verdict != "MATCH":
            raise AssessmentLinkError(
                "IDENTITY_CHECK_UNAVAILABLE",
                "The M2 identity check returned an unrecognised result.",
                status_code=503,
            )

    # ------------------------------------------------------------------ read

    def _read_link(self, assessment_id: UUID, user_id: UUID) -> tuple[UUID, int] | None:
        with self._m2.connect() as conn:
            conn.execute(
                text("select set_config('project1.actor_id', :actor, true)"),
                {"actor": str(user_id)},
            )
            row = conn.execute(
                text(
                    """
                    select l.m2_assessment_id, a.revision
                    from public.m2_assessment_links l
                    join public.m2_assessments a on a.id = l.m2_assessment_id
                    where l.marketplace_assessment_id = :mp
                      and l.revoked_at is null
                    """
                ),
                {"mp": str(assessment_id)},
            ).mappings().first()
            conn.rollback()
        if row is None:
            return None
        return UUID(str(row["m2_assessment_id"])), int(row["revision"])

    def _instrument_id(self) -> UUID:
        with self._m2.connect() as conn:
            rows = conn.execute(
                text(
                    """
                    select id from public.m2_instrument_versions
                    where code = :code and approval_state = 'AUTHORIZED'
                    """
                ),
                {"code": INSTRUMENT_CODE},
            ).mappings().all()
            conn.rollback()
        if len(rows) != 1:
            # 0 => nothing authorised; >1 => ambiguous. Both must refuse rather
            # than guess which instrument the entrepreneur is answering.
            raise AssessmentLinkError(
                "INSTRUMENT_NOT_UNAMBIGUOUS",
                f"Expected exactly one AUTHORIZED {INSTRUMENT_CODE} instrument, "
                f"found {len(rows)}.",
                status_code=503,
            )
        return UUID(str(rows[0]["id"]))

    # ---------------------------------------------------------------- create

    def _create_and_link(self, assessment_id: UUID, user_id: UUID) -> LinkResult:
        """Create the M2 assessment and its binding in **one Dss transaction**.

        Concurrency: the link's partial unique index on
        ``marketplace_assessment_id`` is the arbiter. Both racing transactions
        insert an M2 assessment and then attempt the link; the loser fails the
        unique index, rolls the *whole* transaction back (so its M2 assessment
        never exists), and re-reads the winner's link. No orphan is committed.

        Partial failure across databases: the marketplace assessment is already
        committed before this runs. If this transaction fails, the marketplace
        assessment simply has no link yet — the next open retries. Nothing is
        deleted to "tidy up", because deleting an assessment would destroy the
        entrepreneur's work.
        """
        instrument_id = self._instrument_id()
        m2_id = uuid4()

        try:
            with self._m2.begin() as conn:
                conn.execute(
                    text("select set_config('project1.actor_id', :actor, true)"),
                    {"actor": str(user_id)},
                )
                conn.execute(
                    text(
                        """
                        insert into public.m2_assessments
                            (id, owner_user_id, instrument_id, revision)
                        values (:id, :owner, :instrument, 0)
                        """
                    ),
                    {"id": str(m2_id), "owner": str(user_id), "instrument": str(instrument_id)},
                )
                conn.execute(
                    text(
                        """
                        insert into public.m2_assessment_links
                            (m2_assessment_id, marketplace_assessment_id, user_id, created_by)
                        values (:m2, :mp, :uid, :uid)
                        """
                    ),
                    {"m2": str(m2_id), "mp": str(assessment_id), "uid": str(user_id)},
                )
        except IntegrityError as exc:
            orig = getattr(exc, "orig", None)
            pgcode = getattr(orig, "pgcode", None)
            constraint = getattr(getattr(orig, "diag", None), "constraint_name", None) or ""

            # FK_ONLY mode: the database is the identity verifier. A missing
            # Dss.users row surfaces here as fk_m2_owner_user, and is reported
            # with the same code the VERDICT mode would have produced.
            if pgcode == "23503" and "owner_user" in constraint:
                raise AssessmentLinkError(
                    "M2_IDENTITY_MISSING",
                    "This account has no M2 identity yet. Identity provisioning is a "
                    "separately authorised step.",
                    status_code=409,
                ) from exc

            # Otherwise: lost the race (or a revoked-then-rebound edge). The
            # transaction is already rolled back, so our M2 row does not exist.
            winner = self._read_link(assessment_id, user_id)
            if winner is None:
                raise AssessmentLinkError(
                    "LINK_CONFLICT",
                    "The assessment could not be linked. Retry the request.",
                    status_code=409,
                )
            m2_won, revision = winner
            return LinkResult(
                marketplace_assessment_id=assessment_id,
                m2_assessment_id=m2_won,
                revision=revision,
                instrument_version_id=instrument_id,
                created=False,
                identity_check=self.identity_check,
            )

        return LinkResult(
            marketplace_assessment_id=assessment_id,
            m2_assessment_id=m2_id,
            revision=0,
            instrument_version_id=instrument_id,
            created=True,
            identity_check=self.identity_check,
        )
