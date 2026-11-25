/// Authenticated client for the Stage 4 Section A preview endpoint.
///
/// Verified route (`project1_stage4_preview.py`):
///
/// * `GET /assessments/{id}/stage4/preview-questionnaire`
///   `?expected_revision=&confirmation_id=`
///
/// The endpoint is read-only and returns all 13 governed core questions with
/// the server's deterministic substitution applied. It requires the M2
/// revision and the confirmation id because the server re-verifies both before
/// serving, so a stale pair is refused with 409 rather than shown.
///
/// Failures are [ApiResult] values, not thrown errors: the panel must tell "the
/// source moved" apart from "the catalogue is unavailable", and Dart cannot
/// read a status off a thrown exception.
library;

import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage4_preview_questionnaire.dart';
import 'package:sitewise_jaspr_web/features/authentication/data/auth_service.dart';

const String _base = '/api/v1/project1-workflow/assessments';

/// Refusal codes this client branches on. Wording always comes from the server.
abstract final class Stage4PreviewCodes {
  static const revisionStale = 'PREVIEW_REVISION_STALE';
  static const confirmationRequired = 'PREVIEW_CONFIRMATION_REQUIRED';
  static const confirmationStale = 'PREVIEW_CONFIRMATION_STALE';
  static const confirmationNotFound = 'PREVIEW_CONFIRMATION_NOT_FOUND';
  static const assessmentNotFound = 'PREVIEW_ASSESSMENT_NOT_FOUND';
  static const catalogueUnavailable = 'PREVIEW_CATALOGUE_UNAVAILABLE';
}

/// True when the caller should re-read rather than retry blindly.
bool isStalePreviewSource(String? code) =>
    code == Stage4PreviewCodes.revisionStale ||
    code == Stage4PreviewCodes.confirmationStale ||
    code == Stage4PreviewCodes.confirmationRequired;

/// Transport port, so a component test can render a recorded payload without
/// reaching the network. It adds no operations: every method is implemented by
/// [Stage4PreviewApi].
abstract interface class Stage4PreviewPort {
  Future<ApiResult<PreviewQuestionnaire>> read({
    required String assessmentId,
    required int expectedRevision,
    required String confirmationId,
  });
}

final class Stage4PreviewApi implements Stage4PreviewPort {
  const Stage4PreviewApi();

  @override
  Future<ApiResult<PreviewQuestionnaire>> read({
    required String assessmentId,
    required int expectedRevision,
    required String confirmationId,
  }) async {
    final path =
        '$_base/${Uri.encodeComponent(assessmentId)}/stage4/'
        'preview-questionnaire'
        '?expected_revision=$expectedRevision'
        '&confirmation_id=${Uri.encodeQueryComponent(confirmationId)}';

    final response = await WebAuth.requestDetailed(path);
    if (response['ok'] != true) {
      return ApiResult<PreviewQuestionnaire>.error(
        AssessmentFailure(
          status: response['status'] as int?,
          code: response['code'] as String?,
          message:
              response['message'] as String? ??
              'The core questionnaire could not be loaded.',
        ),
      );
    }
    final payload = response['body'];
    if (payload is! Map<String, dynamic>) {
      return ApiResult<PreviewQuestionnaire>.error(
        const AssessmentFailure(
          code: 'unexpected_response',
          message: 'The server returned a questionnaire this page cannot read.',
        ),
      );
    }
    try {
      return ApiResult<PreviewQuestionnaire>.success(
        PreviewQuestionnaire.fromJson(payload),
      );
    } on Object catch (error) {
      // A malformed payload is reported, never rendered as if it were wording.
      return ApiResult<PreviewQuestionnaire>.error(
        AssessmentFailure(
          code: 'unexpected_response',
          message: 'The questionnaire response could not be read: $error',
        ),
      );
    }
  }
}
