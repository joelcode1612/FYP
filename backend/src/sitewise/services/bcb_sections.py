"""Deterministic three-part Business Context for the M2 V2 instrument.

Produces the three separately identifiable outputs required for Phase 2:

``business_description``
    Confirmed entrepreneur-declared café characteristics.
``research_context``
    Declared assumptions, uncertainties, research intentions and source
    references.
``questionnaire_stimuli``
    Structured product, price, service, feature and segment inputs.

Rules enforced here:

* Nothing is inferred. Every field is copied from a confirmed declaration.
* Free text is preserved byte-for-byte: no trimming, case folding or repair.
* Every field carries ``item_key``, ``item_version_id``,
  ``answer_revision_id`` and ``confirmation_id`` so it is traceable to its exact
  source answer.
* An answer state that carries no value (UNDECIDED, NOT_PROVIDED,
  SKIPPED_OPTIONAL, NOT_APPLICABLE) is recorded as an uncertainty, never
  promoted into a value.
* No model, provider or LLM is consulted.
"""
from __future__ import annotations

from sitewise.modules.decision_engine.domain.geo_catalogue import area_label as geo_area_label

SECTION_CONTRACT = "bcb-sections/1"

#: M2V2-09 substantive topics map one-to-one onto the mandatory objectives.
#: A declared priority orders the work; it never removes an objective.
OBJECTIVE_BY_TOPIC = {
    "CONCEPT_INTEREST": "O1",
    "PRODUCT_PREFERENCE": "O2",
    "PRICE_ACCEPTABILITY": "O3",
    "SERVICE_PREFERENCE": "O4",
    "EXPERIENCE_PREFERENCE": "O5",
    "SEGMENT_INTEREST": "O6",
}
MANDATORY_OBJECTIVES = ("O1", "O2", "O3", "O4", "O5", "O6")

#: States that declare an absence of content rather than a value.
VALUELESS_STATES = frozenset({"UNDECIDED", "NOT_PROVIDED",
                              "SKIPPED_OPTIONAL", "NOT_APPLICABLE"})


def _labels(item: dict | None) -> dict:
    if not item:
        return {}
    data = item.get("option_values")
    if not isinstance(data, dict):
        return {}
    return {o["code"]: o["label"] for o in data.get("options", [])}


def _ref(declaration: dict, confirmation_id: str) -> dict:
    """Trace reference for one confirmed source answer."""
    return {
        "item_key": declaration["item_key"],
        "item_version_id": declaration["item_version_id"],
        "answer_revision_id": declaration["answer_revision_id"],
        "confirmation_id": confirmation_id,
        "answer_state": declaration["answer_state"],
        "source_hash": declaration["source_hash"],
    }


def _field(declaration: dict | None, confirmation_id: str, item: dict | None,
           *, key: str | None = None) -> dict | None:
    """One traceable field, or None when the answer carries no value."""
    if declaration is None or declaration["answer_state"] in VALUELESS_STATES:
        return None
    value = declaration["value"]
    labels = _labels(item)
    out = {"value": value, "ref": _ref(declaration, confirmation_id)}
    if key is not None:
        out["item_key"] = key
    if isinstance(value, str) and value in labels:
        out["label"] = labels[value]
    elif isinstance(value, dict):
        # DD-063: a GEO answer is {jurisdiction, area_ref, catalogue_version}.
        # Its label is the catalogue's own jurisdiction name, resolved from the
        # authority — the instrument's option codes (JOHOR, PENANG, ...) are not
        # carried inside the structured value, so they cannot be looked up here.
        area = geo_area_label(value)
        if area:
            out["label"] = area
    elif isinstance(value, list):
        out["labels"] = [labels.get(v, v) for v in value]
    return out


def _absent(declaration: dict | None, key: str, confirmation_id: str,
            item: dict | None) -> dict | None:
    """Record a valueless answer as an explicit uncertainty entry."""
    if declaration is None:
        return {"item_key": key, "reason": "ANSWER_ABSENT"}
    if declaration["answer_state"] in VALUELESS_STATES:
        entry = {"item_key": key, "reason": declaration["answer_state"],
                 "ref": _ref(declaration, confirmation_id)}
        return entry
    return None


def _business_description(by_key, item_map, confirmation_id, unmapped):
    def f(key, *, field_key=None):
        return _field(by_key.get(key), confirmation_id, item_map.get(key),
                      key=field_key)

    description = {
        "study_area": f("M2V2-01"),
        "service_format": f("M2V2-02"),
        "product_categories": f("M2V2-03"),
        "customer_groups": f("M2V2-04"),
        "primary_customer_group": f("M2V2-05"),
        "concept_emphasis": f("M2V2-06"),
        "customer_occasion": f("M2V2-07"),
        "offered_service_formats": f("M2V2-15"),
        "business_stage": f("M2V2-19"),
    }
    # Concept review contributes a title/details only when the entrepreneur
    # supplied them. A CONFIRMED verdict is not itself a café characteristic.
    review = by_key.get("M2V2-12")
    if review is not None and review["answer_state"] == "ANSWERED":
        value = review["value"] or {}
        for name, source in (("concept_title", "title"),
                             ("concept_details", "details")):
            if isinstance(value.get(source), str) and value[source].strip():
                description[name] = {
                    "value": value[source],
                    "ref": _ref(review, confirmation_id),
                    "item_key": "M2V2-12",
                }
    if review is not None and review["answer_state"] == "ANSWERED":
        description["concept_review_status"] = {
            "value": (review["value"] or {}).get("review_status"),
            "ref": _ref(review, confirmation_id),
            "item_key": "M2V2-12",
        }
    return {k: v for k, v in description.items() if v is not None}


def _research_context(by_key, item_map, confirmation_id, *, include_topic_refs=True):
    uncertainties = []
    for key in ("M2V2-01", "M2V2-02", "M2V2-03", "M2V2-04", "M2V2-05",
                "M2V2-06", "M2V2-07", "M2V2-08", "M2V2-09", "M2V2-10",
                "M2V2-11", "M2V2-13", "M2V2-16", "M2V2-17", "M2V2-19"):
        entry = _absent(by_key.get(key), key, confirmation_id, item_map.get(key))
        if entry:
            uncertainties.append(entry)

    assumptions = []
    hypothesis = by_key.get("M2V2-18")
    if hypothesis is not None and hypothesis["answer_state"] == "ANSWERED":
        value = hypothesis["value"] or {}
        status = value.get("hypothesis_status")
        entry = {
            "item_key": "M2V2-18",
            "hypothesis_status": status,
            "ref": _ref(hypothesis, confirmation_id),
            # A hypothesis is a declared belief, never an established fact.
            "evidence_class": "ENTREPRENEUR_HYPOTHESIS",
            "facts_independently_verified": False,
        }
        if status == "HYPOTHESIS_IDENTIFIED":
            entry["hypothesis_text"] = value.get("hypothesis_text")
        assumptions.append(entry)

    # Price absence is an uncertainty, not a zero or an inferred amount.
    offer = by_key.get("M2V2-14")
    price_uncertain = None
    if offer is not None and offer["answer_state"] == "ANSWERED":
        value = offer["value"] or {}
        if value.get("decision") == "PRICE_NOT_DECIDED":
            price_uncertain = {"item_key": "M2V2-14",
                               "reason": "PRICE_NOT_DECIDED",
                               "ref": _ref(offer, confirmation_id)}

    topics_declaration = by_key.get("M2V2-09")
    topics = []
    if topics_declaration is not None and topics_declaration["answer_state"] == "ANSWERED":
        selected = topics_declaration["value"] or []
        for code in selected:
            if code in OBJECTIVE_BY_TOPIC:
                topic = {"topic": code, "objective": OBJECTIVE_BY_TOPIC[code]}
                # Added in the 1.2.1 projection. The frozen 1.2.0 shape must not
                # carry it, or packets persisted under that label stop rebuilding
                # byte-identically and become unreadable.
                if include_topic_refs:
                    topic["ref"] = _ref(topics_declaration, confirmation_id)
                topics.append(topic)
    declared_objectives = {t["objective"] for t in topics}

    priority_declaration = by_key.get("M2V2-10")
    priority = None
    if priority_declaration is not None and priority_declaration["answer_state"] == "ANSWERED":
        priority = {"topic": priority_declaration["value"],
                    "objective": OBJECTIVE_BY_TOPIC.get(priority_declaration["value"]),
                    "ref": _ref(priority_declaration, confirmation_id)}

    decision_declaration = by_key.get("M2V2-11")
    decision = None
    if decision_declaration is not None and decision_declaration["answer_state"] == "ANSWERED":
        decision = {"status": decision_declaration["value"],
                    "ref": _ref(decision_declaration, confirmation_id)}

    sources_declaration = by_key.get("M2V2-08")
    sources = None
    if sources_declaration is not None and sources_declaration["answer_state"] == "ANSWERED":
        sources = {"declared": sources_declaration["value"],
                   "ref": _ref(sources_declaration, confirmation_id),
                   "evidence_class": "ENTREPRENEUR_DECLARED",
                   "facts_independently_verified": False}

    return {
        "assumptions": assumptions,
        "uncertainties": uncertainties,
        "price_uncertainty": price_uncertain,
        "research_intentions": {
            "topics": topics,
            "declared_objectives": sorted(declared_objectives),
            # A priority reorders the work; it never disables an objective.
            "priority": priority,
            "priority_is_ordering_only": True,
            "decision_status": decision,
        },
        "mandatory_objectives": {
            "objectives": list(MANDATORY_OBJECTIVES),
            "declared": sorted(declared_objectives),
            "undeclared": sorted(set(MANDATORY_OBJECTIVES) - declared_objectives),
            # Declaring an intention is not evidence that an objective is met.
            "covered_by_approved_measure": [],
            "note": "Declaring a research topic does not establish objective coverage.",
        },
        "source_references": sources,
    }


def _questionnaire_stimuli(by_key, item_map, confirmation_id):
    stimuli = {"products": None, "price_offer": None, "service_formats": None,
               "experience_features": None, "customer_segments": None}

    menu = by_key.get("M2V2-13")
    if menu is not None and menu["answer_state"] == "ANSWERED":
        value = menu["value"] or {}
        stimuli["products"] = {
            "categories": value.get("categories"),
            "products": value.get("products") or [],
            "ref": _ref(menu, confirmation_id),
            "undecided": False,
        }
    elif menu is not None:
        stimuli["products"] = {"undecided": True,
                               "reason": menu["answer_state"],
                               "ref": _ref(menu, confirmation_id)}

    offer = by_key.get("M2V2-14")
    if offer is not None and offer["answer_state"] == "ANSWERED":
        value = offer["value"] or {}
        entry = {
            "decision": value.get("decision"),
            "ref": _ref(offer, confirmation_id),
        }
        if value.get("decision") == "PRICED":
            entry.update({
                "product_ref": value.get("product_ref"),
                "size_quantity": value.get("size_quantity"),
                # Kept as the canonical decimal string; no float conversion.
                "amount_myr": value.get("amount_myr"),
                "total_price_details": value.get("total_price_details"),
            })
        else:
            entry["amount_myr"] = None
            entry["price_fabricated"] = False
        stimuli["price_offer"] = entry

    formats = by_key.get("M2V2-15")
    if formats is not None and formats["answer_state"] == "ANSWERED":
        stimuli["service_formats"] = _field(formats, confirmation_id,
                                            item_map.get("M2V2-15"))

    features = by_key.get("M2V2-16")
    if features is not None and features["answer_state"] == "ANSWERED":
        value = features["value"] or {}
        stimuli["experience_features"] = {
            "features": value.get("features"),
            "other_feature_text": value.get("other_feature_text"),
            "ref": _ref(features, confirmation_id),
        }
    elif features is not None:
        stimuli["experience_features"] = {"undecided": True,
                                          "reason": features["answer_state"],
                                          "ref": _ref(features, confirmation_id)}

    segments = by_key.get("M2V2-17")
    if segments is not None and segments["answer_state"] == "ANSWERED":
        value = segments["value"] or {}
        stimuli["customer_segments"] = {
            "segments": value.get("segments") or [],
            "ref": _ref(segments, confirmation_id),
        }
    elif segments is not None:
        stimuli["customer_segments"] = {"undecided": True,
                                        "reason": segments["answer_state"],
                                        "ref": _ref(segments, confirmation_id)}

    return stimuli


def build_sections(declarations: list[dict], item_map: dict, confirmation_id: str,
                   *, include_topic_refs: bool = True) -> dict:
    """Build the three separable outputs from confirmed declarations only.

    ``include_topic_refs`` selects the projection shape, not a preference: the
    frozen ``BCB-V1-1.2.0`` contract omits per-topic refs and must keep doing so,
    while ``BCB-V1-1.2.1`` adds them. Callers derive the flag from the contract
    version recorded on the packet.
    """
    by_key = {d["item_key"]: d for d in declarations}
    unmapped = sorted(k for k in by_key if k not in item_map)
    sections = {
        "contract": SECTION_CONTRACT,
        "business_description": _business_description(by_key, item_map,
                                                      confirmation_id, unmapped),
        "research_context": _research_context(by_key, item_map, confirmation_id,
                                              include_topic_refs=include_topic_refs),
        "questionnaire_stimuli": _questionnaire_stimuli(by_key, item_map,
                                                        confirmation_id),
        "unmapped_item_keys": unmapped,
        "deterministic": True,
        "model_invoked": False,
    }
    return sections


def render_description_text(rows: list[dict], item_map: dict) -> str | None:
    """Deterministic prose description from confirmed M2 V2 answers.

    Used where the context bindings need a single authoritative description
    string. It restates declared values only: no inference, no model, and no
    placeholder text when nothing was declared.
    """
    by = {r["item_key"]: r for r in rows if r.get("answer_state") == "ANSWERED"}
    if not by:
        return None

    def single(key):
        value = (by.get(key) or {}).get("value")
        if not isinstance(value, str):
            return None
        return _labels(item_map.get(key)).get(value, value)

    def many(key):
        value = (by.get(key) or {}).get("value")
        if not isinstance(value, list):
            return None
        labels = _labels(item_map.get(key))
        return ", ".join(labels.get(v, v) for v in value) or None

    sentences = []
    service, categories = single("M2V2-02"), many("M2V2-03")
    groups, emphasis = many("M2V2-04"), single("M2V2-06")
    head = "The entrepreneur plans to establish a café"
    if service:
        head += f" with a {service} service model"
    sentences.append(head + ".")
    if categories:
        sentences.append(f"Planned product categories: {categories}.")
    if groups:
        sentences.append(f"Intended customer groups: {groups}.")
    if emphasis:
        sentences.append(f"Planned emphasis: {emphasis}.")

    stage = ((by.get("M2V2-19") or {}).get("value") or {})
    if isinstance(stage, dict) and isinstance(stage.get("stage"), str):
        sentences.append(f"Declared business stage: {stage['stage']}.")

    review = ((by.get("M2V2-12") or {}).get("value") or {})
    if isinstance(review, dict) and isinstance(review.get("details"), str) \
            and review["details"].strip():
        sentences.append(f"Entrepreneur note: {review['details']}")

    return " ".join(sentences).strip() or None
