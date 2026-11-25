/// Authenticated client for the Stage 5 composed-questionnaire route.
///
/// Verified route (`project1_stage5_composed.py`):
///
/// * `GET /assessments/{m2_id}/stage5/composed-questionnaire`
///   `?expected_revision=&confirmation_id=`
///
/// Two binding facts this client encodes, because getting either wrong produced
/// a 404 that looked like "no questionnaire exists":
///
/// * the path parameter is the **M2** assessment id, not the marketplace
///   assessment id;
/// * the server re-verifies the revision *and* the confirmation snapshot before
///   composing, so a stale pair is refused with 409 rather than served.
///
/// Failures are [ApiResult] values, not thrown errors: the screen must tell
/// "your declaration moved" apart from "the service is down", and Dart cannot
/// read a status off a thrown exception.
library;

import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage5_composed_questionnaire.dart';
import 'package:sitewise_jaspr_web/features/authentication/data/auth_service.dart';

const String _base = '/api/v1/project1-workflow/assessments';

/// Refusal codes this client branches on. Wording always comes from the server.
abstract final class Stage5ComposedCodes {
  static const assessmentNotFound = 'COMPOSITION_ASSESSMENT_NOT_FOUND';
  static const revisionStale = 'COMPOSITION_REVISION_STALE';
  static const confirmationRequired = 'COMPOSITION_CONFIRMATION_REQUIRED';
  static const confirmationNotFound = 'COMPOSITION_CONFIRMATION_NOT_FOUND';
  static const confirmationStale = 'COMPOSITION_CONFIRMATION_STALE';
  static const catalogueUnavailable = 'PREVIEW_CATALOGUE_UNAVAILABLE';
}

/// True when the caller should re-read the confirmation rather than retry the
/// same request. Retrying a stale pair can only fail again.
bool isStaleComposedSource(String? code) =>
    code == Stage5ComposedCodes.revisionStale ||
    code == Stage5ComposedCodes.confirmationRequired ||
    code == Stage5ComposedCodes.confirmationStale;

/// True when the assessment itself is not readable by this caller. Treated as
/// an authorisation/identity problem, never as "empty questionnaire".
bool isUnreadableAssessment(String? code) =>
    code == Stage5ComposedCodes.assessmentNotFound ||
    code == Stage5ComposedCodes.confirmationNotFound;

/// Transport port, so a component test can render a recorded document without
/// reaching the network. It adds no operations: [Stage5ComposedApi] implements
/// every method here.
abstract interface class Stage5ComposedPort {
  Future<ApiResult<ComposedQuestionnaire>> read({
    required String assessmentId,
    required int expectedRevision,
    required String confirmationId,
  });
}

final class Stage5ComposedApi implements Stage5ComposedPort {
  const Stage5ComposedApi();

  @override
  Future<ApiResult<ComposedQuestionnaire>> read({
    required String assessmentId,
    required int expectedRevision,
    required String confirmationId,
  }) async {
    final path =
        '$_base/${Uri.encodeComponent(assessmentId)}/stage5/'
        'composed-questionnaire'
        '?expected_revision=$expectedRevision'
        '&confirmation_id=${Uri.encodeQueryComponent(confirmationId)}';

    final response = await WebAuth.requestDetailed(path);
    if (response['ok'] != true) {
      return ApiResult<ComposedQuestionnaire>.error(
        AssessmentFailure(
          status: response['status'] as int?,
          code: response['code'] as String?,
          message:
              response['message'] as String? ??
              'The composed questionnaire could not be loaded.',
        ),
      );
    }
    final payload = response['body'];
    if (payload is! Map<String, dynamic>) {
      return ApiResult<ComposedQuestionnaire>.error(
        const AssessmentFailure(
          code: 'unexpected_response',
          message: 'The server returned a questionnaire this page cannot read.',
        ),
      );
    }
    try {
      return ApiResult<ComposedQuestionnaire>.success(
        ComposedQuestionnaire.fromJson(payload),
      );
    } on Object catch (error) {
      // A malformed payload is reported, never rendered as if it were wording.
      return ApiResult<ComposedQuestionnaire>.error(
        AssessmentFailure(
          code: 'unexpected_response',
          message: 'The questionnaire response could not be read: $error',
        ),
      );
    }
  }
}
