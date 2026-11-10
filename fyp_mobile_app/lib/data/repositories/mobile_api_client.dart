import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_logic/shared_logic.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/mobile_endpoints.dart';

/// Bearer-aware [ApiClient] for the Flutter app, implementing the shared
/// transport port with `dart:io` (which is why it lives HERE and not in
/// `shared_logic` — the shared package must stay browser-safe).
///
/// The Supabase access token is attached per request from the persisted
/// session; the adapter never stores, logs or refreshes credentials itself.
/// Authorization is decided by the FastAPI backend exactly as on web.
///
/// Used only when the composition root wires the live repositories (see
/// `application/providers.dart`); demo-data builds never construct it.
class MobileApiClient implements ApiClient {
  final String? Function()? _tokenOverride;

  /// [bearer] exists for tests; production reads the Supabase session.
  MobileApiClient({String? Function()? bearer}) : _tokenOverride = bearer;

  static final HttpClient _http = HttpClient();

  String? _bearer() {
    if (_tokenOverride != null) return _tokenOverride();
    try {
      return Supabase.instance.client.auth.currentSession?.accessToken;
    } on Object {
      // Supabase.initialize() never ran: fail closed downstream (no header).
      return null;
    }
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = MobileEndpoints.apiBaseUrl;
    return Uri.parse('$base$path').replace(
      queryParameters:
          (query == null || query.isEmpty) ? null : query,
    );
  }

  Future<Map<String, dynamic>> _send(
    String method,
    Uri uri, [
    Map<String, dynamic>? body,
  ]) async {
    final token = _bearer();
    if (token == null) {
      throw const NetworkFailure('No authenticated session is available.');
    }
    final request = await _http.openUrl(method, uri)
      ..headers.contentType = ContentType.json
      ..headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (body != null) {
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(
      const Duration(seconds: 15),
    );
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // FastAPI error shape: {detail: string} or {detail: {code, message}}.
      // Messages are the backend's own user-facing sentences; no stack or
      // header detail is carried through.
      String message = 'The data service could not complete this request.';
      try {
        final decoded = jsonDecode(text);
        final detail = decoded is Map ? decoded['detail'] : null;
        if (detail is String && detail.isNotEmpty) {
          message = detail;
        } else if (detail is Map && detail['message'] is String) {
          message = detail['message'] as String;
        }
      } on Object {
        // Non-JSON error body: the generic message stands.
      }
      throw NetworkFailure(message);
    }
    if (text.isEmpty) return const {}; // 204-style empty success
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    // Bare arrays are wrapped the same way the web bridge wraps them, so
    // every repository sees one response shape on both platforms.
    return {'data': decoded};
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) => _send('GET', _uri(path, query));

  @override
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) =>
      _send('POST', _uri(path), body);

  @override
  Future<Map<String, dynamic>> patch(String path, Map<String, dynamic> body) =>
      _send('PATCH', _uri(path), body);

  @override
  Future<Map<String, dynamic>> delete(String path) =>
      _send('DELETE', _uri(path));

  @override
  Future<Map<String, dynamic>> uploadMultipart(
    String path, {
    required Map<String, String> fields,
    required String fileField,
    required String filename,
    required List<int> bytes,
    required String contentType,
  }) async {
    final token = _bearer();
    if (token == null) {
      throw const NetworkFailure('No authenticated session is available.');
    }
    final request =
        http.MultipartRequest('POST', _uri(path))
          ..fields.addAll(fields)
          ..files.add(
            http.MultipartFile.fromBytes(
              fileField,
              bytes,
              filename: filename,
            ),
          )
          ..headers[HttpHeaders.authorizationHeader] = 'Bearer $token';
    final streamed = await request.send().timeout(const Duration(seconds: 30));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NetworkFailure(_failureMessage(response.body));
    }
    return _decodePayload(response.body);
  }

  @override
  Future<List<int>> downloadBinary(String path) async {
    final token = _bearer();
    if (token == null) {
      throw const NetworkFailure('No authenticated session is available.');
    }
    final response = await _http
        .openUrl('GET', _uri(path))
        .then((r) async {
          r.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
          return r.close();
        })
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final text = await response.transform(utf8.decoder).join();
      throw NetworkFailure(_failureMessage(text));
    }
    return await response.fold<List<int>>(
      <int>[],
      (acc, chunk) => acc..addAll(chunk),
    );
  }

  /// FastAPI error shape: `{detail: string}` or `{detail: {code, message}}`.
  String _failureMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      final detail = decoded is Map ? decoded['detail'] : null;
      if (detail is String && detail.isNotEmpty) return detail;
      if (detail is Map && detail['message'] is String) {
        return detail['message'] as String;
      }
    } on Object {
      // Non-JSON error body: the generic message stands.
    }
    return 'The data service could not complete this request.';
  }

  Map<String, dynamic> _decodePayload(String text) {
    if (text.isEmpty) return const {};
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    return {'data': decoded};
  }
}
