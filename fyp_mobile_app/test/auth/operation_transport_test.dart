import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/data/repositories/mobile_api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  for (final status in [409, 429, 503]) {
    test(
      'HTTP $status retains safe operation code and never retries a write',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        var calls = 0;
        server.listen((request) async {
          calls++;
          await request.drain<void>();
          request.response.statusCode = status;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'detail': {
                'code': 'SOURCE_STALE',
                'message': 'Reload saved source.',
              },
            }),
          );
          await request.response.close();
        });
        final client = MobileApiClient(
          bearer: () => 'synthetic-local-token',
          baseUrl: 'http://127.0.0.1:${server.port}',
        );
        try {
          await client.post('/test-operation', {'request_id': 'same-request'});
          fail('Expected refusal');
        } on AppFailure catch (e) {
          expect(e.statusCode, status);
          expect(e.backendCode, 'SOURCE_STALE');
          expect(e.outcomeUnknown, false);
          if (status == 409) expect(e, isA<ConflictFailure>());
          if (status == 429) expect(e, isA<ThrottledFailure>());
          if (status == 503) expect(e, isA<ServiceFailure>());
        }
        expect(calls, 1);
      },
    );
  }
  test(
    'body-stream timeout is bounded and marks uncertain POST without replay',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var calls = 0;
      server.listen((request) async {
        calls++;
        try {
          await request.drain<void>();
          request.response.headers.contentType = ContentType.json;
          request.response.write('{');
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 300));
          request.response.write('}');
          await request.response.close();
        } catch (_) {
          /* Expected client abort after its budget. */
        }
      });
      final client = MobileApiClient(
        bearer: () => 'synthetic-local-token',
        baseUrl: 'http://127.0.0.1:${server.port}',
        requestTimeout: const Duration(milliseconds: 100),
      );
      final clock = Stopwatch()..start();
      await expectLater(
        client.post('/test-operation', {'request_id': 'same-request'}),
        throwsA(
          isA<NetworkFailure>().having(
            (e) => e.outcomeUnknown,
            'unknown write outcome',
            true,
          ),
        ),
      );
      expect(clock.elapsedMilliseconds, lessThan(2000));
      expect(calls, 1);
    },
  );
}
