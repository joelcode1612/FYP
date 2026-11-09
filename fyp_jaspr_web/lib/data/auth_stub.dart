/// Server (VM) implementation of the auth/data bridge.
///
/// The browser build resolves `auth_browser.dart` instead — it drives the real
/// Supabase session through `web/auth_bundle.js`. This file exists for two
/// callers:
///
/// 1. **Server-side rendering.** The VM has no `sitewiseAuth` JS object, so the
///    SSR pass needs its own way to (a) know who the request belongs to and
///    (b) talk to the FastAPI backend. Both come from the request itself:
///    `installServerSession` decodes the two cookies the browser bridge keeps
///    in sync (`sitewise_session`, `sitewise_token`), and [WebAuth.request]
///    replays the access token to the API over `package:http`.
/// 2. **VM component tests**, where nothing is installed and every call fails
///    with the same explicit "not configured" signal as before.
///
/// Keeping the API surface identical to the browser implementation is what
/// lets pages, cubits and `AppLocator` stay platform-agnostic.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'api_config.dart';

/// Cookie names shared with `tool/auth_client.js`.
const String kSessionCookie = 'sitewise_session';
const String kTokenCookie = 'sitewise_token';

abstract final class WebAuth {
  static Map<String, dynamic>? _profile;
  static String? _token;
  static bool _server = false;

  /// True once [installServerSession] ran on this render (or forever false in
  /// VM tests). Supabase itself is never reached from the server: signing in,
  /// signing up and MFA all stay browser concerns.
  static bool get configured => _server;

  static Map<String, dynamic>? get profile => _profile;
  static String get error => 'The local authentication API is not configured.';
  static bool get mfaRequired => false;
  static bool get mfaEnrollmentRequired => false;
  static String? get mfaEnrollQr => null;
  static String? get mfaEnrollSecret => null;

  /// Reads the per-request identity off the cookies sent by the browser.
  ///
  /// Called once per render, from the server entry point, before the component
  /// tree is built. A missing or malformed cookie simply leaves the render
  /// anonymous — exactly what the router's guard expects for `/login`.
  static void installServerSession(Map<String, String> cookies) {
    _server = true;
    _token = cookies[kTokenCookie];
    _profile = null;
    final raw = cookies[kSessionCookie];
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = utf8.decode(base64Url.decode(base64Url.normalize(raw)));
      final value = jsonDecode(decoded);
      if (value is Map<String, dynamic>) _profile = value;
    } on Object {
      _profile = null;
    }
  }

  /// Origin of the intended FastAPI backend, shared with the same-origin
  /// `/api/*` proxy in `main.server.dart` (see `data/api_config.dart`).
  /// Configured once via `SITEWISE_API_BASE`; no port is duplicated here.
  static final Uri _base = kBackendApiBase;

  /// Loopback calls go direct; anything else honours the process proxy.
  ///
  /// A machine behind a corporate proxy otherwise answers `502` for a
  /// loopback API call, which would make every SSR page render its error
  /// state even though the API is running.
  static final http.Client _client = IOClient(
    HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = (uri) => uri.host == 'localhost' || uri.host == '127.0.0.1'
          ? 'DIRECT'
          : HttpClient.findProxyFromEnvironment(uri),
  );

  static Future<void> initialize() async {}

  static Future<void> google([bool remember = true]) async =>
      throw StateError(error);
  static Future<void> password(
    String email,
    String password, [
    bool remember = true,
    String? mfaCode,
    String? expectedPortal,
  ]) async => throw StateError(error);
  static Future<String> mfaChallengeStart() async => throw StateError(error);
  static Future<void> mfaChallengeVerify(String code) async =>
      throw StateError(error);
  static Future<void> mfaEnrollStart() async => throw StateError(error);
  static Future<void> mfaEnrollVerify(String code) async =>
      throw StateError(error);
  static Future<String> resetPassword(String email) async =>
      throw StateError(error);
  static Future<void> updatePassword(String password) async =>
      throw StateError(error);
  static Future<String> signup(
    String email,
    String password,
    String name,
  ) async => throw StateError(error);
  static Future<void> complete([String? next]) async => throw StateError(error);
  static Future<void> signout() async {}

  /// VM/tests: no invitation session exists, so there is never a notice to
  /// consume. The browser bridge returns the one-time password-set notice.
  static Map<String, dynamic>? consumePasswordNotice() => null;

  /// Performs the same JSON round-trip the browser bridge performs.
  ///
  /// Throws when the API is unreachable or answers non-2xx; the calling cubit
  /// turns that into its normal error state, so a stopped backend degrades the
  /// page instead of breaking the render.
  static Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    if (!_server) throw StateError(error);
    final response = await _send(path, method: method, body: body);
    if (response.statusCode >= 400) {
      throw StateError(
        '${response.statusCode} ${response.reasonPhrase ?? ''}'.trim(),
      );
    }
    return _decodeBody(response);
  }

  /// VM/SSR counterpart of the browser's `requestDetailed`: the failure is
  /// returned as data (`ok`, `status`, `code`, `message`) so a page can
  /// distinguish 404 from 401/403 from 5xx without catching and parsing a
  /// thrown string.
  static Future<Map<String, dynamic>> requestDetailed(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    if (!_server) {
      return {
        'ok': false,
        'status': null,
        'code': 'api_unavailable',
        'message': error,
      };
    }
    final http.Response response;
    try {
      response = await _send(path, method: method, body: body);
    } on Object catch (failure) {
      return {
        'ok': false,
        'status': null,
        'code': 'network_error',
        'message': 'The data service could not be reached: $failure',
      };
    }
    if (response.statusCode >= 400) {
      return {
        'ok': false,
        'status': response.statusCode,
        'code': _errorCode(response),
        'message':
            _errorMessage(response) ??
            response.reasonPhrase ??
            'Request failed.',
      };
    }
    return {'ok': true, 'body': _decodeBody(response)};
  }

  /// Split any query off the path: `Uri.replace(path:)` would percent-encode
  /// the '?' (→ %3F) and 404 the route. The browser bridge passes the same
  /// string straight to `fetch`, which parses it correctly — mirror that here.
  static Future<http.Response> _send(
    String path, {
    required String method,
    Map<String, dynamic>? body,
  }) async {
    final target = Uri.parse(path);
    final uri = _base.replace(
      path: target.path,
      query: target.hasQuery ? target.query : null,
    );
    final headers = <String, String>{
      if (_token != null) 'Authorization': 'Bearer $_token',
      if (body != null) 'Content-Type': 'application/json',
    };
    return switch (method) {
      'POST' => _client.post(
        uri,
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      ),
      'PATCH' => _client.patch(
        uri,
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      ),
      'DELETE' => _client.delete(uri, headers: headers),
      _ => _client.get(uri, headers: headers),
    }.timeout(const Duration(seconds: 8));
  }

  /// 204 No Content (e.g. DELETE) has an empty body; the browser bridge's
  /// `response.json().catch(() => ({}))` yields {} for it, so match that.
  static Map<String, dynamic> _decodeBody(http.Response response) {
    if (response.bodyBytes.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map<String, dynamic>) return decoded;
    // GET /users/ returns a bare array; wrap it so callers see one shape.
    return {'data': decoded};
  }

  static Map<String, dynamic>? _detail(http.Response response) {
    if (response.bodyBytes.isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    }
  }

  static String? _errorCode(http.Response response) {
    final detail = _detail(response);
    if (detail == null) return null;
    final nested = detail['detail'];
    if (nested is Map<String, dynamic> && nested['code'] is String) {
      return nested['code'] as String;
    }
    return null;
  }

  static String? _errorMessage(http.Response response) {
    final detail = _detail(response);
    if (detail == null) return null;
    final nested = detail['detail'];
    if (nested is String && nested.isNotEmpty) return nested;
    if (nested is Map<String, dynamic> && nested['message'] is String) {
      final message = nested['message'] as String;
      return message.isEmpty ? null : message;
    }
    return null;
  }
}
