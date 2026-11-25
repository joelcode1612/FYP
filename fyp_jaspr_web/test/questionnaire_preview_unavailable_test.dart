/// The questionnaire is unavailable for *this* assessment.
///
/// This file used to inject rows into the component (`rows: [CqRow(...)]`) and
/// assert that no built-in café sample appeared. That constructor no longer
/// exists: the panel now takes transport ports and renders only what the
/// composed-questionnaire route returns, so "supplied rows" is the only source
/// of wording that exists. What still has to be true is the other half of the
/// old intent — when the document cannot be retrieved, or does not belong to
/// this binding, nothing is drawn in its place and the publish control is
/// refused rather than offered.
library;

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
  final paths = <String>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    paths.add(path);
    if (path ==
        '/api/v1/m2/assessments/by-marketplace/$stage5MarketplaceAssessmentId') {
      return stage5LinkPayload();
    }
    if (path == '/api/v1/m2/assessments/$stage5M2AssessmentId') {
      return stage5M2DraftPayload();
    }
    if (path ==
        '/api/v1/m2/assessments/$stage5M2AssessmentId/confirmation-current') {
      return stage5ConfirmationPayload();
    }
    if (path ==
        '/api/v1/m2/assessments/$stage5M2AssessmentId/confirmations/'
            '$stage5ConfirmationId/business-context-status') {
      return stage5ContextStatusPayload();
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('The unavailable path must not write to the M2 transport.');
}

/// Returns whatever the caller hands it: a refusal, or a document that belongs
/// to a different binding.
class _FixedComposedPort implements Stage5ComposedPort {
  _FixedComposedPort(this.result);

  final ApiResult<ComposedQuestionnaire> result;
  int calls = 0;

  @override
  Future<ApiResult<ComposedQuestionnaire>> read({
    required String assessmentId,
    required int expectedRevision,
    required String confirmationId,
  }) async {
    calls++;
    return result;
  }
}

/// A publication service that is never asked anything.
///
/// The component reads publication readiness only once a document is on screen.
/// Reaching this port from an unavailable document would mean the page had
/// begun offering to publish something it never retrieved.
class _UnreachablePublicationPort implements Stage5PublicationPort {
  @override
  Future<ApiResult<PublicationReport>> preview({
    required String assessmentId,
  }) async => throw StateError('Publication must not be read without a document.');

  @override
  Future<ApiResult<PublicationReport>> publish({
    required String assessmentId,
  }) async => throw StateError('Publication must not be attempted without a document.');
}

/// Collection state is read before the composition gate by design, so it has to
/// answer; it is independent of whether a document exists.
class _FakeCollectionPort implements Stage5CollectionPort {
  @override
  Future<ApiResult<CollectionSnapshot>> read({
    required String assessmentId,
  }) async => ApiResult<CollectionSnapshot>.success(
    CollectionSnapshot(const {'lifecycle_state': 'OPEN'}),
  );

  @override
  Future<ApiResult<CollectionSnapshot>> setTarget({
    required String assessmentId,
    required int target,
    required String requestId,
  }) async => throw StateError('No target is set from an unavailable document.');

  @override
  Future<ApiResult<CollectionSnapshot>> endCollection({
    required String assessmentId,
    required String requestId,
    required String completionPolicy,
    required String inProgressDisposition,
    String? reason,
  }) async => throw StateError('No collection is ended from an unavailable document.');
}

/// A composed document that echoes a different revision than the one the
/// confirmation agreed on.
Map<String, dynamic> _documentAtOtherRevision() =>
    stage5ComposedDocument()..['assessment_revision'] = stage5Revision - 1;

void main() {
  late ApiM2Repository originalM2;

  setUp(() => originalM2 = AppLocator.m2);
  tearDown(() => AppLocator.m2 = originalM2);

  testComponents('an unreadable document draws no sample questions and cannot '
      'be published', (tester) async {
    AppLocator.m2 = ApiM2Repository(_FakeM2Client());
    final port = _FixedComposedPort(
      ApiResult<ComposedQuestionnaire>.error(
        const AssessmentFailure(
          status: 503,
          code: 'COMPOSITION_UNAVAILABLE',
          message: 'The composition service is unavailable.',
        ),
      ),
    );

    tester.pumpComponent(
      CustomerQuestionnaireStep5(
        assessmentId: stage5MarketplaceAssessmentId,
        api: port,
        publication: _UnreachablePublicationPort(),
        collection: _FakeCollectionPort(),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }

    // The server's own sentence, not a sentence of ours.
    expect(
      find.text('The questionnaire could not be loaded'),
      findsOneComponent,
    );
    expect(
      find.text('The composition service is unavailable.'),
      findsOneComponent,
    );

    // Nothing is drawn in the document's place -- in particular not the
    // design's café sample, which is what a fallback would look like.
    expect(find.text('How often do you visit a café?'), findsNothing);
    expect(find.textContaining('Governed core question'), findsNothing);
    expect(find.text('Question list'), findsOneComponent);

    // Publication is stated and refused: the readiness chip says so, the
    // control's caption says so, and the service was never asked.
    expect(find.text('Not publishable'), findsOneComponent);
    expect(
      find.text('Unavailable until a composed questionnaire is retrieved.'),
      findsOneComponent,
    );
    expect(port.calls, 1);
  });

  testComponents('a document composed for another revision is refused, not '
      'rendered', (tester) async {
    AppLocator.m2 = ApiM2Repository(_FakeM2Client());
    final port = _FixedComposedPort(
      ApiResult<ComposedQuestionnaire>.success(
        ComposedQuestionnaire.fromJson(_documentAtOtherRevision()),
      ),
    );

    tester.pumpComponent(
      CustomerQuestionnaireStep5(
        assessmentId: stage5MarketplaceAssessmentId,
        api: port,
        publication: _UnreachablePublicationPort(),
        collection: _FakeCollectionPort(),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }

    // The payload is well-formed but belongs to another revision, so rendering
    // it would show one declaration's wording under another's heading.
    expect(
      find.textContaining('composed for a different assessment or revision'),
      findsOneComponent,
    );
    expect(find.textContaining('Governed core question'), findsNothing);
    expect(find.text('How often do you visit a café?'), findsNothing);
    expect(find.text('Not publishable'), findsOneComponent);
  });
}
