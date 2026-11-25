"""Candidate issue classification, business relevance and objective resolution.

Status: **candidate policy, not adopted.** ``POLICY_ADOPTED`` is ``False`` and
nothing in this module can change it. It exists so the classification can be
tested and reviewed *before* it is trusted, and so a reviewer can see exactly
which rule produced which disposition.

What this module refuses to do
------------------------------
* It does not turn a source conflict into a customer-research objective. A
  contradiction in the entrepreneur's own declarations is a clarification task
  for the entrepreneur (G4 in the directive: "Do not present a CQ as a solution
  to an entrepreneur's own planning contradiction").
* It does not treat ``NOT_ESTABLISHED`` as a proven customer need, or ``NONE``
  as proof that customers do not exist.
* It does not create an objective. Every disposition carries
  ``auto_new_objective = False`` and ``auto_admission = False``; a novel
  candidate still has to pass owner review and the admission gate.
* It does not accept the model's own claim of relevance. ``resolve_candidate``
  re-derives relevance from the candidate text against the verified concept
  anchors and refuses an unanchored candidate regardless of what the model said.

Two kinds of check, deliberately separated
------------------------------------------
**Coded** checks read registered option codes (``M2V2-15`` service formats,
``M2V2-02`` primary format). They are deterministic and may raise an issue on
their own.

**Textual** checks read free text, which is untrusted data. They may only
*propose* ``POTENTIAL_CONFLICT`` with an exact quoted excerpt and
``requires_human_review = True``. They never certify a contradiction, because
negation, hypotheticals and future plans are not decidable by substring match.
"""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field

#: Version of the rule set. Changing a literal, a class or a disposition is a new
#: version, because a stored disposition must name the policy it was produced by.
#:
#: 0.2 — construct coverage requires a construct *claim*. 0.1 counted bare
#: domain words, so ``dine-in`` bound a trading-area objective to O4. Stored
#: 0.1 dispositions are left exactly as they were; this only changes how a new
#: candidate is classified.
#:
#: 0.3 — O3 also recognises price acceptance written as a verb phrase
#: ("would they accept RM 16.00"), not only as a noun ("price acceptability").
#: Same construct, same objective; only the wording the lexicon could see was
#: too narrow, so a real price objective was reported as NOVEL (DD-067).
#: Stored 0.2 dispositions are untouched for the same reason as above.
POLICY_VERSION = 'P1-BDJ-ISSUE-0.3-CAND'

#: Never true in this module. Kept as a value so a caller can assert it.
POLICY_ADOPTED = False

# -- vocabularies -----------------------------------------------------------
EXPLICIT_UNCERTAINTY = 'EXPLICIT_UNCERTAINTY'
EVIDENCE_UNAVAILABLE = 'EVIDENCE_UNAVAILABLE'
PLANNING_UNDECIDED = 'PLANNING_UNDECIDED'
HYPOTHESIS_ABSENT = 'HYPOTHESIS_ABSENT'
POTENTIAL_CONFLICT = 'POTENTIAL_CONFLICT'
AMBIGUOUS = 'AMBIGUOUS'
UNVERIFIED_ASSUMPTION = 'UNVERIFIED_ASSUMPTION'
NO_ISSUE = 'NO_ISSUE'

CLASSES = (EXPLICIT_UNCERTAINTY, EVIDENCE_UNAVAILABLE, PLANNING_UNDECIDED,
           HYPOTHESIS_ABSENT, POTENTIAL_CONFLICT, AMBIGUOUS,
           UNVERIFIED_ASSUMPTION, NO_ISSUE)

ENTREPRENEUR_CLARIFICATION = 'ENTREPRENEUR_CLARIFICATION'
BUSINESS_DECISION_REQUIRED = 'BUSINESS_DECISION_REQUIRED'
OTHER_EVIDENCE_REQUIRED = 'OTHER_EVIDENCE_REQUIRED'
LINK_EXISTING_OBJECTIVE = 'LINK_EXISTING_OBJECTIVE'
LINK_EXISTING_OBJECTIVE_OR_NO_ACTION = 'LINK_EXISTING_OBJECTIVE_OR_NO_ACTION'
NEW_OPTIONAL_CANDIDATE = 'NEW_OPTIONAL_CANDIDATE'
NO_ACTION = 'NO_ACTION'
HOLD_REVIEW = 'HOLD_REVIEW'

DISPOSITIONS = (ENTREPRENEUR_CLARIFICATION, BUSINESS_DECISION_REQUIRED,
                OTHER_EVIDENCE_REQUIRED, LINK_EXISTING_OBJECTIVE,
                LINK_EXISTING_OBJECTIVE_OR_NO_ACTION, NEW_OPTIONAL_CANDIDATE,
                NO_ACTION, HOLD_REVIEW)

COVERED_BY_FIXED_OBJECTIVE = 'COVERED_BY_FIXED_OBJECTIVE'
COVERED_BY_OPTIONAL_OBJECTIVE = 'COVERED_BY_OPTIONAL_OBJECTIVE'
POTENTIAL_EXTENSION = 'POTENTIAL_EXTENSION'
NOVEL_CANDIDATE = 'NOVEL_CANDIDATE'
NOT_CUSTOMER_RESEARCH_SUITABLE = 'NOT_CUSTOMER_RESEARCH_SUITABLE'

RESOLUTIONS = (COVERED_BY_FIXED_OBJECTIVE, COVERED_BY_OPTIONAL_OBJECTIVE,
               POTENTIAL_EXTENSION, NOVEL_CANDIDATE,
               NOT_CUSTOMER_RESEARCH_SUITABLE)

#: Classes a customer survey *can* resolve. Kept apart from the planning
#: classes because the two answer different questions: a planning class says the
#: entrepreneur has not decided something, while these say the customer answer
#: is genuinely unknown.
#:
#: DD-064: ``policy_binding`` used to take the *first* matched issue, so a
#: proposal that cited both an undecided study area and an explicitly declared
#: customer uncertainty was refused for the study area — even though the
#: objective was about the uncertainty. One refused planning item must not veto a
#: gap that other confirmed declarations establish.
CUSTOMER_ANSWERABLE_CLASSES = frozenset({
    EXPLICIT_UNCERTAINTY, UNVERIFIED_ASSUMPTION, EVIDENCE_UNAVAILABLE})

#: Literals that declare a customer-answerable uncertainty, keyed by
#: ``(item_key, literal)``.
#:
#: Separate from ``ITEM_RULES`` on purpose: one item can carry both a planning
#: literal and a research literal, and M2V2-11 is exactly that case — UNDECIDED
#: is a clarification request, VALIDATE_CHOICE is a declared research priority.
#: A single disposition per item cannot express both, and inventing a second
#: item key would misreport which declaration was cited.
#:
#: ``link_objective`` stays ``None`` for these: the objective is decided by the
#: declared research topic (M2V2-09) and by what the proposal text actually
#: claims, not by the fact that a hypothesis exists.
DECLARED_UNCERTAINTY_RULES: dict[tuple[str, str], dict] = {
    ('M2V2-11', 'VALIDATE_CHOICE'): {
        'classification': EXPLICIT_UNCERTAINTY,
        'disposition': OTHER_EVIDENCE_REQUIRED,
        'reason': ('The entrepreneur has explicitly asked for customer '
                   'validation of a choice already made. That is a declared '
                   'research priority a survey can answer.'),
        'link_objective': None,
    },
    ('M2V2-11', 'EXPLORE'): {
        'classification': EXPLICIT_UNCERTAINTY,
        'disposition': OTHER_EVIDENCE_REQUIRED,
        'reason': ('The entrepreneur has explicitly declared an exploratory '
                   'research priority. That is a declared uncertainty, not a '
                   'planning decision.'),
        'link_objective': None,
    },
    ('M2V2-18', 'HYPOTHESIS_IDENTIFIED'): {
        'classification': UNVERIFIED_ASSUMPTION,
        'disposition': OTHER_EVIDENCE_REQUIRED,
        'reason': ('The entrepreneur has stated a hypothesis that no customer '
                   'evidence has tested yet. An untested hypothesis is a '
                   'customer-answerable uncertainty, not a proven need.'),
        'link_objective': None,
    },
}

#: Item-specific rules. Keyed by the exact registered item and literal, because
#: the directive forbids broadening these globally: "Do not call `NONE` or
#: `NOT_ESTABLISHED` customer evidence without a registered item-specific
#: policy." A rule that applied to any item would be exactly that broadening.
ITEM_RULES: dict[str, dict] = {
    'M2V2-01': {
        'literals': {'UNDECIDED'},
        'classification': PLANNING_UNDECIDED,
        'disposition': BUSINESS_DECISION_REQUIRED,
        'reason': ('The study area is an entrepreneur planning decision. A '
                   'customer survey cannot choose a neighbourhood.'),
        'link_objective': None,
    },
    'M2V2-08': {
        'literals': {'NONE'},
        'classification': EVIDENCE_UNAVAILABLE,
        'disposition': LINK_EXISTING_OBJECTIVE_OR_NO_ACTION,
        'reason': ('No customer information has been gathered yet. That is an '
                   'evidence gap, not a finding that customers do not exist.'),
        'link_objective': None,
    },
    'M2V2-11': {
        'literals': {'UNDECIDED', 'UNSURE'},
        'classification': EXPLICIT_UNCERTAINTY,
        'disposition': ENTREPRENEUR_CLARIFICATION,
        'reason': ('The entrepreneur has not settled the research decision. '
                   'Clarifying the decision comes before drafting a question.'),
        'link_objective': None,
    },
    'M2V2-14': {
        'literals': {'PRICE_NOT_DECIDED'},
        'classification': PLANNING_UNDECIDED,
        'disposition': BUSINESS_DECISION_REQUIRED,
        'reason': ('No exact priced offer exists. A priced-stimulus measurement '
                   'must not be invented from an undecided price.'),
        'link_objective': None,
    },
    'M2V2-15': {
        'literals': {'NOT_DECIDED'},
        'classification': PLANNING_UNDECIDED,
        'disposition': BUSINESS_DECISION_REQUIRED,
        'reason': ('Which service formats will be offered is an entrepreneur '
                   'decision. O4 may later measure preference among the formats '
                   'actually chosen; that is a link, not a new objective.'),
        'link_objective': 'O4',
    },
    'M2V2-18': {
        'literals': {'NOT_ESTABLISHED'},
        'classification': HYPOTHESIS_ABSENT,
        'disposition': NO_ACTION,
        'reason': ('An absent hypothesis is a valid non-claim. It is never '
                   'treated as a proven customer need or a research gap.'),
        'link_objective': None,
    },
}

#: M2V2-09 research topics to the six fixed objectives. Derived from the item's
#: own registered option codes, so the mapping is traceable to the instrument
#: rather than to a paraphrase. Marked candidate because OD-11 is still open.
TOPIC_TO_OBJECTIVE = {
    'CONCEPT_INTEREST': 'O1',
    'PRODUCT_PREFERENCE': 'O2',
    'PRICE_ACCEPTABILITY': 'O3',
    'SERVICE_PREFERENCE': 'O4',
    'EXPERIENCE_PREFERENCE': 'O5',
    'SEGMENT_INTEREST': 'O6',
}
TOPIC_MAPPING_STATUS = 'PROPOSED_NOT_ADOPTED'

#: Construct claims. A candidate covers a fixed objective only when it *names*
#: the construct that objective measures — not when it mentions a word belonging
#: to that construct's domain.
#:
#: The distinction is the point of the table. ``dine-in`` is a *service mode*,
#: i.e. a value O4 would measure, not a claim that the candidate is about
#: measuring service preference. Counting the bare word bound a trading-area
#: objective to O4 purely because it described the business as "a primarily
#: dine-in café" (N03 audit, proposal c3a8c85e). So O4 requires an explicit
#: service construct, a stated preference for a mode, or a genuine comparison
#: between modes.
#:
#: Entries are regular expressions, matched case-insensitively. A miss produces
#: NOVEL_CANDIDATE or POTENTIAL_EXTENSION, never an automatic objective.
CONSTRUCT_LEXICON: dict[str, tuple[str, ...]] = {
    'O1': (
        r'\bconcept interest\b',
        r'\boverall interest\b',
        # "interest in the café concept": a short qualifier between the two
        # nouns must not defeat the claim, or a real O1 objective reads as novel.
        # ``\w`` is Unicode-aware, so an accented word ("café") is a qualifier.
        r'\binterest in\b(?:\s+[\w\'’\-]+){0,3}\s+concept\b',
    ),
    'O2': (
        r'\bproduct preference\b',
        r'\bpreference between\b',
        r'\bprefer between\b',
        r'\bwhich product\b',
        r'\bproduct choice\b',
    ),
    'O3': (
        r'\bprice acceptability\b',
        r'\bacceptable price\b',
        r'\bprice acceptance\b',
        r'\bacceptance of the\b',
        r'\bpriced offer\b',
        r'\bwillingness to pay\b',
        # DD-067. "Would they accept RM 16.00 for this coffee?" is the price
        # construct written in plain English, but the lexicon above only knew
        # the noun forms, so a genuine price objective resolved NOVEL and a
        # reader was told it was a new construct. Each pattern below still
        # requires a price word or a currency amount, so ordinary uses of
        # "accept" ("accept the invitation") cannot claim O3.
        r'\baccept(?:s|ed|ing)?\s+(?:an?\s+|the\s+)?'
        r'(?:price|pricing|price point)\b',
        r'\baccept(?:s|ed|ing)?\s+(?:rm|myr)\s?\d',
        r'\bacceptability of\s+(?:the\s+|that\s+|this\s+)?'
        r'(?:price|priced|rm|myr)\b',
        r'\b(?:price|priced)\s+(?:point\s+)?(?:is|be)\s+acceptable\b',
    ),
    'O4': (
        # The construct itself.
        r'\bservice (?:preference|format|mode|type|option)s?\b',
        # A stated preference for one mode.
        r'\bprefer(?:ence)?\s+(?:for\s+|between\s+)?'
        r'(?:dine-?in|take-?away|delivery)\b',
        # A genuine comparison between modes.
        r'\b(?:dine-?in|take-?away|delivery)\s+'
        r'(?:or|versus|vs\.?|instead of|rather than)\s+'
        r'(?:dine-?in|take-?away|delivery)\b',
    ),
    'O5': (
        r'\bexperience preference\b',
        r'\bexperience feature\b',
        r'\bambience\b',
        r'\batmosphere\b',
        r'\bnoise level\b',
        r'\bseating comfort\b',
    ),
    'O6': (
        r'\bsegment interest\b',
        r'\bby segment\b',
        r'\bcustomer segment\b',
        r'\btarget group\b',
        r'\bintended customer group\b',
    ),
}

_CONSTRUCT_PATTERNS: dict[str, tuple[re.Pattern[str], ...]] = {
    objective: tuple(re.compile(pattern, re.IGNORECASE) for pattern in patterns)
    for objective, patterns in CONSTRUCT_LEXICON.items()
}

#: Concept anchors: tokens that tie a candidate to the verified business. A
#: candidate with no anchor is not about this business, so it is refused rather
#: than reviewed. Kept generic enough to accept any confirmed café concept and
#: specific enough to reject an unrelated domain.
DEFAULT_CONCEPT_ANCHORS = ('café', 'cafe', 'coffee', 'espresso', 'latte',
                           'pastry', 'bakery', 'beverage', 'dine-in', 'takeaway')

#: Domains that are unambiguously not this business. Used only as a refusal
#: signal, never as evidence about the business.
UNRELATED_DOMAINS = ('hotel', 'room booking', 'flight', 'insurance policy',
                     'car rental', 'apartment rental')

_WS = re.compile(r'\s+')
_TERMINAL = re.compile(r'[.!?;:]+$')


@dataclass(frozen=True)
class Issue:
    item_key: str
    literal: str
    classification: str
    disposition: str
    reason: str
    link_objective: str | None
    source_ref: dict
    requires_human_review: bool
    policy_version: str = POLICY_VERSION
    #: Invariants. A reader can assert these instead of trusting prose.
    auto_new_objective: bool = False
    auto_admission: bool = False
    policy_adopted: bool = False

    def as_dict(self) -> dict:
        return {
            'item_key': self.item_key,
            'literal': self.literal,
            'classification': self.classification,
            'disposition': self.disposition,
            'reason': self.reason,
            'link_objective': self.link_objective,
            'source_ref': self.source_ref,
            'requires_human_review': self.requires_human_review,
            'policy_version': self.policy_version,
            'auto_new_objective': self.auto_new_objective,
            'auto_admission': self.auto_admission,
            'policy_adopted': self.policy_adopted,
        }


def _literal(value) -> str | None:
    """Extract a single registered code from a scalar, list or composite value.

    Multi-select items (M2V2-08, M2V2-15) store a list. Only a single-element
    list can identify one literal; a list of two codes is not "the literal", so
    it returns ``None`` and no rule fires. That is deliberate: reading the first
    element of a multi-selection would silently misclassify a mixed answer.
    """
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        if len(value) == 1 and isinstance(value[0], str):
            return value[0]
        return None
    if isinstance(value, dict):
        for key in ('decision', 'hypothesis_status', 'review_status', 'stage'):
            if isinstance(value.get(key), str):
                return value[key]
    return None


def _codes(value) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [v for v in value if isinstance(v, str)]
    if isinstance(value, dict):
        out = []
        for key in ('categories', 'features', 'segments', 'decision',
                    'hypothesis_status'):
            item = value.get(key)
            out.extend(_codes(item))
        return out
    return []


def _source_ref(declaration: dict) -> dict:
    return {'item_key': declaration.get('item_key'),
            'item_version_id': declaration.get('item_version_id'),
            'answer_revision_id': declaration.get('answer_revision_id')}


def classify(declarations: list[dict]) -> list[dict]:
    """Classify every declaration against the item-specific rules.

    Returns issues only for declarations that matched a rule. A declaration that
    matches nothing is not an issue; silence is not evidence.

    Both tables are consulted: ``ITEM_RULES`` for the planning and evidence
    literals, ``DECLARED_UNCERTAINTY_RULES`` for the literals that declare a
    customer-answerable uncertainty. A declaration can match at most one of
    them, because the second is keyed by the exact literal.
    """
    issues = []
    for declaration in declarations:
        key = declaration.get('item_key')
        literal = _literal(declaration.get('value'))
        if literal is None:
            continue

        rule = ITEM_RULES.get(key)
        if rule is not None and literal in rule['literals']:
            issues.append(Issue(
                item_key=key, literal=literal,
                classification=rule['classification'],
                disposition=rule['disposition'],
                reason=rule['reason'],
                link_objective=rule['link_objective'],
                source_ref=_source_ref(declaration),
                # A coded rule is deterministic, but the *disposition* is a policy
                # proposal, so a reviewer still has to adopt it. It is not a
                # per-item human hold; it is an unadopted rule.
                requires_human_review=False,
            ).as_dict())
            continue

        declared = DECLARED_UNCERTAINTY_RULES.get((key, literal))
        if declared is not None:
            issues.append(Issue(
                item_key=key, literal=literal,
                classification=declared['classification'],
                disposition=declared['disposition'],
                reason=declared['reason'],
                link_objective=declared['link_objective'],
                source_ref=_source_ref(declaration),
                requires_human_review=False,
            ).as_dict())
    return issues


def governing_issue(issues: list[dict]) -> dict | None:
    """The issue whose disposition decides the proposal.

    A customer-answerable class outranks a planning class. DD-064: the objective
    is about what customers can tell the entrepreneur, so an explicitly declared
    uncertainty governs even when the same proposal also cites an undecided
    planning item as its context.

    When no answerable issue exists, the first matched issue decides exactly as
    before — so a proposal that cites only an undecided study area is still
    refused.
    """
    if not issues:
        return None
    answerable = [i for i in issues
                  if i.get('classification') in CUSTOMER_ANSWERABLE_CLASSES]
    return (answerable or issues)[0]


def service_mode_conflict(declarations: list[dict]) -> dict | None:
    """Coded contradiction between the primary format and the offered formats.

    ``M2V2-02`` asks the *primary intended* format; ``M2V2-15`` asks *which
    formats will be offered*. They are compatible when the primary format is
    among the offered ones, or when the primary is HYBRID. They contradict only
    when the primary format is absent from the offered set — which is a real
    inconsistency, not a stylistic difference.

    A free-text claim of a different format is handled separately and may only
    produce a review candidate.
    """
    primary = next((d for d in declarations if d.get('item_key') == 'M2V2-02'), None)
    offered = next((d for d in declarations if d.get('item_key') == 'M2V2-15'), None)
    if primary is None or offered is None:
        return None
    primary_code = _literal(primary.get('value'))
    offered_codes = set(_codes(offered.get('value')))
    if not primary_code or not offered_codes:
        return None
    if 'NOT_DECIDED' in offered_codes or primary_code == 'UNDECIDED':
        # An undecided answer is not a contradiction; it is an undecided answer.
        return None
    if primary_code == 'HYBRID' or primary_code in offered_codes:
        return {
            'classification': NO_ISSUE,
            'detail': ('The primary format is among the offered formats, so the '
                       'two declarations are compatible.'),
            'primary': primary_code,
            'offered': sorted(offered_codes),
            'source_refs': [_source_ref(primary), _source_ref(offered)],
            'requires_human_review': False,
            'auto_new_objective': False,
        }
    return {
        'classification': POTENTIAL_CONFLICT,
        'detail': ('The primary intended format is not among the formats said '
                   'to be offered. This is a declaration inconsistency for the '
                   'entrepreneur to clarify; it is not a customer-research '
                   'objective.'),
        'disposition': ENTREPRENEUR_CLARIFICATION,
        'primary': primary_code,
        'offered': sorted(offered_codes),
        'source_refs': [_source_ref(primary), _source_ref(offered)],
        'requires_human_review': True,
        'auto_new_objective': False,
        'auto_admission': False,
    }


#: Negation phrases that, next to a structured code, suggest the free text may
#: disagree with it. Each match is quoted and held for review.
_NEGATION = re.compile(
    r'\b(?:only|no|not|never|without)\s+(?:dine[- ]in|takeaway|delivery)\b'
    r'|\b(?:dine[- ]in|takeaway|delivery)[- ]only\b', re.I)


def textual_conflict(declaration: dict, offered_codes: set[str]) -> dict | None:
    """Propose a conflict from free text, with the exact excerpt.

    This is the conservative half: the model or rule may only *propose*, the
    excerpt is preserved verbatim, and the disposition is a clarification. A
    substring match cannot decide negation, hypotheticals or future plans, so
    this can never certify a contradiction.
    """
    value = declaration.get('value')
    texts = []
    if isinstance(value, dict):
        texts = [v for v in value.values() if isinstance(v, str)]
    elif isinstance(value, str):
        texts = [value]
    for text in texts:
        for match in _NEGATION.finditer(text):
            excerpt = text[max(0, match.start() - 40):match.end() + 40].strip()
            return {
                'classification': POTENTIAL_CONFLICT,
                'disposition': ENTREPRENEUR_CLARIFICATION,
                'exact_quote': match.group(0),
                'excerpt': excerpt,
                'item_key': declaration.get('item_key'),
                'source_ref': _source_ref(declaration),
                'offered_codes': sorted(offered_codes),
                'requires_human_review': True,
                'auto_new_objective': False,
                'auto_admission': False,
                'note': ('Free text is untrusted data. This is a review '
                         'candidate, not a certified contradiction.'),
            }
    return None


def normalise(text: str) -> str:
    """NFC, casefold, trim, collapse whitespace, strip terminal punctuation.

    Used only for exact-duplicate detection. The original text is always kept
    separately, because normalisation is lossy.
    """
    folded = unicodedata.normalize('NFC', text or '').casefold()
    folded = _WS.sub(' ', folded).strip()
    return _TERMINAL.sub('', folded).strip()


def is_exact_duplicate(a: str, b: str) -> bool:
    return bool(a) and normalise(a) == normalise(b)


def construct_matches(text: str) -> dict[str, int]:
    """How many construct *claims* each fixed objective makes in ``text``.

    Counts claims, not keyword occurrences. An objective that merely describes
    the business — "a primarily dine-in café serving students" — claims nothing,
    so it resolves as a novel candidate instead of being silently absorbed by
    O4. The count is used only to pick the strongest claim and to detect an
    equal tie, which is a human hold rather than a guess.
    """
    body = _WS.sub(' ', (text or '').strip())
    return {objective: sum(1 for pattern in patterns if pattern.search(body))
            for objective, patterns in _CONSTRUCT_PATTERNS.items()}


def has_anchor(text: str, anchors=DEFAULT_CONCEPT_ANCHORS) -> bool:
    lowered = (text or '').casefold()
    return any(token in lowered for token in anchors)


def is_unrelated(text: str) -> bool:
    lowered = (text or '').casefold()
    return any(token in lowered for token in UNRELATED_DOMAINS)


def resolve_candidate(text: str, *, existing_objectives: dict[str, list[str]] | None = None,
                      anchors=DEFAULT_CONCEPT_ANCHORS) -> dict:
    """Place one candidate objective in the five-way resolution.

    ``existing_objectives`` maps objective_id to the normalised texts already
    registered for it, so an exact duplicate can be consolidated rather than
    re-created. ``None`` means "no optional objectives exist yet".
    """
    existing_objectives = existing_objectives or {}
    base = {
        'policy_version': POLICY_VERSION,
        'policy_adopted': POLICY_ADOPTED,
        'candidate_text': text,
        'auto_new_objective': False,
        'auto_admission': False,
        'creates_approved_measurement': False,
    }

    if not (text or '').strip():
        return {**base, 'resolution': NOT_CUSTOMER_RESEARCH_SUITABLE,
                'reason': 'EMPTY_CANDIDATE'}

    if is_unrelated(text):
        return {**base, 'resolution': NOT_CUSTOMER_RESEARCH_SUITABLE,
                'reason': 'UNRELATED_BUSINESS_DOMAIN'}

    if not has_anchor(text, anchors):
        return {**base, 'resolution': NOT_CUSTOMER_RESEARCH_SUITABLE,
                'reason': 'NO_VERIFIED_BUSINESS_ANCHOR'}

    # Exact duplicate of an already-registered objective: consolidate, never
    # create a second row for the same construct and scope.
    for objective_id, texts in existing_objectives.items():
        for existing in texts:
            if is_exact_duplicate(text, existing):
                return {**base, 'resolution': COVERED_BY_OPTIONAL_OBJECTIVE,
                        'reason': 'EXACT_DUPLICATE_CONSOLIDATE_WITH_AUDIT',
                        'covered_by': objective_id}

    scores = construct_matches(text)
    best = max(scores.values()) if scores else 0
    if best > 0:
        winners = sorted(k for k, v in scores.items() if v == best)
        if len(winners) > 1:
            # Two constructs claim the candidate equally. Similarity is not a
            # scientific decision, so this is a human hold rather than a guess.
            return {**base, 'resolution': POTENTIAL_EXTENSION,
                    'reason': 'AMBIGUOUS_CONSTRUCT_OVERLAP',
                    'candidate_objectives': winners}
        return {**base, 'resolution': COVERED_BY_FIXED_OBJECTIVE,
                'reason': 'CONSTRUCT_MATCHES_FIXED_OBJECTIVE',
                'covered_by': winners[0]}

    return {**base, 'resolution': NOVEL_CANDIDATE,
            'reason': 'ANCHORED_BUT_NOT_COVERED_BY_FIXED_OBJECTIVE'}


def topic_objectives(declaration: dict) -> list[str]:
    """Objectives the entrepreneur themselves named in M2V2-09."""
    return sorted({TOPIC_TO_OBJECTIVE[code]
                   for code in _codes(declaration.get('value'))
                   if code in TOPIC_TO_OBJECTIVE})


def policy_summary() -> dict:
    return {
        'policy_version': POLICY_VERSION,
        'policy_adopted': POLICY_ADOPTED,
        'classes': list(CLASSES),
        'dispositions': list(DISPOSITIONS),
        'resolutions': list(RESOLUTIONS),
        'item_rules': {k: {'literals': sorted(v['literals']),
                           'classification': v['classification'],
                           'disposition': v['disposition'],
                           'link_objective': v['link_objective']}
                       for k, v in ITEM_RULES.items()},
        'declared_uncertainty_rules': {
            f'{k[0]}:{k[1]}': {'classification': v['classification'],
                               'disposition': v['disposition'],
                               'link_objective': v['link_objective']}
            for k, v in DECLARED_UNCERTAINTY_RULES.items()},
        'customer_answerable_classes': sorted(CUSTOMER_ANSWERABLE_CLASSES),
        'topic_mapping': dict(TOPIC_TO_OBJECTIVE),
        'topic_mapping_status': TOPIC_MAPPING_STATUS,
        'invariants': {
            'auto_new_objective': False,
            'auto_admission': False,
            'model_relevance_is_not_self_verifying': True,
            'conflict_requires_human_review': True,
        },
    }


__all__ = ['CLASSES', 'CONSTRUCT_LEXICON', 'COVERED_BY_FIXED_OBJECTIVE',
           'COVERED_BY_OPTIONAL_OBJECTIVE', 'CUSTOMER_ANSWERABLE_CLASSES',
           'DECLARED_UNCERTAINTY_RULES', 'DISPOSITIONS', 'ITEM_RULES',
           'NOVEL_CANDIDATE', 'NOT_CUSTOMER_RESEARCH_SUITABLE', 'POLICY_ADOPTED',
           'POLICY_VERSION', 'POTENTIAL_CONFLICT', 'POTENTIAL_EXTENSION',
           'RESOLUTIONS', 'TOPIC_MAPPING_STATUS', 'TOPIC_TO_OBJECTIVE', 'Issue',
           'classify', 'construct_matches', 'governing_issue', 'has_anchor',
           'is_exact_duplicate', 'normalise', 'policy_summary',
           'resolve_candidate', 'service_mode_conflict', 'textual_conflict',
           'topic_objectives']
