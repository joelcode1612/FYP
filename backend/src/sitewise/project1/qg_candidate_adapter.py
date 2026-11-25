"""Versioned controlled-measurement -> Direct-QG fixed-option candidate adapter.

What this adapter is
--------------------
The seam the directive asks for: a *versioned* adapter that takes a trusted
measurement specification and an **admitted** objective, verifies a per-assessment
QG authorization, dispatches at most one generation attempt, validates the output
against the five fixed response formats, and persists a versioned candidate.

It does not replace ``DirectQgService``. That service still owns the V2.0
composition and still fails closed with ``QG_FIXED_OPTION_ADMISSION_UNAVAILABLE``
when no policy resolver is supplied. This adapter *is* that policy resolver's
server-side half, plus the persistence the service never had.

Why the gates are ordered this way
----------------------------------
Cheapest and most authoritative first:

1. **Measurement.** If no approved measurement applies, there is nothing to
   generate, and a candidate must not be invented for a construct nobody has
   approved. Abstention is a result.
2. **Admission.** ``APPROVED`` is the owner's own decision; ``ADMITTED`` is the
   separate authority that the cited gap is worth researching. Only ``ADMITTED``
   may proceed. This is checked against the admission record, not a flag.
3. **Authorization.** Exact-bound, unexpired, unconsumed, same owner.
4. **Dispatch.** Only now is the injected generator called. Every refusal above
   happens before the call, so a hold can never spend a provider attempt.
5. **Validation.** Structural, provenance and semantic checks run on the output.
6. **Persistence and consumption.** The candidate row is written, then the
   authorization is spent naming that candidate. A failure between the two
   leaves an unconsumed authorization and no candidate, which is recoverable;
   the reverse would leave a candidate nobody authorized.

What it refuses to claim
------------------------
``execution_mode`` is copied from the generator's receipt rather than assumed,
so a simulated run and a real provider run are distinguishable in the row
itself. A ``LIVE`` receipt is refused unless it names the authorised provider,
carries a run id and attempt number, records both model identities, and binds
the same prompt version and hash the authorization bound. ``fielding_authorized``
is always false, ``scientific_acceptance`` is always false, and a candidate is
never counted as an approved measurement. A structurally valid candidate is a
*review object*.
"""
from __future__ import annotations

import json
import uuid
from dataclasses import dataclass

from sqlalchemy import text

from sitewise.project1 import measurement_library as ml
from sitewise.project1 import qg_attempt
from sitewise.project1 import qg_authorization
from sitewise.project1 import source_currentness
from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.qg_contract import ConfirmedFacts, field_authority
from sitewise.project1.qg_fixed_options import (
    FIXED_OPTION_CONTRACT, validate_fixed_candidate,
)

#: Version of this adapter. A behavioural change is a new version, because a
#: persisted candidate names the adapter that produced it.
ADAPTER_VERSION = 'P1-QG-FIXED-ADAPTER-1.0-CAND'

#: The production hold remains in force. This adapter is reachable only through
#: an explicitly named scope, and reports which one.
SYNTHETIC_SCOPE = 'SYNTHETIC_CANDIDATE_ONLY'

#: Owner-authorised candidate-only test against the real provider. It unlocks a
#: *real* dispatch and nothing else: the candidate is still unfieldable, still
#: not scientifically accepted, and the production hold is still in force.
LIVE_SCOPE = 'LIVE_PROVIDER_CANDIDATE_TEST'

#: Scope -> the execution mode a persisted candidate is allowed to claim. The
#: mode is a property of the authorisation, not of whatever the generator says,
#: so a synthetic-scoped adapter cannot record ``LIVE`` and a live-scoped
#: adapter cannot record ``SIMULATED``.
SCOPE_EXECUTION_MODE = {SYNTHETIC_SCOPE: 'SIMULATED', LIVE_SCOPE: 'LIVE'}

#: The only provider identity a ``LIVE`` candidate may name.
LIVE_PROVIDER = 'tokenharbor'

GENERATED = 'GENERATED'
VALIDATED = 'VALIDATED'
ABSTAINED = 'ABSTAINED'


@dataclass(frozen=True)
class AdapterGates:
    measurement: dict
    admission: dict
    authorization: dict

    def as_dict(self) -> dict:
        return {'measurement': self.measurement, 'admission': self.admission,
                'authorization': self.authorization}


@dataclass(frozen=True)
class ExecutionReceipt:
    """What actually happened when the generator ran.

    This exists because the previous ``_persist`` hardcoded
    ``SIMULATED``/``simulated-qg-v1``/``run_id = NULL``. A genuine provider call
    would have been recorded as a simulation, and a reader could not tell the
    two apart. Provenance is now carried, not assumed.

    ``prompt_version`` and ``prompt_sha256`` are part of the receipt so the
    adapter can prove the prompt that was actually dispatched is the one the
    authorization bound. Without that, a caller could authorise prompt A and
    dispatch prompt B.
    """

    execution_mode: str
    model_provider: str
    model_requested: str
    model_returned: str | None
    run_id: str | None
    attempt_no: int | None
    prompt_version: str
    prompt_sha256: str


@dataclass(frozen=True)
class GenerationResult:
    """The generator's output plus the receipt that describes how it was made."""

    output: dict
    receipt: ExecutionReceipt


#: The receipt a synthetic generator is allowed to produce. ``run_id`` and
#: ``attempt_no`` are genuinely absent: no attempt was reserved and no provider
#: was called, so recording an identifier would be a fabrication.
SIMULATED_RECEIPT = ExecutionReceipt(
    execution_mode='SIMULATED',
    model_provider='simulated-qg-v1',
    model_requested='simulated-qg-v1',
    model_returned=None,
    run_id=None,
    attempt_no=None,
    prompt_version='',
    prompt_sha256='',
)


def facts_from_objective(packet: dict, *, objective_id: str,
                         objective_text: str, admission_id: str | None = None,
                         authority_ref: str | None = None) -> ConfirmedFacts:
    """Assemble ``ConfirmedFacts`` for the M2 V2 -> BDJ objective path.

    ``qg_contract.facts_from_packet`` expects a ``confirmed_uncertainty`` block.
    A BCB 1.2.1 packet built from a confirmed M2 V2 revision has
    ``confirmed_uncertainty = null`` — the M2 V2 contract has no confirmed
    uncertainty object at all. The anchor in this path is the **authorised
    objective**, so that is what is bound, and the substitution is recorded in
    ``uncertainty_source`` rather than being passed off as a confirmed
    uncertainty.

    ``authority_ref`` names that anchor in contract 2.1 (``decision:<uuid>``),
    where no admission row exists. ``admission_id`` remains for the legacy path.
    Exactly one must be supplied; a candidate whose provenance names neither
    cannot be traced back to the thing that authorised it.
    """
    anchor = authority_ref or (f'admission:{admission_id}' if admission_id else None)
    if anchor is None:
        raise WorkflowHeld('QG_CONFIRMED_FACTS_INCOMPLETE')
    answers = packet.get('m2_answers') or []
    revision_ids = [str(a['answer_revision_id']) for a in answers
                    if a.get('answer_revision_id')]
    if not revision_ids:
        raise WorkflowHeld('QG_CONFIRMED_FACTS_INCOMPLETE')

    texts: list[str] = []
    for answer in answers:
        value = answer.get('value')
        if isinstance(value, str):
            texts.append(value)
        elif isinstance(value, list):
            texts.extend(str(v) for v in value)
        elif isinstance(value, dict):
            texts.extend(str(v) for v in value.values() if isinstance(v, str))
    # The objective text is the entrepreneur-admitted construct being measured;
    # it is included so a candidate that restates it is not refused for using a
    # number that only appears there.
    texts.append(objective_text)

    joined = '\n'.join(texts)
    identity = packet.get('identity') or {}
    concept = packet.get('concept') or {}
    assessment_id = (identity.get('assessment_id') or concept.get('assessment_id')
                     or packet.get('assessment_id'))
    if not assessment_id:
        raise WorkflowHeld('QG_CONFIRMED_FACTS_INCOMPLETE')

    from sitewise.project1.qg_contract import _currency, _numbers, _offers
    sources = sorted({f"{s['id']}@{s['version']}"
                      for s in packet.get('supporting_sources') or []
                      if isinstance(s, dict) and s.get('id')})
    sources.append(f'objective:{objective_id}')
    sources.append(anchor)

    # A confirmed ``amount_myr`` is a decimal in MYR by the item's own type, so
    # rendering it as ``RM<amount>`` restates the confirmed value rather than
    # inventing a currency. Without this, a question that quotes the confirmed
    # price would be refused as an unsourced amount — the price would be
    # confirmed yet unusable.
    currency = set(_currency(joined))
    for answer in answers:
        value = answer.get('value')
        if isinstance(value, dict) and isinstance(value.get('amount_myr'), str):
            amount = value['amount_myr'].strip()
            if amount:
                currency.add('RM' + amount.replace(' ', '').upper())
    for declaration in packet.get('declarations') or []:
        value = declaration.get('value')
        if isinstance(value, dict) and isinstance(value.get('amount_myr'), str):
            amount = value['amount_myr'].strip()
            if amount:
                currency.add('RM' + amount.replace(' ', '').upper())

    return ConfirmedFacts(
        assessment_id=str(assessment_id),
        objective_id=objective_id,
        objective_text=objective_text,
        # Named for what it is: the admitted objective, not a confirmed
        # uncertainty. A reader must not have to infer that from context.
        uncertainty_id=objective_id,
        uncertainty_version=anchor,
        uncertainty_text=objective_text,
        bcb_version=str(packet.get('context_version')
                        or packet.get('schema_version')
                        or 'business-context-package/1.1'),
        context_hash=str(packet.get('packet_hash') or ''),
        m2_answer_revision_ids=revision_ids,
        bdj_findings=[],
        confirmed_offers=_offers(joined),
        confirmed_numbers=sorted(_numbers(joined)),
        confirmed_currency=sorted(currency),
        source_refs=sources,
    )


class QgCandidateAdapter:
    """One governed measurement -> QG candidate attempt."""

    def __init__(self, *, engine, actor_id, store: ml.MeasurementStore,
                 admission_lookup, generate, scope: str = SYNTHETIC_SCOPE,
                 source_check=None):
        if scope not in SCOPE_EXECUTION_MODE:
            # The production path is not enabled by this directive. Refusing an
            # unknown scope is what keeps the hold unconditional.
            raise WorkflowHeld('QG_ADAPTER_SCOPE_NOT_AUTHORIZED')
        self.engine = engine
        self.actor_id = actor_id
        self.store = store
        self.admission_lookup = admission_lookup
        self.generate = generate
        self.scope = scope
        # A LIVE attempt must prove its source is still the workflow's current
        # one. Required for LIVE, optional for synthetic: a synthetic candidate
        # never claims a provider receipt, so a stale context cannot misrepresent
        # a real call. Supplied as a callable so the authority (the persisted
        # business-context service) stays outside the adapter.
        self.source_check = source_check
        self.execution_mode = SCOPE_EXECUTION_MODE[scope]
        self.dispatch_calls = 0

    # -- gates ------------------------------------------------------------
    def resolve_measurement(self, objective_id: str, stimulus: dict) -> dict:
        return ml.resolve(self.store, objective_id, stimulus=stimulus,
                          supported_formats=ml.CANDIDATE_FORMATS,
                          # Only a SYNTHETIC_TEST-scoped approval can unlock the
                          # lab path, and the resolver labels it as such.
                          allow_synthetic_test_approval=True)

    def require_admitted(self, proposal_id, *, source_fingerprint: str,
                         objective_id: str) -> dict:
        """An admission must exist, name *this* objective and still be eligible.

        Two separate refusals, deliberately kept apart:

        * ``QG_OBJECTIVE_NOT_ADMITTED_<STATE>`` — no usable admission record.
        * ``QG_ADMISSION_OBJECTIVE_MISMATCH`` — there is an admission, but it
          admits a different objective. Without this check an admission for one
          proposal could authorise a candidate for an unrelated objective, which
          is the exact hole the objective binding column exists to close.
        """
        admission = self.admission_lookup(proposal_id, source_fingerprint)
        state = admission.get('admission_state')
        if state != 'ADMITTED':
            raise WorkflowHeld(f'QG_OBJECTIVE_NOT_ADMITTED_{state}')
        bound = admission.get('objective_id')
        if bound is not None and bound != objective_id:
            raise WorkflowHeld('QG_ADMISSION_OBJECTIVE_MISMATCH')
        if bound is None:
            raise WorkflowHeld('QG_ADMISSION_BINDS_NO_FIXED_OBJECTIVE')
        if admission.get('qg_eligible') is False:
            raise WorkflowHeld(
                'QG_ADMISSION_NOT_ELIGIBLE_'
                + str(admission.get('qg_blocker') or 'UNSPECIFIED'))
        return admission

    def require_authorization(self, **binding) -> dict:
        return qg_authorization.verify(
            self.engine, actor_id=self.actor_id, **binding)

    # -- execution receipt ------------------------------------------------
    def _require_receipt(self, receipt: ExecutionReceipt, *, prompt_version: str,
                         prompt_sha256: str) -> None:
        """Refuse a receipt that cannot describe this adapter's authorised run.

        A ``LIVE`` candidate is only meaningful if every one of these holds, so
        each is a separate refusal code rather than one opaque failure.
        """
        if not isinstance(receipt, ExecutionReceipt):
            raise WorkflowHeld('QG_GENERATOR_RECEIPT_REQUIRED')
        if receipt.execution_mode != self.execution_mode:
            raise WorkflowHeld('QG_EXECUTION_MODE_MISMATCH')
        if receipt.execution_mode != 'LIVE':
            return
        if receipt.model_provider != LIVE_PROVIDER:
            raise WorkflowHeld('QG_LIVE_PROVIDER_NOT_AUTHORIZED')
        if not receipt.run_id:
            raise WorkflowHeld('QG_LIVE_RUN_ID_MISSING')
        if not isinstance(receipt.attempt_no, int) or receipt.attempt_no < 1:
            raise WorkflowHeld('QG_LIVE_ATTEMPT_NO_MISSING')
        if not (receipt.model_requested or '').strip():
            raise WorkflowHeld('QG_LIVE_MODEL_REQUESTED_MISSING')
        if not (receipt.model_returned or '').strip():
            raise WorkflowHeld('QG_LIVE_MODEL_RETURNED_MISSING')
        if (receipt.prompt_version != prompt_version
                or receipt.prompt_sha256 != prompt_sha256):
            # The dispatched prompt must be the authorised one. Recording a
            # different version would make the persisted row describe a run
            # nobody approved.
            raise WorkflowHeld('QG_LIVE_PROMPT_IDENTITY_MISMATCH')

    def _unwrap(self, produced, *, prompt_version: str,
                prompt_sha256: str) -> tuple[dict, ExecutionReceipt]:
        """Split the generator's return value into output and receipt.

        A bare dict is only admissible under the synthetic scope. Accepting one
        on the live path would recreate the defect this change removes: a real
        dispatch recorded as a simulation, or a simulation recorded as real.
        """
        if isinstance(produced, GenerationResult):
            self._require_receipt(produced.receipt, prompt_version=prompt_version,
                                  prompt_sha256=prompt_sha256)
            return produced.output, produced.receipt
        if self.execution_mode == 'SIMULATED':
            return produced, SIMULATED_RECEIPT
        raise WorkflowHeld('QG_GENERATOR_RECEIPT_REQUIRED')

    # -- main -------------------------------------------------------------
    def prepare(self, *, assessment_id, confirmation_id, assessment_revision,
                source_fingerprint, context_id, context_packet_hash,
                objective_id, objective_text, proposal_id, packet,
                stimulus: dict, authorization_id, prompt_version,
                prompt_sha256, population: str | None = None,
                authority: dict | None = None,
                response_format: str | None = None) -> dict:
        """Run the gated attempt. Returns an envelope, never a bare candidate.

        ``authority`` is the contract 2.1 relationship derived from the owner's
        approval (``qg_generation_eligibility.derive_objective_authority``).
        Supplying it replaces the legacy admission gate: the owner has already
        said this objective is worth researching, and asking again through a
        separate admission row is the step the directive removes. When it is
        absent the legacy admission path runs unchanged, because historical rows
        and the operator script still depend on it.

        ``response_format`` is only consulted when the basis is
        ``PROPOSED_NOT_CONFIRMED``: with no approved specification there is no
        format to inherit, so the drafting caller must name one and it is
        validated against the five supported formats. Naming it is a drafting
        choice; the row still records that no measurement was approved.
        """
        envelope = {
            'adapter_version': ADAPTER_VERSION,
            'fixed_option_contract': FIXED_OPTION_CONTRACT,
            'scope': self.scope,
            'execution_mode': self.execution_mode,
            'assessment_id': str(assessment_id),
            'objective_id': objective_id,
            'synthetic_scope': self.scope == SYNTHETIC_SCOPE,
            'production_hold': 'QG_FIXED_OPTION_ADMISSION_UNAVAILABLE',
            'fielding_authorized': False,
            'publication_authorized': False,
            'scientifically_accepted': False,
        }

        measurement = self.resolve_measurement(objective_id, stimulus)
        envelope['measurement'] = {
            k: measurement[k] for k in
            ('outcome', 'reason', 'measurement_id', 'measurement_version',
             'scientifically_approved', 'synthetic_test_scope',
             'missing_parameters', 'considered_specifications')
            if k in measurement}
        # Only a lab-scoped approval or a real scientific approval may proceed.
        reusable = measurement['outcome'] in (ml.REUSE, ml.REUSE_SYNTHETIC)
        if measurement['outcome'] == ml.ABSTAIN:
            envelope.update({
                'outcome': 'ABSTAINED_NO_MEASUREMENT',
                'dispatched': False,
                'candidate_persisted': False,
                'authorization_consumed': False,
                'abstention_reason': measurement['reason'],
            })
            return envelope
        if not reusable:
            if authority is None:
                envelope.update({
                    'outcome': 'HELD_NO_APPROVED_MEASUREMENT',
                    'dispatched': False,
                    'candidate_persisted': False,
                    'authorization_consumed': False,
                    'proposed_extension_allowed': True,
                    'abstention_reason': measurement['reason'],
                })
                return envelope
            # Contract 2.1: an approved *objective* may be drafted against a
            # proposed measurement. This is the only way a candidate can be
            # produced without a scientifically approved specification, and the
            # row says so: PROPOSED_NOT_CONFIRMED travels into
            # m2_qg_candidates.measurement_basis and into the envelope, so no
            # reader can mistake it for an approval.
            if response_format not in ml.CANDIDATE_FORMATS:
                raise WorkflowHeld('QG_PROPOSED_MEASUREMENT_FORMAT_REQUIRED')
            envelope['measurement']['measurement_basis'] = qg_authorization.BASIS_PROPOSED
            envelope['measurement']['response_format'] = response_format

        if authority is not None:
            decision = authority.get('decision') or {}
            objective_decision_id = str(decision.get('decision_id') or '')
            if not objective_decision_id:
                raise WorkflowHeld('QG_AUTHORITY_DECISION_REQUIRED')
            objective_kind = str(authority.get('objective_kind') or '')
            if objective_kind not in qg_authorization.OBJECTIVE_KINDS:
                raise WorkflowHeld('QG_AUTHORITY_KIND_REQUIRED')
            measurement_basis = (qg_authorization.BASIS_APPROVED if reusable
                                 else qg_authorization.BASIS_PROPOSED)
            admission_id = None
            authority_ref = f'decision:{objective_decision_id}'
            envelope['authority'] = {
                'authority_basis': qg_authorization.AUTHORITY_DECISION,
                'objective_decision_id': objective_decision_id,
                'objective_kind': objective_kind,
                'measurement_basis': measurement_basis,
                'decided_by': (None if decision.get('decided_by') is None
                               else str(decision.get('decided_by'))),
                'decided_at': decision.get('decided_at'),
                # Recorded as a value, not implied by an empty field: the
                # relationship was derived, and a reader should not have to
                # infer that no owner action is outstanding.
                'requires_separate_owner_action': False,
                'objective_id': authority.get('objective_id'),
                'confirmation_id': authority.get('confirmation_id'),
                'confirmation_revision': authority.get('confirmation_revision'),
            }
        else:
            admission = self.require_admitted(
                proposal_id, source_fingerprint=source_fingerprint,
                objective_id=objective_id)
            admission_id = admission['admission_id']
            authority_ref = f'admission:{admission_id}'
            objective_decision_id = None
            objective_kind = None
            measurement_basis = None
            envelope['admission'] = {
                'admission_state': admission.get('admission_state'),
                'admission_id': admission.get('admission_id'),
                'admission_reason': admission.get('admission_reason'),
                'objective_id': admission.get('objective_id'),
                'qg_eligible': admission.get('qg_eligible'),
            }

        # The admission says the owner once decided this. It does not say the
        # snapshot that decision cites is still the workflow's source. Checked
        # here, before any authorization is spent, for every caller.
        if self.source_check is None:
            if self.scope == LIVE_SCOPE:
                raise WorkflowHeld('QG_LIVE_SOURCE_CHECK_REQUIRED')
        else:
            verdict = self.source_check()
            code = source_currentness.refusal(
                verdict, authorized_context_packet_hash=context_packet_hash)
            if code is not None:
                envelope.update({
                    'outcome': 'HELD_SOURCE_NOT_CURRENT',
                    'source_refusal': code,
                    'source_context_id': (verdict or {}).get('context_id'),
                    'source_packet_hash': (verdict or {}).get('packet_hash'),
                    'dispatched': False,
                    'candidate_persisted': False,
                    'authorization_consumed': False,
                })
                return envelope

        authorization = self.require_authorization(
            authorization_id=authorization_id,
            assessment_id=assessment_id,
            source_fingerprint=source_fingerprint,
            context_id=context_id,
            context_packet_hash=context_packet_hash,
            objective_id=objective_id,
            objective_admission_id=admission_id,
            measurement_id=measurement['measurement_id'],
            measurement_version=measurement['measurement_version'],
            prompt_version=prompt_version,
            prompt_sha256=prompt_sha256,
            objective_decision_id=objective_decision_id,
            objective_kind=objective_kind,
            measurement_basis=measurement_basis,
        )
        envelope['authorization'] = {
            'authorization_id': authorization['authorization_id'],
            'expires_at': authorization['expires_at'],
            'consumed': authorization['consumed'],
        }

        facts = facts_from_objective(
            packet, objective_id=objective_id, objective_text=objective_text,
            admission_id=admission_id, authority_ref=authority_ref)

        # With a proposed basis there is no approved population to inherit, so
        # the generator is given whatever the caller supplied and validation
        # checks only that the candidate declares one.
        approved_population = (population
                               or measurement.get('population')
                               or '')
        approved_format = (response_format if measurement_basis
                           == qg_authorization.BASIS_PROPOSED
                           else measurement['response_format'])

        # With a proposed basis there is no approved specification to enforce, and
        # the registered prompt explicitly lets the model choose: "response_format
        # is exactly one of SINGLE_CHOICE, BINARY_CHOICE, ORDERED_SCALE,
        # NUMERIC_RANGE_OPTIONS, MULTIPLE_CHOICE". Constraining validation to the
        # caller's hint therefore refused a single-choice answer to a single-choice
        # question with UNSUPPORTED_FORMAT — a disagreement between the request
        # default and the prompt, not a defect in the answer. A proposed basis
        # accepts any registered format; an approved basis still enforces exactly
        # its own, because there the format *is* part of the specification.
        allowed_formats = (
            frozenset(ml.CANDIDATE_FORMATS)
            if measurement_basis == qg_authorization.BASIS_PROPOSED
            else frozenset({approved_format}))

        # Spend the attempt before the socket opens. Both records that authorise
        # it — the single-use authorization and the owner's consent grant — are
        # reserved in one transaction here, so a failed or unknown-outcome call
        # is still recorded as an attempt and cannot be replayed. Doing this
        # after persistence, as it used to be, meant a successful provider call
        # whose write failed left the authorization looking unspent.
        reservation = qg_attempt.reserve(
            self.engine, actor_id=self.actor_id,
            authorization_id=authorization_id,
            assessment_id=assessment_id,
            confirmation_id=confirmation_id,
            assessment_revision=assessment_revision,
            objective_decision_id=objective_decision_id)

        # Dispatch happens only now, after every gate above has passed.
        self.dispatch_calls += 1
        produced = self.generate({
            'facts': facts,
            'measurement': measurement,
            'objective_id': objective_id,
            'response_format': approved_format,
            'population': approved_population,
            'stimulus': stimulus,
        })
        raw, receipt = self._unwrap(
            produced, prompt_version=prompt_version, prompt_sha256=prompt_sha256)

        candidate = validate_fixed_candidate(
            raw, facts,
            supported_formats=allowed_formats,
            approved_population=approved_population,
            period_required=False,
            population_basis=(measurement_basis
                              or qg_authorization.BASIS_APPROVED))

        # The row must describe the question that was actually drafted. Under a
        # proposed basis the candidate may legitimately choose a format other than
        # the one the caller hinted, and recording the hint would make the row
        # claim a format the question does not have.
        #
        # An abstention has no measurement at all — the contract forbids one —
        # so there is no drafted format to read. Reading it unconditionally
        # raised ``AttributeError: 'NoneType' object has no attribute
        # 'response_format'`` *after* the provider had answered and the attempt
        # had been spent, which surfaced as a 500 and left no candidate row
        # (ledger reason RETURNED_NOT_PERSISTED). The column is NOT NULL and
        # CHECK-constrained to the five formats, so an abstention records the
        # format the attempt was aimed at; ``candidate_state = 'ABSTAINED'`` and
        # ``structural_status = 'ABSTAINED'`` are what say no question exists.
        if candidate.fixed_measurement is not None:
            recorded_format = candidate.fixed_measurement.response_format
        else:
            recorded_format = approved_format

        candidate_json = candidate.model_dump(mode='json')
        output_digest = digest(candidate_json)
        abstained = candidate.decision == 'ABSTAIN_NEEDS_REVIEW'

        if abstained:
            structural = 'ABSTAINED'
            state = ABSTAINED
        else:
            structural = 'STRUCTURALLY_VALID'
            state = VALIDATED

        candidate_id = uuid.uuid5(uuid.NAMESPACE_URL, '|'.join([
            'qg-fixed-candidate', str(assessment_id), str(objective_id),
            # The authority reference, not a legacy admission id: a 2.1 attempt
            # has no admission, and hashing 'None' would collide across
            # different approvals.
            authority_ref,
            str(measurement['measurement_id']),
            str(measurement['measurement_version']),
            output_digest, ADAPTER_VERSION]))

        request_digest = digest({
            'facts': facts.model_dump(mode='json'),
            'measurement': ('PROPOSED@' + str(approved_format)
                            if measurement_basis
                            == qg_authorization.BASIS_PROPOSED
                            else str(measurement['measurement_id']) + '@' +
                                 str(measurement['measurement_version'])),
            'objective_id': objective_id,
            'prompt_version': prompt_version,
            'prompt_sha256': prompt_sha256,
            'adapter_version': ADAPTER_VERSION,
        })

        persisted = self._persist(
            candidate_id=candidate_id, assessment_id=assessment_id,
            confirmation_id=confirmation_id,
            assessment_revision=assessment_revision,
            source_fingerprint=source_fingerprint, context_id=context_id,
            context_packet_hash=context_packet_hash, objective_id=objective_id,
            admission_id=admission_id, decision_id=objective_decision_id,
            objective_kind=objective_kind, measurement_basis=measurement_basis,
            measurement=measurement, authorization_id=authorization_id,
            prompt_version=prompt_version, prompt_sha256=prompt_sha256,
            request_digest=request_digest, output_digest=output_digest,
            response_format=recorded_format, state=state,
            structural=structural, candidate_json=candidate_json,
            receipt=receipt)

        # The attempt was spent before dispatch (see ``qg_attempt.reserve``), so
        # there is nothing left to consume here. The candidate names the
        # authorization it came from, which is the same link in the other
        # direction; ``consumed_candidate_id`` stays NULL because the candidate
        # did not exist when the attempt was reserved, and inventing a
        # post-dispatch second write would break the single-transition guard.
        consumed = bool(reservation.get('reserved'))

        envelope.update({
            'outcome': 'ABSTAINED_BY_MODEL' if abstained else 'CANDIDATE_VALIDATED',
            'dispatched': True,
            'dispatch_calls': self.dispatch_calls,
            'candidate_id': str(candidate_id),
            'candidate_state': state,
            'candidate_persisted': persisted['created'],
            'candidate_already_existed': not persisted['created'],
            'authorization_consumed': consumed,
            # Where the spend happened, and whether the owner's consent grant
            # was the record that paid for it. ``consent_id`` is null only for a
            # grant read from the legacy snapshot location, which has no row to
            # reserve.
            'attempt_reservation': {
                'reserved_before_dispatch': bool(
                    reservation.get('reserved_before_dispatch')),
                'consent_id': reservation.get('consent_id'),
            },
            'output_sha256': output_digest,
            'request_sha256': request_digest,
            'response_format': recorded_format,
            'execution': {
                'execution_mode': receipt.execution_mode,
                'model_provider': receipt.model_provider,
                'model_requested': receipt.model_requested,
                'model_returned': receipt.model_returned,
                'run_id': receipt.run_id,
                'attempt_no': receipt.attempt_no,
            },
            'question': candidate.question,
            'response_codes': list(candidate.response_codes),
            'field_authority': field_authority(candidate),
            'dispositions': {
                'structural': structural,
                'semantic': 'UNDER_REVIEW',
                'provenance': 'SOURCE_BOUND',
            },
        })
        return envelope

    def _persist(self, *, candidate_id, assessment_id, confirmation_id,
                 assessment_revision, source_fingerprint, context_id,
                 context_packet_hash, objective_id, admission_id, measurement,
                 authorization_id, prompt_version, prompt_sha256,
                 request_digest, output_digest, response_format, state,
                 structural, candidate_json, receipt: ExecutionReceipt,
                 decision_id=None, objective_kind=None,
                 measurement_basis=None) -> dict:
        from sitewise.repositories.m2_context_bindings import bind_restricted_principal
        from sitewise.services.business_context_v1 import ContextRefused
        with self.engine.begin() as conn:
            try:
                bind_restricted_principal(conn, self.actor_id)
            except ContextRefused as exc:
                raise WorkflowHeld(exc.code) from None
            inserted = conn.execute(text("""
                INSERT INTO public.m2_qg_candidates (
                    candidate_id, assessment_id, confirmation_id,
                    assessment_revision, source_fingerprint, context_id,
                    context_packet_hash, objective_id, objective_admission_id,
                    measurement_id, measurement_version, qg_authorization_id,
                    run_id, attempt_no, prompt_version, prompt_sha256,
                    request_sha256, output_sha256, execution_mode,
                    model_provider, model_requested, model_returned,
                    response_format, candidate_state, structural_status,
                    semantic_status, provenance_status, contract_version,
                    adapter_version, candidate_json, owner_user_id,
                    objective_decision_id, objective_kind, measurement_basis)
                VALUES (
                    :candidate, :assessment, :confirmation, :revision, :source,
                    :context, :context_hash, :objective, :admission,
                    :measurement, :measurement_version, :authorization,
                    :run_id, :attempt_no, :prompt_version, :prompt_sha, :request_sha,
                    :output_sha, :mode, :provider, :model_requested,
                    :model_returned, :format,
                    :state, :structural, 'UNDER_REVIEW', 'SOURCE_BOUND',
                    :contract, :adapter, CAST(:body AS jsonb), :owner,
                    :decision, :kind, :basis)
                ON CONFLICT (candidate_id) DO NOTHING
            """), {
                'candidate': str(candidate_id), 'assessment': str(assessment_id),
                'confirmation': str(confirmation_id),
                'revision': int(assessment_revision),
                'source': source_fingerprint, 'context': str(context_id),
                'context_hash': context_packet_hash, 'objective': objective_id,
                'admission': (None if admission_id is None
                              else str(admission_id)),
                'measurement': measurement['measurement_id'],
                'measurement_version': measurement['measurement_version'],
                'authorization': str(authorization_id),
                'prompt_version': prompt_version, 'prompt_sha': prompt_sha256,
                'request_sha': request_digest, 'output_sha': output_digest,
                # Provenance comes from the receipt, never from a literal. A
                # simulated run and a live run are now distinguishable in the
                # row itself.
                'mode': receipt.execution_mode,
                'provider': receipt.model_provider,
                'model_requested': receipt.model_requested,
                'model_returned': receipt.model_returned,
                'run_id': receipt.run_id, 'attempt_no': receipt.attempt_no,
                'format': response_format,
                'state': state, 'structural': structural,
                'contract': FIXED_OPTION_CONTRACT, 'adapter': ADAPTER_VERSION,
                'body': json.dumps(candidate_json, ensure_ascii=False),
                'owner': str(self.actor_id),
                'decision': (None if decision_id is None else str(decision_id)),
                'kind': objective_kind, 'basis': measurement_basis,
            }).rowcount
        return {'created': inserted == 1}


def read_candidates(engine, *, actor_id, assessment_id, limit: int = 50) -> list[dict]:
    from sitewise.repositories.m2_context_bindings import bind_restricted_principal
    from sitewise.services.business_context_v1 import ContextRefused
    with engine.connect() as conn:
        try:
            bind_restricted_principal(conn, actor_id)
        except ContextRefused as exc:
            raise WorkflowHeld(exc.code) from None
        rows = conn.execute(text("""
            SELECT candidate_id, assessment_id, confirmation_id,
                   assessment_revision, source_fingerprint, context_id,
                   context_packet_hash, objective_id, objective_admission_id,
                   measurement_id, measurement_version, qg_authorization_id,
                   prompt_version, prompt_sha256, request_sha256, output_sha256,
                   execution_mode, model_provider, model_returned,
                   response_format, candidate_state, structural_status,
                   semantic_status, provenance_status, contract_version,
                   adapter_version, owner_user_id, created_at,
                   objective_decision_id, objective_kind, measurement_basis
            FROM public.m2_qg_candidates
            WHERE assessment_id = :a
            ORDER BY created_at DESC, candidate_id
            LIMIT :limit
        """), {'a': str(assessment_id), 'limit': limit}).mappings().all()
    return [dict(row) for row in rows]


__all__ = ['ADAPTER_VERSION', 'ABSTAINED', 'AdapterGates', 'ExecutionReceipt',
           'GENERATED', 'GenerationResult', 'LIVE_PROVIDER', 'LIVE_SCOPE',
           'QgCandidateAdapter', 'SCOPE_EXECUTION_MODE', 'SIMULATED_RECEIPT',
           'SYNTHETIC_SCOPE', 'VALIDATED', 'facts_from_objective',
           'read_candidates']
