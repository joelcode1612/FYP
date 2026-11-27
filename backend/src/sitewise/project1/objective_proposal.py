"""BDJ objective-proposal contract v1 (candidate).

Additive: `bdj-objective-proposal/1` sits beside `bdj-output/1`. It does not
replace it, does not migrate anything, and does not touch historical rows.

Two recommendation statuses only. `CLARIFY` is deliberately absent: it was a
review action, not a recommendation category, and historical records that used
it stay as they are.

Every recommendation is candidate-only. Nothing here approves an objective,
authorises fielding, or generates a questionnaire question.
"""
from typing import Literal

from pydantic import Field

from sitewise.project1.contracts import StrictModel, WorkflowHeld, digest

CONTRACT_VERSION = 'bdj-objective-proposal/2'

#: The previous contract. Still accepted, because a payload that was valid when
#: it was produced does not become invalid because a later revision raised a
#: ceiling. Historical rows keep their own label.
LEGACY_CONTRACT_VERSION = 'bdj-objective-proposal/1'

ACCEPTED_CONTRACT_VERSIONS = (LEGACY_CONTRACT_VERSION, CONTRACT_VERSION)

#: How many recommendations one proposal may carry (owner decision, 2026-11-26).
#:
#: Raised 5 -> 6. This is a **capacity** limit, not a shape: the field set, the
#: two statuses and the validation rules are unchanged. That distinction is why
#: the ceiling can move without the model having to relabel its output -- the
#: version identifies the payload's shape, and the item ceiling is policy that
#: was always enforced by the schema rather than by the label.
#:
#: No historical record changes meaning: a ``/1`` payload could never have
#: carried six items, because the schema it was validated against forbade it.
MAX_RECOMMENDATIONS = 6

#: What ``/1`` permitted. Kept as a named constant so the difference between the
#: two revisions is a fact in the code rather than a comment.
HISTORICAL_MAX_RECOMMENDATIONS = 5

#: There is deliberately **no minimum**. The owner's target of four to six
#: suitable recommendations is a research goal, not a validation rule: a review
#: that finds fewer genuine research needs must be able to say so rather than
#: invent proposals to reach a quota. ``min_length`` is therefore unset on
#: ``recommendations`` and a test pins that.

# Status -> the only problem_type it may carry.
PROBLEM_TYPE_FOR_STATUS = {
    'MOST_SUGGESTED': 'SOURCE_CONFIRMED_INFORMATION_GAP',
    'SUGGESTED': 'EXPLORATORY_RESEARCH_NEED',
}

# A source may only support a gap if its confirmed value is itself an
# uncertainty literal. This is what stops "M2V1-02 = DINE_IN" being dressed up
# as an information gap.
SUPPORTING_LITERALS = {
    'M2V1-08': frozenset({'UNKNOWN', 'NONE'}),
    # DD-064. The adopted objective prompt declares a *second* valid source
    # shape: a confirmed declaration that states an unresolved CUSTOMER
    # uncertainty. The declaration is definite; what it states is unresolved.
    # These entries are that shape, transcribed from the adopted prompt:
    #
    #   M2V2-11  "a declared validation requirement or exploration priority"
    #   M2V2-18  "an identified but untested hypothesis"
    #
    # Before this, only the first shape (an uncertainty *literal*) was
    # accepted, so a proposal the adopted prompt explicitly permits could
    # never pass: it was refused as BDJ_OBJECTIVE_SOURCE_NOT_SUPPORTING no
    # matter how faithfully the model followed the prompt. Demonstrated with
    # backend/var/e2e/tmp/probe_dd064.py cases B and C.
    #
    # M2V2-18 accepts only HYPOTHESIS_IDENTIFIED. NOT_ESTABLISHED is not an
    # identified hypothesis, and accepting it would let every unanswered
    # hypothesis pass as a gap.
    'M2V2-11': frozenset({'VALIDATE_CHOICE', 'EXPLORE'}),
    'M2V2-18': frozenset({'HYPOTHESIS_IDENTIFIED'}),
}
DEFAULT_SUPPORTING_LITERALS = frozenset({'UNDECIDED', 'UNSURE', 'UNKNOWN'})

#: Items whose *content* is a declared research topic rather than a status.
#: DD-064 names "a declared research topic (M2V2-09) naming what the
#: entrepreneur wants to learn" as the third form of the second shape, and the
#: value is a multi-select list, so it establishes when it carries at least one
#: topic code.
#:
#: This is the one entry that *broadens* eligibility beyond a conditional
#: status: the instrument collects a topic list from every respondent, so any
#: assessment that answered M2V2-09 can support a MOST_SUGGESTED proposal.
#: That is what the adopted prompt says, and implementing the prompt is the
#: point -- but it is a scientific consequence the owner should confirm, not
#: something a validator may quietly decide. Recorded as DD-099.
DECLARED_TOPIC_ITEMS = frozenset({'M2V2-09'})

CLAIM_PHRASES = (
    'guarantee', 'guaranteed', 'will definitely', 'proves demand', 'proven demand',
    'market demand', 'profitable', 'profitability', 'willingness to pay',
    'market size', 'scientifically proven',
)
ALLOWED_OPENERS = ('to investigate', 'to explore', 'to understand', 'to assess',
                   'to determine', 'to establish', 'to identify', 'to evaluate')


class ObjectiveSourceRef(StrictModel):
    """Answer-level pointer. `item_version_id` is required on purpose: an answer
    revision alone does not prove which registered item definition produced it.

    The key space is the union of the two registered instrument families and
    nothing else: ``M2V1-01..11`` and ``M2V2-01..19``. Widening it further would
    let a proposal cite an item that no instrument registers, so the pattern
    stays an enumeration rather than becoming a prefix match.
    """
    item_key: str = Field(
        pattern=r'^(?:M2V1-(?:0[1-9]|1[01])|M2V2-(?:0[1-9]|1[0-9]))$')
    answer_revision_id: str = Field(min_length=1, max_length=64)
    item_version_id: str = Field(min_length=1, max_length=64)


class Recommendation(StrictModel):
    recommendation_status: Literal['MOST_SUGGESTED', 'SUGGESTED']
    problem_type: Literal['SOURCE_CONFIRMED_INFORMATION_GAP',
                          'EXPLORATORY_RESEARCH_NEED']
    # Both fields are REQUIRED, including when they are empty/null. With a
    # default they dropped out of the JSON schema's `required` list, and the
    # live model then omitted `source_refs` entirely on a MOST_SUGGESTED
    # recommendation (observed 2026-11-21, BDJ-OBJECTIVE-1-CAND). A field the
    # model may omit is a field it will omit.
    problem: str | None = Field(max_length=1000)
    research_objective: str = Field(min_length=12, max_length=500)
    source_refs: list[ObjectiveSourceRef] = Field(max_length=8)
    reason: str = Field(min_length=1, max_length=1000)
    authority: Literal['CANDIDATE_ONLY'] = 'CANDIDATE_ONLY'


class ObjectiveProposal(StrictModel):
    contract_version: Literal['bdj-objective-proposal/1',
                              'bdj-objective-proposal/2']
    #: Capacity only: at most MAX_RECOMMENDATIONS (6), and no minimum. A review
    #: with one genuine research need, or none, is a valid outcome.
    recommendations: list[Recommendation] = Field(max_length=MAX_RECOMMENDATIONS)


BOUND_CONTRACT_VERSION = 'bdj-objective-proposal-bound/1'


class BoundObjectiveProposal(StrictModel):
    """A proposal attached to one persisted business context.

    The identifiers are supplied by the server, never by the model: a model
    cannot verify a context hash, and asking it to echo one would create a
    second, competing claim about provenance.
    """
    contract_version: Literal['bdj-objective-proposal-bound/1']
    context_id: str = Field(min_length=1, max_length=64)
    context_packet_hash: str = Field(pattern=r'^[0-9a-f]{64}$')
    confirmation_id: str = Field(min_length=1, max_length=64)
    confirmation_digest: str = Field(pattern=r'^[0-9a-f]{64}$')
    proposals: list[Recommendation]
    binding_authority: Literal['SERVER_DETERMINISTIC'] = 'SERVER_DETERMINISTIC'


def bind_to_business_context(proposal: ObjectiveProposal, *,
                             context_packet: dict, context_id: str) -> BoundObjectiveProposal:
    """Attach a validated proposal to a persisted business context.

    Fails closed when the context is not the current confirmed one, when its
    packet hash does not recompute, or when any cited answer is absent from the
    context's own `m2_answers`. That last check is the real link: a proposal may
    only be bound to a context built from the same answers it cites.
    """
    if not isinstance(context_packet, dict) or not isinstance(context_id, str) or not context_id:
        raise WorkflowHeld('BDJ_OBJECTIVE_CONTEXT_INVALID')

    from sitewise.services.business_context_v1 import source_hash

    claimed = context_packet.get('packet_hash')
    content = {k: v for k, v in context_packet.items() if k != 'packet_hash'}
    if not isinstance(claimed, str) or source_hash(content) != claimed:
        raise WorkflowHeld('BDJ_OBJECTIVE_CONTEXT_HASH_INVALID')

    confirmation = context_packet.get('confirmation') or {}
    if confirmation.get('status') != 'CURRENT_CONFIRMED':
        raise WorkflowHeld('BDJ_OBJECTIVE_CONTEXT_NOT_CURRENT')

    answers = {row.get('item_key'): row
               for row in (context_packet.get('m2_answers') or [])
               if isinstance(row, dict)}
    for rec in proposal.recommendations:
        for ref in rec.source_refs:
            row = answers.get(ref.item_key)
            if (row is None or row.get('answer_revision_id') != ref.answer_revision_id or
                    row.get('item_version_id') != ref.item_version_id or
                    row.get('answer_state') != 'ANSWERED'):
                raise WorkflowHeld('BDJ_OBJECTIVE_CONTEXT_SOURCE_MISMATCH')

    return BoundObjectiveProposal(
        contract_version=BOUND_CONTRACT_VERSION,
        context_id=context_id,
        context_packet_hash=claimed,
        confirmation_id=str(confirmation.get('id') or ''),
        confirmation_digest=str(confirmation.get('digest') or ''),
        proposals=proposal.recommendations,
    )


def _normalise(text: str) -> str:
    return ' '.join(text.casefold().split())


def _string_leaves(value):
    """Every string inside a declared value, whatever its shape.

    The M2 V2 instrument mixes scalar, multi-select (list) and structured
    (object) answers, and an uncertainty can live in one *field* of an object.
    Comparing only the top-level value meant a structured declaration could
    never satisfy any literal set, so ``M2V2-18 HYPOTHESIS_IDENTIFIED`` was
    unreachable even after its literal was registered. Keys are deliberately
    excluded: a field *name* is not a declared value.
    """
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for inner in value.values():
            yield from _string_leaves(inner)
    elif isinstance(value, list):
        for inner in value:
            yield from _string_leaves(inner)


def _establishes_uncertainty(item_key: str, value) -> bool:
    """Does this confirmed declaration state an unresolved uncertainty?

    Both shapes DD-064 defines, and nothing else:

    *first* — the value itself is an uncertainty literal (UNDECIDED / UNSURE /
    UNKNOWN), or the item's own registered literal set says so (M2V1-08).

    *second* — a **declared** uncertainty: a validation requirement, an
    identified but untested hypothesis, or a declared research topic. The
    declaration is definite; the thing it states is not yet resolved.

    A definite operational choice (DINE_IN, TAKEAWAY, PRICED, a chosen product)
    is establishing under neither shape. It may still be *cited* — the prompt
    allows it as the subject of the uncertainty — but it cannot be the sole
    reason a gap exists.
    """
    leaves = list(_string_leaves(value))
    allowed = SUPPORTING_LITERALS.get(item_key, DEFAULT_SUPPORTING_LITERALS)
    if any(leaf in allowed for leaf in leaves):
        return True
    if item_key in DECLARED_TOPIC_ITEMS:
        return any(leaf.strip() for leaf in leaves)
    return False


def validate_objective_proposal(raw, packet: dict) -> ObjectiveProposal:
    """Fail-closed validation of a candidate proposal against the source packet.

    Passing this proves structure and source binding only. It is not semantic
    approval, not a finding, and not an authorised objective.
    """
    output = ObjectiveProposal.model_validate(raw)
    sources = {d['item_key']: d for d in packet.get('declarations', [])}
    seen: set[str] = set()

    for rec in output.recommendations:
        # 1. status / problem_type must agree.
        if rec.problem_type != PROBLEM_TYPE_FOR_STATUS[rec.recommendation_status]:
            raise WorkflowHeld('BDJ_OBJECTIVE_PROBLEM_TYPE_MISMATCH')

        # 2. no prohibited business claim. Checked before phrasing so a
        # claim-laden objective reports the more serious violation.
        low = _normalise(rec.research_objective)
        if any(phrase in low for phrase in CLAIM_PHRASES):
            raise WorkflowHeld('BDJ_OBJECTIVE_CLAIM_NOT_ALLOWED')

        # 3. the objective is a research statement, not a questionnaire question.
        if low.endswith('?'):
            raise WorkflowHeld('BDJ_OBJECTIVE_PHRASING_INVALID')
        if not low.startswith(ALLOWED_OPENERS):
            raise WorkflowHeld('BDJ_OBJECTIVE_PHRASING_INVALID')

        if rec.recommendation_status == 'MOST_SUGGESTED':
            # 4a. a source-confirmed gap must name the problem and the source.
            if not (rec.problem or '').strip():
                raise WorkflowHeld('BDJ_OBJECTIVE_PROBLEM_REQUIRED')
            if not rec.source_refs:
                raise WorkflowHeld('BDJ_OBJECTIVE_SOURCE_REQUIRED')
            # Every ref must still be a real, exactly-matching, ANSWERED
            # declaration -- a citation is never accepted on trust.
            #
            # What changed (DD-064): *one* ref must establish the uncertainty,
            # not all of them. The adopted prompt lets a proposal cite the
            # definite declaration the uncertainty is *about* (a priced offer,
            # a chosen product) alongside the declaration that establishes it.
            # Requiring every ref to be an uncertainty literal refused exactly
            # that permitted combination. A definite value on its own still
            # fails, because nothing in the set then establishes a gap.
            establishing = False
            for ref in rec.source_refs:
                source = sources.get(ref.item_key)
                if (source is None or source.get('answer_state') != 'ANSWERED' or
                        source.get('answer_revision_id') != ref.answer_revision_id or
                        source.get('item_version_id') != ref.item_version_id):
                    raise WorkflowHeld('BDJ_OBJECTIVE_SOURCE_INVALID')
                if _establishes_uncertainty(ref.item_key, source.get('value')):
                    establishing = True
            if not establishing:
                raise WorkflowHeld('BDJ_OBJECTIVE_SOURCE_NOT_SUPPORTING')
        else:
            # 4b. an exploratory proposal may not pretend a problem was found.
            if rec.problem is not None:
                raise WorkflowHeld('BDJ_OBJECTIVE_PROBLEM_NOT_ALLOWED')
            if rec.source_refs:
                raise WorkflowHeld('BDJ_OBJECTIVE_SOURCE_NOT_ALLOWED')

        signature = digest({'status': rec.recommendation_status,
                            'objective': _normalise(rec.research_objective)})
        if signature in seen:
            raise WorkflowHeld('BDJ_OBJECTIVE_DUPLICATE_RECOMMENDATION')
        seen.add(signature)

    return output
