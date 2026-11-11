/// Synthetic successor routing behaviour — dual population + frozen codes.
/// Host: `fyp_mobile_app` (pure Dart, no Riverpod).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:fyp/cq_successor/route_contract.dart';
import 'package:fyp/cq_successor/route_outcome.dart';
import 'package:fyp/cq_successor/route_port.dart';
import 'package:fyp/cq_successor/route_snapshot.dart';
import 'package:fyp/cq_successor/successor_runtime.dart';

RoutePreviewRequest req({
  List<String> q01 = const [],
  String? q02,
  String? q04,
  String? q05,
}) =>
    RoutePreviewRequest(
      assessmentId: 'SYN-ASSESSMENT',
      tenantId: 'SYN-TENANT',
      q01Codes: q01,
      q02Code: q02,
      q04Code: q04,
      q05Code: q05,
    );

RouteSnapshot snapshotOf(RouteOutcome outcome) {
  expect(outcome, isA<RouteAvailable>());
  return (outcome as RouteAvailable).snapshot;
}

PreviewPermission perm(RouteOutcome outcome, String id) =>
    snapshotOf(outcome).permissions.firstWhere((p) => p.itemId == id);

void main() {
  const port = SyntheticRoutePort();

  group('Q01 classifications', () {
    test('historical CURRENT_CONNECTION still works', () async {
      final r = await port.preview(req(q01: const ['WORK'], q02: 'DAYS_1_3', q04: 'ONE'));
      expect(snapshotOf(r).connectionGroup, 'CURRENT_CONNECTION');
      expect(perm(r, 'Q08').state, RouteItemState.eligibleToShow);
    });

    test('NO_CURRENT_CONNECTION is a separate group, never a route exit', () async {
      final r = await port.preview(req(q01: const [kQ01NoCurrentConnection], q02: 'NONE'));
      expect(snapshotOf(r).connectionGroup, 'NO_CURRENT_CONNECTION');
      expect(snapshotOf(r).routeState, 'IN_PROGRESS');
      expect(perm(r, 'Q04').state, RouteItemState.eligibleToShow);
    });

    test('LIVE + NEVER is invalid', () async {
      final r = await port.preview(req(q01: const ['LIVE', 'NEVER'], q02: 'DAYS_1_3'));
      expect(snapshotOf(r).connectionGroup, 'INVALID_CONFLICT');
      expect(snapshotOf(r).routeState, 'VALIDATION_REQUIRED');
      expect(perm(r, 'Q03').state, RouteItemState.blocked);
    });

    test('duplicate Q01 codes invalid', () async {
      final r = await port.preview(req(q01: const ['LIVE', 'LIVE'], q02: 'DAYS_1_3'));
      expect(snapshotOf(r).connectionGroup, 'INVALID_DUPLICATE');
    });

    test('legacy codes never recoded', () async {
      for (final code in kQ01LegacyFrequencyCodes) {
        final r = await port.preview(req(q01: [code], q02: 'DAYS_1_3'));
        expect(snapshotOf(r).connectionGroup, 'HISTORICAL_AMBIGUOUS');
      }
    });

    test('unknown Q01 code rejected', () async {
      final r = await port.preview(req(q01: const ['MADE_UP'], q02: 'DAYS_1_3'));
      expect(snapshotOf(r).connectionGroup, 'INVALID_CODE');
    });
  });

  group('D02 x D08 composite', () {
    test('NO_CURRENT_CONNECTION + Q02 NONE + Q04 ZERO', () async {
      final r = await port.preview(req(
        q01: const [kQ01NoCurrentConnection],
        q02: 'NONE',
        q04: 'ZERO',
      ));
      final s = snapshotOf(r);
      expect(s.connectionGroup, 'NO_CURRENT_CONNECTION');
      expect(s.routeState, 'IN_PROGRESS');
      expect(perm(r, 'Q08').state, RouteItemState.notShown);
      expect(perm(r, 'Q08').reason, 'Q04_NOT_SUBSTANTIVE_NONZERO');
      expect(perm(r, 'Q05').state, RouteItemState.eligibleToShow);
      expect(perm(r, 'Q02').state, RouteItemState.eligibleToShow);
      expect(perm(r, 'Q04').state, RouteItemState.eligibleToShow);
    });

    test('Q02 zero days never terminates', () async {
      final r = await port.preview(req(q01: const ['LIVE'], q02: 'NONE', q04: 'ZERO'));
      expect(snapshotOf(r).routeState, 'IN_PROGRESS');
      expect(perm(r, 'Q04').state, RouteItemState.eligibleToShow);
    });

    test('Q04 CANNOT_REMEMBER withholds Q08 only', () async {
      final r = await port.preview(req(q01: const ['LIVE'], q02: 'DAYS_1_3', q04: 'CANNOT_REMEMBER'));
      expect(perm(r, 'Q08').state, RouteItemState.notShown);
      expect(perm(r, 'Q05').state, RouteItemState.eligibleToShow);
      expect(perm(r, 'Q04').state, RouteItemState.eligibleToShow);
    });

    test('negative Q05 is not a route exit', () async {
      final a = await port.preview(req(q01: const ['LIVE'], q02: 'DAYS_1_3', q05: 'DEF_NO'));
      final b = await port.preview(req(q01: const ['LIVE'], q02: 'DAYS_1_3', q05: 'DEF_YES'));
      expect(snapshotOf(a).packetDigest, snapshotOf(b).packetDigest);
    });
  });

  group('scientific gates and frozen codes', () {
    test('Q09/Q10 always NOT_SHOWN', () async {
      final r = await port.preview(req(q01: const ['LIVE'], q02: 'DAYS_1_3', q04: 'ONE'));
      expect(perm(r, 'Q09').state, RouteItemState.notShown);
      expect(perm(r, 'Q09').reason, 'SCIENTIFIC_GATE_UNAPPROVED');
      expect(perm(r, 'Q10').state, RouteItemState.notShown);
      expect(perm(r, 'Q10').reason, 'SCIENTIFIC_GATE_UNAPPROVED');
    });

    test('NOT_SHOWN distinct from refused/invalid', () async {
      final r = await port.preview(req(q01: const ['LIVE'], q02: 'DAYS_1_3', q04: 'ZERO'));
      final p = perm(r, 'Q08');
      expect(p.state, RouteItemState.notShown);
      expect(p.state, isNot(RouteItemState.blocked));
      expect(p.reason.toUpperCase().contains('REFUSED'), isFalse);
    });

    test('all 13 Q01-Q13 IDs preserved exactly', () async {
      final r = await port.preview(req(q01: const ['LIVE'], q02: 'DAYS_1_3'));
      final ids = snapshotOf(r).permissions.map((p) => p.itemId).toList();
      expect(ids, kQuestionIds);
      expect(ids.length, 13);
    });

    test('six frozen affiliation codes intact', () {
      expect(kQ01AffiliationCodes.length, 6);
      expect(kQ01AffiliationCodes.containsAll(const [
        'LIVE', 'WORK', 'STUDY', 'RUN_BUSINESS', 'VISIT_PURPOSE', 'PASS_THROUGH',
      ]), isTrue);
    });

    test('NO_CURRENT_CONNECTION is not injected into the frozen bank', () {
      expect(kQ01AffiliationCodes.contains(kQ01NoCurrentConnection), isFalse);
      expect(kQ01LegacyFrequencyCodes.contains('RARELY'), isTrue);
      expect(kQ01LegacyFrequencyCodes.contains('NEVER'), isTrue);
      expect(kQ01LegacyFrequencyCodes.contains('NOT_SURE'), isTrue);
    });
  });

  group('authorization flags on every response', () {
    test('no production fielding or report release is ever implied', () async {
      final r = snapshotOf(await port.preview(req(q01: const ['LIVE'], q02: 'DAYS_1_3')));
      expect(r.renderable, isFalse);
      expect(r.runtimeType.toString(), isNotEmpty);
    });
  });

  group('runtime helpers', () {
    test('renderablePermissions filters to eligible only', () async {
      final r = await port.preview(req(q01: const ['LIVE'], q02: 'DAYS_1_3', q04: 'ONE'));
      final eligible = renderablePermissions(r);
      expect(eligible.every((p) => p.state == RouteItemState.eligibleToShow), isTrue);
      expect(eligible.any((p) => p.itemId == 'Q09'), isFalse);
    });
  });
}