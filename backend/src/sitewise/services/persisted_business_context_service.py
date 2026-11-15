"""Construct with the existing BCB, persist atomically, reauthorize on retrieval.

Separate idempotent operation after confirmation. No downstream execution.
"""
from contextlib import contextmanager
from copy import deepcopy
from uuid import UUID, NAMESPACE_URL, uuid5

from sitewise.core.exceptions import ConflictError, NotFoundError
from sitewise.domain.m2_provenance import pins_match
from sitewise.services.business_context_v1 import (
    BusinessContextBuilderV1, ContextRefused, canonical_bytes, json_value, source_hash,
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
    def __init__(self, store: ContextStorePort): self.store = store

    @staticmethod
    def _select(unit, selection, actor):
        assessment = unit.m2.get_assessment_for_update(selection.assessment_id, actor.user_id)
        if assessment is None:
            raise NotFoundError('Assessment not found.')
        if (assessment['revision'] != selection.revision or
                assessment['confirmed_revision'] != selection.revision):
            raise ConflictError('Confirm the current M2 revision before constructing context.')
        build = unit.read_build(selection.confirmation_id, actor.user_id)
        if build is None or build['assessment_id'] != selection.assessment_id:
            raise NotFoundError('Confirmation snapshot not found.')
        if build['assessment_revision'] != selection.revision:
            raise ConflictError('Confirmation revision mismatch.')

    @staticmethod
    def _build(unit, selection, actor):
        inputs = unit.resolve_inputs(selection, actor)
        request = inputs.request
        if (request.viewer_id != actor.user_id or request.role != actor.role or
                request.assessment_id != selection.assessment_id or
                request.confirmation_id != selection.confirmation_id or
                request.confirmed_revision != selection.revision):
            raise ContextBindingUnavailable('BCB_BINDING_SCOPE_INVALID')
        return BusinessContextBuilderV1(_Authorization(inputs.decision),
            _Snapshot(unit, selection, actor, inputs.bindings)).get_context(request)

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

    def construct_and_save(self, selection: ContextSelection, actor: ContextActor):
        # Only known PostgreSQL serialization/deadlock failures are retried.
        # No provider/remote call exists in this pure construction operation.
        for attempt in range(3):
            try:
                return self._construct_once(selection, actor)
            except ContextStoreUnavailable as exc:
                if attempt == 2:
                    self._record_failure(selection, actor)
                    raise ContextOperationHeld('BCB_PERSISTENCE_UNAVAILABLE',503) from exc

    def _record_failure(self, selection, actor):
        try:
            with self.store.open() as failure:
                failure.m2.get_assessment_for_update(selection.assessment_id, actor.user_id)
                failure.record_build(selection.confirmation_id, actor.user_id, 'FAILED', 'BCB_PERSISTENCE_UNAVAILABLE')
                failure.commit()
        except ContextStoreUnavailable:
            pass  # DB outage: prior durable state remains; HTTP stays failed.

    def _construct_once(self, selection: ContextSelection, actor: ContextActor):
        selected = False
        try:
            with self.store.open() as unit:
                self._select(unit, selection, actor)
                selected = True
                try:
                    packet = self._build(unit, selection, actor)
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

    def retrieve(self, assessment_id: UUID, context_id: UUID, actor: ContextActor):
        try:
            with self.store.open() as unit:
                row = unit.read_context(context_id, actor.user_id)
                if row is None or row['assessment_id'] != assessment_id:
                    raise NotFoundError('Business context not found.')
                selection = ContextSelection(assessment_id, row['confirmation_id'], row['assessment_revision'])
                self._select(unit, selection, actor)
                try:
                    packet = self._build(unit, selection, actor)
                except (ContextBindingUnavailable, ContextRefused) as exc:
                    raise ContextOperationHeld(exc.code, 503 if isinstance(exc, ContextBindingUnavailable) else 409) from exc
                if packet['packet_hash'] != row['packet_hash']:
                    raise ContextOperationHeld('BCB_CONTEXT_SOURCE_CHANGED')
                return self._response(row)
        except ContextStoreUnavailable as exc:
            raise ContextOperationHeld('BCB_PERSISTENCE_UNAVAILABLE', 503) from exc

    def status(self, assessment_id: UUID, confirmation_id: UUID, actor: ContextActor):
        try:
            with self.store.open() as unit:
                assessment = unit.m2.get_assessment(assessment_id, actor.user_id)
                row = unit.read_build(confirmation_id, actor.user_id)
                if assessment is None or row is None or row['assessment_id'] != assessment_id:
                    raise NotFoundError('Confirmation context status not found.')
                return {**row, 'source_is_current':assessment['revision'] == row['assessment_revision'] == assessment['confirmed_revision']}
        except ContextStoreUnavailable as exc:
            raise ContextOperationHeld('BCB_PERSISTENCE_UNAVAILABLE', 503) from exc
