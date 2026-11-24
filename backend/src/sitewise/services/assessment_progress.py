"""Evidence-based five-stage assessment progress.

One model, one number. The marketplace record (``completed_stages`` /
``progress_percent``), the history list and the versioned readiness contract all
read this module, so the dashboard card, the workspace stepper and the
``/workflow-readiness`` endpoint cannot disagree about how far an assessment has
actually got.

Why this replaced the previous derivation
-----------------------------------------
Progress used to be counted from five legacy timestamp columns on the
``assessment`` row. Three of them (``evidence_reviewed_at``,
``explanation_reviewed_at``, ``report_generated_at``) were only ever written by
``PATCH /assessments/{id} {"complete_stage": ...}``, and those writes were
refused whenever a capability probe said the model artifact or report was
unavailable. The result was a bar that could not pass 40% no matter what the
entrepreneur did, while the readiness contract reported its own separate
verdict. Neither number described the work.

A stage is now COMPLETE only when its own authoritative evidence exists:

===========================  ==========================================
stage                        authoritative evidence
===========================  ==========================================
1 ``select_property``        ``assessment.property_selected_at``
2 ``business_requirements``  a *current*, owner-bound M2 confirmation
3 ``location_evidence``      the Stage 3 contract's own verdict, T3-01..T3-06
4 ``ai_explanation``         an approved current question per verified objective
5 ``assessment_report``      an adopted questionnaire-preview contract
===========================  ==========================================

A button click, a saved draft or a legacy timestamp is not evidence and never
counts. Where a stage's contract is missing or a governance hold applies, the
stage reports BLOCKED with the specific reason instead of pretending to be
complete -- and because only COMPLETE stages are counted, the percentage cannot
run ahead of what actually happened.

Stage keys keep their historical names (``location_evidence`` etc.) because they
are the wire contract the workspace routes on; the labels shown to the
entrepreneur are the redesigned journey names and live in the frontend.
"""
from __future__ import annotations

from typing import Any, Iterable

CONTRACT_VERSION = "sitewise-assessment-progress/1"

# (key, title) in workflow order. Titles are the server fallback; the workspace
# renders its own labels for the same keys.
STAGES: tuple[tuple[str, str], ...] = (
    ("select_property", "Select property"),
    ("business_requirements", "Business requirements"),
    ("location_evidence", "Location evidence"),
    ("ai_explanation", "AI recommendation explanation"),
    ("assessment_report", "Assessment report"),
)
STAGE_KEYS: tuple[str, ...] = tuple(key for key, _ in STAGES)
TOTAL_STAGES = len(STAGES)

# Stage states. COMPLETE is the only state that counts toward progress.
COMPLETE = "COMPLETE"
IN_PROGRESS = "IN_PROGRESS"
BLOCKED = "BLOCKED"
NOT_AVAILABLE = "NOT_AVAILABLE"

# Reasons. Named so a reader can tell "waiting for you" from "waiting for the
# system", and so a test can assert the exact blocker instead of a substring.
REASON_STAGE_1_INCOMPLETE = "STAGE_1_INCOMPLETE"
REASON_M2_NOT_LINKED = "M2_NOT_LINKED"
REASON_CURRENT_CONFIRMATION_REQUIRED = "CURRENT_CONFIRMATION_REQUIRED"
REASON_M2_STORAGE_UNAVAILABLE = "M2_STORAGE_UNAVAILABLE"
REASON_NO_RESEARCH_OBJECTIVE = "NO_RESEARCH_OBJECTIVE"
REASON_OBJECTIVE_AUTHORITY_UNVERIFIED = "OBJECTIVE_AUTHORITY_UNVERIFIED"
#: The confirmation's instrument has no adopted adapter that can record a
#: research objective from it, so the stage cannot be completed by any action
#: the entrepreneur takes. This is a contract gap, not a missing step.
REASON_OBJECTIVE_CONTRACT_UNAVAILABLE = "OBJECTIVE_CONTRACT_UNAVAILABLE_FOR_INSTRUMENT"
#: An objective exists, but the Stage 3 contract's predicates are not all
#: satisfied. An objective's *existence* is not completion: the approved
#: contract is ``sitewise-stage3-completion/1`` (T3-01..T3-06) and only its own
#: verdict may mark the stage COMPLETE. This reason exists because an earlier
#: version of this module counted ``verified > 0`` as completion and moved the
#: bar from 40% to 60% on a single objective -- a progress-calculation defect.
REASON_STAGE_3_CONTRACT_UNSATISFIED = "STAGE_3_CONTRACT_PREDICATES_UNSATISFIED"
REASON_QUESTION_GENERATION_REQUIRED = "QUESTION_GENERATION_AUTHORIZATION_REQUIRED"
REASON_CANDIDATE_REVIEW_PENDING = "CANDIDATE_REVIEW_PENDING"
REASON_CANDIDATE_REJECTED = "CANDIDATE_REJECTED"
REASON_PREVIEW_CONTRACT_UNADOPTED = "QUESTIONNAIRE_PREVIEW_CONTRACT_UNADOPTED"

# The rule we would need the owner to approve before stage 5 can ever complete.
# Reported, never applied: applying it silently is exactly the fabrication the
# questionnaire-preview endpoint exists to prevent.
STAGE_5_PROPOSED_RULE = (
    "Stage 5 would be COMPLETE when an adopted questionnaire-preview contract "
    "returns status=READY for the current confirmation, with every item "
    "accepted=True and fielding_authorized=false. Today the preview contract is "
    "unadopted, so the endpoint caps at DRAFT_AVAILABLE and stage 5 stays "
    "BLOCKED."
)

#: Stage 3's completion rule, recovered from the existing contracts rather than
#: re-invented, and adopted by the owner on 2026-11-24. It is enforced by
#: ``stage3_completion.decide``; this string is the human-readable rendering of
#: the same predicate set, reported so the payload states its own rule.
#:
#: Recovered from:
#:   * ``sitewise/services/stage3_completion.py`` -- T3-01..T3-05, unchanged;
#:   * ``deliverables/phase5/PROJECT1_STAGE34_FINAL_TRANSITION_CONTRACT.md`` --
#:     the written contract, including the zero-proposal ruling;
#:   * ``deliverables/m2v2/phase3a_research_objective_decision_brief.md`` §6 item 3
#:     -- the ``M2V2-09 -> O1..O6`` mapping, now used by T3-06.
#:
#: The M2V2 instrument registers the six fixed objectives itself: M2V2-09 offers
#: exactly six substantive topic codes that map one-to-one onto O1..O6, plus an
#: exclusive ``NONE``. So "registration of the six fixed objectives" is expressed
#: in the instrument and needs no new data model.
STAGE_3_RULE = (
    "Stage 3 completes when sitewise-stage3-completion/2 holds: T3-01 ownership; "
    "T3-02 a current confirmation; T3-03 a PERSISTED business context bound to the "
    "confirmation digest; T3-04 an authorized BDJ disposition -- VALIDATED_OUTPUT "
    "or VALID_ABSTENTION, fixture modes excluded, authorization consumed; T3-05 "
    "every BDJ proposal decided and every approved one admitted; T3-06 no "
    "unresolved blocker AND all six fixed objectives O1..O6 registered from the "
    "M2V2-09 topic answer, with every SELECTED topic carrying a verified research "
    "objective. Registration is a disposition, never coverage: it does not raise "
    "objective_registry.coverage(), which stays 0 of 6 until an approved "
    "measurement exists. ADOPTED and APPLIED 2026-11-24."
)


def empty_evidence(property_selected_at: Any = None,
                   requirements_saved_at: Any = None) -> dict:
    """Evidence for a record whose M2 store has not been read yet."""
    return {
        "property_selected_at": property_selected_at,
        # The legacy requirements form is still a supported way to record the
        # business declaration. Its timestamp is written only after the payload
        # validated, so it is persisted evidence -- but it is never allowed to
        # stand in for a confirmation in stage 3.
        "requirements_saved_at": requirements_saved_at,
        "linked": False,
        "store_readable": True,
        "instrument_version": None,
        "m2_assessment_id": None,
        "declaration": None,
        "declaration_reason": REASON_M2_NOT_LINKED,
        "objectives": {"total": 0, "verified": 0, "completed_at": None},
        # The Stage 3 contract's own verdict, when a caller has evaluated it
        # (``stage3_completion.decide``). Absent means "not evaluated", which is
        # BLOCKED -- never COMPLETE. Objective rows cannot substitute for it.
        "stage3": {},
        "candidates": {"current": 0, "approved": 0, "rejected": 0, "pending": 0},
        "preview": {"status": "UNAVAILABLE",
                    "reason": REASON_CURRENT_CONFIRMATION_REQUIRED},
    }


def preview_status(evidence: dict) -> dict:
    """Mirror of ``GET /m2/assessments/{id}/questionnaire-preview``.

    The endpoint is the authority; this reproduces its decision table from the
    same rows so progress does not need a second HTTP round trip. Kept in step by
    ``test_preview_status_matches_the_endpoint_contract``.
    """
    if evidence["declaration"] is None:
        reason = (REASON_CURRENT_CONFIRMATION_REQUIRED
                  if evidence["declaration_reason"] == REASON_M2_NOT_LINKED
                  else evidence["declaration_reason"])
        return {"status": "UNAVAILABLE", "reason": reason}
    objectives = evidence["objectives"]
    if objectives["verified"] == 0:
        return {"status": "UNAVAILABLE", "reason": REASON_NO_RESEARCH_OBJECTIVE}
    if evidence["candidates"]["current"] == 0:
        return {"status": "UNAVAILABLE", "reason": "NO_VALIDATED_QUESTION"}
    # A question exists, but the adopted preview contract does not.
    return {"status": "DRAFT_AVAILABLE",
            "reason": "QUESTIONNAIRE_SOURCE_PROJECTION_UNVERIFIED"}


#: The instrument whose research intention the objective path has always
#: accepted. Kept for reference; the authoritative list is the service's own map.
M2V1_INSTRUMENT = "M2V1-20261114-1"


def _objective_contract_missing(evidence: dict) -> bool:
    """True when the confirmed instrument has no adopted research intention.

    Read from ``confirmation_service.RESEARCH_INTENTION_ITEMS`` so this model and
    the write path cannot disagree about which instruments can record an
    objective. An instrument absent from that map has no path at all -- a
    contract gap rather than a step the owner skipped.
    """
    version = evidence.get("instrument_version")
    if not version:
        return False
    from sitewise.services.confirmation_service import RESEARCH_INTENTION_ITEMS
    return version not in RESEARCH_INTENTION_ITEMS


def evaluate(evidence: dict) -> dict:
    """Return the five stage verdicts and the progress they imply.

    Pure: no I/O, no clock, no session. ``evidence`` comes from
    :func:`load_evidence` in production and from a fixture in tests, which is
    what makes every transition testable without a database.
    """
    stages: list[dict[str, Any]] = []

    def add(key: str, number: int, state: str, reason: str | None = None,
            completed_at: Any = None) -> None:
        title = STAGES[number - 1][1]
        stages.append({
            "key": key,
            "number": number,
            "title": title,
            "state": state,
            "complete": state == COMPLETE,
            "reason": reason,
            "completed_at": completed_at,
        })

    # -- stage 1: the property is on the record -----------------------------
    if evidence["property_selected_at"] is not None:
        add("select_property", 1, COMPLETE, completed_at=evidence["property_selected_at"])
    else:
        add("select_property", 1, IN_PROGRESS, "PROPERTY_NOT_SELECTED")

    stage_1_done = stages[0]["complete"]

    # -- stage 2: a current, owner-bound M2 confirmation --------------------
    if not stage_1_done:
        add("business_requirements", 2, BLOCKED, REASON_STAGE_1_INCOMPLETE)
    elif evidence["declaration"] is not None:
        add("business_requirements", 2, COMPLETE,
            completed_at=evidence["declaration"].get("confirmed_at"))
    elif evidence.get("requirements_saved_at") is not None:
        # Legacy form: the declaration is saved and validated, just not through
        # the M2 instrument. It completes stage 2 and stops there -- stages 3-5
        # still require the M2 confirmation their evidence is bound to.
        add("business_requirements", 2, COMPLETE,
            completed_at=evidence["requirements_saved_at"])
    elif not evidence["store_readable"]:
        # An unreadable M2 store must not read as "you have not confirmed yet".
        add("business_requirements", 2, BLOCKED, REASON_M2_STORAGE_UNAVAILABLE)
    elif evidence["declaration_reason"] == REASON_M2_NOT_LINKED:
        add("business_requirements", 2, IN_PROGRESS, REASON_M2_NOT_LINKED)
    else:
        # A confirmation exists but is no longer current, or its provenance did
        # not validate. "Re-confirm" is the entrepreneur's own next action, so it
        # is progress waiting on them; a failed provenance check is not.
        reason = evidence["declaration_reason"] or REASON_CURRENT_CONFIRMATION_REQUIRED
        add("business_requirements", 2,
            IN_PROGRESS if reason == REASON_CURRENT_CONFIRMATION_REQUIRED else BLOCKED,
            reason)

    stage_2_done = stages[1]["complete"]

    # -- stage 3: the Stage 3 completion contract's own verdict -------------
    #
    # Stage 3 is NOT "an objective exists". The approved contract is
    # ``sitewise-stage3-completion/1`` (T3-01..T3-06), evaluated by
    # ``stage3_completion.decide``. This model reads that verdict; it never
    # derives one from a row count. Counting a verified objective as completion
    # is the defect that moved the bar 40% -> 60% on a single objective, so the
    # only path to COMPLETE here is ``stage3.complete is True``.
    objectives = evidence["objectives"]
    stage_3_contract = evidence.get("stage3") or {}
    if not stage_2_done:
        # Stage 2's own reason carries the detail (unlinked, stale, unreadable);
        # repeating it here would read as two separate blockers.
        add("location_evidence", 3, BLOCKED, "STAGE_2_INCOMPLETE")
    elif stage_3_contract.get("complete") is True:
        add("location_evidence", 3, COMPLETE,
            completed_at=stage_3_contract.get("completed_at"))
    elif _objective_contract_missing(evidence):
        # An M2V2 declaration has no adopted objective adapter: the entrepreneur
        # path is pinned to M2V1 and the BDJ path refuses a declaration-only
        # snapshot. Reported as BLOCKED so nobody reads it as "just do it".
        add("location_evidence", 3, BLOCKED, REASON_OBJECTIVE_CONTRACT_UNAVAILABLE)
    elif objectives["total"] > 0 and objectives["verified"] == 0:
        # Objectives were saved but their provenance does not verify against
        # the current confirmation. Not progress, and not the owner's fault.
        add("location_evidence", 3, BLOCKED, REASON_OBJECTIVE_AUTHORITY_UNVERIFIED)
    elif stage_3_contract:
        # Evaluated and not satisfied: report the contract's own blocker.
        add("location_evidence", 3, BLOCKED,
            stage_3_contract.get("reason") or REASON_STAGE_3_CONTRACT_UNSATISFIED)
    elif objectives["verified"] > 0:
        # An objective exists and verifies, but the Stage 3 contract has not been
        # evaluated for this record. Its existence is not completion, so this is
        # a hold rather than progress -- and it is a contract gap, not the
        # entrepreneur's next action.
        add("location_evidence", 3, BLOCKED, REASON_STAGE_3_CONTRACT_UNSATISFIED)
    else:
        # Nothing written yet on an instrument that can record an objective:
        # this one really is the entrepreneur's own next action.
        add("location_evidence", 3, IN_PROGRESS, REASON_NO_RESEARCH_OBJECTIVE)

    stage_3_done = stages[2]["complete"]

    # -- stage 4: an approved current question per verified objective ------
    candidates = evidence["candidates"]
    if not stage_3_done:
        add("ai_explanation", 4, BLOCKED, "STAGE_3_INCOMPLETE")
    elif candidates["approved"] > 0 and candidates["approved"] >= objectives["verified"]:
        add("ai_explanation", 4, COMPLETE, completed_at=candidates.get("completed_at"))
    elif candidates["current"] > 0:
        add("ai_explanation", 4, IN_PROGRESS,
            REASON_CANDIDATE_REJECTED if candidates["approved"] == 0 and candidates["rejected"] > 0
            else REASON_CANDIDATE_REVIEW_PENDING)
    else:
        # Generating a candidate needs its own authorization; without it the
        # stage is blocked by governance, not by the entrepreneur.
        add("ai_explanation", 4, BLOCKED, REASON_QUESTION_GENERATION_REQUIRED)

    stage_4_done = stages[3]["complete"]

    # -- stage 5: the questionnaire-preview contract -----------------------
    preview = evidence["preview"]
    if not stage_4_done:
        add("assessment_report", 5, BLOCKED, "STAGE_4_INCOMPLETE")
    elif preview["status"] == "READY":
        add("assessment_report", 5, COMPLETE, completed_at=preview.get("completed_at"))
    elif preview["status"] == "DRAFT_AVAILABLE":
        add("assessment_report", 5, BLOCKED, REASON_PREVIEW_CONTRACT_UNADOPTED)
    else:
        add("assessment_report", 5, BLOCKED, preview["reason"])

    completed = sum(1 for stage in stages if stage["complete"])
    current_index = next((i for i, stage in enumerate(stages) if not stage["complete"]),
                         TOTAL_STAGES - 1)
    return {
        "contract_version": CONTRACT_VERSION,
        "completed_stages": completed,
        # Rendered next to the completed count so "2 of 5" is not mistaken for
        # "almost done": the remainder is named, not implied.
        "remaining_stages": TOTAL_STAGES - completed,
        "total_stages": TOTAL_STAGES,
        "progress_percent": round(completed / TOTAL_STAGES * 100),
        "current_stage": current_index + 1,
        "current_stage_key": STAGE_KEYS[current_index],
        "stages": stages,
    }


# -- evidence loading -------------------------------------------------------
#
# The provenance predicate is the SQL twin of
# ``SqlModelM2Repository.research_workspace``. Both contracts are accepted and
# each verifies against its own authority fields: an entrepreneur objective is
# confirmed from the M2 declarations, an admitted objective from an owner
# admission. Neither may verify using the other's evidence.
#: SQL predicate: an objective row is *verified* against the current confirmation.
#: Public so ``stage3_completion`` can apply the identical test when it checks
#: that every selected M2V2-09 topic carries a verified objective. Two copies of
#: this predicate would eventually disagree about what "verified" means.
VERIFIED_OBJECTIVE_SQL = """
            (
              s.provenance->>'snapshot_digest' = cur.snapshot_digest
              AND s.provenance->>'confirmation_id' = cur.confirmation_id::text
              AND s.provenance->>'assessment_id' = cur.m2_id::text
              AND s.provenance->>'assessment_revision' = cur.assessment_revision::text
              AND s.provenance->>'objective_version' = u.id::text
              AND s.provenance->>'owner_user_id' = cur.owner_user_id::text
              AND s.provenance->>'owner_decision' = 'CONFIRMED'
              AND s.provenance->>'approval_status' = 'CONFIRMED_BY_OWNER'
              AND s.provenance->>'objective_text_sha256'
                  = encode(sha256(convert_to(u.exact_text, 'UTF8')), 'hex')
              AND (
                    (s.provenance->>'objective_contract' = 'entrepreneur-objective/1'
                     AND s.provenance->>'origin' = 'ENTREPRENEUR')
                 OR (s.provenance->>'objective_contract' = 'bdj-admitted-objective/1'
                     AND s.provenance->>'origin' = 'BDJ_ADMISSION'
                     AND nullif(s.provenance->>'admission_id', '') IS NOT NULL
                     AND nullif(s.provenance->>'objective_id', '') IS NOT NULL
                     AND s.provenance->>'finding_id' IS NULL)
              )
              AND NOT EXISTS (SELECT 1 FROM public.m2_research_revisions r
                              WHERE r.parent_id = u.id)
            )
"""
_VERIFIED = VERIFIED_OBJECTIVE_SQL

_LINKS_SQL = """
    SELECT l.marketplace_assessment_id AS mid,
           a.id AS m2_id,
           a.revision,
           a.confirmed_revision,
           i.version_tag AS instrument_version,
           c.id AS confirmation_id,
           c.assessment_revision,
           c.snapshot_digest,
           c.created_at AS confirmed_at
    FROM public.m2_assessment_links l
    JOIN public.m2_assessments a ON a.id = l.m2_assessment_id
    LEFT JOIN public.m2_instrument_versions i ON i.id = a.instrument_id
    LEFT JOIN public.m2_confirmation_snapshots c
           ON c.assessment_id = a.id
          AND c.assessment_revision = a.revision
          AND a.confirmed_revision = a.revision
          AND c.actor_user_id = a.owner_user_id
    WHERE l.marketplace_assessment_id = ANY(CAST(:ids AS uuid[]))
      AND l.revoked_at IS NULL
      AND a.owner_user_id = l.user_id
"""

_OBJECTIVES_SQL = f"""
    WITH cur AS (
        SELECT l.marketplace_assessment_id AS mid,
               a.id AS m2_id,
               a.owner_user_id,
               a.revision,
               c.id AS confirmation_id,
               c.assessment_revision,
               c.snapshot_digest
        FROM public.m2_assessment_links l
        JOIN public.m2_assessments a ON a.id = l.m2_assessment_id
        JOIN public.m2_confirmation_snapshots c
          ON c.assessment_id = a.id
         AND c.assessment_revision = a.revision
         AND a.confirmed_revision = a.revision
         AND c.actor_user_id = a.owner_user_id
        WHERE l.marketplace_assessment_id = ANY(CAST(:ids AS uuid[]))
          AND l.revoked_at IS NULL
          AND a.owner_user_id = l.user_id
    )
    SELECT cur.mid,
           u.id AS objective_id,
           u.created_at AS objective_created_at,
           COALESCE({_VERIFIED}, false) AS verified,
           q.id AS version_id,
           rv.decision AS review_decision,
           rv.recorded_at AS review_recorded_at
    FROM cur
    LEFT JOIN public.m2_confirmed_uncertainties u
           ON u.confirmation_id = cur.confirmation_id
          AND u.actor_user_id = cur.owner_user_id
    LEFT JOIN public.m2_research_objective_sources s ON s.objective_id = u.id
    LEFT JOIN public.m2_review_question_versions q
           ON q.objective_id = u.id
          AND NOT EXISTS (SELECT 1 FROM public.m2_review_question_versions n
                          WHERE n.supersedes = q.id)
    LEFT JOIN public.m2_candidate_owner_reviews rv ON rv.candidate_id = q.id
"""


def load_evidence(session, actor_id, marketplace_ids: Iterable, *,
                  property_selected_at: dict | None = None,
                  requirements_saved_at: dict | None = None) -> dict:
    """Read progress evidence for a page of assessments in two queries.

    ``property_selected_at`` / ``requirements_saved_at`` map marketplace
    assessment id (str) to its timestamp. Every failure degrades to "no
    evidence" -- an unreadable M2 store must not invent progress and must not
    break the assessment list -- but the degradation is recorded as
    ``store_readable=False`` so the stage reports BLOCKED rather than "not
    started".
    """
    ids = [str(i) for i in marketplace_ids if i is not None]
    stamps = property_selected_at or {}
    requirements = requirements_saved_at or {}

    def blank(mid):
        return empty_evidence(stamps.get(mid), requirements.get(mid))

    result = {mid: blank(mid) for mid in ids}
    if not ids:
        return result

    try:
        links = session.execute(_sql(_LINKS_SQL), {"ids": ids}).mappings().all()
    except Exception:  # noqa: BLE001 - M2 storage is optional for this read
        for evidence in result.values():
            evidence["store_readable"] = False
            evidence["declaration_reason"] = REASON_M2_STORAGE_UNAVAILABLE
        return result

    linked = []
    for row in links:
        mid = str(row["mid"])
        evidence = result.setdefault(mid, blank(mid))
        evidence["linked"] = True
        evidence["instrument_version"] = row["instrument_version"]
        evidence["m2_assessment_id"] = str(row["m2_id"])
        if row["confirmation_id"] is None:
            evidence["declaration_reason"] = REASON_CURRENT_CONFIRMATION_REQUIRED
            continue
        evidence["declaration"] = {
            "confirmation_id": str(row["confirmation_id"]),
            "assessment_revision": row["assessment_revision"],
            "snapshot_digest": row["snapshot_digest"],
            "confirmed_at": row["confirmed_at"],
        }
        evidence["declaration_reason"] = None
        linked.append(mid)

    if linked:
        try:
            rows = session.execute(_sql(_OBJECTIVES_SQL), {"ids": linked}).mappings().all()
        except Exception:  # noqa: BLE001
            for mid in linked:
                result[mid]["store_readable"] = False
                result[mid]["declaration"] = None
                result[mid]["declaration_reason"] = REASON_M2_STORAGE_UNAVAILABLE
            rows = []
        _absorb(result, rows)

    _attach_stage3(result, session, actor_id, linked)

    for evidence in result.values():
        evidence["preview"] = preview_status(evidence)
    return result


def _attach_stage3(result: dict, session, actor_id, linked: list) -> None:
    """Attach the Stage 3 contract's own verdict to each confirmed assessment.

    Purpose: stage 3 must complete on the contract's verdict, never on the
    presence of an objective row.
    Reason: an earlier version counted ``objectives["verified"] > 0`` and moved
    the bar 40% -> 60% on a single objective, which the owner rejected.
    Constraint: only assessments with a current confirmation are evaluated (the
    rest cannot reach stage 3 anyway), and any failure degrades to "not
    evaluated" -- which reports BLOCKED rather than inventing progress.
    """
    from sitewise.services import stage3_completion

    for mid in linked:
        evidence = result.get(mid)
        if evidence is None or evidence.get("declaration") is None:
            continue
        m2_id = evidence.get("m2_assessment_id")
        if not m2_id:
            continue
        # ``stage3_completion`` is written against a DBAPI cursor (it uses
        # pyformat placeholders and ``cur.description``), while this module
        # holds a SQLAlchemy Session. The raw cursor is taken from the *same*
        # connection, so the RLS actor binding and the transaction are shared --
        # and a savepoint keeps a failure from aborting the page read.
        savepoint = session.begin_nested()
        try:
            raw = session.connection().connection.cursor()
            verdict = stage3_completion.evaluate(
                raw,
                marketplace_assessment_id=mid,
                m2_assessment_id=m2_id,
                actor_id=actor_id,
                # Ownership is already established by the link join in
                # ``_LINKS_SQL`` (assessment owner = link user = M2 owner), so the
                # app-side record is supplied from that fact rather than re-read.
                assessment={"assessment_id": mid, "user_id": actor_id},
                link=None,
                ledger_cur=None,
                expected={},
            )
            savepoint.commit()
        except Exception:  # noqa: BLE001 - an unevaluated contract is a hold
            savepoint.rollback()
            evidence["stage3"] = {"complete": False,
                                  "reason": REASON_STAGE_3_CONTRACT_UNSATISFIED}
            continue
        evidence["stage3"] = {
            "complete": bool(verdict.get("complete")),
            "reason": _stage3_reason(verdict),
            "blockers": verdict.get("blockers") or [],
            "registration": verdict.get("registration") or {},
        }


def _stage3_reason(verdict: dict) -> str:
    """Name the first thing standing between this record and stage completion."""
    blockers = verdict.get("blockers") or []
    if blockers:
        return str(blockers[0].get("reason") or REASON_STAGE_3_CONTRACT_UNSATISFIED)
    registration = verdict.get("registration") or {}
    if registration and not registration.get("ok"):
        return str(registration.get("reason") or REASON_STAGE_3_CONTRACT_UNSATISFIED)
    return "NO_UNRESOLVED_BLOCKERS"


def _absorb(result: dict, rows) -> None:
    """Fold the flat objective/candidate rows into per-assessment evidence."""
    seen: dict[str, set] = {}
    for row in rows:
        mid = str(row["mid"])
        evidence = result.get(mid)
        if evidence is None:
            continue
        objectives = evidence["objectives"]
        candidates = evidence["candidates"]
        objective_id = row["objective_id"]
        if objective_id is not None:
            key = str(objective_id)
            bucket = seen.setdefault(mid, set())
            if key not in bucket:
                bucket.add(key)
                objectives["total"] += 1
                if row["verified"]:
                    objectives["verified"] += 1
                    stamp = row["objective_created_at"]
                    if stamp is not None and (objectives["completed_at"] is None
                                              or stamp < objectives["completed_at"]):
                        objectives["completed_at"] = stamp
        if row["version_id"] is not None:
            candidates["current"] += 1
            decision = row["review_decision"]
            if decision == "APPROVE_FOR_REVIEW":
                candidates["approved"] += 1
                stamp = row["review_recorded_at"]
                if stamp is not None and (candidates.get("completed_at") is None
                                          or stamp > candidates["completed_at"]):
                    candidates["completed_at"] = stamp
            elif decision == "REJECT":
                candidates["rejected"] += 1
            else:
                candidates["pending"] += 1


def _sql(statement: str):
    from sqlalchemy import text
    return text(statement)
