import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/confirmed_worksheet_status.dart';

void main() {
  test('an unevaluated worksheet does not become a zero-findings result', () {
    final status = AiExecutionStatus.fromConfirmedReview(
      evaluationState: 'NOT_EVALUATED', revision: 4,
      ruleVersion: 'NOT_EVALUATED', findingCount: 0,
    );
    expect(status.worksheet, ConfirmedWorksheetStatus.notEvaluated);
    expect(status.historicalFindingCount, isNull);
    expect(status.m2Revision, 4);
  });

  test('historical zero findings remains a candidate worksheet', () {
    final status = AiExecutionStatus.fromConfirmedReview(
      evaluationState: 'EVALUATED_CANDIDATE', revision: 14,
      ruleVersion: 'TEST-CANDIDATE', findingCount: 0,
    );
    expect(status.worksheet, ConfirmedWorksheetStatus.historicalCandidate);
    expect(status.historicalFindingCount, 0);
  });

  test('unknown states do not become running or completed executions', () {
    final status = AiExecutionStatus.fromConfirmedReview(
      evaluationState: 'NEW_SERVER_STATE', revision: 2,
      ruleVersion: '', findingCount: 4,
    );
    expect(status.worksheet, ConfirmedWorksheetStatus.unavailable);
    expect(status.historicalFindingCount, isNull);
  });
}
