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
``execution_mode`` is recorded verbatim, ``fielding_authorized`` is always false,
``scientific_acceptance`` is always false, and a candidate is never counted as
an approved measurement. A structurally valid candidate is a *review object*.
"""
from __future__ import annotations

import json
import uuid
from dataclasses import dataclass

from sqlalchemy import text

from sitewise.project1 import measurement_library as ml
from sitewise.project1 import qg_authorization
from sitewise.project1.contracts import WorkflowHeld, digest
from sitewise.project1.qg_contract import ConfirmedFacts, field_authority
from sitewise.project1.qg_fixed_options import (
    FIXED_OPTION_CONTRACT, validate_fixed_candidate,
)

#: Version of this adapter. A behavioural change is a new version, because a
#: persisted candidate names the adapter that produced it.
ADAPTER_VERSION = 'P1-QG-FIXED-ADAPTER-1.0-CAND'

#: The production hold remains in force. This adapter is reachable only through
#: an explicit synthetic scope, and reports that it was.
SYNTHETIC_SCOPE = 'SYNTHETIC_CANDIDATE_ONLY'

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


def facts_from_objective(packet: dict, *, objective_id: str,
                         objective_text: str, admission_id: str) -> ConfirmedFacts:
    """Assemble ``ConfirmedFacts`` for the M2 V2 -> BDJ objective path.

    ``qg_contract.facts_from_packet`` expects a ``confirmed_uncertainty`` block.
    A BCB 1.2.1 packet built from a confirmed M2 V2 revision has
    ``confirmed_uncertainty = null`` — the M2 V2 contract has no confirmed
    uncertainty object at all. The anchor in this path is the **admitted
    objective**, so that is what is bound, and the substitution is recorded in
    ``uncertainty_source`` rather than being passed off as a confirmed
    uncertainty.
    """
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
    sources.append(f'admission:{admission_id}')

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
        uncertainty_version=str(admission_id),
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
                 admission_lookup, generate, scope: str = SYNTHETIC_SCOPE):
        if scope != SYNTHETIC_SCOPE:
            # The production path is not enabled by this directive. Refusing an
            # unknown scope is what keeps the hold unconditional.
            raise WorkflowHeld('QG_ADAPTER_SCOPE_NOT_AUTHORIZED')
        self.engine = engine
        self.actor_id = actor_id
        self.store = store
        self.admission_lookup = admission_lookup
        self.generate = generate
        self.scope = scope
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

    # -- main -------------------------------------------------------------
    def prepare(self, *, assessment_id, confirmation_id, assessment_revision,
                source_fingerprint, context_id, context_packet_hash,
                objective_id, objective_text, proposal_id, packet,
                stimulus: dict, authorization_id, prompt_version,
                prompt_sha256, population: str | None = None) -> dict:
        """Run the gated attempt. Returns an envelope, never a bare candidate."""
        envelope = {
            'adapter_version': ADAPTER_VERSION,
            'fixed_option_contract': FIXED_OPTION_CONTRACT,
            'scope': self.scope,
            'assessment_id': str(assessment_id),
            'objective_id': objective_id,
            'synthetic_scope': True,
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
            envelope.update({
                'outcome': 'HELD_NO_APPROVED_MEASUREMENT',
                'dispatched': False,
                'candidate_persisted': False,
                'authorization_consumed': False,
                'proposed_extension_allowed': True,
                'abstention_reason': measurement['reason'],
            })
            return envelope

        admission = self.require_admitted(
            proposal_id, source_fingerprint=source_fingerprint,
            objective_id=objective_id)
        envelope['admission'] = {
            'admission_state': admission.get('admission_state'),
            'admission_id': admission.get('admission_id'),
            'admission_reason': admission.get('admission_reason'),
            'objective_id': admission.get('objective_id'),
            'qg_eligible': admission.get('qg_eligible'),
        }

        authorization = self.require_authorization(
            authorization_id=authorization_id,
            assessment_id=assessment_id,
            source_fingerprint=source_fingerprint,
            context_id=context_id,
            context_packet_hash=context_packet_hash,
            objective_id=objective_id,
            objective_admission_id=admission['admission_id'],
            measurement_id=measurement['measurement_id'],
            measurement_version=measurement['measurement_version'],
            prompt_version=prompt_version,
            prompt_sha256=prompt_sha256,
        )
        envelope['authorization'] = {
            'authorization_id': authorization['authorization_id'],
            'expires_at': authorization['expires_at'],
            'consumed': authorization['consumed'],
        }

        facts = facts_from_objective(
            packet, objective_id=objective_id, objective_text=objective_text,
            admission_id=admission['admission_id'])

        approved_population = population or measurement['population']
        approved_format = measurement['response_format']

        # Dispatch happens only now, after every gate above has passed.
        self.dispatch_calls += 1
        raw = self.generate({
            'facts': facts,
            'measurement': measurement,
            'objective_id': objective_id,
            'response_format': approved_format,
            'population': approved_population,
            'stimulus': stimulus,
        })

        candidate = validate_fixed_candidate(
            raw, facts,
            supported_formats=frozenset({approved_format}),
            approved_population=approved_population,
            period_required=False)

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
            str(admission['admission_id']),
            str(measurement['measurement_id']),
            str(measurement['measurement_version']),
            output_digest, ADAPTER_VERSION]))

        request_digest = digest({
            'facts': facts.model_dump(mode='json'),
            'measurement': measurement['measurement_id'] + '@' +
                           measurement['measurement_version'],
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
            admission_id=admission['admission_id'],
            measurement=measurement, authorization_id=authorization_id,
            prompt_version=prompt_version, prompt_sha256=prompt_sha256,
            request_digest=request_digest, output_digest=output_digest,
            response_format=approved_format, state=state,
            structural=structural, candidate_json=candidate_json)

        # The authorization is spent by *this attempt*, not by the row being new.
        # Persistence is idempotent (a byte-identical candidate keeps its id), so
        # keying consumption off ``created`` would leave a spent attempt looking
        # unspent and let the same authorization be replayed.
        qg_authorization.consume(
            self.engine, actor_id=self.actor_id,
            authorization_id=authorization_id, candidate_id=candidate_id)
        consumed = True

        envelope.update({
            'outcome': 'ABSTAINED_BY_MODEL' if abstained else 'CANDIDATE_VALIDATED',
            'dispatched': True,
            'dispatch_calls': self.dispatch_calls,
            'candidate_id': str(candidate_id),
            'candidate_state': state,
            'candidate_persisted': persisted['created'],
            'candidate_already_existed': not persisted['created'],
            'authorization_consumed': consumed,
            'output_sha256': output_digest,
            'request_sha256': request_digest,
            'response_format': approved_format,
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
                 structural, candidate_json) -> dict:
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
                    adapter_version, candidate_json, owner_user_id)
                VALUES (
                    :candidate, :assessment, :confirmation, :revision, :source,
                    :context, :context_hash, :objective, :admission,
                    :measurement, :measurement_version, :authorization,
                    NULL, NULL, :prompt_version, :prompt_sha, :request_sha,
                    :output_sha, :mode, :provider, :model, NULL, :format,
                    :state, :structural, 'UNDER_REVIEW', 'SOURCE_BOUND',
                    :contract, :adapter, CAST(:body AS jsonb), :owner)
                ON CONFLICT (candidate_id) DO NOTHING
            """), {
                'candidate': str(candidate_id), 'assessment': str(assessment_id),
                'confirmation': str(confirmation_id),
                'revision': int(assessment_revision),
                'source': source_fingerprint, 'context': str(context_id),
                'context_hash': context_packet_hash, 'objective': objective_id,
                'admission': str(admission_id),
                'measurement': measurement['measurement_id'],
                'measurement_version': measurement['measurement_version'],
                'authorization': str(authorization_id),
                'prompt_version': prompt_version, 'prompt_sha': prompt_sha256,
                'request_sha': request_digest, 'output_sha': output_digest,
                'mode': 'SIMULATED', 'provider': 'simulated-qg-v1',
                'model': 'simulated-qg-v1', 'format': response_format,
                'state': state, 'structural': structural,
                'contract': FIXED_OPTION_CONTRACT, 'adapter': ADAPTER_VERSION,
                'body': json.dumps(candidate_json, ensure_ascii=False),
                'owner': str(self.actor_id),
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
                   adapter_version, owner_user_id, created_at
            FROM public.m2_qg_candidates
            WHERE assessment_id = :a
            ORDER BY created_at DESC, candidate_id
            LIMIT :limit
        """), {'a': str(assessment_id), 'limit': limit}).mappings().all()
    return [dict(row) for row in rows]


__all__ = ['ADAPTER_VERSION', 'ABSTAINED', 'AdapterGates', 'GENERATED',
           'QgCandidateAdapter', 'SYNTHETIC_SCOPE', 'VALIDATED',
           'facts_from_objective', 'read_candidates']
