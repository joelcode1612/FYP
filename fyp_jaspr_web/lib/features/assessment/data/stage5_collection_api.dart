/// Authenticated client for the CQ collection routes (DD-097).
///
/// Verified routes (`api/v1/customer_questionnaire.py`):
///
/// * `GET  /api/v1/cq/assessments/{m2_assessment_id}/collection`
/// * `PUT  /api/v1/cq/assessments/{m2_assessment_id}/collection/target`
/// * `POST /api/v1/cq/assessments/{m2_assessment_id}/collection/end`
///
/// Three facts this client encodes, because getting any of them wrong produced a
/// control that lied:
///
/// * the path parameter is the **M2** assessment id, the same id the publication
///   and composed routes take — not the marketplace assessment id;
/// * the respondent target is **not** a publication gate. It is the
///   entrepreneur's own planning figure, and it is stored on the server so it
///   survives a reload, a logout, a device change and an application restart. It
///   used to live only in component state, which meant the number a reader typed
///   disappeared the moment the page reloaded;
/// * collection progress is **derived by the server** from persisted sessions,
///   receipts and measurement snapshots. This client never computes a count, and
///   a value it does not receive is rendered as unknown rather than as zero.
///
/// The response is kept as the server's own map. Parsing it into a narrower model
/// here would mean the screen could show a number the server never sent.
library;

import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/authentication/data/auth_service.dart';

const String _base = '/api/v1/cq/assessments';

/// Refusal codes this client branches on. Wording always comes from the server.
abstract final class Stage5CollectionCodes {
  /// Not published yet, or published by somebody else. The server deliberately
  /// does not distinguish the two.
  static const campaignNotFound = 'CQ_COLLECTION_CAMPAIGN_NOT_FOUND';

  /// The figure is not a positive integer within the accepted range.
  static const targetInvalid = 'CQ_COLLECTION_TARGET_INVALID';

  /// Collection has ended, so the goal can no longer be restated.
  static const targetLocked = 'CQ_COLLECTION_ENDED_TARGET_LOCKED';

  /// The closure policy the client asked for is not one the server implements.
  static const policyUnsupported = 'CQ_COLLECTION_POLICY_UNSUPPORTED';
  static const dispositionUnsupported = 'CQ_COLLECTION_DISPOSITION_UNSUPPORTED';

  /// The owner asked to close only at target, but the target has not been met.
  static const targetNotReached = 'CQ_COLLECTION_TARGET_NOT_REACHED';
  static const targetNotSet = 'CQ_COLLECTION_TARGET_NOT_SET';

  /// The server is not configured with the CQ write principal.
  static const principalRequired = 'CQ_COLLECTION_STATE_PRINCIPAL_REQUIRED';
}

/// The server's answer to "where does this collection stand".
///
/// Deliberately a thin view over the response map. Every number on screen comes
/// from here, so a missing key reads as "unknown" instead of silently becoming
/// zero.
class CollectionSnapshot {
  const CollectionSnapshot(this.raw);

  final Map<String, dynamic> raw;

  Map<String, dynamic> get _progress =>
      (raw['progress'] as Map<String, dynamic>?) ?? const <String, dynamic>{};

  String get lifecycleState => raw['lifecycle_state'] as String? ?? 'OPEN';

  bool get acceptingResponses => raw['accepting_responses'] as bool? ?? true;

  bool get isEnded => lifecycleState == 'ENDED';

  /// Null means the entrepreneur has not set a target. It is not zero.
  int? get respondentTarget => _progress['respondent_target'] as int?;

  int? get eligibleSubmittedRespondents =>
      _progress['eligible_submitted_respondents'] as int?;

  int? get remainingRespondents => _progress['remaining_respondents'] as int?;

  num? get progressPercent => _progress['progress_percent'] as num?;

  bool? get targetReached => _progress['operational_target_reached'] as bool?;

  int? get totalSessions => _progress['total_sessions'] as int?;

  int? get submittedSessions => _progress['submitted_sessions'] as int?;

  int? get openSessions => _progress['open_sessions'] as int?;

  int? get validReceipts => _progress['valid_submission_receipts'] as int?;

  String get evidenceScope =>
      _progress['evidence_scope'] as String? ?? 'UNKNOWN';

  bool get isSynthetic => evidenceScope == 'SYNTHETIC_DEVELOPER_PREVIEW';

  Map<String, dynamic>? get closure =>
      raw['closure'] as Map<String, dynamic>?;

  bool get closedBelowTarget =>
      (closure?['closed_below_target'] as bool?) ?? false;

  int? get openSessionsCount => openSessions;
}

/// Transport port, so a component test can render a recorded snapshot without
/// reaching the network.
abstract interface class Stage5CollectionPort {
  Future<ApiResult<CollectionSnapshot>> read({required String assessmentId});

  Future<ApiResult<CollectionSnapshot>> setTarget({
    required String assessmentId,
    required int target,
    required String requestId,
  });

  Future<ApiResult<CollectionSnapshot>> endCollection({
    required String assessmentId,
    required String requestId,
    required String completionPolicy,
    required String inProgressDisposition,
    String? reason,
  });
}

final class Stage5CollectionApi implements Stage5CollectionPort {
  const Stage5CollectionApi();

  @override
  Future<ApiResult<CollectionSnapshot>> read({
    required String assessmentId,
  }) => _send(assessmentId, 'GET', null);

  @override
  Future<ApiResult<CollectionSnapshot>> setTarget({
    required String assessmentId,
    required int target,
    required String requestId,
  }) => _send(assessmentId, 'PUT', <String, dynamic>{
    'request_id': requestId,
    'respondent_target': target,
  }, suffix: '/target');

  @override
  Future<ApiResult<CollectionSnapshot>> endCollection({
    required String assessmentId,
    required String requestId,
    required String completionPolicy,
    required String inProgressDisposition,
    String? reason,
  }) => _send(assessmentId, 'POST', <String, dynamic>{
    'request_id': requestId,
    'completion_policy': completionPolicy,
    'in_progress_disposition': inProgressDisposition,
    if (reason != null && reason.isNotEmpty) 'reason': reason,
  }, suffix: '/end');

  Future<ApiResult<CollectionSnapshot>> _send(
    String assessmentId,
    String method,
    Map<String, dynamic>? body, {
    String suffix = '',
  }) async {
    final path =
        '$_base/${Uri.encodeComponent(assessmentId)}/collection$suffix';
    final response = await WebAuth.requestDetailed(
      path,
      method: method,
      body: body,
    );
    if (response['ok'] != true) {
      return ApiResult<CollectionSnapshot>.error(
        AssessmentFailure(
          status: response['status'] as int?,
          code: response['code'] as String?,
          message:
              response['message'] as String? ??
              'The collection request could not be completed.',
        ),
      );
    }
    final payload = response['body'];
    if (payload is! Map<String, dynamic>) {
      return ApiResult<CollectionSnapshot>.error(
        const AssessmentFailure(
          message: 'The collection response was not readable.',
        ),
      );
    }
    return ApiResult<CollectionSnapshot>.success(CollectionSnapshot(payload));
  }
}
