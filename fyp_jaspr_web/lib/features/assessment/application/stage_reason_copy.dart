/// Turns the progress contract's machine reasons into sentences a reader can act
/// on.
///
/// `sitewise-assessment-progress/1` names every blocker with a stable token
/// (`OBJECTIVE_CONTRACT_UNAVAILABLE_FOR_INSTRUMENT`, `CURRENT_CONFIRMATION_REQUIRED`,
/// …) precisely so a surface cannot invent its own wording for the same state.
/// This module is the **one** place those tokens become prose. It does not
/// decide progress: the backend's `evaluate()` remains the only authority on
/// whether a stage is COMPLETE, and nothing here can mark anything complete.
///
/// Two distinctions matter to the reader and are carried explicitly:
///
/// * [StageReasonOwner.you] — the blocker waits on the entrepreneur's own next
///   action, so the copy can say what to do.
/// * [StageReasonOwner.system] — the blocker is a contract or governance hold.
///   No action on this page can clear it, and saying "do this next" would be a
///   lie that sends the reader round the same loop again.
library;

/// Who the blocker is waiting on.
enum StageReasonOwner {
  /// The entrepreneur's own next action can clear it.
  you,

  /// A contract, adoption or governance hold. Nothing on this page clears it.
  system,
}

/// One reason, rendered for a reader.
final class StageReasonCopy {
  /// The sentence to show. Never the raw token.
  final String message;

  /// Who the blocker is waiting on.
  final StageReasonOwner owner;

  const StageReasonCopy(this.message, this.owner);

  /// True when the reader can do something about it here.
  bool get isYourAction => owner == StageReasonOwner.you;
}

/// The copy for a reason token, or null when there is no reason to show.
///
/// An unrecognised token is **not** hidden: it is de-tokenised
/// (`SOME_NEW_HOLD` → "Some new hold") and reported as a system hold, because a
/// blocker this build does not know about is not the reader's to fix and must
/// still be visible.
StageReasonCopy? stageReasonCopy(String? token) {
  final key = token?.trim();
  if (key == null || key.isEmpty) return null;
  final known = _known[key];
  if (known != null) return known;
  return StageReasonCopy(_humanise(key), StageReasonOwner.system);
}

/// The sentence for [token], or null when there is nothing to say.
String? stageReasonMessage(String? token) => stageReasonCopy(token)?.message;

/// Whether the entrepreneur's own action can clear [token].
bool stageReasonIsYourAction(String? token) =>
    stageReasonCopy(token)?.isYourAction ?? false;

/// `SOME_NEW_HOLD` → `Some new hold`.
///
/// Used only for a token this build does not recognise, so an unknown hold is
/// still readable instead of printing an enum name at the reader.
String _humanise(String token) {
  final words = token
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  if (words.isEmpty) return token;
  return '${words[0].toUpperCase()}${words.substring(1)}';
}

/// Every token that can reach a stage's `reason` field, plus the composition
/// and preview codes forwarded from their own contracts.
///
/// Two vocabularies, because the backend has two channels:
///
/// * `sitewise-assessment-progress/1` constants, for stages 1, 2 and 5 and for
///   stage 3's *fallback* reason;
/// * `sitewise-stage3-completion/3` predicate reasons, which
///   `assessment_progress._stage3_reason()` forwards verbatim as stage 3's
///   reason whenever a T3 predicate fails.
///
/// Keys are the wire values and must not be reworded here; only the sentences
/// are presentation. A token absent from this map still renders (see
/// [stageReasonCopy]), so adding a reason on the server can never blank a
/// section of the page — but it *will* read like a machine code, which is why
/// the completeness test enumerates both vocabularies.
const Map<String, StageReasonCopy> _known = {
  // -- stage 1 --------------------------------------------------------------
  'PROPERTY_NOT_SELECTED': StageReasonCopy(
    'No property is attached to this assessment yet.',
    StageReasonOwner.you,
  ),
  'STAGE_1_INCOMPLETE': StageReasonCopy(
    'Select a property before this stage can be assessed.',
    StageReasonOwner.you,
  ),

  // -- stage 2 --------------------------------------------------------------
  'M2_NOT_LINKED': StageReasonCopy(
    'This assessment is not linked to a business declaration yet.',
    StageReasonOwner.you,
  ),
  'CURRENT_CONFIRMATION_REQUIRED': StageReasonCopy(
    'Confirm your current business declaration. Changing an answer makes the '
        'earlier confirmation out of date, so it has to be confirmed again.',
    StageReasonOwner.you,
  ),
  'M2_STORAGE_UNAVAILABLE': StageReasonCopy(
    'Your business declaration store could not be read, so progress cannot be '
        'verified. Nothing has been marked complete.',
    StageReasonOwner.system,
  ),

  // -- stage 3 --------------------------------------------------------------
  'NO_RESEARCH_OBJECTIVE': StageReasonCopy(
    'No research objective has been recorded for this assessment yet.',
    StageReasonOwner.you,
  ),
  'OBJECTIVE_AUTHORITY_UNVERIFIED': StageReasonCopy(
    'The recorded objectives no longer match your current declaration, so they '
        'cannot count as evidence. Confirm the declaration, then record the '
        'objective again.',
    StageReasonOwner.you,
  ),
  'OBJECTIVE_CONTRACT_UNAVAILABLE_FOR_INSTRUMENT': StageReasonCopy(
    'This kind of declaration has no adopted way to record a research '
        'objective, so this stage cannot be completed from this page. It is '
        'waiting on a system contract, not on anything you can do here.',
    StageReasonOwner.system,
  ),
  'STAGE_2_INCOMPLETE': StageReasonCopy(
    'Complete the business preferences stage first.',
    StageReasonOwner.you,
  ),
  'STAGE_3_CONTRACT_PREDICATES_UNSATISFIED': StageReasonCopy(
    'The Stage 3 completion contract is not satisfied for this assessment yet. '
        'Its own conditions decide completion, not the number of objectives '
        'recorded.',
    StageReasonOwner.system,
  ),

  // -- stage 3: the completion contract's own predicate vocabulary ----------
  //
  // `assessment_progress._stage3_reason()` does not emit a progress-contract
  // constant. It forwards `blockers[0]["reason"]` — the **first failing T3
  // predicate's** reason — verbatim. So stage 3 can surface the whole
  // `sitewise-stage3-completion/3` vocabulary, which is a different set of
  // strings from everything above. Until these were mapped, every one of them
  // fell through to the de-tokenising fallback and printed a machine code at
  // the reader ("Held: No evaluation").
  //
  // T3-01 assessment ownership
  'SUBJECT_NOT_FOUND': StageReasonCopy(
    'This assessment could not be read for your account, so no stage evidence '
        'can be verified.',
    StageReasonOwner.system,
  ),
  'OWNERSHIP_MISMATCH': StageReasonCopy(
    'This assessment is not owned by the signed-in account, so its evidence '
        'cannot be verified here.',
    StageReasonOwner.system,
  ),

  // T3-02 M2 confirmation
  'NO_CURRENT_CONFIRMATION': StageReasonCopy(
    'Your business preferences have not been confirmed, so the research stage '
        'has no agreed starting point.',
    StageReasonOwner.you,
  ),
  'CONFIRMATION_STALE': StageReasonCopy(
    'Your preferences changed after they were confirmed, so the confirmation '
        'no longer covers your current answers. Confirm them again.',
    StageReasonOwner.you,
  ),

  // T3-03 business context
  'NO_CONTEXT_FOR_CONFIRMATION': StageReasonCopy(
    'No business context was stored with that confirmation, so the research '
        'stage has nothing to build on.',
    StageReasonOwner.system,
  ),
  'CONTEXT_NOT_CURRENT': StageReasonCopy(
    'The stored business context belongs to an earlier revision of your '
        'preferences, so it no longer matches what was confirmed.',
    StageReasonOwner.system,
  ),

  // T3-04 BDJ execution disposition
  'NO_EVALUATION': StageReasonCopy(
    'No business evaluation (BDJ) has been recorded for this assessment yet, so '
        'the research stage has no findings to build on. The evaluation is a '
        'governed dispatch, not a button on this page.',
    StageReasonOwner.system,
  ),
  'EVALUATION_NOT_VALID': StageReasonCopy(
    'The last business evaluation did not produce a valid result, so it cannot '
        'count as evidence for this stage.',
    StageReasonOwner.system,
  ),
  'EVALUATION_NOT_AUTHORIZED': StageReasonCopy(
    'The business evaluation ran without a recorded authorisation, so its '
        'result cannot be used as evidence.',
    StageReasonOwner.system,
  ),
  'EVALUATION_PROVENANCE_MISMATCH': StageReasonCopy(
    'The business evaluation was computed from an earlier version of your '
        'preferences, so it no longer describes your current answers.',
    StageReasonOwner.system,
  ),
  'EVALUATION_CONTEXT_MISMATCH': StageReasonCopy(
    'The business evaluation was computed against a different business context '
        'than the one on this assessment.',
    StageReasonOwner.system,
  ),
  'EVALUATION_RULESET_UNVERIFIED': StageReasonCopy(
    'The evaluation could not be checked against the rules and prompt that are '
        'current today, because the adopted identity could not be resolved. That '
        'is a system hold, not something you can change on this page.',
    StageReasonOwner.system,
  ),
  'EVALUATION_RULESET_SUPERSEDED': StageReasonCopy(
    'The evaluation rules changed after this evaluation ran, so it has to be '
        're-run before it can count.',
    StageReasonOwner.system,
  ),
  'SOURCE_FINGERPRINT_UNAVAILABLE': StageReasonCopy(
    'The fingerprint of your confirmed answers could not be computed, so the '
        'evaluation cannot be tied to what you actually said.',
    StageReasonOwner.system,
  ),

  // T3-05 objective resolution
  'ZERO_PROPOSALS_WITHOUT_EVALUATION': StageReasonCopy(
    'No research objective has been proposed, and no evaluation established '
        'that having none was the right answer. An empty list is not evidence.',
    StageReasonOwner.system,
  ),
  'UNDECIDED_PROPOSAL': StageReasonCopy(
    'A proposed research objective is still waiting for your approve or reject '
        'decision.',
    StageReasonOwner.you,
  ),
  'APPROVED_NOT_ADMITTED': StageReasonCopy(
    'A research objective was approved but never admitted, so it cannot count '
        'as resolved yet.',
    StageReasonOwner.system,
  ),

  // T3-06 registration of the six fixed objectives
  'OBJECTIVES_NOT_REGISTERED': StageReasonCopy(
    'Not all six fixed research objectives are accounted for. Each one has to '
        'be either selected with its own objective or explicitly left out.',
    StageReasonOwner.you,
  ),
  'RESEARCH_TOPIC_ANSWER_UNAVAILABLE': StageReasonCopy(
    'Your preferences have no research-topic answer recorded, so the six fixed '
        'objectives cannot be registered.',
    StageReasonOwner.you,
  ),
  'BLOCKERS_PRESENT': StageReasonCopy(
    'An earlier research-stage condition is still failing, so this stage cannot '
        'close yet.',
    StageReasonOwner.system,
  ),

  // -- stage 4 --------------------------------------------------------------
  'STAGE_3_INCOMPLETE': StageReasonCopy(
    // "location evidence" is the wire key for step 3, not its name. The stepper
    // calls that step "Business review and research goals"; naming it here the
    // same way is the point of `stage_labels.dart`.
    'Complete the business review and research goals stage first.',
    StageReasonOwner.you,
  ),
  'QUESTIONNAIRE_COMPOSITION_INVALID': StageReasonCopy(
    'The composed questionnaire contradicts itself, so it cannot be approved. '
        'This needs a system fix rather than another review.',
    StageReasonOwner.system,
  ),
  'CANDIDATE_REVIEW_PENDING': StageReasonCopy(
    'Some research questions still need an approve or reject decision.',
    StageReasonOwner.you,
  ),
  'CANDIDATE_REJECTED': StageReasonCopy(
    'Every current question was rejected, so none can carry the objective. '
        'Approve at least one question.',
    StageReasonOwner.you,
  ),
  'QUESTION_GENERATION_AUTHORIZATION_REQUIRED': StageReasonCopy(
    'No approved question exists for this objective, and generating one needs '
        'its own authorisation. Nothing you can do on this page starts it.',
    StageReasonOwner.system,
  ),

  // -- stage 5 --------------------------------------------------------------
  'STAGE_4_INCOMPLETE': StageReasonCopy(
    'Complete the question review stage first.',
    StageReasonOwner.you,
  ),
  'QUESTIONNAIRE_PREVIEW_CONTRACT_UNADOPTED': StageReasonCopy(
    'The questionnaire preview contract is not adopted, so the preview stops at '
        'a draft and this stage cannot be marked complete.',
    StageReasonOwner.system,
  ),
};
