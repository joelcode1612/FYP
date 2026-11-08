"""Pure, draft-stage M2 answer rules. No framework/ORM imports."""

class M2ValidationError(ValueError):
    pass


def validate_m2_answer(item: dict, state: str, value: object) -> None:
    """Validate against the exact DB-backed item definition, never guessed options."""
    if item["lifecycle"] != "ACTIVE" or item["answer_kind"] == "ACTION":
        raise M2ValidationError("This item does not accept an answer in this instrument version.")
    if state not in item["allowed_states"]:
        raise M2ValidationError("Response state not allowed for this item version.")
    if state != "ANSWERED":
        if value is not None:
            raise M2ValidationError("Non-substantive responses cannot contain substantive values.")
        return
    kind = item["answer_kind"]
    options = item["option_values"]
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
    elif kind == "TEXT":
        if not isinstance(value, str) or not value.strip() or len(value) > 4000:
            raise M2ValidationError("Text response must contain 1–4000 characters.")
    else:
        raise M2ValidationError("Unknown response kind; fail closed.")


def missing_required_items(items: list[dict], latest_answers: dict[str, dict]) -> list[str]:
    """Requiredness is instrument-version data; no hardcoded 18/21 field assumption."""
    missing = []
    for item in items:
        if item["lifecycle"] != "ACTIVE" or item["answer_kind"] == "ACTION":
            continue
        if item["requiredness"] not in {"REQUIRED"}:
            continue
        answer = latest_answers.get(item["item_key"])
        if answer is None or answer["answer_state"] not in item["allowed_states"]:
            missing.append(item["item_key"])
        elif answer["answer_state"] in {"NOT_PROVIDED", "SKIPPED_OPTIONAL"}:
            missing.append(item["item_key"])
    return missing
