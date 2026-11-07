import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jaspr_test/jaspr_test.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:sitewise_jaspr_web/data/staff_guard.dart';

/// F4 regression: the SSR staff guard must authorize /admin and /agent from the
/// backend-verified bearer token (active + staff role + aal2), never from the
/// unsigned session cookie, and must fail closed.
const backendOrigin = 'http://127.0.0.1:8000';

shelf.Request req(String path, {String? cookie}) => shelf.Request(
  'GET',
  Uri.parse('http://localhost$path'),
  headers: cookie == null ? const {} : {'cookie': cookie},
);

String sessionValue(Map<String, dynamic> profile) =>
    base64Url.encode(utf8.encode(jsonEncode(profile))).replaceAll('=', '');

Map<String, dynamic> decodeSession(String cookieHeader) {
  final part = cookieHeader
      .split(';')
      .map((s) => s.trim())
      .firstWhere((s) => s.startsWith('sitewise_session='));
  final value = part.substring('sitewise_session='.length);
  return jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(value))))
      as Map<String, dynamic>;
}

/// A stub backend that records every call and answers with [identity].
({http.Client client, List<http.Request> calls}) stubBackend({
  Map<String, dynamic>? identity,
  int status = 200,
  bool unreachable = false,
}) {
  final calls = <http.Request>[];
  final client = MockClient((request) async {
    calls.add(request);
    if (unreachable) throw Exception('backend unreachable');
    return http.Response(
      jsonEncode(identity ?? const {}),
      status,
      headers: {'content-type': 'application/json'},
    );
  });
  return (client: client, calls: calls);
}

Map<String, dynamic> identity({
  String role = 'admin',
  String status = 'active',
  String? aal = 'aal2',
}) => {
  'user_id': 'u-verified',
  'email': 'staff@sitewise.my',
  'full_name': 'Verified Staff',
  'role': role,
  'account_status': status,
  'assurance_level': aal,
};

void main() {
  // Runs the guard with a stub backend and a capturing inner handler.
  Future<({shelf.Response response, shelf.Request? rendered, List<http.Request> calls})>
  run(
    shelf.Request request, {
    Map<String, dynamic>? id,
    int status = 200,
    bool unreachable = false,
  }) async {
    final stub = stubBackend(identity: id, status: status, unreachable: unreachable);
    shelf.Request? captured;
    final handler = createStaffGuard(
      Uri.parse(backendOrigin),
      client: stub.client,
    )((r) async {
      captured = r;
      return shelf.Response.ok('RENDERED');
    });
    final response = await handler(request);
    return (response: response, rendered: captured, calls: stub.calls);
  }

  group('createStaffGuard passthrough', () {
    test('non-staff workspace is not guarded and never calls the backend', () async {
      final forged = 'sitewise_session=${sessionValue({'role': 'entrepreneur'})}';
      final r = await run(req('/entrepreneur/explore', cookie: forged));
      expect(r.rendered, isNotNull);
      expect(r.calls, isEmpty);
      expect(await r.response.readAsString(), 'RENDERED');
    });

    test('the /staff/verify screen is not guarded (no redirect loop)', () async {
      final r = await run(req('/staff/verify'));
      expect(r.rendered, isNotNull);
      expect(r.calls, isEmpty);
    });
  });

  group('createStaffGuard fail-closed', () {
    test('forged admin cookie WITHOUT a token is rejected', () async {
      final forged = 'sitewise_session=${sessionValue({'role': 'admin'})}';
      final r = await run(req('/admin', cookie: forged));
      expect(r.response.statusCode, 302);
      expect(r.response.headers['location'], '/login?next=http%3A%2F%2Flocalhost%2Fadmin');
      expect(r.rendered, isNull);
      expect(r.calls, isEmpty, reason: 'no token means no backend call');
    });

    test('backend 401 fails closed to sign-in', () async {
      final r = await run(
        req('/admin', cookie: 'sitewise_token=bad'),
        status: 401,
      );
      expect(r.response.statusCode, 302);
      expect(r.response.headers['location'], startsWith('/login?next='));
      expect(r.rendered, isNull);
    });

    test('unreachable backend fails closed to sign-in', () async {
      final r = await run(
        req('/admin', cookie: 'sitewise_token=abc'),
        unreachable: true,
      );
      expect(r.response.statusCode, 302);
      expect(r.response.headers['location'], startsWith('/login?next='));
      expect(r.rendered, isNull);
    });

    test('suspended staff is rejected even at aal2', () async {
      final r = await run(
        req('/admin', cookie: 'sitewise_token=abc'),
        id: identity(status: 'suspended'),
      );
      expect(r.response.statusCode, 302);
      expect(r.response.headers['location'], startsWith('/login?next='));
      expect(r.rendered, isNull);
    });

    test('pending staff is rejected', () async {
      final r = await run(
        req('/admin', cookie: 'sitewise_token=abc'),
        id: identity(status: 'pending'),
      );
      expect(r.response.statusCode, 302);
      expect(r.rendered, isNull);
    });
  });

  group('createStaffGuard MFA assurance', () {
    test('staff aal1 is routed to /staff/verify', () async {
      final r = await run(
        req('/admin', cookie: 'sitewise_token=abc'),
        id: identity(aal: 'aal1'),
      );
      expect(r.response.statusCode, 302);
      expect(r.response.headers['location'], '/staff/verify');
      expect(r.rendered, isNull);
    });

    test('staff with no aal claim is routed to /staff/verify', () async {
      final r = await run(
        req('/admin', cookie: 'sitewise_token=abc'),
        id: identity(aal: null),
      );
      expect(r.response.statusCode, 302);
      expect(r.response.headers['location'], '/staff/verify');
    });

    test('a forged aal2 in the cookie is never trusted (backend aal1 wins)', () async {
      // The unsigned cookie claims admin; the token cookie has no aal field at
      // all. Assurance comes ONLY from the backend response, which says aal1.
      final forged =
          'sitewise_token=abc; sitewise_session=${sessionValue({'role': 'admin', 'aal': 'aal2'})}';
      final r = await run(req('/admin', cookie: forged), id: identity(aal: 'aal1'));
      expect(r.response.headers['location'], '/staff/verify');
      expect(r.rendered, isNull);
    });
  });

  group('createStaffGuard role enforcement', () {
    test('a verified non-staff account cannot open /admin', () async {
      final r = await run(
        req('/admin', cookie: 'sitewise_token=abc'),
        id: identity(role: 'entrepreneur'),
      );
      expect(r.response.statusCode, 302);
      expect(r.response.headers['location'], '/entrepreneur');
      expect(r.rendered, isNull);
    });

    test('forged admin cookie + entrepreneur token cannot escalate (F4 core)', () async {
      final forged =
          'sitewise_token=abc; sitewise_session=${sessionValue({'role': 'admin'})}';
      final r = await run(
        req('/admin', cookie: forged),
        id: identity(role: 'entrepreneur'),
      );
      // Backend truth (entrepreneur) overrides the forged admin cookie.
      expect(r.response.statusCode, 302);
      expect(r.response.headers['location'], '/entrepreneur');
      expect(r.rendered, isNull);
    });

    test('agent cannot open the admin workspace', () async {
      final r = await run(
        req('/admin', cookie: 'sitewise_token=abc'),
        id: identity(role: 'agent'),
      );
      expect(r.response.statusCode, 302);
      expect(r.response.headers['location'], '/agent');
    });
  });

  group('createStaffGuard verified admission', () {
    test('admin aal2 is admitted; cookie rewritten to the verified profile', () async {
      // Attacker-supplied cookie says entrepreneur; the backend verifies admin.
      final forged =
          'sitewise_token=abc; sitewise_session=${sessionValue({'role': 'entrepreneur'})}';
      final r = await run(req('/admin', cookie: forged), id: identity());
      expect(r.rendered, isNotNull);
      expect(r.response.statusCode, 200);
      // The backend was called with the bearer token at /auth/me.
      expect(r.calls, hasLength(1));
      expect(r.calls.single.url.path, '/api/v1/auth/me');
      expect(r.calls.single.headers['authorization'], 'Bearer abc');
      // The render isolate receives the SERVER-VERIFIED role, not the cookie.
      final profile = decodeSession(r.rendered!.headers['cookie']!);
      expect(profile['role'], 'admin');
      expect(profile['user_id'], 'u-verified');
    });

    test('agent aal2 is admitted on /agent with a verified agent cookie', () async {
      final r = await run(
        req('/agent/listings', cookie: 'sitewise_token=abc'),
        id: identity(role: 'agent'),
      );
      expect(r.rendered, isNotNull);
      expect(decodeSession(r.rendered!.headers['cookie']!)['role'], 'agent');
    });

    test('administrator aal2 may also act in the /agent workspace', () async {
      final r = await run(
        req('/agent', cookie: 'sitewise_token=abc'),
        id: identity(role: 'admin'),
      );
      expect(r.rendered, isNotNull);
      expect(decodeSession(r.rendered!.headers['cookie']!)['role'], 'admin');
    });

    test('legacy administrator is canonicalised to admin and admitted', () async {
      final r = await run(
        req('/admin', cookie: 'sitewise_token=abc'),
        id: identity(role: 'administrator'),
      );
      expect(r.rendered, isNotNull);
      expect(decodeSession(r.rendered!.headers['cookie']!)['role'], 'admin');
    });

    test('cookie rewrite preserves the token and unrelated cookies', () async {
      final cookie =
          'sitewise_token=abc; ui_state=xyz; sitewise_session=${sessionValue({'role': 'admin'})}';
      final r = await run(req('/admin', cookie: cookie), id: identity());
      final out = r.rendered!.headers['cookie']!;
      expect(out, contains('sitewise_token=abc'));
      expect(out, contains('ui_state=xyz'));
      expect(decodeSession(out)['role'], 'admin');
    });
  });
}