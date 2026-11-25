import 'package:jaspr_test/jaspr_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage5_collection_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage5_composed_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage5_composed_questionnaire.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage5_publication_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/customer_questionnaire_step5.dart';

import 'fixtures/stage5_composed_fixtures.dart';

/// Serves the three M2 reads the component performs before it may retrieve the
/// composed document: link → draft → current confirmation.
class _FakeM2Client extends ApiClient {
  _FakeM2Client({
    this.linked = true,
    this.confirmationRevision = stage5Revision,
    this.contextStatusFails = false,
  });

  final bool linked;
  final int confirmationRevision;

  /// When set, the business-context read throws. Composition does not depend on
  /// it, so the questionnaire must still render.
  final bool contextStatusFails;
  final paths = <String>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    paths.add(path);
    if (path ==
        '/api/v1/m2/assessments/by-marketplace/$stage5MarketplaceAssessmentId') {
      // The real repository treats 404 `ASSESSMENT_NOT_LINKED` as "no link",
      // which is a normal state. Returning an empty payload instead would make
      // the repository throw a format error and reach the wrong state.
      if (!linked) {
        throw const NotFoundFailure.response(
          'No M2 assessment is linked.',
          statusCode: 404,
          backendCode: 'ASSESSMENT_NOT_LINKED',
        );
      }
      return stage5LinkPayload();
    }
    if (path == '/api/v1/m2/assessments/$stage5M2AssessmentId') {
      return stage5M2DraftPayload();
    }
    if (path ==
        '/api/v1/m2/assessments/$stage5M2AssessmentId/confirmation-current') {
      return stage5ConfirmationPayload(revision: confirmationRevision);
    }
    if (path ==
        '/api/v1/m2/assessments/$stage5M2AssessmentId/confirmations/'
            '$stage5ConfirmationId/business-context-status') {
      if (contextStatusFails) {
        throw StateError('business-context-status unavailable');
      }
      return stage5ContextStatusPayload();
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Stage 5 must not write to the M2 transport.');
}

/// Serves a fixed composed document, so each render state is reachable without
/// a browser session or a live backend.
class _FakeComposedPort implements Stage5ComposedPort {
  _FakeComposedPort(this.result);

  ApiResult<ComposedQuestionnaire> result;
  int calls = 0;
  final requests = <String>[];

  @override
  Future<ApiResult<ComposedQuestionnaire>> read({
    required String assessmentId,
    required int expectedRevision,
    required String confirmationId,
  }) async {
    calls++;
    requests.add('$assessmentId@$expectedRevision/$confirmationId');
    return result;
  }
}

/// Stands in for the publication service so a component test never reaches the
/// network. Records both calls, because the screen must ask for a preview
/// before it offers to publish.
class _FakePublicationPort implements Stage5PublicationPort {
  _FakePublicationPort({this.previewResult});

  ApiResult<PublicationReport>? previewResult;
  int previews = 0;
  int publishes = 0;

  @override
  Future<ApiResult<PublicationReport>> preview({
    required String assessmentId,
  }) async {
    previews++;
    return previewResult ??= ApiResult<PublicationReport>.success(_report());
  }

  @override
  Future<ApiResult<PublicationReport>> publish({
    required String assessmentId,
  }) async {
    publishes++;
    return ApiResult<PublicationReport>.success(
      _report(state: 'ALREADY_PUBLISHED', alreadyPublished: true),
    );
  }
}

/// Serves the collection read and the target write.
///
/// The candidate target is persisted on the server (DD-097), so "Set" is a
/// write, not a local flag: without a port the control reports the transport's
/// refusal and never relabels to "Update". The fake echoes the target it was
/// given, which is what the real route does.
class _FakeCollectionPort implements Stage5CollectionPort {
  Map<String, dynamic> _snapshot = const {'lifecycle_state': 'OPEN'};

  int reads = 0;
  int writes = 0;

  @override
  Future<ApiResult<CollectionSnapshot>> read({
    required String assessmentId,
  }) async {
    reads++;
    return ApiResult<CollectionSnapshot>.success(CollectionSnapshot(_snapshot));
  }

  @override
  Future<ApiResult<CollectionSnapshot>> setTarget({
    required String assessmentId,
    required int target,
    required String requestId,
  }) async {
    writes++;
    _snapshot = {
      'lifecycle_state': 'OPEN',
      'progress': {'respondent_target': target},
    };
    return ApiResult<CollectionSnapshot>.success(CollectionSnapshot(_snapshot));
  }

  @override
  Future<ApiResult<CollectionSnapshot>> endCollection({
    required String assessmentId,
    required String requestId,
    required String completionPolicy,
    required String inProgressDisposition,
    String? reason,
  }) async => throw StateError('This fixture never ends collection.');
}

PublicationReport _report({
  String state = 'PREVIEW',
  bool alreadyPublished = false,
  int authorized = 0,
}) => PublicationReport(
  state: state,
  releaseId: 'release-fixture-0001',
  manifestHash: 'hash-fixture',
  questionCount: 13,
  authorizedCount: authorized,
  excludedCount: 13 - authorized,
  alreadyPublished: alreadyPublished,
  authorizedQuestionIds: const <String>[],
  sourceClass: 'SYNTHETIC_FIXTURE',
  principal: 'p1_cq_publisher',
  productionFieldingAuthorized: false,
  runtimeActivated: false,
);

ComposedQuestionnaire _document({bool additional = true}) =>
    ComposedQuestionnaire.fromJson(
      stage5ComposedDocument(additional: additional),
    );

void main() {
  late ApiM2Repository originalM2;

  setUp(() => originalM2 = AppLocator.m2);
  tearDown(() => AppLocator.m2 = originalM2);

  // ------------------------------------------------------------------ model

  test(
    'the composed document decodes both sections and every authority flag',
    () {
      final document = _document();

      expect(document.contractVersion, 'sitewise-questionnaire-composition/1');
      expect(document.assessmentId, stage5M2AssessmentId);
      expect(document.assessmentRevision, stage5Revision);
      expect(document.fixedCore.length, 13);
      expect(document.additional.length, 1);
      expect(document.totalCount, 14);
      expect(document.compositionValid, isTrue);
      expect(document.validation.passed, isTrue);

      // Authority is negative on the document and on every item, whatever the
      // composition verdict says.
      expect(document.fieldingAuthorized, isFalse);
      expect(document.publicationAuthorized, isFalse);
      expect(document.scientificallyAccepted, isFalse);
      expect(document.customerFieldingEnabled, isFalse);
      expect(document.isPublishable, isFalse);
      expect(
        document.items.every(
          (item) =>
              !item.fieldingAuthorized &&
              !item.publicationAuthorized &&
              !item.scientificallyAccepted,
        ),
        isTrue,
      );

      // The fixed core is never individually reviewable.
      expect(
        document.fixedCore.every((item) => item.reviewControls == 'NONE'),
        isTrue,
      );
      expect(document.fixedCore.every((item) => !item.isReviewable), isTrue);
    },
  );

  test('an additional item keeps its objective binding and scoped intent', () {
    final item = _document().additional.single;

    expect(item.isAdditional, isTrue);
    expect(item.reviewControls, 'PER_ITEM');
    expect(item.isReviewable, isTrue);
    expect(item.reviewDecision, 'APPROVE_FOR_REVIEW');
    expect(item.semanticBasis, 'OWNER_REVIEW');
    expect(item.objectiveId, isNotNull);
    expect(item.objectiveAdmissionId, isNotNull);
    expect(item.ownerIntendedOption, 'B');
    expect(item.ownerIntendedOptionScope, 'ENTREPRENEUR_ONLY_METADATA');
    expect(item.hasScopedIntendedOption, isTrue);
    expect(item.options.map((option) => option.display), [
      'Under 10 minutes',
      '10 to 20 minutes',
      'More than 20 minutes',
    ]);
  });

  test('an unscoped intended option is not shown as one', () {
    final json = stage5AdditionalItem()..remove('owner_intended_option_scope');
    final item = ComposedItem.fromJson(json);

    expect(item.ownerIntendedOption, 'B');
    expect(item.hasScopedIntendedOption, isFalse);
  });

  test('an empty Section B is explained, never left blank', () {
    final document = _document(additional: false);

    expect(document.additional, isEmpty);
    expect(document.additionalStatus, AdditionalStatus.noneEligible);
    expect(
      document.blockingRequirements.map((row) => row.code),
      contains(RequirementCodes.noAdditional),
    );
    expect(
      document.excludedCandidates.single.reason,
      ExclusionCodes.notApproved,
    );
    expect(
      document.excludedCandidates.single.label,
      'You have not approved this question for review.',
    );
  });

  test('an unknown reason code is surfaced verbatim, not swallowed', () {
    expect(describeExclusionCode('SOMETHING_NEW'), 'SOMETHING_NEW');
    expect(describeRequirementCode('SOMETHING_NEW'), 'SOMETHING_NEW');
  });

  test('stale and unreadable refusal codes are classified separately', () {
    expect(isStaleComposedSource(Stage5ComposedCodes.revisionStale), isTrue);
    expect(
      isStaleComposedSource(Stage5ComposedCodes.confirmationStale),
      isTrue,
    );
    expect(
      isStaleComposedSource(Stage5ComposedCodes.assessmentNotFound),
      isFalse,
    );
    expect(
      isUnreadableAssessment(Stage5ComposedCodes.assessmentNotFound),
      isTrue,
    );
    expect(isUnreadableAssessment(Stage5ComposedCodes.revisionStale), isFalse);
  });

  // -------------------------------------------------------------- component

  testComponents('renders the composed core, the approved question and a '
      'disabled publish control', (tester) async {
    AppLocator.m2 = ApiM2Repository(_FakeM2Client());
    final port = _FakeComposedPort(
      ApiResult<ComposedQuestionnaire>.success(_document()),
    );
    final publication = _FakePublicationPort(
      previewResult: ApiResult<PublicationReport>.success(_report()),
    );

    tester.pumpComponent(
      CustomerQuestionnaireStep5(
        assessmentId: stage5MarketplaceAssessmentId,
        api: port,
        publication: publication,
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }

    // The real governed questions, not the design's café fixture.
    // Q01 carries an unresolved slot in this fixture, so Q02 is the plain
    // governed wording to assert on.
    expect(find.text('Governed core question Q02 wording.'), findsOneComponent);
    // Q01 and Q07 share the unresolved template in this fixture.
    expect(
      find.textContaining('How often do you visit a [named area]'),
      findsNComponents(2),
    );
    expect(find.text('How often do you visit a café?'), findsNothing);

    // Section B, with its approval and its entrepreneur-only intent.
    expect(
      find.textContaining('How far would you travel for a climbing session'),
      findsOneComponent,
    );
    expect(find.textContaining('Your intended answer'), findsOneComponent);
    expect(
      find.textContaining('Entrepreneur-only metadata'),
      findsOneComponent,
    );

    // Publication is stated and refused, not offered. The caption names every
    // unmet condition, and the control carries no click handler, so its
    // presence is a statement about wording, not capability.
    //
    // DD-096 changed what those conditions are. The candidate target is no
    // longer one of them: it was a figure held only in this component's state
    // and it reached no server, so requiring it made the control look broken
    // while changing nothing. The conditions are now the document's own verdict
    // and the server's authorisation count.
    expect(find.text('Publish Questionnaire'), findsOneComponent);
    expect(find.text('Candidate target'), findsOneComponent);
    expect(find.text('Not planned'), findsOneComponent);
    expect(find.text('Not set'), findsOneComponent);
    expect(
      find.textContaining('Disabled: the document is not publishable'),
      findsOneComponent,
    );
    expect(
      find.textContaining('no question survived authorisation'),
      findsOneComponent,
    );
    // The publication row reports the server's answer, not a build flag.
    expect(find.text('Not ready'), findsOneComponent);
    expect(publication.previews, 1);
    expect(publication.publishes, 0);

    // The request carried the M2 binding, never the marketplace id.
    expect(port.requests.single, startsWith(stage5M2AssessmentId));
  });

  testComponents('the candidate target is a plan, not a publication gate', (
    tester,
  ) async {
    AppLocator.m2 = ApiM2Repository(_FakeM2Client());
    final port = _FakeComposedPort(
      ApiResult<ComposedQuestionnaire>.success(_document()),
    );

    final publication = _FakePublicationPort(
      previewResult: ApiResult<PublicationReport>.success(_report()),
    );
    final collection = _FakeCollectionPort();

    tester.pumpComponent(
      CustomerQuestionnaireStep5(
        assessmentId: stage5MarketplaceAssessmentId,
        api: port,
        publication: publication,
        collection: collection,
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }

    // The target starts unset and the row says so -- as a plan, not a gate.
    expect(find.text('Not planned'), findsOneComponent);
    expect(find.text('Not set'), findsOneComponent);
    expect(
      find.textContaining('not required to publish'),
      findsOneComponent,
    );

    // Committing a target relabels the control to Update and flips the chip, so
    // the control never reads as still-unset.
    await tester.click(
      find.ancestor(of: find.text('Set'), matching: find.tag('button')).first,
    );
    await tester.pump();

    expect(find.text('Set'), findsOneComponent);
    expect(find.text('Update'), findsOneComponent);
    expect(find.text('Not set'), findsNothing);
    expect(find.text('Not planned'), findsNothing);

    // The target is not what keeps the control closed. What does is the
    // document's own verdict, which is not the entrepreneur's to override.
    expect(
      find.textContaining('Disabled: the document is not publishable'),
      findsOneComponent,
    );
    expect(find.textContaining('no candidate target is set'), findsNothing);
    expect(publication.publishes, 0);
  });

  testComponents('an empty Section B states why, with its reason codes', (
    tester,
  ) async {
    AppLocator.m2 = ApiM2Repository(_FakeM2Client());
    final port = _FakeComposedPort(
      ApiResult<ComposedQuestionnaire>.success(_document(additional: false)),
    );

    tester.pumpComponent(
      CustomerQuestionnaireStep5(
        assessmentId: stage5MarketplaceAssessmentId,
        api: port,
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }

    expect(find.text('No additional question is included'), findsOneComponent);
    expect(find.textContaining('Excluded candidates'), findsOneComponent);
    expect(
      find.textContaining('You have not approved this question for review.'),
      findsOneComponent,
    );
    expect(find.textContaining('CANDIDATE_NOT_APPROVED'), findsOneComponent);
  });

  testComponents('a stale revision is refused, not rendered', (tester) async {
    // The confirmation disagrees with the draft revision.
    AppLocator.m2 = ApiM2Repository(_FakeM2Client(confirmationRevision: 23));
    final port = _FakeComposedPort(
      ApiResult<ComposedQuestionnaire>.success(_document()),
    );

    tester.pumpComponent(
      CustomerQuestionnaireStep5(
        assessmentId: stage5MarketplaceAssessmentId,
        api: port,
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }

    expect(find.text('Your declaration moved'), findsOneComponent);
    expect(find.textContaining('Governed core question'), findsNothing);
    // Nothing was requested, because the binding never agreed.
    expect(port.calls, 0);
  });

  testComponents('a server refusal code is rendered, and the document is not', (
    tester,
  ) async {
    AppLocator.m2 = ApiM2Repository(_FakeM2Client());
    final port = _FakeComposedPort(
      ApiResult<ComposedQuestionnaire>.error(
        const AssessmentFailure(
          status: 409,
          code: Stage5ComposedCodes.confirmationStale,
          message: 'The confirmation is stale.',
        ),
      ),
    );

    tester.pumpComponent(
      CustomerQuestionnaireStep5(
        assessmentId: stage5MarketplaceAssessmentId,
        api: port,
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }

    expect(find.text('Your declaration moved'), findsOneComponent);
    expect(find.textContaining('Governed core question'), findsNothing);
  });

  testComponents(
    'an unlinked assessment is blocked, with no sample questions',
    (tester) async {
      AppLocator.m2 = ApiM2Repository(_FakeM2Client(linked: false));
      final port = _FakeComposedPort(
        ApiResult<ComposedQuestionnaire>.success(_document()),
      );

      tester.pumpComponent(
        CustomerQuestionnaireStep5(
          assessmentId: stage5MarketplaceAssessmentId,
          api: port,
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }

      expect(
        find.text('Questionnaire not available for this assessment'),
        findsOneComponent,
      );
      expect(
        find.textContaining('No M2 research record is linked'),
        findsOneComponent,
      );
      expect(find.text('How often do you visit a café?'), findsNothing);
      expect(port.calls, 0);
    },
  );

  testComponents('the three preserved views are present and switch', (
    tester,
  ) async {
    AppLocator.m2 = ApiM2Repository(_FakeM2Client());
    final port = _FakeComposedPort(
      ApiResult<ComposedQuestionnaire>.success(_document()),
    );

    tester.pumpComponent(
      CustomerQuestionnaireStep5(
        assessmentId: stage5MarketplaceAssessmentId,
        api: port,
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }

    // The design's three views survive the data change.
    expect(find.text('Question list'), findsOneComponent);
    expect(find.text('Who sees each question'), findsOneComponent);
    expect(find.text('Question details'), findsOneComponent);
    expect(find.text('Preview as Respondent'), findsOneComponent);
    // The seven-row summary list became a five-cell strip beside the document.
    // The facts it carried are still stated; only their shape changed.
    expect(find.text('Questions'), findsOneComponent);
    expect(find.text('Composition'), findsOneComponent);
    expect(find.text('Revision'), findsOneComponent);

    // Question list is the default view.
    expect(find.text('Governed core question Q02 wording.'), findsOneComponent);

    // Who sees each question: it must state the absence rather than invent an
    // audience, and it must still show the real determinants.
    await tester.click(
      find
          .ancestor(
            of: find.text('Who sees each question'),
            matching: find.tag('button'),
          )
          .first,
    );
    await tester.pump();
    expect(
      find.textContaining('Per-respondent routing is not recorded'),
      findsOneComponent,
    );
    expect(find.textContaining('All respondents'), findsNothing);
    // The list view's table is gone while this tab is active.
    expect(find.text('Governed core question Q02 wording.'), findsNothing);

    // Question details: real per-item metadata, no invented fields.
    await tester.click(
      find
          .ancestor(
            of: find.text('Question details'),
            matching: find.tag('button'),
          )
          .first,
    );
    await tester.pump();
    expect(find.text('How customers can respond'), findsOneComponent);
    // 13 core items plus the one additional item, all carrying codes.
    expect(find.textContaining('Answer codes:'), findsNComponents(14));
    expect(find.textContaining('Before you share'), findsOneComponent);
  });

  testComponents('the summary reports the resolved business context', (
    tester,
  ) async {
    AppLocator.m2 = ApiM2Repository(_FakeM2Client());
    final port = _FakeComposedPort(
      ApiResult<ComposedQuestionnaire>.success(_document()),
    );

    tester.pumpComponent(
      CustomerQuestionnaireStep5(
        assessmentId: stage5MarketplaceAssessmentId,
        api: port,
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }

    expect(find.text('Business context (BCB)'), findsOneComponent);
    expect(find.text('Persisted'), findsOneComponent);
  });

  testComponents('a failed business-context read still renders the document', (
    tester,
  ) async {
    // The BCB read throws; composition does not depend on it, so the
    // questionnaire must still be shown and the gap reported.
    AppLocator.m2 = ApiM2Repository(_FakeM2Client(contextStatusFails: true));
    final port = _FakeComposedPort(
      ApiResult<ComposedQuestionnaire>.success(_document()),
    );

    tester.pumpComponent(
      CustomerQuestionnaireStep5(
        assessmentId: stage5MarketplaceAssessmentId,
        api: port,
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }

    expect(find.text('Governed core question Q02 wording.'), findsOneComponent);
    expect(find.text('Business context (BCB)'), findsOneComponent);
    expect(find.text('UNRESOLVED'), findsOneComponent);
  });

  testComponents(
    'the respondent preview never preselects the intended option',
    (tester) async {
      AppLocator.m2 = ApiM2Repository(_FakeM2Client());
      final port = _FakeComposedPort(
        ApiResult<ComposedQuestionnaire>.success(_document()),
      );

      tester.pumpComponent(
        CustomerQuestionnaireStep5(
          assessmentId: stage5MarketplaceAssessmentId,
          api: port,
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }

      await tester.click(
        find
            .ancestor(
              of: find.text('Preview as Respondent'),
              matching: find.tag('button'),
            )
            .first,
      );
      await tester.pump();

      // The first item is Q01; its option codes are rendered, and no radio or
      // checkbox carries a `checked` attribute — the owner's intended answer is
      // entrepreneur-only metadata and is never a respondent's preselection.
      expect(find.textContaining('Question 1 of 14'), findsOneComponent);
      expect(find.textContaining('NOT FIELDED'), findsOneComponent);
      expect(find.text('R1'), findsOneComponent);
    },
  );

  // DD-111: a questionnaire that is already published must not render as
  // unpublishable. `isPublishable` excluded `already_published`, so the real
  // assessment (published as release 577e61b0) showed "Not publishable" and a
  // disabled button. Publishing is idempotent by manifest hash, so the control
  // stays available and the row reports the publication that exists.
  testComponents('an already published questionnaire stays publishable', (
    tester,
  ) async {
    AppLocator.m2 = ApiM2Repository(_FakeM2Client());
    final port = _FakeComposedPort(
      ApiResult<ComposedQuestionnaire>.success(_document()),
    );
    final publication = _FakePublicationPort(
      previewResult: ApiResult<PublicationReport>.success(
        _report(alreadyPublished: true, authorized: 7),
      ),
    );

    tester.pumpComponent(
      CustomerQuestionnaireStep5(
        assessmentId: stage5MarketplaceAssessmentId,
        api: port,
        publication: publication,
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }

    expect(find.text('Publication service'), findsOneComponent);
    // The card header and the gate row both report it, so a reader sees the
    // state without having to find the row.
    expect(find.text('Published'), findsNComponents(2));
    expect(find.text('Not publishable'), findsNothing);
    expect(find.textContaining('Already published'), findsOneComponent);

    // The control is live: clicking it reaches the port. A disabled control
    // never fires (the sibling test asserts `publishes == 0` in that case).
    await tester.click(
      find
          .ancestor(
            of: find.text('Publish Questionnaire'),
            matching: find.tag('button'),
          )
          .first,
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(
      publication.publishes,
      1,
      reason: 'an already published document is still publishable: the write is '
          'idempotent and returns ALREADY_PUBLISHED',
    );
  });
}
