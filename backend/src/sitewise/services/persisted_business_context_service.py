"""Construct with the existing BCB, persist atomically, reauthorize on retrieval.

Separate idempotent operation after confirmation. No downstream execution.
"""
from contextlib import contextmanager
from copy import deepcopy
from uuid import UUID, NAMESPACE_URL, uuid5

from sitewise.core.exceptions import ConflictError, NotFoundError
from sitewise.domain.m2_provenance import pins_match
from sitewise.services.business_context_v1 import (
    CONTRACTS, CURRENT_CONTEXT_VERSION, HISTORICAL_SECTIONS_CONTRACTS,
    SECTIONS_CONTRACTS, SECTIONS_CONTEXT_VERSION, BusinessContextBuilderV1,
    ContextRefused, canonical_bytes, json_value, source_hash,
)
from sitewise.services.ports.business_context_v1_port import ContextReadView
from sitewise.services.ports.business_context_store_port import (
    ContextActor, ContextBindingUnavailable, ContextSelection, ContextStorePort,
    ContextStoreUnavailable,
)


class ContextOperationHeld(ValueError):
    def __init__(self, code: str, status_code: int = 409):
        self.code, self.status_code = code, status_code
        super().__init__(code)


#: How a persisted packet's bound objective version stands today. A confirmed
#: uncertainty is immutable, but the owner may confirm a *newer* version of the
#: same research intention; that supersession invalidates the context by
#: version, without touching the M2 confirmation or the historical packet.
UNCERTAINTY_CURRENT = 'CURRENT'
UNCERTAINTY_SUPERSEDED = 'SUPERSEDED'
UNCERTAINTY_ABSENT = 'ABSENT'
UNCERTAINTY_UNBOUND = 'UNBOUND'
UNCERTAINTY_UNREADABLE = 'UNREADABLE'
#: States that leave the packet's binding intact. UNREADABLE is here on
#: purpose: a lineage read that is unavailable is not evidence of staleness,
#: and inventing staleness from a missing capability would invalidate every
#: context on a store that does not implement the read.
UNCERTAINTY_LIVE = (UNCERTAINTY_CURRENT, UNCERTAINTY_UNBOUND, UNCERTAINTY_UNREADABLE)


class _Authorization:
    def __init__(self, decision): self.decision = decision
    def authorize(self, request): return deepcopy(self.decision)


class _FrozenM2:
    """Detached source object graph, captured after authorization in one RR tx."""
    def __init__(self, repo, selection, owner):
        self.assessment = repo.get_assessment(selection.assessment_id, owner)
        self.confirmation = repo.get_confirmation(selection.confirmation_id, owner)
        self.instrument = repo.get_instrument(self.assessment['instrument_id'])
        self.items = repo.list_items(self.assessment['instrument_id'])
        self.answers = repo.get_latest_answers(selection.assessment_id, selection.revision)
        self.findings = repo.get_findings(selection.assessment_id, selection.revision)
        snapshot = self.confirmation['snapshot_json']
        if not pins_match(snapshot,
                repo.get_evaluation(selection.assessment_id,selection.revision,snapshot.get('bdj_rule_version')),
                repo.get_review(selection.assessment_id,selection.revision),self.findings,self.items):
            raise ContextRefused('M2_CONFIRMATION_PROVENANCE_UNPINNED')
        decisions = repo.latest_clarifications(selection.assessment_id, selection.revision)
        refs = self.confirmation['snapshot_json'].get('finding_decision_event_refs', {})
        if any(fid not in decisions or str(decisions[fid]['id']) != event_id or
               decisions[fid]['decision'] != 'KEEP_ORIGINAL' or
               decisions[fid]['actor_user_id'] != owner for fid,event_id in refs.items()):
            raise ContextRefused('FINDING_CONFIRMATION_MISMATCH')
        for name in ('assessment', 'confirmation', 'instrument', 'items', 'answers', 'findings'):
            setattr(self, name, json_value(getattr(self, name)))
    def get_assessment(self, *args): return deepcopy(self.assessment)
    def get_confirmation(self, *args): return deepcopy(self.confirmation)
    def get_instrument(self, *args): return deepcopy(self.instrument)
    def list_items(self, *args): return deepcopy(self.items)
    def get_latest_answers(self, *args): return deepcopy(self.answers)
    def get_findings(self, *args): return deepcopy(self.findings)


class _Snapshot:
    def __init__(self, unit, selection, actor, bindings):
        self.unit, self.selection, self.actor, self.bindings = unit, selection, actor, bindings
    @contextmanager
    def open_read(self, request, decision):
        # Builder calls this only after checking the trusted authorization.
        yield ContextReadView(_FrozenM2(self.unit.m2, self.selection, self.actor.user_id),
                              deepcopy(self.bindings))


class PersistedBusinessContextService:
    def __init__(self, store: ContextStorePort, contract: str | None = None):
        # ``None`` means "choose per instrument at build time" (DD-017). An
        # explicit contract still wins, so historical callers and tests that
        # pin 1.0/1.1 keep producing byte-identical packets.
        if contract is not None and contract not in CONTRACTS:
            raise ContextOperationHeld('BCB_CONTRACT_VERSION_UNSUPPORTED')
        self.store, self.contract = store, contract
        #: Why the last ``_reproduces`` call returned False, or None when it
        #: reproduced. Diagnostic only: it never alters the boolean or the
        #: refusal, and it carries no source data.
        self.last_reproduction_failure = None

    @staticmethod
    def _instrument_contract(unit, selection, actor) -> str:
        """Pick the contract from the assessment's instrument (DD-017).

        M2V2 assessments carry the three separable V2 outputs, so they need the
        sections contract; every other instrument stays on the geo-excluded 1.1
        contract it was already built with. The builder still fails closed
        (``SECTIONS_REQUIRE_M2V2``) if an M2V1 assessment is ever pointed at a
        sections contract, so a wrong mapping is a refusal, not an empty block.
        """
        assessment = unit.m2.get_assessment_for_update(selection.assessment_id, actor.user_id)
        if assessment is None:
            # ``_select`` runs first and raises NotFoundError; this is only a
            # defensive default and never reaches the builder.
            return CURRENT_CONTEXT_VERSION
        instrument = unit.m2.get_instrument(UUID(str(assessment['instrument_id'])))
        tag = str((instrument or {}).get('version_tag') or '')
        return SECTIONS_CONTEXT_VERSION if tag.startswith('M2V2-') else CURRENT_CONTEXT_VERSION

    @staticmethod
    def _require_contract_family(unit, selection, actor, contract: str) -> None:
        """Refuse a caller-pinned contract from the wrong family (DD-078).

        ``_instrument_contract`` already selects the right family when nobody
        pins one. The remaining hole is the opt-in override: a caller could pin
        a non-sections label on an M2V2 assessment and get a packet that
        silently drops the three separable V2 outputs. That packet still passes
        its own integrity checks, so the loss is invisible until BDJ or QG
        cannot read it — which is exactly how a ``BCB-V1-1.1.0`` row was once
        persisted against an M2V2 assessment.

        This is the mirror of the builder's ``SECTIONS_REQUIRE_M2V2`` refusal,
        and it stays inside the family rather than pinning one label: a caller
        may still reproduce the historical ``BCB-V1-1.2.0`` sections label. It
        is deliberately not applied to ``_reproduction_failure``, which rebuilds
        a recorded packet under its own recorded contract.
        """
        wants_sections = PersistedBusinessContextService._instrument_contract(
            unit, selection, actor) in SECTIONS_CONTRACTS
        if wants_sections != (contract in SECTIONS_CONTRACTS):
            raise ContextOperationHeld('BCB_CONTRACT_INSTRUMENT_MISMATCH')

    @staticmethod
    def _select(unit, selection, actor, *, initialize_build=True):
        assessment = unit.m2.get_assessment_for_update(selection.assessment_id, actor.user_id)
        if assessment is None:
            raise NotFoundError('Assessment not found.')
        if (assessment['revision'] != selection.revision or
                assessment['confirmed_revision'] != selection.revision):
            raise ConflictError('Confirm the current M2 revision before constructing context.')
        # The build row has no other producer, and a missing build was being
        # reported as a missing confirmation snapshot. Verify the confirmation
        # actually belongs to this assessment/revision first, then initialise.
        confirmation = unit.m2.get_confirmation(selection.confirmation_id, actor.user_id)
        if (confirmation is None
                or str(confirmation['assessment_id']) != str(selection.assessment_id)
                or confirmation['assessment_revision'] != selection.revision):
            raise NotFoundError('Confirmation snapshot not found.')
        if initialize_build:
            unit.ensure_build(selection.confirmation_id, actor.user_id,
                              selection.assessment_id, selection.revision)
        build = unit.read_build(selection.confirmation_id, actor.user_id)
        if build is None or build['assessment_id'] != selection.assessment_id:
            raise NotFoundError('Confirmation snapshot not found.')
        if build['assessment_revision'] != selection.revision:
            raise ConflictError('Confirmation revision mismatch.')

    @staticmethod
    def _build(unit, selection, actor, contract):
        inputs = unit.resolve_inputs(selection, actor)
        request = inputs.request
        if (request.viewer_id != actor.user_id or request.role != actor.role or
                request.assessment_id != selection.assessment_id or
                request.confirmation_id != selection.confirmation_id or
                request.confirmed_revision != selection.revision):
            raise ContextBindingUnavailable('BCB_BINDING_SCOPE_INVALID')
        return BusinessContextBuilderV1(_Authorization(inputs.decision),
            _Snapshot(unit, selection, actor, inputs.bindings), contract=contract).get_context(request)

    @staticmethod
    def _row(packet):
        body = {k:v for k,v in packet.items() if k != 'packet_hash'}
        if source_hash(body) != packet['packet_hash']:
            raise ContextOperationHeld('BCB_PACKET_INTEGRITY_INVALID')
        return {'context_id':uuid5(NAMESPACE_URL, 'sitewise:bcb:'+packet['packet_hash']),
            'assessment_id':UUID(packet['identity']['assessment_id']),
            'owner_user_id':UUID(packet['identity']['owner_id']),
            'confirmation_id':UUID(packet['confirmation']['id']),
            'assessment_revision':packet['confirmation']['revision'],
            'schema_version':packet['schema_version'], 'builder_version':packet['context_version'],
            'purpose':packet['access']['scope']['purpose'], 'tenant_id':packet['identity']['tenant_id'],
            'concept_version':packet['concept']['version'], 'snapshot_digest':packet['confirmation']['digest'],
            'packet_hash':packet['packet_hash'], 'canonical_body':canonical_bytes(body).decode('utf-8'),
            'packet_json':packet, 'lifecycle_status':'PERSISTED'}

    @staticmethod
    def _response(row, replayed=False):
        packet = row['packet_json']
        expected = PersistedBusinessContextService._row(packet)
        if (source_hash({k:v for k,v in packet.items() if k != 'packet_hash'}) != row['packet_hash'] or
                packet.get('packet_hash') != row['packet_hash'] or
                any(row[key] != expected[key] for key in expected if key not in {'packet_json','canonical_body'}) or
                canonical_bytes({k:v for k,v in packet.items() if k != 'packet_hash'}).decode('utf-8') != row['canonical_body']):
            raise ContextOperationHeld('BCB_STORED_INTEGRITY_INVALID')
        return {'contract_version':'persisted-business-context/1', 'context_id':row['context_id'],
            'assessment_id':row['assessment_id'], 'confirmation_id':row['confirmation_id'],
            'assessment_revision':row['assessment_revision'], 'lifecycle_status':row['lifecycle_status'],
            'created_at':row['created_at'], 'replayed':replayed, 'packet':packet,
            'qj_execution_authorized':False, 'qg_execution_authorized':False}

    def construct_and_save(self, selection: ContextSelection, actor: ContextActor,
                          contract: str | None = None):
        # Only known PostgreSQL serialization/deadlock failures are retried.
        # No provider/remote call exists in this pure construction operation.
        for attempt in range(3):
            try:
                return self._construct_once(selection, actor, contract)
            except ContextStoreUnavailable as exc:
                if attempt == 2:
                    self._record_failure(selection, actor)
                    raise ContextOperationHeld('BCB_PERSISTENCE_UNAVAILABLE',503) from exc

    def _record_failure(self, selection, actor):
        try:
            with self.store.open(actor.user_id) as failure:
                failure.m2.get_assessment_for_update(selection.assessment_id, actor.user_id)
                failure.record_build(selection.confirmation_id, actor.user_id, 'FAILED', 'BCB_PERSISTENCE_UNAVAILABLE')
                failure.commit()
        except ContextStoreUnavailable:
            pass  # DB outage: prior durable state remains; HTTP stays failed.

    def _construct_once(self, selection: ContextSelection, actor: ContextActor,
                        contract: str | None = None):
        # An explicit contract is opt-in per call; an explicit service contract
        # pins every build. When neither is given, the instrument decides
        # (DD-017): M2V2 -> sections, otherwise the geo-excluded 1.1 contract.
        caller_contract = contract
        contract = contract or self.contract
        selected = False
        try:
            with self.store.open(actor.user_id) as unit:
                self._select(unit, selection, actor)
                selected = True
                if contract is None:
                    contract = self._instrument_contract(unit, selection, actor)
                if contract not in CONTRACTS:
                    raise ContextOperationHeld('BCB_CONTRACT_VERSION_UNSUPPORTED')
                if caller_contract is not None:
                    # Only the caller-supplied pin is checked: a service-level
                    # contract is a construction-time decision, and the
                    # reproduction path never reaches this method.
                    self._require_contract_family(unit, selection, actor, contract)
                try:
                    packet = self._build(unit, selection, actor, contract)
                except (ContextBindingUnavailable, ContextRefused) as exc:
                    unit.record_build(selection.confirmation_id, actor.user_id, 'HELD', exc.code)
                    unit.commit()
                    code = exc.code
                    status = 503 if isinstance(exc, ContextBindingUnavailable) else (403 if code == 'ACCESS_DENIED' else 409)
                    raise ContextOperationHeld(code, status) from exc
                row, inserted = unit.put_context(self._row(packet))
                result = self._response(row, not inserted)
                unit.record_build(selection.confirmation_id, actor.user_id, 'PERSISTED', None, row['context_id'])
                unit.commit()
                return result
        except ContextStoreUnavailable as exc:
            if exc.retryable:
                raise
            if selected:
                # Separate failure receipt after the failed packet/status tx has
                # fully rolled back. Never commit a partial context.
                self._record_failure(selection, actor)
            raise ContextOperationHeld('BCB_PERSISTENCE_UNAVAILABLE', 503) from exc

    @staticmethod
    def _bound_objective_id(context_row):
        """The objective version this packet was built against, if any.

        M2 V2 packets carry ``confirmed_uncertainty = null`` by contract, so an
        absent binding is normal and must never read as an error.
        """
        if not context_row:
            return None
        uncertainty = context_row['packet_json'].get('confirmed_uncertainty')
        if not isinstance(uncertainty, dict) or not uncertainty.get('id'):
            return None
        try:
            return UUID(str(uncertainty['id']))
        except (TypeError, ValueError):
            return None

    @staticmethod
    def _current_objective_id(unit, context_row, actor):
        """The bound version, but only while it is still the current one.

        Returns None when the version has been superseded: rebuilding with None
        reproduces the historical first-uncertainty selection instead of
        pretending a superseded version is still bindable.
        """
        objective_id = PersistedBusinessContextService._bound_objective_id(context_row)
        if objective_id is None or not hasattr(unit.m2, 'read_current_objective'):
            return None
        saved = unit.m2.read_current_objective(
            objective_id, actor.user_id, context_row['assessment_revision'])
        if saved and (saved.get('provenance') or {}).get('objective_contract') \
                == 'entrepreneur-objective/1':
            return objective_id
        return None

    @staticmethod
    def _uncertainty_version(unit, context_row, actor) -> dict:
        """Classify the packet's bound objective version without mutating it.

        ``read_current_objective`` answers "may I bind this now?"; that answer
        is deliberately empty once a child revision exists, which collapses
        "superseded by version N+1" and "never existed". Explaining a persisted
        packet needs the distinction, so this uses the lineage read instead.
        Never raises: a status read must not fail because lineage is unknown.
        """
        objective_id = PersistedBusinessContextService._bound_objective_id(context_row)
        blank = {'objective_id': objective_id, 'superseded_by': None, 'action': None}
        if objective_id is None:
            return {'status': UNCERTAINTY_UNBOUND, **blank}
        reader = getattr(unit.m2, 'read_objective_version', None)
        if reader is None:
            return {'status': UNCERTAINTY_UNREADABLE, **blank}
        try:
            row = reader(objective_id, actor.user_id)
        except Exception:  # noqa: BLE001 - diagnostics must not break the read
            return {'status': UNCERTAINTY_UNREADABLE, **blank}
        if row is None:
            return {'status': UNCERTAINTY_ABSENT, **blank}
        if row.get('superseded_by'):
            return {'status': UNCERTAINTY_SUPERSEDED, **blank,
                    'superseded_by': row['superseded_by'],
                    'action': row.get('supersession_action')}
        return {'status': UNCERTAINTY_CURRENT, **blank}

    @classmethod
    def _invalidation_code(cls, unit, context_row, actor, default):
        """Name the version-aware cause when one exists, else keep ``default``."""
        version = cls._uncertainty_version(unit, context_row, actor)
        if version['status'] == UNCERTAINTY_SUPERSEDED:
            return 'BCB_CONTEXT_UNCERTAINTY_SUPERSEDED'
        if version['status'] == UNCERTAINTY_ABSENT:
            return 'BCB_CONTEXT_UNCERTAINTY_ABSENT'
        return default

    def latest_context_id(self, assessment_id: UUID, actor: ContextActor) -> UUID | None:
        """Newest persisted context for this owner, or ``None``.

        Owner-scoped and RLS-bound exactly like [retrieve]: the store is opened
        as the restricted principal with the actor bound, so this can only ever
        name a context the caller already owns. A caller that has no confirmed
        context gets ``None`` rather than a refusal — "nothing confirmed yet"
        is a state the report must be able to draw, not an error.
        """
        try:
            with self.store.open(actor.user_id) as unit:
                return unit.latest_context_id(assessment_id, actor.user_id)
        except ContextStoreUnavailable as exc:
            raise ContextOperationHeld('BCB_PERSISTENCE_UNAVAILABLE', 503) from exc

    def retrieve(self, assessment_id: UUID, context_id: UUID, actor: ContextActor):
        try:
            with self.store.open(actor.user_id) as unit:
                row = unit.read_context(context_id, actor.user_id)
                if row is None or row['assessment_id'] != assessment_id:
                    raise NotFoundError('Business context not found.')
                # New owner-confirmed objective versions can be reconstructed
                # from the packet's existing uncertainty ID. Historical rows
                # retain their earlier first-uncertainty selection semantics.
                selected_id = self._current_objective_id(unit, row, actor)
                selection = ContextSelection(assessment_id, row['confirmation_id'], row['assessment_revision'], selected_id)
                # Readback must not create a missing build row. Construction is
                # the only path allowed to initialize one; a missing build here
                # is evidence of an inconsistent persisted context.
                self._select(unit, selection, actor, initialize_build=False)
                # Rebuild against the contract the stored packet was created
                # under, so historical 1.0 snapshots stay readable after the
                # 1.1 (GEO-excluded) version bump instead of being re-versioned.
                if row['builder_version'] not in CONTRACTS:
                    raise ContextOperationHeld('BCB_CONTRACT_VERSION_UNSUPPORTED')
                try:
                    packet = self._build(unit, selection, actor, row['builder_version'])
                except (ContextBindingUnavailable, ContextRefused) as exc:
                    # A superseded objective version surfaces from the builder as
                    # an unverified objective source, because the version is no
                    # longer bindable. That is a version event, not a source
                    # defect, so report it as one.
                    raise ContextOperationHeld(
                        self._invalidation_code(unit, row, actor, exc.code),
                        503 if isinstance(exc, ContextBindingUnavailable) else 409) from exc
                if packet['packet_hash'] != row['packet_hash']:
                    # Distinguish the causes rather than reporting them all as a
                    # changed source. A historical contract whose projection the
                    # current builder no longer reproduces is a versioning gap; a
                    # superseded objective version is a deliberate owner action.
                    # Neither is evidence that the entrepreneur's answers moved.
                    default = (
                        'BCB_CONTEXT_HISTORICAL_INCOMPATIBLE'
                        if row['builder_version'] in HISTORICAL_SECTIONS_CONTRACTS
                        else 'BCB_CONTEXT_SOURCE_CHANGED')
                    raise ContextOperationHeld(
                        self._invalidation_code(unit, row, actor, default))
                return self._response(row)
        except ContextStoreUnavailable as exc:
            raise ContextOperationHeld('BCB_PERSISTENCE_UNAVAILABLE', 503) from exc

    def _reproduces(self, unit, context_row, assessment_id, actor) -> bool:
        """True when the recorded contract still rebuilds this exact packet.

        Readback and status both need this answer; computing it the same way in
        both places is what stops them from disagreeing about whether a context
        is usable. Never raises: a status read must not fail merely because
        readback would.

        The boolean contract is unchanged. The *reason* is recorded on
        ``last_reproduction_failure`` so an operator can tell a missing contract
        from a builder refusal from a hash mismatch, without a silent ``False``
        and without exposing any source value.
        """
        reason = self._reproduction_failure(
            unit, context_row, assessment_id, actor)
        self.last_reproduction_failure = reason
        return reason is None

    def _reproduction_failure(self, unit, context_row, assessment_id,
                              actor) -> str | None:
        """Stable, non-leaking reason code; ``None`` when it reproduces.

        Codes are exception *classes* and the contract's own stable ``code``
        attribute — never a message, never a source value, never a packet
        fragment. ``PACKET_HASH_MISMATCH`` is the one outcome that is not an
        error: the builder succeeded and legitimately derived a different
        packet, which is what a moved source looks like.

        Supersession is classified *after* the rebuild, never instead of it. A
        newer objective version that happens to carry identical text still
        reproduces byte-identically, and reporting it stale would invalidate a
        context that is in fact usable.
        """
        if context_row is None:
            return 'CONTEXT_ROW_MISSING'
        if context_row['builder_version'] not in CONTRACTS:
            return 'CONTRACT_UNREGISTERED'
        try:
            selection = ContextSelection(
                assessment_id, context_row['confirmation_id'],
                context_row['assessment_revision'],
                self._current_objective_id(unit, context_row, actor))
            self._select(unit, selection, actor, initialize_build=False)
            rebuilt = self._build(unit, selection, actor, context_row['builder_version'])
            if rebuilt['packet_hash'] == context_row['packet_hash']:
                return None
            failure = 'PACKET_HASH_MISMATCH'
        except Exception as exc:  # noqa: BLE001 - a status read must not raise
            code = getattr(exc, 'code', None)
            failure = f'{type(exc).__name__}:{code}' if code else type(exc).__name__
        # The rebuild did not reproduce. If the bound version was superseded,
        # that is the honest explanation and it is version-aware: it names the
        # successor instead of implying the entrepreneur's declarations moved.
        version = self._uncertainty_version(unit, context_row, actor)
        if version['status'] == UNCERTAINTY_SUPERSEDED:
            return 'CONFIRMED_UNCERTAINTY_SUPERSEDED'
        if version['status'] == UNCERTAINTY_ABSENT:
            return 'CONFIRMED_UNCERTAINTY_ABSENT'
        return failure

    def status(self, assessment_id: UUID, confirmation_id: UUID, actor: ContextActor):
        try:
            with self.store.open(actor.user_id) as unit:
                assessment = unit.m2.get_assessment(assessment_id, actor.user_id)
                row = unit.read_build(confirmation_id, actor.user_id)
                if assessment is None or row is None or row['assessment_id'] != assessment_id:
                    raise NotFoundError('Confirmation context status not found.')
                # The build row records where the context is, not how it was
                # built, so the contract has to be read off the context itself.
                context_row = (unit.read_context(row['context_id'], actor.user_id)
                               if row.get('context_id') else None)
                builder_version = (context_row or {}).get('builder_version')
                # Status must agree with readback, so it performs the same
                # rebuild-and-compare readback does rather than inferring
                # compatibility from the label alone. A packet recorded under a
                # known contract but carrying content that contract does not
                # produce (the mislabelled 1.2.0 artefact) is therefore reported
                # incompatible here, exactly as readback refuses it.
                compatible = self._reproduces(unit, context_row, assessment_id, actor)
                superseded = (SECTIONS_CONTEXT_VERSION
                              if builder_version in HISTORICAL_SECTIONS_CONTRACTS
                              else None)
                version = self._uncertainty_version(unit, context_row, actor)
                return {**row,
                        'builder_version': builder_version,
                        'context_compatible': compatible,
                        # Diagnostic, not a decision. Stable code, no source
                        # data. Absent (None) when the context reproduces.
                        'context_incompatible_reason': (
                            None if compatible else self.last_reproduction_failure),
                        'superseded_by': superseded,
                        # Which objective version this packet is bound to, and
                        # whether that version still stands. Supersession is a
                        # version event: it invalidates the context by naming a
                        # successor, and it never asks for the M2 confirmation
                        # to be repeated.
                        'uncertainty_version_status': version['status'],
                        'superseded_by_objective_id': version['superseded_by'],
                        'uncertainty_supersession_action': version['action'],
                        'source_is_current': (
                            compatible
                            and version['status'] in UNCERTAINTY_LIVE
                            and assessment['revision'] == row['assessment_revision']
                            == assessment['confirmed_revision'])}
        except ContextStoreUnavailable as exc:
            raise ContextOperationHeld('BCB_PERSISTENCE_UNAVAILABLE', 503) from exc
