"""Version-bound draft projection BEFORE BDJ; confirmation remains a later event."""
import json
from uuid import UUID

from sitewise.core.exceptions import ConflictError, NotFoundError
from sitewise.domain.m2_rules import validate_m2_answer
from sitewise.project1.contracts import digest

EXCLUDED = frozenset({'M2-11', 'M2-15', 'M2-20', 'M2-21'})


class M2SourceProjection:
    def __init__(self, repository):
        self.repo = repository

    def read(self, assessment_id: UUID, actor_id: UUID, expected_revision: int) -> dict:
        try:
            assessment = self.repo.get_assessment_for_update(assessment_id, actor_id)
            if assessment is None:
                raise NotFoundError('Assessment not found.')
            if assessment['revision'] != expected_revision:
                raise ConflictError('Your business details changed. Reload before reviewing.')
            instrument = self.repo.get_instrument(assessment['instrument_id'])
            if not instrument or instrument['approval_state'] != 'AUTHORIZED':
                raise ConflictError('An authorized M2 instrument version is required.')
            items = self.repo.list_items(assessment['instrument_id'])
            item_map = {i['item_key']: i for i in items}
            if len(item_map) != len(items) or not items:
                raise ConflictError('M2 item definitions could not be verified.')
            answers = self.repo.get_latest_answers(assessment_id, expected_revision)
            declarations = []
            for key, answer in sorted(answers.items()):
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
                validate_m2_answer(item, answer['answer_state'], answer['value_json'])
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
                'excluded_items': {'M2-11': 'DEFERRED', 'M2-15': 'PRIVACY_PENDING'},
                'confirmed': assessment['confirmed_revision'] == expected_revision,
                'facts_independently_verified': False,
            }
            # Detached source view; text, including injection-like text, stays JSON data.
            return json.loads(json.dumps({**packet, 'source_fingerprint': digest(packet)},
                                         ensure_ascii=False, allow_nan=False))
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
