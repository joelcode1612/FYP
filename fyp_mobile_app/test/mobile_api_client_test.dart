import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/core/config/mobile_endpoints.dart';
import 'package:fyp/data/repositories/mobile_api_client.dart';
import 'package:shared_logic/shared_logic.dart';

/// Transport-level failure classification for [MobileApiClient].
///
/// The Priority-1 brief demands these states stay distinct: backend
/// unavailable (connection refused), unauthorized session (401), server
/// error (5xx), invalid response contract (non-JSON 2xx), and a successful
/// empty body. The client is exercised against a real loopback HTTP server
/// so the classification of genuine sockets — not mocks — is what is tested.
///
/// Run with the API base define pointing at the loopback port:
///   flutter test test/mobile_api_client_test.dart \
///     --dart-define=API_BASE_URL=http://127.0.0.1:8377
void main() {
  final base = Uri.parse(MobileEndpoints.apiBaseUrl);
  if (base.host != '127.0.0.1') {
    test(
      'skipped: MobileEndpoints.apiBaseUrl is not 127.0.0.1 in this build',
      () {},
      skip: 'compile with --dart-define=API_BASE_URL=http://127.0.0.1:<port>',
    );
    return;
  }

  HttpServer? server;
  MobileApiClient? client;

  /// The Authorization header of the most recent request, recorded by the
  /// single default listener.
  String? lastAuth;

  /// Per-path canned responses; a path without an entry answers 200 with
  /// the default payload.
  final handler = <String, (int, String)>{};

  Future<void> attach() async {
    server = await HttpServer.bind(base.host, base.port);
    server!.listen((req) async {
      lastAuth = req.headers.value('authorization');
      final entry =
          handler[req.uri.path] ?? (200, jsonEncode({'data': {'ok': true}}));
      req.response.statusCode = entry.$1;
      req.response.headers.contentType = ContentType.json;
      req.response.write(entry.$2);
      await req.response.close();
    });
  }

  setUpAll(() async {
    await attach();
    client = MobileApiClient(bearer: () => 'test-token');
  });

  tearDownAll(() async {
    await server?.close(force: true);
  });

  group('MobileApiClient failure classification', () {
    test('attaches the bearer token and returns the decoded map', () async {
      lastAuth = null;
      final result = await client!.get('/probe');
      expect(result['data']['ok'], true);
      expect(lastAuth, 'Bearer test-token');
    });

    test('bare array payloads are wrapped', () async {
      handler['/array'] = (200, jsonEncode([1, 2]));
      final result = await client!.get('/array');
      expect(result['data'], [1, 2]);
    });

    test('empty 204-style body maps to an empty map', () async {
      handler['/empty'] = (200, '');
      final result = await client!.get('/empty');
      expect(result, isEmpty);
    });

    test('a non-JSON 2xx body is a ResponseFormatFailure', () async {
      handler['/malformed'] = (200, '<html>not json</html>');
      await expectLater(
        client!.get('/malformed'),
        throwsA(isA<ResponseFormatFailure>()),
      );
    });

    test('401 is an UnauthorizedFailure, not a connection problem', () async {
      handler['/secure'] = (
        401,
        jsonEncode({'detail': 'Authentication credentials were not provided.'}),
      );
      await expectLater(
        client!.get('/secure'),
        throwsA(isA<UnauthorizedFailure>()),
      );
    });

    test('404 carries the backend detail as a NotFoundFailure', () async {
      handler['/missing'] = (
        404,
        jsonEncode({
          'detail': {
            'code': 'property_not_found',
            'message': 'No published property with this id.',
          },
        }),
      );
      await expectLater(
        client!.get('/missing'),
        throwsA(
          isA<NotFoundFailure>().having(
            (f) => f.message,
            'message',
            'No published property with this id.',
          ),
        ),
      );
    });

    test('422 is a ValidationFailure', () async {
      handler['/invalid'] = (
        422,
        jsonEncode({'detail': 'radius_m must be one of [250, 500, 1000]'}),
      );
      await expectLater(
        client!.get('/invalid'),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('5xx is a ServiceFailure', () async {
      handler['/boom'] = (500, jsonEncode({'detail': 'database unavailable'}));
      await expectLater(
        client!.get('/boom'),
        throwsA(
          isA<ServiceFailure>().having(
            (f) => f.message,
            'message',
            'database unavailable',
          ),
        ),
      );
    });

    test('a refused connection is a NetworkFailure (backend unavailable)',
        () async {
      // Stop listening: the port exists but nothing accepts — the exact
      // "backend not running" condition the mobile app reports.
      await server!.close();
      try {
        await expectLater(
          client!.get('/probe'),
          throwsA(isA<NetworkFailure>()),
        );
      } finally {
        await attach();
      }
    });

    test('no session fails closed without performing a request', () async {
      final anonymous = MobileApiClient(bearer: () => null);
      await expectLater(
        anonymous.get('/anything'),
        throwsA(isA<UnauthorizedFailure>()),
      );
    });
  });
}
