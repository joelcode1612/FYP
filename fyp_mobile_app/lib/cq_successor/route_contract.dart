/// Versioned route-preview contracts for the SYNTHETIC successor candidate.
///
/// This is an INTEGRATION-LAYER contract, deliberately divergent from the
/// pure-Python oracle's `QuestionnaireContext`. The oracle carries
/// `completed_ids`, `viewer_authorized`, `consented`, `withdrawn` and
/// `*_approved_in_fixture` as domain-fixture conveniences; NONE of those may
/// cross an HTTP boundary. All authority is derived server-side.
///
/// The RESPONSE is field-for-field with the oracle's `RoutePreview`
/// (`models.py:91-104`), plus version/provenance fields.
///
/// SYNTHETIC ONLY. Not an approved replacement for frozen CUST03.
library;

const String kInstrumentVersion = 'SYN-CUST03-SUCCESSOR-1';
const String kRoutingPolicyVersion = 'SD-CQ-AREA-01-SYNTHETIC-PROPOSAL-1';
const String kQuestionBankVersion = 'SYN-QBANK-V1';
const String kConceptVersion = 'SYN-CONCEPT-1';
const String kM2ContextVersion = 'SYN-M2-V1';

const List<String> kQuestionIds = <String>[
  'Q01', 'Q02', 'Q03', 'Q04', 'Q05', 'Q06', 'Q07',
  'Q08', 'Q09', 'Q10', 'Q11', 'Q12', 'Q13',
];

/// Six frozen CUST03 Q01 affiliation codes, preserved read-only.
const Set<String> kQ01AffiliationCodes = <String>{
  'LIVE', 'WORK', 'STUDY', 'RUN_BUSINESS', 'VISIT_PURPOSE', 'PASS_THROUGH',
};

/// Legacy historical codes. Never silently recoded into the successor code.
const Set<String> kQ01LegacyFrequencyCodes = <String>{'RARELY', 'NEVER', 'NOT_SURE'};

/// NEW successor candidate option — synthetic/review mode ONLY.
/// Never inserted into the frozen question bank in `questionnaire_repository.dart`.
const String kQ01NoCurrentConnection = 'NO_CURRENT_CONNECTION';

enum RouteItemState {
  eligibleToShow,
  notShown,
  pendingDependency,
  blocked,
}

String routeItemStateName(RouteItemState state) => switch (state) {
      RouteItemState.eligibleToShow => 'ELIGIBLE_TO_SHOW',
      RouteItemState.notShown => 'NOT_SHOWN',
      RouteItemState.pendingDependency => 'PENDING_DEPENDENCY',
      RouteItemState.blocked => 'BLOCKED',
    };

class PreviewPermission {
  final String itemId;
  final RouteItemState state;
  final String reason;

  const PreviewPermission({
    required this.itemId,
    required this.state,
    required this.reason,
  });
}

/// Request DTO. NO authority-granting fields. NO `completedIds`.
class RoutePreviewRequest {
  final String assessmentId;
  final String tenantId;
  final List<String> q01Codes;
  final String? q02Code;
  final String? q04Code;
  final String? q05Code;
  final String instrumentVersion;
  final String routingPolicyVersion;
  final String questionBankVersion;
  final String conceptVersion;
  final String m2ContextVersion;
  final int expectedRevision;

  const RoutePreviewRequest({
    required this.assessmentId,
    required this.tenantId,
    this.q01Codes = const <String>[],
    this.q02Code,
    this.q04Code,
    this.q05Code,
    this.instrumentVersion = kInstrumentVersion,
    this.routingPolicyVersion = kRoutingPolicyVersion,
    this.questionBankVersion = kQuestionBankVersion,
    this.conceptVersion = kConceptVersion,
    this.m2ContextVersion = kM2ContextVersion,
    this.expectedRevision = 0,
  });

  bool get versionsMatchCurrent =>
      instrumentVersion == kInstrumentVersion &&
      routingPolicyVersion == kRoutingPolicyVersion &&
      questionBankVersion == kQuestionBankVersion &&
      conceptVersion == kConceptVersion &&
      m2ContextVersion == kM2ContextVersion;

  /// Wire shape — key-for-key with the FastAPI `RoutePreviewRequest` JSON
  /// contract. NO authority-granting fields are ever emitted.
  Map<String, Object?> toJson() => <String, Object?>{
        'assessment_id': assessmentId,
        'tenant_id': tenantId,
        'q01_codes': q01Codes,
        'q02_code': q02Code,
        'q04_code': q04Code,
        'q05_code': q05Code,
        'instrument_version': instrumentVersion,
        'routing_policy_version': routingPolicyVersion,
        'question_bank_version': questionBankVersion,
        'concept_version': conceptVersion,
        'm2_context_version': m2ContextVersion,
        'expected_revision': expectedRevision,
      };
}

/// Response mirrors the oracle's RoutePreview fields.
class RoutePreviewResponse {
  final String mode;
  final String assessmentId;
  final String instrumentVersion;
  final String routingPolicyVersion;
  final String connectionGroup;
  final String routeState;
  final String? nextQuestionId;
  final List<PreviewPermission> previewPermissions;
  final List<String> q10FeatureIds;
  final String packetDigest;
  final bool actualDisplayLogged;
  final bool productionFieldingAuthorized;
  final bool reportReleaseAuthorized;

  const RoutePreviewResponse({
    this.mode = 'SYNTHETIC_ONLY',
    required this.assessmentId,
    required this.instrumentVersion,
    required this.routingPolicyVersion,
    required this.connectionGroup,
    required this.routeState,
    required this.nextQuestionId,
    required this.previewPermissions,
    this.q10FeatureIds = const <String>[],
    required this.packetDigest,
    this.actualDisplayLogged = false,
    this.productionFieldingAuthorized = false,
    this.reportReleaseAuthorized = false,
  });

  PreviewPermission? permission(String itemId) {
    for (final p in previewPermissions) {
      if (p.itemId == itemId) return p;
    }
    return null;
  }

  /// Parses the FastAPI `RoutePreviewResponse` JSON contract.
  factory RoutePreviewResponse.fromJson(Map<String, Object?> json) {
    final perms = (json['preview_permissions'] as List<dynamic>? ?? <dynamic>[])
        .map((e) {
          final m = e as Map<String, Object?>;
          final raw = m['state'] as String? ?? 'BLOCKED';
          final state = RouteItemState.values.firstWhere(
            (s) => routeItemStateName(s) == raw,
            orElse: () => RouteItemState.blocked,
          );
          return PreviewPermission(
            itemId: m['item_id'] as String? ?? '',
            state: state,
            reason: m['reason'] as String? ?? '',
          );
        })
        .toList();
    return RoutePreviewResponse(
      assessmentId: json['assessment_id'] as String? ?? '',
      instrumentVersion: json['instrument_version'] as String? ?? kInstrumentVersion,
      routingPolicyVersion:
          json['routing_policy_version'] as String? ?? kRoutingPolicyVersion,
      connectionGroup: json['connection_group'] as String? ?? '',
      routeState: json['route_state'] as String? ?? '',
      nextQuestionId: json['next_question_id'] as String?,
      previewPermissions: perms,
      q10FeatureIds: (json['q10_feature_ids'] as List<dynamic>? ?? <dynamic>[])
          .map((e) => e as String)
          .toList(),
      packetDigest: json['packet_digest'] as String? ?? '',
      actualDisplayLogged: json['actual_display_logged'] as bool? ?? false,
      productionFieldingAuthorized:
          json['production_fielding_authorized'] as bool? ?? false,
      reportReleaseAuthorized: json['report_release_authorized'] as bool? ?? false,
    );
  }
}
