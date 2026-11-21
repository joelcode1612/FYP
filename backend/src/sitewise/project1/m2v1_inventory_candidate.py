"""Versioned, non-persistent M2V1 inventory candidate; not a dispatch path.

The existing projection/fingerprints and confirmation snapshots stay unchanged.
No inventory-only item is a stored answer or an eligible finding source.
"""
from sitewise.modules.decision_engine.domain.m2_rules import resolve_m2_items
from sitewise.project1.projection import M2V1_ITEMS


def inventory(items, answers):
    indexed = {item['item_key']: item for item in items if item['item_key'] in M2V1_ITEMS}
    if set(indexed) != M2V1_ITEMS or len(indexed) != sum(item['item_key'] in M2V1_ITEMS for item in items):
        raise ValueError('Exact registered M2V1 items required.')
    resolved = {item['item_key']: item for item in resolve_m2_items(list(indexed.values()), answers)}
    rows = []
    for key in sorted(indexed):
        item = indexed[key]
        answer = answers.get(key)
        rules = item['option_values'].get('rules', {})
        row = {'item_key': key, 'question': item['question_text'], 'item_version_id': str(item['id']),
               'state': 'MISSING', 'value': None, 'answer_revision_id': None,
               'answer_revision': None, 'derived_from': None}
        if answer is not None:
            row.update(state=answer['answer_state'], value=answer['value_json'],
                       answer_revision_id=str(answer['id']), answer_revision=answer['assessment_revision'])
        elif resolved[key].get('derived_value') is not None:
            source_key = rules['source_item']
            row.update(state='DERIVED', value=resolved[key]['derived_value'],
                       derived_from={'item_key':source_key, 'answer_revision_id':str(answers[source_key]['id'])})
        elif 'not_applicable_when' in rules:
            condition = rules['not_applicable_when']
            source = answers.get(condition['item'])
            if source and source['answer_state'] == 'ANSWERED' and source['value_json'] == condition['value']:
                row.update(state='NOT_APPLICABLE', derived_from={'item_key':condition['item'],
                           'answer_revision_id':str(source['id'])})
            elif not source or source['answer_state'] != 'ANSWERED':
                row['state'] = 'CONDITION_UNRESOLVED'
        elif 'source_item' in rules and not resolved[key].get('applicable', True):
            source_key = rules['source_item']
            source = answers.get(source_key)
            if source and source['answer_state'] == 'ANSWERED':
                row.update(state='NOT_APPLICABLE', derived_from={'item_key':source_key,
                           'answer_revision_id':str(source['id'])})
            else:
                row['state'] = 'CONDITION_UNRESOLVED'
        elif 'requires_priority' in rules and not resolved[key].get('applicable', True):
            source = answers.get('M2V1-09')
            if source and source['answer_state'] == 'ANSWERED' and source['value_json'] == ['NONE']:
                row.update(state='NOT_APPLICABLE', derived_from={'item_key':'M2V1-09',
                           'answer_revision_id':str(source['id'])})
            else:
                row['state'] = 'CONDITION_UNRESOLVED'
        rows.append(row)
    return {'schema_version':'m2v1-item-inventory/1-candidate', 'items':rows}
