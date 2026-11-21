import 'package:shared_logic/shared_logic.dart';
import 'package:test/test.dart';

/// A transport double: answers one canned response, or throws one canned
/// failure. Records the last request so the URL/body contract can be asserted.
class StubClient extends ApiClient {
  final Map<String, dynamic>? response;
  final Object? failure;
  String? path;
  Map<String, dynamic>? body;
  Map<String, String>? query;

  StubClient.answer(this.response) : failure = null;
  StubClient.throws(this.failure) : response = null;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    this.path = path;
    this.query = query;
    if (failure != null) throw failure!;
    return response!;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    this.path = path;
    this.body = body;
    if (failure != null) throw failure!;
    return response!;
  }

  @override
  Future<Map<String, dynamic>> put(String path, Map<String, dynamic> body) async {
    this.path = path;
    this.body = body;
    if (failure != null) throw failure!;
    return response!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected request: ${invocation.memberName}');
}

const _objective = '00000000-0000-4000-8000-000000000001';
const _context = '00000000-0000-4000-8000-000000000002';
const _version = '00000000-0000-4000-8000-000000000003';

Map<String, dynamic> _validatedBody() => {
  'status': 'VALIDATED_OUTPUT',
  'code': null,
  'version': _version,
  'candidate': {
    'question': 'How much rent would you pay for this unit?',
    'response_codes': ['A', 'B'],
    'response_options': ['Under RM 4,000', 'RM 4,000 or more'],
    'missing_business_facts': <String>[],
  },
  'field_authority': {
    'scientifically_adopted': false,
    'fielding_authorized': false,
  },
  'admission': {'uncertainty_version': _objective},
  'attempts': [
    {'attempt': 1, 'outcome': 'ACCEPTED'},
  ],
  'missing_business_facts': <String>[],
  'candidate_authority': 'ENTREPRENEUR_REVIEW_ONLY',
};

void main() {
  group('review actions are decided in one place', () {
    test('a pending version offers all three decisions', () {
      expect(reviewActionsFor(ResearchDecision.pending), [
        ResearchReviewAction.approveForReview,
        ResearchReviewAction.reject,
        ResearchReviewAction.requestRevision,
      ]);
    });

    test('a decided version offers no decision', () {
      for (final decided in [
        ResearchDecision.approveForReview,
        ResearchDecision.reject,
        ResearchDecision.requestRevision,
        ResearchDecision.unknown,
      ]) {
        expect(reviewActionsFor(decided), isEmpty, reason: '$decided');
      }
    });

    test('only REQUEST_REVISION allows generating a child version', () {
      expect(canGenerateRevision(ResearchDecision.requestRevision), isTrue);
      expect(canGenerateRevision(ResearchDecision.pending), isFalse);
      expect(canGenerateRevision(ResearchDecision.reject), isFalse);
    });

    test('an unrecognised code is not silently treated as pending', () {
      expect(
        ResearchDecision.fromCode('SOMETHING_NEW'),
        ResearchDecision.unknown,
      );
      expect(reviewActionsFor(ResearchDecision.fromCode('SOMETHING_NEW')), isEmpty);
    });
  });

  group('field authority defaults to "no authority"', () {
    test('a missing block is a proposal', () {
      final authority = FieldAuthority.fromJson(null);
      expect(authority.isProposal, isTrue);
      expect(authority.grantsAnyAuthority, isFalse);
    });

    test('explicit false flags are a proposal', () {
      final authority = FieldAuthority.fromJson({
        'scientifically_adopted': false,
        'fielding_authorized': false,
      });
      expect(authority.isProposal, isTrue);
    });

    test('an adopted flag is never a proposal', () {
      final authority = FieldAuthority.fromJson({
        'scientifically_adopted': true,
        'fielding_authorized': false,
      });
      expect(authority.isProposal, isFalse);
      expect(authority.grantsAnyAuthority, isTrue);
    });
  });

  group('prepare outcome classification', () {
    test('VALIDATED_OUTPUT yields a candidate with zipped options', () {
      final outcome = CandidatePrepareOutcome.fromAnswer(_validatedBody());
      expect(outcome.kind, CandidateOutcomeKind.validated);
      expect(outcome.hasCandidate, isTrue);
      expect(outcome.candidate!.version, _version);
      expect(outcome.candidate!.options, [
        const ResearchAnswerOption('A', 'Under RM 4,000'),
        const ResearchAnswerOption('B', 'RM 4,000 or more'),
      ]);
      expect(outcome.candidate!.fieldAuthority.isProposal, isTrue);
      expect(outcome.attempts, hasLength(1));
    });

    test('VALID_ABSTENTION is an answer, not an error', () {
      final outcome = CandidatePrepareOutcome.fromAnswer({
        'status': 'VALID_ABSTENTION',
        'version': null,
        'candidate': {
          'decision': 'ABSTAIN_NEEDS_REVIEW',
          'missing_business_facts': ['PRICE'],
          'question': '',
        },
        'missing_business_facts': ['PRICE'],
      });
      expect(outcome.kind, CandidateOutcomeKind.abstention);
      expect(outcome.isAbstention, isTrue);
      expect(outcome.hasCandidate, isFalse);
      expect(outcome.missingBusinessFacts, ['PRICE']);
      expect(outcome.abstentionDecision, 'ABSTAIN_NEEDS_REVIEW');
    });

    test('documented HTTP refusals map to distinct kinds', () {
      expect(
        CandidatePrepareOutcome.fromFailure(
          const ConflictFailure('stale', backendCode: 'QG_CONTEXT_REVISION_STALE'),
        ).kind,
        CandidateOutcomeKind.conflict,
      );
      expect(
        CandidatePrepareOutcome.fromFailure(
          const ThrottledFailure(
            'budget',
            backendCode: 'MODEL_ATTEMPT_BUDGET_EXHAUSTED',
          ),
        ).kind,
        CandidateOutcomeKind.budgetExhausted,
      );
      expect(
        CandidatePrepareOutcome.fromFailure(
          const ServiceFailure.response('missing', statusCode: 503),
        ).kind,
        CandidateOutcomeKind.unavailable,
      );
      expect(
        CandidatePrepareOutcome.fromFailure(
          const NetworkFailure(),
        ).kind,
        CandidateOutcomeKind.unavailable,
      );
    });

    test('a 200 with an undocumented status is not a candidate', () {
      final outcome = CandidatePrepareOutcome.fromAnswer({
        'status': 'SOMETHING_ELSE',
        'version': _version,
      });
      expect(outcome.kind, CandidateOutcomeKind.unavailable);
      expect(outcome.hasCandidate, isFalse);
    });

    test('a validated body without a version fails closed', () {
      expect(
        () => CandidatePrepareOutcome.fromAnswer({
          'status': 'VALIDATED_OUTPUT',
          'version': null,
          'candidate': {'question': 'Q'},
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('transport contract', () {
    test('prepare sends the documented body to the documented path', () async {
      final client = StubClient.answer(_validatedBody());
      final repository = ApiM2Repository(client);
      final outcome = await repository.prepareCandidate(
        objectiveId: _objective,
        expectedRevision: 4,
        contextId: _context,
      );
      expect(
        client.path,
        '/api/v1/m2/research-objectives/$_objective/qg-candidate',
      );
      expect(client.body, {'expected_revision': 4, 'context_id': _context});
      expect(outcome.hasCandidate, isTrue);
    });

    test('a 409 is returned as a conflict outcome, not thrown', () async {
      final client = StubClient.throws(
        const ConflictFailure('stale', backendCode: 'QG_CONTEXT_REVISION_STALE'),
      );
      final outcome = await ApiM2Repository(client).prepareCandidate(
        objectiveId: _objective,
        expectedRevision: 1,
        contextId: _context,
      );
      expect(outcome.kind, CandidateOutcomeKind.conflict);
      expect(outcome.code, 'QG_CONTEXT_REVISION_STALE');
    });

    test('a 401 is rethrown for the app session handling', () async {
      final client = StubClient.throws(
        const UnauthorizedFailure.response('expired', statusCode: 401),
      );
      expect(
        () => ApiM2Repository(client).prepareCandidate(
          objectiveId: _objective,
          expectedRevision: 1,
          contextId: _context,
        ),
        throwsA(isA<UnauthorizedFailure>()),
      );
    });

    test('revise targets the child-version route', () async {
      final client = StubClient.answer(_validatedBody());
      await ApiM2Repository(client).reviseCandidate(
        version: _version,
        expectedRevision: 2,
        contextId: _context,
      );
      expect(client.path, '/api/v1/m2/research-questions/$_version/revision');
    });

    test('history parses every version without dropping a decision', () async {
      final client = StubClient.answer({
        'objective_id': _objective,
        'objective': 'Which rent level is acceptable?',
        'version_count': 2,
        'versions': [
          {
            'version': _version,
            'depth': 0,
            'question': 'First wording',
            'options': [
              {'code': 'A', 'label': 'Yes', 'eligible': true},
            ],
            'status': 'REQUEST_REVISION',
            'decision': 'REQUEST_REVISION',
            'rationale': 'Too vague',
          },
          {
            'version': '00000000-0000-4000-8000-000000000004',
            'depth': 1,
            'question': 'Second wording',
            'options': <Map<String, dynamic>>[],
            'supersedes': _version,
            'status': 'PENDING',
            'decision': null,
          },
        ],
      });
      final history = await ApiM2Repository(client).candidateHistory(_objective, 3);
      expect(history.versions, hasLength(2));
      expect(
        history.versions.first.decision,
        ResearchDecision.requestRevision,
      );
      expect(history.versions.last.decision, ResearchDecision.pending);
      expect(history.versions.last.supersedes, _version);
      expect(client.query, {'expected_revision': '3'});
    });

    test('a review with a blank rationale uses the approved default', () async {
      final client = StubClient.answer({'decision': 'REJECT'});
      await ApiM2Repository(client).recordOwnerReview(
          _version,
          ResearchReviewAction.reject,
          '   ',
      );
      expect(client.body, {'decision': 'REJECT', 'rationale': 'No rationale provided by reviewer.'});
    });

    test('owner prediction uses the versioned current-source contract', () async {
      final read = StubClient.answer({'id': _version, 'objective_id': _objective,
        'question': 'Synthetic question?', 'options': <Object>[], 'option_code': 'A'});
      final item = await ApiM2Repository(read).readEntrepreneurQuestion(_version, 3);
      expect(item['option_code'], 'A');
      expect(read.path, '/api/v1/m2/research-questions/$_version/entrepreneur-review');
      expect(read.query, {'expected_revision': '3'});
      final save = StubClient.answer({'question_version': _version, 'desired_option': 'A'});
      await ApiM2Repository(save).saveDesiredOption(_version, 3, 'A');
      expect(save.path, '/api/v1/m2/research-questions/$_version/desired-option');
      expect(save.body, {'expected_revision': 3, 'option_code': 'A'});
      final wrong = StubClient.answer({'question_version': _objective, 'desired_option': 'A'});
      await expectLater(ApiM2Repository(wrong).saveDesiredOption(_version, 3, 'A'), throwsFormatException);
    });

    test('a review sends the documented decision and rationale', () async {
      final client = StubClient.answer({
        'candidate_id': _version,
        'decision': 'REQUEST_REVISION',
        'rationale': 'Name the reference period.',
        'fielding_authorized': false,
        'scientific_acceptance': false,
      });
      final result = await ApiM2Repository(client).recordOwnerReview(
        _version,
        ResearchReviewAction.requestRevision,
        '  Name the reference period.  ',
      );
      expect(client.path, '/api/v1/m2/research-questions/$_version/owner-review');
      expect(client.body, {
        'decision': 'REQUEST_REVISION',
        'rationale': 'Name the reference period.',
      });
      expect(result['decision'], 'REQUEST_REVISION');
    });

    test('a review response that claims authority is rejected', () async {
      final client = StubClient.answer({
        'decision': 'APPROVE_FOR_REVIEW',
        'fielding_authorized': true,
      });
      expect(
        () => ApiM2Repository(client).recordOwnerReview(
          _version,
          ResearchReviewAction.approveForReview,
          'Looks reasonable.',
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('entrepreneur-facing wording', () {
    test('every declared missing fact has a plain-language label', () {
      for (final code in [
        'PRICE',
        'PRODUCT',
        'PACKAGE_SIZE',
        'SERVICE_FORMAT',
        'POPULATION',
        'REFERENCE_PERIOD',
        'LOCATION',
        'OBJECTIVE',
        'OTHER',
      ]) {
        expect(missingBusinessFactLabel(code), isNotEmpty, reason: code);
        expect(missingBusinessFactLabel(code), isNot(code), reason: code);
      }
    });

    test('an unknown fact code is shown verbatim, never invented', () {
      expect(missingBusinessFactLabel('TURNOVER'), 'TURNOVER');
    });

    test('refusal copy is shared, not re-written per app', () {
      final conflict = candidateRefusalCopy(
        CandidatePrepareOutcome.fromFailure(
          const ConflictFailure('stale', backendCode: 'QG_CONTEXT_REVISION_STALE'),
        ),
      );
      expect(conflict.title, 'Your research state changed');
      expect(conflict.body, contains('Reload the objective'));

      final budget = candidateRefusalCopy(
        CandidatePrepareOutcome.fromFailure(const ThrottledFailure('budget')),
      );
      expect(budget.title, 'Model attempt budget exhausted');

      final unavailable = candidateRefusalCopy(
        CandidatePrepareOutcome.fromFailure(
          const ServiceFailure.response('missing', statusCode: 503),
        ),
      );
      expect(unavailable.title, 'No question was produced');
      expect(unavailable.body, contains('nothing was generated'));
    });

    test('a known conflict code explains what to do next', () {
      expect(
        candidateConflictExplanation('QG_CANDIDATE_REVISION_UNCHANGED'),
        contains('no new version'),
      );
      expect(
        candidateConflictExplanation('WHATEVER'),
        contains('Nothing was stored'),
      );
    });
  });
}
