/// Questionnaire contract for the M2 location assessment.
///
/// The application layer drives the assessment through this contract. It knows
/// nothing about where the questions come from: the default provider supplies
/// the illustrative prototype definition, and either app can override the
/// provider at its composition root with a different questionnaire source.
library;

import '../entities/m2_assessment.dart';

abstract class M2QuestionnaireRepository {
  /// Answer fields (actions are excluded).
  List<M2Item> get answerItems;

  /// Governance/review actions shown separately from answer fields.
  List<M2Item> get actions;

  /// Identifier of the question set in use (e.g. `PROTO-V4-2026-10-28`).
  String get version;
}
