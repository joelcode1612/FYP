"""Pure, draft-stage M2 answer rules. No framework/ORM imports."""

class M2ValidationError(ValueError):
    pass


def resolve_m2_items(items: list[dict], answers: dict[str, dict]) -> list[dict]:
    """Project registered option labels/conditions without changing saved answers."""
    result = []
    def value(key):
        a = answers.get(key, {})
        return a.get('value_json') if a.get('answer_state') == 'ANSWERED' else None
    for raw in items:
        item = dict(raw)
        data = item['option_values']
        if not isinstance(data, dict):
            result.append(item)
            continue
        options = data.get('options', [])
        rules = data.get('rules', {})
        item.update(option_labels={o['code']: o['label'] for o in options},
                    effective_options=[o['code'] for o in options], applicable=True,
                    derived_value=None)
        if 'not_applicable_when' in rules:
            condition = rules['not_applicable_when']
            if value(condition['item']) != condition['value']:
                item['allowed_states'] = [s for s in item['allowed_states'] if s != 'NOT_APPLICABLE']
        if 'source_item' in rules:
            chosen = value(rules['source_item'])
            chosen = [v for v in (chosen if isinstance(chosen, list) else []) if v not in rules['exclude']]
            item['effective_options'] = chosen + (['UNDECIDED'] if chosen and rules['allow_undecided'] else [])
            source = next((q for q in items if q['item_key'] == rules['source_item']), None)
            if source:
                item['option_labels'] = {o['code']: o['label'] for o in source['option_values']['options']}
            item['option_labels']['UNDECIDED'] = 'Not decided yet'
            item['applicable'] = bool(chosen)
            item['derived_value'] = chosen[0] if len(chosen) == 1 else None
        if 'requires_priority' in rules:
            priority = value(rules['requires_priority'])
            topics = value('M2V1-09')
            active = isinstance(topics, list) and 'NONE' not in topics and bool(topics)
            item['applicable'] = active and (len(topics) == 1 or priority in topics)
        item['effective_required'] = item['applicable'] and item['requiredness'] in {'REQUIRED', 'CONDITIONAL'}
        result.append(item)
    return result


def derived_m2_selections(items: list[dict], answers: dict[str, dict]) -> list[dict]:
    return [{'item_key': q['item_key'], 'value': q['derived_value'],
             'source_item': q['option_values']['rules']['source_item'],
             'source_answer_revision_id': str(answers[q['option_values']['rules']['source_item']]['id'])}
            for q in resolve_m2_items(items, answers) if q.get('derived_value') is not None]


def validate_m2_answer(item: dict, state: str, value: object) -> None:
    """Validate against the exact DB-backed item definition, never guessed options."""
    if item["lifecycle"] != "ACTIVE" or item["answer_kind"] == "ACTION":
        raise M2ValidationError("This item does not accept an answer in this instrument version.")
    if state not in item["allowed_states"]:
        raise M2ValidationError("Response state not allowed for this item version.")
    if item.get('applicable') is False:
        if state not in {'NOT_APPLICABLE', 'NOT_PROVIDED'}:
            raise M2ValidationError('This conditional item is not applicable to the current saved selections.')
    data = item['option_values']
    rules = data.get('rules', {}) if isinstance(data, dict) else {}
    if isinstance(data, dict) and state == 'NOT_APPLICABLE' and item.get('applicable') is not False and item['item_key'] != 'M2V1-07':
        raise M2ValidationError('This item is applicable to the current saved selections.')
    if state != "ANSWERED":
        if value is not None:
            raise M2ValidationError("Non-substantive responses cannot contain substantive values.")
        return
    kind = item["answer_kind"]
    options = item.get('effective_options', [o['code'] for o in data.get('options', [])] if isinstance(data, dict) else data)
    if kind == 'GEO':
        if value == 'UNDECIDED':
            return
        geo = rules['geography']
        if geo['status'] != 'VERIFIED':
            raise M2ValidationError('The approved versioned GEO catalogue is unavailable. No area reference can be invented.')
        if not isinstance(value, dict) or set(value) != {'jurisdiction', 'area_ref', 'catalogue_version'}:
            raise M2ValidationError('Select an authorized area and catalogue version.')
        if value not in geo['areas']:
            raise M2ValidationError('Area is not registered in the approved GEO catalogue.')
        return
    if kind == "SINGLE":
        if not isinstance(value, str) or value not in options:
            raise M2ValidationError("Answer must match one registered option value.")
    elif kind == "MULTI":
        if not isinstance(value, list) or not value or len(value) != len(set(map(str, value))):
            raise M2ValidationError("Select one or more distinct registered options.")
        if not all(isinstance(x, str) and x in options for x in value):
            raise M2ValidationError("Answer contains an unregistered option value.")
        if "NONE" in value and len(value) != 1:
            raise M2ValidationError("NONE must be exclusive.")
        if "NONE_MISSING" in value and len(value) != 1:
            raise M2ValidationError("NONE_MISSING must be exclusive.")
        if len(value) > 1 and set(value).intersection(rules.get('exclusive', [])):
            raise M2ValidationError('This response must be selected on its own.')
    elif kind == "TEXT":
        if not isinstance(value, str) or not value.strip() or len(value) > 4000:
            raise M2ValidationError("Text response must contain 1–4000 characters.")
    else:
        raise M2ValidationError("Unknown response kind; fail closed.")


def missing_required_items(items: list[dict], latest_answers: dict[str, dict]) -> list[str]:
    """Requiredness is instrument-version data; no hardcoded 18/21 field assumption."""
    missing = []
    for item in resolve_m2_items(items, latest_answers):
        if item["lifecycle"] != "ACTIVE" or item["answer_kind"] == "ACTION":
            continue
        if not item.get('effective_required', item['requiredness'] == 'REQUIRED'):
            continue
        if item.get('derived_value') is not None and item['item_key'] not in latest_answers:
            continue
        answer = latest_answers.get(item["item_key"])
        if answer is None or answer["answer_state"] not in item["allowed_states"]:
            missing.append(item["item_key"])
        elif answer["answer_state"] in {"NOT_PROVIDED", "SKIPPED_OPTIONAL"}:
            missing.append(item["item_key"])
    return missing
