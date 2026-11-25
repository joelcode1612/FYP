"""Version-bound M2 source projection; confirmation is checked by the caller."""
import json
from uuid import UUID

from sitewise.core.exceptions import ConflictError, NotFoundError
from sitewise.modules.decision_engine.domain.m2_rules import resolve_m2_items, validate_m2_answer
from sitewise.project1.contracts import digest
from sitewise.project1.m2v2_projection import M2V2_VERSION

EXCLUDED = frozenset({'M2-11', 'M2-15', 'M2-20', 'M2-21'})
M2V1_ITEMS = frozenset(f'M2V1-{number:02d}' for number in range(1, 12))
M2V1_VERSION = 'M2V1-20261114-1'


class M2SourceProjection:
    def __init__(self, repository):
        self.repo = repository

    def read(self, assessment_id: UUID, actor_id: UUID, expected_revision: int, *, include_inventory: bool = False, read_only: bool = False) -> dict:
        """Build the projection packet for one confirmed assessment revision.

        ``read_only`` exists for callers that only need the *fingerprint* and must
        not take a row lock. The default takes ``SELECT … FOR UPDATE`` on the
        assessment, which is correct for every write path that builds a packet
        before mutating something. A page read that merely wants to compare a
        stored ``source_fingerprint`` against the current one must not lock the
        row: doing so serialised the whole assessment list behind one assessment
        being edited (DD-122).

        The packet is built by exactly the same code either way, so the
        fingerprint a read-only caller computes is the fingerprint a writer
        would have stored. Only the locking differs.
        """
        try:
            if read_only:
                assessment = self.repo.get_assessment(assessment_id, actor_id)
            else:
                assessment = self.repo.get_assessment_for_update(assessment_id, actor_id)
            if assessment is None:
                raise NotFoundError('Assessment not found.')
            if assessment['revision'] != expected_revision:
                raise ConflictError('Your business details changed. Reload before reviewing.')
            instrument = self.repo.get_instrument(assessment['instrument_id'])
            if instrument and instrument['version_tag'] == M2V2_VERSION:
                # The M2 V2 instrument has nineteen registered items, no
                # exclusions and a structured value per composite answer, so its
                # packet is a different contract rather than a variant of this
                # one. Dispatch here, after the same owner-scoped lock and the
                # same revision check, so every caller keeps one entry point.
                if include_inventory:
                    # The versioned item inventory is an M2 V1 artefact bound to
                    # the eleven M2V1-* keys; there is no V2 equivalent.
                    raise ConflictError(
                        'An M2 V2 source has no versioned item inventory.')
                from sitewise.project1.m2v2_projection import build_packet
                return build_packet(
                    assessment=assessment, instrument=instrument,
                    items=self.repo.list_items(assessment['instrument_id']),
                    answers=self.repo.get_latest_answers(assessment_id, expected_revision),
                    assessment_id=assessment_id, expected_revision=expected_revision)
            if not instrument or instrument['approval_state'] != 'AUTHORIZED':
                raise ConflictError('An authorized M2 instrument version is required.')
            items = self.repo.list_items(assessment['instrument_id'])
            item_map = {i['item_key']: i for i in items}
            if len(item_map) != len(items) or not items:
                raise ConflictError('M2 item definitions could not be verified.')
            answers = self.repo.get_latest_answers(assessment_id, expected_revision)
            # Derived items (e.g. M2V1-05 / M2V1-10) carry empty static options;
            # their effective options are derived from a source item. Validate
            # against the resolved view, but keep definition_digest bound to the
            # raw registered definition so the packet fingerprint is stable.
            resolved_map = {i['item_key']: i for i in resolve_m2_items(items, answers)}
            declarations = []
            for key, answer in sorted(answers.items()):
                if instrument['version_tag'] == M2V1_VERSION and key not in M2V1_ITEMS:
                    raise ConflictError('M2V1 source contains an unsupported item.')
                if key in EXCLUDED:
                    continue
                item = item_map.get(key)
                if (not item or item['instrument_id'] != instrument['id'] or
                        answer['assessment_id'] != assessment_id or
                        answer['item_version_id'] != item['id'] or
                        not 0 < answer['assessment_revision'] <= expected_revision):
                    raise ConflictError('M2 answer versions could not be verified.')
                if item['answer_kind'] == 'ACTION' or item['lifecycle'] != 'ACTIVE':
                    continue
                validate_m2_answer(resolved_map.get(key, item), answer['answer_state'], answer['value_json'])
                declarations.append({
                    'item_key': key, 'question': item['question_text'],
                    'item_version_id': str(item['id']), 'definition_digest': digest({
                        k: str(v) if isinstance(v, UUID) else v for k, v in item.items()}),
                    'answer_revision_id': str(answer['id']),
                    'answer_revision': answer['assessment_revision'],
                    'answer_state': answer['answer_state'], 'value': answer['value_json'],
                    'trust_class': 'ENTREPRENEUR_DECLARED',
                })
            packet = {
                'schema_version': 'project1-m2-projection/1-candidate',
                'assessment_id': str(assessment_id), 'assessment_revision': expected_revision,
                'instrument_id': str(instrument['id']),
                'instrument_version': instrument['version_tag'],
                'instrument_digest': instrument['schema_digest'],
                'declarations': declarations,
                'governance_items': ['M2-20', 'M2-21'],
                'excluded_items': ({} if instrument['version_tag'] == M2V1_VERSION
                                   else {'M2-11': 'DEFERRED', 'M2-15': 'PRIVACY_PENDING'}),
                'confirmed': assessment['confirmed_revision'] == expected_revision,
                'facts_independently_verified': False,
            }
            # Preserve the historical source fingerprint; the optional inventory
            # is a separate versioned envelope bound to that exact fingerprint.
            projection = {**packet, 'source_fingerprint': digest(packet)}
            if include_inventory:
                if instrument['version_tag'] != M2V1_VERSION:
                    raise ConflictError('M2V1 inventory requires its registered instrument version.')
                from sitewise.project1.m2v1_inventory_candidate import inventory
                for key in M2V1_ITEMS:
                    item = item_map.get(key)
                    if (not item or item['instrument_id'] != instrument['id'] or
                            item['lifecycle'] != 'ACTIVE' or item['answer_kind'] == 'ACTION' or
                            not item.get('question_text')):
                        raise ConflictError('M2V1 item definitions could not be verified.')
                try:
                    inventory_data = inventory(items, answers)
                except (KeyError, TypeError, ValueError):
                    raise ConflictError('M2V1 item inventory could not be verified.') from None
                bound_inventory = {**inventory_data, 'source_fingerprint': projection['source_fingerprint']}
                result = {'projection': projection, 'item_inventory': {
                    **bound_inventory, 'inventory_fingerprint': digest(bound_inventory)}}
            else:
                result = projection
            # Detached source view; text, including injection-like text, stays JSON data.
            return json.loads(json.dumps(result, ensure_ascii=False, allow_nan=False))
        finally:
            self.repo.rollback()


def verify_projection(packet: dict) -> None:
    content = {k: v for k, v in packet.items() if k != 'source_fingerprint'}
    if digest(content) != packet.get('source_fingerprint'):
        raise ConflictError('Source fingerprint mismatch.')
    declarations = packet.get('declarations', [])
    keys = [d['item_key'] for d in declarations]
    if len(set(keys)) != len(keys) or EXCLUDED.intersection(keys):
        raise ConflictError('Source membership mismatch.')
    if packet.get('instrument_version') == M2V1_VERSION and not set(keys).issubset(M2V1_ITEMS):
        raise ConflictError('M2V1 source contains an unsupported item.')


def verify_bdj_inventory(envelope: dict, *, item_definitions: list[dict]) -> None:
    """Recompute using independently retrieved registered instrument definitions.

    The caller must establish those definitions' authority and currentness;
    unkeyed inventory hashes alone do not authenticate an inventory.
    """
    projection, inventory_data = envelope.get('projection'), envelope.get('item_inventory')
    if not isinstance(projection, dict) or not isinstance(inventory_data, dict):
        raise ConflictError('M2V1 inventory envelope is missing.')
    verify_projection(projection)
    source = {k: v for k, v in inventory_data.items() if k != 'inventory_fingerprint'}
    rows = inventory_data.get('items')
    if (inventory_data.get('schema_version') != 'm2v1-item-inventory/1-candidate' or
            inventory_data.get('source_fingerprint') != projection['source_fingerprint'] or
            digest(source) != inventory_data.get('inventory_fingerprint') or
            not isinstance(rows, list) or len(rows) != 11 or
            any(not isinstance(row, dict) for row in rows) or
            {row.get('item_key') for row in rows} != M2V1_ITEMS):
        raise ConflictError('M2V1 inventory binding is invalid.')
    declarations = {d['item_key']: d for d in projection['declarations']}
    for row in rows:
        saved = declarations.get(row['item_key'])
        if saved is not None:
            if any(row.get(k) != saved.get(src) for k, src in (
                    ('item_version_id', 'item_version_id'), ('question', 'question'),
                    ('answer_revision_id', 'answer_revision_id'), ('answer_revision', 'answer_revision'),
                    ('state', 'answer_state'), ('value', 'value'))):
                raise ConflictError('M2V1 inventory does not match saved source.')
        elif row.get('answer_revision_id') is not None or row.get('answer_revision') is not None:
            raise ConflictError('M2V1 inventory contains an invented answer revision.')
        derived = row.get('derived_from')
        if derived is not None:
            if not isinstance(derived, dict):
                raise ConflictError('M2V1 inventory derived source is invalid.')
            source_row = declarations.get(derived.get('item_key'))
            if not source_row or source_row['answer_revision_id'] != derived.get('answer_revision_id'):
                raise ConflictError('M2V1 inventory derived source is invalid.')
            source_key, value = derived['item_key'], source_row['value']
            target, state = row['item_key'], row.get('state')
            if source_row['answer_state'] != 'ANSWERED':
                raise ConflictError('M2V1 inventory derived source is invalid.')
            if state == 'DERIVED':
                if ((target, source_key) not in {('M2V1-05', 'M2V1-04'), ('M2V1-10', 'M2V1-09')} or
                        not isinstance(value, list) or len(value) != 1 or
                        value[0] in {'NONE', 'UNDECIDED'} or row.get('value') != value[0]):
                    raise ConflictError('M2V1 inventory derived value is invalid.')
            elif state == 'NOT_APPLICABLE':
                allowed = ((target, source_key, value) in (
                    ('M2V1-05', 'M2V1-04', ['UNDECIDED']),
                    ('M2V1-10', 'M2V1-09', ['NONE']),
                    ('M2V1-07', 'M2V1-02', 'DELIVERY'),
                    ('M2V1-11', 'M2V1-09', ['NONE'])))
                if not allowed or row.get('value') is not None:
                    raise ConflictError('M2V1 inventory applicability is invalid.')
            else:
                raise ConflictError('M2V1 inventory derived state is invalid.')
        elif saved is None and row.get('state') in {'DERIVED', 'NOT_APPLICABLE'}:
            raise ConflictError('M2V1 inventory derived source is missing.')
    try:
        if any(str(item['instrument_id']) != projection['instrument_id']
               for item in item_definitions if item['item_key'] in M2V1_ITEMS):
            raise ValueError('M2V1 inventory instrument mismatch.')
        answers = {d['item_key']: {'id':d['answer_revision_id'],
                    'assessment_revision':d['answer_revision'], 'answer_state':d['answer_state'],
                    'value_json':d['value']} for d in projection['declarations']}
        from sitewise.project1.m2v1_inventory_candidate import inventory
        recomputed = inventory(item_definitions, answers)
    except (KeyError, ValueError, TypeError):
        raise ConflictError('M2V1 inventory source definitions are invalid.') from None
    if (inventory_data['schema_version'] != recomputed['schema_version'] or
            rows != recomputed['items']):
        raise ConflictError('M2V1 inventory differs from recomputed source.')


def bind_bdj_inventory_to_confirmation(envelope: dict, confirmed_projection: dict, *, item_definitions: list[dict]) -> dict:
    """Rebind a server-created inventory after its current confirmation is attached.

    The caller is responsible for authenticating the owner and verifying the
    confirmation against PostgreSQL; fingerprints cannot establish authority.
    """
    verify_bdj_inventory(envelope, item_definitions=item_definitions)
    verify_projection(confirmed_projection)
    original = envelope['projection']
    before = {k: v for k, v in confirmed_projection.items() if k not in ('confirmation', 'source_fingerprint')}
    if before != {k: v for k, v in original.items() if k != 'source_fingerprint'}:
        raise ConflictError('M2 source changed while binding its inventory.')
    confirmation = confirmed_projection.get('confirmation')
    if (not confirmed_projection.get('confirmed') or not isinstance(confirmation, dict) or
            not isinstance(confirmation.get('confirmation_id'), str) or not confirmation['confirmation_id'] or
            not isinstance(confirmation.get('snapshot_digest'), str) or
            len(confirmation['snapshot_digest']) != 64 or
            any(c not in '0123456789abcdef' for c in confirmation['snapshot_digest'])):
        raise ConflictError('Current M2 confirmation is required.')
    inventory_data = {k: v for k, v in envelope['item_inventory'].items() if k != 'inventory_fingerprint'}
    inventory_data['source_fingerprint'] = confirmed_projection['source_fingerprint']
    result = {'projection': confirmed_projection,
              'item_inventory': {**inventory_data, 'inventory_fingerprint': digest(inventory_data)}}
    verify_bdj_inventory(result, item_definitions=item_definitions)
    return result
