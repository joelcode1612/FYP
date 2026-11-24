"""Narrowly scoped synthetic-only disclosure adapter for BDJ and QG attempts.

This is a trusted server-side adapter. It authorizes ONE synthetic, non-human
packet to be sent to the approved provider — either a single BDJ attempt or a
separately identified, research-only QG evaluation — and refuses everything else:

  * real personal data (data_class must be SYNTHETIC_NONHUMAN),
  * any stage other than the one the authorization was issued for (BDJ or QG),
  * any endpoint/model other than the adopted provider/model,
  * any packet whose source_fingerprint does not match the authorization,
  * any packet whose schema is not the authorized schema for that stage,
  * any budget outside the authorized attempt counts,
  * a missing operator receipt.

The two stages cannot stand in for one another: the purpose and schema checks
in ``validate_synthetic`` are bound per stage, so a BDJ authorization never
authorizes a QG packet and vice versa. ``validate_synthetic`` is the single pure
predicate both ``require_current`` ports and preflight delegate to.

It mirrors the style of the existing ``SyntheticPreviewAuthorization`` capability
(frozen dataclass bound to a run) but is stage-specific because neither the BDJ
M2 projection nor the QG confirmed-facts packet carries a CQ synthetic-import
marker. No raw source text or provider payload is stored or logged here.
"""
from dataclasses import dataclass

from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1.provider import ENDPOINT, MODEL

#: research-only purpose for a live QG evaluation. Distinct from the BDJ
#: diagnostic purpose so the two authorizations can never stand in for one
#: another — the purpose check in `validate_synthetic` enforces the separation.
QG_PURPOSE = 'SYNTHETIC_QG_RESEARCH_EVALUATION'
#: Schema a QG packet must carry so a BDJ M2 projection cannot be relabelled as
#: QG input. The schema check in `validate_synthetic` binds this value.
QG_SCHEMA_VERSION = 'project1-qg-confirmed-facts/2-candidate'

#: Research-only purpose for a synthetic Explanation evaluation. Distinct from
#: both the BDJ diagnostic and the QG research purposes, so no authorization for
#: one stage can be presented as authority for another. This matters more here
#: than elsewhere: the Explanation stage sends a *narrative request* rather than
#: a measurement packet, so an inherited BDJ grant would disclose a different
#: class of input entirely.
EXPLANATION_PURPOSE = 'SYNTHETIC_EXPLANATION_DIAGNOSTIC'
#: The schema an Explanation packet must carry. It is the request contract the
#: prompt module builds, so a BDJ projection or a QG facts packet cannot be
#: relabelled into the Explanation stage.
EXPLANATION_SCHEMA_VERSION = 'ee01-explanation-request/1'
#: The prompt version an Explanation authorization may cover. Kept as a literal
#: rather than imported from ``explanation_prompt`` so this module stays free of
#: that dependency; ``test_disclosure_explanation_stage.py`` asserts it equals
#: ``explanation_prompt.PROMPT_VERSION``, so the two cannot drift silently.
EXPLANATION_PROMPT_VERSION = 'EE01-EXPLANATION-2-CAND'


@dataclass(frozen=True)
class SyntheticBdjAuthorization:
    """Explicit operator authorization for exactly one synthetic BDJ attempt."""

    run_id: str
    source_fingerprint: str
    operator_receipt: str
    purpose: str = 'SYNTHETIC_BDJ_DIAGNOSTIC'
    data_class: str = 'SYNTHETIC_NONHUMAN'
    stage: str = 'BDJ'
    endpoint: str = ENDPOINT
    model: str = MODEL
    max_attempts: int = 1
    # Real-data authorisation matched by real_data_authorization.load(). None
    # keeps the synthetic path's fail-closed behaviour unchanged.
    real_authorization: object | None = None
    #: Projection schema this run must present, resolved from the instrument by
    #: ``m2v2_projection.expected_projection_schema``. ``None`` keeps the
    #: historical M2V1 default so every pre-existing caller is unchanged; the BDJ
    #: path always sets it, which is what lets an M2V2 packet pass preflight and
    #: still be re-checked against the same value at dispatch (DD-009).
    expected_schema: str | None = None


@dataclass(frozen=True)
class SyntheticQgAuthorization:
    """Explicit research-only authorization for a synthetic QG evaluation.

    Separately identified from ``SyntheticBdjAuthorization``: a different
    purpose, a different packet schema and its own ``QG`` stage. The extra
    ``contract_version`` field records which QG contract the authorization was
    issued against; it is carried on the authorization, not used as a disclosure
    decision, so ``validate_synthetic`` stays a pure predicate over the same
    fields for both stages.
    """

    run_id: str
    source_fingerprint: str
    operator_receipt: str
    purpose: str = QG_PURPOSE
    data_class: str = 'SYNTHETIC_NONHUMAN'
    stage: str = 'QG'
    endpoint: str = ENDPOINT
    model: str = MODEL
    max_attempts: int = 1
    contract_version: str = 'P1-QG-CONTRACT-2.0'
    # Real-data authorisation, when the caller has matched one against this exact
    # source fingerprint / ruleset hash / prompt hash. None keeps the synthetic
    # path's fail-closed behaviour unchanged.
    real_authorization: object | None = None


class SyntheticBdjDisclosure:
    """Implements the ModelRunner disclosure port: require_current(stage, packet, endpoint, model)."""

    def __init__(self, authorization: SyntheticBdjAuthorization, *, revalidate=None):
        self.authorization = authorization
        #: Optional callable returning the authorization as it is *now*
        #: (``real_data_authorization.load`` partially applied). DD-005 §1.6:
        #: ownership, expiry, source binding and spend state are re-checked
        #: immediately before the reservation, not only at composition time.
        #: ``None`` keeps every synthetic caller unchanged.
        self.revalidate = revalidate

    def spendable_authorization(self):
        """The matched real-data authorization this attempt must spend, if any.

        Returning ``None`` for a synthetic packet is what keeps the historical
        no-consumption path byte for byte identical.
        """
        from sitewise.project1.real_data_authorization import RealDataAuthorization
        bound = getattr(self.authorization, 'real_authorization', None)
        return bound if isinstance(bound, RealDataAuthorization) else None

    def _require_still_current(self):
        """Refuse a stale authorization before the atomic reservation."""
        bound = getattr(self.authorization, 'real_authorization', None)
        if self.revalidate is None or bound is None:
            return
        fresh = self.revalidate()
        # ``None`` means load() no longer matches: the row was spent by a
        # concurrent attempt, expired, or its binding changed. An id mismatch
        # means a different row answered, which is never acceptable here.
        if fresh is None or str(getattr(fresh, 'id', '')) != str(bound.id):
            raise WorkflowHeld('BDJ_AUTHORIZATION_NOT_CURRENT')

    def require_current(self, stage, packet, endpoint, model):
        a = self.authorization
        if not isinstance(a, SyntheticBdjAuthorization):
            raise WorkflowHeld('DISCLOSURE_AUTHORIZATION_INVALID')
        if not a.run_id:
            # Dispatch requires a bound run. The pre-provisioning preflight calls
            # validate_synthetic() directly and never needs one, so an unbound
            # authorization reaching dispatch is a composition error, not a
            # disclosure decision.
            raise WorkflowHeld('DISCLOSURE_AUTHORIZATION_INVALID')
        # Re-check against the SAME schema the preflight used. Omitting this
        # would silently fall back to the M2V1 default at dispatch, so an M2V2
        # packet that passed preflight would still be refused here (or, worse,
        # an M2V1 packet would be accepted under a looser value).
        schema_kwargs = ({'expected_schema': a.expected_schema}
                         if a.expected_schema else {})
        validate_synthetic(
            data_class=a.data_class, purpose=a.purpose, stage=a.stage,
            endpoint=a.endpoint, model=a.model, max_attempts=a.max_attempts,
            operator_receipt=a.operator_receipt,
            source_fingerprint=a.source_fingerprint, packet=packet,
            expected_stage=stage, expected_endpoint=endpoint, expected_model=model,
            real_authorization=getattr(a, 'real_authorization', None),
            **schema_kwargs)
        self._require_still_current()


class RegisteredSyntheticBdjDisclosure:
    """Additional source-bound gate for an isolated BDJ trial.

    `registry` and `current_source` are trusted server-side dependencies; do
    not supply either from HTTP input. The registry must be independently
    protected from writes by the execution principal. A DB row or callback by
    itself is not proof that its owner decision was legitimately recorded.
    The existing disclosure predicate remains mandatory.
    """

    def __init__(self, authorization, *, registry, current_source, owner_id,
                 assessment_id, revision, confirmation_id, rules_sha256,
                 prompt_fingerprint, request_sha256, revalidate=None):
        self.authorization = authorization
        self.registry = registry
        self.current_source = current_source
        #: Forwarded to the inner BDJ port so the DD-005 §1.6 re-check also runs
        #: on the registered path. A wrapper that silently dropped it would be
        #: the one path where a stale authorization could still reach dispatch.
        self.revalidate = revalidate
        self.expected = {
            'run_id': authorization.run_id, 'owner_id': str(owner_id),
            'assessment_id': str(assessment_id), 'revision': revision,
            'confirmation_id': str(confirmation_id),
            'source_fingerprint': authorization.source_fingerprint,
            'endpoint': authorization.endpoint, 'model': authorization.model,
            'rules_sha256': rules_sha256, 'prompt_fingerprint': prompt_fingerprint,
            'request_sha256': request_sha256, 'approval_receipt': authorization.operator_receipt,
            'data_class': 'SYNTHETIC_NONHUMAN', 'decision': 'APPROVED',
            'max_attempts': 1,
        }

    def spendable_authorization(self):
        return SyntheticBdjDisclosure(self.authorization).spendable_authorization()

    def require_current(self, stage, packet, endpoint, model):
        SyntheticBdjDisclosure(self.authorization,
                               revalidate=self.revalidate).require_current(
                                   stage, packet, endpoint, model)
        record = self.registry.get_server_authorization(self.authorization.run_id)
        if not isinstance(record, dict) or any(record.get(k) != v for k, v in self.expected.items()):
            raise WorkflowHeld('DISCLOSURE_REGISTERED_AUTHORIZATION_REQUIRED')
        if (str(packet.get('assessment_id')) != self.expected['assessment_id'] or
                packet.get('assessment_revision') != self.expected['revision'] or
                packet.get('confirmation', {}).get('confirmation_id') != self.expected['confirmation_id']):
            raise WorkflowHeld('DISCLOSURE_ASSESSMENT_BINDING_MISMATCH')
        current = self.current_source()
        if not isinstance(current, dict) or any(current.get(k) != self.expected[k] for k in (
                'owner_id', 'assessment_id', 'revision', 'confirmation_id', 'source_fingerprint')):
            raise WorkflowHeld('DISCLOSURE_CURRENT_SOURCE_REQUIRED')

    def require_request(self, provider, prompt, messages, output_type):
        import hashlib
        import httpx
        if prompt.fingerprint != self.expected['prompt_fingerprint']:
            raise WorkflowHeld('DISCLOSURE_PROMPT_MISMATCH')
        body = httpx.Request('POST', self.expected['endpoint'],
                             json=provider.prepare_payload(messages, output_type)).content
        if hashlib.sha256(body).hexdigest() != self.expected['request_sha256']:
            raise WorkflowHeld('DISCLOSURE_REQUEST_MISMATCH')


@dataclass(frozen=True)
class SyntheticExplanationAuthorization:
    """Explicit research-only authorization for a synthetic Explanation call.

    Separately identified from BDJ and QG by purpose, schema and stage. The
    ``prompt_version`` field records which candidate prompt the authorization was
    issued against, so an approval for one prompt version cannot silently cover
    the next. It is carried on the authorization rather than consulted by
    ``validate_synthetic``, which stays a pure predicate.
    """

    run_id: str
    source_fingerprint: str
    operator_receipt: str
    prompt_version: str
    purpose: str = EXPLANATION_PURPOSE
    data_class: str = 'SYNTHETIC_NONHUMAN'
    stage: str = 'EXPLANATION'
    endpoint: str = ENDPOINT
    model: str = MODEL
    max_attempts: int = 1
    real_authorization: object | None = None


class SyntheticExplanationDisclosure:
    """Explanation-side disclosure port.

    Every disclosure decision is delegated to ``validate_synthetic`` with the
    Explanation stage's own purpose, schema and attempt budget, so preflight and
    dispatch cannot drift apart. A BDJ or QG authorization reaching this port is
    refused on three independent checks (type, stage, purpose), not one.
    """

    def __init__(self, authorization: SyntheticExplanationAuthorization):
        self.authorization = authorization

    def require_current(self, stage, packet, endpoint, model):
        a = self.authorization
        if not isinstance(a, SyntheticExplanationAuthorization):
            raise WorkflowHeld('DISCLOSURE_AUTHORIZATION_INVALID')
        if not a.run_id:
            # Same composition-error rule as the BDJ and QG ports.
            raise WorkflowHeld('DISCLOSURE_AUTHORIZATION_INVALID')
        if stage != 'EXPLANATION' or a.stage != stage:
            raise WorkflowHeld('DISCLOSURE_STAGE_NOT_AUTHORIZED')
        if a.prompt_version != EXPLANATION_PROMPT_VERSION:
            # An authorization for an older prompt cannot authorize a call that
            # would send a different system message.
            raise WorkflowHeld('DISCLOSURE_PROMPT_VERSION_NOT_AUTHORIZED')
        validate_synthetic(
            data_class=a.data_class, purpose=a.purpose, stage=a.stage,
            endpoint=a.endpoint, model=a.model, max_attempts=a.max_attempts,
            operator_receipt=a.operator_receipt,
            source_fingerprint=a.source_fingerprint, packet=packet,
            expected_stage='EXPLANATION', expected_endpoint=endpoint,
            expected_model=model,
            expected_purpose=EXPLANATION_PURPOSE,
            expected_schema=EXPLANATION_SCHEMA_VERSION,
            allowed_max_attempts=(1,))


class SyntheticQgDisclosure:
    """QG-side ModelRunner disclosure port.

    The governing stage is ``QG`` — separately identified from BDJ, never a
    relabelled BDJ attempt. Only the authorization type and its run binding are
    checked here; *every* disclosure decision is delegated to the same
    ``validate_synthetic`` predicate the BDJ path uses, so preflight and dispatch
    cannot drift apart for either stage.
    """

    def __init__(self, authorization: SyntheticQgAuthorization):
        self.authorization = authorization

    def require_current(self, stage, packet, endpoint, model):
        a = self.authorization
        if not isinstance(a, SyntheticQgAuthorization):
            raise WorkflowHeld('DISCLOSURE_AUTHORIZATION_INVALID')
        if not a.run_id:
            # Same composition-error rule as the BDJ port: an unbound
            # authorization reaching dispatch is a wiring mistake, not a
            # disclosure decision. Preflight calls validate_synthetic directly.
            raise WorkflowHeld('DISCLOSURE_AUTHORIZATION_INVALID')
        # Both ends are authoritative: the caller cannot dispatch QG through a
        # BDJ-labelled authorization, nor BDJ through a QG-labelled one. The
        # authorization's stage field must not be decorative.
        if stage != 'QG' or a.stage != stage:
            raise WorkflowHeld('DISCLOSURE_STAGE_NOT_AUTHORIZED')
        validate_synthetic(
            data_class=a.data_class, purpose=a.purpose, stage=a.stage,
            endpoint=a.endpoint, model=a.model, max_attempts=a.max_attempts,
            operator_receipt=a.operator_receipt,
            source_fingerprint=a.source_fingerprint, packet=packet,
            expected_stage='QG', expected_endpoint=endpoint, expected_model=model,
            expected_purpose=QG_PURPOSE, expected_schema=QG_SCHEMA_VERSION,
            allowed_max_attempts=(1, 3))


def validate_synthetic(*, data_class, purpose, stage, endpoint, model, max_attempts,
                       operator_receipt, source_fingerprint, packet,
                       expected_stage='BDJ', expected_endpoint=ENDPOINT,
                       expected_model=MODEL,
                       expected_purpose='SYNTHETIC_BDJ_DIAGNOSTIC',
                       expected_schema='project1-m2-projection/1-candidate',
                       allowed_max_attempts=(1,), real_authorization=None):
    """Every refusal condition, as a pure predicate over fields and the packet.

    Deliberately does **not** consult a run id. All ten conditions are decidable
    from the authorization fields and the packet, so a caller can run this
    *before* provisioning a `project1_ai.runs` row. That ordering is the whole
    point: `runs` is append-only (`deny_mutation()` refuses DELETE), so a refusal
    that happens after provisioning leaves an orphan row no later code can remove.

    `require_current()` delegates here, so dispatch and preflight cannot drift
    apart. Raises `WorkflowHeld` with the same code it always has.

    The three stage-specific values (``expected_purpose``, ``expected_schema``,
    ``allowed_max_attempts``) are optional keyword-only parameters whose defaults
    are exactly the BDJ values, so a BDJ caller that omits them behaves byte for
    byte as before. The QG disclosure supplies its own values. The stage check is
    symmetric — ``stage != expected_stage`` — and the dispatch site passes its
    own stage, so either side moving away from the expected stage is refused.
    """
    if data_class != 'SYNTHETIC_NONHUMAN':
        # Real-data path. Default (real_authorization=None) keeps the historical
        # fail-closed behaviour byte for byte. A caller may only proceed by
        # supplying an authorisation that has already been matched against this
        # exact source fingerprint, ruleset hash and prompt hash.
        if real_authorization is None:
            raise WorkflowHeld('DISCLOSURE_REAL_DATA_NOT_AUTHORIZED')
        # Strict: a bare object must not open the gate. Only a matched row loaded
        # by real_data_authorization.load() is accepted.
        from sitewise.project1.real_data_authorization import RealDataAuthorization
        if not isinstance(real_authorization, RealDataAuthorization):
            raise WorkflowHeld('DISCLOSURE_REAL_DATA_NOT_AUTHORIZED')
    if purpose != expected_purpose:
        raise WorkflowHeld('DISCLOSURE_PURPOSE_MISMATCH')
    if stage != expected_stage:
        raise WorkflowHeld('DISCLOSURE_STAGE_NOT_AUTHORIZED')
    if endpoint != expected_endpoint:
        raise WorkflowHeld('DISCLOSURE_ENDPOINT_MISMATCH')
    if model != expected_model:
        raise WorkflowHeld('DISCLOSURE_MODEL_MISMATCH')
    if max_attempts not in allowed_max_attempts:
        raise WorkflowHeld('DISCLOSURE_BUDGET_INVALID')
    if not operator_receipt or len(operator_receipt) < 8:
        raise WorkflowHeld('DISCLOSURE_RECEIPT_REQUIRED')
    if packet.get('schema_version') != expected_schema:
        raise WorkflowHeld('DISCLOSURE_SOURCE_CLASS_INVALID')
    if source_fingerprint != packet.get('source_fingerprint'):
        raise WorkflowHeld('DISCLOSURE_SOURCE_MISMATCH')


class RegisteredObjectiveDisclosure:
    """Assessment-bound cloud-disclosure gate for the BDJ **objective** route.

    ``ObjectiveSimulationDisclosure`` binds model, endpoint, schema version,
    source fingerprint and context packet hash. That is a *source-binding*
    check. It does not prove that an owner decision authorised **this** source
    to leave the boundary, and a source-binding check alone must never be
    treated as permission to disclose entrepreneur data externally.

    This gate adds exactly that proof and nothing else. It reads an
    operator-provisioned record from the same read-only registry the findings
    trial uses and refuses unless every term of the execution matches it.

    It binds only terms that genuinely exist for the objective contract. The
    findings gate additionally binds ``rules_sha256`` and ``request_sha256``
    because that path loads a rules artefact and hashes the outgoing body; the
    objective route runs ``rules=None`` by design and builds its body from a
    prompt plus packet, so requiring those hashes here would mean inventing a
    binding. ``require_request`` therefore binds the prompt, which is the real
    artefact this route sends.
    """

    STAGE = 'BDJ_OBJECTIVE'
    DATA_CLASS = 'SYNTHETIC_NONHUMAN'

    def __init__(self, *, registry, current_source, owner_id, assessment_id,
                 revision, confirmation_id, source_fingerprint,
                 context_packet_hash, prompt, endpoint, model, consent=None):
        self.registry = registry
        self.current_source = current_source
        #: Optional derived authorization. When present it is the authority for
        #: the terms, and any operator record must agree with it exactly. It
        #: never removes this gate: the consent is still verified, still bound
        #: to the same source, and still refuses without a grant.
        self.consent = consent
        self.expected = {
            'stage': self.STAGE,
            'data_class': self.DATA_CLASS,
            'decision': 'APPROVED',
            'max_attempts': 1,
            'owner_id': str(owner_id),
            'assessment_id': str(assessment_id),
            'revision': revision,
            'confirmation_id': str(confirmation_id),
            'source_fingerprint': source_fingerprint,
            'context_packet_hash': context_packet_hash,
            'prompt_version': prompt.version,
            'prompt_fingerprint': prompt.fingerprint,
            'endpoint': endpoint,
            'model': model,
        }
        self._binding = (str(assessment_id), revision, str(confirmation_id))

    def require_current(self, stage, packet, endpoint, model):
        if stage != 'BDJ':
            raise WorkflowHeld('DISCLOSURE_STAGE_NOT_AUTHORIZED')
        if self.consent is not None:
            # Owner-recorded permission is the authority. Every term is still
            # checked against this execution, so a grant for a different
            # assessment, revision, source, context, prompt or model is useless.
            derived = self.consent.derive()
            for key, value in self.expected.items():
                if derived.get(key) != value:
                    raise WorkflowHeld('DISCLOSURE_REGISTERED_AUTHORIZATION_REQUIRED')
            self._require_binding(packet, endpoint, model)
            # An operator record is still honoured, but only as a *mirror*: if
            # one exists and disagrees with the owner's recorded grant, the
            # disagreement is a refusal rather than a silent override.
            record = None
            try:
                record = self.registry.get_server_authorization(
                    assessment_id=self.expected['assessment_id'],
                    revision=self.expected['revision'],
                    fingerprint=self.expected['source_fingerprint'])
            except WorkflowHeld:
                record = None
            if isinstance(record, dict):
                for key, value in derived.items():
                    if key in record and record[key] != value:
                        raise WorkflowHeld('DISCLOSURE_CONSENT_REGISTRY_CONFLICT')
            current = self.current_source()
            if not isinstance(current, dict) or any(
                    current.get(k) != self.expected[k] for k in
                    ('owner_id', 'assessment_id', 'revision', 'confirmation_id',
                     'source_fingerprint')):
                raise WorkflowHeld('DISCLOSURE_CURRENT_SOURCE_REQUIRED')
            return
        record = self.registry.get_server_authorization(
            assessment_id=self.expected['assessment_id'],
            revision=self.expected['revision'],
            fingerprint=self.expected['source_fingerprint'])
        if not isinstance(record, dict):
            raise WorkflowHeld('DISCLOSURE_REGISTERED_AUTHORIZATION_REQUIRED')
        # Every term must match. A partial match is a different authorisation.
        for key, value in self.expected.items():
            if record.get(key) != value:
                raise WorkflowHeld('DISCLOSURE_REGISTERED_AUTHORIZATION_REQUIRED')
        receipt = record.get('operator_receipt')
        if not isinstance(receipt, str) or len(receipt) < 8:
            raise WorkflowHeld('DISCLOSURE_RECEIPT_REQUIRED')
        self._require_binding(packet, endpoint, model)
        current = self.current_source()
        if not isinstance(current, dict) or any(
                current.get(k) != self.expected[k] for k in
                ('owner_id', 'assessment_id', 'revision', 'confirmation_id',
                 'source_fingerprint')):
            raise WorkflowHeld('DISCLOSURE_CURRENT_SOURCE_REQUIRED')

    def _require_binding(self, packet, endpoint, model):
        """The packet/endpoint/model terms every authorization path must satisfy."""
        if (str(packet.get('assessment_id')),
                packet.get('assessment_revision'),
                str(packet.get('confirmation', {}).get('confirmation_id'))) != self._binding:
            raise WorkflowHeld('DISCLOSURE_ASSESSMENT_BINDING_MISMATCH')
        if endpoint != self.expected['endpoint']:
            raise WorkflowHeld('DISCLOSURE_ENDPOINT_MISMATCH')
        if model != self.expected['model']:
            raise WorkflowHeld('DISCLOSURE_MODEL_MISMATCH')

    def require_request(self, provider, prompt, messages, output_type):
        if prompt.fingerprint != self.expected['prompt_fingerprint']:
            raise WorkflowHeld('DISCLOSURE_PROMPT_MISMATCH')
