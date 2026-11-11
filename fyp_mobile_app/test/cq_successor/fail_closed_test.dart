/// D27a — CRITICAL fail-closed fixture (host: `fyp_mobile_app`).
///
/// Bound to FLUTTER_API_PASS: backend/router absent → fail closed, even with a
/// still-valid cached RouteSnapshot. NEVER a silent fallback to MockRouting.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fyp/cq_successor/route_contract.dart';
import 'package:fyp/cq_successor/route_outcome.dart';
import 'package:fyp/cq_successor/route_port.dart';
import 'package:fyp/cq_successor/route_snapshot.dart';
import 'package:fyp/cq_successor/successor_flags.dart';
import 'package:fyp/cq_successor/successor_runtime.dart';

RouteSnapshot validSnapshot() => RouteSnapshot(
      instrumentVersion: kInstrumentVersion,
      routingPolicyVersion: kRoutingPolicyVersion,
      questionBankVersion: kQuestionBankVersion,
      conceptVersion: kConceptVersion,
      m2ContextVersion: kM2ContextVersion,
      expectedRevision: 3,
      packetDigest: 'SYN-VALID-CACHED-DIGEST',
      connectionGroup: 'NO_CURRENT_CONNECTION',
      routeState: 'IN_PROGRESS',
      nextQuestionId: 'Q05',
      permissions: [
        for (final id in kQuestionIds)
          PreviewPermission(
            itemId: id,
            state: id == 'Q05'
                ? RouteItemState.eligibleToShow
                : RouteItemState.notShown,
            reason: 'CACHED_FROM_PRIOR_SESSION',
          ),
      ],
    );

void main() {
  group('D27a — fail closed with cached RouteSnapshot', () {
    test('a valid cached snapshot is provenance-only and never renderable', () {
      final snapshot = validSnapshot();
      expect(snapshot.versionsMatchCurrent, isTrue);
      expect(snapshot.renderable, isFalse);
      expect(snapshot.packetDigest, isNotEmpty);
      expect(snapshot.permissions.length, 13);
    });

    test('default runtime is Unavailable even when a snapshot was cached', () async {
      final cached = validSnapshot();
      expect(cached.renderable, isFalse);

      const runtime = SuccessorRuntime(); // default = UnavailableRoutePort
      final outcome = await runtime.evaluate(const RoutePreviewRequest(
        assessmentId: 'SYN-ASSESSMENT',
        tenantId: 'SYN-TENANT',
      ));

      expect(outcome, isA<RouteUnavailable>());
      expect(outcome.isRenderable, isFalse);
      expect(outcome.permissions, isEmpty);
      expect(renderablePermissions(outcome), isEmpty);
      final message = (outcome as RouteUnavailable).genericReason;
      expect(message, 'Temporarily unavailable');
      expect(message.contains('VERSION'), isFalse);
      expect(message.contains('SYN-'), isFalse);
    });

    test('Available -> Unavailable drops all rendered content', () async {
      const synthetic = SyntheticRoutePort();
      final available = await synthetic.preview(const RoutePreviewRequest(
        assessmentId: 'SYN-ASSESSMENT',
        tenantId: 'SYN-TENANT',
        q01Codes: [kQ01NoCurrentConnection],
        q02Code: 'NONE',
        q04Code: 'ZERO',
      ));
      expect(available, isA<RouteAvailable>());
      expect(available.isRenderable, isTrue);
      expect(renderablePermissions(available), isNotEmpty);

      const unavailable = UnavailableRoutePort();
      final after = await unavailable.preview(const RoutePreviewRequest(
        assessmentId: 'SYN-ASSESSMENT',
        tenantId: 'SYN-TENANT',
      ));
      expect(after, isA<RouteUnavailable>());
      expect(after.isRenderable, isFalse);
      expect(renderablePermissions(after), isEmpty);
    });

    test('no code path in lib/cq_successor imports or calls MockRouting', () {
      final dir = Directory('lib/cq_successor');
      expect(dir.existsSync(), isTrue);
      final files = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      expect(files.length, greaterThanOrEqualTo(5));
      for (final f in files) {
        // Strip line/doc comments: a prohibition written in a comment is not a
        // code reference. Only executable code may be checked.
        final code = f
            .readAsStringSync()
            .split('\n')
            .where((line) => !line.trimLeft().startsWith('//'))
            .join('\n');
        expect(code.contains('MockRouting'), isFalse,
            reason: '${f.path} must not reference MockRouting in code');
        expect(code.contains('mock_routing.dart'), isFalse,
            reason: '${f.path} must not import mock_routing.dart');
      }
    });

    test('stale-version cached snapshot never becomes Available', () {
      final stale = RouteSnapshot(
        instrumentVersion: kInstrumentVersion,
        routingPolicyVersion: 'STALE-V0',
        questionBankVersion: kQuestionBankVersion,
        conceptVersion: kConceptVersion,
        m2ContextVersion: kM2ContextVersion,
        expectedRevision: 3,
        packetDigest: 'SYN-STALE',
        connectionGroup: 'CURRENT_CONNECTION',
        routeState: 'IN_PROGRESS',
        nextQuestionId: 'Q05',
        permissions: const [],
      );
      expect(stale.versionsMatchCurrent, isFalse);
      expect(stale.renderable, isFalse);
    });

    test('version mismatch yields RouteRejected, never RouteAvailable', () async {
      const port = SyntheticRoutePort();
      final rejected = await port.preview(const RoutePreviewRequest(
        assessmentId: 'SYN-ASSESSMENT',
        tenantId: 'SYN-TENANT',
        conceptVersion: 'STALE-V0',
      ));
      expect(rejected, isA<RouteRejected>());
      expect(rejected.isRenderable, isFalse);
      expect(renderablePermissions(rejected), isEmpty);
    });

    test('default runtime port is UnavailableRoutePort (fail closed)', () async {
      const runtime = SuccessorRuntime();
      expect(runtime.port, isA<UnavailableRoutePort>());
      final outcome = await runtime.evaluate(const RoutePreviewRequest(
        assessmentId: 'SYN-ASSESSMENT',
        tenantId: 'SYN-TENANT',
      ));
      expect(outcome, isA<RouteUnavailable>());
      expect(renderablePermissions(outcome), isEmpty);
    });
  });

  group('Successor flags — all gates disabled by default', () {
    test('default flags are all safe', () {
      const f = SuccessorFlags();
      expect(f.syntheticMode, isFalse);
      expect(f.serverAuthoritativeRouting, isFalse);
      expect(f.historicalDemoToggle, isFalse);
      expect(f.q09Q10ScientificGatesApproved, isFalse);
      expect(f.bilingualApproved, isFalse);
      expect(f.productionFieldingAuthorized, isFalse);
      expect(f.reportReleaseAuthorized, isFalse);
    });

    test('synthetic review profile enables no approvals', () {
      const f = SuccessorFlags.syntheticReview();
      expect(f.syntheticMode, isTrue);
      expect(f.serverAuthoritativeRouting, isFalse);
      expect(f.q09Q10ScientificGatesApproved, isFalse);
      expect(f.bilingualApproved, isFalse);
      expect(f.productionFieldingAuthorized, isFalse);
    });
  });
}