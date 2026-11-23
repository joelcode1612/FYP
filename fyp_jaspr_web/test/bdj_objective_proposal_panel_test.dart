import 'package:jaspr_test/jaspr_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/bdj_objective_proposal_panel.dart';

import 'fixtures/bdj_objective_fixtures.dart';

/// Transport double for the four M2 reads the panel performs before it is
/// allowed to show a proposal. It serves the same payloads the verified
/// Gate B/C run recorded, so the panel exercises its real resolution order:
/// link → draft → current confirmation → business-context status.
class _FakeM2Client extends ApiClient {
  final paths = <String>[];

  /// When set, `confirmation-current` answers with this revision, which lets a
  /// test make the confirmation disagree with the draft.
  int? confirmationRevisionOverride;

  Map<String, dynamic>? statusOverride;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    paths.add(path);
    if (path == '/api/v1/m2/assessments/by-marketplace/$marketplaceAssessmentId') {
      return linkPayload();
    }
    if (path == '/api/v1/m2/assessments/$m2AssessmentId') {
      return m2DraftPayload();
    }
    if (path == '/api/v1/m2/assessments/$m2AssessmentId/confirmation-current') {
      return confirmationPayload(
        revision: confirmationRevisionOverride ?? confirmationRevision,
      );
    }
    if (path ==
        '/api/v1/m2/assessments/$m2AssessmentId/confirmations/'
            '$confirmationId/business-context-status') {
      return statusOverride ?? contextStatusPayload();
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('The panel must not write to the M2 transport.');
}

/// Serves fixed [ApiResult] values so each render state can be reached without
/// a browser session or a live backend.
class _FakeProposalPort implements BdjObjectiveProposalPort {
  ApiResult<BdjObjectiveProposalList>? listResult;
  ApiResult<BdjObjectiveDecision>? readDecisionResult;
  ApiResult<BdjObjectiveDecision>? decideResult;

  final listCalls = <String>[];
  final decideCalls = <String>[];

  @override
  Future<ApiResult<BdjObjectiveProposalList>> list({
    required String assessmentId,
    required int expectedRevision,
    required String contextId,
  }) async {
    listCalls.add('$assessmentId|$expectedRevision|$contextId');
    return listResult!;
  }

  @override
  Future<ApiResult<BdjObjectiveDecision>> readDecision({
    required String assessmentId,
    required String proposalId,
    required int expectedRevision,
    required String contextId,
  }) async => readDecisionResult!;

  @override
  Future<ApiResult<BdjObjectiveDecision>> decide({
    required String assessmentId,
    required String proposalId,
    required int expectedRevision,
    required String contextId,
    required String decision,
  }) async {
    decideCalls.add('$proposalId|$decision');
    return decideResult!;
  }

  @override
  Future<ApiResult<BdjObjectiveEvaluation>> evaluate({
    required String assessmentId,
    required int expectedRevision,
    required String contextId,
  }) async => ApiResult.success(
    BdjObjectiveEvaluation.fromJson(evaluationPayload()),
  );

  @override
  Future<ApiResult<BdjProposalReadback>> read({
    required String assessmentId,
    required String proposalId,
    required int expectedRevision,
    required String contextId,
  }) async => throw StateError('The panel reads the list, not one proposal.');
}

/// `GET …/objective-proposals` reads persisted rows and, per the contract,
/// carries no execution block. The fixture keeps one because it mirrors the
/// evaluate envelope, so it is stripped here to keep the double faithful.
ApiResult<BdjObjectiveProposalList> _listed(Map<String, dynamic> payload) =>
    ApiResult.success(
      BdjObjectiveProposalList.fromJson(
        Map<String, dynamic>.from(payload)..remove('execution'),
      ),
    );

void main() {
  late ApiM2Repository originalM2;
  late _FakeM2Client client;
  late _FakeProposalPort port;

  setUp(() {
    originalM2 = AppLocator.m2;
    client = _FakeM2Client();
    port = _FakeProposalPort();
    AppLocator.m2 = ApiM2Repository(client);
    port.listResult = _listed(evaluationPayload());
    port.readDecisionResult = ApiResult.success(
      BdjObjectiveDecision.fromJson(heldDecisionPayload()),
    );
  });

  tearDown(() => AppLocator.m2 = originalM2);

  BdjObjectiveProposalPanel panel() => BdjObjectiveProposalPanel(
    marketplaceAssessmentId: marketplaceAssessmentId,
    api: port,
  );

  testComponents('the reading state is shown before the governed read settles', (
    tester,
  ) async {
    tester.pumpComponent(panel());
    expect(find.text('Reading persisted research objectives…'), findsOneComponent);
    // No proposal may be on screen while the source is still being resolved.
    expect(find.text('Most suggested'), findsNothing);
  });

  testComponents('persisted proposals render their category and source', (
    tester,
  ) async {
    tester.pumpComponent(panel());
    await tester.pump();
    await tester.pump();

    expect(find.text('Research objectives'), findsOneComponent);
    // Two source-confirmed gaps and one exploratory suggestion.
    expect(find.text('Most suggested'), findsNComponents(2));
    expect(find.text('Suggested'), findsOneComponent);
    // Review state is a second, separate badge.
    expect(find.text('Approved by you'), findsOneComponent);
    expect(find.text('Awaiting your decision'), findsNComponents(2));

    // The server's own objective text, never a placeholder.
    expect(
      find.text(
        'To investigate candidate areas for the proposed cafe and the '
        'characteristics of each that matter to the concept.',
      ),
      findsOneComponent,
    );
    // Source references are shown as chips keyed by item and answer revision.
    expect(find.text('M2V1-01 · 0f1c2d3e'), findsOneComponent);
    expect(find.text('M2V1-08 · 262fe6ea'), findsOneComponent);
    // The exploratory proposal has no source, and says so.
    expect(
      find.text(
        'No source reference: this is an exploratory objective, not a '
        'source-confirmed gap.',
      ),
      findsOneComponent,
    );
    // A persisted read carries no execution block, so the panel must not
    // invent a provenance line for it.
    expect(
      find.textContaining('Simulated pass — no cloud model was called'),
      findsNothing,
    );
    // The governed read used the confirmation's revision and context.
    expect(port.listCalls.single, '$m2AssessmentId|$confirmationRevision|$contextId');
  });

  testComponents('approval is shown as a decision, admission as still held', (
    tester,
  ) async {
    tester.pumpComponent(panel());
    await tester.pump();
    await tester.pump();

    expect(find.text('Admission held'), findsOneComponent);
    expect(
      find.text(
        'Question generation: not authorised · Fielding: not authorised',
      ),
      findsOneComponent,
    );
    expect(
      find.text(
        'A source-linked BDJ finding review is not adopted; the objective '
        'cannot be linked to a confirmed uncertainty yet.',
      ),
      findsOneComponent,
    );
    // The decision is the entrepreneur's own record, so it stays visible next
    // to the hold rather than being overwritten by it.
    expect(find.text('Approved by you'), findsOneComponent);
  });

  testComponents('an empty result is rendered as empty, not as a proposal', (
    tester,
  ) async {
    port.listResult = _listed(
      evaluationPayload()
        ..['proposals'] = <Map<String, dynamic>>[]
        ..['proposal_count'] = 0,
    );
    tester.pumpComponent(panel());
    await tester.pump();
    await tester.pump();

    expect(find.text('No research objectives yet'), findsOneComponent);
    expect(find.text('Most suggested'), findsNothing);
    expect(find.text('Suggested'), findsNothing);
    expect(find.text('Approve'), findsNothing);
  });

  testComponents('a moved confirmation is stale, not empty and not an error', (
    tester,
  ) async {
    client.confirmationRevisionOverride = confirmationRevision + 1;
    tester.pumpComponent(panel());
    await tester.pump();
    await tester.pump();

    expect(find.text('The confirmed source is not current'), findsOneComponent);
    expect(
      find.textContaining(
        'The M2 confirmation is missing or no longer matches revision '
        '$confirmationRevision.',
      ),
      findsOneComponent,
    );
    // Nothing is proposed from a source that no longer agrees.
    expect(port.listCalls, isEmpty);
    expect(find.text('Most suggested'), findsNothing);
  });

  testComponents('a stale business context withholds the proposals', (
    tester,
  ) async {
    client.statusOverride = contextStatusPayload(
      status: 'HELD',
      sourceIsCurrent: false,
    );
    tester.pumpComponent(panel());
    await tester.pump();
    await tester.pump();

    expect(find.text('The confirmed source is not current'), findsOneComponent);
    expect(find.textContaining('(status HELD)'), findsOneComponent);
    expect(port.listCalls, isEmpty);
  });

  testComponents('a stale refusal from the service is classified as stale', (
    tester,
  ) async {
    port.listResult = ApiResult.error(
      const AssessmentFailure(
        status: 409,
        code: BdjObjectiveCodes.sourceNotCurrent,
        message: 'The confirmed source moved.',
      ),
    );
    tester.pumpComponent(panel());
    await tester.pump();
    await tester.pump();

    expect(find.text('The confirmed source is not current'), findsOneComponent);
    expect(
      find.textContaining(BdjObjectiveCodes.sourceNotCurrent),
      findsOneComponent,
    );
  });

  testComponents('a failed read reports the server sentence and offers retry', (
    tester,
  ) async {
    port.listResult = ApiResult.error(
      const AssessmentFailure(
        status: 503,
        code: 'service_unavailable',
        message: 'The objective service is temporarily unavailable.',
      ),
    );
    tester.pumpComponent(panel());
    await tester.pump();
    await tester.pump();

    expect(find.text('Research objectives could not be read'), findsOneComponent);
    expect(
      find.text('The objective service is temporarily unavailable.'),
      findsOneComponent,
    );
    expect(find.text('Retry'), findsOneComponent);
    // A failure is never rendered as an empty success.
    expect(find.text('No research objectives yet'), findsNothing);
  });

  testComponents('recording a decision never claims downstream authority', (
    tester,
  ) async {
    port.decideResult = ApiResult.success(
      BdjObjectiveDecision.fromJson(
        heldDecisionPayload(proposalId: sourcedProposalId),
      ),
    );
    tester.pumpComponent(panel());
    await tester.pump();
    await tester.pump();

    expect(find.text('Approve'), findsNComponents(2));
    await tester.click(
      find.ancestor(of: find.text('Approve'), matching: find.tag('button')).first,
    );
    await tester.pump();
    await tester.pump();

    expect(port.decideCalls.single, '$sourcedProposalId|APPROVED');
    // The badge now reports the stored decision, and the admission card still
    // states that question generation and fielding are not authorised.
    expect(find.text('Approved by you'), findsNComponents(2));
    expect(find.text('Admission held'), findsNComponents(2));
    expect(
      find.text(
        'Question generation: not authorised · Fielding: not authorised',
      ),
      findsNComponents(2),
    );
    // The decided proposal no longer offers Approve/Reject.
    expect(find.text('Approve'), findsOneComponent);
  });

  testComponents('a simulated pass is labelled, and a re-read drops the label', (
    tester,
  ) async {
    tester.pumpComponent(panel());
    await tester.pump();
    await tester.pump();
    expect(
      find.textContaining('Simulated pass — no cloud model was called'),
      findsNothing,
    );

    await tester.click(
      find.ancestor(of: find.text('Re-run'), matching: find.tag('button')).first,
    );
    await tester.pump();
    await tester.pump();
    // A simulated pass must never read like a live model result.
    expect(
      find.textContaining('Simulated pass — no cloud model was called'),
      findsOneComponent,
    );

    await tester.click(
      find.ancestor(of: find.text('Refresh'), matching: find.tag('button')).first,
    );
    await tester.pump();
    await tester.pump();
    // The list endpoint returns persisted rows only, so the note cannot outlive
    // the re-read and imply a run that this read did not perform.
    expect(
      find.textContaining('Simulated pass — no cloud model was called'),
      findsNothing,
    );
  });
}
