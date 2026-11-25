import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:jaspr_test/jaspr_test.dart';
import 'package:jaspr/jaspr.dart' show ValueKey;
import 'package:shared_logic/shared_logic.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/m2_workflow_panel.dart';
import 'package:sitewise_jaspr_web/core/di/app_locator.dart';

import 'm2_autosave_verification_test.dart' as fixture;

const cid = '00000000-0000-4000-8000-000000000004';
const rid = '00000000-0000-4000-8000-000000000005';

/// Synthetic transport for real component/repository tests, not live acceptance.
class ConfirmationClient extends fixture.SaveClient {
  bool confirmed = false;
  final postedBodies = <Map<String, dynamic>>[];
  Object? reviewFailure;
  Object? confirmFailure;
  bool invalidDigest = false;

  /// Models the readback race DD-134 fixed: the POST has committed, but the
  /// owner-scoped current-confirmation read keeps answering "none" because it
  /// has not caught up yet. Each read consumes one.
  int staleConfirmationReads = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path.endsWith('/confirmation-current')) {
      calls.add('GET $path');
      if (staleConfirmationReads > 0) {
        staleConfirmationReads--;
        throw const NotFoundFailure.response(
          'No confirmation yet',
          statusCode: 404,
        );
      }
      if (!confirmed) {
        throw const NotFoundFailure.response(
          'No confirmation',
          statusCode: 404,
        );
      }
      return {
        'id': cid,
        'assessment_id': fixture.mid,
        'assessment_revision': revision,
        'is_current': true,
      };
    }
    final result = await super.get(path, query: query);
    if (path.endsWith('/${fixture.mid}')) {
      (result['assessment'] as Map)['confirmed_revision'] = confirmed
          ? revision
          : null;
    }
    return result;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    calls.add('POST $path');
    postedBodies.add(Map.of(body));
    expect(body['expected_revision'], revision);
    if (path.endsWith('/review')) {
      if (reviewFailure != null) throw reviewFailure!;
      return {
        'id': rid,
        'assessment_id': fixture.mid,
        'assessment_revision': revision,
      };
    }
    if (path.endsWith('/confirm')) {
      if (confirmFailure != null) throw confirmFailure!;
      expect(body['acknowledged_issue_ids'], isEmpty);
      final snapshot = <String, dynamic>{
        'snapshot_contract_version': 'm2-confirmation/3',
        'confirmation_scope': 'M2_DECLARATIONS_ONLY',
        'assessment_id': fixture.mid,
        'assessment_revision': revision,
        'review_event_id': rid,
        'qj_handoff_authorized': false,
      };
      final digest = sha256
          .convert(utf8.encode(canonicalSourceJson(snapshot)))
          .toString();
      confirmed = true;
      return {
        'id': cid,
        'assessment_id': fixture.mid,
        'assessment_revision': revision,
        'snapshot_json': snapshot,
        'snapshot_digest': invalidDigest ? 'invalid' : digest,
      };
    }
    throw StateError('Unexpected mutation');
  }
}

void main() {
  test('confirmation revision uses the server integer fingerprint', () {
    final snapshot = <String, dynamic>{
      'assessment_revision': 11,
      'qj_handoff_authorized': false,
    };
    expect(sha256.convert(utf8.encode(canonicalConfirmationJson(snapshot))).toString(),
        '954add7a7d36a8e146d426480cea4c834178b31bdc4f6516639c01ca2a0599b3');
  });
  late ApiM2Repository original;
  late ConfirmationClient client;
  setUp(() {
    original = AppLocator.m2;
    client = ConfirmationClient();
    AppLocator.m2 = ApiM2Repository(client);
  });
  tearDown(() => AppLocator.m2 = original);

  const panel = M2WorkflowPanel(
    assessmentId: fixture.mid,
    requireExplicitId: true,
    embedded: true,
  );

  testComponents(
    'bound review and confirmation retain the marketplace identity',
    (tester) async {
      tester.pumpComponent(const M2WorkflowPanel(
        assessmentId: fixture.mid, requireExplicitId: true, embedded: true,
        marketplaceAssessmentId: fixture.iid,
      ));
      await tester.pump();
      await tester.click(find.ancestor(of: find.text('Review business declaration'), matching: find.tag('button')));
      await tester.pump();
      await tester.click(find.ancestor(of: find.text('Confirm business declaration'), matching: find.tag('button')));
      await tester.pump();
      expect(client.postedBodies.length, 2);
      expect(client.postedBodies.every((body) => body['marketplace_assessment_id'] == fixture.iid), isTrue);
    },
  );
  testComponents(
    'review and confirm use saved revision and never call BDJ; reload restores confirmation',
    (tester) async {
      tester.pumpComponent(panel);
      await tester.pump();
      expect(find.text('Saved M2 revision 1'), findsOneComponent);
      await tester.click(
        find.ancestor(
          of: find.text('Review business declaration'),
          matching: find.tag('button'),
        ),
      );
      await tester.pump();
      expect(find.text('TEST-01 · ANSWERED · A'), findsOneComponent);
      await tester.click(
        find.ancestor(
          of: find.text('Confirm business declaration'),
          matching: find.tag('button'),
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('Business declaration confirmed at revision 1.'),
        findsOneComponent,
      );
      expect(find.text('Confirm business declaration'), findsNothing);
      expect(client.calls.where((c) => c.startsWith('POST ')).toList(), [
        'POST /api/v1/m2/assessments/${fixture.mid}/review',
        'POST /api/v1/m2/assessments/${fixture.mid}/confirm',
      ]);
      expect(
        client.calls.any(
          (c) =>
              c.contains('bdj/evaluate') ||
              c.contains('business-understanding'),
        ),
        isFalse,
      );
      tester.pumpComponent(
        const M2WorkflowPanel(
          key: ValueKey('reopen'),
          assessmentId: fixture.mid,
          requireExplicitId: true,
          embedded: true,
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('This business declaration is confirmed.'),
        findsOneComponent,
      );
      expect(find.textContaining('Confirmation $cid'), findsOneComponent);
    },
  );

  final cases = <(String, Object, String)>[
    (
      'stale',
      const ConflictFailure(
        'private diagnostics',
        backendCode: 'M2_REVISION_STALE',
      ),
      'The saved revision or confirmation state changed.',
    ),
    (
      '401',
      const UnauthorizedFailure.response(
        'private diagnostics',
        statusCode: 401,
      ),
      'Your session has expired.',
    ),
    (
      '403',
      const UnauthorizedFailure.response(
        'private diagnostics',
        statusCode: 403,
      ),
      'This assessment is unavailable to your account.',
    ),
    (
      '422',
      const ValidationFailure.response('private diagnostics', statusCode: 422),
      'A declaration does not match',
    ),
    (
      'service',
      const ServiceFailure.response(
        'private diagnostics',
        statusCode: 503,
        backendCode: 'M2_SOURCE_UNAVAILABLE',
      ),
      'The confirmation service is unavailable.',
    ),
    (
      'network',
      const NetworkFailure.transport(
        'private diagnostics',
        outcomeUnknown: true,
      ),
      'The connection failed.',
    ),
    (
      'invalid response',
      const ResponseFormatFailure('private diagnostics'),
      'The service response could not be verified.',
    ),
  ];
  for (final (name, failure, message) in cases) {
    testComponents(
      'review $name preserves typed error; never confirms or leaks diagnostics',
      (tester) async {
        client.reviewFailure = failure;
        tester.pumpComponent(panel);
        await tester.pump();
        await tester.click(
          find.ancestor(
            of: find.text('Review business declaration'),
            matching: find.tag('button'),
          ),
        );
        await tester.pump();
        expect(find.textContaining(message), findsOneComponent);
        expect(find.textContaining('private diagnostics'), findsNothing);
        expect(
          client.calls.where(
            (c) => c.contains('/confirm') && c.startsWith('POST'),
          ),
          isEmpty,
        );
        expect(find.text('Confirm business declaration'), findsNothing);
      },
    );
  }

  testComponents(
    'post-200 invalid digest never reports success and prompts authoritative reload',
    (tester) async {
      client.invalidDigest = true;
      tester.pumpComponent(panel);
      await tester.pump();
      await tester.click(
        find.ancestor(
          of: find.text('Review business declaration'),
          matching: find.tag('button'),
        ),
      );
      await tester.pump();
      await tester.click(
        find.ancestor(
          of: find.text('Confirm business declaration'),
          matching: find.tag('button'),
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('The service response could not be verified.'),
        findsOneComponent,
      );
      expect(
        find.textContaining('Business declaration confirmed at revision'),
        findsNothing,
      );
    },
  );

  // DD-134. The opposite failure to the one above, and the one the owner hit:
  // the POST returns a receipt the client CAN verify, but the follow-up read
  // has not caught up. That used to be turned into
  // "The service response could not be verified. Reload saved confirmation
  // before retrying.", so the owner had to reload the browser to see a
  // confirmation the server had already committed.
  testComponents(
    'a verified receipt is not discarded when the readback has not caught up',
    (tester) async {
      tester.pumpComponent(panel);
      await tester.pump();
      await tester.click(
        find.ancestor(
          of: find.text('Review business declaration'),
          matching: find.tag('button'),
        ),
      );
      await tester.pump();
      // The confirmation commits, but every subsequent read answers "none".
      client.staleConfirmationReads = 999;
      await tester.click(
        find.ancestor(
          of: find.text('Confirm business declaration'),
          matching: find.tag('button'),
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('Business declaration confirmed at revision'),
        findsOneComponent,
      );
      expect(
        find.textContaining('The service response could not be verified.'),
        findsNothing,
      );
      // The owner is never told to reload, and the confirmation is never
      // reported as missing.
      expect(find.textContaining('Reload saved confirmation'), findsNothing);
      expect(find.textContaining('could not be re-read'), findsNothing);
    },
  );

  // DD-134 follow-up. `M2_ALREADY_CONFIRMED_OR_CHANGED` covers two different
  // situations -- "this revision is already confirmed" and "the revision moved".
  // Only the second needs a reload; telling the owner to reload when their
  // confirmation already succeeded is what made a successful confirm look like
  // a failure and invited the duplicate click that produced this refusal.
  testComponents(
    'a duplicate confirm reports the already-confirmed state, not a reload',
    (tester) async {
      tester.pumpComponent(panel);
      await tester.pump();
      await tester.click(
        find.ancestor(
          of: find.text('Review business declaration'),
          matching: find.tag('button'),
        ),
      );
      await tester.pump();
      // The server refuses because this revision is already confirmed, and the
      // current confirmation it returns agrees.
      client.confirmed = true;
      client.confirmFailure = const ConflictFailure(
        'private diagnostics',
        backendCode: 'M2_ALREADY_CONFIRMED_OR_CHANGED',
      );
      await tester.click(
        find.ancestor(
          of: find.text('Confirm business declaration'),
          matching: find.tag('button'),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.textContaining('is already confirmed, so nothing further'),
        findsOneComponent,
      );
      expect(find.textContaining('Reload saved declarations'), findsNothing);
      expect(find.textContaining('private diagnostics'), findsNothing);
    },
  );
}
