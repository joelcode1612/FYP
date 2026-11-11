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


def validate_measurement(measurement: Measurement, packet: dict, uncertainty_version: str):
    refs = {a['answer_revision_id'] for a in packet['m2_answers']}
    refs |= {s['id'] + '@' + s['version'] for s in packet['supporting_sources']}
    refs.add(packet['confirmed_uncertainty']['id'])
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
        # Verifies current UC version/latest nonwithdrawn event, purpose, essential
        # conflict resolution, exact BCB version and adopted measurement policy.
        task = self.authority.admit_qj(packet)
        uncertainty_version = task['uncertainty_version']
        qj = QJOutput.model_validate(self.runner('QJ', packet, QJOutput))
        self.authority.require_current(packet, task)
        result = {'qj': qj.model_dump(), 'qg': None, 'bank': 'not_checked',
                  'source_fingerprint': packet['packet_hash'], **no_authority()}
        if qj.route != 'CUSTOMER_SURVEY_CANDIDATE':
            if qj.measurement is not None:
                raise WorkflowHeld('NON_SURVEY_MEASUREMENT_FORBIDDEN')
            return result
        if qj.measurement is None:
            raise WorkflowHeld('SURVEY_MEASUREMENT_INCOMPLETE')
        validate_measurement(qj.measurement, packet, uncertainty_version)
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
