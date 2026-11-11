
"""
Project1 — UC Decision Gateway
CP1-B2/B3/B4 staging integration.

Responsibilities:
- Enforce the restricted UC database identity.
- Call the authorized UC PostgreSQL function.
- Preserve canonical M2/UC atomic persistence.
- Commit successful decisions or roll back failures.

Important:
- STAGING ONLY.
- No direct table writes.
- No JWT verification inside this repository.
- Actor UUID must originate from verified FastAPI authentication.
"""

from uuid import UUID

from sqlalchemy import text
from sqlmodel import Session


class UcDecisionGateway:
    """Dedicated UC PostgreSQL decision adapter."""

    ALLOWED_ACTIONS = frozenset({
        "CONFIRMED",
        "REJECTED",
        "DEFERRED",
        "WITHDRAWN",
    })

    # Preserve the existing B2/B3 PostgreSQL 16 tests
    # and the B4 PostgreSQL 18 isolated tests.
    ALLOWED_STAGE_TARGETS = frozenset({
        ("dss_uc_stage_tests", 5432, 16),
        ("dss_uc_stage_tests", 5433, 18),
    })

    REQUIRED_DB_ROLE = "p1uc_stage_human"

    DECISION_SQL = text("""
        SELECT
            project1_uc.record_authenticated_entrepreneur_decision(
                :actor_id,
                :event_id,
                :version_id,
                :action,
                :receipt
            )
    """)

    IDENTITY_SQL = text("""
        SELECT
            current_database() AS db_name,
            inet_server_port() AS server_port,
            session_user AS login_role,
            current_user AS effective_role,
            current_setting('server_version_num') AS version_num
    """)

    def __init__(self, session: Session):
        self.session = session

    def _verify_database_identity(self) -> None:
        """Reject unexpected databases and database principals."""

        row = self.session.execute(
            self.IDENTITY_SQL
        ).mappings().one()

        target = (
            row["db_name"],
            int(row["server_port"]),
            int(row["version_num"]) // 10000,
        )

        if target not in self.ALLOWED_STAGE_TARGETS:
            raise RuntimeError(
                "UC gateway refused an unauthorized database target."
            )

        if (
            row["login_role"] != self.REQUIRED_DB_ROLE
            or row["effective_role"] != self.REQUIRED_DB_ROLE
        ):
            raise PermissionError(
                "UC decision requires the restricted "
                "human database identity."
            )

    @staticmethod
    def _validate_request(
        verified_actor_user_id: UUID,
        event_id: UUID,
        candidate_version_id: UUID,
        action: str,
        receipt: str,
    ) -> None:
        """Validate request structure without changing exact values."""

        if not isinstance(verified_actor_user_id, UUID):
            raise ValueError(
                "A verified actor UUID is required."
            )

        if not isinstance(event_id, UUID):
            raise ValueError(
                "A valid UC event UUID is required."
            )

        if not isinstance(candidate_version_id, UUID):
            raise ValueError(
                "A valid UC candidate version UUID is required."
            )

        if action not in UcDecisionGateway.ALLOWED_ACTIONS:
            raise ValueError(
                "Invalid UC decision action."
            )

        if (
            not isinstance(receipt, str)
            or not 1 <= len(receipt.strip()) <= 2000
        ):
            raise ValueError(
                "UC receipt must contain 1–2000 "
                "non-whitespace characters."
            )

    def record_decision(
        self,
        *,
        verified_actor_user_id: UUID,
        event_id: UUID,
        candidate_version_id: UUID,
        action: str,
        receipt: str,
    ) -> UUID | None:
        """
        Persist one authorized UC decision.

        CONFIRMED:
            Returns the canonical M2 uncertainty UUID.

        Other actions:
            Returns None if no canonical uncertainty is created.

        PostgreSQL remains authoritative for:
            - M2 assessment ownership
            - source/version integrity
            - current candidate validation
            - action eligibility
            - idempotency
            - atomic canonical M2 + UC persistence

        Uses the supplied SQLAlchemy session.
        """

        self._validate_request(
            verified_actor_user_id,
            event_id,
            candidate_version_id,
            action,
            receipt,
        )

        try:
            self._verify_database_identity()

            result = self.session.execute(
                self.DECISION_SQL,
                {
                    "actor_id": verified_actor_user_id,
                    "event_id": event_id,
                    "version_id": candidate_version_id,
                    "action": action,
                    "receipt": receipt,
                },
            ).scalar_one()

            self.session.commit()

            return result

        except Exception:
            self.session.rollback()
            raise
