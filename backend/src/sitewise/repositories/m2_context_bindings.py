"""M2-backed BCB binding resolver and the minimum ownership authorization port.

Replaces the refusing ``UnverifiedContextBindings`` stub. Every governed binding
is derived from a persisted M2 record and nothing else:

* ``m2_assessments.owner_user_id`` — the ownership authority, and the only tenant
  identity used (an owner-scoped label, not a tenant registry);
* ``m2_confirmation_snapshots`` — confirmation identity, revision, digest and
  actor, i.e. the confirmed concept version;
* ``m2_bdj_findings`` at the confirmed revision — applicable deterministic
  findings and their rule versions;
* ``m2_confirmed_uncertainties`` — the entrepreneur-confirmed uncertainty;
* existing source references — there is no M2 table holding qualified external
  evidence for this assessment, so the list is empty and the packet reports
  ``EXTERNAL_EVIDENCE_MISSING`` instead of an invented citation.

Nothing else is manufactured. A verified finding authority, an approval receipt,
a tenant registry, a GEO catalogue or an external source citation cannot be
derived from these tables, so those slots stay empty and the frozen builder
fails closed on them with its own specific code.

Determinism: identical persisted state must yield an identical packet, otherwise
repeated builds would create new contexts instead of replaying one. The access
decision is therefore a pure function of the confirmation, never of wall-clock
time, and its validity horizon is an explicit input -- never an invented default.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import and_, select, text
from sqlalchemy.exc import SQLAlchemyError

from sitewise.db.models.m2_schema import uncertainties
from sitewise.repositories.m2_repository import SqlModelM2Repository
from sitewise.services.business_context_v1 import (
    PURPOSES, UTCClock, ContextRefused, current_business_description, json_value, require,
    source_hash,
)
from sitewise.services.ports.business_context_store_port import (
    ContextBindingUnavailable, GovernedContextInputs,
)
from sitewise.services.ports.business_context_v1_port import ContextRequest

#: Owner-scoped tenant label. The ownership authority is the tenant boundary;
#: no separate tenant registry exists and none is invented.
TENANT_PREFIX = "m2-owner:"

#: The restricted principal that owns the ``public.m2_*`` grants. It is a
#: different role from ``p1ai_runtime`` (which owns the ``project1_ai`` grants):
#: two schemas, two principals. It is NOSUPERUSER / NOBYPASSRLS, so its
#: ``owner_scope`` policies actually apply.
RESTRICTED_ROLE = "p1_m2_runtime"

#: Business Description item used by instrument versions that predate M2V1.
DECLARED_DESCRIPTION_ITEM = "M2-04"
M2V1_INSTRUMENT_VERSION = "M2V1-20261114-1"


def bind_restricted_principal(session, actor_id) -> None:
    """Establish the restricted M2 principal and owner GUC on this transaction.

    Mirrors ``project1/ledger.py``. Statements must execute as
    ``p1_m2_runtime`` and the owner policies read ``project1.actor_id``. Two
    paths reach that state:

    * a direct ``p1_m2_runtime`` login (production ``M2_DATABASE_URL``), or
    * ``SET LOCAL ROLE p1_m2_runtime`` from a login that may assume it. The
      disposable harness logs in as a superuser; RLS still applies to
      ``current_user`` after the switch, so the harness exercises the same
      policy path rather than bypassing it.

    Anything else — including an effective principal that is a superuser or
    holds BYPASSRLS — fails closed.
    """
    current = session.execute(text("SELECT current_user")).scalar()
    if current != RESTRICTED_ROLE:
        try:
            session.execute(text("SET LOCAL ROLE " + RESTRICTED_ROLE))
        except SQLAlchemyError:
            raise ContextRefused("RESTRICTED_PRINCIPAL_REQUIRED") from None
        current = session.execute(text("SELECT current_user")).scalar()
    if current != RESTRICTED_ROLE:
        raise ContextRefused("RESTRICTED_PRINCIPAL_REQUIRED")
    privileged = session.execute(text(
        "SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user")).scalar()
    if privileged is not False:
        raise ContextRefused("RESTRICTED_PRINCIPAL_REQUIRED")
    # Share the M2 session's protected binding rather than silently falling
    # back to an editable actor UUID when protected mode is selected.
    from sitewise.db.m2_session import bind_m2_actor
    bind_m2_actor(session, actor_id)


def confirmation_horizon(confirmation: dict, validity: timedelta | None) -> str:
    """Deterministic end of the confirmation's validity window.

    ``validity`` is an explicit input. There is NO default: an unset or
    non-positive basis is a configuration refusal, not an assumed 90-day
    policy. (The only 90-day figure elsewhere in the project is raw-response
    retention, ``B3-04``, which concerns a different object.)
    """
    if not isinstance(validity, timedelta) or validity <= timedelta(0):
        raise ContextRefused("VALIDITY_BASIS_UNAUTHORIZED")
    created = confirmation["created_at"]
    if not isinstance(created, datetime) or created.tzinfo is None:
        raise ContextBindingUnavailable("BCB_CONFIRMATION_TIMESTAMP_UNVERIFIED")
    return (created + validity).astimezone(timezone.utc).isoformat()


def confirmed_description(instrument: dict, items: list[dict], answers: dict,
                         snapshot: dict) -> str:
    """The entrepreneur's own confirmed description. Never inferred, never modelled."""
    if instrument["version_tag"] == M2V1_INSTRUMENT_VERSION:
        text = current_business_description(items, answers)["text"]
    else:
        text = next((row["value"] for row in snapshot.get("answer_revisions", ())
                     if row.get("item_key") == DECLARED_DESCRIPTION_ITEM
                     and row.get("answer_state") == "ANSWERED"), None)
    if not isinstance(text, str) or not text.strip():
        # A concept without a confirmed description has no authoritative source.
        raise ContextBindingUnavailable("CONCEPT_DESCRIPTION_UNAVAILABLE")
    return text.strip()


class M2OwnershipAuthorization:
    """Minimum production AuthorizationPort: ownership, role, permitted purpose.

    Deliberately not a policy engine: it answers one question — may this active
    entrepreneur/admin build a context for this assessment from this confirmed
    revision — and returns a scoped decision. It reads identity and confirmation
    metadata only, never answer content.
    """
    POLICY_VERSION = "M2-OWNER-AUTHZ/1"
    ROLES = frozenset({"entrepreneur", "admin"})

    def __init__(self, repository, clock=None, validity: timedelta | None = None):
        self.repository = repository
        self.clock = clock or UTCClock()
        self.validity = validity

    def authorize(self, request: ContextRequest) -> dict:
        if request.role not in self.ROLES or request.purpose not in PURPOSES:
            return {"allowed": False, "reason": "ROLE_OR_PURPOSE_NOT_PERMITTED"}
        assessment = self.repository.get_assessment(request.assessment_id, request.viewer_id)
        if assessment is None or assessment["owner_user_id"] != request.viewer_id:
            return {"allowed": False, "reason": "OWNERSHIP_NOT_VERIFIED"}
        confirmation = self.repository.get_confirmation(request.confirmation_id, request.viewer_id)
        if confirmation is None or confirmation["assessment_revision"] != request.confirmed_revision:
            return {"allowed": False, "reason": "CONFIRMATION_NOT_CURRENT"}
        scope = {"viewer_id": str(request.viewer_id), "tenant_id": request.tenant_id,
                 "assessment_id": str(request.assessment_id), "purpose": request.purpose,
                 "role": request.role, "confirmation_id": str(request.confirmation_id),
                 "confirmed_revision": request.confirmed_revision,
                 "concept_version": request.concept_version}
        return {"allowed": True, "scope": scope, "owner_id": str(request.viewer_id),
                "decision_id": "m2-owner-access:" + source_hash(
                    {**scope, "policy_version": self.POLICY_VERSION})[:32],
                "policy_version": self.POLICY_VERSION,
                "valid_until": confirmation_horizon(confirmation, self.validity)}


class M2ContextBindings:
    """Resolve governed context inputs from confirmed M2 records only."""

    def __init__(self, session, purpose: str = "EXPLANATION",
                 validity: timedelta | None = None):
        require(purpose in PURPOSES, "INVALID_REQUEST")
        self.session = session
        self.validity = validity
        self.repository = SqlModelM2Repository(session)
        self.authorization = M2OwnershipAuthorization(
            self.repository, validity=validity)
        self.purpose = purpose

    def resolve(self, selection, actor) -> GovernedContextInputs:
        # No silent window: an unset basis is a configuration refusal before any
        # source row is read.
        if self.validity is None:
            raise ContextRefused("VALIDITY_BASIS_UNAUTHORIZED")
        # Owner policies are keyed on project1.actor_id; without this the read
        # is owner_user_id = NULL and every source row disappears.
        bind_restricted_principal(self.session, actor.user_id)
        repo = self.repository
        assessment = repo.get_assessment(selection.assessment_id, actor.user_id)
        if assessment is None:
            # Owner-scoped read: another owner's assessment is indistinguishable
            # from a missing one, so nothing about its existence leaks.
            raise ContextRefused("ACCESS_DENIED")
        confirmation = repo.get_confirmation(selection.confirmation_id, actor.user_id)
        if confirmation is None:
            raise ContextRefused("M2_CONFIRMATION_MISSING")
        if (confirmation["assessment_id"] != assessment["id"]
                or confirmation["assessment_revision"] != selection.revision):
            raise ContextRefused("M2_CONFIRMATION_STALE")
        instrument = repo.get_instrument(assessment["instrument_id"])
        if instrument is None or instrument["approval_state"] != "AUTHORIZED":
            raise ContextRefused("INSTRUMENT_UNAUTHORIZED")
        items = repo.list_items(assessment["instrument_id"])
        answers = repo.get_latest_answers(selection.assessment_id, selection.revision)
        findings = repo.get_findings(selection.assessment_id, selection.revision)
        owner = assessment["owner_user_id"]
        tenant_id = TENANT_PREFIX + str(owner)
        digest = confirmation["snapshot_digest"]
        concept_version = f"M2-CONFIRMED-{selection.revision}-{digest[:16]}"
        content = {"description": confirmed_description(
            instrument, items, answers, confirmation["snapshot_json"])}
        request = ContextRequest(
            viewer_id=actor.user_id, tenant_id=tenant_id, role=actor.role,
            assessment_id=selection.assessment_id, purpose=self.purpose,
            confirmation_id=selection.confirmation_id,
            confirmed_revision=selection.revision, concept_version=concept_version)
        decision = json_value(self.authorization.authorize(request))
        if not isinstance(decision, dict) or decision.get("allowed") is not True:
            raise ContextRefused("ACCESS_DENIED")
        concept = {
            "tenant_id": tenant_id, "assessment_id": str(selection.assessment_id),
            "version": concept_version, "confirmation_id": str(confirmation["id"]),
            "assessment_revision": selection.revision,
            "status": "ENTREPRENEUR_CONFIRMED", "confirmed_by": str(owner),
            "confirmation_event_id": str(confirmation["id"]), "content": content,
            "valid_until": confirmation_horizon(confirmation, self.validity),
            "m2_snapshot_digest": digest, "source_hash": source_hash(content)}
        bindings = {
            "scope": {"tenant_id": tenant_id, "assessment_id": str(selection.assessment_id)},
            "snapshot_id": f"m2-confirmation:{confirmation['id']}:{digest}",
            "consistency": "IMMUTABLE_SNAPSHOT", "concept": concept,
            "current_concept_version": concept_version,
            # GEO features are outside V1 scope; no catalogue is bound.
            "geography": None,
            "rule_versions": {row["rule_id"]: row["rule_version"] for row in findings},
            # No persisted finding-review authority exists for BDJ findings, so a
            # VERIFIED finding still fails closed in the builder.
            "finding_authorities": {},
            "uncertainty": self._uncertainty(confirmation["id"], owner, selection.objective_id,
                                              selection.assessment_id, selection.revision),
            "sources": []}
        return GovernedContextInputs(request, decision, bindings)

    def _uncertainty(self, confirmation_id, owner_id, objective_id=None, assessment_id=None, revision=None):
        """First confirmed uncertainty of this confirmation, deterministically."""
        if objective_id is not None:
            from hashlib import sha256
            objective = self.repository.read_current_objective(objective_id, owner_id, revision)
            source = objective['provenance'] if objective else {}
            if (not objective or source.get('assessment_id') != str(assessment_id)
                    or source.get('confirmation_id') != str(confirmation_id)
                    or source.get('origin') != 'ENTREPRENEUR'
                    or source.get('objective_contract') != 'entrepreneur-objective/1'
                    or source.get('objective_version') != str(objective_id)
                    or source.get('owner_user_id') != str(owner_id)
                    or source.get('owner_decision') != 'CONFIRMED'
                    or source.get('approval_status') != 'CONFIRMED_BY_OWNER'
                    or source.get('objective_text_sha256') != sha256(objective['exact_text'].encode('utf-8')).hexdigest()):
                raise ContextRefused('BCB_OBJECTIVE_SOURCE_UNVERIFIED')
            return {'id': str(objective_id), 'confirmation_id': str(confirmation_id),
                    'actor_user_id': str(owner_id), 'exact_text': objective['exact_text']}
        row = self.session.execute(
            select(uncertainties).where(and_(
                uncertainties.c.confirmation_id == confirmation_id,
                uncertainties.c.actor_user_id == owner_id,
            )).order_by(uncertainties.c.created_at, uncertainties.c.id).limit(1)
        ).mappings().first()
        if row is None:
            return None
        return {"id": str(row["id"]), "confirmation_id": str(row["confirmation_id"]),
                "actor_user_id": str(row["actor_user_id"]), "exact_text": row["exact_text"]}
