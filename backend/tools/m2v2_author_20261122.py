"""Author the M2 V2 candidate instrument definition from the V1 source of record.

Derivation is deliberate and auditable:

* M2V2-01..11 are produced by re-keying the *live, adopted* M2V1 definition, so
  the retained business semantics cannot drift by retyping. Only ``item_key``
  and the cross-item rule references are rewritten.
* M2V2-12..19 are declared explicitly here, matching the Owner direction
  captured verbatim in ``instruments/m2v2_20261122/source.txt``.

This script only writes a JSON artefact. It never touches a database and never
registers an instrument. Registration is a separate, guarded step.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
V1 = BACKEND / "src/sitewise/instruments/m2v1_20261114"
V2 = BACKEND / "src/sitewise/instruments/m2v2_20261122"

VERSION_TAG = "M2V2-20261122-1"
CODE = "M2V2"


def rekey(value, mapping):
    """Rewrite M2V1-NN references to M2V2-NN inside nested rule structures."""
    if isinstance(value, str):
        return mapping.get(value, value)
    if isinstance(value, list):
        return [rekey(v, mapping) for v in value]
    if isinstance(value, dict):
        return {k: rekey(v, mapping) for k, v in value.items()}
    return value


def retained_items(v1_items):
    mapping = {f"M2V1-{i:02d}": f"M2V2-{i:02d}" for i in range(1, 12)}
    out = []
    for item in v1_items:
        if item["item_key"] not in mapping:
            continue  # M2-20 / M2-21 are governance actions, not re-keyed
        item = json.loads(json.dumps(item))  # deep copy
        item["item_key"] = mapping[item["item_key"]]
        item["option_values"] = rekey(item["option_values"], mapping)
        out.append(item)
    return out


def composite(fields, conditional=()):
    schema = {"contract": "m2-composite/1", "fields": list(fields)}
    if conditional:
        schema["conditional_required"] = list(conditional)
    return schema


def new_items():
    items = []

    items.append({
        "item_key": "M2V2-12",
        "title": "Café Concept Review",
        "question_text": ("Review the generated café concept card. Confirm it, "
                          "or tell us what needs correcting."),
        "requiredness": "REQUIRED",
        "answer_kind": "COMPOSITE",
        "option_values": {
            "contract": "m2-item-options/1",
            "options": [],
            "rules": {
                # The card is computed from already-saved answers and shown
                # before confirmation. It is NOT stored as an answer, so it
                # cannot depend on its own confirmation (no circular binding).
                "concept_preview": {
                    "source": "CONFIRMED_OR_DRAFT_M2_ANSWERS",
                    "deterministic": True,
                    "persisted_as_answer": False,
                    "derived_from": [f"M2V2-{i:02d}" for i in range(1, 12)],
                }
            },
            "source_rules": [
                "Rule: the concept preview is deterministic and is never stored "
                "as an answer. The finalised BCB is derived only from the "
                "subsequently confirmed revision.",
            ],
            "value_schema": composite(
                fields=[
                    {"name": "review_status", "type": "ENUM", "required": True,
                     "values": ["CONFIRMED", "NEEDS_CORRECTION", "NOT_READY"]},
                    {"name": "title", "type": "TEXT", "required": False, "max_length": 200},
                    {"name": "details", "type": "TEXT", "required": False, "max_length": 4000},
                ],
                conditional=[
                    # A correction or a not-ready verdict must say what is wrong.
                    {"field": "details", "when": {"field": "review_status",
                                                  "in": ["NEEDS_CORRECTION", "NOT_READY"]}},
                ],
            ),
        },
        "allowed_states": ["ANSWERED", "NOT_PROVIDED"],
        "lifecycle": "ACTIVE",
        "sort_order": 11,
    })

    items.append({
        "item_key": "M2V2-13",
        "title": "Specific Products and Menu",
        "question_text": ("List the specific products you plan to sell, within the "
                          "categories you selected."),
        "requiredness": "REQUIRED",
        "answer_kind": "COMPOSITE",
        "option_values": {
            "contract": "m2-item-options/1",
            "options": [],
            # Advisory only, not a ``source_item``: the menu must stay
            # answerable (including explicit UNDECIDED) while M2V2-03 is still
            # undecided. The category domain is enforced by values_from below.
            "rules": {"category_domain_from": "M2V2-03"},
            "source_rules": [
                "Rule: product categories are governed by M2V2-03. Product names "
                "are only requested for categories the entrepreneur actually "
                "selected. Undecided is a valid explicit answer.",
            ],
            "value_schema": composite(
                fields=[
                    {"name": "categories", "type": "MULTI", "required": True,
                     "values_from": "M2V2-03"},
                    {"name": "products", "type": "LIST", "required": False,
                     "item_fields": [
                         {"name": "name", "type": "TEXT", "required": True, "max_length": 200},
                         {"name": "category", "type": "TEXT", "required": False, "max_length": 64},
                         {"name": "description", "type": "TEXT", "required": False, "max_length": 1000},
                     ]},
                ],
                conditional=[
                    {"field": "products", "when": {"field": "categories", "non_empty": True}},
                ],
            ),
        },
        "allowed_states": ["ANSWERED", "NOT_PROVIDED", "UNDECIDED"],
        "lifecycle": "ACTIVE",
        "sort_order": 12,
    })

    items.append({
        "item_key": "M2V2-14",
        "title": "Exact Priced Offer",
        "question_text": ("Do you have one exact priced offer you want tested? "
                          "Give the product, size, and price."),
        "requiredness": "REQUIRED",
        "answer_kind": "COMPOSITE",
        "option_values": {
            "contract": "m2-item-options/1",
            "options": [],
            # Not a ``source_item``: M2V2-14 must stay answerable even when the
            # menu in M2V2-13 is undecided, because PRICE_NOT_DECIDED has to be
            # a valid confirmation answer. The reference is advisory only.
            "rules": {"product_reference_from": "M2V2-13"},
            "source_rules": [
                "Rule: an exact price is never required to confirm M2. "
                "PRICE_NOT_DECIDED is a valid answer and must not be fabricated "
                "into an amount.",
            ],
            "value_schema": composite(
                fields=[
                    {"name": "decision", "type": "ENUM", "required": True,
                     "values": ["PRICED", "PRICE_NOT_DECIDED"]},
                    {"name": "product_ref", "type": "TEXT", "required": False, "max_length": 200},
                    {"name": "size_quantity", "type": "TEXT", "required": False, "max_length": 100},
                    {"name": "amount_myr", "type": "AMOUNT_MYR", "required": False},
                    {"name": "total_price_details", "type": "TEXT", "required": False, "max_length": 1000},
                ],
                conditional=[
                    {"field": "product_ref", "when": {"field": "decision", "equals": "PRICED"}},
                    {"field": "size_quantity", "when": {"field": "decision", "equals": "PRICED"}},
                    {"field": "amount_myr", "when": {"field": "decision", "equals": "PRICED"}},
                ],
            ),
        },
        "allowed_states": ["ANSWERED", "NOT_PROVIDED"],
        "lifecycle": "ACTIVE",
        "sort_order": 13,
    })

    items.append({
        "item_key": "M2V2-15",
        "title": "Offered Service Formats",
        "question_text": "Which service formats will your café actually offer?",
        "requiredness": "REQUIRED",
        "answer_kind": "MULTI",
        "option_values": {
            "contract": "m2-item-options/1",
            "options": [
                {"code": "DINE_IN", "label": "Dine-in"},
                {"code": "TAKEAWAY", "label": "Takeaway"},
                {"code": "DELIVERY", "label": "Delivery"},
                {"code": "NOT_DECIDED", "label": "I have not decided which formats to offer"},
            ],
            "rules": {"exclusive": ["NOT_DECIDED"]},
            "source_rules": [
                "Rule: NOT_DECIDED cannot be combined with other selections.",
                "Rule: this asks which formats will be offered, not the single "
                "intended concept format asked in M2V2-02.",
            ],
        },
        "allowed_states": ["ANSWERED", "NOT_PROVIDED"],
        "lifecycle": "ACTIVE",
        "sort_order": 14,
    })

    items.append({
        "item_key": "M2V2-16",
        "title": "Café Experience Features",
        "question_text": ("Which experience features will your café provide? "
                          "Select all that apply."),
        "requiredness": "REQUIRED",
        "answer_kind": "COMPOSITE",
        "option_values": {
            "contract": "m2-item-options/1",
            "options": [],
            "rules": {"governed_feature_bank": "PENDING_APPROVAL"},
            "source_rules": [
                "Rule: feature selections are governed. The feature bank is not "
                "yet approved, so only the declared codes below are accepted.",
                "Rule: other-feature text is required only when OTHER is selected.",
            ],
            "value_schema": composite(
                fields=[
                    {"name": "features", "type": "MULTI", "required": True,
                     "values": ["QUIET_WORK_SPACE", "SOCIAL_SEATING",
                                "OUTDOOR_SEATING", "SPECIALTY_EQUIPMENT",
                                "RETAIL_BEANS", "OTHER"]},
                    {"name": "other_feature_text", "type": "TEXT", "required": False,
                     "max_length": 500},
                ],
                conditional=[
                    {"field": "other_feature_text",
                     "when": {"field": "features", "contains": "OTHER"}},
                ],
            ),
        },
        "allowed_states": ["ANSWERED", "NOT_PROVIDED", "UNDECIDED"],
        "lifecycle": "ACTIVE",
        "sort_order": 15,
    })

    items.append({
        "item_key": "M2V2-17",
        "title": "Customer Segment Definitions",
        "question_text": ("In your own words, how would you define each customer "
                          "group you selected?"),
        "requiredness": "REQUIRED",
        "answer_kind": "COMPOSITE",
        "option_values": {
            "contract": "m2-item-options/1",
            "options": [],
            "rules": {
                "source_item": "M2V2-04",
                "exclude": ["UNDECIDED", "OTHER_UNLISTED"],
            },
            "source_rules": [
                "Rule: segments are limited to the groups selected in M2V2-04. "
                "This asks for the entrepreneur's own definition of each "
                "segment, which is a different question from group selection.",
                "Rule: descriptions are optional. Undecided is a valid explicit answer.",
            ],
            "value_schema": composite(
                fields=[
                    {"name": "segments", "type": "LIST", "required": True,
                     "item_fields": [
                         {"name": "group", "type": "TEXT", "required": True, "max_length": 64},
                         {"name": "description", "type": "TEXT", "required": False,
                          "max_length": 1000},
                     ]},
                ],
            ),
        },
        "allowed_states": ["ANSWERED", "NOT_PROVIDED", "UNDECIDED", "NOT_APPLICABLE"],
        "lifecycle": "ACTIVE",
        "sort_order": 16,
    })

    items.append({
        "item_key": "M2V2-18",
        "title": "Customer Needs / Jobs / Problems",
        "question_text": ("Do you have a specific hypothesis about a customer need, "
                          "job or problem your café would address?"),
        "requiredness": "OPTIONAL",
        "answer_kind": "COMPOSITE",
        "option_values": {
            "contract": "m2-item-options/1",
            "options": [],
            "rules": {},
            "source_rules": [
                "Rule: this item is optional. An unanswered or not-established "
                "hypothesis is a valid outcome and is never treated as a defect.",
                "Rule: hypothesis text is required only when HYPOTHESIS_IDENTIFIED.",
            ],
            "value_schema": composite(
                fields=[
                    {"name": "hypothesis_status", "type": "ENUM", "required": True,
                     "values": ["HYPOTHESIS_IDENTIFIED", "NOT_ESTABLISHED",
                                "NO_SPECIFIC_PROBLEM"]},
                    {"name": "hypothesis_text", "type": "TEXT", "required": False,
                     "max_length": 2000},
                ],
                conditional=[
                    {"field": "hypothesis_text",
                     "when": {"field": "hypothesis_status",
                              "equals": "HYPOTHESIS_IDENTIFIED"}},
                ],
            ),
        },
        "allowed_states": ["ANSWERED", "NOT_PROVIDED", "SKIPPED_OPTIONAL"],
        "lifecycle": "ACTIVE",
        "sort_order": 17,
    })

    items.append({
        "item_key": "M2V2-19",
        "title": "Business Stage and Research Decision",
        "question_text": "What stage is your café business at right now?",
        "requiredness": "REQUIRED",
        "answer_kind": "COMPOSITE",
        "option_values": {
            "contract": "m2-item-options/1",
            "options": [],
            "rules": {},
            "source_rules": [
                "Rule: UNSURE is a valid structured response and must not be "
                "treated as a missing answer.",
            ],
            "value_schema": composite(
                fields=[
                    {"name": "stage", "type": "ENUM", "required": True,
                     "values": ["IDEA", "PLANNING", "CONCEPT_TESTING",
                                "PRE_LAUNCH", "OPERATING", "UNSURE"]},
                    {"name": "decision_explanation", "type": "TEXT", "required": False,
                     "max_length": 2000},
                ],
            ),
        },
        "allowed_states": ["ANSWERED", "NOT_PROVIDED"],
        "lifecycle": "ACTIVE",
        "sort_order": 18,
    })

    return items


def build():
    v1 = json.loads((V1 / "definition.json").read_text(encoding="utf-8"))
    source_sha = hashlib.sha256((V2 / "source.txt").read_bytes()).hexdigest()
    items = retained_items(v1["items"]) + new_items()
    definition = {
        "code": CODE,
        "version_tag": VERSION_TAG,
        "source_sha256": source_sha,
        "adoption": {
            "scope": "Candidate instrument. Synthetic verification only.",
            "decision": ("Owner direction 2026-11-22: candidate implementation and "
                         "synthetic testing only. Not production activation."),
            "approval_state": "PROPOSED_NOT_AUTHORIZED",
            "customer_fielding_authorized": False,
            "scientific_review_status": "NOT_INDEPENDENTLY_VERIFIED",
            "supersedes": None,
            "retains": "M2V1-20261114-1",
        },
        "items": items,
    }
    keys = [q["item_key"] for q in items]
    expected = [f"M2V2-{i:02d}" for i in range(1, 20)]
    assert keys == expected, f"item keys must be M2V2-01..19, got {keys}"
    assert len(items) == 19
    return definition


def main():
    definition = build()
    target = V2 / "definition.json"
    target.write_text(json.dumps(definition, indent=2, ensure_ascii=False) + "\n",
                      encoding="utf-8")
    digest = hashlib.sha256(json.dumps(definition, sort_keys=True,
                                       ensure_ascii=False,
                                       separators=(",", ":")).encode()).hexdigest()
    print(json.dumps({
        "path": str(target.relative_to(BACKEND)),
        "items": len(definition["items"]),
        "item_keys": [q["item_key"] for q in definition["items"]],
        "source_sha256": definition["source_sha256"],
        "schema_digest": digest,
        "answer_kinds": sorted({q["answer_kind"] for q in definition["items"]}),
    }, indent=2))


if __name__ == "__main__":
    main()
