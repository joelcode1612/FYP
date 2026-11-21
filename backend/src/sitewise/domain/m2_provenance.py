"""Deterministic confirmation provenance; no new questionnaire semantics."""
import hashlib
import json
from uuid import UUID
from sitewise.core.exceptions import ConflictError

LEGACY_SNAPSHOT_VERSION = 'm2-confirmation/2'
SNAPSHOT_VERSION = 'm2-confirmation/3'


class M2ConfirmationConflict(ConflictError):
    """Safe, structured declaration error; never carries submitted values."""
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def _json_default(value):
    if isinstance(value,UUID): return str(value)
    raise TypeError('Unsupported provenance value.')


def _digest(value):
    return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':'),
        ensure_ascii=False,allow_nan=False,default=_json_default).encode('utf-8')).hexdigest()


def confirmation_pins(rule_version, evaluation, review, findings, items):
    """Pin actual persisted receipts/definitions; timestamps are not synthesized."""
    finding_keys=('id','assessment_id','assessment_revision','rule_id','rule_version',
        'source_answer_ids','issue_type','explanation','not_proven','next_action','review_state')
    item_keys=('id','instrument_id','item_key','question_text','requiredness','answer_kind',
        'option_values','allowed_states','lifecycle','sort_order')
    return {'snapshot_contract_version':LEGACY_SNAPSHOT_VERSION,'bdj_rule_version':rule_version,
        'bdj_evaluation_id':str(evaluation['id']),'review_event_id':str(review['id']),
        'finding_hashes':{str(f['id']):_digest({k:f[k] for k in finding_keys}) for f in findings},
        'item_definition_hashes':{str(i['id']):_digest({k:i[k] for k in item_keys}) for i in items}}


def declaration_pins(review, items):
    """A saved declaration review, without claiming any BDJ execution."""
    keys=('id','instrument_id','item_key','question_text','requiredness','answer_kind',
          'option_values','allowed_states','lifecycle','sort_order')
    return {'snapshot_contract_version':SNAPSHOT_VERSION,
            'confirmation_scope':'M2_DECLARATIONS_ONLY',
            'review_event_id':str(review['id']),
            'review_event_hash':_digest({k:review[k] for k in (
                'id','assessment_id','assessment_revision','actor_user_id')}),
            'item_definition_hashes':{str(i['id']):_digest({k:i[k] for k in keys}) for i in items}}


def pins_match(snapshot, evaluation, review, findings, items):
    version = snapshot.get('snapshot_contract_version')
    if version == SNAPSHOT_VERSION:
        if (review is None or snapshot.get('unresolved_candidate_findings') != [] or
                snapshot.get('finding_decision_event_refs') != {} or
                any(k in snapshot for k in ('bdj_evaluation_id','bdj_rule_version','finding_hashes'))):
            return False
        expected = declaration_pins(review, items)
        return all(snapshot.get(key) == value for key,value in expected.items())
    if evaluation is None or review is None or version != LEGACY_SNAPSHOT_VERSION:
        return False
    expected=confirmation_pins(snapshot.get('bdj_rule_version'),evaluation,review,findings,items)
    return all(snapshot.get(key)==value for key,value in expected.items())
