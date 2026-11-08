import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/questionnaire_repository.dart';
import '../model/mock_routing.dart';
import '../model/question.dart';
import '../model/questionnaire_state.dart';

final questionnaireProvider =
    NotifierProvider<QuestionnaireViewModel, QuestionnaireState>(
      QuestionnaireViewModel.new,
    );

/// Shared session ViewModel. Views send intents and render immutable state.
/// All data is held in memory. No analytics, network requests or persistence.
class QuestionnaireViewModel extends Notifier<QuestionnaireState> {
  @override
  QuestionnaireState build() => QuestionnaireState();
  void setLanguage(AppLanguage language) =>
      state = state.copyWith(language: language);
  void setConsent(bool value) {
    if (state.page == SurveyPage.welcome) {
      state = state.copyWith(consent: value);
    }
  }

  void configure(DemoConfig config) {
    if (state.page == SurveyPage.welcome && state.displayed.isEmpty) {
      state = state.copyWith(config: config);
    }
  }

  void start() {
    if (!state.consent || state.page != SurveyPage.welcome) return;
    state = state.copyWith(
      page: SurveyPage.question,
      currentId: 'Q01',
      displayed: {...state.displayed, 'Q01'},
    );
  }

  bool select(String code) {
    if (state.page != SurveyPage.question) return false;
    final q = state.current;
    if (q.kind == QuestionKind.matrix ||
        !q.options.any((o) => o.code == code)) {
      return false;
    }
    final selected = {...?state.answers[q.id]?.codes};
    if (q.kind == QuestionKind.single) {
      selected
        ..clear()
        ..add(code);
    } else if (selected.contains(code)) {
      selected.remove(code);
    } else if (q.exclusive.contains(code)) {
      selected
        ..clear()
        ..add(code);
    } else {
      selected.removeWhere(q.exclusive.contains);
      if (q.maxSelections != null && selected.length >= q.maxSelections!) {
        state = state.copyWith(
          error: LocalText(
            'Select up to ${q.maxSelections} options.',
            'Pilih sehingga ${q.maxSelections} pilihan.',
          ).inLanguage(state.language),
        );
        return false;
      }
      selected.add(code);
    }
    _record(q.id, Answer(codes: selected));
    return true;
  }

  void rate(String featureId, String code) {
    if (state.page != SurveyPage.question ||
        state.current.kind != QuestionKind.matrix ||
        !QuestionnaireRepository.features.any((f) => f.id == featureId) ||
        !state.current.options.any((o) => o.code == code)) {
      return;
    }
    _record(
      state.currentId,
      Answer(
        ratings: {...?state.answers[state.currentId]?.ratings, featureId: code},
      ),
    );
  }

  void _record(String id, Answer answer) {
    final answers = {...state.answers, id: answer};
    final routeIds = MockRouting.route(
      state.bank,
      answers,
      state.config,
    ).map((q) => q.id).toSet();
    // Hidden values never return if the route later expands again.
    answers.removeWhere((key, _) => !routeIds.contains(key));
    state = state.copyWith(
      answers: answers,
      skipped: {...state.skipped}
        ..remove(id)
        ..removeWhere((key) => !routeIds.contains(key)),
    );
  }

  void next() {
    if (state.page != SurveyPage.question) return;
    if (!state.isAnswered(state.current) && !state.current.optional) {
      state = state.copyWith(
        error: const LocalText(
          'Choose an answer to continue. Refusal and uncertainty choices are accepted where offered.',
          'Pilih jawapan untuk meneruskan. Pilihan tidak mahu menjawab dan tidak pasti diterima jika tersedia.',
        ).inLanguage(state.language),
      );
      return;
    }
    if (!state.isAnswered(state.current)) {
      state = state.copyWith(skipped: {...state.skipped, state.currentId});
    }
    final route = state.route;
    if (state.index == route.length - 1) {
      state = state.copyWith(page: SurveyPage.review, editing: false);
    } else {
      final id = route[state.index + 1].id;
      state = state.copyWith(
        currentId: id,
        displayed: {...state.displayed, id},
      );
    }
  }

  void previous() {
    if (state.page == SurveyPage.review) {
      edit(state.route.last.id);
    } else if (state.page == SurveyPage.question && state.index > 0) {
      state = state.copyWith(currentId: state.route[state.index - 1].id);
    } else if (state.page == SurveyPage.question) {
      state = state.copyWith(page: SurveyPage.welcome);
    }
  }

  void edit(String id) {
    if (state.page != SurveyPage.review ||
        !state.route.any((q) => q.id == id)) {
      return;
    }
    state = state.copyWith(
      page: SurveyPage.question,
      currentId: id,
      editing: true,
      displayed: {...state.displayed, id},
    );
  }

  void returnToReview() {
    if (state.editing) {
      state = state.copyWith(page: SurveyPage.review, editing: false);
    }
  }

  void skipOptional() {
    if (state.page != SurveyPage.question || !state.current.optional) return;
    state = state.copyWith(
      answers: {...state.answers}..remove(state.currentId),
      skipped: {...state.skipped, state.currentId},
    );
    next();
  }

  bool submit() {
    if (!state.canSubmit) return false;
    state = state.copyWith(page: SurveyPage.submitted);
    return true;
  }

  /// Withdrawal and reset erase the whole synthetic session immediately.
  void reset() => state = QuestionnaireState(
    language: state.language,
    config: state.config,
  );
}
