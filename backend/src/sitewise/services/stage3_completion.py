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

/2 — the six-objective registration extension
---------------------------------------------
``/1`` completed on T3-01..T3-05 plus "no unresolved blockers". That left a
gap: nothing required the six fixed objectives (O1..O6) to be *registered*
against the instrument, so one entrepreneur-written objective could look like a
finished research design. ``/2`` extends T3-06 to require that all six are
accounted for.

Registration is read from the instrument, not asserted here. ``M2V2-09``'s own
registered option codes name exactly the six fixed objectives, and
``issue_resolution.TOPIC_TO_OBJECTIVE`` maps them one-to-one. A topic is either
SELECTED or NOT_SELECTED (a recorded, deliberate abstention). ``NONE`` is an
explicit decline of all six and is reported as mode ``DECLINED``.

The six objectives are system-defined: ``objective_registry`` declares them
mandatory for every assessment, so their *existence* never depends on an
entrepreneur record. T3-06 therefore separates four things that a single
boolean would conflate:

* **mandatory registration** — all six have a recorded disposition. Blocked
  only when the research-intention answer cannot be read.
* **business declaration completeness** — which topics were selected, and the
  declared priority and decision status.
* **measurement readiness** — which selected objectives a verified research
  objective already carries. Reported on T3-06's evidence and on
  ``registration.measurement_pending``; it does not gate this stage, because
  the QG eligibility gate (G-05) and publication enforce it downstream.
* **optional BDJ objective admission** — T3-05, unchanged. A BDJ proposal may
  link to a fixed objective; it never creates, retires or re-ranks one.

Missing business information therefore lowers readiness. It never removes an
objective from the registry.

Registration is a **disposition, not coverage**. It never raises
``objective_registry.coverage()``: that number stays 0 of 6 until an approved
measurement exists, and this module does not touch it.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

CONTRACT_VERSION = "sitewise-stage3-completion/2"

#: Ordered predicates. The order is the evaluation order and the order in
#: which blockers are reported.
PREDICATES = ("T3-01", "T3-02", "T3-03", "T3-04", "T3-05", "T3-06")

PREDICATE_TITLES = {
    "T3-01": "Assessment ownership",
    "T3-02": "M2 confirmation",
    "T3-03": "Business context",
    "T3-04": "BDJ execution disposition",
    "T3-05": "Objective resolution",
    # /2 extension: T3-06 was "no unresolved blockers". It now also requires the
    # six fixed objectives to be registered from the instrument. Recovered from
    # deliverables/m2v2/phase3a_research_objective_decision_brief.md §6 item 3
    # ("Confirm the M2V2-09 -> O1..O6 topic mapping"), approved 2026-11-24.
    "T3-06": "No unresolved blockers and six objectives registered",
}

#: The M2V2-09 item whose registered option codes name the six fixed objectives.
RESEARCH_TOPIC_ITEM = "M2V2-09"
PRIORITY_ITEM = "M2V2-10"
DISPOSITION_ITEM = "M2V2-11"

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

def _intention_answers(cur, m2_assessment_id, confirmed_revision) -> dict:
    """The research-intention answers in force at the confirmed revision.

    ``m2_answer_revisions`` stores *changes*, so the answer in force is the
    newest row at or before the confirmed revision -- not simply the newest row.
    Reading the newest row would let a post-confirmation edit rewrite what the
    confirmation registered.
    """
    rows = _rows(
        cur,
        "select distinct on (iv.item_key) iv.item_key, ar.answer_state, ar.value_json "
        "from public.m2_answer_revisions ar "
        "join public.m2_item_versions iv on iv.id = ar.item_version_id "
        "where ar.assessment_id = %s and iv.item_key in (%s, %s, %s) "
        "  and ar.assessment_revision <= %s "
        "order by iv.item_key, ar.assessment_revision desc, ar.created_at desc",
        (m2_assessment_id, RESEARCH_TOPIC_ITEM, PRIORITY_ITEM, DISPOSITION_ITEM,
         confirmed_revision),
    )
    return {row["item_key"]: {"answer_state": row["answer_state"],
                              "value": row["value_json"]} for row in rows}


def _verified_objectives(cur, m2_assessment_id, actor_id, confirmation) -> list[dict]:
    """Objectives bound to this confirmation, with their provenance verdict.

    The verification predicate is imported from ``assessment_progress`` rather
    than restated: two copies would eventually disagree about what "verified"
    means, and the progress bar would then count an objective that this
    contract rejects.
    """
    from sitewise.services.assessment_progress import VERIFIED_OBJECTIVE_SQL

    rows = _rows(
        cur,
        "with cur as (select %s::uuid as m2_id, %s::uuid as confirmation_id, "
        "                    %s::integer as assessment_revision, "
        "                    %s::text as snapshot_digest, %s::uuid as owner_user_id) "
        "select u.id, s.provenance->>'priority' as priority, "
        f"       coalesce({VERIFIED_OBJECTIVE_SQL}, false) as verified "
        "from cur "
        "join public.m2_confirmed_uncertainties u "
        "  on u.confirmation_id = cur.confirmation_id "
        "left join public.m2_research_objective_sources s on s.objective_id = u.id",
        (m2_assessment_id, confirmation["id"],
         confirmation["assessment_revision"], confirmation["snapshot_digest"],
         actor_id),
    )
    return [{"id": str(row["id"]), "priority": row["priority"],
             "verified": bool(row["verified"])} for row in rows]


def _registration(records: dict) -> dict:
    """Register the six fixed objectives from the M2V2-09 topic answer.

    Pure. A topic is SELECTED when its own option code appears in the answer;
    NOT_SELECTED otherwise, which is a recorded abstention rather than a gap.
    ``NONE`` is exclusive in the instrument and is reported as mode DECLINED:
    all six are registered out of scope, so nothing is required to resolve.

    O1..O6 are **system-defined**. ``objective_registry`` declares them mandatory
    for every assessment, so no entrepreneur action creates or retires one, and
    no ``m2_confirmed_uncertainties`` row is required for an objective to exist.
    Requiring one objective row per selected topic made the six-objective stage
    unreachable: the only writer of such a row (``confirm_objective``,
    origin=ENTREPRENEUR) stamps ``priority`` from the single ``M2V2-10`` answer,
    so at most one selected topic could ever resolve and the rest blocked
    forever. Registration is therefore reported from the declaration, and three
    things that were previously collapsed into one boolean stay separate:

    ``ok`` / ``blocking``
        Whether all six have a recorded disposition. False only when the
        research-intention answer itself cannot be read -- a real gap in the
        declaration, not a missing objective row.

    ``measurement_ready`` / ``measurement_pending``
        Which selected objectives a verified research objective already carries.
        A missing business fact lowers readiness; it never unregisters the
        objective. Measurement is enforced downstream by the QG eligibility gate
        (G-05 needs a resolved stimulus for a registry objective) and again at
        publication, so reporting readiness here without gating on it drops no
        safeguard. ``objective_registry.coverage()`` remains the only thing that
        raises the measured count, and this function never calls it.
    """
    from sitewise.project1.issue_resolution import TOPIC_TO_OBJECTIVE

    answers = records.get("research_intention") or {}
    answer = answers.get(RESEARCH_TOPIC_ITEM)
    if not answer or answer.get("answer_state") != "ANSWERED":
        return {
            "ok": False,
            "reason": "RESEARCH_TOPIC_ANSWER_UNAVAILABLE",
            "mode": None,
            "blocking": list(TOPIC_TO_OBJECTIVE.values()),
            "rows": [],
            # Nothing can be measured while the declaration is unreadable, so
            # every objective is reported as pending rather than as absent.
            "measurement_ready": [],
            "measurement_pending": list(TOPIC_TO_OBJECTIVE.values()),
        }

    value = answer.get("value") or []
    if isinstance(value, str):
        value = [value]
    codes = {str(code) for code in value}
    declined = "NONE" in codes

    # A verified objective resolves the topic named by its own ``priority``.
    resolved: dict[str, list[str]] = {}
    for objective in records.get("objectives") or []:
        if not objective.get("verified"):
            continue
        priority = objective.get("priority")
        if priority:
            resolved.setdefault(str(priority), []).append(objective["id"])

    rows, ready, pending = [], [], []
    for code, objective_id in TOPIC_TO_OBJECTIVE.items():
        selected = (code in codes) and not declined
        carried_by = resolved.get(code, [])
        measured = bool(carried_by)
        if selected:
            (ready if measured else pending).append(objective_id)
        rows.append({
            "topic_code": code,
            "objective_id": objective_id,
            "mandatory": True,
            "registered": True,
            "disposition": "SELECTED" if selected else "NOT_SELECTED",
            "verified_objectives": carried_by,
            "measurement_ready": measured,
        })

    return {
        "ok": True,
        "reason": "SIX_OBJECTIVES_REGISTERED",
        "mode": "DECLINED" if declined else "SELECTED",
        # Registration is never blocked by a missing objective row: the six
        # objectives exist by registry, not by record. Only an unreadable
        # research-intention answer blocks, and that returns above.
        "blocking": [],
        "rows": rows,
        "measurement_ready": ready,
        "measurement_pending": pending,
        "priority": answers.get(PRIORITY_ITEM, {}).get("value"),
        "disposition": answers.get(DISPOSITION_ITEM, {}).get("value"),
    }


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
        # /2: the research-intention answers and the verified objectives they
        # must resolve to. Both are read at the *confirmed* revision, because
        # registration is about the confirmation being completed, not about
        # whatever the draft has drifted to since.
        "research_intention": {},
        "objectives": [],
        "ledger_readable": True,
        # The currently adopted ruleset/prompt, and the current projection
        # fingerprint. The fingerprint cannot be computed from these tables: it
        # is ``digest(packet + confirmation receipt)``, exactly as
        # ``project1_workflow.source`` writes it into ``bdj_results`` and
        # ``m2_qg_candidates``. It is **not** the projection builder's own
        # ``digest(packet)`` -- measured on ``c3082df0`` revision 20 the builder
        # produced ``49cefb93…`` while the ledger recorded ``b404a3c8…``, so a
        # caller that supplied the builder's digest would fail every valid
        # evaluation with ``EVALUATION_PROVENANCE_MISMATCH``.
        #
        # Left absent, T3-04 fails closed with
        # SOURCE_FINGERPRINT_UNAVAILABLE rather than guessing. The application
        # supplies it (DD-122) through
        # ``assessment_progress._current_source_fingerprint``, which reproduces
        # this exact recipe and is checked against a recorded ledger value.
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
        # The attempt ledger lives in ``project1_ai``, which the M2 runtime role
        # has no USAGE on by default. A read that is refused is reported as
        # LEDGER_UNAVAILABLE rather than raised: T3-04 fails closed either way,
        # and a caller must be able to tell "no evaluation exists" from "I was
        # not allowed to look".
        try:
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
                    # DD-005 mechanism B: a spend is an append-only row in
                    # bdj_authorization_consumptions, so the legacy
                    # consumed_run_id column is NULL for every new spend. The
                    # LEFT JOIN reports both mechanisms under the same two
                    # field names, so existing readers keep their meaning:
                    # consumed_at is when the authorization was spent and
                    # consumed_run_id is the run that spent it. For a legacy
                    # row the coalesce falls back to the original columns. If
                    # the caller's principal cannot see the consumption table,
                    # the join yields NULL and legacy behaviour is unchanged
                    # rather than the read failing.
                    "select a.id, "
                    "       coalesce(c.consumed_at, a.consumed_at) as consumed_at, "
                    "       coalesce(c.run_id, a.consumed_run_id) as consumed_run_id, "
                    "       a.receipt, a.expires_at "
                    "from project1_ai.bdj_real_data_authorizations a "
                    "left join project1_ai.bdj_authorization_consumptions c "
                    "       on c.authorization_id = a.id "
                    "where coalesce(c.run_id, a.consumed_run_id) = %s",
                    (row["run_id"],),
                )
        except Exception:  # noqa: BLE001 - a refused ledger read is a blocker
            records["ledger_readable"] = False
            records["evaluations"] = []
            records["authorizations"] = []

    # ---- /2 registration evidence ---------------------------------------
    # Read at the confirmation's own revision. A confirmation that is stale is
    # already T3-02's finding; registration still reports what was confirmed.
    if records["confirmation"]:
        confirmed_revision = records["confirmation"]["assessment_revision"]
        records["research_intention"] = _intention_answers(
            cur, m2_assessment_id, confirmed_revision)
        records["objectives"] = _verified_objectives(
            cur, m2_assessment_id, actor_id, records["confirmation"])

    if records["context"]:
        # `m2_business_contexts.context_id` is `uuid`, so the driver hands back a
        # `UUID`; `m2_bdj_objective_proposals.context_id` is `varchar(64)`
        # (`20261121_0100_m2_bdj_objective_proposals.sql:16`). Binding the UUID
        # object raises `operator does not exist: character varying = uuid`, which
        # made `collect` — and therefore the whole completion verdict — fail for
        # every assessment that has a business context. Normalising to text here
        # matches the column that is actually compared, and changes no value: the
        # varchar holds the same uuid string.
        records["proposals"] = _rows(
            cur,
            "select proposal_id, review_state, owner_user_id, context_packet_hash, "
            "confirmation_revision, execution_mode "
            "from public.m2_bdj_objective_proposals "
            "where assessment_id = %s and context_id = %s",
            (m2_assessment_id, str(records["context"]["context_id"])),
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

    # ---- T3-06 no unresolved blockers; six objectives registered ---------
    #
    # /2 splits T3-06 into two independently reported lists. Keeping them apart
    # matters: a reader must be able to see "BDJ never ran" and "O3 was selected
    # but never resolved" at the same time, instead of the second only becoming
    # visible once the first is fixed.
    blockers = [code for code in ("T3-01", "T3-02", "T3-03", "T3-04", "T3-05")
                if not preds[code]["satisfied"]]
    registration = _registration(records)
    result["blockers"] = [{"predicate": c, "reason": preds[c]["reason"]} for c in blockers]
    result["registration"] = registration
    t3_06_ok = not blockers and registration["ok"]
    preds["T3-06"] = _pred(
        "T3-06", t3_06_ok,
        "BLOCKERS_PRESENT" if blockers else
        "OBJECTIVES_NOT_REGISTERED" if not registration["ok"] else
        "NO_UNRESOLVED_BLOCKERS",
        blocking=blockers,
        registration_blocking=registration["blocking"],
        registration_mode=registration["mode"],
        # Reported, never gating. A selected objective with no approved measure
        # lowers readiness; it does not unregister a system-defined objective.
        measurement_ready=registration.get("measurement_ready", []),
        measurement_pending=registration.get("measurement_pending", []),
    )

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
