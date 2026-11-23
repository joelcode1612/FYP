"""Objective proposer compositions for the BDJ pipeline.

Two compositions, one governed gate
-----------------------------------
This module hosts both ways the BDJ objective proposer can be executed. They
share the same disclosure gate, the same output contract and the same
persistence path; they differ only in what actually produces the proposals.

* ``SimulatedObjectiveProvider`` — **network-free**. No ``httpx`` import, no
  credential, no socket. Retained for offline verification and for the test
  suite, which must be able to exercise the governed machinery without egress.
* ``TokenHarbour`` (``sitewise.project1.provider``) — the **adopted cloud
  adapter**. The governed HTTP route composes this one, so a successful
  proposal is a real model call.

Owner decision (2026-11-23)
---------------------------
The route previously composed the simulator only, on the grounds that neither
the ``SyntheticBdjDisclosure`` packet authorisation nor the real-data
authorisation row was an authorisation to disclose this source to a cloud
model. The repository owner has since directed that the objective route use
TokenHarbour outright. That decision is recorded here rather than silently
encoded, and it is the *only* reason the disclosure below admits a cloud
model:

* ``execution_mode='LIVE'`` is persisted for a real dispatch, and
  ``'SIMULATED'`` for the offline composition — a fixture is never stored as if
  a model produced it (``objective_adapter.persist`` enforces the vocabulary,
  and ``public.m2_bdj_objective_proposals`` has a matching CHECK constraint);
* the disclosure still refuses every stage, model, endpoint, schema version,
  source fingerprint and context binding other than the one this execution was
  built for;
* the output still has to pass ``validate_objective_proposal`` and
  ``bind_to_business_context`` unchanged, so a model answer cannot bypass the
  candidate contract.

Nothing here grants approval, admission or QG authority. A persisted proposal
is still ``CANDIDATE_ONLY``.

The simulated proposal text is derived mechanically from the confirmed
declarations: a recommendation may only cite an answer whose confirmed value is
itself an uncertainty literal. Nothing is invented, and a source with no
uncertainty literal produces the bounded exploratory recommendation instead.
"""
from __future__ import annotations

from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.objective_proposal import (
    CONTRACT_VERSION, DEFAULT_SUPPORTING_LITERALS, MAX_RECOMMENDATIONS,
    PROBLEM_TYPE_FOR_STATUS, SUPPORTING_LITERALS,
)
from sitewise.project1.provider import ENDPOINT, MODEL

SIMULATOR_MODEL = "simulated-objective-v1"
SIMULATOR_ENDPOINT = "local://simulated-objective"
SIMULATOR_MODE = "json_schema"
#: The adopted cloud model, re-exported so a caller composing the TokenHarbour
#: path never has to duplicate (and can never drift from) the adapter's model.
TOKENHARBOUR_MODEL = MODEL
PROJECTION_SCHEMA = "project1-m2-projection/1-candidate"
#: M2 V2 source family. Accepted only when the caller asks for it explicitly,
#: so an M2 V1 execution can never be satisfied by a V2 packet (or vice versa).
PROJECTION_SCHEMA_M2V2 = "project1-m2v2-projection/1-candidate"


class ObjectiveSimulationDisclosure:
    """Fail-closed gate for a governed objective execution.

    Mirrors the ``ModelRunner`` disclosure port signature so the governed runner
    can be composed unchanged. It grants nothing on its own: it asserts that
    this execution is bound to this exact source revision and persisted context,
    and that the stage, model and endpoint are ones this composition was built
    for.

    The admitted model and endpoint are constructor parameters so one class can
    cover both compositions without either inheriting the other's authority:

    * default arguments -> the offline simulator, admitted for
      ``SIMULATOR_MODEL`` on either ``SIMULATOR_ENDPOINT`` or ``ENDPOINT``;
    * ``for_tokenharbour()`` -> the governed route, admitted for the adopted
      cloud model on the adopted cloud endpoint only.
    """

    def __init__(self, *, assessment_id, revision, confirmation_id,
                 source_fingerprint, context_packet_hash,
                 expected_schema_version=PROJECTION_SCHEMA,
                 accepted_models=(SIMULATOR_MODEL,),
                 accepted_endpoints=(SIMULATOR_ENDPOINT, ENDPOINT)):
        self.assessment_id = str(assessment_id)
        self.revision = int(revision)
        self.confirmation_id = str(confirmation_id)
        self.source_fingerprint = str(source_fingerprint)
        self.context_packet_hash = str(context_packet_hash)
        self.expected_schema_version = str(expected_schema_version)
        self.accepted_models = frozenset(accepted_models)
        self.accepted_endpoints = frozenset(accepted_endpoints)

    @classmethod
    def for_tokenharbour(cls, *, model=MODEL, **kwargs):
        """Composition for the governed route: the adopted cloud model only.

        The accepted set is exactly ``{model}`` -- a configured fallback or an
        operator override cannot inherit this authorisation by accident.
        """
        return cls(accepted_models=(model,),
                   accepted_endpoints=(ENDPOINT,), **kwargs)

    def require_current(self, stage, packet, endpoint, model):
        if stage != "BDJ":
            raise WorkflowHeld("DISCLOSURE_STAGE_NOT_AUTHORIZED")
        if model not in self.accepted_models:
            # A model this composition was not built for must never inherit its
            # authorisation. For the TokenHarbour composition this is what stops
            # a downgraded or substituted model from being accepted silently.
            raise WorkflowHeld("DISCLOSURE_MODEL_MISMATCH")
        if endpoint not in self.accepted_endpoints:
            raise WorkflowHeld("DISCLOSURE_ENDPOINT_MISMATCH")
        if (not isinstance(packet, dict) or
                packet.get("schema_version") != self.expected_schema_version):
            raise WorkflowHeld("DISCLOSURE_SOURCE_CLASS_INVALID")
        if packet.get("source_fingerprint") != self.source_fingerprint:
            raise WorkflowHeld("DISCLOSURE_SOURCE_MISMATCH")
        confirmation = packet.get("confirmation") or {}
        if (str(packet.get("assessment_id")) != self.assessment_id
                or packet.get("assessment_revision") != self.revision
                or str(confirmation.get("confirmation_id")) != self.confirmation_id):
            raise WorkflowHeld("DISCLOSURE_ASSESSMENT_BINDING_MISMATCH")


def _values(value):
    return value if isinstance(value, list) else [value]


def _supporting_literals(item_key):
    return SUPPORTING_LITERALS.get(item_key, DEFAULT_SUPPORTING_LITERALS)


def simulate_objective_proposal(packet: dict) -> dict:
    """Deterministic ``bdj-objective-proposal/1`` payload from confirmed answers.

    One MOST_SUGGESTED per confirmed uncertainty literal, capped by the
    contract. When no confirmed answer carries a literal, the result is the
    single bounded exploratory SUGGESTED — never a fabricated gap.
    """
    declarations = [d for d in packet.get("declarations", []) if isinstance(d, dict)]
    recommendations = []
    for row in sorted(declarations, key=lambda r: str(r.get("item_key"))):
        if row.get("answer_state") != "ANSWERED":
            continue
        allowed = _supporting_literals(str(row.get("item_key")))
        literal = next((v for v in _values(row.get("value"))
                        if isinstance(v, str) and v in allowed), None)
        if literal is None:
            continue
        item_key = str(row["item_key"])
        recommendations.append({
            "recommendation_status": "MOST_SUGGESTED",
            "problem_type": PROBLEM_TYPE_FOR_STATUS["MOST_SUGGESTED"],
            "problem": (f"The confirmed answer to {item_key} is {literal}, so this "
                        "element of the business concept remains undecided."),
            "research_objective": (f"To investigate what the confirmed {item_key} "
                                   "declaration leaves unresolved for the proposed concept."),
            "source_refs": [{
                "item_key": item_key,
                "answer_revision_id": str(row["answer_revision_id"]),
                "item_version_id": str(row["item_version_id"]),
            }],
            "reason": ("The cited declaration records an explicit uncertainty literal; "
                       "no further evidence is inferred from it."),
            "authority": "CANDIDATE_ONLY",
        })
        if len(recommendations) >= MAX_RECOMMENDATIONS:
            break

    if not recommendations:
        recommendations.append({
            "recommendation_status": "SUGGESTED",
            "problem_type": PROBLEM_TYPE_FOR_STATUS["SUGGESTED"],
            "problem": None,
            "research_objective": ("To explore the factors that influence customers' "
                                   "selection of the proposed cafe concept."),
            "source_refs": [],
            "reason": ("No confirmed M2 answer establishes an existing problem; this "
                       "objective is exploratory and not source-backed."),
            "authority": "CANDIDATE_ONLY",
        })

    return {"contract_version": CONTRACT_VERSION, "recommendations": recommendations}


class SimulatedObjectiveProvider:
    """In-process provider. ``complete`` performs no I/O and holds no secret."""

    model = SIMULATOR_MODEL
    mode = SIMULATOR_MODE

    def __init__(self, packet: dict):
        self.packet = packet
        self.last_identity = None
        self.last_execution = None

    def prepare_payload(self, messages, output_type):
        """Shape-compatible with TokenHarbor.prepare_payload; never dispatched."""
        return {"model": self.model, "messages": messages,
                "response_format": {"type": "json_schema",
                                    "json_schema": {"name": output_type.__name__,
                                                    "strict": True,
                                                    "schema": output_type.model_json_schema()}}}

    def complete(self, messages, output_type):
        output = simulate_objective_proposal(self.packet)
        # Validated locally so a contract drift fails here, not at persistence.
        output_type.model_validate(output)
        self.last_identity = {
            "requested_model": self.model, "returned_model": None,
            "classification": "SIMULATED_LOCAL", "identity_verified": False,
        }
        self.last_execution = {
            "model_requested": self.model, "model_returned": None,
            "identity_verified": False, "http_status": None, "usage": None,
            "schema_validation": "VALID", "dispatched": False,
            "dispatch_attempted": False, "execution_mode": "SIMULATED",
            "provider": "in_process_simulator",
        }
        return output
