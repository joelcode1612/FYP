import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import '../domain/assessment_draft.dart';
import '../domain/m2_questions.dart';

final assessmentProvider = NotifierProvider<AssessmentViewModel, AssessmentDraft>(
  AssessmentViewModel.new,
);

/// ViewModel owns UI state and input validation, but NEVER asserts scientific validity.
/// No http requests, database writes, authentication or report admission occur here.
class AssessmentViewModel extends Notifier<AssessmentDraft> {
  @override
  AssessmentDraft build() => AssessmentDraft();

  void changePage(int page) {
    if (page < 0 || page > 4) return;
    state = state.copyWith(page: page);
  }

  void setSingle(String id, String answer) {
    final q = m2Questions.where((q) => q.id == id).firstOrNull;
    if (q == null || q.kind != M2Kind.single || !q.options.contains(answer)) return;
    state = state.copyWith(
      singleAnswers: {...state.singleAnswers, id: answer},
      reviewed: false,
      confirmedInDemo: false,
      answerRevision: state.answerRevision + 1,
    );
  }

  void toggleMulti(String id, String value) {
    final q = m2Questions.where((q) => q.id == id).firstOrNull;
    if (q == null || q.kind != M2Kind.multi || !q.options.contains(value)) return;
    final current = state.multi(id).toList();
    if (current.contains(value)) {
      current.remove(value);
    } else if (value == q.exclusiveChoice) {
      current..clear()..add(value);
    } else {
      current.remove(q.exclusiveChoice);
      if (q.maximum != null && current.length >= q.maximum!) return;
      current.add(value);
    }
    final primary = id == 'M2-07' && !current.contains(state.primaryCustomer)
        ? '' : state.primaryCustomer;
    state = state.copyWith(
      multiAnswers: {...state.multiAnswers, id: current},
      primaryCustomer: primary,
      reviewed: false,
      confirmedInDemo: false,
      answerRevision: state.answerRevision + 1,
    );
  }

  void setPrimaryCustomer(String choice) {
    if (!state.multi('M2-07').contains(choice)) return;
    state = state.copyWith(
      primaryCustomer: choice,
      reviewed: false,
      confirmedInDemo: false,
      answerRevision: state.answerRevision + 1,
    );
  }

  void setDescription(String text) {
    state = state.copyWith(
      description: text,
      reviewed: false,
      confirmedInDemo: false,
      answerRevision: state.answerRevision + 1,
    );
  }

  void setOtherDetail(String id, String text) {
    state = state.copyWith(
      otherDetails: {...state.otherDetails, id: text},
      reviewed: false,
      confirmedInDemo: false,
      answerRevision: state.answerRevision + 1,
    );
  }

  void setEntrepreneurConcern(String text) {
    state = state.copyWith(
      entrepreneurConcern: text,
      reviewed: false,
      confirmedInDemo: false,
      answerRevision: state.answerRevision + 1,
    );
  }

  void reviewDemo() {
    state = state.copyWith(reviewed: true, confirmedInDemo: false);
  }

  void confirmDemo() {
    if (!state.reviewed) return;
    // Demo-only acknowledgement, NOT M2-21 authorization or report admission.
    state = state.copyWith(confirmedInDemo: true);
  }

  void reset() => state = AssessmentDraft();
}
