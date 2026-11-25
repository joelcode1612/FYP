import 'package:jaspr/dom.dart';
import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/application/stage_labels.dart';
import 'package:sitewise_jaspr_web/features/assessment/application/stage_reason_copy.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/assessment_journey_stepper.dart';

const _capability = AssessmentCapability(available: false);
const _capabilities = AssessmentCapabilities(
  model: _capability,
  explanation: _capability,
  report: _capability,
);

const _keys = [
  'select_property',
  'business_requirements',
  'location_evidence',
  'ai_explanation',
  'assessment_report',
];

/// A server-shaped record: `progress_percent` is what the backend computed, and
/// each stage carries the contract's own `state` and `reason`.
AssessmentRecord recordWith({
  required int completed,
  Map<String, ({String state, String? reason})> stageState = const {},
}) => AssessmentRecord(
  assessmentId: 'synthetic',
  propertyId: 'synthetic',
  status: completed == 5 ? 'completed' : 'in_progress',
  currentStage: completed < 5 ? completed + 1 : 5,
  currentStageKey: _keys[completed < 5 ? completed : 4],
  completedStages: completed,
  totalStages: 5,
  progressPercent: (completed / 5 * 100).round(),
  reportAvailable: false,
  requirements: null,
  requirementsVersion: 0,
  capabilities: _capabilities,
  nextAction: const AssessmentNextAction(
    kind: 'continue',
    stageKey: 'business_requirements',
    label: '',
  ),
  property: null,
  stages: [
    for (var i = 0; i < _keys.length; i++)
      AssessmentStage(
        key: _keys[i],
        number: i + 1,
        title: _keys[i],
        status: i < completed
            ? 'complete'
            : i == completed
            ? 'current'
            : 'incomplete',
        state: stageState[_keys[i]]?.state ??
            (i < completed
                ? 'COMPLETE'
                : i == completed
                ? 'BLOCKED'
                : 'BLOCKED'),
        reason: stageState[_keys[i]]?.reason,
      ),
  ],
);

/// Every token `assessment_progress.evaluate()` can emit, copied from the
/// backend constants. Kept here so a new server reason that this build has no
/// sentence for is a visible test failure rather than a silent de-tokenisation.
const _serverReasonVocabulary = <String>[
  'PROPERTY_NOT_SELECTED',
  'STAGE_1_INCOMPLETE',
  'M2_NOT_LINKED',
  'CURRENT_CONFIRMATION_REQUIRED',
  'M2_STORAGE_UNAVAILABLE',
  'NO_RESEARCH_OBJECTIVE',
  'OBJECTIVE_AUTHORITY_UNVERIFIED',
  'OBJECTIVE_CONTRACT_UNAVAILABLE_FOR_INSTRUMENT',
  'STAGE_2_INCOMPLETE',
  'STAGE_3_CONTRACT_PREDICATES_UNSATISFIED',
  'STAGE_3_INCOMPLETE',
  'QUESTIONNAIRE_COMPOSITION_INVALID',
  'CANDIDATE_REVIEW_PENDING',
  'CANDIDATE_REJECTED',
  'QUESTION_GENERATION_AUTHORIZATION_REQUIRED',
  'STAGE_4_INCOMPLETE',
  'QUESTIONNAIRE_PREVIEW_CONTRACT_UNADOPTED',

  // Stage 3 has a second, larger vocabulary. `_stage3_reason()` forwards the
  // first failing T3 predicate's reason verbatim, so these reach the wire as a
  // stage reason even though the progress contract never names them.
  ..._stage3PredicateVocabulary,
];

/// Every reason a `sitewise-stage3-completion/2` predicate can report when it
/// fails. T3-06's `NO_UNRESOLVED_BLOCKERS` and the satisfaction reasons
/// (`CONFIRMATION_CURRENT`, `CONTEXT_BOUND`, `EVALUATION_AUTHORIZED`,
/// `ALL_OBJECTIVES_RESOLVED`, `OWNER_VERIFIED`, `ZERO_PROPOSALS_VALID_OUTCOME`)
/// are deliberately absent: a satisfied predicate is never a blocker, so it can
/// never become a stage's `reason`.
const _stage3PredicateVocabulary = <String>[
  'SUBJECT_NOT_FOUND', // T3-01
  'OWNERSHIP_MISMATCH', // T3-01
  'NO_CURRENT_CONFIRMATION', // T3-02
  'CONFIRMATION_STALE', // T3-02
  'NO_CONTEXT_FOR_CONFIRMATION', // T3-03
  'CONTEXT_NOT_CURRENT', // T3-03
  'NO_EVALUATION', // T3-04
  'EVALUATION_NOT_VALID', // T3-04
  'EVALUATION_NOT_AUTHORIZED', // T3-04
  'EVALUATION_PROVENANCE_MISMATCH', // T3-04
  'EVALUATION_CONTEXT_MISMATCH', // T3-04
  'EVALUATION_RULESET_SUPERSEDED', // T3-04
  'SOURCE_FINGERPRINT_UNAVAILABLE', // T3-04
  'ZERO_PROPOSALS_WITHOUT_EVALUATION', // T3-05
  'UNDECIDED_PROPOSAL', // T3-05
  'APPROVED_NOT_ADMITTED', // T3-05
  'OBJECTIVES_NOT_REGISTERED', // T3-06
  'RESEARCH_TOPIC_ANSWER_UNAVAILABLE', // T3-06
  'BLOCKERS_PRESENT', // T3-06
];

/// Tokens the contract says the entrepreneur's own action can clear.
const _yourAction = <String>{
  'PROPERTY_NOT_SELECTED',
  'STAGE_1_INCOMPLETE',
  'M2_NOT_LINKED',
  'CURRENT_CONFIRMATION_REQUIRED',
  'NO_RESEARCH_OBJECTIVE',
  'OBJECTIVE_AUTHORITY_UNVERIFIED',
  'STAGE_2_INCOMPLETE',
  'STAGE_3_INCOMPLETE',
  'CANDIDATE_REVIEW_PENDING',
  'CANDIDATE_REJECTED',
  'STAGE_4_INCOMPLETE',
  'NO_CURRENT_CONFIRMATION',
  'CONFIRMATION_STALE',
  'UNDECIDED_PROPOSAL',
  'OBJECTIVES_NOT_REGISTERED',
  'RESEARCH_TOPIC_ANSWER_UNAVAILABLE',
};

void main() {
  group('stage.reason survives the wire', () {
    test('a BLOCKED stage keeps its reason even when status is not unavailable', () {
      // The server only copies a reason into `unavailable_reason` when the
      // legacy status is `unavailable`. A blocked *current* stage therefore
      // carried its reason in `reason` alone — the field the model used to drop.
      final stage = AssessmentStage.fromJson({
        'key': 'location_evidence',
        'number': 3,
        'title': 'Location evidence',
        'status': 'current',
        'state': 'BLOCKED',
        'reason': 'OBJECTIVE_CONTRACT_UNAVAILABLE_FOR_INSTRUMENT',
        'unavailable_reason': null,
      });
      expect(stage.isBlocked, isTrue);
      expect(stage.isComplete, isFalse);
      expect(stage.blockerReason,
          'OBJECTIVE_CONTRACT_UNAVAILABLE_FOR_INSTRUMENT');
      expect(stageReasonMessage(stage.blockerReason), contains('system contract'));
    });

    test('the legacy field is still honoured when reason is absent', () {
      final stage = AssessmentStage.fromJson({
        'key': 'ai_explanation',
        'number': 4,
        'title': 'AI recommendation explanation',
        'status': 'unavailable',
        'state': 'NOT_AVAILABLE',
        'unavailable_reason': 'CANDIDATE_REVIEW_PENDING',
      });
      expect(stage.reason, isNull);
      expect(stage.blockerReason, 'CANDIDATE_REVIEW_PENDING');
    });

    test('a complete stage needs no blocker', () {
      final stage = AssessmentStage.fromJson({
        'key': 'business_requirements',
        'number': 2,
        'title': 'Business requirements',
        'status': 'complete',
        'state': 'COMPLETE',
        'reason': null,
      });
      expect(stage.isComplete, isTrue);
      expect(stage.blockerReason, isNull);
    });
  });

  group('one authoritative progress number', () {
    test('the bar and the count are both functions of the stage list', () {
      for (var completed = 0; completed <= 5; completed++) {
        final record = recordWith(completed: completed);
        // The server contract: progress_percent == round(completed / total).
        expect(record.progressPercent, record.stageProgressPercent,
            reason: '$completed of 5 must render one percentage');
        expect(record.stageProgressPercent, (completed / 5 * 100).round());
      }
    });

    test('a percent that disagrees with the stage list cannot split the card', () {
      // Defensive: even a malformed payload renders the bar from the stage list,
      // so the width and the "N / 5" text can never contradict each other.
      final record = AssessmentRecord(
        assessmentId: 'x',
        propertyId: 'x',
        status: 'in_progress',
        currentStage: 3,
        currentStageKey: 'location_evidence',
        completedStages: 2,
        totalStages: 5,
        progressPercent: 99,
        reportAvailable: false,
        requirements: null,
        requirementsVersion: 0,
        capabilities: _capabilities,
        nextAction: const AssessmentNextAction(
          kind: 'continue',
          stageKey: 'location_evidence',
          label: '',
        ),
        property: null,
        stages: const [],
      );
      expect(record.stageProgressPercent, 40);
    });

    test('no stages means no division by zero', () {
      final record = AssessmentRecord(
        assessmentId: 'x',
        propertyId: 'x',
        status: 'in_progress',
        currentStage: 1,
        currentStageKey: 'select_property',
        completedStages: 0,
        totalStages: 0,
        progressPercent: 0,
        reportAvailable: false,
        requirements: null,
        requirementsVersion: 0,
        capabilities: _capabilities,
        nextAction: const AssessmentNextAction(
          kind: 'continue',
          stageKey: 'select_property',
          label: '',
        ),
        property: null,
        stages: const [],
      );
      expect(record.stageProgressPercent, 0);
    });
  });

  group('every backend reason has a sentence', () {
    test('the whole server vocabulary is covered, not de-tokenised', () {
      for (final token in _serverReasonVocabulary) {
        final copy = stageReasonCopy(token);
        expect(copy, isNotNull, reason: '$token must have copy');
        // A de-tokenised fallback always ends up as sentence case of the enum
        // name; a real sentence carries a full stop.
        expect(copy!.message.endsWith('.'), isTrue,
            reason: '$token fell through to the generic fallback');
        expect(copy.message, isNot(contains('_')));
      }
    });

    test('the stage-3 predicate vocabulary gets a sentence, not a code', () {
      // Live copy was "Held: No evaluation" — the lock icon and the system
      // prefix were right, the body was `NO_EVALUATION` de-tokenised. The
      // fallback did its job (the blocker stayed visible), but a reader learns
      // nothing from it. This pins the whole T3 vocabulary so a predicate added
      // on the server shows up here instead of on the page.
      for (final token in _stage3PredicateVocabulary) {
        final message = stageReasonMessage(token)!;
        expect(message.endsWith('.'), isTrue,
            reason: '$token is still falling through to the fallback');
        expect(message.length, greaterThan(40),
            reason: '$token has a stub, not an explanation');
        // The fallback would have produced exactly the de-tokenised token.
        expect(message.toLowerCase(),
            isNot('${token.toLowerCase().replaceAll('_', ' ')}.'));
      }
      // The exact state the operator saw, spelled out.
      expect(stageReasonMessage('NO_EVALUATION'),
          contains('business evaluation'));
      expect(stageReasonIsYourAction('NO_EVALUATION'), isFalse,
          reason: 'the BDJ evaluation is a governed dispatch, not a page action');
    });

    test('the owner of each reason matches the contract', () {
      for (final token in _serverReasonVocabulary) {
        expect(stageReasonIsYourAction(token), _yourAction.contains(token),
            reason: 'wrong owner for $token');
      }
    });

    test('a system hold never reads as the reader\'s next step', () {
      for (final token in const [
        'OBJECTIVE_CONTRACT_UNAVAILABLE_FOR_INSTRUMENT',
        'STAGE_3_CONTRACT_PREDICATES_UNSATISFIED',
        'QUESTIONNAIRE_COMPOSITION_INVALID',
        'QUESTION_GENERATION_AUTHORIZATION_REQUIRED',
        'QUESTIONNAIRE_PREVIEW_CONTRACT_UNADOPTED',
        'M2_STORAGE_UNAVAILABLE',
      ]) {
        expect(stageReasonIsYourAction(token), isFalse, reason: token);
      }
    });

    test('an unknown token is shown, not hidden', () {
      final copy = stageReasonCopy('SOME_NEW_GOVERNANCE_HOLD');
      expect(copy, isNotNull);
      expect(copy!.message, 'Some new governance hold');
      // An unrecognised blocker is never presented as the reader's action.
      expect(copy.isYourAction, isFalse);
    });

    test('no reason means no copy', () {
      expect(stageReasonCopy(null), isNull);
      expect(stageReasonCopy(''), isNull);
      expect(stageReasonCopy('   '), isNull);
      expect(stageReasonMessage(null), isNull);
    });

    test('a blocker names a stage the way the stepper names it', () {
      // "Complete the location evidence stage first." was live copy: the wire
      // key `location_evidence` with its underscores turned into spaces. The
      // stepper calls that step "Business review and research goals", so the
      // sentence sent the reader looking for a step that does not exist.
      //
      // A de-spaced key is only allowed when it is also the label.
      final labels = {
        for (final entry in stageLabels.entries) entry.value.toLowerCase(),
      };
      for (final token in _serverReasonVocabulary) {
        final message = stageReasonCopy(token)!.message.toLowerCase();
        for (final key in _keys) {
          final deSpaced = key.replaceAll('_', ' ');
          if (labels.contains(deSpaced)) continue;
          expect(message.contains(deSpaced), isFalse,
              reason: '$token prints the wire key "$deSpaced" instead of the '
                  'step name "${stageLabels[key]}"');
        }
      }
    });

    test('every stage has a reader-facing name and an unknown one falls back',
        () {
      for (final key in _keys) {
        expect(stageLabels[key], isNotNull, reason: '$key has no label');
      }
      // A stage added on the server before this build knows it still gets the
      // payload's own label rather than a raw key or a blank.
      expect(stageDisplayLabel('brand_new_stage', 'Server label'),
          'Server label');
      expect(stageDisplayLabel('location_evidence', 'ignored'),
          'Business review and research goals');
    });
  });

  group('the stepper shows the blocker beside the count', () {
    testComponents('a blocked current stage prints its reason, count unchanged',
        (tester) async {
      final record = recordWith(
        completed: 2,
        stageState: const {
          'location_evidence': (
            state: 'BLOCKED',
            reason: 'OBJECTIVE_CONTRACT_UNAVAILABLE_FOR_INSTRUMENT',
          ),
        },
      );
      tester.pumpComponent(AssessmentJourneyStepper(
        record: record,
        busy: false,
        governedWorkflow: true,
        selectedStageKey: 'location_evidence',
        onOpenStage: (_) {},
      ));
      await tester.pump();

      // Requirement 6: the count is the record's, and the reason explains the
      // stage without moving it.
      expect(find.text('2 / 5'), findsOneComponent);
      expect(find.text('3 / 5'), findsNothing);
      expect(
        find.text(stageReasonMessage(
            'OBJECTIVE_CONTRACT_UNAVAILABLE_FOR_INSTRUMENT')!),
        findsOneComponent,
      );
    });

    testComponents('a complete stage carries no reason line', (tester) async {
      final record = recordWith(
        completed: 2,
        stageState: const {
          'business_requirements': (state: 'COMPLETE', reason: null),
        },
      );
      tester.pumpComponent(AssessmentJourneyStepper(
        record: record,
        busy: false,
        governedWorkflow: true,
        selectedStageKey: 'business_requirements',
        onOpenStage: (_) {},
      ));
      await tester.pump();
      expect(find.text('2 / 5'), findsOneComponent);
      // Nothing in the vocabulary is rendered for a completed step.
      for (final token in _serverReasonVocabulary) {
        expect(find.text(stageReasonMessage(token)!), findsNothing);
      }
    });

    testComponents('a missing reason renders nothing rather than a guess',
        (tester) async {
      final record = recordWith(completed: 1);
      tester.pumpComponent(AssessmentJourneyStepper(
        record: record,
        busy: false,
        governedWorkflow: true,
        selectedStageKey: 'business_requirements',
        onOpenStage: (_) {},
      ));
      await tester.pump();
      expect(find.text('1 / 5'), findsOneComponent);
      expect(find.textContaining('Held:'), findsNothing);
    });
  });

  group('a successful completion moves every surface once', () {
    test('the count, the percent and the next stage all move together', () {
      final before = recordWith(
        completed: 1,
        stageState: const {
          'business_requirements': (
            state: 'IN_PROGRESS',
            reason: 'CURRENT_CONFIRMATION_REQUIRED',
          ),
        },
      );
      final after = recordWith(completed: 2);

      // Before: one stage, 20%, and the reason the second is not complete.
      expect(before.completedStages, 1);
      expect(before.stageProgressPercent, 20);
      expect(before.progressPercent, before.stageProgressPercent);
      expect(stageReasonIsYourAction(
              before.stageByKey('business_requirements')!.blockerReason),
          isTrue);

      // After the write: the same record type, advanced by exactly one stage.
      expect(after.completedStages, 2);
      expect(after.stageProgressPercent, 40);
      expect(after.progressPercent, after.stageProgressPercent);
      expect(after.stagesRemaining, 3);
      // The completed stage carries no blocker, so nothing explains a stage
      // that is done.
      expect(after.stageByKey('business_requirements')!.isComplete, isTrue);
      expect(after.stageByKey('business_requirements')!.blockerReason, isNull);
    });

    testComponents('the stepper prints the new count after the write',
        (tester) async {
      tester.pumpComponent(AssessmentJourneyStepper(
        record: recordWith(completed: 1),
        busy: false,
        governedWorkflow: true,
        onOpenStage: (_) {},
      ));
      await tester.pump();
      expect(find.text('1 / 5'), findsOneComponent);

      tester.pumpComponent(AssessmentJourneyStepper(
        record: recordWith(completed: 2),
        busy: false,
        governedWorkflow: true,
        onOpenStage: (_) {},
      ));
      await tester.pump();
      expect(find.text('2 / 5'), findsOneComponent);
      expect(find.text('1 / 5'), findsNothing);
    });
  });

  group('stale readiness cannot rewrite the record', () {
    test('a readiness map that lags behind the record does not lower the count',
        () {
      // The post-write sequence is: record replaced, then readiness re-read.
      // Between those two moments readiness still describes the old state.
      // Completeness must come from the record, so the bar cannot regress and
      // then jump back — that flicker is what made the bar look broken.
      final record = recordWith(completed: 2);
      const laggingReadiness = <String, dynamic>{
        'stage_1': {'complete': true},
        'stage_2': {'complete': false},
        'stage_3': {'enterable': false},
        'stage_4': {'enterable': false},
        'stage_5': {'preview_enterable': false},
      };

      expect(record.completedStages, 2);
      expect(record.stageProgressPercent, 40);
      // Readiness still governs entry, and it says "not yet" — which is exactly
      // why it must not also be allowed to govern the count.
      expect(canViewAssessmentStage('location_evidence', laggingReadiness),
          isFalse);
      expect(canViewAssessmentStage('location_evidence', const {
        'stage_3': {'enterable': true},
      }), isTrue);
    });
  });

  group('completing stage 3 and stage 4 moves the number', () {
    test('3/5 is 60% and 4/5 is 80%', () {
      // The two steps the reader expects to see after Stage 3 (business review
      // and research goals) and Stage 4 (question review) finish. Neither is
      // reachable through a stage-write endpoint — they complete on their own
      // evidence — so the number has to come from a re-read of the record.
      expect(recordWith(completed: 2).stageProgressPercent, 40);
      expect(recordWith(completed: 3).stageProgressPercent, 60);
      expect(recordWith(completed: 4).stageProgressPercent, 80);
      expect(recordWith(completed: 5).stageProgressPercent, 100);
    });

    test('the count and the remaining figure move with the percentage', () {
      // One record, three surfaces. If any of these disagreed the reader would
      // see "3/5 stages" beside a 40% bar.
      for (final (done, pct, remaining) in const [
        (2, 40, 3),
        (3, 60, 2),
        (4, 80, 1),
        (5, 100, 0),
      ]) {
        final record = recordWith(completed: done);
        expect(record.completedStages, done);
        expect(record.stageProgressPercent, pct, reason: '$done/5');
        expect(record.stagesRemaining, remaining, reason: '$done/5');
      }
    });

    test('a stage that only partly finished stays at the old number', () {
      // The failure this guards: a 200 write that changed nothing. The record
      // is unchanged, so the bar must be unchanged — a request succeeding is
      // not evidence that a stage completed.
      final before = recordWith(completed: 2);
      final after = recordWith(completed: 2);
      expect(after.stageProgressPercent, before.stageProgressPercent);
      expect(after.allStagesComplete, isFalse);
    });
  });

  group('a finished bar is painted finished, and only then', () {    test('the finished flag is the same two numbers the width uses', () {
      // The card and the details panel both switch their fill to the success
      // token on this flag. Deriving it from `completedStages`/`totalStages` —
      // not from `status`, and not from the server's `progress_percent` — is
      // what stops a bar being painted done while the count beside it still
      // says stages remain.
      expect(recordWith(completed: 5).allStagesComplete, isTrue);
      expect(recordWith(completed: 4).allStagesComplete, isFalse);

      // Far along is not finished. 80% keeps the in-progress colour.
      expect(recordWith(completed: 4).stageProgressPercent, 80);
      expect(recordWith(completed: 5).stageProgressPercent, 100);
      expect(recordWith(completed: 5).stagesRemaining, 0);
    });

    test('a record with no stages is not complete', () {
      // Nothing to have finished. Without the `totalStages > 0` guard the
      // `>=` would make 0/0 read as done and paint an empty bar green.
      final empty = AssessmentRecord(
        assessmentId: 'synthetic',
        propertyId: 'synthetic',
        status: 'in_progress',
        currentStage: 1,
        currentStageKey: 'select_property',
        completedStages: 0,
        totalStages: 0,
        progressPercent: 0,
        reportAvailable: false,
        requirements: null,
        requirementsVersion: 0,
        capabilities: _capabilities,
        nextAction: const AssessmentNextAction(
          kind: 'continue',
          stageKey: 'select_property',
          label: '',
        ),
        property: null,
        stages: const [],
      );
      expect(empty.allStagesComplete, isFalse);
      expect(empty.stageProgressPercent, 0);
    });
  });

  group('a second tap cannot start a second write', () {
    testComponents('while a write is in flight no step is a click target',
        (tester) async {
      // Requirement 7, rapid repeated clicks. The page guards with `_busy`, and
      // the stepper takes the same flag: with it set, every control renders as
      // a plain element instead of a button, so there is nothing to click and
      // no second request can be issued against a record that is mid-update.
      final record = recordWith(completed: 1);

      tester.pumpComponent(AssessmentJourneyStepper(
        record: record,
        busy: false,
        governedWorkflow: false,
        selectedStageKey: 'business_requirements',
        onOpenStage: (_) {},
      ));
      await tester.pump();
      final idle = find.byType(button).evaluate().length;
      expect(idle, greaterThan(0),
          reason: 'an idle stepper must offer its steps');

      tester.pumpComponent(AssessmentJourneyStepper(
        record: record,
        busy: true,
        governedWorkflow: false,
        selectedStageKey: 'business_requirements',
        onOpenStage: (_) {},
      ));
      await tester.pump();
      expect(find.byType(button).evaluate(), isEmpty,
          reason: 'a busy stepper must not accept another tap');
    });
  });

  group('a refused write is reported, never counted', () {    test('the failure kind the page branches on comes from the status', () {
      // The page renders a different state per kind: no retry for an
      // authorization refusal, the server's sentence for a governance refusal,
      // a retry for a service failure. A wrong classification is what turns a
      // refusal into a silently unchanged bar.
      expect(const AssessmentFailure(status: 401, message: '').kind,
          AssessmentFailureKind.unauthorized);
      expect(const AssessmentFailure(status: 403, message: '').kind,
          AssessmentFailureKind.unauthorized);
      expect(const AssessmentFailure(status: 404, message: '').kind,
          AssessmentFailureKind.notFound);
      expect(const AssessmentFailure(status: 409, message: '').kind,
          AssessmentFailureKind.refused);
      expect(const AssessmentFailure(status: 422, message: '').kind,
          AssessmentFailureKind.refused);
      expect(const AssessmentFailure(status: 500, message: '').kind,
          AssessmentFailureKind.serviceFailure);
      expect(const AssessmentFailure(message: '').kind,
          AssessmentFailureKind.serviceFailure);
      expect(const AssessmentFailure(status: 409, message: '').isRetryable,
          isFalse);
      expect(const AssessmentFailure(status: 503, message: '').isRetryable,
          isTrue);
    });
  });
}
