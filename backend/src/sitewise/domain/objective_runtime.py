"""Deterministic O1-O6 objective-obligation evaluator (pure, synthetic-only).

Design constraints (PROJECT1 Adaptive Routing V1.5, owner direction P4):

* **Pure** - no I/O, no database, no clock, no network. It consumes only
  already-computed routing rows, effective answers, and a release-versioned
  objective registry.
* **No measurement authority** - an objective whose construct is not
  ``APPROVED`` can never resolve; it is reported as
  ``HOLD_RELEASE_OBJECTIVE_COVERAGE``. The registry records obligations; it
  does not grant science.
* **No invented evidence** - an objective is resolved only by an accepted
  effective answer bound to a slot that the approved manifest declares as
  measuring *that* construct. A missing/withheld question yields
  ``OUTSTANDING``, never a resolution.
* **No duplicate presentation** - one slot may serve several objectives only
  when the manifest declares it measures each of them; the evaluator never
  fabricates a second answer event.

This module is deliberately *not* wired into the production submit path in
V1.5. It is exercised only by synthetic approved-manifest fixtures. Real
activation requires the P4/P5 approvals recorded in
``artifacts/adaptive_routing_v15``.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Iterable, Mapping, Sequence

# --- status tokens (exact strings required by the V1.5 policy) --------------
OBJECTIVE_BRANCH_RESOLVED = "OBJECTIVE_BRANCH_RESOLVED"
RESOLVED_BY_AUTHORISED_NONRESPONSE = "RESOLVED_BY_AUTHORISED_NONRESPONSE"
SKIP_NOT_APPLICABLE = "SKIP_NOT_APPLICABLE"
OUTSTANDING = "OUTSTANDING"
HOLD_RELEASE_OBJECTIVE_COVERAGE = "HOLD_RELEASE_OBJECTIVE_COVERAGE"

APPROVED = "APPROVED"
RESOLVED_STATES = frozenset({OBJECTIVE_BRANCH_RESOLVED, RESOLVED_BY_AUTHORISED_NONRESPONSE})

# Effective-answer states that count as an accepted answer event.
ACCEPTED_ANSWER_STATES = frozenset(
    {"ANSWERED_SUBSTANTIVE", "ANSWERED_NON_SUBSTANTIVE", "REFUSED"}
)


@dataclass(frozen=True)
class ObjectiveObligation:
    """One release-versioned objective obligation.

    ``required_slots`` is ordered; the first slot carrying a qualifying
    effective answer resolves the objective. ``applicability`` is a small
    declarative predicate (``{"fact": ..., "equals": ...}``) evaluated against
    the caller-supplied facts; ``None`` means always applicable.
    """

    objective_id: str
    construct_id: str
    required_slots: tuple[str, ...]
    # Fail closed: an obligation that does not explicitly declare APPROVED is
    # NOT treated as approved. Synthetic fixtures must opt in explicitly.
    construct_status: str = "NOT_AUTHORIZED"
    mandatory: bool = True
    applicability: Mapping[str, Any] | None = None
    nonresponse_codes: frozenset[str] = frozenset()
    question_bank_version: str = ""
    registry_version: str = "objective-registry/1"

    def __post_init__(self) -> None:
        if not self.objective_id or not self.construct_id:
            raise ValueError("objective_id and construct_id are required")
        if not self.required_slots:
            raise ValueError("required_slots must not be empty")
        # Accept the contract's real status vocabulary (and any future token).
        # Anything that is not exactly APPROVED fails closed to HOLD; an unknown
        # token is therefore safe rather than rejected.
        if not isinstance(self.construct_status, str) or not self.construct_status:
            raise ValueError("construct_status must be a non-empty string")


@dataclass(frozen=True)
class ObjectiveResolution:
    objective_id: str
    construct_id: str
    status: str
    reason: str
    evidence_slot: str | None = None
    evidence_event_id: str | None = None
    context_digest: str | None = None


@dataclass(frozen=True)
class Evaluation:
    registry_version: str
    resolutions: tuple[ObjectiveResolution, ...]
    final_ready: bool
    outstanding: tuple[str, ...]
    held: tuple[str, ...]

    def resolution(self, objective_id: str) -> ObjectiveResolution:
        for item in self.resolutions:
            if item.objective_id == objective_id:
                return item
        raise KeyError(objective_id)

    @property
    def resolved_ids(self) -> tuple[str, ...]:
        return tuple(r.objective_id for r in self.resolutions if r.status in RESOLVED_STATES)


def _applicable(obligation: ObjectiveObligation, facts: Mapping[str, Any]) -> bool:
    rule = obligation.applicability
    if rule is None:
        return True
    if "fact" not in rule or "equals" not in rule:
        raise ValueError("applicability must be {'fact': ..., 'equals': ...}")
    return facts.get(rule["fact"]) == rule["equals"]


def _codes(value: Any) -> frozenset[str]:
    """Normalise an answer value into a set of option codes."""
    if value is None:
        return frozenset()
    if isinstance(value, (list, tuple, set, frozenset)):
        return frozenset(str(v) for v in value)
    return frozenset({str(value)})


def _qualifying_answer(
    obligation: ObjectiveObligation,
    effective: Mapping[str, Mapping[str, Any]],
    slot_constructs: Mapping[str, str],
    slot_contexts: Mapping[str, str] | None,
) -> tuple[str, Mapping[str, Any]] | None:
    """Return (slot, answer) for the first slot that truly measures this construct."""
    for slot in obligation.required_slots:
        answer = effective.get(slot)
        if not answer:
            continue
        # A shared slot may resolve an objective only if the approved manifest
        # declares that slot measures this exact construct.
        if slot_constructs.get(slot) != obligation.construct_id:
            continue
        # Bind the resolution to the context that produced the answer. When the
        # caller supplies current per-slot digests, a stale/superseded answer
        # (e.g. after a pre-final edit changed the dependency context) must not
        # keep the objective resolved.
        if slot_contexts is not None:
            if answer.get("context_digest") != slot_contexts.get(slot):
                continue
        state = answer.get("state")
        if state not in ACCEPTED_ANSWER_STATES:
            continue
        if answer.get("event_id") is None:
            continue
        if state == "ANSWERED_SUBSTANTIVE":
            # Substantive includes negative codes (DEF_NO): valid evidence.
            return slot, answer
        # Non-substantive / refused resolves only when the exact option code is
        # an authorised nonresponse for this construct (codes live in `value`,
        # not in the answer state).
        if _codes(answer.get("value")) & obligation.nonresponse_codes:
            return slot, answer
    return None


def evaluate(
    obligations: Sequence[ObjectiveObligation],
    *,
    effective_answers: Mapping[str, Mapping[str, Any]],
    slot_constructs: Mapping[str, str],
    facts: Mapping[str, Any] | None = None,
    registry_version: str = "objective-registry/1",
    common_core_ready: bool = True,
    slot_contexts: Mapping[str, str] | None = None,
) -> Evaluation:
    """Deterministically evaluate a release's objective obligations.

    ``effective_answers`` maps ``slot_id`` -> ``{"state", "value", "event_id"}``
    as produced by the existing CQ routing adapter. ``slot_constructs`` is the
    approved manifest's declaration of which construct each slot measures.
    ``common_core_ready`` is the existing ``can_submit`` result; final readiness
    requires it as well, so objectives never substitute for the common core.
    """
    facts = facts or {}
    resolutions: list[ObjectiveResolution] = []
    outstanding: list[str] = []
    mandatory_outstanding: list[str] = []
    held: list[str] = []

    for obligation in obligations:
        if obligation.construct_status != APPROVED:
            held.append(obligation.objective_id)
            resolutions.append(
                ObjectiveResolution(
                    objective_id=obligation.objective_id,
                    construct_id=obligation.construct_id,
                    status=HOLD_RELEASE_OBJECTIVE_COVERAGE,
                    reason=f"CONSTRUCT_{obligation.construct_status}",
                )
            )
            continue

        if not _applicable(obligation, facts):
            resolutions.append(
                ObjectiveResolution(
                    objective_id=obligation.objective_id,
                    construct_id=obligation.construct_id,
                    status=SKIP_NOT_APPLICABLE,
                    reason="APPLICABILITY_FALSE",
                )
            )
            continue

        match = _qualifying_answer(obligation, effective_answers, slot_constructs, slot_contexts)
        if match is None:
            outstanding.append(obligation.objective_id)
            if obligation.mandatory:
                mandatory_outstanding.append(obligation.objective_id)
            # Distinguish "wrong construct on the only available slot" from
            # "simply unanswered", so a shared-question misuse is observable.
            reason = "NO_ACCEPTED_ANSWER"
            for slot in obligation.required_slots:
                if effective_answers.get(slot) and slot_constructs.get(slot) != obligation.construct_id:
                    reason = "SLOT_MEASURES_DIFFERENT_CONSTRUCT"
                    break
            resolutions.append(
                ObjectiveResolution(
                    objective_id=obligation.objective_id,
                    construct_id=obligation.construct_id,
                    status=OUTSTANDING,
                    reason=reason,
                )
            )
            continue

        slot, answer = match
        resolved_by = (
            OBJECTIVE_BRANCH_RESOLVED
            if answer.get("state") == "ANSWERED_SUBSTANTIVE"
            else RESOLVED_BY_AUTHORISED_NONRESPONSE
        )
        resolutions.append(
            ObjectiveResolution(
                objective_id=obligation.objective_id,
                construct_id=obligation.construct_id,
                status=resolved_by,
                reason="ACCEPTED_EFFECTIVE_ANSWER",
                evidence_slot=slot,
                evidence_event_id=str(answer.get("event_id")),
                context_digest=answer.get("context_digest"),
            )
        )

    # A non-mandatory objective may remain outstanding without blocking final
    # readiness; a held construct and any mandatory outstanding objective do.
    final_ready = not held and not mandatory_outstanding and bool(common_core_ready)
    return Evaluation(
        registry_version=registry_version,
        resolutions=tuple(resolutions),
        final_ready=final_ready,
        outstanding=tuple(outstanding),
        held=tuple(held),
    )
