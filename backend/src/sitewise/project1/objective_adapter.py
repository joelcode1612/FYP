"""Persistence adapter for BDJ objective proposals (candidate only).

Design constraints this module enforces:

* A proposal is never an objective. It is written with ``review_state =
  'CANDIDATE'`` and nothing here can create an approved objective.
* Identity is deterministic and retry-safe. ``proposal_id`` is a UUIDv5 over
  the evaluation, context, contract, prompt, status, normalised objective and
  source digest — so a duplicate request lands on the same row. There is no
  rule-level unique key: two answers may legitimately share a rule.
* Every statement runs behind ``assert_target``, which reads the same policy
  module as the HTTP guard (``proposal_target_policy``). Pointing this adapter
  at a database outside the allowlist raises before any SQL executes.
* Historical findings are never touched. There is no UPDATE or DELETE against
  ``m2_bdj_findings`` in this module.
"""
from __future__ import annotations

import json
import uuid
from pathlib import Path

from sqlalchemy import text

from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.objective_proposal import (
    BOUND_CONTRACT_VERSION, PROBLEM_TYPE_FOR_STATUS, BoundObjectiveProposal,
)
from sitewise.project1.proposal_target_policy import refusal

MIGRATION_FILE = (Path(__file__).resolve().parents[3] /
                  "migrations/sql/20261121_0100_m2_bdj_objective_proposals.sql")
DECISIONS_MIGRATION_FILE = (Path(__file__).resolve().parents[3] /
                            "migrations/sql/20261121_0200_m2_bdj_objective_decisions.sql")


def _bind_actor(conn, actor_id) -> None:
    """Bind the authenticated owner to this transaction as the restricted M2
    principal, so the ``owner_scope`` RLS policies on the proposal/decision
    tables actually apply.

    ``bind_restricted_principal`` fails closed for a superuser / BYPASSRLS
    connection and refuses a login that cannot assume ``p1_m2_runtime``. The
    adapter's explicit ``owner_user_id`` predicates remain the authoritative
    check; RLS is the second layer.
    """
    from sitewise.repositories.m2_context_bindings import bind_restricted_principal
    from sitewise.services.business_context_v1 import ContextRefused
    try:
        bind_restricted_principal(conn, actor_id)
    except ContextRefused as exc:
        raise WorkflowHeld(exc.code) from None

SUGGESTED_LIMITATION = ("No confirmed M2 finding establishes this need; the objective is "
                        "exploratory and not source-backed.")


def assert_target(conn) -> str:
    """Refuse any database that is not an explicitly disposable target.

    Reads ``proposal_target_policy`` — the same module the HTTP guard uses — so
    the adapter and the route cannot disagree about where proposal rows live.
    The pair is checked as ``(database, port)``: a name that is allowlisted on
    the disposable cluster is not allowlisted on another port, because a second
    cluster can hold a different database of the same name.

    The *principal* is deliberately not checked here. ``_bind_actor`` runs
    immediately after this and fails closed unless the transaction ends up as
    ``p1_m2_runtime`` with neither ``rolsuper`` nor ``rolbypassrls``; checking
    ``current_user`` at this point would instead see the login, which is a
    superuser only inside the disposable harness.
    """
    current, server_port = conn.execute(text(
        "select current_database(), inet_server_port()")).one()
    if refusal(current, server_port) is not None:
        raise WorkflowHeld("PROPOSAL_DB_TARGET_REFUSED")
    return current


def migrate(engine) -> None:
    """Apply the versioned DDL. Idempotent; safe to re-run."""
    sql = MIGRATION_FILE.read_text(encoding="utf-8")
    with engine.begin() as conn:
        assert_target(conn)
        conn.execute(text(sql))


def migrate_decisions(engine) -> None:
    """Apply the decision DDL. Idempotent; safe to re-run."""
    sql = DECISIONS_MIGRATION_FILE.read_text(encoding="utf-8")
    with engine.begin() as conn:
        assert_target(conn)
        conn.execute(text(sql))


def _normalise(text_value: str) -> str:
    return " ".join(text_value.casefold().split())


def proposal_identity(*, assessment_id, confirmation_revision, confirmation_id,
                      context_packet_hash, contract_version, prompt_version,
                      recommendation) -> uuid.UUID:
    refs = sorted(
        "%s@%s@%s" % (r.item_key, r.answer_revision_id, r.item_version_id)
        for r in recommendation.source_refs)
    material = "|".join([
        str(assessment_id), str(confirmation_revision), str(confirmation_id),
        str(context_packet_hash), str(contract_version), str(prompt_version),
        recommendation.recommendation_status,
        _normalise(recommendation.research_objective),
        ",".join(refs) or "NO_SOURCE",
    ])
    return uuid.uuid5(uuid.NAMESPACE_URL, "bdj-objective-proposal|" + material)


def _check_recommendation(rec) -> None:
    if rec.problem_type != PROBLEM_TYPE_FOR_STATUS[rec.recommendation_status]:
        raise WorkflowHeld("PROPOSAL_PROBLEM_TYPE_MISMATCH")
    if rec.recommendation_status == "MOST_SUGGESTED":
        if not rec.source_refs:
            raise WorkflowHeld("PROPOSAL_SOURCE_REQUIRED")
        if not (rec.problem or "").strip():
            raise WorkflowHeld("PROPOSAL_PROBLEM_REQUIRED")
    else:
        if rec.source_refs:
            raise WorkflowHeld("PROPOSAL_SOURCE_NOT_ALLOWED")
        if rec.problem is not None:
            raise WorkflowHeld("PROPOSAL_PROBLEM_NOT_ALLOWED")


def persist(engine, bound: BoundObjectiveProposal, *, owner_user_id, evaluation_id,
            assessment_id, confirmation_revision, confirmation_id, source_fingerprint,
            prompt_version, execution_mode="SIMULATED", model_provider=None,
            model_requested=None, model_returned=None) -> list[dict]:
    """Insert every recommendation; return [{proposal_id, created}] per row.

    ``execution_mode`` must distinguish a real dispatch from a simulated or
    deterministic run — a fixture must never be stored as if a model produced it.
    """
    if not isinstance(bound, BoundObjectiveProposal) or bound.contract_version != BOUND_CONTRACT_VERSION:
        raise WorkflowHeld("PROPOSAL_NOT_BOUND_TO_CONTEXT")
    if execution_mode not in {"LIVE", "SIMULATED", "DETERMINISTIC"}:
        raise WorkflowHeld("PROPOSAL_EXECUTION_MODE_INVALID")
    if len(str(source_fingerprint)) != 64:
        raise WorkflowHeld("PROPOSAL_SOURCE_FINGERPRINT_INVALID")

    rows, out = [], []
    for rec in bound.proposals:
        _check_recommendation(rec)
        pid = proposal_identity(
            assessment_id=assessment_id, confirmation_revision=confirmation_revision,
            confirmation_id=confirmation_id, context_packet_hash=bound.context_packet_hash,
            contract_version=bound.contract_version, prompt_version=prompt_version,
            recommendation=rec)
        rows.append({
            "proposal_id": str(pid), "evaluation_id": str(evaluation_id),
            "assessment_id": str(assessment_id), "confirmation_id": str(confirmation_id),
            "confirmation_revision": int(confirmation_revision),
            "source_fingerprint": str(source_fingerprint),
            "context_id": bound.context_id,
            "context_packet_hash": bound.context_packet_hash,
            "recommendation_status": rec.recommendation_status,
            "problem_type": rec.problem_type, "problem": rec.problem,
            "research_objective": rec.research_objective, "reason": rec.reason,
            "evidence_limitation": (rec.reason if rec.recommendation_status == "SUGGESTED"
                                    else None),
            "source_refs": json.dumps([r.model_dump() for r in rec.source_refs]),
            "contract_version": bound.contract_version, "prompt_version": prompt_version,
            "execution_mode": execution_mode, "model_provider": model_provider,
            "model_requested": model_requested, "model_returned": model_returned,
            "validation_status": "VALID", "owner_user_id": str(owner_user_id),
        })
        out.append({"proposal_id": str(pid), "created": None})

    with engine.begin() as conn:
        assert_target(conn)
        _bind_actor(conn, owner_user_id)
        for row, result in zip(rows, out):
            inserted = conn.execute(text("""
                INSERT INTO public.m2_bdj_objective_proposals (
                    proposal_id, evaluation_id, assessment_id, confirmation_id,
                    confirmation_revision, source_fingerprint, context_id,
                    context_packet_hash, recommendation_status, problem_type, problem,
                    research_objective, reason, evidence_limitation, source_refs,
                    contract_version, prompt_version, execution_mode, model_provider,
                    model_requested, model_returned, validation_status, owner_user_id)
                VALUES (
                    :proposal_id, :evaluation_id, :assessment_id, :confirmation_id,
                    :confirmation_revision, :source_fingerprint, :context_id,
                    :context_packet_hash, :recommendation_status, :problem_type, :problem,
                    :research_objective, :reason, :evidence_limitation,
                    CAST(:source_refs AS jsonb), :contract_version, :prompt_version,
                    :execution_mode, :model_provider, :model_requested, :model_returned,
                    :validation_status, :owner_user_id)
                ON CONFLICT (proposal_id) DO NOTHING
            """), row).rowcount
            result["created"] = inserted == 1
    return out


def read(engine, proposal_id, owner_user_id) -> dict | None:
    """Owner-scoped read. A different owner gets None, not a redacted row."""
    with engine.begin() as conn:
        assert_target(conn)
        _bind_actor(conn, owner_user_id)
        row = conn.execute(text("""
            SELECT proposal_id, evaluation_id, assessment_id, confirmation_id,
                   confirmation_revision, source_fingerprint, context_id,
                   context_packet_hash, recommendation_status, problem_type, problem,
                   research_objective, reason, evidence_limitation, source_refs,
                   contract_version, prompt_version, execution_mode, validation_status,
                   model_provider, model_requested, model_returned,
                   review_state, owner_user_id, created_at
            FROM public.m2_bdj_objective_proposals
            WHERE proposal_id = :pid AND owner_user_id = :owner
        """), {"pid": str(proposal_id), "owner": str(owner_user_id)}).mappings().one_or_none()
        if row is None:
            return None
        out = dict(row)
        out["source_refs"] = json.loads(out["source_refs"]) if isinstance(
            out["source_refs"], str) else out["source_refs"]
        return out


def read_for_assessment(engine, assessment_id, owner_user_id,
                        confirmation_revision, limit=50) -> list[dict]:
    """Owner-scoped proposal history for one confirmed assessment revision."""
    if (isinstance(limit, bool) or not isinstance(limit, int) or
            not 1 <= limit <= 100):
        raise WorkflowHeld("PROPOSAL_READ_LIMIT_INVALID")
    with engine.begin() as conn:
        assert_target(conn)
        _bind_actor(conn, owner_user_id)
        rows = conn.execute(text("""
            SELECT proposal_id, evaluation_id, assessment_id, confirmation_id,
                   confirmation_revision, source_fingerprint, context_id,
                   context_packet_hash, recommendation_status, problem_type, problem,
                   research_objective, reason, evidence_limitation, source_refs,
                   contract_version, prompt_version, execution_mode, validation_status,
                   review_state, owner_user_id, created_at
            FROM public.m2_bdj_objective_proposals
            WHERE assessment_id = :assessment AND owner_user_id = :owner
              AND confirmation_revision = :revision
            ORDER BY created_at DESC, proposal_id
            LIMIT :limit
        """), {"assessment": str(assessment_id), "owner": str(owner_user_id),
               "revision": int(confirmation_revision), "limit": limit}).mappings().all()
        result = []
        for row in rows:
            out = dict(row)
            out["source_refs"] = json.loads(out["source_refs"]) if isinstance(
                out["source_refs"], str) else out["source_refs"]
            result.append(out)
        return result


def rollback_candidate(engine, proposal_id, owner_user_id) -> bool:
    """Guarded rollback: only an owned CANDIDATE row may be removed.

    Reviewed or withdrawn rows are never deleted here, so a rollback cannot
    erase an entrepreneur decision. Returns True when a row was removed.
    """
    with engine.begin() as conn:
        assert_target(conn)
        _bind_actor(conn, owner_user_id)
        removed = conn.execute(text("""
            DELETE FROM public.m2_bdj_objective_proposals
            WHERE proposal_id = :pid AND owner_user_id = :owner
              AND review_state = 'CANDIDATE'
        """), {"pid": str(proposal_id), "owner": str(owner_user_id)}).rowcount
        return removed == 1


def decide(engine, proposal_id, *, actor_id, decision, source_fingerprint,
           context_packet_hash, note=None) -> dict:
    """Record the entrepreneur's decision. Append-only; never deletes a proposal.

    One decision per proposal. A repeat of the same decision by the same actor is
    idempotent; a different decision raises ``PROPOSAL_ALREADY_DECIDED`` so an
    approval cannot be silently overwritten. Ownership, source fingerprint and
    context hash are checked inside the same row lock.
    """
    if decision not in {"APPROVED", "REJECTED"}:
        raise WorkflowHeld("PROPOSAL_DECISION_INVALID")
    state = decision
    with engine.begin() as conn:
        assert_target(conn)
        _bind_actor(conn, actor_id)
        proposal = conn.execute(text("""
            SELECT owner_user_id, source_fingerprint, context_packet_hash
            FROM public.m2_bdj_objective_proposals
            WHERE proposal_id = :pid FOR UPDATE
        """), {"pid": str(proposal_id)}).mappings().one_or_none()
        if proposal is None:
            raise WorkflowHeld("PROPOSAL_NOT_FOUND")
        if str(proposal["owner_user_id"]) != str(actor_id):
            raise WorkflowHeld("PROPOSAL_DECISION_FORBIDDEN")
        if (proposal["source_fingerprint"] != source_fingerprint or
                proposal["context_packet_hash"] != context_packet_hash):
            raise WorkflowHeld("PROPOSAL_DECISION_STALE")

        existing = conn.execute(text("""
            SELECT decision_id, decision, decided_by, decided_at
            FROM public.m2_bdj_objective_decisions WHERE proposal_id = :pid
        """), {"pid": str(proposal_id)}).mappings().one_or_none()
        if existing is not None:
            if (existing["decision"] == decision and
                    str(existing["decided_by"]) == str(actor_id)):
                return {"decision_id": str(existing["decision_id"]),
                        "decision": decision, "created": False,
                        "decided_at": existing["decided_at"]}
            raise WorkflowHeld("PROPOSAL_ALREADY_DECIDED")

        decision_id = uuid.uuid4()
        conn.execute(text("""
            INSERT INTO public.m2_bdj_objective_decisions (
                decision_id, proposal_id, decision, decided_by, source_fingerprint,
                confirmation_id, context_packet_hash, note)
            SELECT :did, :pid, :decision, :actor, :fp, confirmation_id,
                   :ctx, :note
            FROM public.m2_bdj_objective_proposals WHERE proposal_id = :pid
        """), {"did": str(decision_id), "pid": str(proposal_id), "decision": decision,
               "actor": str(actor_id), "fp": source_fingerprint, "ctx": context_packet_hash,
               "note": note})
        conn.execute(text("""
            UPDATE public.m2_bdj_objective_proposals SET review_state = :state
            WHERE proposal_id = :pid
        """), {"state": state, "pid": str(proposal_id)})
        return {"decision_id": str(decision_id), "decision": decision, "created": True}


def read_decision(engine, proposal_id, owner_user_id) -> dict | None:
    """Owner-scoped decision read. Another owner gets None."""
    with engine.begin() as conn:
        assert_target(conn)
        _bind_actor(conn, owner_user_id)
        row = conn.execute(text("""
            SELECT d.decision_id, d.decision, d.decided_by, d.decided_at,
                   d.source_fingerprint, d.context_packet_hash, d.note
            FROM public.m2_bdj_objective_decisions d
            JOIN public.m2_bdj_objective_proposals p USING (proposal_id)
            WHERE d.proposal_id = :pid AND p.owner_user_id = :owner
        """), {"pid": str(proposal_id), "owner": str(owner_user_id)}).mappings().one_or_none()
        return dict(row) if row else None


def admissible_for_qg(engine, proposal_id, *, source_fingerprint,
                      actor_id) -> tuple[bool, str]:
    """QG admission gate: only an APPROVED, source-current proposal may pass.

    Pending and rejected proposals are never admissible, and a proposal whose
    source fingerprint has moved is stale even if it was approved earlier.

    ``actor_id`` is required: the read runs under the owner-scoped RLS policy, so
    an unbound or foreign-owner call must not be able to probe another owner's
    proposal. A missing actor fails closed as ``PROPOSAL_OWNER_REQUIRED`` rather
    than looking like "not found".
    """
    if actor_id is None:
        raise WorkflowHeld("PROPOSAL_OWNER_REQUIRED")
    with engine.begin() as conn:
        assert_target(conn)
        _bind_actor(conn, actor_id)
        row = conn.execute(text("""
            SELECT p.source_fingerprint, p.review_state, d.decision
            FROM public.m2_bdj_objective_proposals p
            LEFT JOIN public.m2_bdj_objective_decisions d USING (proposal_id)
            WHERE p.proposal_id = :pid
        """), {"pid": str(proposal_id)}).mappings().one_or_none()
        if row is None:
            return False, "PROPOSAL_NOT_FOUND"
        if row["source_fingerprint"] != source_fingerprint:
            return False, "PROPOSAL_SOURCE_STALE"
        if row["decision"] != "APPROVED":
            return False, "PROPOSAL_NOT_APPROVED"
        return True, "ADMISSIBLE"


def admission_status(engine, proposal_id, *, source_fingerprint, actor_id) -> dict:
    """Entrepreneur approval vs downstream admission, kept deliberately separate.

    An APPROVED decision is the owner's own record and is preserved verbatim. It
    does **not** authorise QJ or QG. ``ADMITTED`` is reachable only through an
    explicit, source-bound owner admission row in
    ``public.m2_bdj_objective_admissions`` (see ``objective_admission.py``); with
    no such row the state stays ``HELD`` with
    ``M2_UNCERTAINTY_LINK_REQUIRED``, which is the honest description of "the
    owner approved the objective but has not yet decided the cited gap is worth
    researching".

    Delegation, not duplication: the admission record and its hash binding are
    read by exactly one module, so the route and the QG adapter cannot disagree
    about whether an objective is admitted.
    """
    from sitewise.project1 import objective_admission
    return objective_admission.admission_state(
        engine, proposal_id, source_fingerprint=source_fingerprint,
        actor_id=actor_id)

