"""Assessment → M2 link service (CP-10 P4).

One responsibility: given a **marketplace** assessment id and the authenticated
entrepreneur, return the **M2** assessment that belongs to it — creating that M2
assessment and its binding only when no link exists.

What this service deliberately does **not** do
----------------------------------------------
* It never *adopts* an existing unlinked M2 assessment. Not by owner, not by
  recency, not by instrument. An unlinked record is left untouched, because
  ownership is not evidence that two records describe the same business
  decision. The one exception is :meth:`AssessmentLinkService.associate`, which
  is not adoption: the caller must name the exact M2 record, ownership and
  instrument usability are verified first, and an existing link is never
  reassigned. Nothing is backfilled behind the caller's back.
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

from sitewise.services.instrument_authorization import (
    authorization_reason, instrument_is_usable,
)

#: The **default** instrument code a marketplace assessment's M2 record is
#: built on. Selected by code + the single audited usability gate, never by
#: "most recent instrument".
#:
#: It remains ``M2V1`` so the production behaviour is byte-identical to before:
#: an M2V1-bound link resolves exactly the one ``AUTHORIZED`` M2V1 row. The
#: code is a *default*, not a hard pin — ``resolve`` accepts an explicit
#: ``instrument_code`` so a marketplace assessment can be bound to its M2 V2
#: record once that instrument is legitimately usable, while the refusal stays
#: intact when it is not (see :meth:`AssessmentLinkService._instrument_id`).
#:
#: The effective default is read from ``settings.m2_default_instrument_code``,
#: whose code default is this value. That lets the isolated PG18 E2E
#: environment build new M2 records on M2V2 without a source edit, while an
#: environment that never sets the setting keeps resolving M2V1 exactly as
#: before. It selects a *default* only; the audited usability gate still
#: decides whether the named code resolves to exactly one row.
INSTRUMENT_CODE = "M2V1"


def default_instrument_code() -> str:
    """The configured default instrument code, falling back to M2V1.

    Purpose: one place that answers "which instrument does a *new* M2 record
    use", so the answer can differ per environment without branching callers.

    Reason: production and the isolated E2E environment must be able to
    disagree about the default while running the same code. Hard-coding either
    value would force the other to carry a patch.

    Constraint: an empty or unset setting means M2V1, never "the newest
    instrument". Choosing by recency would silently re-point production at a
    candidate the first time anyone registered one.
    """
    from sitewise.core.config import settings

    configured = (getattr(settings, "m2_default_instrument_code", "") or "").strip()
    return configured or INSTRUMENT_CODE


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
        instrument_code: str | None = None,
    ) -> LinkResult:
        """Return the M2 assessment linked to this marketplace assessment.

        Order of checks matters: ownership is proven *before* anything is read
        from `Dss`, so an unauthorised caller cannot learn whether a link exists.

        ``instrument_code`` selects which instrument a **newly created** M2
        record is built on, and defaults to the configured instrument code
        (M2V1 unless the environment says otherwise), so the production
        behaviour is unchanged. It is honoured only on creation; an existing
        link reports the instrument its M2 record is actually bound to, read
        from the row rather than assumed from the request.
        """
        self._require_marketplace_ownership(marketplace_assessment_id, user_id)
        self._require_m2_identity(user_id, verified_email)

        existing = self._read_link(marketplace_assessment_id, user_id)
        if existing is not None:
            m2_id, revision, instrument_id = existing
            return LinkResult(
                marketplace_assessment_id=marketplace_assessment_id,
                m2_assessment_id=m2_id,
                revision=revision,
                # The linked record's own instrument, not the requested one.
                # Reporting the request here was a latent 503: reading a link
                # must not depend on an instrument code still being resolvable.
                instrument_version_id=instrument_id,
                created=False,
                identity_check=self.identity_check,
            )

        if not create_if_missing:
            raise AssessmentLinkError(
                "ASSESSMENT_NOT_LINKED",
                "This assessment has no M2 research record yet.",
                status_code=404,
            )
        return self._create_and_link(
            marketplace_assessment_id, user_id, instrument_code=instrument_code)

    def associate(
        self,
        *,
        marketplace_assessment_id: UUID,
        m2_assessment_id: UUID,
        user_id: UUID,
        verified_email: str | None = None,
    ) -> LinkResult:
        """Bind an **existing** M2 assessment to a marketplace assessment.

        This is the authorised association path, and it exists for one narrow
        purpose: an M2 assessment that was created outside the marketplace
        lifecycle (for example a synthetic or workbench record) has no link, so
        the assessment workspace cannot reach it. Rather than *silently*
        backfill such records, this operation performs the association the
        caller explicitly asks for, and refuses everything it cannot verify.

        It is deliberately fail-closed:

        * ownership of the marketplace assessment is proven first, exactly as
          in :meth:`resolve`, before any ``Dss`` read;
        * the M2 assessment must already be owned by the caller — the
          ``owner_user_id`` is compared, so an unowned id (whether absent or
          another account's) is refused rather than adopted;
        * the M2 assessment's instrument must be usable under the **single
          audited gate**. Against a production target a
          ``PROPOSED_NOT_AUTHORIZED`` candidate is therefore refused; only a
          genuinely ``AUTHORIZED`` instrument (or a candidate under an explicit
          disposable-target synthetic scope) can be associated;
        * an existing active link is never reassigned. Re-associating the same
          M2 assessment is idempotent; pointing the marketplace assessment at a
          *different* M2 record is refused rather than performed silently;
        * no proposal, decision, confirmation, admission or answer row is read
          for writing or touched. Only the binding is inserted.

        Nothing here is a backfill: the caller must name the exact M2 record,
        and every refusal leaves both databases exactly as they were.
        """
        self._require_marketplace_ownership(marketplace_assessment_id, user_id)
        self._require_m2_identity(user_id, verified_email)

        row = self._read_m2_owned(m2_assessment_id, user_id)
        if row is None:
            raise AssessmentLinkError(
                "M2_ASSESSMENT_NOT_FOUND",
                "No such M2 assessment is visible to this account.",
                status_code=404,
            )
        if str(row["owner_user_id"]) != str(user_id):
            raise AssessmentLinkError(
                "ASSESSMENT_NOT_OWNED",
                "That M2 assessment belongs to another account.",
                status_code=403,
            )
        if not instrument_is_usable(dict(row)):
            raise AssessmentLinkError(
                "INSTRUMENT_NOT_USABLE",
                f"The instrument behind that M2 assessment is not usable "
                f"({authorization_reason(dict(row))}).",
                status_code=409,
            )

        existing = self._read_link(marketplace_assessment_id, user_id)
        if existing is not None:
            current, revision, instrument_id = existing
            if current == m2_assessment_id:
                return LinkResult(
                    marketplace_assessment_id=marketplace_assessment_id,
                    m2_assessment_id=current,
                    revision=revision,
                    instrument_version_id=instrument_id,
                    created=False,
                    identity_check=self.identity_check,
                )
            raise AssessmentLinkError(
                "LINK_ALREADY_EXISTS",
                "This assessment is already linked to a different M2 record. "
                "Re-association is not performed silently.",
                status_code=409,
            )

        instrument_id = UUID(str(row["instrument_id"]))
        try:
            with self._m2.begin() as conn:
                conn.execute(
                    text("select set_config('project1.actor_id', :actor, true)"),
                    {"actor": str(user_id)},
                )
                conn.execute(
                    text(
                        """
                        insert into public.m2_assessment_links
                            (m2_assessment_id, marketplace_assessment_id, user_id, created_by)
                        values (:m2, :mp, :uid, :uid)
                        """
                    ),
                    {"m2": str(m2_assessment_id), "mp": str(marketplace_assessment_id),
                     "uid": str(user_id)},
                )
        except IntegrityError as exc:
            orig = getattr(exc, "orig", None)
            pgcode = getattr(orig, "pgcode", None)
            constraint = getattr(getattr(orig, "diag", None), "constraint_name", None) or ""
            if pgcode == "23503" and "owner_user" in constraint:
                raise AssessmentLinkError(
                    "M2_IDENTITY_MISSING",
                    "This account has no M2 identity yet. Identity provisioning is a "
                    "separately authorised step.",
                    status_code=409,
                ) from exc
            # Lost a race to another writer; the winning link is the truth.
            winner = self._read_link(marketplace_assessment_id, user_id)
            if winner is None or winner[0] != m2_assessment_id:
                raise AssessmentLinkError(
                    "LINK_CONFLICT",
                    "The association could not be stored. Retry the request.",
                    status_code=409,
                ) from exc
            raise AssessmentLinkError(
                "LINK_ALREADY_EXISTS",
                "This assessment was linked concurrently. No second link was written.",
                status_code=409,
            ) from exc

        return LinkResult(
            marketplace_assessment_id=marketplace_assessment_id,
            m2_assessment_id=m2_assessment_id,
            revision=int(row["revision"]),
            instrument_version_id=instrument_id,
            created=True,
            identity_check=self.identity_check,
        )

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

    def _read_link(
        self, assessment_id: UUID, user_id: UUID
    ) -> tuple[UUID, int, UUID] | None:
        with self._m2.connect() as conn:
            conn.execute(
                text("select set_config('project1.actor_id', :actor, true)"),
                {"actor": str(user_id)},
            )
            row = conn.execute(
                text(
                    """
                    select l.m2_assessment_id, a.revision, a.instrument_id
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
        return (UUID(str(row["m2_assessment_id"])), int(row["revision"]),
                UUID(str(row["instrument_id"])))

    def _read_m2_owned(self, m2_assessment_id: UUID, user_id: UUID) -> dict | None:
        """Read one M2 assessment with its instrument state, actor-scoped.

        ``project1.actor_id`` is set so the ``owner_scope`` RLS policy applies:
        a row another account owns is *not* returned here. The caller still
        compares ``owner_user_id`` explicitly, so ownership is proven twice
        rather than resting on the policy alone.
        """
        with self._m2.connect() as conn:
            conn.execute(
                text("select set_config('project1.actor_id', :actor, true)"),
                {"actor": str(user_id)},
            )
            row = conn.execute(
                text(
                    """
                    select a.id, a.owner_user_id, a.revision, a.confirmed_revision,
                           a.instrument_id, v.code as instrument_code,
                           v.approval_state
                    from public.m2_assessments a
                    join public.m2_instrument_versions v on v.id = a.instrument_id
                    where a.id = :id
                    """
                ),
                {"id": str(m2_assessment_id)},
            ).mappings().first()
            conn.rollback()
        return dict(row) if row is not None else None

    def _instrument_id(self, code: str | None = None) -> UUID:
        """Resolve the single **usable** instrument row for ``code``.

        Usability is decided by the one audited gate
        (``instrument_authorization.instrument_is_usable``), never by comparing
        ``approval_state`` here. That preserves the production premise exactly —
        an ``AUTHORIZED`` instrument is usable — while letting the same code
        resolve a ``PROPOSED_NOT_AUTHORIZED`` candidate *only* while an explicit
        disposable-target synthetic scope is active. Against ``Dss`` on 5432 the
        scope can never activate, so a not-yet-authorized candidate stays
        unusable and the refusal below fires.
        """
        instrument_code = code or default_instrument_code()
        with self._m2.connect() as conn:
            rows = conn.execute(
                text(
                    """
                    select id, code, approval_state
                    from public.m2_instrument_versions
                    where code = :code
                    """
                ),
                {"code": instrument_code},
            ).mappings().all()
            conn.rollback()
        usable = [row for row in rows if instrument_is_usable(dict(row))]
        if len(usable) != 1:
            # 0 => nothing usable; >1 => ambiguous. Both must refuse rather than
            # guess which instrument the entrepreneur is answering. The reason
            # is reported so a diagnostics caller can tell "no such code" from
            # "candidate present, synthetic scope inactive".
            reasons = sorted(authorization_reason(dict(row)) for row in rows)
            raise AssessmentLinkError(
                "INSTRUMENT_NOT_UNAMBIGUOUS",
                f"Expected exactly one usable {instrument_code} instrument, "
                f"found {len(usable)}."
                + (f" States seen: {', '.join(reasons)}." if reasons else ""),
                status_code=503,
            )
        return UUID(str(usable[0]["id"]))

    # ---------------------------------------------------------------- create

    def _create_and_link(
        self, assessment_id: UUID, user_id: UUID, *, instrument_code: str | None = None
    ) -> LinkResult:
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
        instrument_id = self._instrument_id(instrument_code)
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
            m2_won, revision, winner_instrument = winner
            return LinkResult(
                marketplace_assessment_id=assessment_id,
                m2_assessment_id=m2_won,
                revision=revision,
                instrument_version_id=winner_instrument,
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
