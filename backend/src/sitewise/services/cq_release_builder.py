"""Compose a release: composed questionnaire -> ``cq-manifest/1`` -> persisted rows.

Why a builder and not an endpoint
---------------------------------
Publication is an **operator** action, not a respondent action. The runtime
principal (``p1_ee01_runtime``) holds SELECT only on
``cq_bank_versions`` / ``cq_manifest_releases`` / ``cq_question_assignments``,
and the only policies on those three tables are SELECT policies. That is not an
oversight to be patched with an INSERT grant: a respondent process must never be
able to mint the instrument it answers. The existing precedent is
``scripts/register_cq_source_bank.py`` -- read-only by default, ``--apply``
behind an operator receipt. This module is the same shape, for a release rather
than a source bank.

What the builder is responsible for
-----------------------------------
1. **Construction.** Turn the Stage 5 composition (governed stems already
   populated from the owner's confirmed declarations) into the exact DTO
   ``domain.cq_runtime.verify_release`` accepts, without inventing a single
   respondent-facing string.
2. **Canonical fingerprint.** ``digest(manifest)`` is the release identity. The
   same inputs must produce the same hash on any machine, so nothing here reads
   a clock, a random source or ambient configuration.
3. **Authorisation, stated rather than assumed.** ``authorized_question_ids`` is
   computed, and every exclusion carries a reason. A question whose stimulus is
   not in this release, or which has no governed feature bank, is *not* silently
   included: it is excluded and reported.
4. **Persistence.** One transaction writes the bank version, the release and one
   assignment per slot, and only after ``assert_authoritative_binding`` has
   compared the manifest against the persisted M2/BCB records *inside that same
   transaction*. A syntactically valid manifest cannot establish its own
   authority.
5. **Idempotency.** ``cq_manifest_releases.manifest_hash`` is UNIQUE, and the
   release id is derived from the hash, so republishing the same manifest is a
   read, not a second row. A bank version that already holds different content
   is a collision, not an update -- the tables are append-only.

What the builder will not do
----------------------------
* It will not choose ``optional_context``, ``mode`` or ``q02_policy`` on the
  owner's behalf; they are arguments with fail-closed defaults.
* It will not write a stimulus text. ``stimuli`` is an input, and the caller must
  pass text that is a deterministic rendering of something already confirmed
  (``concept.content.description``, or the declared priced offer). A missing
  stimulus is reported as a routing exclusion, never filled in here.
* It will not touch ``cq_campaigns``. A release becomes visible to the runtime
  only through a campaign (the SELECT policy says so), and creating one is a
  separate, separately-authorised step.
"""
from __future__ import annotations

from copy import deepcopy
from typing import Any, Mapping
from uuid import NAMESPACE_URL, UUID, uuid5

from sitewise.domain.cq_runtime import CqRefused, verify_release
from sitewise.domain.customer_questionnaire import digest
from sitewise.services.customer_questionnaire_candidate import SOURCE_SHA

CONTRACT_VERSION = 'cq-manifest/1'
BUILDER_VERSION = 'cq-release-builder/1'

#: ``cq_manifest_releases.source_class`` CHECK constraint. Repeated here so a
#: caller learns the refusal from the builder rather than from a 23514.
SOURCE_CLASSES = frozenset({'ADOPTED', 'CANDIDATE', 'SYNTHETIC_FIXTURE'})

#: Gate fact -> the stimulus kind whose delivery satisfies it. Derived from
#: ``policy['gate']['token_predicates']``: a clause is ``is_true`` on one of
#: these facts, and ``route()`` computes each fact from ``ready(kind)``.
FACT_TO_STIMULUS = {
    'CONCEPT_READY': 'concept',
    'MENU_READY': 'menu',
    'OCCASION_READY': 'occasion',
    'FEATURE_BANK_READY': 'features',
    'APPROVED_EXACT_OFFER_STIMULUS': 'offer',
}

#: Facts a release may *declare* instead of delivering. ``OPTIONAL_CONTEXT_ENABLED``
#: is the owner's decision to include the optional-context block (Q11-Q13); it is
#: a manifest field, not a stimulus.
DECLARED_FACTS = {'OPTIONAL_CONTEXT_ENABLED': 'optional_context'}

#: The routing dependency graph ``verify_release`` pins exactly. Not a policy
#: choice: any other shape is refused as CQ_ROUTING_DEPENDENCY_INVALID.
_DEPENDENCIES = {'Q01': [], 'Q08': ['Q01', 'Q04']}

#: Composition section marker for an additional (Section B) question. It is set
#: on additional items **only**. Fixed-core items carry no such key, so a
#: fixed-only manifest is byte-identical to the one this builder produced before
#: Section B support existed -- which is what keeps every already-published
#: release reproducible.
SECTION_ADDITIONAL = 'B_ADDITIONAL'

#: The show gate an additional question inherits.
#:
#: An additional question has no entry in the frozen ``item_show_gate`` map,
#: because that map was written for Q01-Q13 and the policy file is pinned by
#: ``policy_hash`` on every release already published. Adding a token to it
#: would change the policy digest and invalidate those releases.
#:
#: ``Q01_ELIGIBLE`` is already registered in the frozen policy, and it is the
#: narrowest token that is still truthful: an additional question is asked of
#: respondents who passed the Q01 screen, and of nobody else. Nothing about its
#: routing is invented here -- the token, its predicate and the interpreter are
#: all pre-existing.
#:
#: This is a scientific consequence, not a formatting choice: it means an
#: additional question is presented unconditionally to every screened-in
#: respondent rather than behind a construct-specific gate. Recorded as DD-100
#: for the owner to confirm before any real fielding.
ADDITIONAL_GATE_TOKEN = 'Q01_ELIGIBLE'


def is_additional(item: Mapping[str, Any]) -> bool:
    """True for a Section B question. Fixed-core items never carry the marker."""
    return str(item.get('section') or '') == SECTION_ADDITIONAL


def dependencies(question_id: str) -> list[str]:
    return list(_DEPENDENCIES.get(question_id, ['Q01']))


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

def _gate_token(item: Mapping[str, Any], policy: Mapping[str, Any]) -> str:
    token = (policy.get('item_show_gate') or {}).get(item['id'])
    if token is None and is_additional(item):
        # Declared on the item, defaulted to the registered token above, and
        # still required to exist in the policy's predicates -- an additional
        # question cannot name a gate the interpreter does not implement.
        token = item.get('gate_token') or ADDITIONAL_GATE_TOKEN
    if token not in (policy.get('gate') or {}).get('token_predicates', {}):
        raise CqRefused('CQ_GATE_UNREGISTERED')
    return str(token)


def stimulus_requirements(item: Mapping[str, Any],
                          policy: Mapping[str, Any]) -> tuple[str, ...]:
    """Which stimulus kinds this question's show gate depends on."""
    token = _gate_token(item, policy)
    predicate = policy['gate']['token_predicates'][token]
    kinds: list[str] = []
    for clause in predicate.get('clauses') or []:
        if clause.get('op') != 'is_true':
            continue
        kind = FACT_TO_STIMULUS.get(str(clause.get('lhs')))
        if kind and kind not in kinds:
            kinds.append(kind)
    return tuple(kinds)


def declared_requirements(item: Mapping[str, Any],
                          policy: Mapping[str, Any]) -> tuple[str, ...]:
    """Which manifest-level declarations this question's gate depends on."""
    token = _gate_token(item, policy)
    predicate = policy['gate']['token_predicates'][token]
    fields: list[str] = []
    for clause in predicate.get('clauses') or []:
        if clause.get('op') != 'is_true':
            continue
        field = DECLARED_FACTS.get(str(clause.get('lhs')))
        if field and field not in fields:
            fields.append(field)
    return tuple(fields)


def _item(composed_item: Mapping[str, Any], source: Mapping[str, Any],
          policy: Mapping[str, Any], labels_module) -> dict[str, Any]:
    """One manifest question, built from the contract item and the composition.

    ``validation`` must be the **whole** contract item: ``verify_release``
    compares ``item['validation'] != source`` where ``source`` is the contract
    record itself, so a reduced copy is refused as CQ_CODEBOOK_MISMATCH. That
    also means the manifest pins the codebook, the stems, the dispositions and
    the refusal routes -- the release cannot drift from the frozen contract.
    """
    qid = str(composed_item['item_id'])
    if qid != source['id']:
        raise CqRefused('CQ_QUESTION_IDENTITIES_INVALID')
    if composed_item.get('response_format') != source['type']:
        raise CqRefused('CQ_CODEBOOK_MISMATCH')

    codes = list(source['codes'])
    table = labels_module.labels_for(qid, codes)
    stem = composed_item.get('stem')
    if not isinstance(stem, str) or not stem.strip():
        raise CqRefused('CQ_STIMULUS_VERSION_INVALID')

    return {
        'id': qid,
        'type': source['type'],
        'codes': codes,
        'validation': deepcopy(dict(source)),
        'required_for_presentation': True,
        # Requiredness for answering is read off the contract's own class
        # taxonomy: ESSENTIAL_SCREEN / ESSENTIAL / ESSENTIAL_CONDITIONAL must be
        # answered by every unit the gate admits; CONDITIONAL_R07 and
        # OPTIONAL_CONTEXT may be skipped.
        'required_for_answer': str(source.get('class') or '').startswith('ESSENTIAL'),
        'wording': {'EN': stem},
        'labels': {'EN': dict(table)},
        'dependencies': dependencies(qid),
        'stimulus_dependencies': list(stimulus_requirements(source, policy)),
        # No governed feature bank exists for Q10 (contract
        # ``feature_bank.approved_bank`` is null, gate G06_APPROVAL_PENDING), so
        # no item may declare feature ids. DD-083.
        'feature_ids': [],
        'version': str(composed_item.get('question_version') or ''),
    }


def _additional_item(composed_item: Mapping[str, Any],
                     policy: Mapping[str, Any]) -> dict[str, Any]:
    """One Section B manifest question, built from its own composition record.

    An additional question has no frozen codebook entry, so there is no
    ``source`` to compare it against. Its contract *is* the composition record:
    :func:`sitewise.services.questionnaire_composition.build_additional_item`
    already fixed the wording, the options, the objective and the measurement
    binding, and this function copies them rather than re-deriving anything.

    ``validation`` therefore carries the composition record itself. That keeps
    one rule true for both sections -- ``verify_release`` requires
    ``item['validation']`` to be the record the item was built from -- without
    pretending an additional question has a governed template.

    Nothing here can promote authority. ``fielding_authorized`` and
    ``publication_authorized`` are not read, copied or consulted: authorisation
    is decided by ``authorization_exclusions`` and by the release authorisation
    step, not by an item.
    """
    qid = str(composed_item['item_id'])
    stem = composed_item.get('stem')
    if not isinstance(stem, str) or not stem.strip():
        raise CqRefused('CQ_STIMULUS_VERSION_INVALID')

    response_format = composed_item.get('response_format')
    if not isinstance(response_format, str) or not response_format:
        raise CqRefused('CQ_CODEBOOK_MISMATCH')

    options = [o for o in (composed_item.get('options') or [])
               if isinstance(o, Mapping) and str(o.get('code') or '').strip()]
    codes = [str(o['code']) for o in options]
    if len(codes) < 2 or len(set(codes)) != len(codes):
        # A question a respondent cannot answer two ways is not a question.
        raise CqRefused('CQ_ADDITIONAL_OPTIONS_INVALID')
    labels = {str(o['code']): str(o.get('label') or '').strip() for o in options}
    if any(not label for label in labels.values()):
        # Inventing a respondent-facing label is exactly what the fixed core's
        # label contract exists to prevent. Refuse instead.
        raise CqRefused('CQ_ADDITIONAL_LABEL_MISSING')

    probe = {'id': qid, 'section': SECTION_ADDITIONAL}
    # The composition record is carried as ``validation`` so the release can be
    # traced to the exact approved candidate. The owner's intended option is
    # entrepreneur-only metadata and is removed here rather than at read time:
    # the respondent session view returns the manifest verbatim, so a key left in
    # this block would be disclosed to the customer and would tell them which
    # answer the business hopes for — biasing the measurement the intention is
    # later compared against.
    #
    # Nothing is lost by removing it: the item still records ``candidate_id``,
    # which is the question version, and the intention lives on
    # ``m2_qg_candidate_reviews`` keyed by that same candidate. The report
    # generator joins on it. Copying the codes into a customer-readable document
    # would be the only way to make them leak.
    validation = {key: value for key, value in dict(composed_item).items()
                  if not str(key).startswith('owner_intended')}
    return {
        'id': qid,
        'section': SECTION_ADDITIONAL,
        'source': 'QG_CANDIDATE',
        'type': response_format,
        'codes': codes,
        'validation': deepcopy(validation),
        'required_for_presentation': True,
        'required_for_answer': True,
        'wording': {'EN': stem},
        'labels': {'EN': labels},
        # Asked only of screened-in respondents, which is the whole meaning of
        # the inherited gate; Q01 therefore precedes it.
        'dependencies': ['Q01'],
        'stimulus_dependencies': list(stimulus_requirements(probe, policy)),
        'feature_ids': [],
        'version': str(composed_item.get('measurement_version')
                       or composed_item.get('candidate_state') or ''),
        'gate_token': ADDITIONAL_GATE_TOKEN,
        # Provenance, so a release can be traced back to the exact approved
        # candidate and the measurement it was written for.
        'candidate_id': qid,
        'objective_id': composed_item.get('objective_id'),
        'objective_admission_id': composed_item.get('objective_admission_id'),
        'measurement_id': composed_item.get('measurement_id'),
        'measurement_version': composed_item.get('measurement_version'),
        'semantic_basis': composed_item.get('semantic_basis'),
        'review_decision': composed_item.get('review_decision'),
    }


def build_manifest(composed: Mapping[str, Any], *,
                   contract: Mapping[str, Any],
                   policy: Mapping[str, Any],
                   assignment: Mapping[str, Any],
                   stimuli: Mapping[str, Mapping[str, Any]],
                   bank_version: str,
                   version: str,
                   title: str,
                   consent_version: str,
                   consent_text: str,
                   optional_context: bool = False,
                   mode: str = 'C0',
                   q02_policy: str = 'UNDECIDED',
                   labels_module=None) -> dict[str, Any]:
    """Build the ``cq-manifest/1`` DTO. Pure: no I/O, no clock, no randomness."""
    if labels_module is None:
        from sitewise.project1 import cq_option_labels as labels_module

    spec_version = str(contract['spec_version'])
    sources = list(contract['items'])
    items = list(composed.get('items') or [])
    # Section A must still be the frozen codebook, complete and in order. A
    # shorter fixed core is a different instrument, not a subset of this one.
    fixed_items = [i for i in items if not is_additional(i)]
    additional_items = [i for i in items if is_additional(i)]
    if [str(i.get('item_id')) for i in fixed_items] != [s['id'] for s in sources]:
        raise CqRefused('CQ_QUESTION_IDENTITIES_INVALID')

    # Section B is additive. Each additional question must have a stable
    # identity of its own and must not shadow a governed item.
    seen_ids = {s['id'] for s in sources}
    for composed_item in additional_items:
        qid = str(composed_item.get('item_id'))
        if qid in seen_ids:
            raise CqRefused('CQ_QUESTION_IDENTITIES_INVALID')
        seen_ids.add(qid)

    questions = []
    for composed_item, source in zip(fixed_items, sources):
        row = _item(composed_item, source, policy, labels_module)
        row['version'] = spec_version
        questions.append(row)
    # Additional questions follow the fixed core, so every governed dependency
    # index still points backwards.
    for composed_item in additional_items:
        questions.append(_additional_item(composed_item, policy))

    for kind, stimulus in stimuli.items():
        if kind not in FACT_TO_STIMULUS.values():
            raise CqRefused('CQ_STIMULUS_VERSION_INVALID')
        if not stimulus.get('version'):
            raise CqRefused('CQ_STIMULUS_VERSION_INVALID')
        if not (stimulus.get('text') or {}).get('EN'):
            raise CqRefused('CQ_STIMULUS_TEXT_UNAVAILABLE')

    manifest = {
        'contract_version': CONTRACT_VERSION,
        'builder_version': BUILDER_VERSION,
        'lane': 'ENTREPRENEUR_SPECIFIC',
        'locales': ['EN'],
        'spec_version': spec_version,
        'version': version,
        'title': title,
        'bank_version': bank_version,
        'policy_version': str(policy.get('version')),
        # `CustomerQuestionnaireService._release` refuses a manifest whose
        # `source_hash` is not the frozen CUST03 hash, and whose `policy_hash`
        # does not equal the stored one. Pinning both here means the release is
        # bound to the exact codebook and policy it was built from, and a later
        # policy edit cannot silently reinterpret an existing release.
        'source_hash': SOURCE_SHA,
        'policy_hash': digest(policy),
        'consent_version': consent_version,
        'consent_text': {'EN': consent_text},
        'mode': mode,
        'q02_policy': q02_policy,
        'optional_context': bool(optional_context),
        'questions': questions,
        'stimuli': {k: deepcopy(dict(v)) for k, v in stimuli.items()},
        'stimulus_order': sorted(stimuli),
        'label_contract_version': labels_module.CONTRACT_VERSION,
        'label_fingerprint': labels_module.fingerprint(),
        'assignment': deepcopy(dict(assignment)),
        'authorized_question_ids': [],
    }
    manifest['authorized_question_ids'] = [
        q['id'] for q in questions
        if not authorization_exclusions(q, composed, manifest, policy)
    ]
    return manifest


# ---------------------------------------------------------------------------
# Authorisation
# ---------------------------------------------------------------------------

def authorization_exclusions(item: Mapping[str, Any],
                             composed: Mapping[str, Any],
                             manifest: Mapping[str, Any],
                             policy: Mapping[str, Any]) -> list[str]:
    """Reasons this question may not be asked by this release. Empty means yes.

    Every reason is a *stated* exclusion rather than a silent omission, so the
    operator sees what the document does not contain before publishing it.
    """
    reasons: list[str] = []
    qid = str(item['id'])

    if (not is_additional(item) and not item.get('feature_ids')
            and item['type'] == 'ordinal_matrix'):
        # An ordinal matrix with no features is not a respondent-facing question:
        # the respondent would be asked to rate "each feature" of nothing.
        #
        # This is a fixed-core rule. An additional question has no governed
        # feature bank by construction, so applying it there would exclude every
        # additional matrix question for a reason that cannot be remedied.
        reasons.append('NO_GOVERNED_FEATURE_BANK')

    missing = [
        kind for kind in item['stimulus_dependencies']
        if kind not in (manifest.get('stimuli') or {})
    ]
    if missing:
        reasons.append('STIMULUS_NOT_IN_RELEASE:' + ','.join(missing))

    # The item itself, not its ``validation`` block. For a fixed-core question
    # the two are equivalent (``validation`` is the contract record, which
    # carries the same ``id``); for an additional question ``validation`` is the
    # composition record, which has ``item_id`` and no ``id`` at all. Passing
    # the item is correct for both and does not change the fixed path.
    for field in declared_requirements(item, policy):
        if not manifest.get(field):
            reasons.append('DECLARATION_OFF:' + field)

    row = next((i for i in composed.get('items') or []
                if str(i.get('item_id')) == qid), {})
    if row.get('population_status') not in (None, 'COMPLETE',
                                            'NO_SUBSTITUTION_REQUIRED'):
        reasons.append('SLOT_UNRESOLVED')
    if row.get('unresolved_slots'):
        reasons.append('SLOT_UNRESOLVED')
    return reasons


#: Plain-English sentence for each Section A authorisation exclusion code.
#:
#: §15 asked why only seven of thirteen fixed questions are authorised. The
#: answer is that six are excluded by *design*: three need a stimulus this
#: release does not carry, and three need an optional declaration that this
#: publication path does not carry. Reporting only the code made all six look
#: like defects. The sentence says what the code means and that the exclusion is
#: expected, so a reader can tell a structural exclusion from a failure.
#:
#: The optional declaration is *not* an owner preference: ``publish`` refuses
#: any non-default option with ``CQ_PUBLICATION_OPTIONS_UNAUTHORISED``, so no
#: caller can switch ``optional_context`` on for this release. The sentence must
#: not tell the owner they chose this.
#:
#: ``{detail}`` is the part after the colon in the reason string (the stimulus
#: kind or declaration field).
EXCLUSION_EXPLANATIONS = {
    'STIMULUS_NOT_IN_RELEASE': (
        "This question depends on the '{detail}' stimulus, which this release "
        'does not include. It is excluded by design, not because the question '
        'or the questionnaire is defective.'
    ),
    'DECLARATION_OFF': (
        "This question depends on the optional '{detail}' declaration, which "
        'this release does not carry. Optional declarations cannot be enabled '
        'on this publication path, so the question is excluded by design, not '
        'by a validation failure.'
    ),
    'NO_GOVERNED_FEATURE_BANK': (
        'This question asks the respondent to rate a governed feature list, and '
        'no feature bank is attached to this release, so there is nothing to '
        'rate. It is excluded by design.'
    ),
    'SLOT_UNRESOLVED': (
        'A required wording slot for this question is unresolved, so the '
        'question cannot be rendered until the declaration is supplied.'
    ),
}


def explain_exclusion(reason: str) -> str:
    """The plain-English sentence for one Section A exclusion reason.

    ``reason`` is the raw token the plan records, e.g.
    ``STIMULUS_NOT_IN_RELEASE:menu``. An unknown code still produces a sentence
    naming it, so a future exclusion is never silently unexplained.
    """
    token = str(reason or '').strip()
    code, _, detail = token.partition(':')
    template = EXCLUSION_EXPLANATIONS.get(code)
    if template is None:
        return f'This question was excluded for {token or "an unstated reason"}.'
    return template.format(detail=detail)


#: Codes that describe the *configuration of this release* rather than a defect
#: in the question itself. Listed explicitly so that a code added later is never
#: silently reported as expected: an unrecognised code is not structural until
#: someone decides that it is.
STRUCTURAL_EXCLUSION_CODES = frozenset({
    'STIMULUS_NOT_IN_RELEASE',
    'DECLARATION_OFF',
    'NO_GOVERNED_FEATURE_BANK',
})


def exclusion_is_structural(reason: str) -> bool:
    """Whether one raw exclusion token is a structural exclusion.

    Derived from the code, never assumed. ``SLOT_UNRESOLVED`` is deliberately
    absent: a required wording slot that could not be filled is a gap to close,
    not a property of the release.
    """
    return str(reason or '').split(':', 1)[0].strip() in STRUCTURAL_EXCLUSION_CODES


def plan(manifest: Mapping[str, Any], composed: Mapping[str, Any],
         contract: Mapping[str, Any],
         policy: Mapping[str, Any]) -> dict[str, Any]:
    """Explain the authorisation of every question, before anything is written."""
    rows = []
    for item in manifest['questions']:
        reasons = authorization_exclusions(item, composed, manifest, policy)
        rows.append({
            'question_id': item['id'],
            # Which section the question belongs to, so an operator reading the
            # plan can see the fixed core and the additional questions as the
            # two different things they are.
            'section': item.get('section') or 'A_FIXED_CORE',
            'authorized': not reasons,
            'reasons': reasons,
            'stimulus_dependencies': item['stimulus_dependencies'],
            # Resolved from the item, not from the frozen contract: an
            # additional question has no contract entry to look up.
            'gate': _gate_token(item, policy),
            'option_count': len(item['codes']),
        })
    return {
        'contract_version': 'cq-release-plan/1',
        'builder_version': BUILDER_VERSION,
        'question_count': len(rows),
        'authorized_count': sum(1 for r in rows if r['authorized']),
        'excluded_count': sum(1 for r in rows if not r['authorized']),
        'questions': rows,
        'stimuli': sorted(manifest.get('stimuli') or {}),
        'manifest_hash': digest(manifest),
        'label_fingerprint': manifest.get('label_fingerprint'),
    }


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

def release_id_for(manifest_hash: str) -> UUID:
    """Deterministic release identity, so republishing is a read."""
    return uuid5(NAMESPACE_URL, 'sitewise:cq:release:' + manifest_hash)


def assignment_slots(questions: list[Mapping[str, Any]]) -> dict[str, tuple]:
    """Slot map, derived exactly as ``CustomerQuestionnaireService._release``.

    Q10 is the only multi-slot item: one slot per feature, ``Q10:<feature>``.
    With no governed feature bank that branch never fires today, but the mapping
    is written to the same rule so a future bank does not need a second one.
    """
    expected: dict[str, tuple] = {}
    for q in questions:
        slots = ([q['id'] + ':' + f for f in q['feature_ids']]
                 if q['id'] == 'Q10' and q['feature_ids'] else [q['id']])
        for slot in slots:
            expected[slot] = (q['version'], digest(q), q['id'])
    return expected


def release_rows(manifest: Mapping[str, Any], policy: Mapping[str, Any],
                 *, release_id: UUID, source_class: str) -> dict[str, Any]:
    """The three row sets, with hashes computed exactly once here."""
    if source_class not in SOURCE_CLASSES:
        raise CqRefused('CQ_SOURCE_CLASS_INVALID')
    manifest_hash = digest(manifest)
    policy_hash = digest(policy)
    if manifest.get('policy_hash') not in (None, policy_hash):
        raise CqRefused('CQ_POLICY_HASH_MISMATCH')
    return {
        'bank': {
            'version': manifest['bank_version'],
            'content_hash': digest(manifest['questions']),
            'questions_json': deepcopy(manifest['questions']),
        },
        'release': {
            'id': release_id,
            'manifest_hash': manifest_hash,
            'policy_hash': policy_hash,
            'manifest_json': deepcopy(dict(manifest)),
            'policy_json': deepcopy(dict(policy)),
            'source_class': source_class,
        },
        'assignments': [
            {
                'release_id': release_id,
                'slot_id': slot,
                'question_id': qid,
                'question_version': version,
                'bank_version': manifest['bank_version'],
                'content_hash': content_hash,
            }
            for slot, (version, content_hash, qid)
            in assignment_slots(manifest['questions']).items()
        ],
    }


def publish(unit, manifest: Mapping[str, Any], policy: Mapping[str, Any], *,
            contract: Mapping[str, Any], reference: Any, actor_id: str,
            source_class: str = 'SYNTHETIC_FIXTURE',
            templates: Mapping[str, str] | None = None) -> dict[str, Any]:
    """Verify, bind, then write -- in that order, inside the caller's transaction.

    The caller owns the transaction (``PostgresCqStore.open`` rolls back on any
    refusal and commits last), so a refusal here leaves no bank version, no
    release and no assignment behind. That is why ``assert_authoritative_binding``
    is called between the verification and the first INSERT rather than after it.
    """
    from sitewise.project1.cq_entrepreneur_adapter import (
        assert_authoritative_binding, load_authoritative,
    )

    verify_release(manifest, policy, contract, reference)

    authoritative = load_authoritative(unit.session, manifest, actor_id)
    assert_authoritative_binding(manifest, authoritative, actor_id)
    if templates is not None:
        from sitewise.project1.cq_entrepreneur_adapter import verify_wording
        verify_wording(manifest, templates)

    rows = release_rows(manifest, policy, release_id=release_id_for(
        digest(manifest)), source_class=source_class)

    existing = unit.release_by_manifest_hash(rows['release']['manifest_hash'])
    if existing is not None:
        if existing['id'] != rows['release']['id']:
            raise CqRefused('CQ_RELEASE_IDEMPOTENCY_CONFLICT')
        stored = unit.assignments(existing['id'])
        if {(a['slot_id'], a['content_hash']) for a in stored} != {
                (a['slot_id'], a['content_hash']) for a in rows['assignments']}:
            raise CqRefused('CQ_ASSIGNMENT_VERSION_INVALID')
        return {'state': 'ALREADY_PUBLISHED', 'release': existing,
                'assignments': stored, 'manifest_hash': rows['release']['manifest_hash']}

    bank = unit.bank(rows['bank']['version'])
    if bank is not None and bank['content_hash'] != rows['bank']['content_hash']:
        # The bank table is append-only and keyed by version: the same version
        # can never hold two question sets. Mint a new version instead.
        raise CqRefused('CQ_BANK_VERSION_COLLISION')
    if bank is None:
        unit.insert_bank(**rows['bank'])
    unit.insert_release(**rows['release'])
    for row in rows['assignments']:
        unit.insert_assignment(**row)
    return {'state': 'PUBLISHED', 'release': rows['release'],
            'assignments': rows['assignments'],
            'manifest_hash': rows['release']['manifest_hash']}


__all__ = [
    'ADDITIONAL_GATE_TOKEN', 'BUILDER_VERSION', 'CONTRACT_VERSION',
    'DECLARED_FACTS', 'FACT_TO_STIMULUS', 'SECTION_ADDITIONAL',
    'SOURCE_CLASSES', 'assignment_slots', 'authorization_exclusions',
    'build_manifest', 'declared_requirements', 'dependencies', 'is_additional',
    'plan', 'publish', 'release_id_for', 'release_rows',
    'stimulus_requirements',
]
