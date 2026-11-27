import 'package:jaspr_test/jaspr_test.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart' show DomElement;
import 'package:shared_logic/shared_logic.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage4_preview_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage4_preview_questionnaire.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage_four_five_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/ai_execution_progress.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/project1_research_stage_panel.dart';
import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'm2_autosave_verification_test.dart' as fixture;

const confirmationId = '00000000-0000-4000-8000-000000000004';
const objectiveId = '00000000-0000-4000-8000-000000000005';
const contextId = '00000000-0000-4000-8000-000000000006';
const candidateId = '00000000-0000-4000-8000-000000000007';

/// Any element carrying [name] in its class list.
Finder withClass(String name) => find.byElementPredicate(
  (element) =>
      element is DomElement &&
      (element.component.classes ?? '').split(' ').contains(name),
  description: 'an element with class $name',
);

/// One fixed-core question card in Section A's catalogue.
final Finder coreRows = withClass('p1-corecard');

/// The supporting-metadata block a `Details` control reveals.
final Finder openCoreRows = withClass('p1-corecard__detail');

/// A closed `Details` control in the fixed-core list.
///
/// The button carries `aria-expanded`, so the closed one is addressable without
/// counting matches — which matters once more than one row is on screen.
Finder _closedDetails() => find.byElementPredicate(
  (element) =>
      element is DomElement &&
      element.component.attributes?['aria-expanded'] == 'false',
  description: 'a collapsed Details control',
);

/// One governed core question, as the preview transport would return it.
Map<String, dynamic> _question(String id, String responseType) => {
  'question_id': id,
  'stem_template': 'SYNTHETIC $id stem?',
  'populated_stem': 'SYNTHETIC $id stem, populated?',
  'response_type': responseType,
  'question_class': 'GOVERNED_CORE',
  'construct': 'GO1_AREA_AFFILIATION',
  'measurement_status': 'BLOCKED',
  'approval_state': 'NOT_APPROVED',
  'population_status': 'NO_SUBSTITUTION_REQUIRED',
  'codes': ['A', 'B'],
  'display_order': ['A', 'B'],
  'exclusive_codes': <Object>[],
  'max_selections': null,
  'unresolved_slots': <Object>[],
};

/// Synthetic Section A transport; never reaches the network.
final class _PreviewPort implements Stage4PreviewPort {
  _PreviewPort(this.questions);

  final List<Map<String, dynamic>> questions;

  @override
  Future<ApiResult<PreviewQuestionnaire>> read({
    required String assessmentId,
    required int expectedRevision,
    required String confirmationId,
  }) async => ApiResult<PreviewQuestionnaire>.success(
    PreviewQuestionnaire.fromJson({
      'catalogue_version': 'CQ-SYNTHETIC-1',
      'authority': 'SYNTHETIC',
      'question_count': questions.length,
      'approved_question_count': 0,
      'unresolved_required_slot_count': 0,
      'population_status': 'COMPLETE',
      'populated_digest': 'synthetic',
      'fielding_authorized': false,
      'questions': questions,
    }),
  );
}

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

/// A status transport that records how many times the ledger was read.
///
/// The rail's recovery action is a *read*, so the only way to prove it happened
/// is to count reads on the transport that actually serves them. The page's
/// other reads go through separate ports, so counting those would pass even if
/// no status request had been made at all.
class _RecordingStatusPort implements StageFourFivePort {
  int reads = 0;

  @override
  Future<ApiResult<AiExecutionReading>> executionStatus({
    required String assessmentId,
  }) async {
    reads += 1;
    // Fail, so the card renders the state that offers a recovery action.
    return const ApiResult<AiExecutionReading>.error(
      AssessmentFailure(message: 'SYNTHETIC status read failed'),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('The rail only reads the execution status.');
}

/// A proposal read that succeeds and returns nothing approved.
///
/// This is the seam the panel's own `proposalApi` parameter exists for: the
/// concrete client reaches the network through the `WebAuth` bridge, which only
/// resolves in a web build, so without a substituted port a component test can
/// only ever observe a *failed* read. A failed read and an empty read are the
/// two states DD-047 exists to keep apart.
class _EmptyProposalPort implements BdjObjectiveProposalPort {
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
        proposalCount: 0,
        proposals: const [],
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Stage 4 must not write through the proposal port.');
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
      final status = _RecordingStatusPort();
      tester.pumpComponent(
        Project1ResearchStagePanel(
          marketplaceAssessmentId: fixture.mid,
          propertyId: 'SYNTHETIC',
          stageNumber: 3,
          stageFourFive: status,
        ),
      );
      await tester.pump();
      expect(
        find.text('Business review and research goals'),
        findsOneComponent,
      );
      expect(find.text('Objective approval unavailable'), findsOneComponent);
      // Stage 3 carries the BDJ card and only the BDJ card. The old surface
      // mounted one card that named both generators, which is what let the same
      // page show two execution states at once (D-H01).
      expect(find.text('Business review status'), findsOneComponent);
      expect(find.text('Question generation status'), findsNothing);
      // Exactly one execution card, and it lives in the panel's rail.
      //
      // Text assertions cannot see this: the page used to render its own
      // `section.p1-rail` *beside* the panel's `aside.s3o-rail`, so the page
      // had three columns and two rails while every label still appeared once.
      // Counting the card and requiring it to sit inside the aside is what
      // distinguishes "one rail" from "one rail plus a second empty column".
      expect(find.byType(AiExecutionProgressPanel), findsOneComponent);
      expect(find.tag('aside'), findsOneComponent);
      expect(
        find.ancestor(
          of: find.text('Business review status'),
          matching: find.tag('aside'),
        ),
        findsOneComponent,
      );
      expect(
        find.text('Direct Question Generator (Direct-QG)'),
        findsNothing,
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
      final readsBefore = status.reads;
      expect(readsBefore, greaterThan(0)); // the rail read the ledger once
      // The fixture's status read fails, so the card says so and offers one
      // recovery action. Clicking it is a read: it must not write anything and
      // must not dispatch a model.
      expect(
        find.textContaining('Execution status is unavailable'),
        findsOneComponent,
      );
      await tester.click(
        find.ancestor(
          of: find.text('Check again'),
          matching: find.tag('button'),
        ),
      );
      await tester.pump();
      expect(status.reads, greaterThan(readsBefore));
      expect(client.calls.where((c) => !c.startsWith('GET ')), isEmpty);
    },
  );

  testComponents('Stage 4 refuses an unapproved objective', (tester) async {
    client.withObjective = true;
    // The objective read only happens once a current business context resolves.
    // Without this the panel cannot tell "nothing is approved" from "the read
    // failed" and correctly renders DD-047's "could not be read" instead, which
    // is a different state from the one this case is about.
    client.withVerifiedCandidate = true;
    final proposals = _EmptyProposalPort();
    tester.pumpComponent(
      Project1ResearchStagePanel(
        marketplaceAssessmentId: fixture.mid,
        propertyId: 'SYNTHETIC',
        stageNumber: 4,
        proposalApi: proposals,
      ),
    );
    await tester.pump();
    // The read has to have happened: "nothing is approved" is only a statement
    // the panel may make after a read that succeeded.
    expect(proposals.listCalls, isNotEmpty);
    expect(find.text('No approved objective'), findsOneComponent);
    // Stage 4 carries the Direct-QG card and only that one.
    expect(find.text('Question generation status'), findsOneComponent);
    expect(find.text('Business review status'), findsNothing);
    // Stage 4 owns its rail, so the card is in the page's `section.p1-rail`
    // beside the main column — not folded into the panel rail the way Stage 3
    // does it, and never twice.
    expect(find.byType(AiExecutionProgressPanel), findsOneComponent);
    expect(
      find.ancestor(
        of: find.text('Question generation status'),
        matching: find.tag('aside'),
      ),
      findsNothing,
    );
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
    'Stage 3 states the current BDJ source evaluation once, in the panel',
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
      // The rail's status read is asynchronous. Pump until it leaves the
      // "reading" state, so nothing below is asserted against a skeleton.
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }

      // The standalone card is gone. Four of its five rows restated facts that
      // were already on this screen (the source evaluation and the revision in
      // the rail's context block, the assessment id and revision in the
      // panel's own context disclosure, and "M2 confirmation: Current" only
      // repeating a check the read path enforces).
      expect(find.text('Recorded BDJ status'), findsNothing);

      // Its fifth row printed the review's `NOT_EVALUATED` sentinel as the
      // name of a ruleset. That literal must not appear at all.
      expect(find.text('NOT_EVALUATED'), findsNothing);

      // The fact itself is not lost: it is a labelled source fact inside the
      // execution panel's disclosure, next to — but distinguishable from — the
      // objective-generation attempt.
      expect(find.text('BDJ source evaluation'), findsOneComponent);
      expect(
        find.text('Completed with findings (COMPLETED_WITH_FINDINGS)'),
        findsOneComponent,
      );
      // One home only: the rail's context block no longer repeats it.
      expect(find.textContaining('Source evaluation:'), findsNothing);
      expect(find.textContaining('Confirmed M2 revision'), findsNothing);

      expect(client.calls.where((c) => !c.startsWith('GET ')), isEmpty);
    },
  );

  testComponents(
    'the BDJ source evaluation survives a failed ledger read',
    (tester) async {
      // The source evaluation is read from `/bdj/current`; the execution rail
      // is read from `/ai-execution-status`. The fake client answers the first
      // and not the second, so this is exactly the case where one read fails
      // and the other succeeds. The source fact must not disappear with the
      // failed read.
      client.withBdj = true;
      tester.pumpComponent(
        const Project1ResearchStagePanel(
          marketplaceAssessmentId: fixture.mid,
          propertyId: 'SYNTHETIC',
          stageNumber: 3,
        ),
      );
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }

      expect(
        find.textContaining('Execution status is unavailable'),
        findsOneComponent,
      );
      expect(find.text('BDJ source evaluation'), findsOneComponent);
    },
  );

  testComponents(
    'Stage 4 does not report the BDJ source evaluation',
    (tester) async {
      // `current_bdj` is in the Stage 4 payload as well, but Stage 4 does not
      // read a BDJ source evaluation. Putting that row on the question
      // generation rail would describe another stage's store.
      client.withBdj = true;
      tester.pumpComponent(
        const Project1ResearchStagePanel(
          marketplaceAssessmentId: fixture.mid,
          propertyId: 'SYNTHETIC',
          stageNumber: 4,
        ),
      );
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }

      expect(find.text('BDJ source evaluation'), findsNothing);
      expect(find.textContaining('Source evaluation:'), findsNothing);
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
    'Stage 4 stacks both question sets and offers no tab switch',
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

      // Both sets are on screen at once. Under the tab strip only one was
      // visible while both stayed mounted, so finding the labels proved
      // nothing; what proves the change is that no view modifier exists that
      // could hide either set.
      expect(find.text('Fixed core questionnaire'), findsOneComponent);
      expect(
        find.text('Generated questions by research objective'),
        findsOneComponent,
      );

      // Section B is one body. It used to be a card whose head was
      // "Additional question candidates" plus a second, independently mounted
      // review surface above it, which printed each objective's wording again
      // and listed its questions a second time. The heading that duplicated
      // the section title is gone with it.
      expect(find.text('Additional question candidates'), findsNothing);
      expect(withClass('p1-s4bcard'), findsOneComponent);
      expect(withClass('p1-filterbar--flat'), findsOneComponent);

      // The separate surface is not mounted: its cards and its per-candidate
      // objective reference were the duplicates. Counted by component, because
      // every string they printed still appears elsewhere on the page.
      expect(withClass('s4-card'), findsNothing);
      expect(withClass('s4-objref'), findsNothing);
      expect(withClass('s4-q'), findsNothing);

      expect(withClass('p1-s4stack'), findsOneComponent);
      expect(withClass('p1-s4tabs'), findsNothing);
      expect(withClass('p1-s4tab'), findsNothing);
      expect(find.text('Basic'), findsNothing);
      expect(find.text('Extra'), findsNothing);

      // The rail's fixed-objective row is derived from the governed registry,
      // and it names the ids as well as counting them. A bare digit cannot be
      // told apart from a wrong count at the size this row renders at, which is
      // how a wrong number survived review once already.
      expect(find.text('6 (O1–O6)'), findsOneComponent);
    },
  );

  testComponents(
    'Stage 4 fixed core cards fold their detail behind a disclosure that '
    'survives a rebuild',
    (tester) async {
      client.withObjective = true;
      tester.pumpComponent(
        Project1ResearchStagePanel(
          marketplaceAssessmentId: fixture.mid,
          propertyId: 'SYNTHETIC',
          stageNumber: 4,
          previewApi: _PreviewPort([
            _question('Q01', 'multi_select_with_exclusive_terminals'),
            _question('Q02', 'ordinal_single'),
          ]),
        ),
      );
      await tester.pump();
      await tester.pump();

      // One catalogue card per question, and the supporting-metadata block
      // starts absent — it is what the `Details` control adds.
      expect(coreRows, findsNComponents(2));
      expect(openCoreRows, findsNothing);

      // Two cards give two buttons whose visible text is "Details", so each
      // names the question it opens rather than repeating one label.
      expect(
        find.byElementPredicate(
          (element) =>
              element is DomElement &&
              element.component.attributes?['aria-label'] == 'Details for Q01',
          description: 'the Q01 disclosure',
        ),
        findsOneComponent,
      );

      // Open the first card.
      await tester.click(_closedDetails().first);
      await tester.pump();
      expect(openCoreRows, findsOneComponent);
      expect(find.text('Hide details'), findsOneComponent);

      // Opening the second card rebuilds this panel. The open state is owned
      // in State, so the card the reader opened first must still be open — a
      // `<details>` element would have lost it on the rebuild.
      await tester.click(_closedDetails().first);
      await tester.pump();
      expect(openCoreRows, findsNComponents(2));
    },
  );

  testComponents(
    'Stage 4 fixed core has no filter bar and lists the catalogue in order',
    (tester) async {
      client.withObjective = true;
      tester.pumpComponent(
        Project1ResearchStagePanel(
          marketplaceAssessmentId: fixture.mid,
          propertyId: 'SYNTHETIC',
          stageNumber: 4,
          previewApi: _PreviewPort([
            _question('Q01', 'multi_select_with_exclusive_terminals'),
            _question('Q02', 'ordinal_single'),
          ]),
        ),
      );
      await tester.pump();
      await tester.pump();

      // No filter control at all: the fixed core is one instrument with one
      // order, and a filter over a read-only list invited the reader to narrow
      // an instrument they cannot change.
      expect(withClass('p1-corefilter'), findsNothing);
      expect(withClass('p1-fchip'), findsNothing);
      expect(find.textContaining('of 2 shown'), findsNothing);
      expect(find.text('Format'), findsNothing);
      expect(find.text('Class'), findsNothing);

      // Every question is listed, in the order the server returned them.
      expect(coreRows, findsNComponents(2));
      expect(find.text('Q01'), findsOneComponent);
      expect(find.text('Q02'), findsOneComponent);

      // Nothing names a research objective: the governed core is not mapped to
      // O1–O6 by any contract this page reads.
      for (final id in ['O1', 'O2', 'O3', 'O4', 'O5', 'O6']) {
        expect(find.text(id), findsNothing);
      }
    },
  );

  testComponents(
    'Section A says the fixed core cannot be answered and renders no control',
    (tester) async {
      client.withObjective = true;
      tester.pumpComponent(
        Project1ResearchStagePanel(
          marketplaceAssessmentId: fixture.mid,
          propertyId: 'SYNTHETIC',
          stageNumber: 4,
          previewApi: _PreviewPort([
            _question('Q01', 'multi_select_with_exclusive_terminals'),
            _question('Q02', 'ordinal_single'),
          ]),
        ),
      );
      await tester.pump();
      await tester.pump();

      // The reading note stands where the reference put its instruction, and
      // says the opposite of it: the reference's "select the option(s) you
      // would choose" invited an answer CP-S4-02 forbids.
      expect(find.text('How to read this section'), findsOneComponent);
      expect(
        find.textContaining('nothing on this screen can be answered'),
        findsOneComponent,
      );
      expect(
        find.textContaining('Select the option(s) you would choose'),
        findsNothing,
      );

      // Every option is text. A checkbox or radio inside a fixed-core card
      // would promise a click the contract does not allow, so the absence of
      // any control is asserted rather than assumed.
      expect(withClass('p1-corecard__opt'), findsNComponents(4));
      // `descendant` reaches inside a card — the negative below is a fact about
      // the card's contents, not about the finder finding nothing at all.
      expect(
        find.descendant(
          of: withClass('p1-corecard'),
          matching: find.textContaining('SYNTHETIC Q01 stem'),
        ),
        findsOneComponent,
      );
      expect(
        find.descendant(
          of: withClass('p1-corecard'),
          matching: find.byElementPredicate(
            (element) => element is DomElement && element.component is input,
            description: 'an input control',
          ),
        ),
        findsNothing,
      );

      // The format line is derived from the contract's own `response_type`, so
      // two questions of different formats must not carry the same label.
      expect(
        find.text('Multiple choice (select all that apply)'),
        findsOneComponent,
      );
      expect(find.text('Single choice (select one)'), findsOneComponent);
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

  testComponents(
    'Section B lists a generated question under its own objective',
    (tester) async {
      // The objective is approved, so it owns a card, and the question was
      // generated for it. Both the wording and the question must appear once:
      // a second, independently mounted surface used to print the objective
      // again above a flat list of the same questions.
      client.savedObjective = 'SYNTHETIC research concern';
      final qg = _FakeQgPort([_qg()]);
      tester.pumpComponent(
        Project1ResearchStagePanel(
          marketplaceAssessmentId: fixture.mid,
          propertyId: 'SYNTHETIC',
          stageNumber: 4,
          stageFourFive: qg,
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // One objective, one card, and the question inside it.
      expect(find.text('SYNTHETIC research concern'), findsOneComponent);
      expect(find.text('SYNTHETIC generated question?'), findsOneComponent);
      expect(withClass('p1-qcard--qg'), findsOneComponent);
      // The count is the number of cards under the card, not a separate list.
      expect(find.text('1 question'), findsOneComponent);

      // The duplicate surface is gone: its cards and its per-candidate
      // objective reference were what printed the same objective twice.
      expect(withClass('s4-card'), findsNothing);
      expect(withClass('s4-objref'), findsNothing);

      // Reading the questions is not generating them.
      expect(qg.reviewCalls, isEmpty);
      expect(qg.expectedAnswerCalls, isEmpty);
    },
  );

  testComponents(
    'a multiple-choice intention is a set, and a single answer is not',
    (tester) async {
      client.savedObjective = 'SYNTHETIC research concern';
      final multi = _FakeQgPort([_qg(responseFormat: 'MULTIPLE_CHOICE')]);
      tester.pumpComponent(
        Project1ResearchStagePanel(
          marketplaceAssessmentId: fixture.mid,
          propertyId: 'SYNTHETIC',
          stageNumber: 4,
          stageFourFive: multi,
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // A question that accepts several answers gets a control per option that
      // can hold several; one that accepts a single answer gets a single-choice
      // control. The format decides, because the format is what the server
      // stored and what a respondent would be shown.
      expect(withClass('p1-optrow--multi'), findsNComponents(2));
      expect(withClass('p1-optrow--single'), findsNothing);

      await tester.click(
        find.byElementPredicate(
          (element) =>
              element is DomElement &&
              element.component.attributes?['data-option'] == 'A',
          description: 'the option A control',
        ),
      );
      await tester.pump();
      await tester.pump();

      // Sent as the set the route stores. The singular spelling would have
      // stored one code and lost the rest.
      expect(multi.expectedAnswerCalls.single, 'qg-1|A|${client.revision}');
      expect(multi.reviewCalls, isEmpty);
    },
  );
}

/// A generated question, as the QG read returns it.
QgCandidate _qg({
  String candidateId = 'qg-1',
  String responseFormat = 'SINGLE_CHOICE',
  String question = 'SYNTHETIC generated question?',
  CandidateReview review = const CandidateReview(),
}) => QgCandidate(
  candidateId: candidateId,
  assessmentId: fixture.mid,
  objectiveId: objectiveId,
  objectiveClassification: 'ADDITIONAL_ASSESSMENT_OBJECTIVE',
  question: question,
  responseFormat: responseFormat,
  options: const [
    CandidateOption(
      code: 'A',
      label: 'Synthetic option A',
      order: 0,
      orderSource: 'MEASUREMENT',
    ),
    CandidateOption(
      code: 'B',
      label: 'Synthetic option B',
      order: 1,
      orderSource: 'MEASUREMENT',
    ),
  ],
  routing: const {},
  review: review,
  candidateState: 'VALIDATED',
  executionMode: 'SIMULATED',
  modelProvider: 'simulated-qg-v1',
  dispatched: false,
  fieldingAuthorized: false,
  scientificallyAccepted: false,
);

/// The generated-question read, with only the members Stage 4 calls answered.
///
/// Everything else forwards to [noSuchMethod] and throws: a test that starts
/// calling a route this fake does not model should fail loudly rather than
/// receive an invented empty answer.
class _FakeQgPort implements StageFourFivePort {
  _FakeQgPort(this.candidatesValue);

  List<QgCandidate> candidatesValue;
  final expectedAnswerCalls = <String>[];
  final reviewCalls = <String>[];

  @override
  Future<ApiResult<List<QgCandidate>>> candidates({
    required String assessmentId,
  }) async => ApiResult.success(candidatesValue);

  @override
  Future<ApiResult<String?>> setExpectedAnswer({
    required String assessmentId,
    required String candidateId,
    String? optionCode,
    List<String>? optionCodes,
    int? expectedRevision,
  }) async {
    // The set is what the control sends, so a truncated multi-select intention
    // is visible here rather than hidden behind a single code.
    expectedAnswerCalls.add(
      '$candidateId|${optionCodes?.join(',') ?? optionCode}|$expectedRevision',
    );
    return ApiResult.success(optionCodes?.join(',') ?? optionCode);
  }

  @override
  Future<ApiResult<CandidateReviewReceipt>> reviewCandidate({
    required String assessmentId,
    required String candidateId,
    required String decision,
    required String rationale,
    int? expectedRevision,
  }) async {
    reviewCalls.add('$candidateId|$decision');
    return ApiResult.success(
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
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'The Stage 4 panel reached an unmodelled route: ${invocation.memberName}',
  );
}
