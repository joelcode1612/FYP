/// The **confirmed worksheet** state, not execution state.
///
/// This file used to be called `ai_execution_status.dart`, which was wrong in a
/// way that mattered: it invites a reader to treat a worksheet as an execution
/// receipt. It never carried execution information — the execution rail reads
/// `AiExecutionPurpose` from the status API instead. The class keeps its old
/// name only to avoid a needless rename ripple; the file name now tells the
/// truth about what is inside.
///
/// Read-only presentation of the confirmed-review response. It is not an
/// execution receipt and must never infer cloud execution from a worksheet.
enum ConfirmedWorksheetStatus { notEvaluated, historicalCandidate, unavailable }

final class AiExecutionStatus {
  final ConfirmedWorksheetStatus worksheet;
  final int? m2Revision;
  final String? ruleset;
  final int? historicalFindingCount;

  const AiExecutionStatus._(
    this.worksheet,
    this.m2Revision,
    this.ruleset,
    this.historicalFindingCount,
  );

  factory AiExecutionStatus.fromConfirmedReview({
    required String evaluationState,
    required int revision,
    required String ruleVersion,
    required int findingCount,
  }) {
    switch (evaluationState) {
      case 'NOT_EVALUATED':
        return AiExecutionStatus._(
          ConfirmedWorksheetStatus.notEvaluated,
          revision,
          null,
          null,
        );
      case 'EVALUATED_CANDIDATE':
        return AiExecutionStatus._(
          ConfirmedWorksheetStatus.historicalCandidate,
          revision,
          ruleVersion,
          findingCount,
        );
      default:
        return AiExecutionStatus._(
          ConfirmedWorksheetStatus.unavailable,
          revision,
          null,
          null,
        );
    }
  }

  static const unavailable = AiExecutionStatus._(
    ConfirmedWorksheetStatus.unavailable,
    null,
    null,
    null,
  );
}
