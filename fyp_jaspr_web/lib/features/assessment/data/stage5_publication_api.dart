/// Authenticated client for the CQ publication routes (DD-096).
///
/// Verified routes (`api/v1/customer_questionnaire.py`):
///
/// * `GET  /api/v1/cq/publication/{m2_assessment_id}` — preview, writes nothing
/// * `POST /api/v1/cq/publication/{m2_assessment_id}` — publish
///
/// Two facts this client encodes, because getting either wrong produced a
/// control that looked broken:
///
/// * the path parameter is the **M2** assessment id, the same id the composed
///   questionnaire route takes — not the marketplace assessment id;
/// * publication is **not** gated on `CQ_RUNTIME_ENABLED`. Fielding and
///   publication are separate decisions held by separate principals, so a
///   successful publish does not mean respondents can start. [PublicationReport]
///   therefore carries `runtimeActivated` and `productionFieldingAuthorized`
///   and the screen renders both, rather than letting "published" imply
///   "fielding".
///
/// Failures are [ApiResult] values, not thrown errors: the screen must tell
/// "this questionnaire is not publishable" (a state of the document) apart from
/// "the publication service is unavailable" (a state of the deployment).
library;

import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/authentication/data/auth_service.dart';

const String _base = '/api/v1/cq/publication';

/// Refusal codes this client branches on. Wording always comes from the server.
abstract final class Stage5PublicationCodes {
  /// The caller does not own the assessment, or it does not exist. The server
  /// deliberately does not distinguish the two.
  static const assessmentNotFound = 'CQ_PUBLICATION_ASSESSMENT_NOT_FOUND';

  /// A governed stem still has an unresolved slot, so nothing can be rendered.
  static const slotsUnresolved = 'CQ_PUBLICATION_SLOTS_UNRESOLVED';

  /// The confirmed revision moved, or the business context is stale.
  static const revisionUnconfirmed = 'CQ_PUBLICATION_REVISION_UNCONFIRMED';
  static const contextStale = 'CQ_PUBLICATION_CONTEXT_STALE';
  static const contextUnavailable = 'CQ_PUBLICATION_CONTEXT_UNAVAILABLE';

  /// No question survived authorisation, so the release would be empty.
  static const noAuthorizedQuestions = 'CQ_PUBLICATION_NO_AUTHORIZED_QUESTIONS';

  /// The assessment is already bound to a different release. Rebinding it is a
  /// supersession decision, not something pressing Publish may do (DD-095).
  static const releaseSuperseded = 'CQ_PUBLICATION_RELEASE_SUPERSEDED';

  /// The publisher principal is not configured for this deployment.
  static const targetUnverified = 'CQ_PUBLICATION_TARGET_UNVERIFIED';
  static const disabled = 'CQ_PUBLICATION_DISABLED';
}

/// True when retrying the same request cannot succeed; the reader has to act.
bool isPublicationBlocked(String? code) =>
    code == Stage5PublicationCodes.assessmentNotFound ||
    code == Stage5PublicationCodes.slotsUnresolved ||
    code == Stage5PublicationCodes.noAuthorizedQuestions ||
    code == Stage5PublicationCodes.releaseSuperseded ||
    code == Stage5PublicationCodes.targetUnverified ||
    code == Stage5PublicationCodes.disabled;

/// The server's answer to "what would publishing do", and to "publish".
///
/// One model for both, because the publish response is the preview plus what it
/// wrote: the same fields, the same meaning, plus `releaseState` and
/// `assignments` when a write happened.
class PublicationReport {
  const PublicationReport({
    required this.state,
    required this.releaseId,
    required this.manifestHash,
    required this.questionCount,
    required this.authorizedCount,
    required this.excludedCount,
    required this.alreadyPublished,
    required this.authorizedQuestionIds,
    required this.sourceClass,
    required this.principal,
    required this.productionFieldingAuthorized,
    required this.runtimeActivated,
    this.releaseState,
    this.assignments,
    this.campaignId,
    this.campaignReleaseMatches,
  });

  /// `PREVIEW`, `PUBLISHED` or `ALREADY_PUBLISHED`.
  final String state;
  final String releaseId;
  final String manifestHash;
  final int questionCount;
  final int authorizedCount;
  final int excludedCount;
  final bool alreadyPublished;
  final List<String> authorizedQuestionIds;
  final String sourceClass;

  /// The database principal that performed the operation. Rendered because it
  /// is the separation this route exists to provide.
  final String principal;

  /// Both false by construction while customer fielding is disabled. They are
  /// fields rather than assumptions so the screen cannot imply otherwise.
  final bool productionFieldingAuthorized;
  final bool runtimeActivated;

  final String? releaseState;
  final int? assignments;
  final String? campaignId;
  final bool? campaignReleaseMatches;

  bool get isPublished => state == 'PUBLISHED';

  /// A `GET` preview reports `state: 'PREVIEW'` with `already_published: true`;
  /// only a `POST` answers `state: 'ALREADY_PUBLISHED'`. Reading the state alone
  /// therefore never recognised a published document on read, so the row said
  /// "Available" for a release that already exists.
  bool get isAlreadyPublished =>
      alreadyPublished || state == 'ALREADY_PUBLISHED';

  /// True when this questionnaire can be published now.
  ///
  /// `already_published` must **not** close this gate. Publishing is idempotent
  /// by `manifest_hash`: publishing an already-published document returns
  /// `ALREADY_PUBLISHED` and writes nothing. Excluding it made a published
  /// questionnaire render as "Not publishable" with the button disabled, which
  /// is the opposite of the truth. Fielding is a separate axis, reported by
  /// [productionFieldingAuthorized] and [runtimeActivated].
  bool get isPublishable =>
      authorizedCount > 0 &&
      (state == 'PREVIEW' || state == 'ALREADY_PUBLISHED');

  factory PublicationReport.fromJson(Map<String, dynamic> json) {
    final campaign = json['campaign'];
    final ids = json['authorized_question_ids'];
    return PublicationReport(
      state: json['state'] as String? ?? 'UNKNOWN',
      releaseId: json['release_id'] as String? ?? '',
      manifestHash: json['manifest_hash'] as String? ?? '',
      questionCount: (json['question_count'] as num?)?.toInt() ?? 0,
      authorizedCount: (json['authorized_count'] as num?)?.toInt() ?? 0,
      excludedCount: (json['excluded_count'] as num?)?.toInt() ?? 0,
      alreadyPublished: json['already_published'] == true,
      authorizedQuestionIds: ids is List
          ? ids.whereType<String>().toList(growable: false)
          : const <String>[],
      sourceClass: json['source_class'] as String? ?? '',
      principal: json['principal'] as String? ?? '',
      productionFieldingAuthorized:
          json['production_fielding_authorized'] == true,
      runtimeActivated: json['runtime_activated'] == true,
      releaseState: json['release_state'] as String?,
      assignments: (json['assignments'] as num?)?.toInt(),
      campaignId: campaign is Map<String, dynamic>
          ? campaign['campaign_id'] as String?
          : null,
      campaignReleaseMatches: campaign is Map<String, dynamic>
          ? campaign['release_matches'] == true
          : null,
    );
  }
}

/// Transport port, so a component test can render a recorded report without
/// reaching the network.
abstract interface class Stage5PublicationPort {
  Future<ApiResult<PublicationReport>> preview({required String assessmentId});

  Future<ApiResult<PublicationReport>> publish({required String assessmentId});
}

final class Stage5PublicationApi implements Stage5PublicationPort {
  const Stage5PublicationApi();

  @override
  Future<ApiResult<PublicationReport>> preview({
    required String assessmentId,
  }) => _send(assessmentId, 'GET');

  @override
  Future<ApiResult<PublicationReport>> publish({
    required String assessmentId,
  }) => _send(assessmentId, 'POST');

  Future<ApiResult<PublicationReport>> _send(
    String assessmentId,
    String method,
  ) async {
    final path = '$_base/${Uri.encodeComponent(assessmentId)}';
    final response = await WebAuth.requestDetailed(
      path,
      method: method,
      // An empty object, not null: the route declares a body model with
      // `extra='forbid'`, so the client states "no options" explicitly and a
      // future attempt to pass one is refused by the server rather than
      // silently ignored.
      body: method == 'POST' ? const <String, dynamic>{} : null,
    );
    if (response['ok'] != true) {
      return ApiResult<PublicationReport>.error(
        AssessmentFailure(
          status: response['status'] as int?,
          code: response['code'] as String?,
          message:
              response['message'] as String? ??
              'The publication request could not be completed.',
        ),
      );
    }
    final payload = response['body'];
    if (payload is! Map<String, dynamic>) {
      return ApiResult<PublicationReport>.error(
        const AssessmentFailure(
          code: 'unexpected_response',
          message: 'The server returned a publication report this page cannot '
              'read.',
        ),
      );
    }
    try {
      return ApiResult<PublicationReport>.success(
        PublicationReport.fromJson(payload),
      );
    } on Object catch (error) {
      return ApiResult<PublicationReport>.error(
        AssessmentFailure(
          code: 'unexpected_response',
          message: 'The publication report could not be read: $error',
        ),
      );
    }
  }
}
