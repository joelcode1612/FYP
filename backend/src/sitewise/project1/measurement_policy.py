"""Versioned measurement policy: the real replacement for a no-op authority.

Two findings drove this module.

**F-01** — ``Measurement.uncertainty_version`` is a required field, but nothing in
the QJ prompt told the model what value to produce. The only candidate was
``packet['confirmed_uncertainty']['id']``, so the survey branch was reachable
only by guessing. ``resolve_uncertainty_version`` makes the value server-authored
and source-bound: it is derived from the hash-verified BCB packet, never from the
model's output, and ``admit_qj`` returns it so the workflow can place it in the
QJ input verbatim.

**F-02** — every ``authority.validate_measurement`` in the tree was
``lambda *_: None``. A measurement was therefore "validated" by nobody. This
module implements a real, deterministic, versioned validator that compares a
candidate against an explicit policy document. It issues **no** scientific
acceptance, bank authorisation, publication right or fielding right, and the
status it returns says so.

Two kinds of check, deliberately separated
------------------------------------------
* **Invariants** hold for *any* admissible measurement, so they apply to a
  model-authored QJ candidate: the version label must be the resolved one, no
  geography inference, every response code routed, codes and labels the same
  length and distinct, the denominator built only from declared codes, every
  source reference entailed by the packet, limitations non-empty, no prohibited
  claim asserted.
* **Pinned** constraints belong to one specific authorised instrument: the exact
  construct, population, timeframe, stimulus tokens and price, the exact response
  coding, the exact denominator wording. A model cannot satisfy a pinned document
  it was never shown, so pinned checks apply only where the measurement is frozen
  or server-compiled — the QG path and the lab instrument.

Conflating the two was the first draft's error: a fully pinned document makes
every model-authored candidate fail for reasons unrelated to the model's
competence, which is a validator that reports nothing.

What this module deliberately is not
------------------------------------
* Not an approval. ``validate`` returns ``TEST_SCOPED_VALID`` only, with
  ``scientific_accepted=False`` and ``production_eligible=False``.
* Not a bank. Equivalence and no-equivalence receipts belong to BD-01/BD-02.
* Not self-authorising. ``authorization_status`` is a property of the policy
  document, and no code path in this module can promote it.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

from sitewise.project1.contracts import WorkflowHeld, digest

#: Version of the *resolution rule* (not of any measurement).
UNCERTAINTY_VERSION_RULE = 'F01-UNCERTAINTY-ID-1.0'
#: Rule used when a deployment cannot prove id immutability. Kept named so a
#: reviewer can see which rule produced a stored value.
UNCERTAINTY_VERSION_RULE_COMPOSITE = 'F01-COMPOSITE-ID-REVISION-TEXT-1.0'

AUTHORIZED = 'AUTHORIZED'
TEST_SCOPED_NOT_AUTHORIZED = 'TEST_SCOPED_NOT_AUTHORIZED'

_CURRENCY = re.compile(r'RM\s?\d+(?:\.\d+)?', re.I)
_CODE = re.compile(r'^[A-Z][A-Z0-9_]{0,63}$')

#: Claims a measurement may never assert. These are prohibitions, not preferences:
#: each one would convert a stated preference into a demand, sales or viability
#: finding the instrument cannot support.
PROHIBITED_CLAIM_PATTERNS = (
    (r'\boptimum price\b', 'PROHIBITED_OPTIMUM_PRICE'),
    (r'\boptimal price\b', 'PROHIBITED_OPTIMUM_PRICE'),
    (r'\bwill (?:definitely )?purchase\b', 'PROHIBITED_PURCHASE_PREDICTION'),
    (r'\bforecast\b', 'PROHIBITED_FORECAST'),
    (r'\bwillingness[- ]to[- ]pay\b', 'PROHIBITED_WTP_CLAIM'),
    (r'\bprofitab', 'PROHIBITED_VIABILITY_CLAIM'),
    (r'\bviab(?:le|ility)\b', 'PROHIBITED_VIABILITY_CLAIM'),
    (r'\bdemand\b', 'PROHIBITED_DEMAND_CLAIM'),
    (r'\bmarket share\b', 'PROHIBITED_DEMAND_CLAIM'),
)


@dataclass(frozen=True)
class UncertaintyVersion:
    """A resolved, server-authored version label plus its provenance.

    ``value`` is what the model must echo. Everything else exists so an auditor
    can see *why* that string is the version, rather than trusting a bare uuid.
    """

    value: str
    basis: str
    rule: str
    uncertainty_id: str
    confirmation_id: str
    assessment_revision: int
    exact_text_digest: str
    packet_hash: str | None

    def provenance(self) -> dict:
        return {'value': self.value, 'basis': self.basis, 'rule': self.rule,
                'uncertainty_id': self.uncertainty_id,
                'confirmation_id': self.confirmation_id,
                'assessment_revision': self.assessment_revision,
                'exact_text_digest': self.exact_text_digest,
                'packet_hash': self.packet_hash}


def resolve_uncertainty_version(packet: dict) -> UncertaintyVersion:
    """Derive the uncertainty version from the packet, never from the model.

    Why the id is admissible as a version label (see F-01 evidence record):

    * ``public.m2_confirmed_uncertainties.id`` is ``PRIMARY KEY`` — unique.
    * The table carries the ``m2_bcb_append_only`` trigger (``BEFORE UPDATE OR
      DELETE``) created by ``migrations/m2/20261113_01_confirmed_context_persistence.sql``,
      so a stored row can never be rewritten in place.
    * A revision mints a *new* row: ``m2_research_revisions(parent_id, child_id)``
      links a new objective to its parent, and ``child_id`` is a distinct
      ``m2_confirmed_uncertainties`` row with its own id.
    * The packet builder refuses an uncertainty whose ``confirmation_id`` does not
      match the confirmation it is presented with
      (``business_context_v1.py`` "UNCERTAINTY_UNCONFIRMED"), and
      ``m2_confirmation_snapshots`` is ``UNIQUE (assessment_id, assessment_revision)``.

    Therefore one id denotes exactly one (confirmation, revision, text) triple.

    **The converse does not hold, and that is deliberate.** ``revise_objective``
    with ``CLARIFY`` mints a new child id even when the objective text is
    unchanged, so two ids may carry identical text. That direction is required,
    not tolerated: a version labels a *confirmation event*, and a re-confirmation
    is a new event whose ancestry and provenance differ. A text-derived label
    would collide across those events and make the ancestry walk in
    ``ResearchWorkflow.execute_objective`` ambiguous. So the rule is
    "same id implies same version", never "same text implies same version".

    Qualification recorded from the F-01 review: immutability rests entirely on
    the ``m2_bcb_append_only`` trigger. ``p1_m2_runtime`` does hold an ``UPDATE``
    grant on this table and the table is not ``FORCE ROW LEVEL SECURITY``, so a
    role that could drop or disable the trigger could rewrite a row. The trigger
    is the mechanism; it is not additionally defended.
    """
    confirmation = packet.get('confirmation') or {}
    uncertainty = packet.get('confirmed_uncertainty') or {}
    if confirmation.get('status') != 'CURRENT_CONFIRMED':
        raise WorkflowHeld('F01_CONFIRMATION_NOT_CURRENT')
    uncertainty_id = uncertainty.get('id')
    confirmation_id = confirmation.get('id')
    revision = confirmation.get('revision')
    exact_text = uncertainty.get('exact_text')
    if not uncertainty_id or not confirmation_id or revision is None:
        raise WorkflowHeld('F01_UNCERTAINTY_IDENTITY_INCOMPLETE')
    if uncertainty.get('confirmation_id') != confirmation_id:
        raise WorkflowHeld('F01_UNCERTAINTY_CONFIRMATION_MISMATCH')
    if not isinstance(exact_text, str) or not exact_text.strip():
        raise WorkflowHeld('F01_UNCERTAINTY_TEXT_MISSING')
    try:
        revision_no = int(revision)
    except (TypeError, ValueError):
        raise WorkflowHeld('F01_UNCERTAINTY_IDENTITY_INCOMPLETE') from None
    if revision_no < 0:
        raise WorkflowHeld('F01_UNCERTAINTY_IDENTITY_INCOMPLETE')
    return UncertaintyVersion(
        value=str(uncertainty_id),
        basis='confirmed_uncertainty.id',
        rule=UNCERTAINTY_VERSION_RULE,
        uncertainty_id=str(uncertainty_id),
        confirmation_id=str(confirmation_id),
        assessment_revision=revision_no,
        exact_text_digest=digest(exact_text),
        packet_hash=packet.get('packet_hash'),
    )


def composite_uncertainty_version(packet: dict) -> UncertaintyVersion:
    """Fallback rule for deployments that cannot prove id immutability.

    Binds the label to the confirmation, the revision and the text digest, so a
    reused id or an in-place text edit still changes the version. Not the default,
    because a longer label is harder for a model to echo verbatim and the id rule
    is already proved for this schema.
    """
    resolved = resolve_uncertainty_version(packet)
    return UncertaintyVersion(
        value=(f"{resolved.uncertainty_id}@{resolved.assessment_revision}:"
               f"{resolved.exact_text_digest[:12]}"),
        basis='confirmed_uncertainty.id@confirmation.revision:exact_text_digest',
        rule=UNCERTAINTY_VERSION_RULE_COMPOSITE,
        uncertainty_id=resolved.uncertainty_id,
        confirmation_id=resolved.confirmation_id,
        assessment_revision=resolved.assessment_revision,
        exact_text_digest=resolved.exact_text_digest,
        packet_hash=resolved.packet_hash,
    )


@dataclass(frozen=True)
class MeasurementPolicyDocument:
    """The admissible shape of a measurement. Data, not code.

    A policy document is what a scientific reviewer signs. Keeping the values in
    a document (rather than literals inside ``validate``) means the price, the
    population and the response coding are reviewable and hashable, and that
    changing any of them changes ``policy_digest``.

    Every ``pinned_*`` field is ``None`` when the document does not constrain it.
    ``None`` means "not pinned", never "no constraint": the invariants always run.
    """

    policy_version: str
    authorization_status: str
    scope: str = 'INVARIANTS_ONLY'
    pinned_construct: str | None = None
    pinned_population: str | None = None
    pinned_timeframe: str | None = None
    pinned_stimulus_tokens: tuple[str, ...] | None = None
    pinned_currency_tokens: frozenset[str] | None = None
    pinned_response_codes: tuple[str, ...] | None = None
    pinned_response_labels: tuple[str, ...] | None = None
    pinned_routing: dict[str, str] | None = None
    pinned_denominator_tokens: tuple[str, ...] | None = None
    limitations_min_length: int = 20
    source_ref_policy: str = 'ENTAILED_BY_PACKET'
    extra: dict = field(default_factory=dict)

    @property
    def production_eligible(self) -> bool:
        return self.authorization_status == AUTHORIZED

    @property
    def pinned(self) -> bool:
        return self.scope == 'PINNED_INSTRUMENT'

    @property
    def policy_digest(self) -> str:
        return digest({
            'policy_version': self.policy_version,
            'authorization_status': self.authorization_status,
            'scope': self.scope,
            'pinned_construct': self.pinned_construct,
            'pinned_population': self.pinned_population,
            'pinned_timeframe': self.pinned_timeframe,
            'pinned_stimulus_tokens': (list(self.pinned_stimulus_tokens)
                                       if self.pinned_stimulus_tokens else None),
            'pinned_currency_tokens': (sorted(self.pinned_currency_tokens)
                                       if self.pinned_currency_tokens else None),
            'pinned_response_codes': (list(self.pinned_response_codes)
                                      if self.pinned_response_codes else None),
            'pinned_response_labels': (list(self.pinned_response_labels)
                                       if self.pinned_response_labels else None),
            'pinned_routing': self.pinned_routing,
            'pinned_denominator_tokens': (list(self.pinned_denominator_tokens)
                                          if self.pinned_denominator_tokens else None),
            'limitations_min_length': self.limitations_min_length,
            'source_ref_policy': self.source_ref_policy})

    # -- checks ----------------------------------------------------------
    def _entailed_refs(self, packet: dict, resolved: UncertaintyVersion) -> set[str]:
        refs = {a['answer_revision_id'] for a in packet.get('m2_answers') or []}
        refs |= {s['id'] + '@' + s['version']
                 for s in packet.get('supporting_sources') or []}
        refs.add(resolved.uncertainty_id)
        return refs

    def _invariants(self, measurement: dict, packet: dict,
                    resolved: UncertaintyVersion) -> None:
        if measurement.get('uncertainty_version') != resolved.value:
            raise WorkflowHeld('F02_UNCERTAINTY_VERSION_MISMATCH')
        if packet.get('geography') is not None:
            raise WorkflowHeld('F02_GEO_NOT_EXCLUDED')
        for key in ('construct', 'population', 'timeframe', 'stimulus',
                    'denominator', 'limitations'):
            value = measurement.get(key)
            if not isinstance(value, str) or not value.strip():
                raise WorkflowHeld('F02_MEASUREMENT_INCOMPLETE')

        codes = measurement.get('response_codes')
        labels = measurement.get('response_options')
        routing = measurement.get('routing')
        if (not isinstance(codes, list) or not isinstance(labels, list)
                or not isinstance(routing, dict)):
            raise WorkflowHeld('F02_RESPONSE_CODING_DRIFT')
        if len(codes) != len(labels) or len(codes) < 2:
            raise WorkflowHeld('F02_RESPONSE_CODING_DRIFT')
        if len(set(codes)) != len(codes) or len(set(labels)) != len(labels):
            raise WorkflowHeld('F02_RESPONSE_CODING_DRIFT')
        if any(not isinstance(c, str) or not _CODE.match(c) for c in codes):
            raise WorkflowHeld('F02_RESPONSE_CODING_DRIFT')
        if any(not isinstance(v, str) or not v.strip() for v in labels):
            raise WorkflowHeld('F02_RESPONSE_LABEL_DRIFT')
        # Every declared code must be routed, and no routing key may be undeclared.
        if set(routing) != set(codes):
            raise WorkflowHeld('F02_ROUTING_DRIFT')
        if any(not isinstance(v, str) or not v.strip() for v in routing.values()):
            raise WorkflowHeld('F02_ROUTING_DRIFT')

        # The denominator must be built from declared codes, so a share cannot be
        # computed over a population the instrument never defined.
        denominator = measurement['denominator']
        if not any(code in denominator for code in codes):
            raise WorkflowHeld('F02_DENOMINATOR_DRIFT')

        if len(measurement['limitations'].strip()) < self.limitations_min_length:
            raise WorkflowHeld('F02_LIMITATIONS_INCOMPLETE')
        # Claims are scanned in the fields that state the estimand, never in
        # `limitations`. A disclaimer has to be able to name the inference it
        # excludes ("not a purchase forecast"), so scanning it would refuse every
        # honest limitation and reward a vague one. The estimand fields are where
        # an unsupported claim would actually change what the instrument measures.
        claim_text = ' '.join((measurement['construct'], measurement['population'],
                               measurement['stimulus'],
                               measurement['denominator'])).casefold()
        for pattern, code in PROHIBITED_CLAIM_PATTERNS:
            if re.search(pattern, claim_text):
                raise WorkflowHeld(code)

        refs = measurement.get('source_refs')
        if (not isinstance(refs, list) or not refs
                or any(not isinstance(r, str) or not r.strip() for r in refs)):
            raise WorkflowHeld('F02_SOURCE_REFS_INVALID')
        if len(set(refs)) != len(refs):
            raise WorkflowHeld('F02_SOURCE_REFS_INVALID')
        entailed = self._entailed_refs(packet, resolved)
        if not set(refs) <= entailed:
            raise WorkflowHeld('F02_SOURCE_NOT_BOUND_TO_PACKET')
        if self.source_ref_policy == 'CONFIRMED_UNCERTAINTY_ONLY':
            if refs != [resolved.uncertainty_id]:
                raise WorkflowHeld('F02_SOURCE_REFS_NOT_ENTAILED')

        # A correct version label does not prove the measurement is *about* the
        # confirmed uncertainty. Every currency amount the instrument puts in front
        # of a respondent must already appear in the confirmed uncertainty text, so
        # a candidate cannot measure a price the entrepreneur never confirmed. This
        # is the D-01 failure at the QJ boundary: the label and the offer are two
        # separate claims and both have to be bound to the packet.
        uncertainty_text = (packet.get('confirmed_uncertainty') or {}).get('exact_text') or ''
        offered = {m.group(0).replace(' ', '').upper()
                   for m in _CURRENCY.finditer(measurement['stimulus'])}
        confirmed = {m.group(0).replace(' ', '').upper()
                     for m in _CURRENCY.finditer(uncertainty_text)}
        if offered and not offered <= confirmed:
            raise WorkflowHeld('F02_STIMULUS_NOT_SUPPORTED_BY_UNCERTAINTY')

    def _pinned_checks(self, measurement: dict) -> None:
        if not self.pinned:
            return
        if self.pinned_construct is not None and measurement['construct'] != self.pinned_construct:
            raise WorkflowHeld('F02_CONSTRUCT_DRIFT')
        if self.pinned_population is not None and measurement['population'] != self.pinned_population:
            raise WorkflowHeld('F02_POPULATION_UNAUTHORIZED')
        if self.pinned_timeframe is not None and measurement['timeframe'] != self.pinned_timeframe:
            raise WorkflowHeld('F02_TIMEFRAME_DRIFT')

        stimulus = measurement['stimulus']
        for token in self.pinned_stimulus_tokens or ():
            if token.casefold() not in stimulus.casefold():
                raise WorkflowHeld('F02_STIMULUS_DRIFT')
        if self.pinned_currency_tokens is not None:
            # D-01 lesson: a substring test cannot protect the price, because
            # "12 oz" already contains the digits of a substituted price. Currency
            # amounts are compared as whole tokens and the set must match exactly.
            amounts = {m.group(0).replace(' ', '').upper()
                       for m in _CURRENCY.finditer(stimulus)}
            if amounts != set(self.pinned_currency_tokens):
                raise WorkflowHeld('F02_STIMULUS_PRICE_DRIFT')

        if (self.pinned_response_codes is not None
                and measurement['response_codes'] != list(self.pinned_response_codes)):
            raise WorkflowHeld('F02_RESPONSE_CODING_DRIFT')
        if (self.pinned_response_labels is not None
                and measurement['response_options'] != list(self.pinned_response_labels)):
            raise WorkflowHeld('F02_RESPONSE_LABEL_DRIFT')
        if self.pinned_routing is not None and measurement['routing'] != self.pinned_routing:
            raise WorkflowHeld('F02_ROUTING_DRIFT')
        for token in self.pinned_denominator_tokens or ():
            if token not in measurement['denominator']:
                raise WorkflowHeld('F02_DENOMINATOR_DRIFT')

    def validate(self, measurement: dict, packet: dict,
                 resolved: UncertaintyVersion) -> dict:
        """Compare a candidate against this document. Raises on any violation."""
        self._invariants(measurement, packet, resolved)
        self._pinned_checks(measurement)
        body = {'status': 'TEST_SCOPED_VALID',
                'policy_version': self.policy_version,
                'policy_scope': self.scope,
                'policy_digest': self.policy_digest,
                'authorization_status': self.authorization_status,
                'measurement_digest': digest(measurement),
                'uncertainty_version': resolved.value,
                'bcb_packet_hash': resolved.packet_hash,
                'scientific_accepted': False,
                'fielding_authorized': False,
                'production_eligible': False}
        # The receipt identifies itself so a later reader can tell a genuine
        # receipt from a dict that merely looks like one. See verify_validation_receipt.
        body['receipt_id'] = digest(body)
        return body


#: Invariant-only document. This is what a model-authored QJ candidate is judged
#: against: it constrains the structure and the entailment of the measurement, and
#: deliberately does not pretend to know which population the model should choose.
QJ_INVARIANTS_POLICY = MeasurementPolicyDocument(
    policy_version='QJ-MEASUREMENT-INVARIANTS-0.1',
    authorization_status=TEST_SCOPED_NOT_AUTHORIZED,
    scope='INVARIANTS_ONLY',
    source_ref_policy='ENTAILED_BY_PACKET',
)

#: The lab instrument, fully pinned. TEST ONLY: the population is fictional, the
#: sample frame is unauthorised and no fielding right exists. It exists so the
#: frozen-measurement and QG paths are checked against a real rule set, and so the
#: RM13-not-RM12 fidelity requirement has an executable meaning.
#:
#: Every value here is copied from the P1 provisional baseline
#: (``tests/m2_bcb/lab_measurement_v0_1.py::canonical_spec``) rather than invented.
#: ``test_measurement_policy.test_lab_policy_matches_the_provisional_baseline``
#: asserts the two agree field by field, so the two documents cannot drift apart
#: silently while both claim to describe one instrument.
LAB_PRICE_RM13_POLICY = MeasurementPolicyDocument(
    policy_version='MEASUREMENT-LAB-POLICY-0.1',
    authorization_status=TEST_SCOPED_NOT_AUTHORIZED,
    scope='PINNED_INSTRUMENT',
    pinned_construct=('Hypothetical stated acceptability of RM13 for an exactly described '
                      '12 oz takeaway iced latte'),
    pinned_population=('Synthetic eligible respondents flagged synthetic_eligibility=true '
                       'in a disposable test cluster; no real sampling frame is authorized'),
    pinned_timeframe=('Judgment at the moment the respondent views the hypothetical offer; '
                      'no future purchase window is inferred'),
    pinned_stimulus_tokens=('12 oz', 'takeaway', 'iced latte'),
    pinned_currency_tokens=frozenset({'RM13'}),
    pinned_response_codes=('ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW', 'REFUSED'),
    pinned_response_labels=('Acceptable', 'Not acceptable', "Don't know",
                            'Prefer not to answer'),
    pinned_routing={code: 'END'
                    for code in ('ACCEPTABLE', 'NOT_ACCEPTABLE', 'DONT_KNOW', 'REFUSED')},
    pinned_denominator_tokens=('ACCEPTABLE', 'NOT_ACCEPTABLE'),
    source_ref_policy='CONFIRMED_UNCERTAINTY_ONLY',
)

POLICIES = {document.policy_version: document
            for document in (QJ_INVARIANTS_POLICY, LAB_PRICE_RM13_POLICY)}


def verify_validation_receipt(receipt, measurement: dict, packet: dict,
                              registry: dict | None = None) -> dict:
    """Independently verify a measurement-validation receipt.

    Why this exists: an authority exposing ``measurement_policy_version`` proves
    only that it has an attribute. It does not prove the policy ran, that it ran
    against *this* measurement, or that the answer was not edited afterwards. The
    workflow therefore does not trust the receipt's claims — it re-derives every
    one of them from the server-side registry and the live objects.

    Checked, each with its own refusal code:

    * a receipt is present at all — ``MEASUREMENT_RECEIPT_MISSING``
    * its policy version is a document this server actually registers —
      ``MEASUREMENT_RECEIPT_UNKNOWN_POLICY``
    * its policy digest is that document's digest —
      ``MEASUREMENT_RECEIPT_POLICY_DIGEST_MISMATCH``
    * it describes this measurement — ``MEASUREMENT_RECEIPT_MEASUREMENT_MISMATCH``
    * it describes this packet — ``MEASUREMENT_RECEIPT_CONTEXT_MISMATCH``
    * it names this uncertainty version — ``MEASUREMENT_RECEIPT_VERSION_MISMATCH``
    * its own id still hashes to its body — ``MEASUREMENT_RECEIPT_TAMPERED``
    * its status is the test-scoped one — ``MEASUREMENT_RECEIPT_STATUS_INVALID``
    * it has not been upgraded to claim acceptance —
      ``MEASUREMENT_RECEIPT_AUTHORITY_ESCALATION``

    A no-op authority returns ``None`` and is refused by the first check. A
    fabricated authority can copy a policy version but cannot produce the
    registered document's digest, so the second and third checks close that route.
    """
    documents = POLICIES if registry is None else registry
    if not isinstance(receipt, dict):
        raise WorkflowHeld('MEASUREMENT_RECEIPT_MISSING')
    policy_version = receipt.get('policy_version')
    document = documents.get(policy_version)
    if document is None:
        raise WorkflowHeld('MEASUREMENT_RECEIPT_UNKNOWN_POLICY')
    if receipt.get('policy_digest') != document.policy_digest:
        raise WorkflowHeld('MEASUREMENT_RECEIPT_POLICY_DIGEST_MISMATCH')
    if receipt.get('measurement_digest') != digest(measurement):
        raise WorkflowHeld('MEASUREMENT_RECEIPT_MEASUREMENT_MISMATCH')
    if receipt.get('bcb_packet_hash') != packet.get('packet_hash'):
        raise WorkflowHeld('MEASUREMENT_RECEIPT_CONTEXT_MISMATCH')
    resolved = resolve_uncertainty_version(packet)
    if receipt.get('uncertainty_version') != resolved.value:
        raise WorkflowHeld('MEASUREMENT_RECEIPT_VERSION_MISMATCH')
    body = {k: v for k, v in receipt.items() if k != 'receipt_id'}
    if receipt.get('receipt_id') != digest(body):
        raise WorkflowHeld('MEASUREMENT_RECEIPT_TAMPERED')
    if receipt.get('status') != 'TEST_SCOPED_VALID':
        raise WorkflowHeld('MEASUREMENT_RECEIPT_STATUS_INVALID')
    if (receipt.get('scientific_accepted') is not False
            or receipt.get('fielding_authorized') is not False
            or receipt.get('production_eligible') is not False):
        raise WorkflowHeld('MEASUREMENT_RECEIPT_AUTHORITY_ESCALATION')
    return receipt


class MeasurementAuthority:
    """A real authority port for ``ResearchWorkflow``.

    Duck-typed to the four methods the workflow calls. The presence of
    ``measurement_policy_version`` is what distinguishes this from a harness
    double; ``research.py`` refuses to dispatch QG drafting without it.
    """

    def __init__(self, document: MeasurementPolicyDocument, *, lab_scope_record: str,
                 production_requested: bool = False):
        if not document:
            raise WorkflowHeld('F02_POLICY_DOCUMENT_REQUIRED')
        if not isinstance(lab_scope_record, str) or not lab_scope_record.strip():
            raise WorkflowHeld('F02_TEST_SCOPE_NOT_AUTHORIZED')
        if production_requested and not document.production_eligible:
            # The honest outcome: this document is lab-scoped, so a production
            # request is refused rather than silently downgraded.
            raise WorkflowHeld('F02_POLICY_NOT_AUTHORIZED')
        self.document = document
        self.lab_scope_record = lab_scope_record.strip()
        self.production_requested = production_requested
        self.measurement_policy_version = document.policy_version
        self.authorization_status = document.authorization_status
        self._admitted: dict | None = None

    # -- port ------------------------------------------------------------
    def resolve_version(self, packet: dict) -> dict:
        """Resolve the version task for a path that does not execute QJ.

        Same provenance and same packet integrity as ``admit_qj``, but the
        ``qj_execution`` permission assertion is deliberately absent. That field
        asks whether *QJ* may run against this context; the direct BCB -> QG path
        never runs QJ, so making it depend on a QJ grant would keep the retired
        stage alive as a hidden precondition. The field is read only by
        ``admit_qj``, which the legacy path still uses.
        """
        resolved = resolve_uncertainty_version(packet)
        if packet.get('geography') is not None:
            raise WorkflowHeld('F02_GEO_NOT_EXCLUDED')
        task = {'uncertainty_version': resolved.value,
                'uncertainty_version_basis': resolved.basis,
                'uncertainty_version_rule': resolved.rule,
                'uncertainty_version_source': resolved.provenance(),
                'policy_version': self.document.policy_version,
                'policy_digest': self.document.policy_digest,
                'authorization_status': self.document.authorization_status,
                'qj_scope': 'SYNTHETIC_LAB_ONLY',
                'production_eligible': False}
        self._admitted = task
        return task

    def admit_qj(self, packet: dict) -> dict:
        """Legacy QJ admission: version resolution plus the QJ permission check."""
        permissions = packet.get('permissions')
        if isinstance(permissions, dict) and permissions.get('qj_execution') is not False:
            # A packet may not assert QJ authority. False is the only admissible
            # value; anything else is a packet granting itself a right.
            raise WorkflowHeld('F01_PACKET_ASSERTS_QJ_AUTHORITY')
        return self.resolve_version(packet)

    def require_current(self, packet: dict, task: dict) -> None:
        """Re-resolve after the model call. A changed context invalidates the task."""
        resolved = resolve_uncertainty_version(packet)
        if resolved.value != task.get('uncertainty_version'):
            raise WorkflowHeld('F01_CONTEXT_CHANGED_SINCE_ADMISSION')
        admitted_hash = (task.get('uncertainty_version_source') or {}).get('packet_hash')
        if resolved.packet_hash != admitted_hash:
            raise WorkflowHeld('F01_CONTEXT_CHANGED_SINCE_ADMISSION')

    def validate_measurement(self, packet: dict, task: dict, measurement: dict) -> dict:
        resolved = resolve_uncertainty_version(packet)
        if task.get('uncertainty_version') != resolved.value:
            raise WorkflowHeld('F01_ADMISSION_STALE')
        if task.get('policy_version') != self.document.policy_version:
            raise WorkflowHeld('F02_POLICY_VERSION_CHANGED')
        return self.document.validate(measurement, packet, resolved)

    def require_drafting(self, packet: dict, task: dict, lookup: dict) -> dict:
        if task.get('authorization_status') != TEST_SCOPED_NOT_AUTHORIZED:
            raise WorkflowHeld('QG_MEASUREMENT_VALIDATION_MISSING')
        if (lookup.get('outcome') != 'verified_no_equivalent'
                or lookup.get('scope') != 'SYNTHETIC_PRIVATE_LAB_ONLY'):
            raise WorkflowHeld('QG_NO_EQUIVALENT_RECEIPT_REQUIRED')
        return {'status': 'DRAFTING_RESEARCH_ONLY', 'candidate_only': True,
                'fielding_authorized': False, 'scientific_acceptance': False}


def lab_authority(document: MeasurementPolicyDocument = QJ_INVARIANTS_POLICY,
                  *, lab_scope_record: str = 'LAB-AUTH-20261117',
                  production_requested: bool = False) -> MeasurementAuthority:
    return MeasurementAuthority(document, lab_scope_record=lab_scope_record,
                                production_requested=production_requested)
