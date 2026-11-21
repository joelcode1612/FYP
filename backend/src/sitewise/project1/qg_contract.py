"""QG contract 2.0: generate a candidate from confirmed facts, not a measurement.

Why this module exists
----------------------
Contract 1.0 required a complete ``Measurement`` before QG could run. QJ used to
produce that measurement; when QJ was removed, the requirement became
unsatisfiable — eight of the eleven ``Measurement`` fields have no source in the
BCB packet, so the direct path could only ever refuse.

The defect was in the *contract*, not in the data. A question-generation stage
does not need an adopted measurement as input; it needs the facts the
entrepreneur actually confirmed, and it produces a *proposal* that a methodologist
and an entrepreneur then review. Conflating "what we know" with "what we propose"
is what made the input look incomplete.

So 2.0 splits the two halves explicitly:

* ``ConfirmedFacts`` — assembled from the hash-verified BCB packet. Every field
  here is something the entrepreneur confirmed or something the server derived
  from a confirmed record. QG may **read** these and may not add to them.
* ``QGCandidate`` — what the model proposes. Wording, construct interpretation,
  response coding, routing, reference period, denominator, limitations. Every
  field here is a **proposal**, never a confirmed fact and never a scientifically
  adopted measurement, no matter how plausible it looks.

The rule that keeps them apart is mechanical: **every number and every currency
amount in a drafted question must already appear in ``ConfirmedFacts``.** A model
that needs a price it was not given cannot invent one; it must abstain and name
the missing fact.

What is deliberately preserved from 1.0
---------------------------------------
* **F-01** — the uncertainty version is server-authored and must be echoed
  exactly; it is never taken from model output.
* **F-02** — the deterministic checks that apply to *any* candidate still run:
  parallel codes and labels, distinct codes, complete routing, a denominator
  built from declared codes, non-empty limitations, and no prohibited claim.
  What 2.0 drops is only the requirement that the input already be complete.
* **D-01** — currency amounts are compared as whole tokens, so RM13 cannot
  become RM12 just because "12 oz" already contains the digits.

Historical records are untouched: ``Measurement`` and ``QGOutput`` keep their
shape and meaning, and 1.0 results remain readable as 1.0 results.
"""
from __future__ import annotations

import re

from pydantic import Field
from typing import Literal

from sitewise.project1.contracts import StrictModel, WorkflowHeld, digest

#: Identifies the contract, not a schema version. A consumer that expects 1.0
#: gets a distinguishable value rather than a differently-shaped object.
CONTRACT_VERSION = 'P1-QG-CONTRACT-2.0'

#: Field-authority labels. Every candidate field is reported with one of these so
#: a reader cannot mistake a proposal for a confirmed fact.
CONFIRMED = 'CONFIRMED'
PROPOSED = 'PROPOSED_NOT_CONFIRMED'

_CURRENCY = re.compile(r'RM\s?\d+(?:\.\d+)?', re.I)
_NUMBER = re.compile(r'\d+(?:\.\d+)?')
_CODE = re.compile(r'^[A-Z][A-Z0-9_]{0,63}$')

PROHIBITED_CLAIM_PATTERNS = (
    (r'\boptimum price\b', 'PROHIBITED_OPTIMUM_PRICE'),
    (r'\boptimal price\b', 'PROHIBITED_OPTIMUM_PRICE'),
    (r'\bwill (?:definitely )?purchase\b', 'PROHIBITED_PURCHASE_PREDICTION'),
    (r'\bforecast\b', 'PROHIBITED_FORECAST'),
    (r'\bwillingness[- ]to[- ]pay\b', 'PROHIBITED_WTP_CLAIM'),
    (r'\bprofitab', 'PROHIBITED_VIABILITY_CLAIM'),
    (r'\bviab(?:le|ility)\b', 'PROHIBITED_VIABILITY_CLAIM'),
    (r'\bdemand\b', 'PROHIBITED_DEMAND_CLAIM'),
    (r'\bmarket share\b', 'PROHIBITED_DEMAND_CLAIM'),
)

#: Facts a question may need but the packet cannot supply. Named so an abstention
#: is structured rather than free prose.
MISSING_FACT_CODES = (
    'PRICE', 'PRODUCT', 'PACKAGE_SIZE', 'SERVICE_FORMAT', 'POPULATION',
    'REFERENCE_PERIOD', 'LOCATION', 'OBJECTIVE', 'OTHER',
)


class ConfirmedFacts(StrictModel):
    """A. Everything QG is allowed to treat as true.

    Assembled only from the verified packet and the persisted objective. If a
    value is not here, QG does not know it.
    """

    contract_version: str = Field(default=CONTRACT_VERSION, min_length=1, max_length=64)
    assessment_id: str = Field(min_length=1, max_length=64)
    objective_id: str | None = Field(default=None, max_length=64)
    objective_text: str = Field(min_length=1, max_length=4000)
    uncertainty_id: str = Field(min_length=1, max_length=64)
    uncertainty_version: str = Field(min_length=1, max_length=128)
    uncertainty_text: str = Field(min_length=1, max_length=4000)
    bcb_version: str = Field(min_length=1, max_length=64)
    context_hash: str = Field(min_length=1, max_length=64)
    m2_answer_revision_ids: list[str] = Field(min_length=1, max_length=64)
    bdj_findings: list[dict] = Field(default_factory=list, max_length=20)
    #: Offer components stated in a confirmed source (e.g. "12 oz", "takeaway").
    confirmed_offers: list[str] = Field(default_factory=list, max_length=32)
    #: Every number the entrepreneur has confirmed, as written (e.g. "12", "13").
    confirmed_numbers: list[str] = Field(default_factory=list, max_length=64)
    #: Every currency amount confirmed, normalised without spaces ("RM13").
    confirmed_currency: list[str] = Field(default_factory=list, max_length=32)
    source_refs: list[str] = Field(min_length=1, max_length=64)

    @property
    def fingerprint(self) -> str:
        return digest(self.model_dump())


class QGCandidate(StrictModel):
    """B. What the model proposes. Nothing here is confirmed.

    The two decision values are the whole outcome space: either a candidate for
    entrepreneur review, or a justified abstention naming what is missing. There
    is no third state in which the model asserts the question is approved.
    """

    decision: Literal['DRAFT', 'ABSTAIN_NEEDS_REVIEW']
    question: str = Field(max_length=2000)
    justification: str = Field(min_length=1, max_length=1000)
    construct_interpretation: str = Field(max_length=1000, default='')
    response_options: list[str] = Field(default_factory=list, max_length=12)
    response_codes: list[str] = Field(default_factory=list, max_length=12)
    routing: dict[str, str] = Field(default_factory=dict)
    reference_period: str = Field(max_length=500, default='')
    measurement_description: str = Field(max_length=1000, default='')
    denominator_specification: str = Field(max_length=500, default='')
    limitations: str = Field(max_length=1000, default='')
    unresolved_assumptions: list[str] = Field(default_factory=list, max_length=12)
    missing_business_facts: list[str] = Field(default_factory=list, max_length=12)
    used_confirmed_facts: list[str] = Field(default_factory=list, max_length=32)


def _currency(text: str) -> set[str]:
    return {m.group(0).replace(' ', '').upper() for m in _CURRENCY.finditer(text or '')}


def _numbers(text: str) -> set[str]:
    return set(_NUMBER.findall(text or ''))


def facts_from_packet(packet: dict, *, objective=None, bdj_findings=(),
                      uncertainty_version: str | None = None) -> ConfirmedFacts:
    """Assemble ``ConfirmedFacts`` from a hash-verified BCB packet.

    Deliberately conservative: only the uncertainty text and M2 answer values are
    read for numbers and offers, because those are the only two places a
    confirmed business fact can live. Nothing is inferred, and a missing value
    produces an empty list rather than a guess.
    """
    uncertainty = packet.get('confirmed_uncertainty') or {}
    exact_text = uncertainty.get('exact_text') or ''
    if not exact_text.strip():
        raise WorkflowHeld('QG_CONFIRMED_UNCERTAINTY_TEXT_MISSING')

    texts = [exact_text]
    revision_ids: list[str] = []
    for answer in packet.get('m2_answers') or []:
        revision_id = answer.get('answer_revision_id')
        if revision_id:
            revision_ids.append(str(revision_id))
        for key in ('value', 'value_json'):
            value = answer.get(key)
            if isinstance(value, str):
                texts.append(value)
            elif isinstance(value, list):
                texts.extend(str(v) for v in value)
    for declaration in packet.get('declarations') or []:
        value = declaration.get('value')
        if isinstance(value, str):
            texts.append(value)
        elif isinstance(value, list):
            texts.extend(str(v) for v in value)
    if not revision_ids:
        raise WorkflowHeld('QG_CONFIRMED_FACTS_INCOMPLETE')
    # A placeholder here would be reported as a CONFIRMED field while being an
    # invention, which is precisely the mislabelling this contract exists to
    # prevent. An unidentified assessment is a refusal, not "UNSPECIFIED".
    assessment_id = (packet.get('assessment_id')
                     or (packet.get('identity') or {}).get('assessment_id'))
    if not assessment_id:
        raise WorkflowHeld('QG_CONFIRMED_FACTS_INCOMPLETE')

    joined = '\n'.join(texts)
    version = (uncertainty_version if uncertainty_version is not None
               else str(uncertainty.get('id')))
    sources = sorted({s['id'] + '@' + s['version']
                      for s in packet.get('supporting_sources') or []})
    sources.append(str(uncertainty.get('id')))

    return ConfirmedFacts(
        assessment_id=str(assessment_id),
        objective_id=(str(objective['objective_id']) if objective
                      and objective.get('objective_id') else None),
        objective_text=(objective.get('text') if objective and objective.get('text')
                        else exact_text),
        uncertainty_id=str(uncertainty.get('id')),
        uncertainty_version=version,
        uncertainty_text=exact_text,
        bcb_version=str(packet.get('schema_version') or 'business-context-package/1.1'),
        context_hash=str(packet.get('packet_hash') or ''),
        m2_answer_revision_ids=revision_ids,
        bdj_findings=[{'rule_id': f.get('rule_id'), 'kind': f.get('kind'),
                       'observed_condition': f.get('observed_condition')}
                      for f in bdj_findings or () if isinstance(f, dict)],
        confirmed_offers=_offers(joined),
        confirmed_numbers=sorted(_numbers(joined)),
        confirmed_currency=sorted(_currency(joined)),
        source_refs=sources,
    )


_OFFER_HINTS = ('oz', 'ml', 'litre', 'liter', 'kg', 'g ', 'takeaway', 'dine-in',
                'dine in', 'delivery', 'iced', 'hot', 'cup', 'slice', 'piece',
                'pack', 'bottle', 'can')


def _offers(text: str) -> list[str]:
    """Offer components actually present in confirmed text.

    A heuristic, and reported as one: these are the tokens a question is most
    likely to need to restate. It never invents — a component absent from the
    confirmed text is absent from this list.
    """
    lowered = text.lower()
    found = []
    for hint in _OFFER_HINTS:
        if hint in lowered:
            found.append(hint.strip())
    for match in re.finditer(r'\d+\s?(?:oz|ml|kg|g|litre|liter)\b', lowered):
        found.append(match.group(0).strip())
    return sorted(set(found))


def validate_candidate(raw, facts: ConfirmedFacts) -> QGCandidate:
    """Deterministic admission of a proposed candidate. Raises on any violation.

    The checks are ordered so that the most specific failure is the one reported.
    Where a rule could pass for the wrong reason, the reason is stated in the
    test that covers it.
    """
    candidate = QGCandidate.model_validate(raw)

    if candidate.decision == 'ABSTAIN_NEEDS_REVIEW':
        # An abstention is a result, not a failure — but it must be *justified*.
        # A bare abstention with nothing missing is indistinguishable from a
        # model that gave up, so it is refused.
        if candidate.question.strip():
            raise WorkflowHeld('QG_ABSTENTION_CONTAINS_QUESTION')
        if not candidate.missing_business_facts:
            raise WorkflowHeld('QG_ABSTENTION_WITHOUT_MISSING_FACTS')
        for code in candidate.missing_business_facts:
            if code not in MISSING_FACT_CODES:
                raise WorkflowHeld('QG_ABSTENTION_CODE_UNRECOGNISED')
        return candidate

    if not candidate.question.strip():
        raise WorkflowHeld('QG_DRAFT_WITHOUT_QUESTION')
    if candidate.missing_business_facts:
        # Drafting while simultaneously declaring a mandatory fact missing is a
        # contradiction: the question cannot be answerable as written.
        raise WorkflowHeld('QG_DRAFT_DECLARES_MISSING_FACTS')

    # -- no invented business facts ------------------------------------
    # The question may only use numbers the entrepreneur confirmed. This is the
    # general form of D-01: it covers prices, sizes, counts and percentages
    # alike, rather than protecting one currency token.
    unsourced = _numbers(candidate.question) - set(facts.confirmed_numbers)
    if unsourced:
        raise WorkflowHeld('QG_UNSOURCED_NUMBER')
    offered = _currency(candidate.question)
    if not offered <= set(facts.confirmed_currency):
        raise WorkflowHeld('QG_UNSOURCED_AMOUNT')
    # Restating a confirmed offer is allowed; adding a new one is not. Checked
    # only when the confirmed text names offer components at all, so a purely
    # abstract objective is not refused for lacking a product.
    if facts.confirmed_offers:
        lowered_question = candidate.question.lower()
        lowered_facts = facts.uncertainty_text.lower()
        for token in re.findall(r'\d+\s?(?:oz|ml|kg|g|litre|liter)\b', lowered_question):
            if token.strip() not in lowered_facts:
                raise WorkflowHeld('QG_UNSOURCED_OFFER_COMPONENT')

    # -- response coding must be internally coherent --------------------
    codes, labels, routing = (candidate.response_codes, candidate.response_options,
                              candidate.routing)
    if len(codes) != len(labels) or len(codes) < 2:
        raise WorkflowHeld('QG_RESPONSE_CODING_DRIFT')
    if len(set(codes)) != len(codes) or len(set(labels)) != len(labels):
        raise WorkflowHeld('QG_RESPONSE_CODING_DRIFT')
    if any(not _CODE.match(c) for c in codes):
        raise WorkflowHeld('QG_RESPONSE_CODING_DRIFT')
    if any(not label.strip() for label in labels):
        raise WorkflowHeld('QG_RESPONSE_LABEL_DRIFT')
    if set(routing) != set(codes):
        raise WorkflowHeld('QG_ROUTING_DRIFT')
    if any(not v.strip() for v in routing.values()):
        raise WorkflowHeld('QG_ROUTING_DRIFT')

    # -- a proposed denominator must be built from declared codes -------
    if not candidate.denominator_specification.strip():
        raise WorkflowHeld('QG_DENOMINATOR_NOT_PROPOSED')
    if not any(code in candidate.denominator_specification for code in codes):
        raise WorkflowHeld('QG_DENOMINATOR_DRIFT')

    # -- the proposal must state its own limits -------------------------
    if len(candidate.limitations.strip()) < 20:
        raise WorkflowHeld('QG_LIMITATIONS_INCOMPLETE')
    claim_text = ' '.join((candidate.construct_interpretation, candidate.question,
                           candidate.denominator_specification)).casefold()
    for pattern, code in PROHIBITED_CLAIM_PATTERNS:
        if re.search(pattern, claim_text):
            raise WorkflowHeld(code)

    # -- the model must say which confirmed facts it used ---------------
    if not candidate.used_confirmed_facts:
        raise WorkflowHeld('QG_CONFIRMED_FACTS_NOT_CITED')
    for fact in candidate.used_confirmed_facts:
        if fact not in facts.source_refs and fact not in facts.confirmed_numbers \
                and fact not in facts.confirmed_currency:
            raise WorkflowHeld('QG_CITED_FACT_NOT_CONFIRMED')
    return candidate


def field_authority(candidate: QGCandidate) -> dict:
    """Report which output fields are confirmed and which are proposals.

    Returned alongside every candidate so a reviewer, an API consumer or a UI
    cannot read a proposal as an adopted measurement. This is the machine-readable
    form of "do not mark generated fields as confirmed".
    """
    return {
        'contract_version': CONTRACT_VERSION,
        CONFIRMED: ['uncertainty_id', 'uncertainty_version', 'objective_id',
                    'objective_text', 'source_refs', 'context_hash', 'bcb_version'],
        PROPOSED: ['question', 'construct_interpretation', 'response_options',
                   'response_codes', 'routing', 'reference_period',
                   'measurement_description', 'denominator_specification',
                   'limitations', 'unresolved_assumptions'],
        'scientifically_adopted': False,
        'fielding_authorized': False,
    }


__all__ = ['CONFIRMED', 'CONTRACT_VERSION', 'ConfirmedFacts', 'MISSING_FACT_CODES',
           'PROPOSED', 'QGCandidate', 'field_authority', 'facts_from_packet',
           'validate_candidate']
