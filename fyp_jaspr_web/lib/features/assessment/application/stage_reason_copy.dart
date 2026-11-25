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

/// Every token `assessment_progress.evaluate()` can emit, plus the composition
/// and preview codes it forwards from their own contracts.
///
/// Keys are the wire values and must not be reworded here; only the sentences
/// are presentation. A token absent from this map still renders (see
/// [stageReasonCopy]), so adding a reason on the server can never blank a
/// section of the page.
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
