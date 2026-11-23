"""Deterministic draft concept preview for M2 V2, before confirmation.

The preview exists so an entrepreneur can read the café concept the questionnaire
has produced *before* performing the M2-21 confirmation, and correct the
underlying answers rather than a separate declaration.

Consistency with the confirmed Business Context Builder is structural, not
aspirational: the preview calls the same ``build_sections`` projection and the
same ``render_description_text`` prose renderer that the confirmed packet uses.
The only deliberate difference is ``confirmation_id=None`` on every reference,
which is how a consumer tells a draft projection from a confirmed one.

Nothing here writes. No confirmation snapshot is created, no BCB is persisted,
no model is invoked, and no value is inferred.
"""
from __future__ import annotations

from sitewise.services.bcb_sections import build_sections, render_description_text
from sitewise.services.business_context_v1 import source_hash

CONTRACT = "m2-concept-preview/1"

#: Answer states that carry no value; they are surfaced as explicit gaps rather
#: than omitted, so a reader can tell "not decided" from "not asked".
_UNDECIDED_STATES = frozenset({"UNDECIDED"})
_SKIPPED_STATES = frozenset({"NOT_PROVIDED", "SKIPPED_OPTIONAL"})
_NOT_APPLICABLE_STATES = frozenset({"NOT_APPLICABLE"})


def _declares_undecided(value) -> bool:
    """True when an ANSWERED value still says "not decided".

    The instrument expresses undecided-ness two ways: a whole-answer
    ``UNDECIDED`` state, and an answered value that is itself the sentinel
    ``UNDECIDED`` / ``NOT_DECIDED`` or carries ``undecided: true`` or
    ``decision: PRICE_NOT_DECIDED``. Both must be reported, or the UI would
    present a decided-looking card over an explicit non-decision.
    """
    if isinstance(value, str):
        return value in {"UNDECIDED", "NOT_DECIDED", "PRICE_NOT_DECIDED"}
    if isinstance(value, dict):
        if value.get("undecided") is True:
            return True
        return any(_declares_undecided(v) for v in value.values())
    if isinstance(value, list):
        return any(_declares_undecided(v) for v in value)
    return False


def _declarations(items: list[dict], answers: dict[str, dict],
                  instrument: dict) -> tuple[list[dict], dict[str, dict]]:
    """Build declaration rows with the same provenance the confirmed path uses."""
    item_map = {i["item_key"]: i for i in items}
    rows: list[dict] = []
    for key in sorted(answers):
        answer = answers[key]
        item = item_map.get(key)
        if item is None:
            continue
        rows.append({
            "item_key": key,
            "answer_revision_id": str(answer["id"]),
            "item_version_id": str(answer["item_version_id"]),
            "answer_state": answer["answer_state"],
            "value": answer["value_json"],
            "question": item["question_text"],
            "question_version": item["id"],
            "response_version": str(answer["id"]),
            "codebook_version": instrument["schema_digest"],
            "codebook_hash": source_hash({k: item[k] for k in
                                          ("id", "answer_kind", "option_values",
                                           "allowed_states")}),
            "question_definition_hash": source_hash(item),
            "source_hash": source_hash(answer),
            "evidence_class": "ENTREPRENEUR_DECLARED",
            "facts_independently_verified": False,
        })
    return rows, item_map


def build_concept_preview(assessment: dict, instrument: dict, items: list[dict],
                          answers: dict[str, dict]) -> dict:
    """Return the draft preview envelope for one assessment revision."""
    declarations, item_map = _declarations(items, answers, instrument)

    # ``confirmation_id=None`` is intentional: no confirmation exists for a
    # draft, and inventing one would misrepresent the provenance.
    sections = build_sections(declarations, item_map, None)
    description = sections["business_description"]
    text = render_description_text(declarations, item_map)

    undecided = sorted(
        d["item_key"] for d in declarations
        if d["answer_state"] in _UNDECIDED_STATES
        or (d["answer_state"] == "ANSWERED" and _declares_undecided(d["value"])))
    skipped = sorted(d["item_key"] for d in declarations
                     if d["answer_state"] in _SKIPPED_STATES)
    not_applicable = sorted(d["item_key"] for d in declarations
                            if d["answer_state"] in _NOT_APPLICABLE_STATES)
    never_answered = [
        key for key, item in sorted(item_map.items())
        if item["lifecycle"] == "ACTIVE" and item["answer_kind"] != "ACTION"
        and key not in answers
    ]

    return {
        "contract_version": CONTRACT,
        "status": "DRAFT_PREVIEW",
        "assessment_id": str(assessment["id"]),
        "instrument": {k: instrument[k] for k in
                       ("id", "version_tag", "schema_digest", "approval_state")},
        "assessment_revision": assessment["revision"],
        "confirmed_revision": assessment["confirmed_revision"],
        "preview_text": text,
        "description": description,
        "sources": [
            {"item_key": d["item_key"],
             "item_version_id": d["item_version_id"],
             "answer_revision_id": d["answer_revision_id"],
             "answer_state": d["answer_state"]}
            for d in declarations
        ],
        # Explicit gaps, each kind separately. "Not decided" is a decision the
        # entrepreneur made and must never be presented as a missing answer.
        "undecided_inputs": undecided,
        "skipped_inputs": skipped,
        "not_applicable_inputs": not_applicable,
        "absent_inputs": never_answered,
        "missing_inputs": sorted(set(undecided) | set(skipped) | set(never_answered)),
        "unmapped_item_keys": sections.get("unmapped_item_keys") or [],
        "creates_confirmation": False,
        "creates_business_context": False,
        "model_invoked": False,
        "deterministic": True,
    }
