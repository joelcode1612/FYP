"""Pure, draft-stage M2 answer rules. No framework/ORM imports."""

class M2ValidationError(ValueError):
    pass


def _rules_of(item_key: str, items: list[dict]) -> dict:
    """Rules of a sibling item, or an empty mapping when it is not present."""
    for candidate in items:
        if candidate['item_key'] == item_key:
            data = candidate.get('option_values')
            return data.get('rules', {}) if isinstance(data, dict) else {}
    return {}


def _source_item_of(item_key: str, items: list[dict]):
    """The item a conditional item derives its options from, if declared."""
    return _rules_of(item_key, items).get('source_item')


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
            allow_undecided = bool(rules.get('allow_undecided'))
            item['effective_options'] = chosen + (['UNDECIDED'] if chosen and allow_undecided else [])
            source = next((q for q in items if q['item_key'] == rules['source_item']), None)
            if source:
                item['option_labels'] = {o['code']: o['label'] for o in source['option_values']['options']}
            if allow_undecided:
                item['option_labels']['UNDECIDED'] = 'Not decided yet'
            item['applicable'] = bool(chosen)
            # Only items that declare derive_single project a single primary
            # value. Items that merely borrow an option domain (for example a
            # list of segment definitions) must not inherit one.
            item['derived_value'] = (chosen[0]
                                     if len(chosen) == 1 and rules.get('derive_single')
                                     else None)
        if 'requires_priority' in rules:
            priority = value(rules['requires_priority'])
            # Version-scoped: the topics item is whatever the priority item
            # derives its options from, so no instrument key is hard-coded.
            topics_key = rules.get('topics_item') or _source_item_of(
                rules['requires_priority'], items)
            topics = value(topics_key) if topics_key else None
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


def _condition_met(when: dict, value: dict) -> bool:
    """Evaluate one declared conditional-required trigger against a response."""
    if not when:
        return True
    actual = value.get(when.get('field'))
    if 'equals' in when:
        return actual == when['equals']
    if 'in' in when:
        return actual in when['in']
    if 'non_empty' in when:
        return bool(actual)
    if 'contains' in when:
        return isinstance(actual, list) and when['contains'] in actual
    return False


def _field_values(field: dict, items) -> list | None:
    """Registered codes for a field, resolving ``values_from`` when possible."""
    if 'values' in field:
        return list(field['values'])
    source = field.get('values_from')
    if source and items:
        for candidate in items:
            if candidate['item_key'] != source:
                continue
            data = candidate.get('option_values')
            if isinstance(data, dict):
                codes = [o['code'] for o in data.get('options', [])]
                return [c for c in codes if c not in ('UNDECIDED', 'NOT_DECIDED')]
    return None


def _validate_composite_field(name: str, field: dict, value, items) -> None:
    kind = field.get('type')
    if kind == 'ENUM':
        if not isinstance(value, str) or value not in (field.get('values') or []):
            raise M2ValidationError(f'Field {name} must be one of the registered values.')
        return
    if kind == 'TEXT':
        limit = int(field.get('max_length') or 4000)
        if not isinstance(value, str) or not value.strip() or len(value) > limit:
            raise M2ValidationError(f'Field {name} must be text of 1-{limit} characters.')
        return
    if kind == 'AMOUNT_MYR':
        # Stored as a canonical decimal string so no float rounding is introduced.
        import re as _re
        if isinstance(value, bool) or not isinstance(value, (str, int, float)):
            raise M2ValidationError(f'Field {name} must be an MYR amount.')
        text = str(value).strip()
        if not _re.fullmatch(r'\d{1,9}(\.\d{1,2})?', text):
            raise M2ValidationError(f'Field {name} must be a non-negative amount with at most two decimals.')
        return
    if kind == 'MULTI':
        if not isinstance(value, list) or not value:
            raise M2ValidationError(f'Field {name} must be a non-empty list.')
        if len(value) != len(set(map(str, value))):
            raise M2ValidationError(f'Field {name} must not repeat a value.')
        allowed = _field_values(field, items)
        if allowed is not None and not all(isinstance(v, str) and v in allowed for v in value):
            raise M2ValidationError(f'Field {name} contains an unregistered value.')
        return
    if kind == 'LIST':
        if not isinstance(value, list) or not value:
            raise M2ValidationError(f'Field {name} must be a non-empty list.')
        sub_fields = field.get('item_fields') or []
        declared = {f['name'] for f in sub_fields}
        for entry in value:
            if not isinstance(entry, dict):
                raise M2ValidationError(f'Field {name} entries must be objects.')
            if set(entry) - declared:
                raise M2ValidationError(f'Field {name} entry contains undeclared fields.')
            for sub in sub_fields:
                present = sub['name'] in entry and entry[sub['name']] not in (None, '', [])
                if sub.get('required') and not present:
                    raise M2ValidationError(f'Field {name}.{sub["name"]} is required.')
                if present:
                    _validate_composite_field(f'{name}.{sub["name"]}', sub,
                                              entry[sub['name']], items)
        return
    raise M2ValidationError('Unknown structured field type; fail closed.')


def _validate_composite(item: dict, value, items=None) -> None:
    """Validate a structured response against the item's declared value_schema.

    Structured selections and free text travel in one answer revision, so a
    single revision id covers both without splitting provenance.
    """
    data = item.get('option_values')
    schema = (data.get('value_schema') if isinstance(data, dict) else None) or {}
    fields = schema.get('fields') or []
    if not fields:
        raise M2ValidationError('This item declares no structured schema; fail closed.')
    if not isinstance(value, dict):
        raise M2ValidationError('A structured response must be an object.')
    declared = {f['name']: f for f in fields}
    if set(value) - set(declared):
        raise M2ValidationError('Response contains fields not declared by this item version.')
    for name, field in declared.items():
        present = name in value and value[name] not in (None, '', [])
        if field.get('required') and not present:
            raise M2ValidationError(f'Field {name} is required.')
        if present:
            _validate_composite_field(name, field, value[name], items)
    for rule in schema.get('conditional_required') or []:
        if _condition_met(rule.get('when') or {}, value):
            target = rule['field']
            if target not in value or value[target] in (None, '', []):
                raise M2ValidationError(f'Field {target} is required for this response.')


def validate_m2_answer(item: dict, state: str, value: object, items=None) -> None:
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
    # An OPTIONAL item that declares NOT_APPLICABLE may be marked so explicitly
    # even when no conditional rule forces it. In M2V1 the only such item is
    # M2V1-07, so this generalisation preserves V1 behaviour exactly while
    # removing the hard-coded instrument key.
    optional_not_applicable = (item['requiredness'] == 'OPTIONAL'
                               and 'NOT_APPLICABLE' in item['allowed_states'])
    if (isinstance(data, dict) and state == 'NOT_APPLICABLE'
            and item.get('applicable') is not False and not optional_not_applicable):
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
    elif kind == "COMPOSITE":
        _validate_composite(item, value, items)
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
