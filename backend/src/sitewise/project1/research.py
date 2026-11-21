"""Deterministic BCB reuse, separate QJ advice and approved-bank-first gated QG.

Authority/bank/disclosure ports must be trusted server adapters. There is no HTTP
payload accepting grants and no production implementation inventing missing owners.
"""
import re

from sitewise.project1.contracts import (
    Measurement, QGOutput, QJOutput, WorkflowHeld, digest, no_authority,
)


def checked_context(builder, request):
    packet = builder.get_context(request)
    if digest({k: v for k, v in packet.items() if k != 'packet_hash'}) != packet['packet_hash']:
        raise WorkflowHeld('BCB_PACKET_FINGERPRINT_INVALID')
    if packet['confirmation']['status'] != 'CURRENT_CONFIRMED':
        raise WorkflowHeld('BCB_CONFIRMATION_REQUIRED')
    if not packet.get('confirmed_uncertainty'):
        raise WorkflowHeld('UNCERTAINTY_NOT_CONFIRMED')
    # Existing BCB has separate immutable snapshots/purpose rights; never replace it
    # with a dictionary assembled from an arbitrary HTTP request.
    if any(a['item_key'] in {'M2-11', 'M2-15', 'M2-20', 'M2-21'}
           for a in packet['m2_answers']):
        raise WorkflowHeld('BCB_RESTRICTED_ITEM_MEMBERSHIP')
    return packet


def validate_measurement(measurement: Measurement, packet: dict, uncertainty_version: str, objective_id=None):
    refs = {a['answer_revision_id'] for a in packet['m2_answers']}
    refs |= {s['id'] + '@' + s['version'] for s in packet['supporting_sources']}
    refs.add(packet['confirmed_uncertainty']['id'])
    if objective_id is not None:
        refs.add(objective_id)
    if (measurement.uncertainty_version != uncertainty_version or
            not set(measurement.source_refs) <= refs or
            len(set(measurement.source_refs)) != len(measurement.source_refs)):
        raise WorkflowHeld('MEASUREMENT_SOURCE_MISMATCH')
    if (len(measurement.response_codes) != len(measurement.response_options) or
            len(set(measurement.response_codes)) != len(measurement.response_codes) or
            len(set(measurement.response_options)) != len(measurement.response_options) or
            set(measurement.routing) != set(measurement.response_codes)):
        raise WorkflowHeld('MEASUREMENT_CODES_OR_ROUTING_INVALID')


def validate_draft(raw, frozen: Measurement) -> QGOutput:
    output = QGOutput.model_validate(raw)
    if output.measurement != frozen:
        raise WorkflowHeld('QG_FROZEN_MEASUREMENT_CHANGED')
    if output.decision == 'DRAFT':
        # Strict candidate guard: exact stimulus/population/timeframe must be visible.
        if any(x not in output.question for x in
               (frozen.stimulus, frozen.population, frozen.timeframe)):
            raise WorkflowHeld('QG_WORDING_CONTRACT_MISMATCH')
        numbers = set(re.findall(r'\d+(?:\.\d+)?', output.question))
        permitted = set(re.findall(r'\d+(?:\.\d+)?', ' '.join(
            (frozen.stimulus, frozen.population, frozen.timeframe))))
        if not numbers <= permitted:
            raise WorkflowHeld('QG_UNSOURCED_NUMBER')
    elif output.question:
        raise WorkflowHeld('QG_ABSTENTION_CONTAINS_QUESTION')
    return output


class ResearchWorkflow:
    def __init__(self, builder, authority, bank, runner):
        self.builder, self.authority, self.bank, self.runner = builder, authority, bank, runner

    def execute(self, request):
        packet = checked_context(self.builder, request)
        return self._evaluate(packet)

    def execute_objective(self, request, objective_id, actor_id, revision, context_reader, *, clarification_policy=None, candidate_policy=None):
        """Resolve the persisted objective before admission and after evaluation."""
        context = context_reader.qj_context(objective_id, actor_id, revision)
        packet = checked_context(self.builder, request)
        source = context["source"]
        identity, confirmation = packet["identity"], packet["confirmation"]
        # The immutable context can anchor the original objective. A revised
        # objective must descend from that exact record through persisted links.
        anchor = packet["confirmed_uncertainty"]
        ancestor = context
        visited = set()
        while ancestor["objective_id"] != anchor["id"]:
            parent = ancestor["source"].get("parent_objective_id")
            if not parent or parent in visited:
                raise WorkflowHeld("OBJECTIVE_SOURCE_MISMATCH")
            visited.add(parent)
            ancestor = context_reader.qj_context(parent, actor_id, revision)
            if ancestor["source"]["confirmation_id"] != source["confirmation_id"]:
                raise WorkflowHeld("OBJECTIVE_SOURCE_MISMATCH")
        if (identity["assessment_id"] != source["assessment_id"] or
                identity["owner_id"] != str(actor_id) or
                confirmation["id"] != source["confirmation_id"] or
                confirmation["digest"] != source["snapshot_digest"] or
                confirmation["revision"] != revision or
                context["objective_id"] != str(objective_id) or
                anchor["exact_text"] != ancestor["objective"]):
            raise WorkflowHeld("OBJECTIVE_SOURCE_MISMATCH")
        result = self._evaluate(packet, context)
        if context_reader.qj_context(objective_id, actor_id, revision) != context:
            raise WorkflowHeld("OBJECTIVE_SOURCE_CHANGED")
        if result["qj"]["route"] == "HOLD" and clarification_policy is not None:
            # A HOLD can also be scientific or jurisdictional. Only a trusted
            # measurement policy may classify it as missing research details.
            decision = clarification_policy(context, result["qj"])
            if decision is not None:
                limitation, proposal = decision
                context_reader.record_qj_limitation(objective_id, actor_id, revision, limitation, proposal)
        if candidate_policy and result["qg"] and result["qg"]["decision"] in {"REUSE_CANDIDATE", "DRAFT"}:
            evidence = candidate_policy(context, result)
            measurement = result["qj"]["measurement"]
            options = evidence["options"]
            if ([o["code"] for o in options] != measurement["response_codes"] or
                    [o["label"] for o in options] != measurement["response_options"] or
                    any(type(o.get("eligible")) is not bool for o in options) or
                    not evidence["question"].strip() or not evidence["source_receipt"].strip()):
                raise WorkflowHeld("CANDIDATE_SOURCE_MISMATCH")
            if result["qg"]["decision"] == "DRAFT" and evidence["question"] != result["qg"]["question"]:
                raise WorkflowHeld("CANDIDATE_SOURCE_MISMATCH")
            if result["qg"]["decision"] == "REUSE_CANDIDATE" and evidence["source_version"] != result["qg"]["item_version"]:
                raise WorkflowHeld("BANK_VERSION_MISMATCH")
            result["candidate_version"] = context_reader.persist_candidate(objective_id, actor_id, revision,
                                                                           context, result, evidence)
        return result

    def _evaluate(self, packet, objective=None):
        # Verifies current UC version/latest nonwithdrawn event, purpose, essential
        # conflict resolution, exact BCB version and adopted measurement policy.
        task = self.authority.admit_qj(packet)
        uncertainty_version = task['uncertainty_version']
        qj_input = packet if objective is None else {'context': packet, 'research_objective': objective}
        qj = QJOutput.model_validate(self.runner('QJ', qj_input, QJOutput))
        self.authority.require_current(packet, task)
        result = {'qj': qj.model_dump(), 'qg': None, 'bank': 'not_checked',
                  'source_fingerprint': packet['packet_hash'], **no_authority()}
        if qj.route != 'CUSTOMER_SURVEY_CANDIDATE':
            if qj.measurement is not None:
                raise WorkflowHeld('NON_SURVEY_MEASUREMENT_FORBIDDEN')
            return result
        if qj.measurement is None:
            raise WorkflowHeld('SURVEY_MEASUREMENT_INCOMPLETE')
        validate_measurement(qj.measurement, packet, uncertainty_version,
                             objective['objective_id'] if objective else None)
        # Independent adopted validator, not the same model asserting validity.
        self.authority.validate_measurement(packet, task, qj.measurement.model_dump())
        lookup = self.bank.lookup(qj.measurement.model_dump(), packet)
        self.bank.verify_receipt(lookup, digest(qj.measurement.model_dump()), packet)
        result['bank'] = lookup['outcome']
        if lookup['outcome'] == 'verified_equivalent':
            if not lookup.get('item_version') or not lookup.get('approval_receipt'):
                raise WorkflowHeld('BANK_EXACT_APPROVAL_REQUIRED')
            # Reuse is a candidate assignment; no QG model invocation.
            result['qg'] = {'decision': 'REUSE_CANDIDATE',
                            'item_version': lookup['item_version']}
        elif lookup['outcome'] == 'verified_no_equivalent':
            self.authority.require_drafting(packet, task, lookup)
            raw = self.runner('QG', {'context': packet,
                'frozen_measurement': qj.measurement.model_dump(), 'bank_receipt': lookup}, QGOutput)
            result['qg'] = validate_draft(raw, qj.measurement).model_dump()
        else:
            raise WorkflowHeld('BANK_AUTHORITY_UNVERIFIED')
        self.authority.require_current(packet, task)
        return result
