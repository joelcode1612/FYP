"""Deterministic BCB reuse, separate QJ advice and approved-bank-first gated QG.

Authority/bank/disclosure ports must be trusted server adapters. There is no HTTP
payload accepting grants and no production implementation inventing missing owners.
"""
import re

from sitewise.project1.contracts import (
    Measurement, QGOutput, QJOutput, WorkflowHeld, digest, no_authority,
)
from sitewise.project1.disclosure import QG_SCHEMA_VERSION
from sitewise.project1.measurement_policy import verify_validation_receipt
from sitewise.project1.qg_contract import (
    CONTRACT_VERSION, QGCandidate, facts_from_packet, field_authority,
    validate_candidate,
)

#: Where a frozen measurement may come from on the direct QG path.
#:
#: QJ used to produce the measurement. With QJ removed from the active path, no
#: production component produces one: the BCB packet carries the uncertainty as
#: free text and the concept as a single ``description`` string, so construct,
#: population, timeframe, response coding, routing, denominator and limitations
#: have no persisted, confirmed source. That gap is an unresolved contract
#: decision. It is named here and refused, rather than filled in by this engine.
#:
#: The canonical synthetic fixture is accepted because it is a versioned artefact
#: with a declared construct and coding, and it is test-only by construction.
DIRECT_QG_MEASUREMENT_SOURCES = {
    'CANONICAL_SYNTHETIC_FIXTURE': {'test_only': True, 'requires_ref': True},
    # Reserved for a future authorised production source. Nothing supplies it yet,
    # so this entry exists to make the missing dependency explicit and to refuse it.
    'AUTHORISED_PRODUCTION_SPEC': {'test_only': False, 'requires_ref': True},
}


def _call_runner(runner, stage, payload, output_type, *, prompt_key=None):
    """Invoke the runner, selecting a prompt independently of the ledger stage.

    ``stage`` is the governed label the attempt ledger records; ``prompt_key``
    selects which template is rendered. Runners that do not advertise
    ``supports_prompt_key`` are called exactly as before, so existing doubles and
    any third-party runner keep working without a signature change.
    """
    if prompt_key is not None and getattr(runner, 'supports_prompt_key', False):
        return runner(stage, payload, output_type, prompt_key=prompt_key)
    return runner(stage, payload, output_type)


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
        # A bare number-subset check cannot protect the price: "12 oz" already
        # permits the token "12", so a draft that rewrites RM13 as RM12 passed.
        # Currency amounts are therefore compared as whole tokens, not digits.
        # Found by the P4 held-out case (2026-11-17); see D-01 in the QJ/QG
        # execution report.
        amounts = set(re.findall(r'RM\s?\d+(?:\.\d+)?', output.question, re.I))
        if not amounts <= set(re.findall(r'RM\s?\d+(?:\.\d+)?', ' '.join(
                (frozen.stimulus, frozen.population, frozen.timeframe)), re.I)):
            raise WorkflowHeld('QG_UNSOURCED_AMOUNT')
    elif output.question:
        raise WorkflowHeld('QG_ABSTENTION_CONTAINS_QUESTION')
    return output


class ResearchWorkflow:
    def __init__(self, builder, authority, bank, runner):
        self.builder, self.authority, self.bank, self.runner = builder, authority, bank, runner

    def execute_fixed_option_candidate(self, request, *, objective, policy, revision_feedback=None):
        """Bounded candidate-only adapter; policy is a trusted server port.

        This method does not authorize model dispatch or customer fielding. The
        caller must supply the existing governed runner and a server-resolved
        objective/population policy; no request can supply a grant.
        """
        from sitewise.project1.qg_fixed_options import (
            FIXED_OPTION_CONTRACT, FixedOptionCandidate, validate_fixed_candidate,
        )
        packet = checked_context(self.builder, request)
        if not objective or not objective.get('objective_id') or not objective.get('text'):
            raise WorkflowHeld('QG_APPROVED_OBJECTIVE_REQUIRED')
        if not policy or not policy.get('policy_version') or not policy.get('approved_population'):
            raise WorkflowHeld('QG_FIXED_POLICY_UNAVAILABLE')
        resolve = getattr(self.authority, 'resolve_version', None)
        if resolve is None:
            raise WorkflowHeld('QG_MEASUREMENT_AUTHORITY_UNVERIFIED')
        task = resolve(packet)
        if (not policy.get('objective_version') or
                str(policy['objective_version']) != str(task.get('uncertainty_version'))):
            raise WorkflowHeld('QG_OBJECTIVE_VERSION_MISMATCH')
        facts = facts_from_packet(packet, objective=objective,
                                  uncertainty_version=task['uncertainty_version'])
        uncertainty = packet.get('confirmed_uncertainty') or {}
        if (str(uncertainty.get('id')) != str(objective['objective_id']) or
                uncertainty.get('exact_text') != objective['text']):
            raise WorkflowHeld('QG_CONTEXT_OBJECTIVE_MISMATCH')
        qg_input = {
            'contract_version': FIXED_OPTION_CONTRACT,
            'schema_version': QG_SCHEMA_VERSION,
            'source_fingerprint': facts.fingerprint,
            'confirmed_facts': facts.model_dump(),
            'policy_version': policy['policy_version'],
        }
        if revision_feedback:
            qg_input['previous_attempt'] = revision_feedback
        raw = _call_runner(self.runner, 'QG', qg_input, FixedOptionCandidate,
                           prompt_key='QG_FIXED_OPTION')
        candidate = validate_fixed_candidate(raw, facts,
            supported_formats=frozenset(policy['supported_formats']),
            approved_population=policy['approved_population'],
            period_required=policy['period_required'])
        self.authority.require_current(packet, task)
        return {'qg': candidate.model_dump(mode='json'),
                'contract_version': FIXED_OPTION_CONTRACT,
                'source_fingerprint': packet['packet_hash'],
                'objective_id': facts.objective_id,
                'admission': {'uncertainty_version': task['uncertainty_version'],
                              'semantic_source_review_required': True},
                'field_authority': {'proposed_fields_are_candidates': True,
                                    'scientifically_adopted': False,
                                    'fielding_authorized': False,
                                    'flutter_compatibility': 'NOT_VERIFIED'},
                'candidate_authority': 'ENTREPRENEUR_REVIEW_ONLY',
                'bank': 'NOT_CONSULTED_DIRECT_QG', **no_authority()}

    # -- active V1 path (directive V2.0): BCB -> QG, no QJ, no shared bank ----
    def execute_direct_qg(self, request, *, frozen_measurement, measurement_source,
                          measurement_source_ref=None, objective=None):
        """Prepare one QG candidate without QJ and without a shared-bank lookup.

        QJ used to *produce* the frozen measurement. Removing it leaves the
        measurement with no producer inside this engine, and the directive forbids
        inventing a replacement. So this method does not build, infer or complete a
        measurement: it accepts one and refuses anything it cannot bind to the
        packet. The caller must state where the measurement came from, and only a
        source that is declared test-only is accepted today — see
        ``DIRECT_QG_MEASUREMENT_SOURCES``.

        What is preserved from the QJ era: the F-01 version binding, the F-02
        deterministic validation and its verified receipt, and the D-01 price
        fidelity check in ``validate_draft``.
        """
        packet = checked_context(self.builder, request)
        return self._direct_qg(packet, frozen_measurement, measurement_source,
                               measurement_source_ref, objective)

    def _direct_qg(self, packet, frozen, source, source_ref, objective):
        if not isinstance(frozen, Measurement):
            raise WorkflowHeld('QG_FROZEN_MEASUREMENT_REQUIRED')
        declared = DIRECT_QG_MEASUREMENT_SOURCES.get(source)
        if declared is None:
            raise WorkflowHeld('QG_MEASUREMENT_SOURCE_UNRECOGNIZED')
        if not declared['test_only']:
            # Reserved for a future authorised production source. Nothing supplies
            # it yet, so accepting it would be accepting a claim with no evidence.
            raise WorkflowHeld('QG_MEASUREMENT_SOURCE_NOT_AVAILABLE')
        if declared['requires_ref'] and not source_ref:
            raise WorkflowHeld('QG_MEASUREMENT_SOURCE_REF_REQUIRED')

        # Version resolution only; no model is invoked. `resolve_version`, not
        # `admit_qj`: this path does not execute QJ, so it must not inherit QJ's
        # permission assertion as a hidden precondition.
        resolve = getattr(self.authority, 'resolve_version', None)
        if resolve is None:
            raise WorkflowHeld('QG_MEASUREMENT_AUTHORITY_UNVERIFIED')
        task = resolve(packet)
        version = task['uncertainty_version']
        objective_id = objective['objective_id'] if objective else None
        validate_measurement(frozen, packet, version, objective_id)
        receipt = self.authority.validate_measurement(packet, task, frozen.model_dump())
        verified = verify_validation_receipt(receipt, frozen.model_dump(), packet)

        qg_input = {'context': packet,
                    'frozen_measurement': frozen.model_dump(),
                    'measurement_validation': {
                        'status': verified['status'],
                        'policy_version': verified['policy_version'],
                        'policy_digest': verified['policy_digest'],
                        'measurement_digest': verified['measurement_digest'],
                        'receipt_id': verified['receipt_id'],
                        'scientific_accepted': False},
                    'measurement_source': {'kind': source, 'ref': source_ref,
                                           'test_only': True}}
        if objective is not None:
            qg_input['research_objective'] = objective
        raw = self.runner('QG', qg_input, QGOutput)
        draft = validate_draft(raw, frozen)
        self.authority.require_current(packet, task)
        return {'qj': None, 'qg': draft.model_dump(),
                # Explicitly not 'not_checked': the bank is out of this path by
                # contract, so a reader cannot mistake this for a skipped lookup.
                'bank': 'NOT_CONSULTED_DIRECT_QG',
                'measurement_validation': verified,
                'measurement_source': qg_input['measurement_source'],
                'source_fingerprint': packet['packet_hash'],
                'objective_id': objective_id,
                'admission': {'uncertainty_version': version,
                              'uncertainty_version_basis': task.get('uncertainty_version_basis'),
                              'uncertainty_version_rule': task.get('uncertainty_version_rule')},
                'candidate_authority': 'ENTREPRENEUR_REVIEW_ONLY',
                **no_authority()}

    # -- contract 2.0 active path: BCB confirmed facts -> QG proposal --------
    def execute_qg_from_facts(self, request, *, objective=None, bdj_findings=(),
                              revision_feedback=None):
        """Generate one QG candidate from confirmed facts. No QJ, no measurement.

        This is the path CP-01 asks for: QG no longer waits for an authored
        ``Measurement``. It receives what the entrepreneur confirmed and returns
        a proposal plus a structured abstention when the facts are insufficient.

        ``revision_feedback`` carries the exact validation failure from a previous
        attempt, so a retry is informed by the real reason rather than by a
        restatement of the same prompt. See ``qg_iteration``.
        """
        packet = checked_context(self.builder, request)
        return self._qg_from_facts(packet, objective, bdj_findings, revision_feedback)

    def _qg_from_facts(self, packet, objective, bdj_findings, revision_feedback=None):
        resolve = getattr(self.authority, 'resolve_version', None)
        if resolve is None:
            raise WorkflowHeld('QG_MEASUREMENT_AUTHORITY_UNVERIFIED')
        task = resolve(packet)
        version = task['uncertainty_version']
        facts = facts_from_packet(packet, objective=objective,
                                  bdj_findings=bdj_findings,
                                  uncertainty_version=version)

        qg_input = {'contract_version': CONTRACT_VERSION,
                    # The disclosure port binds the packet to its authorization
                    # by schema and source fingerprint. Both are server-derived:
                    # the schema is a constant, the fingerprint is a @property
                    # over the confirmed facts assembled from this verified packet.
                    'schema_version': QG_SCHEMA_VERSION,
                    'source_fingerprint': facts.fingerprint,
                    'confirmed_facts': facts.model_dump(),
                    'field_authority': {'proposed_fields_are_candidates': True,
                                        'confirmed_fields_are_facts': True,
                                        'scientifically_adopted': False,
                                        'fielding_authorized': False}}
        if revision_feedback:
            # The failure is data, not instruction: it is quoted to the model so
            # the retry targets the actual defect. It never widens what the model
            # is allowed to assert — `validate_candidate` runs unchanged.
            qg_input['previous_attempt'] = revision_feedback
        raw = _call_runner(self.runner, 'QG', qg_input, QGCandidate,
                           prompt_key='QG_PROPOSAL')
        candidate = validate_candidate(raw, facts)
        self.authority.require_current(packet, task)
        return {'qj': None,
                'qg': candidate.model_dump(),
                'contract_version': CONTRACT_VERSION,
                'bank': 'NOT_CONSULTED_DIRECT_QG',
                'confirmed_facts': facts.model_dump(),
                'field_authority': field_authority(candidate),
                'source_fingerprint': packet['packet_hash'],
                'objective_id': facts.objective_id,
                'admission': {'uncertainty_version': version,
                              'uncertainty_version_basis': task.get('uncertainty_version_basis'),
                              'uncertainty_version_rule': task.get('uncertainty_version_rule')},
                'candidate_authority': 'ENTREPRENEUR_REVIEW_ONLY',
                **no_authority()}

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
        # F-01: the version label is server-authored. Before this, the model had to
        # invent it — nothing in the prompt named the field or its expected value —
        # so the survey branch was reachable only by guessing a uuid it never saw.
        # The resolved value is now placed in the input verbatim, with its basis, so
        # copying it is the only correct behaviour and substitution is detectable.
        admission = {'uncertainty_version': uncertainty_version,
                     'uncertainty_version_basis': task.get('uncertainty_version_basis'),
                     'uncertainty_version_rule': task.get('uncertainty_version_rule'),
                     'policy_version': task.get('policy_version'),
                     'authorization_status': task.get('authorization_status')}
        qj_input = {'context': packet, 'admission': admission}
        if objective is not None:
            qj_input['research_objective'] = objective
        qj = QJOutput.model_validate(self.runner('QJ', qj_input, QJOutput))
        self.authority.require_current(packet, task)
        result = {'qj': qj.model_dump(), 'qg': None, 'bank': 'not_checked',
                  'source_fingerprint': packet['packet_hash'],
                  'admission': admission, **no_authority()}
        if qj.route != 'CUSTOMER_SURVEY_CANDIDATE':
            if qj.measurement is not None:
                raise WorkflowHeld('NON_SURVEY_MEASUREMENT_FORBIDDEN')
            return result
        if qj.measurement is None:
            raise WorkflowHeld('SURVEY_MEASUREMENT_INCOMPLETE')
        validate_measurement(qj.measurement, packet, uncertainty_version,
                             objective['objective_id'] if objective else None)
        # F-02: an independent adopted validator, not the same model asserting
        # validity. The receipt is not trusted on its own word — it is re-derived
        # against the server-side policy registry and the live measurement/packet,
        # so a no-op authority, a fabricated policy version, a stale receipt or an
        # edited one all stop here. See measurement_policy.verify_validation_receipt.
        receipt = self.authority.validate_measurement(packet, task, qj.measurement.model_dump())
        result['measurement_validation'] = verify_validation_receipt(
            receipt, qj.measurement.model_dump(), packet)
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
            # F-02: a QG draft is a new research question, so it may only follow a
            # measurement that a real, versioned policy admitted. A duck-typed
            # double whose `validate_measurement` does nothing has no policy version
            # and is refused here, which is what closes the no-op bypass.
            if not getattr(self.authority, 'measurement_policy_version', None):
                raise WorkflowHeld('MEASUREMENT_AUTHORITY_UNVERIFIED')
            self.authority.require_drafting(packet, task, lookup)
            raw = self.runner('QG', {'context': packet,
                'frozen_measurement': qj.measurement.model_dump(), 'bank_receipt': lookup}, QGOutput)
            result['qg'] = validate_draft(raw, qj.measurement).model_dump()
        else:
            raise WorkflowHeld('BANK_AUTHORITY_UNVERIFIED')
        self.authority.require_current(packet, task)
        return result
