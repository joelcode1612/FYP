import '../data/questionnaire_repository.dart';
import 'mock_routing.dart';
import 'question.dart';

enum SurveyPage { welcome, question, review, submitted }

class QuestionnaireState {
  final AppLanguage language;
  final SurveyPage page;
  final bool consent;
  final DemoConfig config;
  final Map<String, Answer> answers;

  /// Actual exposure history, including questions subsequently removed.
  final Set<String> displayed;
  final Set<String> skipped;
  final String currentId;
  final bool editing;
  final String? error;
  QuestionnaireState({
    this.language = AppLanguage.en,
    this.page = SurveyPage.welcome,
    this.consent = false,
    this.config = const DemoConfig(),
    Map<String, Answer> answers = const {},
    Set<String> displayed = const {},
    Set<String> skipped = const {},
    this.currentId = 'Q01',
    this.editing = false,
    this.error,
  }) : answers = Map.unmodifiable(answers),
       displayed = Set.unmodifiable(displayed),
       skipped = Set.unmodifiable(skipped);

  QuestionnaireState copyWith({
    AppLanguage? language,
    SurveyPage? page,
    bool? consent,
    DemoConfig? config,
    Map<String, Answer>? answers,
    Set<String>? displayed,
    Set<String>? skipped,
    String? currentId,
    bool? editing,
    String? error,
  }) => QuestionnaireState(
    language: language ?? this.language,
    page: page ?? this.page,
    consent: consent ?? this.consent,
    config: config ?? this.config,
    answers: answers ?? this.answers,
    displayed: displayed ?? this.displayed,
    skipped: skipped ?? this.skipped,
    currentId: currentId ?? this.currentId,
    editing: editing ?? this.editing,
    error: error,
  );

  List<Question> get bank => const QuestionnaireRepository().questions;
  List<Question> get route => MockRouting.route(bank, answers, config);
  Question get current => bank.firstWhere((q) => q.id == currentId);
  int get index => route.indexWhere((q) => q.id == currentId);
  int get shownCount => route.where((q) => displayed.contains(q.id)).length;
  int get answeredCount => route.where(isAnswered).length;
  int get optionalSkippedCount => route
      .where(
        (q) =>
            q.optional &&
            displayed.contains(q.id) &&
            skipped.contains(q.id) &&
            !isAnswered(q),
      )
      .length;
  int get removedExposureCount =>
      displayed.where((id) => !route.any((q) => q.id == id)).length;
  List<Question> get missingRequired =>
      route.where((q) => !q.optional && !isAnswered(q)).toList();
  bool get canSubmit =>
      consent &&
      page == SurveyPage.review &&
      missingRequired.isEmpty &&
      shownCount == route.length;
  double get progress => route.isEmpty
      ? 0
      : route
                .where(
                  (q) =>
                      isAnswered(q) || (q.optional && skipped.contains(q.id)),
                )
                .length /
            route.length;

  bool isAnswered(Question q) {
    if (!displayed.contains(q.id)) return false;
    final answer = answers[q.id];
    if (answer == null || answer.isEmpty) return false;
    final codes = q.options.map((o) => o.code).toSet();
    if (q.kind == QuestionKind.matrix) {
      return answer.codes.isEmpty &&
          answer.ratings.length == QuestionnaireRepository.features.length &&
          QuestionnaireRepository.features.every(
            (f) => codes.contains(answer.ratings[f.id]),
          );
    }
    if (answer.ratings.isNotEmpty || !answer.codes.every(codes.contains)) {
      return false;
    }
    if (q.kind == QuestionKind.single && answer.codes.length != 1) return false;
    if (q.maxSelections != null && answer.codes.length > q.maxSelections!) {
      return false;
    }
    if (answer.codes.any(q.exclusive.contains) && answer.codes.length > 1) {
      return false;
    }
    return true;
  }
}
