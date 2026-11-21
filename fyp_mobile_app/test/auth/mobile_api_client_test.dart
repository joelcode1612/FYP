// Run backend/tests/integration/run_cross_app.py --mobile for the private lab.
// Real mobile transport and JWT verification; fixture keys/SQLite only.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/core/config/mobile_endpoints.dart';
import 'package:fyp/data/repositories/mobile_api_client.dart';

void main() {
  group('actual mobile transport to private FastAPI', () {
    late MobileApiClient client;
    setUp(() {
      expect(MobileEndpoints.apiBaseUrl, Platform.environment['P1_HTTP_BASE']);
      client = MobileApiClient(bearer: () => Platform.environment['P1_HTTP_TOKEN']);
    });

    test('missing local session refuses the request', () async {
      final anonymous = MobileApiClient(bearer: () => null);
      await expectLater(anonymous.get('/api/v1/auth/me'), throwsA(isA<UnauthorizedFailure>()));
    });

    test('signed identity is verified through the actual auth/me endpoint', () async {
      final profile = await client.get('/api/v1/auth/me');
      expect(profile['user_id'], '00000000-0000-4000-8000-000000000001');
      expect(profile['role'], 'entrepreneur');
      expect(profile['account_status'], 'active');
    });

    test('mobile consumes actual saved confirmation and rejects stale source and wrong owner', () async {
      final mid = Platform.environment['P1_HTTP_M2_ASSESSMENT']!;
      final cid = Platform.environment['P1_HTTP_M2_CONFIRMATION']!;
      final data = await ApiConfirmedReviewRepository(client).read(assessmentId: mid, confirmationId: cid, revision: 1);
      expect(data.answers.single.displayValue, 'Private HTTP synthetic declaration.');
      expect(data.activity, hasLength(4));
      await expectLater(ApiConfirmedReviewRepository(client).read(assessmentId: mid, confirmationId: cid, revision: 0), throwsA(isA<AppFailure>()));
      final other = MobileApiClient(bearer: () => Platform.environment['P1_HTTP_OTHER_TOKEN']);
      await expectLater(ApiConfirmedReviewRepository(other).read(assessmentId: mid, confirmationId: cid, revision: 1), throwsA(isA<NotFoundFailure>()));
    }, skip: Platform.environment['P1_HTTP_M2_ASSESSMENT'] == null ? 'Pass --confirmed-review to the private lab.' : false);

    test('authenticated mobile reads the held Project1 contract', () async {
      final result = await ApiProject1ReadRepository(client).read(
        assessmentId: Platform.environment['P1_HTTP_ASSESSMENT'],
      );
      expect(result.review.code, 'M2_BINDING_REQUIRED');
      expect(result.questionnaire.code, 'QUESTIONNAIRE_AUTHORIZATION_REQUIRED');
      expect(result.report.code, 'REPORT_ADMISSION_REQUIRED');
    });

    test('another verified principal cannot read the workspace', () async {
      final other = MobileApiClient(bearer: () => Platform.environment['P1_HTTP_OTHER_TOKEN']);
      await expectLater(ApiProject1ReadRepository(other).read(
        assessmentId: Platform.environment['P1_HTTP_ASSESSMENT'],
      ), throwsA(isA<UnauthorizedFailure>()));
    });

    test('missing record is a typed failure without fixture fallback', () async {
      await expectLater(ApiProject1ReadRepository(client).read(
        assessmentId: '00000000-0000-4000-8000-999999999999',
      ), throwsA(isA<NotFoundFailure>()));
    });
  }, skip: Platform.environment['P1_HTTP_BASE'] == null
      ? 'Run the private FastAPI mobile HTTP lab.' : false);
}
