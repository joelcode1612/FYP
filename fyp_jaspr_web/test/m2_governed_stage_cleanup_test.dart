import 'package:jaspr_test/jaspr_test.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart' show DomElement;
import 'package:shared_logic/shared_logic.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/project1_research_stage_panel.dart';
import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'm2_autosave_verification_test.dart' as fixture;

const confirmationId = '00000000-0000-4000-8000-000000000004';
const objectiveId = '00000000-0000-4000-8000-000000000005';
const contextId = '00000000-0000-4000-8000-000000000006';
const candidateId = '00000000-0000-4000-8000-000000000007';

/// Synthetic transport; exercises the current panel, never a model.
class GovernedClient extends fixture.SaveClient {
  bool withObjective = false;
  bool withCandidate = false;
  bool withIntention = false;
  bool withBdj = false;
  bool withVerifiedCandidate = false;
  String? prediction;
  String decision = 'PENDING';
  Map<String, dynamic>? lastReviewBody;
  String? savedObjective;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    final packet = <String, dynamic>{
      'schema_version': 'business-context-package/1.1',
      'identity': {'assessment_id': fixture.mid},
      'confirmation': {
        'id': confirmationId,
        'revision': revision,
        'status': 'CURRENT_CONFIRMED',
      },
      'confirmed_uncertainty': {'id': objectiveId},
      'geography': null,
      'permissions': {'qj_execution': false, 'qg_execution': false},
    };
    packet['packet_hash'] = sha256
        .convert(utf8.encode(canonicalBusinessContextJson(packet)))
        .toString();
    if (withVerifiedCandidate && path.endsWith('/business-context-status')) {
      calls.add('GET $path');
      return {
        'assessment_id': fixture.mid,
        'confirmation_id': confirmationId,
        'assessment_revision': revision,
        'source_is_current': true,
        'status': 'PERSISTED',
        'attempt_count': 1,
        'context_id': contextId,
      };
    }
    if (withVerifiedCandidate &&
        path.endsWith('/business-contexts/$contextId')) {
      calls.add('GET $path');
      return {
        'contract_version': 'persisted-business-context/1',
        'assessment_id': fixture.mid,
        'confirmation_id': confirmationId,
        'assessment_revision': revision,
        'lifecycle_status': 'PERSISTED',
        'context_id': contextId,
        'replayed': false,
        'created_at': '2026-01-01T00:00:00Z',
        'qj_execution_authorized': false,
        'qg_execution_authorized': false,
        'packet': packet,
      };
    }
    const options = [
      {'code': 'A', 'label': 'Synthetic option A', 'eligible': true},
      {'code': 'B', 'label': 'Synthetic option B', 'eligible': true},
    ];
    if (withVerifiedCandidate && path.endsWith('/research-questions')) {
      calls.add('GET $path');
      return {
        'objective_id': objectiveId,
        'objective': 'Synthetic objective',
        'versions': [
          {
            'version': candidateId,
            'question': 'Synthetic candidate question?',
            'options': options,
            'status': decision,
          },
        ],
      };
    }
    if (withVerifiedCandidate && path.endsWith('/entrepreneur-review')) {
      calls.add('GET $path');
      return {
        'id': candidateId,
        'objective_id': objectiveId,
        'question': 'Synthetic candidate question?',
        'options': options,
        'option_code': prediction,
      };
    }
    if (withVerifiedCandidate &&
        path.endsWith('/research-questions/$candidateId')) {
      calls.add('GET $path');
      return {
        'version': candidateId,
        'objective_id': objectiveId,
        'question': 'Synthetic candidate question?',
        'options': options,
        'status': decision,
        'contract_version': 'P1-QG-FIXED-OPTION-1.0',
        'fixed_measurement': {'response_format': 'BINARY_CHOICE'},
        'source_fingerprint': packet['packet_hash'],
      };
    }
    if (path.endsWith('/bdj/current') && withBdj) {
      calls.add('GET $path');
      return {
        'contract_version': 'sitewise-bdj-current/1',
        'assessment_id': fixture.mid,
        'confirmation_id': confirmationId,
        'assessment_revision': revision,
        'source_fingerprint': 'a' * 64,
        'status': 'COMPLETED_WITH_FINDINGS',
        'result': {
          'assessment_id': fixture.mid,
          'assessment_revision': revision,
          'source_fingerprint': 'a' * 64,
          'validation_status': 'valid',
          'finding_authority': 'candidate_only',
          'finding_count': 1,
          'findings': [
            {
              'rule_id': 'SYNTHETIC',
              'observed_condition': 'Synthetic finding',
              'source_refs': [
                {
                  'item_key': 'M2V1-09',
                  'answer_revision_id': 'synthetic-answer',
                  'item_version_id': 'synthetic-version',
                },
              ],
            },
          ],
        },
      };
    }
    if (path.contains('/by-marketplace/')) {
      calls.add('GET $path');
      return {
        'marketplace_assessment_id': fixture.mid,
        'm2_assessment_id': fixture.mid,
      };
    }
    if (path.endsWith('/confirmation-current')) {
      calls.add('GET $path');
      return {
        'id': confirmationId,
        'assessment_id': fixture.mid,
        'assessment_revision': revision,
      };
    }
    if (path.endsWith('/confirmed-review')) {
      calls.add('GET $path');
      return {
        'contract_version': 'project1-confirmed-review/1',
        'source_status': 'CURRENT_CONFIRMED_SOURCE',
        'trust_class': 'T2_AUTHENTICATED_ENTREPRENEUR_DECLARATION',
        'evaluation_state': 'NOT_EVALUATED',
        'activity_scope': 'M2_RECORDS_THROUGH_CONFIRMED_REVISION',
        'fielding_authorized': false,
        'qj_handoff_authorized': false,
        'report_release_authorized': false,
        'activity_truncated': false,
        'assessment_id': fixture.mid,
        'confirmation_id': confirmationId,
        'assessment_revision': revision,
        'snapshot_digest': 'a' * 64,
        'rule_version': 'NOT_EVALUATED',
        'answers': withIntention
            ? [
                {
                  'item_key': 'M2V1-09',
                  'question': 'Synthetic topic',
                  'answer_state': 'ANSWERED',
                  'value': ['CONCEPT_INTEREST'],
                  'source_answer_revision_id':
                      '00000000-0000-4000-8000-000000000010',
                  'source_item_version_id':
                      '00000000-0000-4000-8000-000000000011',
                },
                {
                  'item_key': 'M2V1-11',
                  'question': 'Synthetic status',
                  'answer_state': 'ANSWERED',
                  'value': 'UNSURE',
                  'source_answer_revision_id':
                      '00000000-0000-4000-8000-000000000012',
                  'source_item_version_id':
                      '00000000-0000-4000-8000-000000000013',
                },
              ]
            : <Object>[],
        'findings': <Object>[],
        'activity': <Object>[],
      };
    }
    if (path.endsWith('/research-workspace')) {
      calls.add('GET $path');
      return {
        'objectives': withObjective || savedObjective != null
            ? [
                {
                  'id': objectiveId,
                  'exact_text': savedObjective ?? 'SYNTHETIC research concern',
                  'provenance': {
                    'assessment_id': fixture.mid,
                    'confirmation_id': confirmationId,
                    'assessment_revision': revision,
                    'origin': 'ENTREPRENEUR',
                    if (savedObjective != null)
                      'objective_version': objectiveId,
                  },
                  if (savedObjective != null) ...{
                    'objective_version_id': objectiveId,
                    'owner_decision': 'CONFIRMED',
                    'approval_status': 'CONFIRMED_BY_OWNER',
                  },
                  if (withCandidate) 'version': 'SYNTHETIC-PREVIOUS-CANDIDATE',
                },
              ]
            : <Object>[],
      };
    }
    return super.get(path, query: query);
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    calls.add('POST $path');
    if (withVerifiedCandidate && path.endsWith('/owner-review')) {
      lastReviewBody = Map.of(body);
      decision = body['decision'] as String;
      return {'decision': decision};
    }
    if (path.endsWith('/research-objectives')) {
      expect(body['origin'], 'ENTREPRENEUR');
      savedObjective = body['objective'] as String;
      return {'id': objectiveId, 'confirmation_id': confirmationId};
    }
    throw StateError('Unexpected POST');
  }

  @override
  Future<Map<String, dynamic>> put(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (withVerifiedCandidate && path.endsWith('/desired-option')) {
      calls.add('PUT $path');
      prediction = body['option_code'] as String?;
      return {'question_version': candidateId, 'desired_option': prediction};
    }
    return super.put(path, body);
  }
}

void main() {
  late ApiM2Repository original;
  late ApiConfirmedReviewRepository originalReview;
  late GovernedClient client;
  setUp(() {
    original = AppLocator.m2;
    originalReview = AppLocator.confirmedReview;
    client = GovernedClient();
    AppLocator.m2 = ApiM2Repository(client);
    AppLocator.confirmedReview = ApiConfirmedReviewRepository(client);
  });
  tearDown(() {
    AppLocator.m2 = original;
    AppLocator.confirmedReview = originalReview;
  });

  testComponents(
    'Stage 3 does not run BDJ or approve an unverified objective',
    (tester) async {
      client.withObjective = true;
      tester.pumpComponent(
        const Project1ResearchStagePanel(
          marketplaceAssessmentId: fixture.mid,
          propertyId: 'SYNTHETIC',
          stageNumber: 3,
        ),
      );
      await tester.pump();
      expect(
        find.text('Business review and research goals'),
        findsOneComponent,
      );
      expect(find.text('Objective approval unavailable'), findsOneComponent);
      expect(find.text('AI Execution Status'), findsOneComponent);
      expect(
        find.text('Direct Question Generator (Direct-QG)'),
        findsOneComponent,
      );
      expect(
        find.text(
          'No candidate worksheet is recorded in this confirmed review.',
        ),
        findsOneComponent,
      );
      expect(find.text('Continue to Stage 4: Question review'), findsNothing);
      expect(client.calls.any((c) => c.contains('/bdj/evaluate')), isFalse);
      expect(client.calls.where((c) => !c.startsWith('GET ')), isEmpty);
      final readsBefore = client.calls.length;
      await tester.click(
        find.ancestor(
          of: find.text('Refresh AI status'),
          matching: find.tag('button'),
        ),
      );
      await tester.pump();
      expect(client.calls.length, greaterThan(readsBefore));
      expect(client.calls.where((c) => !c.startsWith('GET ')), isEmpty);
    },
  );

  testComponents('Stage 4 refuses an unapproved objective', (tester) async {
    client.withObjective = true;
    tester.pumpComponent(
      const Project1ResearchStagePanel(
        marketplaceAssessmentId: fixture.mid,
        propertyId: 'SYNTHETIC',
        stageNumber: 4,
      ),
    );
    await tester.pump();
    expect(find.text('No approved objective'), findsOneComponent);
    expect(find.text('AI Execution Status'), findsOneComponent);
    expect(
      find.text('Continue to Stage 5 (subject to release gates)'),
      findsNothing,
    );
    expect(client.calls.where((c) => !c.startsWith('GET ')), isEmpty);
  });

  testComponents('explicit entrepreneur objective saves then reloads', (
    tester,
  ) async {
    client.withIntention = true;
    tester.pumpComponent(
      const Project1ResearchStagePanel(
        marketplaceAssessmentId: fixture.mid,
        propertyId: 'SYNTHETIC',
        stageNumber: 3,
      ),
    );
    await tester.pump();
    expect(find.text('Your research intention'), findsOneComponent);
    expect(client.calls.where((c) => c.startsWith('POST ')), isEmpty);
    (find.byType(textarea).evaluate().single.component as textarea).onInput!(
      'SYNTHETIC purpose',
    );
    await tester.pump();
    await tester.click(
      find.ancestor(
        of: find.text('Confirm my research objective'),
        matching: find.tag('button'),
      ),
    );
    await tester.pump();
    expect(client.savedObjective, 'SYNTHETIC purpose');
    expect(find.text('SYNTHETIC purpose'), findsOneComponent);
    expect(
      find.text('Source: your confirmed M2 research intention.'),
      findsOneComponent,
    );
    expect(find.text('Objective approval unavailable'), findsNothing);
  });

  testComponents(
    'Stage 3 displays the matching synthetic current BDJ finding',
    (tester) async {
      client.withBdj = true;
      tester.pumpComponent(
        const Project1ResearchStagePanel(
          marketplaceAssessmentId: fixture.mid,
          propertyId: 'SYNTHETIC',
          stageNumber: 3,
        ),
      );
      await tester.pump();
      expect(find.text('Synthetic finding'), findsOneComponent);
      expect(find.text('M2 sources: M2V1-09'), findsOneComponent);
      expect(client.calls.where((c) => !c.startsWith('GET ')), isEmpty);
    },
  );

  testComponents(
    'Stage 4 holds stored candidates without verified provenance',
    (tester) async {
      client.withObjective = true;
      client.withCandidate = true;
      tester.pumpComponent(
        const Project1ResearchStagePanel(
          marketplaceAssessmentId: fixture.mid,
          propertyId: 'SYNTHETIC',
          stageNumber: 4,
        ),
      );
      await tester.pump();
      expect(find.text('Candidate provenance unavailable'), findsOneComponent);
      expect(
        find.text('Continue to Stage 5 (subject to release gates)'),
        findsNothing,
      );
      expect(client.calls.where((c) => !c.startsWith('GET ')), isEmpty);
    },
  );

  testComponents(
    'Stage 4 opens on the governed core and switches sets without re-reading',
    (tester) async {
      client.withObjective = true;
      tester.pumpComponent(
        const Project1ResearchStagePanel(
          marketplaceAssessmentId: fixture.mid,
          propertyId: 'SYNTHETIC',
          stageNumber: 4,
        ),
      );
      await tester.pump();

      // Both columns stay mounted, so text alone cannot tell the views apart —
      // the grid modifier is the state that actually decides what is on screen.
      Finder panelIn(String view) => find.byElementPredicate(
        (element) =>
            element is DomElement &&
            (element.component.classes ?? '')
                .split(' ')
                .contains('p1-s4two--$view'),
        description: 'the two-set panel in the $view view',
      );

      // Basic is the default: the governed core is what the owner can act on,
      // and the generated set is empty until an objective is approved.
      expect(panelIn('basic'), findsOneComponent);
      expect(panelIn('extra'), findsNothing);
      // There is no combined view left to return to.
      expect(find.text('Combined'), findsNothing);
      final reads = client.calls.length;

      await tester.click(
        find.ancestor(of: find.text('Extra'), matching: find.tag('button')),
      );
      await tester.pump();
      expect(panelIn('extra'), findsOneComponent);
      expect(panelIn('basic'), findsNothing);
      expect(find.text('Generated questions'), findsOneComponent);
      expect(find.text('Additional question candidates'), findsOneComponent);

      await tester.click(
        find.ancestor(of: find.text('Basic'), matching: find.tag('button')),
      );
      await tester.pump();
      expect(panelIn('basic'), findsOneComponent);
      expect(panelIn('extra'), findsNothing);

      // A view change is presentation only: the same mounted tree is re-laid
      // out, so nothing is fetched again and no recorded decision is lost.
      expect(client.calls.length, reads);
    },
  );

  testComponents(
    'Stage 4 renders source-bound synthetic candidate and choices',
    (tester) async {
      client.savedObjective = 'Synthetic objective';
      client.withVerifiedCandidate = true;
      tester.pumpComponent(
        const Project1ResearchStagePanel(
          marketplaceAssessmentId: fixture.mid,
          propertyId: 'SYNTHETIC',
          stageNumber: 4,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Synthetic candidate question?'), findsOneComponent);
      expect(find.text('Synthetic option A'), findsComponents);
      expect(find.text('Request revision'), findsOneComponent);
      expect(client.calls.where((call) => !call.startsWith('GET ')), isEmpty);
      await tester.click(
        find.ancestor(
          of: find.text('Request revision'),
          matching: find.tag('button'),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(client.decision, 'REQUEST_REVISION');
      expect(
        client.lastReviewBody?['rationale'],
        'No rationale provided by reviewer.',
      );
      expect(
        client.calls.any((call) => call.endsWith('/owner-review')),
        isTrue,
      );
      expect(find.text('Generate revised candidate'), findsOneComponent);
    },
  );
}
