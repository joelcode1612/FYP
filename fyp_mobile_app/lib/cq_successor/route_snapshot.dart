/// Cached route snapshot — PROVENANCE ONLY.
///
/// This object exists for version/digest comparison and stale-write detection.
/// It must NEVER be surfaced as a route, rendered as items, or used to recover
/// `ELIGIBLE_TO_SHOW` permissions when the backend is unavailable.
library;

import 'route_contract.dart';

class RouteSnapshot {
  final String instrumentVersion;
  final String routingPolicyVersion;
  final String questionBankVersion;
  final String conceptVersion;
  final String m2ContextVersion;
  final int expectedRevision;
  final String packetDigest;
  final String connectionGroup;
  final String routeState;
  final String? nextQuestionId;
  final List<PreviewPermission> permissions;

  const RouteSnapshot({
    required this.instrumentVersion,
    required this.routingPolicyVersion,
    required this.questionBankVersion,
    required this.conceptVersion,
    required this.m2ContextVersion,
    required this.expectedRevision,
    required this.packetDigest,
    required this.connectionGroup,
    required this.routeState,
    required this.nextQuestionId,
    required this.permissions,
  });

  /// Deliberately ALWAYS false. A cached snapshot is not an authorization to
  /// render. Rendering is gated strictly on `RouteAvailable`.
  bool get renderable => false;

  bool get versionsMatchCurrent =>
      instrumentVersion == kInstrumentVersion &&
      routingPolicyVersion == kRoutingPolicyVersion &&
      questionBankVersion == kQuestionBankVersion &&
      conceptVersion == kConceptVersion &&
      m2ContextVersion == kM2ContextVersion;
}
