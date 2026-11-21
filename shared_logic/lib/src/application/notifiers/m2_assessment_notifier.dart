/// M2 assessment ViewModel — the "VM" in MVVM.
///
/// Pure Dart (Riverpod core only), so the Flutter app consumes it through
/// `flutter_riverpod` and the Jaspr app through `jaspr_riverpod`. The ViewModel
/// knows nothing about widgets, routes, themes or platform APIs.
///
/// This is the deliberate state pattern for new feature work: Riverpod
/// `Notifier` for the ViewModel, immutable state object, derived values
/// computed rather than stored. It coexists with the pre-existing Cubits in
/// `application/cubits/` — those are not touched here.
library;

import 'package:riverpod/riverpod.dart';

import '../../domain/entities/m2_assessment.dart';
import '../../domain/repositories/m2_questionnaire_repository.dart';
import 'providers.dart';

/// Provides the M2 assessment ViewModel.
final m2AssessmentProvider =
    NotifierProvider<M2AssessmentNotifier, M2AssessmentState>(
      M2AssessmentNotifier.new,
    );

/// Drives one M2 assessment: answers, validation and submission.
class M2AssessmentNotifier extends Notifier<M2AssessmentState> {
  /// The questionnaire definition supplied by the composition root.
  late M2QuestionnaireRepository _questionnaire;

  /// The questionnaire definition this ViewModel is bound to.
  List<M2Item> get items => _questionnaire.answerItems;

  /// Governance/review actions, shown separately from answer fields.
  List<M2Item> get actions => _questionnaire.actions;

  @override
  M2AssessmentState build() {
    _questionnaire = ref.watch(m2QuestionnaireProvider);
    return M2AssessmentState.seeded(_questionnaire.answerItems);
  }

  // --- mutations -------------------------------------------------------

  /// Set a single-value answer ([M2ItemType.choice] or [M2ItemType.text]).
  void setAnswer(String itemId, String value) {
    final next = Map<String, String>.from(state.answers)..[itemId] = value;
    // `showErrors` is deliberately NOT cleared here. The banner recomputes its
    // list from live state, so it shrinks as fields are filled; clearing it on
    // the first keystroke would hide the remaining gaps. It is cleared only by
    // a successful submit (or a reset).
    state = state.copyWith(answers: next);
  }

  /// Toggle one option of a [M2ItemType.multi] answer.
  void toggleMulti(String itemId, String option) {
    final next = <String, Set<String>>{
      for (final entry in state.multi.entries) entry.key: Set<String>.from(entry.value),
    };
    final current = next.putIfAbsent(itemId, () => <String>{});
    if (!current.remove(option)) current.add(option);
    state = state.copyWith(multi: next);
  }

  /// Replace the multi-select answer for [itemId] wholesale.
  void setMulti(String itemId, Set<String> values) {
    final next = <String, Set<String>>{
      for (final entry in state.multi.entries) entry.key: Set<String>.from(entry.value),
    }..[itemId] = Set<String>.from(values);
    state = state.copyWith(multi: next);
  }

  /// Restore every field to its illustrative sample value.
  void resetToSamples() {
    state = M2AssessmentState.seeded(_questionnaire.answerItems);
  }

  /// Clear every answer. Keeps `submitted` false.
  void clearAll() {
    state = M2AssessmentState(
      answers: {for (final i in _questionnaire.answerItems) if (i.type != M2ItemType.multi && i.type != M2ItemType.action) i.id: ''},
      multi: {for (final i in _questionnaire.answerItems) if (i.type == M2ItemType.multi) i.id: <String>{}},
    );
  }

  /// Validate and submit.
  ///
  /// Returns `false` and sets [M2AssessmentState.showErrors] when a required
  /// field is empty — the caller should surface the errors rather than
  /// navigating on.
  bool submit() {
    if (state.missingRequired(_questionnaire.answerItems).isNotEmpty) {
      state = state.copyWith(showErrors: true, submitted: false);
      return false;
    }
    state = state.copyWith(showErrors: false, submitted: true);
    return true;
  }

  // --- derived ---------------------------------------------------------

  /// Answer fields with a value.
  int get answeredCount => state.answeredCount(_questionnaire.answerItems);

  /// Total answer fields (actions excluded).
  int get fieldCount => state.fieldCount(_questionnaire.answerItems);

  /// Completion 0.0–1.0.
  double get progress => state.progress(_questionnaire.answerItems);

  /// Required fields still empty.
  List<M2Item> get missingRequired => state.missingRequired(_questionnaire.answerItems);

  /// Whether every required field is filled.
  bool get isComplete => missingRequired.isEmpty;

  /// Section headings in first-seen order.
  List<String> get sections => M2AssessmentState.sectionsOf(_questionnaire.answerItems);

  /// Items in [section].
  List<M2Item> itemsInSection(String section) =>
      M2AssessmentState.itemsInSection(_questionnaire.answerItems, section);
}
