import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal_api.dart';

import 'fixtures/bdj_objective_fixtures.dart';

void main() {
  group('BDJ objective evaluation envelope', () {
    test('decodes the three persisted proposals with their categories', () {
      final evaluation = BdjObjectiveEvaluation.fromJson(evaluationPayload());
      expect(evaluation.contractVersion, 'bdj-objective-proposal/1');
      expect(evaluation.proposalCount, 3);
      expect(evaluation.proposals, hasLength(3));
      expect(
        evaluation.proposals.map((row) => row.recommendation.status),
        [
          BdjRecommendationStatus.mostSuggested,
          BdjRecommendationStatus.mostSuggested,
          BdjRecommendationStatus.suggested,
        ],
      );
      expect(evaluation.isEmpty, isFalse);
      expect(evaluation.findingAuthority, 'CANDIDATE_ONLY');
      expect(evaluation.statusContract, 'UNRECONCILED_PROPOSAL');
    });

    test('source-confirmed proposals carry a problem and a source reference', () {
      final evaluation = BdjObjectiveEvaluation.fromJson(evaluationPayload());
      final confirmed = evaluation.proposals
          .where((row) => row.recommendation.status.isSourceConfirmed)
          .toList();
      expect(confirmed, hasLength(2));
      for (final row in confirmed) {
        expect(row.recommendation.problem, isNotNull);
        expect(row.recommendation.sourceRefs, isNotEmpty);
        expect(row.recommendation.isProperlySourced, isTrue);
      }
      expect(confirmed.first.recommendation.sourceRefs.single.itemKey, 'M2V1-01');
      expect(confirmed.last.recommendation.sourceRefs.single.itemKey, 'M2V1-08');
    });

    test('the exploratory proposal has no problem and no source reference', () {
      final evaluation = BdjObjectiveEvaluation.fromJson(evaluationPayload());
      final exploratory = evaluation.proposals.last;
      expect(exploratory.recommendation.status, BdjRecommendationStatus.suggested);
      expect(exploratory.recommendation.problem, isNull);
      expect(exploratory.recommendation.sourceRefs, isEmpty);
      expect(exploratory.recommendation.problemType, 'EXPLORATORY_RESEARCH_NEED');
      // Not being sourced is correct for SUGGESTED, so it must not be flagged.
      expect(exploratory.recommendation.isProperlySourced, isTrue);
    });

    test('a MOST_SUGGESTED proposal without a reference is not trusted', () {
      final payload = evaluationPayload();
      final proposals = payload['proposals'] as List;
      final broken = Map<String, dynamic>.from(proposals.first as Map)
        ..['source_refs'] = <Map<String, dynamic>>[];
      final recommendation = BdjRecommendation.fromJson(broken);
      expect(recommendation.status.isSourceConfirmed, isTrue);
      expect(recommendation.isProperlySourced, isFalse);
    });

    test('review state is decoded per proposal', () {
      final evaluation = BdjObjectiveEvaluation.fromJson(evaluationPayload());
      expect(evaluation.proposals[0].reviewState, BdjReviewState.pending);
      expect(evaluation.proposals[1].reviewState, BdjReviewState.approved);
      expect(evaluation.proposals[0].reviewState.hasDecision, isFalse);
      expect(evaluation.proposals[1].reviewState.hasDecision, isTrue);
    });

    test('the execution block reports a simulated, non-dispatched attempt', () {
      final evaluation = BdjObjectiveEvaluation.fromJson(evaluationPayload());
      final execution = evaluation.execution!;
      expect(execution.isSimulated, isTrue);
      expect(execution.dispatched, isFalse);
      expect(execution.reused, isFalse);
      expect(execution.attemptNo, 1);
      expect(execution.receiptOutcome, 'returned');
      expect(execution.promptVersion, 'BDJ-OBJECTIVE-3-CAND');
      expect(execution.promptSha256, startsWith('76027bff'));
    });

    test('an empty proposal list is empty, not an error', () {
      final payload = evaluationPayload()
        ..['proposals'] = <Map<String, dynamic>>[]
        ..['proposal_count'] = 0;
      final evaluation = BdjObjectiveEvaluation.fromJson(payload);
      expect(evaluation.isEmpty, isTrue);
      expect(evaluation.proposalCount, 0);
    });

    test('a list envelope without an execution block still decodes', () {
      final payload = evaluationPayload()
        ..remove('execution')
        ..remove('contract_version');
      final listed = BdjObjectiveProposalList.fromJson(payload);
      expect(listed.proposals, hasLength(3));
      expect(listed.proposalCount, 3);
      expect(listed.contextId, '0af90393-46b3-56ed-bd76-7776cd5ec1c2');
    });
  });

  group('BDJ decision and admission', () {
    test('APPROVED is preserved while admission is held', () {
      final decision = BdjObjectiveDecision.fromJson(
        decisionPayload(
          decision: 'APPROVED',
          admissionState: 'HELD',
          admissionReason: 'M2_UNCERTAINTY_LINK_REQUIRED',
          pendingRequirement:
              'A source-linked BDJ finding review is not adopted; the objective '
              'cannot be linked to a confirmed uncertainty yet.',
        ),
      );
      expect(decision.isApproved, isTrue);
      expect(decision.isRejected, isFalse);
      expect(decision.decisionCreated, isTrue);
      expect(decision.reviewState, BdjReviewState.approved);
      // The two facts must not collapse into one another.
      expect(decision.admission.state, BdjAdmissionState.held);
      expect(decision.admission.state.grantsDownstreamAuthority, isFalse);
      expect(decision.admission.qgExecution, isFalse);
      expect(decision.admission.fieldingAuthorized, isFalse);
      expect(decision.admission.uncertaintyLink, isNull);
      expect(decision.admission.summary, contains('not admitted'));
    });

    test('REJECTED is not admissible', () {
      final decision = BdjObjectiveDecision.fromJson(
        decisionPayload(
          decision: 'REJECTED',
          admissionState: 'NOT_ADMISSIBLE',
          admissionReason: 'PROPOSAL_NOT_APPROVED',
        ),
      );
      expect(decision.isRejected, isTrue);
      expect(decision.admission.state, BdjAdmissionState.notAdmissible);
      expect(decision.admission.qgExecution, isFalse);
      expect(decision.admission.summary, contains('Not admissible'));
    });

    test('ADMITTED is its own state and still grants nothing downstream', () {
      // The server has always emitted `ADMITTED` for a recorded admission.
      // This enum had no member for it, so the Stage 3 card reported
      // "Admission unreadable" for an objective that was in fact admitted.
      final decision = BdjObjectiveDecision.fromJson(
        decisionPayload(
          decision: 'APPROVED',
          admissionState: 'ADMITTED',
          admissionReason: 'ADMISSION_RECORDED',
        ),
      );
      expect(decision.admission.state, BdjAdmissionState.admitted);
      expect(decision.admission.summary, contains('admitted for question generation'));
      expect(decision.admission.summary, contains('not a fielding'));
      // Admission is not a permission. If this ever becomes true, the whole
      // separation between admission and authority has been lost.
      expect(decision.admission.state.grantsDownstreamAuthority, isFalse);
      expect(decision.admission.qgExecution, isFalse);
      expect(decision.admission.fieldingAuthorized, isFalse);
    });

    test('a repeated identical decision is reported as not newly created', () {
      final decision = BdjObjectiveDecision.fromJson(
        decisionPayload(
          decision: 'APPROVED',
          admissionState: 'HELD',
          admissionReason: 'M2_UNCERTAINTY_LINK_REQUIRED',
          decisionCreated: false,
        ),
      );
      expect(decision.decisionCreated, isFalse);
      expect(decision.isApproved, isTrue);
    });

    test('an unreadable admission block never claims authority', () {
      final payload = decisionPayload(
        decision: 'APPROVED',
        admissionState: 'HELD',
        admissionReason: 'M2_UNCERTAINTY_LINK_REQUIRED',
      )..remove('admission');
      final decision = BdjObjectiveDecision.fromJson(payload);
      expect(decision.admission.state, BdjAdmissionState.unrecognised);
      expect(decision.admission.qgExecution, isFalse);
      expect(decision.admission.fieldingAuthorized, isFalse);
    });
  });

  group('staleness classification', () {
    test('the stale-source family is recognised', () {
      expect(isStaleSourceCode(BdjObjectiveCodes.sourceNotCurrent), isTrue);
      expect(isStaleSourceCode(BdjObjectiveCodes.contextNotCurrent), isTrue);
    });

    test('other refusals are not treated as staleness', () {
      expect(isStaleSourceCode(BdjObjectiveCodes.proposalNotFound), isFalse);
      expect(isStaleSourceCode(BdjObjectiveCodes.candidateRejected), isFalse);
      expect(isStaleSourceCode(BdjObjectiveCodes.executionHeld), isFalse);
      expect(isStaleSourceCode(null), isFalse);
    });
  });

  group('unrecognised values are surfaced, not coerced', () {
    test('an unknown recommendation status stays visible', () {
      final recommendation = BdjRecommendation.fromJson(const {
        'recommendation_status': 'CLARIFY',
        'problem_type': 'SOMETHING_ELSE',
        'research_objective': 'To investigate something.',
        'reason': 'Because.',
        'source_refs': <Map<String, dynamic>>[],
      });
      expect(recommendation.status, BdjRecommendationStatus.unrecognised);
      expect(recommendation.status.isSourceConfirmed, isFalse);
      expect(recommendation.status.wire, 'UNRECOGNISED');
    });

    test('an unknown review state stays visible', () {
      expect(BdjReviewState.parse('CONFIRMED'), BdjReviewState.unrecognised);
      expect(BdjReviewState.parse(null), BdjReviewState.unrecognised);
    });
  });
}
