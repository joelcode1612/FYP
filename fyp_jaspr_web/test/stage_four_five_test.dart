import 'package:jaspr/jaspr.dart';
import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage_four_five_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/stage_four_question_review.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/stage_five_questionnaire_preview.dart';

const _assessmentId = '4fc0abc2-0000-4000-8000-000000000001';
const _contextId = 'ctx-0000-0000-0000-000000000001';
const _revision = 23;

/// Serves fixed results so every render state is reachable without a browser
/// session, a backend or a database.
class _FakeStagePort implements StageFourFivePort {
  _FakeStagePort();

  ProposalAdmission admissionValue = const ProposalAdmission(
    state: 'HELD',
    reason: 'M2_UNCERTAINTY_LINK_REQUIRED',
  );
  QuestionHistory? historyValue;
  QuestionReviewDetail? detailValue;
  QuestionnairePreview? previewValue;

  ApiResult<QuestionReviewReceipt>? reviewResult;
  ApiResult<String?>? desiredResult;
  /// Contract 2.1 authority. Defaults to a refusal so the existing fixtures
  /// keep exercising the admission path; a test that wants the approval to be
  /// the authority sets this explicitly.
  ApiResult<ObjectiveAuthority>? authorityResult;

  final admissionCalls = <String>[];
  final authorityCalls = <String>[];
  final historyCalls = <String>[];
  final detailCalls = <String>[];
  final reviewCalls = <String>[];
  final desiredCalls = <String>[];

  @override
  Future<ApiResult<ProposalAdmission>> admission({
    required String assessmentId,
    required String proposalId,
    required int expectedRevision,
    required String contextId,
  }) async {
    admissionCalls.add('$proposalId|$expectedRevision|$contextId');
    return ApiResult.success(admissionValue);
  }

  /// The ledger reading. Defaults to a refusal, so a fixture that does not care
  /// about execution status renders the "unavailable" wording rather than a
  /// state nobody recorded.
  ApiResult<AiExecutionReading>? executionResult;

  /// The QG permission. Defaults to `ABSENT`, which is the true state before the
  /// owner has been asked.
  ApiResult<QgConsent>? consentResult;

  final executionCalls = <String>[];
  final consentCalls = <String>[];
  final grantCalls = <String>[];

  @override
  Future<ApiResult<AiExecutionReading>> executionStatus({
    required String assessmentId,
  }) async {
    executionCalls.add(assessmentId);
    return executionResult ??
        ApiResult.error(
          const AssessmentFailure(
            code: 'ledger_unavailable',
            message: 'No execution reading in this fixture.',
          ),
        );
  }

  @override
  Future<ApiResult<QgConsent>> qgConsent({
    required String assessmentId,
    required String proposalId,
  }) async {
    consentCalls.add(proposalId);
    return consentResult ??
        ApiResult.success(
          const QgConsent(
            state: 'ABSENT',
            disclosure: <String, dynamic>{
              'contract_version': 'ai-processing-consent-qg/1',
              'provider': 'tokenharbor',
              'purpose': 'Generate candidate customer questions.',
              'data_shared': <String>['confirmed_facts', 'objective'],
              'max_attempts': 1,
              'endpoint': 'https://example.invalid/v1/chat/completions',
              'model': 'fixture-model',
            },
          ),
        );
  }

  @override
  Future<ApiResult<QgConsent>> grantQgConsent({
    required String assessmentId,
    required String proposalId,
    required Map<String, dynamic> echo,
    String? contextId,
  }) async {
    grantCalls.add('$proposalId|${echo['disclosure_version']}');
    return ApiResult.success(
      QgConsent(
        state: 'GRANTED',
        disclosure: const <String, dynamic>{},
        consentId: 'consent-fixture',
        maxAttempts: 1,
      ),
    );
  }

  @override
  Future<ApiResult<ObjectiveAuthority>> objectiveAuthority({
    required String assessmentId,
    required String proposalId,
    required String contextId,
  }) async {
    authorityCalls.add('$proposalId|$contextId');
    return authorityResult ??
        ApiResult.error(
          const AssessmentFailure(
            code: 'QG_OBJECTIVE_NOT_APPROVED',
            message: 'No derived authority in this fixture.',
          ),
        );
  }

  @override
  Future<ApiResult<QuestionHistory>> history({
    required String objectiveId,
    required int expectedRevision,
  }) async {
    historyCalls.add('$objectiveId|$expectedRevision');
    final value = historyValue;
    if (value == null) {
      return ApiResult.error(
        const AssessmentFailure(code: 'not_found', message: 'No history.'),
      );
    }
    return ApiResult.success(value);
  }

  @override
  Future<ApiResult<QuestionReviewDetail>> reviewQuestion({
    required String version,
    required int expectedRevision,
  }) async {
    detailCalls.add('$version|$expectedRevision');
    final value = detailValue;
    if (value == null) {
      return ApiResult.error(
        const AssessmentFailure(code: 'not_found', message: 'No detail.'),
      );
    }
    return ApiResult.success(value);
  }

  @override
  Future<ApiResult<QuestionReviewReceipt>> recordReview({
    required String version,
    required String decision,
    required String rationale,
  }) async {
    reviewCalls.add('$version|$decision|$rationale');
    return reviewResult ??
        ApiResult.success(
          QuestionReviewReceipt(
            decision: decision,
            rationale: rationale.isEmpty
                ? 'No rationale provided by reviewer.'
                : rationale,
            fieldingAuthorized: false,
            scientificAcceptance: false,
          ),
        );
  }

  @override
  Future<ApiResult<String?>> selectDesiredOption({
    required String version,
    required int expectedRevision,
    String? optionCode,
  }) async {
    desiredCalls.add('$version|$expectedRevision|$optionCode');
    return desiredResult ?? ApiResult.success(optionCode);
  }

  @override
  Future<ApiResult<QuestionnairePreview>> preview({
    required String assessmentId,
  }) async {
    final value = previewValue;
    if (value == null) {
      return ApiResult.error(
        const AssessmentFailure(code: 'not_found', message: 'No preview.'),
      );
    }
    return ApiResult.success(value);
  }

  // -- Direct-QG candidate readback -----------------------------------------

  List<QgCandidate> candidateValue = const [];
  QgEligibility? eligibilityValue;
  ApiResult<CandidateReviewReceipt>? candidateReviewResult;
  ApiResult<String?>? expectedAnswerResult;

  /// Returned by every `candidates()` call after the first, so the post-write
  /// read-back is exercised rather than assumed.
  List<QgCandidate>? candidateAfterWrite;

  final candidateCalls = <String>[];
  final eligibilityCalls = <String>[];
  final candidateReviewCalls = <String>[];
  final expectedAnswerCalls = <String>[];

  @override
  Future<ApiResult<List<QgCandidate>>> candidates({
    required String assessmentId,
  }) async {
    candidateCalls.add(assessmentId);
    final after = candidateAfterWrite;
    if (after != null && candidateCalls.length > 1) {
      candidateValue = after;
    }
    return ApiResult.success(candidateValue);
  }

  @override
  Future<ApiResult<QgEligibility>> eligibility({
    required String assessmentId,
    required String objectiveId,
  }) async {
    eligibilityCalls.add('$assessmentId|$objectiveId');
    final value = eligibilityValue;
    if (value == null) {
      return ApiResult.error(
        const AssessmentFailure(code: 'not_found', message: 'No eligibility.'),
      );
    }
    return ApiResult.success(value);
  }

  @override
  Future<ApiResult<CandidateReviewReceipt>> reviewCandidate({
    required String assessmentId,
    required String candidateId,
    required String decision,
    required String rationale,
    int? expectedRevision,
  }) async {
    candidateReviewCalls.add(
      '$candidateId|$decision|$rationale|$expectedRevision',
    );
    return candidateReviewResult ??
        ApiResult.success(
          CandidateReviewReceipt(
            candidateId: candidateId,
            decision: decision,
            rationale: rationale,
            fieldingAuthorized: false,
            scientificallyAccepted: false,
          ),
        );
  }

  @override
  Future<ApiResult<String?>> setExpectedAnswer({
    required String assessmentId,
    required String candidateId,
    String? optionCode,
    int? expectedRevision,
  }) async {
    expectedAnswerCalls.add('$candidateId|$optionCode|$expectedRevision');
    return expectedAnswerResult ?? ApiResult.success(optionCode);
  }
}

class _FakeProposalPort implements BdjObjectiveProposalPort {
  _FakeProposalPort(this.proposals);

  final List<BdjObjectiveProposal> proposals;
  final listCalls = <String>[];

  @override
  Future<ApiResult<BdjObjectiveProposalList>> list({
    required String assessmentId,
    required int expectedRevision,
    required String contextId,
  }) async {
    listCalls.add('$assessmentId|$expectedRevision|$contextId');
    return ApiResult.success(
      BdjObjectiveProposalList(
        assessmentId: assessmentId,
        contextId: contextId,
        proposalCount: proposals.length,
        proposals: proposals,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Stage 4 must not write through the proposal port.');
}

BdjObjectiveProposal _proposal({
  required String id,
  required String objective,
  required BdjReviewState state,
  List<BdjSourceRef> refs = const [],
}) => BdjObjectiveProposal(
  proposalId: id,
  recommendation: BdjRecommendation(
    status: BdjRecommendationStatus.mostSuggested,
    problemType: 'TRADING_LOCATION_UNCERTAINTY',
    problem: 'The trading area is not established.',
    researchObjective: objective,
    reason: 'The confirmed answers leave the area undecided.',
    sourceRefs: refs,
  ),
  reviewState: state,
);

/// A persisted candidate shaped exactly as `sitewise-qg-candidate/1` returns it.
///
/// Defaults describe the one candidate the database actually holds: simulated,
/// no ledger run. A test that wants live provenance must say so explicitly, so
/// the simulated case can never be produced by omission.
QgCandidate _candidate({
  String candidateId = 'cand-1',
  String objectiveId = 'O1',
  String question = 'How interested would you be in this concept?',
  String executionMode = 'SIMULATED',
  String modelProvider = 'simulated-qg-v1',
  String? runId,
  String? proposalId,
  String responseFormat = 'SINGLE_SELECT',
  String? referencePeriod,
  String? measurementId = 'P1-MEAS-O1-CONCEPT-INTEREST',
  String candidateState = 'VALIDATED',
  CandidateReview review = const CandidateReview(),
  List<CandidateOption> options = const [
    CandidateOption(
      code: 'INTERESTED',
      label: 'Interested',
      order: 0,
      orderSource: 'MEASUREMENT',
    ),
    CandidateOption(
      code: 'NOT_INTERESTED',
      label: 'Not interested',
      order: 1,
      orderSource: 'MEASUREMENT',
    ),
  ],
}) => QgCandidate(
  candidateId: candidateId,
  assessmentId: _assessmentId,
  objectiveId: objectiveId,
  objectiveClassification: 'FIXED_O1_O6',
  question: question,
  responseFormat: responseFormat,
  options: options,
  routing: const {},
  review: review,
  candidateState: candidateState,
  executionMode: executionMode,
  modelProvider: modelProvider,
  dispatched: runId != null,
  fieldingAuthorized: false,
  scientificallyAccepted: false,
  objectiveAdmissionId: 'ea8d9d6b-0000-4000-8000-000000000001',
  proposalId: proposalId,
  measurementId: measurementId,
  measurementVersion: '0.1-CAND',
  runId: runId,
  contractVersion: 'sitewise-qg-candidate/1',
  adapterVersion: 'qg-candidate-adapter/1',
  promptVersion: 'qg-prompt/1',
  referencePeriod: referencePeriod,
  structuralStatus: 'PASS',
  semanticStatus: 'PASS',
  provenanceStatus: 'PASS',
  createdAt: '2026-11-22T00:00:00Z',
);

void main() {
  group('Stage 4 — question review', () {
    late _FakeStagePort port;

    setUp(() => port = _FakeStagePort());

    Component stageFour(_FakeProposalPort proposals) => StageFourQuestionReview(
      m2AssessmentId: _assessmentId,
      expectedRevision: _revision,
      contextId: _contextId,
      api: port,
      proposalApi: proposals,
    );

    testComponents('a proposal without a decision shows the gate, not a question', (
      tester,
    ) async {
      final proposals = _FakeProposalPort([
        _proposal(
          id: 'p1',
          objective: 'To investigate the trading area for the concept.',
          state: BdjReviewState.pending,
        ),
      ]);
      tester.pumpComponent(stageFour(proposals));
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('Not approved yet. Approve the objective on Stage 3'),
        findsOneComponent,
      );
      // No question wording may appear for a proposal that was never approved.
      expect(
        find.textContaining('Which of the following best describes'),
        findsNothing,
      );
      // The admission lookup must not run for an undecided proposal: reading it
      // would imply the proposal is a candidate for admission.
      expect(port.historyCalls, isEmpty);
    });

    testComponents('an admitted objective lists its persisted versions', (
      tester,
    ) async {
      port.admissionValue = const ProposalAdmission(
        state: 'ADMITTED',
        reason: 'FIXED_OBJECTIVE_BOUND',
        objectiveId: 'O1',
        qgEligible: true,
      );
      port.historyValue = const QuestionHistory(
        objectiveId: 'O1',
        objective: 'Concept interest',
        versions: [
          ResearchQuestionCandidate(
            version: 'v1',
            question: 'How interested would you be in this concept?',
            options: [
              QuestionOption(code: 'A', label: 'Very interested'),
              QuestionOption(code: 'B', label: 'Not interested'),
            ],
            status: 'PENDING',
          ),
        ],
      );
      port.detailValue = const QuestionReviewDetail(
        version: 'v1',
        objectiveId: 'O1',
        question: 'How interested would you be in this concept?',
        options: [
          QuestionOption(code: 'A', label: 'Very interested', eligible: true),
          QuestionOption(code: 'B', label: 'Not interested', eligible: false),
        ],
      );
      final proposals = _FakeProposalPort([
        _proposal(
          id: 'p1',
          objective: 'To investigate concept interest.',
          state: BdjReviewState.approved,
          refs: const [
            BdjSourceRef(
              itemKey: 'M2V2-01',
              answerRevisionId: 'aaaaaaaa-1111',
              itemVersionId: 'iv-1',
            ),
          ],
        ),
      ]);
      tester.pumpComponent(stageFour(proposals));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Exact persisted wording, never a paraphrase.
      expect(
        find.text('How interested would you be in this concept?'),
        findsOneComponent,
      );
      expect(find.text('Very interested'), findsOneComponent);
      // The server's eligibility constraint is surfaced verbatim.
      expect(
        find.text('not selectable'),
        findsOneComponent,
      );
      expect(
        find.textContaining('selectable: A; not selectable: B'),
        findsOneComponent,
      );
      // Provenance is shown from the proposal's own source references.
      expect(find.textContaining('M2V2-01 · aaaaaaaa'), findsOneComponent);
      // The detail read used the leaf version and the current revision.
      expect(port.detailCalls.single, 'v1|$_revision');
    });

    testComponents('a review decision posts the exact server vocabulary', (
      tester,
    ) async {
      port.admissionValue = const ProposalAdmission(
        state: 'ADMITTED',
        reason: 'FIXED_OBJECTIVE_BOUND',
        objectiveId: 'O1',
        qgEligible: true,
      );
      port.historyValue = const QuestionHistory(
        objectiveId: 'O1',
        objective: 'Concept interest',
        versions: [
          ResearchQuestionCandidate(
            version: 'v1',
            question: 'How interested would you be?',
            options: [
              QuestionOption(code: 'A', label: 'Interested'),
              QuestionOption(code: 'B', label: 'Not interested'),
            ],
            status: 'PENDING',
          ),
        ],
      );
      port.detailValue = const QuestionReviewDetail(
        version: 'v1',
        objectiveId: 'O1',
        question: 'How interested would you be?',
        options: [
          QuestionOption(code: 'A', label: 'Interested', eligible: true),
          QuestionOption(code: 'B', label: 'Not interested', eligible: true),
        ],
      );
      final proposals = _FakeProposalPort([
        _proposal(
          id: 'p1',
          objective: 'To investigate concept interest.',
          state: BdjReviewState.approved,
        ),
      ]);
      tester.pumpComponent(stageFour(proposals));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      await tester.click(find.ancestor(
        of: find.text('Approve for review'),
        matching: find.tag('button'),
      ));
      await tester.pump();

      expect(port.reviewCalls.single, startsWith('v1|APPROVE_FOR_REVIEW|'));
      expect(
        find.textContaining('Recorded decision: APPROVE_FOR_REVIEW'),
        findsOneComponent,
      );
      // The receipt must be asserted, not trusted silently.
      expect(
        find.textContaining('fielding authorisation is still false'),
        findsOneComponent,
      );
    });

    testComponents('the expected answer is written separately from a decision', (
      tester,
    ) async {
      port.admissionValue = const ProposalAdmission(
        state: 'ADMITTED',
        reason: 'FIXED_OBJECTIVE_BOUND',
        objectiveId: 'O1',
        qgEligible: true,
      );
      port.historyValue = const QuestionHistory(
        objectiveId: 'O1',
        objective: 'Concept interest',
        versions: [
          ResearchQuestionCandidate(
            version: 'v1',
            question: 'How interested would you be?',
            options: [
              QuestionOption(code: 'A', label: 'Interested'),
              QuestionOption(code: 'B', label: 'Not interested'),
            ],
            status: 'PENDING',
          ),
        ],
      );
      port.detailValue = const QuestionReviewDetail(
        version: 'v1',
        objectiveId: 'O1',
        question: 'How interested would you be?',
        options: [
          QuestionOption(code: 'A', label: 'Interested', eligible: true),
          QuestionOption(code: 'B', label: 'Not interested', eligible: true),
        ],
      );
      final proposals = _FakeProposalPort([
        _proposal(
          id: 'p1',
          objective: 'To investigate concept interest.',
          state: BdjReviewState.approved,
        ),
      ]);
      tester.pumpComponent(stageFour(proposals));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // The legacy per-objective version chain keeps its explicit button; only
      // the Direct-QG card folds the expectation into the option row.
      await tester.click(find.ancestor(
        of: find.text('Expect A'),
        matching: find.tag('button'),
      ));
      await tester.pump();

      expect(port.desiredCalls.single, 'v1|$_revision|A');
      // Choosing an expectation is not a review decision.
      expect(port.reviewCalls, isEmpty);
      expect(
        find.textContaining('never counted in a CQ or EE-01 calculation'),
        findsOneComponent,
      );
    });

    testComponents('a held admission names the exact refusal code', (tester) async {
      port.admissionValue = const ProposalAdmission(
        state: 'HELD',
        reason: 'M2_UNCERTAINTY_LINK_REQUIRED',
      );
      final proposals = _FakeProposalPort([
        _proposal(
          id: 'p1',
          objective: 'To investigate the trading area.',
          state: BdjReviewState.approved,
        ),
      ]);
      tester.pumpComponent(stageFour(proposals));
      await tester.pump();
      await tester.pump();

      // The state is named in the same words Stage 3 uses, and the server's own
      // refusal code is preserved rather than paraphrased away.
      expect(
        find.textContaining('held by the server (M2_UNCERTAINTY_LINK_REQUIRED)'),
        findsOneComponent,
      );
      expect(find.textContaining('Held'), findsOneComponent);
      // The wire token is never printed as if it were a state the reader could
      // act on, and the raw state is never the whole message.
      expect(find.text('HELD'), findsNothing);
      // A held admission is not attributed to an owner action that cannot
      // change it: the previous sentence told the owner to record that the gap
      // was worth researching even when the server had refused for policy.
      expect(
        find.textContaining('not recorded that this gap is worth researching'),
        findsNothing,
      );
      expect(port.historyCalls, isEmpty);
    });

    testComponents(
      'a policy refusal is shown as the server worded it, not as a missing '
      'owner step',
      (tester) async {
        // Exactly the shape `objective_admission._state` returns for a
        // BUSINESS_DECISION_REQUIRED disposition: NOT_ADMISSIBLE, a coded
        // reason, and a pending_requirement that says outright that this is a
        // policy result rather than an unfinished owner action.
        port.admissionValue = const ProposalAdmission(
          state: 'NOT_ADMISSIBLE',
          reason: 'ADMISSION_NOT_RESEARCH_SUITABLE_BUSINESS_DECISION_REQUIRED',
          pendingRequirement:
              'The candidate policy classifies this gap as '
              'BUSINESS_DECISION_REQUIRED; a customer survey is not the '
              'instrument that can answer it, so no objective admission is '
              'available. This is a policy result, not a missing owner action.',
          policyDisposition: 'BUSINESS_DECISION_REQUIRED',
        );
        final proposals = _FakeProposalPort([
          _proposal(
            id: 'p1',
            objective: 'To investigate the trading area.',
            state: BdjReviewState.approved,
          ),
        ]);
        tester.pumpComponent(stageFour(proposals));
        await tester.pump();
        await tester.pump();

        // The server's sentence is used verbatim.
        expect(
          find.textContaining('This is a policy result, not a missing owner'),
          findsOneComponent,
        );
        // No "UNKNOWN" placeholder and no empty reason bracket: the two
        // symptoms the owner reported.
        expect(find.textContaining('UNKNOWN'), findsNothing);
        expect(find.textContaining('()'), findsNothing);
        // The badge is a sentence fragment, not the wire enum.
        expect(
          find.text('ADMISSION_NOT_RESEARCH_SUITABLE_'
              'BUSINESS_DECISION_REQUIRED'),
          findsNothing,
        );
      },
    );
  });

  group('Stage 4 — Direct-QG candidate readback', () {
    late _FakeStagePort port;

    setUp(() => port = _FakeStagePort());

    Component stageFour() => StageFourQuestionReview(
      m2AssessmentId: _assessmentId,
      expectedRevision: _revision,
      contextId: _contextId,
      api: port,
      proposalApi: _FakeProposalPort(const []),
    );

    testComponents('a persisted candidate renders its exact wording and codes', (
      tester,
    ) async {
      port.candidateValue = [_candidate()];
      tester.pumpComponent(stageFour());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // The wording is the persisted one, never a paraphrase.
      expect(
        find.text('How interested would you be in this concept?'),
        findsOneComponent,
      );
      // Every option is rendered with both its code and its label.
      expect(find.text('INTERESTED'), findsOneComponent);
      expect(find.text('Interested'), findsOneComponent);
      expect(find.text('NOT_INTERESTED'), findsOneComponent);
      expect(find.text('Not interested'), findsOneComponent);
      // Measurement identity and validation status are part of the record.
      expect(find.text('0.1-CAND'), findsOneComponent);
      expect(find.text('VALIDATED'), findsOneComponent);
      // Structural, semantic and provenance validation all pass; the finder has
      // no exact-count matcher, so the count is asserted via the three rows.
      expect(find.text('PASS'), findsComponents);
      expect(find.text('SINGLE_SELECT'), findsOneComponent);
      expect(find.text('FIXED_O1_O6'), findsOneComponent);
    });

    testComponents('a simulated candidate is never presented as live evidence', (
      tester,
    ) async {
      port.candidateValue = [_candidate()];
      tester.pumpComponent(stageFour());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('not live TokenHarbour evidence'),
        findsOneComponent,
      );
      expect(
        find.textContaining('the ledger has no run for it'),
        findsOneComponent,
      );
      // The provenance grid reports the absent run rather than omitting it.
      expect(find.text('not recorded'), findsComponents);
      // A simulated candidate is reported as simulated, not as "dispatched but
      // missing a run": the simulator branch is the stronger statement and it
      // must win, or the reader would look for a run that was never attempted.
      expect(
        find.text('simulated — not live evidence'),
        findsOneComponent,
      );
      expect(find.text('no ledger run'), findsNothing);
    });

    testComponents('a dispatched candidate reports its ledger run', (tester) async {
      port.candidateValue = [
        _candidate(
          executionMode: 'LIVE',
          modelProvider: 'TokenHarbour',
          runId: 'run-abc',
        ),
      ];
      tester.pumpComponent(stageFour());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('ledger run run-abc'), findsOneComponent);
      expect(find.text('dispatched'), findsOneComponent);
      expect(find.textContaining('not live TokenHarbour evidence'), findsNothing);
    });

    testComponents('eligibility blockers are listed in the server order', (
      tester,
    ) async {
      port.candidateValue = [_candidate()];
      port.eligibilityValue = const QgEligibility(
        prepareStatus: 'UNVERIFIED',
        prepareRefusal: 'MEASUREMENT_SYNTHETIC_SCOPE_ONLY',
        dispatchStatus: 'UNVERIFIED',
        dispatchRefusal: 'QG_LIVE_AUTHORIZATION_NOT_BOUND_TO_ASSESSMENT',
        fieldingAuthorized: false,
        scientificallyAccepted: false,
        dispatchesModel: false,
        checks: [
          EligibilityCheck(
            checkId: 'MV-10',
            title: 'Measurement is scientifically approved',
            status: 'UNVERIFIED',
            reasonCode: 'MEASUREMENT_SYNTHETIC_SCOPE_ONLY',
            evidence: {'scope': 'SYNTHETIC'},
          ),
          EligibilityCheck(
            checkId: 'QG-AUTH',
            title: 'Live QG execution authorization',
            status: 'UNVERIFIED',
            reasonCode: 'QG_LIVE_AUTHORIZATION_NOT_BOUND_TO_ASSESSMENT',
          ),
        ],
      );
      tester.pumpComponent(stageFour());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(port.eligibilityCalls.single, '$_assessmentId|O1');
      expect(find.text('MEASUREMENT_SYNTHETIC_SCOPE_ONLY'), findsOneComponent);
      expect(
        find.text('QG_LIVE_AUTHORIZATION_NOT_BOUND_TO_ASSESSMENT'),
        findsOneComponent,
      );
      expect(find.text('UNVERIFIED'), findsComponents);
      // The report must not read as an authorisation.
      expect(
        find.textContaining('would still not authorise a provider call'),
        findsOneComponent,
      );
    });

    testComponents('a candidate decision posts the server vocabulary and re-reads', (
      tester,
    ) async {
      port.candidateValue = [_candidate()];
      port.candidateAfterWrite = [
        _candidate(
          review: const CandidateReview(
            decision: 'APPROVE_FOR_REVIEW',
            rationale: 'Wording matches the objective.',
            recordedAt: '2026-11-22T01:00:00Z',
            reviewed: true,
          ),
        ),
      ];
      tester.pumpComponent(stageFour());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      await tester.click(find.ancestor(
        of: find.text('Approve for review'),
        matching: find.tag('button'),
      ));
      await tester.pump();
      await tester.pump();

      expect(
        port.candidateReviewCalls.single,
        'cand-1|APPROVE_FOR_REVIEW||$_revision',
      );
      // The receipt does not echo the record, so the page must read it back.
      expect(port.candidateCalls.length, 2);
      expect(
        find.textContaining('Decision: APPROVE_FOR_REVIEW'),
        findsOneComponent,
      );
      expect(find.textContaining('reviewed: APPROVE_FOR_REVIEW'), findsOneComponent);
    });

    testComponents('a candidate expectation is written separately from a decision', (
      tester,
    ) async {
      port.candidateValue = [_candidate()];
      tester.pumpComponent(stageFour());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      await tester.click(find.ancestor(
        of: find.text('Interested'),
        matching: find.tag('button'),
      ));
      await tester.pump();
      await tester.pump();

      expect(port.expectedAnswerCalls.single, 'cand-1|INTERESTED|$_revision');
      expect(port.candidateReviewCalls, isEmpty);
    });

    testComponents('eligibility is reported once per objective, not per candidate', (
      tester,
    ) async {
      // A retry leaves two candidate rows on the same objective. The
      // requirements are a property of the objective, so printing them under
      // both rows would read as two separate assessments of the same gate.
      port.candidateValue = [
        _candidate(candidateId: 'cand-1'),
        _candidate(candidateId: 'cand-2'),
        _candidate(candidateId: 'cand-3', objectiveId: 'O2'),
      ];
      port.eligibilityValue = const QgEligibility(
        prepareStatus: 'UNVERIFIED',
        prepareRefusal: 'MEASUREMENT_SYNTHETIC_SCOPE_ONLY',
        dispatchStatus: 'UNVERIFIED',
        dispatchRefusal: 'QG_LIVE_AUTHORIZATION_NOT_BOUND_TO_ASSESSMENT',
        fieldingAuthorized: false,
        scientificallyAccepted: false,
        dispatchesModel: false,
        checks: [
          EligibilityCheck(
            checkId: 'MV-10',
            title: 'Measurement is scientifically approved',
            status: 'UNVERIFIED',
            reasonCode: 'MEASUREMENT_SYNTHETIC_SCOPE_ONLY',
          ),
        ],
      );
      tester.pumpComponent(stageFour());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // O1 has two rows and O2 one, so the report is rendered twice overall —
      // once for O1 and once for O2 — and the suppressed row says where it went
      // rather than dropping the block silently.
      expect(
        find.text('Generation requirements, in the order the server checks them:'),
        findsComponents,
      );
      expect(
        find.textContaining('reported once, under its first question above'),
        findsOneComponent,
      );
    });

    testComponents('a candidate with no options cannot be reviewed as closed', (
      tester,
    ) async {
      port.candidateValue = [_candidate(options: const [])];
      tester.pumpComponent(stageFour());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('records no answer options'),
        findsOneComponent,
      );
    });
  });

  // The card's reading order is the review's reasoning order. These tests exist
  // because the previous card put the objective and the question at the same
  // weight, tagged the owner's expectation with a lowercase fragment on the
  // option row, and left every gap for the reviewer to notice unaided.
  group('Stage 4 — generated question card', () {
    late _FakeStagePort port;

    setUp(() => port = _FakeStagePort());

    Component stageFour({List<BdjObjectiveProposal> proposals = const []}) =>
        StageFourQuestionReview(
          m2AssessmentId: _assessmentId,
          expectedRevision: _revision,
          contextId: _contextId,
          api: port,
          proposalApi: _FakeProposalPort(proposals),
        );

    testComponents('the objective is labelled as not being the question', (
      tester,
    ) async {
      const objective =
          'Establish whether a collection-only coffee offer at RM 9.50 is '
          'acceptable to buyers in the target area.';
      // The shape the database actually holds for a contract-2.1 candidate: no
      // admission row, no `proposal_id`, and the objective identity is the
      // derived `proposal:<id>`.
      port.candidateValue = [
        _candidate(objectiveId: 'proposal:prop-1', proposalId: null),
      ];
      tester.pumpComponent(
        stageFour(
          proposals: [
            _proposal(
              id: 'prop-1',
              objective: objective,
              state: BdjReviewState.approved,
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Both strings are present, and the objective carries its own label.
      expect(find.text('Research objective'), findsOneComponent);
      // Twice: once in the objective panel and once, labelled, on the card.
      // That duplication is the point — the card has to carry the aim it is
      // serving, or a reviewer judges the wording against nothing.
      expect(find.text(objective), findsComponents);
      expect(
        find.textContaining('Not a questionnaire question'),
        findsOneComponent,
      );
      // The generated wording is labelled as the generated wording.
      expect(find.text('Generated question'), findsOneComponent);
      expect(
        find.text('How interested would you be in this concept?'),
        findsOneComponent,
      );
    });

    testComponents('an absent objective wording is stated, not reconstructed', (
      tester,
    ) async {
      port.candidateValue = [_candidate()];
      tester.pumpComponent(stageFour());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('carries the objective identity but not its wording'),
        findsOneComponent,
      );
    });

    testComponents('the intended answer is a named field, not a row tag', (
      tester,
    ) async {
      port.candidateValue = [
        _candidate(
          review: const CandidateReview(expectedOptionCode: 'INTERESTED'),
        ),
      ];
      tester.pumpComponent(stageFour());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('Your intended answer'), findsOneComponent);
      // Named with the code and the label the record holds.
      expect(
        find.text('You expect respondents to choose INTERESTED — Interested.'),
        findsOneComponent,
      );
      // And still denied any evidentiary status, in the same box.
      expect(
        find.textContaining('never counted in a CQ or EE-01 calculation'),
        findsOneComponent,
      );
      expect(find.text('intended answer'), findsOneComponent);
    });

    testComponents('an unrecorded intended answer says so rather than blank', (
      tester,
    ) async {
      port.candidateValue = [_candidate()];
      tester.pumpComponent(stageFour());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('None recorded'), findsOneComponent);
      expect(find.text('Your intended answer'), findsOneComponent);
    });

    testComponents('the gaps in the record are listed before the decision', (
      tester,
    ) async {
      // The default fixture offers no PREFER_NOT_TO_ANSWER, which is visible on
      // the record, so it is stated rather than left to be noticed.
      port.candidateValue = [_candidate()];
      tester.pumpComponent(stageFour());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        find.text('What this record does not establish'),
        findsOneComponent,
      );
      expect(find.textContaining('No opt-out option'), findsOneComponent);
      // A bound measurement is not reported as a gap.
      expect(
        find.textContaining('No measurement bound to this question'),
        findsNothing,
      );
      // The format and the absent period are read out once, under the wording,
      // as what the answer can and cannot support.
      expect(
        find.textContaining('One choice only. No reference period is confirmed'),
        findsOneComponent,
      );
      // Stated once: the reading note carries the period, so the gap list does
      // not repeat it.
      expect(
        find.textContaining('No reference period'),
        findsOneComponent,
      );
    });

    testComponents('a question with an opt-out raises no opt-out gap', (
      tester,
    ) async {
      port.candidateValue = [
        _candidate(
          options: const [
            CandidateOption(
              code: 'INTERESTED',
              label: 'Interested',
              order: 0,
              orderSource: 'MEASUREMENT',
            ),
            CandidateOption(
              code: 'PREFER_NOT_TO_ANSWER',
              label: 'Prefer not to answer',
              order: 1,
              orderSource: 'GOVERNED_CORE',
            ),
          ],
        ),
      ];
      tester.pumpComponent(stageFour());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('No opt-out option'), findsNothing);
      expect(find.text('PREFER_NOT_TO_ANSWER'), findsOneComponent);
    });

    testComponents('the three authorities are stated as one strip', (
      tester,
    ) async {
      port.candidateValue = [_candidate()];
      tester.pumpComponent(stageFour());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('Fielding not authorised'), findsOneComponent);
      expect(find.text('Scientific acceptance not given'), findsOneComponent);
      expect(find.text('Measurement P1-MEAS-O1-CONCEPT-INTEREST'), findsOneComponent);
    });

    testComponents('a "not specified" period is not read as a period', (
      tester,
    ) async {
      // `qg_live_candidate` writes a sentence into `reference_period` when no
      // window is confirmed, so the field is non-null and says nothing. Reading
      // it as a period would let the card imply a frequency it cannot support.
      port.candidateValue = [
        _candidate(
          responseFormat: 'SINGLE_CHOICE',
          referencePeriod:
              'Not specified - no reference period is confirmed for this '
              'objective; the item is framed as occasion-neutral.',
          measurementId: null,
        ),
      ];
      tester.pumpComponent(stageFour());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('One choice only. No reference period is confirmed'),
        findsOneComponent,
      );
      // The unbound measurement is named as a gap, and as an authority chip.
      expect(
        find.textContaining('No measurement bound to this question'),
        findsOneComponent,
      );
      expect(find.text('No measurement bound'), findsOneComponent);
    });
  });

  group('Stage 4 — eligibility contract v2', () {
    // The shape `qg_generation_eligibility.build_report` actually returns
    // (`sitewise-qg-generation-eligibility/2`), copied field for field. The
    // projection used to read `checks` / `prepare_status` / `dispatch_status`,
    // which are v1 names, so every real report rendered as two UNVERIFIED
    // badges with an empty requirement list while the payload held the refusal.
    Map<String, dynamic> v2Payload() => {
      'contract_version': 'sitewise-qg-generation-eligibility/2',
      'assessment_id': _assessmentId,
      'objective_id': 'proposal:5a6b77a1-45ae-56e8-b6d3-e5f254f000c4',
      'objective_kind': 'ADDITIONAL_ASSESSMENT_OBJECTIVE',
      'generation_status': 'FAIL',
      'generation_refusal': 'QG_OBJECTIVE_NOT_RESEARCH_SUITABLE',
      'scientific_status': 'FAIL',
      'scientific_refusal': 'MEASUREMENT_NOT_FOUND',
      'generation_checks': [
        {
          'check_id': 'G-01',
          'title': 'Objective approved by the owner',
          'status': 'PASS',
          'reason_code': '',
          'sources': ['8666de6d-e497-4d4b-8281-fb5069ccd658'],
          'evidence': {'decision': 'APPROVED'},
          'policy_version': '',
        },
        {
          'check_id': 'G-05S',
          'title': 'Objective is not explicitly unsuitable for customer research',
          'status': 'FAIL',
          'reason_code': 'QG_OBJECTIVE_NOT_RESEARCH_SUITABLE',
          'sources': [],
          'evidence': {},
          'policy_version': '',
        },
      ],
      'scientific_checks': [
        {
          'check_id': 'MV-01',
          'title': 'Measurement exists for this objective',
          'status': 'FAIL',
          'reason_code': 'MEASUREMENT_NOT_FOUND',
        },
      ],
      'scientifically_approved': false,
      'dispatches_model': false,
      'publication_authorized': false,
      'fielding_authorized': false,
    };

    test('the v2 axes and checks are read, not defaulted to UNVERIFIED', () {
      final report = QgEligibility.fromJson(v2Payload());
      expect(report.contractVersion, 'sitewise-qg-generation-eligibility/2');
      expect(report.objectiveKind, 'ADDITIONAL_ASSESSMENT_OBJECTIVE');
      // `generation` is what the v1 field called `prepare`.
      expect(report.prepareStatus, 'FAIL');
      expect(report.prepareRefusal, 'QG_OBJECTIVE_NOT_RESEARCH_SUITABLE');
      // `scientific` is what the v1 field called `dispatch`.
      expect(report.dispatchStatus, 'FAIL');
      expect(report.dispatchRefusal, 'MEASUREMENT_NOT_FOUND');
      expect(report.checks.length, 2);
      expect(report.checks.first.checkId, 'G-01');
      expect(report.checks.first.status, 'PASS');
      expect(report.firstBlocker?.checkId, 'G-05S');
      expect(report.scientificChecks.single.reasonCode, 'MEASUREMENT_NOT_FOUND');
      // A report is never an authority, whatever it says.
      expect(report.fieldingAuthorized, isFalse);
      expect(report.scientificallyAccepted, isFalse);
      expect(report.dispatchesModel, isFalse);
    });

    test('the v1 field names still parse, so an older payload cannot regress', () {
      final report = QgEligibility.fromJson({
        'prepare_status': 'PASS',
        'prepare_refusal': '',
        'dispatch_status': 'UNVERIFIED',
        'dispatch_refusal': 'MEASUREMENT_SYNTHETIC_SCOPE_ONLY',
        'checks': [
          {
            'check_id': 'MV-10',
            'title': 'Measurement is scientifically approved',
            'status': 'UNVERIFIED',
            'reason_code': 'MEASUREMENT_SYNTHETIC_SCOPE_ONLY',
          },
        ],
      });
      expect(report.prepareStatus, 'PASS');
      expect(report.dispatchStatus, 'UNVERIFIED');
      expect(report.dispatchRefusal, 'MEASUREMENT_SYNTHETIC_SCOPE_ONLY');
      expect(report.checks.single.checkId, 'MV-10');
    });

    test('a report with no checks claims nothing', () {
      final report = QgEligibility.fromJson({'objective_id': 'O1'});
      expect(report.prepareStatus, 'UNVERIFIED');
      expect(report.dispatchStatus, 'UNVERIFIED');
      expect(report.checks, isEmpty);
      expect(report.scientificChecks, isEmpty);
    });
  });

  group('Stage 5 — questionnaire preview', () {
    testComponents('a blocked preview prints the server reason, not a sample', (
      tester,
    ) async {
      final port = _FakeStagePort()
        ..previewValue = const QuestionnairePreview(
          status: 'UNAVAILABLE',
          reason: 'NO_ADMITTED_OBJECTIVE',
          items: [],
          draftOnly: true,
          fieldingAuthorized: false,
          publicationAuthorized: false,
          confirmationId: 'conf-1',
          assessmentRevision: _revision,
        );
      tester.pumpComponent(
        StageFiveQuestionnairePreview(m2AssessmentId: _assessmentId, api: port),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('UNAVAILABLE'), findsOneComponent);
      expect(
        find.textContaining('No research objective has been admitted'),
        findsOneComponent,
      );
      expect(
        find.textContaining('No sample question is shown in place of a real one'),
        findsOneComponent,
      );
    });

    testComponents('a draft preview renders persisted wording, codes and labels', (
      tester,
    ) async {
      final port = _FakeStagePort()
        ..previewValue = const QuestionnairePreview(
          status: 'DRAFT_AVAILABLE',
          reason: '',
          draftOnly: true,
          fieldingAuthorized: false,
          publicationAuthorized: false,
          confirmationId: 'conf-1',
          assessmentRevision: _revision,
          items: [
            PreviewItem(
              objectiveId: 'O1',
              objectiveText: 'Concept interest',
              question: 'How interested would you be in this concept?',
              questionVersion: 'v3',
              options: [
                QuestionOption(code: 'A', label: 'Very interested'),
                QuestionOption(code: 'B', label: 'Not interested'),
              ],
              accepted: false,
              source: 'm2_review_question_versions',
            ),
          ],
        );
      tester.pumpComponent(
        StageFiveQuestionnairePreview(m2AssessmentId: _assessmentId, api: port),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('DRAFT'), findsOneComponent);
      expect(find.text('Q1'), findsOneComponent);
      expect(find.text('Draft'), findsOneComponent);
      expect(
        find.text('How interested would you be in this concept?'),
        findsOneComponent,
      );
      expect(find.text('Very interested'), findsOneComponent);
      expect(find.text('A'), findsOneComponent);
      expect(find.text('version v3'), findsOneComponent);
      expect(
        find.textContaining('objective O1'),
        findsOneComponent,
      );
      // The four statuses are separate rows, not one readiness badge.
      expect(find.text('Generated'), findsOneComponent);
      expect(find.text('Reviewed by you'), findsOneComponent);
      expect(find.text('Scientifically accepted'), findsOneComponent);
      expect(find.text('Published or fielded'), findsOneComponent);
      // This endpoint does not join the owner-review table, so the review state
      // is unknown here — and unknown must not be rendered as "not reviewed".
      expect(find.text('not reported by this endpoint'), findsOneComponent);
      expect(find.text('not accepted'), findsOneComponent);
      expect(find.text('not authorised'), findsOneComponent);
      expect(find.text('m2_review_question_versions'), findsOneComponent);
    });

    testComponents('a generated candidate is excluded, not merged into the draft', (
      tester,
    ) async {
      final port = _FakeStagePort()
        ..previewValue = const QuestionnairePreview(
          status: 'DRAFT_AVAILABLE',
          reason: 'QUESTIONNAIRE_SOURCE_PROJECTION_UNVERIFIED',
          draftOnly: true,
          fieldingAuthorized: false,
          publicationAuthorized: false,
          items: [
            PreviewItem(
              objectiveId: 'O1',
              objectiveText: 'Concept interest',
              question: 'How interested would you be?',
              questionVersion: 'v1',
              options: [],
              accepted: false,
              source: 'm2_review_question_versions',
            ),
          ],
        )
        ..candidateValue = [
          _candidate(question: 'A generated question that is not in the preview?'),
        ];
      tester.pumpComponent(
        StageFiveQuestionnairePreview(m2AssessmentId: _assessmentId, api: port),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // The candidate wording appears, but under the exclusion heading.
      expect(
        find.text('A generated question that is not in the preview?'),
        findsOneComponent,
      );
      expect(find.text('Generated candidates'), findsOneComponent);
      expect(find.text('not in this preview'), findsOneComponent);
      expect(
        find.textContaining('are not part of it'),
        findsOneComponent,
      );
      // Its execution is reported as simulated rather than as a live run.
      expect(find.text('simulated — no provider call'), findsOneComponent);
      expect(find.text('not reviewed yet'), findsOneComponent);
    });

    testComponents('a reviewed candidate shows the decision, still not accepted', (
      tester,
    ) async {
      final port = _FakeStagePort()
        ..previewValue = const QuestionnairePreview(
          status: 'UNAVAILABLE',
          reason: 'NO_ADMITTED_OBJECTIVE',
          items: [],
          draftOnly: true,
          fieldingAuthorized: false,
          publicationAuthorized: false,
        )
        ..candidateValue = [
          _candidate(
            review: const CandidateReview(
              decision: 'APPROVE_FOR_REVIEW',
              recordedAt: '2026-11-22T01:00:00Z',
              reviewed: true,
            ),
          ),
        ];
      tester.pumpComponent(
        StageFiveQuestionnairePreview(m2AssessmentId: _assessmentId, api: port),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('APPROVE_FOR_REVIEW'), findsOneComponent);
      // A review is not a scientific acceptance and not a publication.
      expect(find.text('not accepted'), findsOneComponent);
      expect(find.text('not authorised'), findsOneComponent);
      // The blocked preview still states its own reason.
      expect(
        find.textContaining('No research objective has been admitted'),
        findsOneComponent,
      );
    });

    testComponents('a claimed fielding authority is surfaced, not hidden', (
      tester,
    ) async {
      final port = _FakeStagePort()
        ..previewValue = const QuestionnairePreview(
          status: 'DRAFT_AVAILABLE',
          reason: '',
          draftOnly: false,
          fieldingAuthorized: true,
          publicationAuthorized: false,
          items: [
            PreviewItem(
              objectiveId: 'O1',
              objectiveText: 'Concept interest',
              question: 'How interested would you be?',
              questionVersion: 'v1',
              options: [],
              accepted: false,
            ),
          ],
        );
      tester.pumpComponent(
        StageFiveQuestionnairePreview(m2AssessmentId: _assessmentId, api: port),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('The server reports fielding or publication authority'),
        findsOneComponent,
      );
      // The ladder must not also claim publication is outstanding.
      expect(find.text('authorised'), findsOneComponent);
    });
  });
}
