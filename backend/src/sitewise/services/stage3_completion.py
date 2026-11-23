"""Stage 3 completion contract - reference evaluator (READ ONLY).

This module computes whether the current research stage (legacy key
``location_evidence``) is complete, from version-bound authoritative records.

Design constraints imposed by the directive
-------------------------------------------
* **No writes.** Every statement is a ``SELECT``. Nothing here advances a
  stage, stamps a timestamp or creates a completion event.
* **No legacy timestamp.** ``assessment.evidence_reviewed_at`` is never read as
  evidence of completion: it belongs to the retired location-evidence
  workflow and has no writer in the research flow.
* **Derived, not persisted.** The result is a point-in-time evaluation, so it
  cannot disagree with the records it summarises (see A4 in the decision
  record).
* **Zero proposals are not evidence.** An empty proposal table is only
  acceptable when an authorized evaluation explicitly established that zero
  proposals were the valid outcome. T3-05 is vacuously true *only* when
  T3-04 is satisfied.

The module is split into ``collect`` (all SQL) and ``decide`` (pure). That
split exists so the zero-proposal cases can be tested against labelled
fixtures without writing anything into any database.

The contract version is independent of ``sitewise-assessment-workflow/2`` so
that adding this evaluator cannot silently change the readiness payload that
the stepper already consumes.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

CONTRACT_VERSION = "sitewise-stage3-completion/1"

#: Ordered predicates. The order is the evaluation order and the order in
#: which blockers are reported.
PREDICATES = ("T3-01", "T3-02", "T3-03", "T3-04", "T3-05", "T3-06")

PREDICATE_TITLES = {
    "T3-01": "Assessment ownership",
    "T3-02": "M2 confirmation",
    "T3-03": "Business context",
    "T3-04": "BDJ execution disposition",
    "T3-05": "Objective resolution",
    "T3-06": "No unresolved blockers",
}

#: A BDJ result counts as an evaluation only if the engine itself said so.
#: ``VALID_ABSTENTION`` is a valid answer (it names the missing confirmed
#: facts), so it is accepted; anything else is a hold or a failure.
ACCEPTED_OUTCOMES = ("VALIDATED_OUTPUT", "VALID_ABSTENTION")

#: A simulated result is a fixture, never an authorized evaluation.
FIXTURE_EXECUTION_MODES = ("SIMULATED",)


def _pred(code: str, satisfied: bool, reason: str, **evidence: Any) -> dict:
    return {
        "predicate": code,
        "title": PREDICATE_TITLES[code],
        "satisfied": bool(satisfied),
        "reason": reason,
        "evidence": evidence,
    }


def _rows(cur, sql: str, params: tuple = ()) -> list[dict]:
    cur.execute(sql, params)
    heads = [d[0] for d in cur.description]
    return [dict(zip(heads, row)) for row in cur.fetchall()]


# ---------------------------------------------------------------------------
# collect - all SQL lives here, and every statement is a SELECT
# ---------------------------------------------------------------------------

def collect(cur, *, marketplace_assessment_id: UUID, m2_assessment_id: UUID,
            actor_id: UUID, assessment: dict | None = None,
            link: dict | None = None, ledger_cur=None,
            expected: dict | None = None) -> dict:
    """Gather every record the decision needs. Read-only.

    Three privileges are involved and no single role holds all of them:

    * ``public.assessment`` / ``public.m2_assessment_links`` - the application
      role. The M2 runtime role deliberately has no ``SELECT`` here, so the
      caller passes ``assessment`` and ``link`` in.
    * ``public.m2_*`` - the M2 runtime role, which is ``cur``.
    * ``project1_ai.*`` - the attempt-ledger role. ``p1_m2_runtime`` has no
      usage on that schema, so a second cursor is supplied as ``ledger_cur``.

    A production implementation therefore cannot be a single-role read. That is
    recorded as a design constraint in the contract, not worked around here.
    """
    records: dict = {
        "subject": {
            "marketplace_assessment_id": marketplace_assessment_id,
            "m2_assessment_id": m2_assessment_id,
            "actor_id": actor_id,
        },
        "assessment": assessment,
        "m2": None,
        "link": link,
        "confirmation": None,
        "context": None,
        "evaluations": [],
        "authorizations": [],
        "proposals": [],
        "decisions": {},
        "admissions": {},
        # The currently adopted ruleset/prompt, and the current projection
        # fingerprint. The fingerprint cannot be computed from these tables: it
        # is digest(project1-m2-projection/1-candidate), which only the
        # projection builder can produce. Left absent, T3-04 fails closed with
        # SOURCE_FINGERPRINT_UNAVAILABLE rather than guessing.
        "expected": dict(expected or {}),
    }

    if assessment is None:
        rows = _rows(
            cur,
            "select assessment_id, user_id, status from public.assessment "
            "where assessment_id = %s",
            (marketplace_assessment_id,),
        )
        records["assessment"] = rows[0] if rows else None

    m2 = _rows(
        cur,
        "select id, owner_user_id, revision, confirmed_revision from public.m2_assessments "
        "where id = %s",
        (m2_assessment_id,),
    )
    records["m2"] = m2[0] if m2 else None

    if link is None:
        rows = _rows(
            cur,
            "select marketplace_assessment_id, m2_assessment_id, user_id "
            "from public.m2_assessment_links "
            "where marketplace_assessment_id = %s and m2_assessment_id = %s",
            (marketplace_assessment_id, m2_assessment_id),
        )
        records["link"] = rows[0] if rows else None

    revision = records["m2"]["revision"] if records["m2"] else None

    if records["m2"]:
        confirmation = _rows(
            cur,
            "select id, assessment_revision, actor_user_id, snapshot_digest, created_at "
            "from public.m2_confirmation_snapshots "
            "where assessment_id = %s and actor_user_id = %s "
            "order by assessment_revision desc, created_at desc limit 1",
            (m2_assessment_id, actor_id),
        )
        records["confirmation"] = confirmation[0] if confirmation else None

    if records["confirmation"]:
        context = _rows(
            cur,
            "select context_id, confirmation_id, assessment_revision, snapshot_digest, "
            "packet_hash, lifecycle_status, owner_user_id "
            "from public.m2_business_contexts "
            "where assessment_id = %s and confirmation_id = %s "
            "order by created_at desc limit 1",
            (m2_assessment_id, records["confirmation"]["id"]),
        )
        records["context"] = context[0] if context else None

    if records["m2"]:
        ledger = ledger_cur if ledger_cur is not None else cur
        records["evaluations"] = _rows(
            ledger,
            "select result_id, run_id, attempt_no, assessment_revision, source_fingerprint, "
            "ruleset_version, prompt_version, execution_outcome, validation_status, "
            "finding_authority, finding_count, execution_mode, provider_dispatched, "
            "result_payload, created_at "
            "from project1_ai.bdj_results "
            "where assessment_id = %s and owner_user_id = %s and assessment_revision = %s "
            "order by created_at desc",
            (m2_assessment_id, actor_id, revision),
        )
        for row in records["evaluations"]:
            records["authorizations"] += _rows(
                ledger,
                "select id, consumed_at, consumed_run_id, receipt, expires_at "
                "from project1_ai.bdj_real_data_authorizations "
                "where consumed_run_id = %s",
                (row["run_id"],),
            )

    if records["context"]:
        records["proposals"] = _rows(
            cur,
            "select proposal_id, review_state, owner_user_id, context_packet_hash, "
            "confirmation_revision, execution_mode "
            "from public.m2_bdj_objective_proposals "
            "where assessment_id = %s and context_id = %s",
            (m2_assessment_id, records["context"]["context_id"]),
        )
        for p in records["proposals"]:
            records["decisions"][p["proposal_id"]] = _rows(
                cur,
                "select decision from public.m2_bdj_objective_decisions where proposal_id = %s",
                (p["proposal_id"],),
            )
            records["admissions"][p["proposal_id"]] = _rows(
                cur,
                "select decision from public.m2_bdj_objective_admissions where proposal_id = %s",
                (p["proposal_id"],),
            )

    return records


# ---------------------------------------------------------------------------
# decide - pure function over the collected records
# ---------------------------------------------------------------------------

def decide(records: dict) -> dict:
    """Apply the six predicates. No I/O, no clock, no randomness."""
    subject = records["subject"]
    result: dict = {
        "contract_version": CONTRACT_VERSION,
        "subject": {
            "marketplace_assessment_id": str(subject["marketplace_assessment_id"]),
            "m2_assessment_id": str(subject["m2_assessment_id"]),
            "actor_id": str(subject["actor_id"]),
        },
        "predicates": {},
        "blockers": [],
        "complete": False,
        "completion_source": "DERIVED",
    }
    preds = result["predicates"]

    assessment = records["assessment"]
    m2 = records["m2"]
    link = records["link"]
    actor = str(subject["actor_id"])

    # ---- T3-01 ownership ------------------------------------------------
    if not assessment or not m2:
        preds["T3-01"] = _pred("T3-01", False, "SUBJECT_NOT_FOUND",
                               assessment_found=bool(assessment), m2_found=bool(m2))
    else:
        owner_ok = (str(assessment["user_id"]) == actor
                    and str(m2["owner_user_id"]) == actor)
        linked = bool(link) and str(link["user_id"]) == actor
        preds["T3-01"] = _pred(
            "T3-01", owner_ok and linked,
            "OWNER_VERIFIED" if (owner_ok and linked) else "OWNERSHIP_MISMATCH",
            assessment_owner=str(assessment["user_id"]),
            m2_owner=str(m2["owner_user_id"]),
            link_present=bool(link), actor=actor,
        )

    revision = m2["revision"] if m2 else None
    confirmed_revision = m2["confirmed_revision"] if m2 else None

    # ---- T3-02 confirmation ---------------------------------------------
    confirmation = records["confirmation"]
    if not confirmation:
        preds["T3-02"] = _pred("T3-02", False, "NO_CURRENT_CONFIRMATION", revision=revision)
    else:
        current = (confirmation["assessment_revision"] == revision
                   and confirmed_revision == revision
                   and str(confirmation["actor_user_id"]) == actor)
        preds["T3-02"] = _pred(
            "T3-02", current,
            "CONFIRMATION_CURRENT" if current else "CONFIRMATION_STALE",
            confirmation_id=str(confirmation["id"]),
            confirmation_revision=confirmation["assessment_revision"],
            assessment_revision=revision, confirmed_revision=confirmed_revision,
            snapshot_digest=confirmation["snapshot_digest"],
        )

    snapshot_digest = confirmation["snapshot_digest"] if confirmation else None

    # ---- T3-03 business context -----------------------------------------
    context = records["context"]
    if not context:
        preds["T3-03"] = _pred("T3-03", False, "NO_CONTEXT_FOR_CONFIRMATION",
                               confirmation_id=(str(confirmation["id"])
                                                if confirmation else None))
    else:
        bound = (context["assessment_revision"] == revision
                 and context["snapshot_digest"] == snapshot_digest
                 and context["packet_hash"] is not None
                 and context["lifecycle_status"] == "PERSISTED"
                 and str(context["owner_user_id"]) == actor)
        preds["T3-03"] = _pred(
            "T3-03", bound,
            "CONTEXT_BOUND" if bound else "CONTEXT_NOT_CURRENT",
            context_id=str(context["context_id"]),
            context_revision=context["assessment_revision"],
            context_snapshot_digest=context["snapshot_digest"],
            confirmation_snapshot_digest=snapshot_digest,
            packet_hash=context["packet_hash"],
            lifecycle_status=context["lifecycle_status"],
        )

    context_id = str(context["context_id"]) if context else None

    # ---- T3-04 BDJ execution disposition --------------------------------
    evaluations = records["evaluations"]
    accepted = None
    for row in evaluations:
        if (row["validation_status"] == "VALID"
                and row["execution_outcome"] in ACCEPTED_OUTCOMES
                and row["execution_mode"] not in FIXTURE_EXECUTION_MODES):
            accepted = row
            break

    if not evaluations:
        preds["T3-04"] = _pred(
            "T3-04", False, "NO_EVALUATION",
            note="no bdj_results row for the current revision; a missing receipt or "
                 "a missing authorization produces exactly this state")
    elif accepted is None:
        best = evaluations[0]
        preds["T3-04"] = _pred(
            "T3-04", False, "EVALUATION_NOT_VALID",
            execution_outcome=best["execution_outcome"],
            validation_status=best["validation_status"],
            execution_mode=best["execution_mode"])
    else:
        payload = accepted.get("result_payload") or {}
        payload_context = payload.get("context_id") if isinstance(payload, dict) else None
        # Provenance is measured against the *projection* fingerprint, not the
        # confirmation snapshot digest. They are different hashes over
        # different objects: `bdj_results.source_fingerprint` is
        # digest(project1-m2-projection/1-candidate) while
        # `m2_confirmation_snapshots.snapshot_digest` digests the confirmation
        # snapshot. Comparing them would fail for every valid evaluation.
        expected = records.get("expected") or {}
        current_source = expected.get("source_fingerprint")
        fingerprint_ok = (current_source is not None
                          and accepted["source_fingerprint"] == current_source)
        context_ok = payload_context is None or str(payload_context) == context_id
        # A ruleset or prompt change supersedes the evaluation that used the
        # previous one: the disposition is no longer about the current rules.
        ruleset_ok = (expected.get("ruleset_version") is None
                      or accepted["ruleset_version"] == expected["ruleset_version"])
        prompt_ok = (expected.get("prompt_version") is None
                     or accepted["prompt_version"] == expected["prompt_version"])
        auth = [a for a in records["authorizations"]
                if str(a["consumed_run_id"]) == str(accepted["run_id"])
                and a["consumed_at"] is not None]
        authorized = bool(auth)
        ok = fingerprint_ok and context_ok and ruleset_ok and prompt_ok and authorized
        reason = ("EVALUATION_AUTHORIZED" if ok else
                  "SOURCE_FINGERPRINT_UNAVAILABLE" if current_source is None else
                  "EVALUATION_PROVENANCE_MISMATCH" if not fingerprint_ok else
                  "EVALUATION_CONTEXT_MISMATCH" if not context_ok else
                  "EVALUATION_RULESET_SUPERSEDED" if not (ruleset_ok and prompt_ok) else
                  "EVALUATION_NOT_AUTHORIZED")
        preds["T3-04"] = _pred(
            "T3-04", ok, reason,
            result_id=str(accepted["result_id"]), run_id=str(accepted["run_id"]),
            execution_outcome=accepted["execution_outcome"],
            validation_status=accepted["validation_status"],
            finding_count=accepted["finding_count"],
            source_fingerprint=accepted["source_fingerprint"],
            current_source_fingerprint=current_source,
            confirmation_snapshot_digest=snapshot_digest,
            context_id=context_id,
            ruleset_version=accepted["ruleset_version"],
            prompt_version=accepted["prompt_version"],
            expected_ruleset_version=expected.get("ruleset_version"),
            expected_prompt_version=expected.get("prompt_version"),
            authorization_consumed=authorized,
            zero_findings=accepted["finding_count"] == 0,
        )

    # ---- T3-05 objective resolution -------------------------------------
    proposals = records["proposals"]
    undecided, approved_not_admitted, decided = [], [], 0
    for p in proposals:
        decision = records["decisions"].get(p["proposal_id"]) or []
        if not decision:
            undecided.append(str(p["proposal_id"]))
            continue
        decided += 1
        if decision[0]["decision"] == "APPROVED":
            admission = records["admissions"].get(p["proposal_id"]) or []
            if not admission:
                approved_not_admitted.append(str(p["proposal_id"]))

    if not proposals:
        satisfied = preds["T3-04"]["satisfied"]
        preds["T3-05"] = _pred(
            "T3-05", satisfied,
            "ZERO_PROPOSALS_VALID_OUTCOME" if satisfied else "ZERO_PROPOSALS_WITHOUT_EVALUATION",
            proposal_count=0,
            note=("an authorized evaluation established zero proposals" if satisfied else
                  "zero rows are not evidence of evaluation; T3-04 must hold first"))
    else:
        ok = not undecided and not approved_not_admitted
        preds["T3-05"] = _pred(
            "T3-05", ok,
            "ALL_OBJECTIVES_RESOLVED" if ok else
            "UNDECIDED_PROPOSAL" if undecided else "APPROVED_NOT_ADMITTED",
            proposal_count=len(proposals), decided=decided,
            undecided=undecided, approved_without_admission=approved_not_admitted)

    # ---- T3-06 no unresolved blockers -----------------------------------
    blockers = [code for code in ("T3-01", "T3-02", "T3-03", "T3-04", "T3-05")
                if not preds[code]["satisfied"]]
    result["blockers"] = [{"predicate": c, "reason": preds[c]["reason"]} for c in blockers]
    preds["T3-06"] = _pred("T3-06", not blockers,
                           "NO_UNRESOLVED_BLOCKERS" if not blockers else "BLOCKERS_PRESENT",
                           blocking=blockers)

    result["complete"] = all(p["satisfied"] for p in preds.values())
    return result


def evaluate(cur, *, marketplace_assessment_id: UUID, m2_assessment_id: UUID,
             actor_id: UUID, assessment: dict | None = None,
             link: dict | None = None, ledger_cur=None,
             expected: dict | None = None) -> dict:
    """Collect then decide. Read-only end to end."""
    return decide(collect(cur, marketplace_assessment_id=marketplace_assessment_id,
                          m2_assessment_id=m2_assessment_id, actor_id=actor_id,
                          assessment=assessment, link=link, ledger_cur=ledger_cur,
                          expected=expected))
