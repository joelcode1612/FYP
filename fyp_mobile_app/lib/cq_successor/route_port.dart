/// Typed backend port and its synthetic-only implementations.
///
/// DEFAULT = fail closed. There is NO silent fallback to permissive
/// `MockRouting`. Importing `lib/model/mock_routing.dart` is forbidden here.
library;

import 'route_contract.dart';
import 'route_outcome.dart';
import 'route_snapshot.dart';

abstract interface class RoutePreviewPort {
  Future<RouteOutcome> preview(RoutePreviewRequest request);
}

/// Fail-closed implementation. This is the DEFAULT provider.
class UnavailableRoutePort implements RoutePreviewPort {
  const UnavailableRoutePort();

  @override
  Future<RouteOutcome> preview(RoutePreviewRequest request) async =>
      const RouteUnavailable('Temporarily unavailable');
}

/// Deterministic in-memory successor implementation for synthetic/review mode.
/// It supports BOTH populations and preserves all Q01–Q13 IDs and CUST03 codes.
class SyntheticRoutePort implements RoutePreviewPort {
  const SyntheticRoutePort();

  String _classify(List<String> codes) {
    if (codes.isEmpty) return 'PENDING';
    if (codes.toSet().length != codes.length) return 'INVALID_DUPLICATE';
    final known = <String>{
      ...kQ01AffiliationCodes,
      ...kQ01LegacyFrequencyCodes,
      kQ01NoCurrentConnection,
    };
    if (codes.any((c) => !known.contains(c))) return 'INVALID_CODE';
    final aff = codes.where(kQ01AffiliationCodes.contains).toList();
    final legacy = codes.where(kQ01LegacyFrequencyCodes.contains).toList();
    final hasNew = codes.contains(kQ01NoCurrentConnection);
    if ((aff.isNotEmpty && legacy.isNotEmpty) || (aff.isNotEmpty && hasNew)) {
      return 'INVALID_CONFLICT';
    }
    if (aff.isNotEmpty) return 'CURRENT_CONNECTION';
    if (hasNew && legacy.isEmpty) return 'NO_CURRENT_CONNECTION';
    if (hasNew && legacy.isNotEmpty) return 'HISTORICAL_AMBIGUOUS';
    if (legacy.isNotEmpty) {
      return codes.length == 1 ? 'HISTORICAL_AMBIGUOUS' : 'CONNECTION_UNCERTAIN';
    }
    return 'CONNECTION_UNCERTAIN';
  }

  @override
  Future<RouteOutcome> preview(RoutePreviewRequest request) async {
    // Version mismatch always fails closed, server-authoritative semantics.
    if (!request.versionsMatchCurrent) {
      return const RouteRejected('VERSION_MISMATCH');
    }
    if (request.q01Codes.isNotEmpty &&
        request.q01Codes.any((c) => c == 'FORBIDDEN_TENANT')) {
      return const RouteRejected('UNAUTHORIZED');
    }

    final group = _classify(request.q01Codes);
    final states = <String, PreviewPermission>{
      for (final id in kQuestionIds)
        id: PreviewPermission(
          itemId: id,
          state: RouteItemState.blocked,
          reason: 'UNSET',
        ),
    };

    void put(String id, RouteItemState s, String r) =>
        states[id] = PreviewPermission(itemId: id, state: s, reason: r);

    if (group.startsWith('INVALID')) {
      for (final id in kQuestionIds.skip(2)) {
        put(id, RouteItemState.blocked, 'Q01_INVALID_REQUIRES_CORRECTION');
      }
      return RouteAvailable(_snapshot(request, 'VALIDATION_REQUIRED', group, states));
    }

    put('Q01', RouteItemState.eligibleToShow,
        'AREA_AFFILIATION_OR_EXPLICIT_NO_CONNECTION');
    put('Q02', RouteItemState.eligibleToShow,
        'FOUR_WEEK_DISTINCT_DAYS_NO_ELIGIBILITY_THRESHOLD');

    if (request.q02Code == null) {
      for (final id in kQuestionIds.skip(2)) {
        put(id, RouteItemState.pendingDependency, 'WAIT_FOR_Q02_SCREENING_ANSWER');
      }
      return RouteAvailable(_snapshot(request, 'IN_PROGRESS', group, states));
    }

    put('Q04', RouteItemState.eligibleToShow, 'ELIGIBLE_FOR_PAST_BEHAVIOR_ITEM');
    put('Q03', RouteItemState.eligibleToShow, 'APPROVED_HYPOTHETICAL_ORIGIN_STIMULUS_FIXTURE');
    put('Q05', RouteItemState.eligibleToShow, 'APPROVED_FUTURE_INTENT_STIMULUS_FIXTURE');
    put('Q06', RouteItemState.notShown, 'MENU_OR_CONCEPT_STIMULUS_MISSING');
    put('Q07', RouteItemState.notShown, 'APPROVED_EXACT_OFFER_MISSING');

    // Q04 ZERO / CANNOT_REMEMBER / refusal withholds Q08 ONLY.
    final q04 = request.q04Code;
    if (q04 == null) {
      put('Q08', RouteItemState.pendingDependency, 'WAIT_FOR_Q04_ANSWER');
    } else if (const <String>{'ONE', 'TWO_THREE', 'FOUR_SEVEN', 'EIGHT_PLUS'}
        .contains(q04)) {
      put('Q08', RouteItemState.eligibleToShow, 'PAST_SUBSTANTIVE_NONZERO_Q04');
    } else {
      put('Q08', RouteItemState.notShown, 'Q04_NOT_SUBSTANTIVE_NONZERO');
    }

    // Scientific gates stay DISABLED.
    put('Q09', RouteItemState.notShown, 'SCIENTIFIC_GATE_UNAPPROVED');
    put('Q10', RouteItemState.notShown, 'SCIENTIFIC_GATE_UNAPPROVED');
    for (final id in const <String>['Q11', 'Q12', 'Q13']) {
      put(id, RouteItemState.notShown, 'OPTIONAL_CONTEXT_DISABLED');
    }

    return RouteAvailable(_snapshot(request, 'IN_PROGRESS', group, states));
  }

  RouteSnapshot _snapshot(
    RoutePreviewRequest request,
    String routeState,
    String group,
    Map<String, PreviewPermission> states,
  ) {
    final permissions = <PreviewPermission>[
      for (final id in kQuestionIds) states[id]!,
    ];
    final eligible = permissions
        .where((p) => p.state == RouteItemState.eligibleToShow)
        .map((p) => p.itemId)
        .toList();
    final next = eligible.isEmpty ? null : eligible.first;
    return RouteSnapshot(
      instrumentVersion: request.instrumentVersion,
      routingPolicyVersion: request.routingPolicyVersion,
      questionBankVersion: request.questionBankVersion,
      conceptVersion: request.conceptVersion,
      m2ContextVersion: request.m2ContextVersion,
      expectedRevision: request.expectedRevision,
      packetDigest: 'SYN-${request.assessmentId}-${permissions.length}-$routeState',
      connectionGroup: group,
      routeState: routeState,
      nextQuestionId: next,
      permissions: permissions,
    );
  }
}
