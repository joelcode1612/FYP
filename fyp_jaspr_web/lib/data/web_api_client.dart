import 'package:shared_logic/shared_logic.dart';

import 'auth_service.dart';

/// Bearer-aware [ApiClient] backed by the platform auth bridge ([WebAuth]).
///
/// The access token is attached by the bridge — the Supabase session in the
/// browser; the retired SSR implementation used a `sitewise_token` cookie.
/// This adapter never sees, stores or logs the token. Every call uses
/// same-origin `/api/*` on unified FastAPI, which enforces staff MFA (`aal2`).
class WebApiClient implements ApiClient {
  const WebApiClient();

  static String _withQuery(String path, Map<String, String>? query) {
    if (query == null || query.isEmpty) return path;
    final qs = query.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    return path.contains('?') ? '$path&$qs' : '$path?$qs';
  }

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) =>
      WebAuth.request(_withQuery(path, query));

  @override
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) =>
      WebAuth.request(path, method: 'POST', body: body);

  @override
  Future<Map<String, dynamic>> patch(String path, Map<String, dynamic> body) =>
      WebAuth.request(path, method: 'PATCH', body: body);

  @override
  Future<Map<String, dynamic>> delete(String path) =>
      WebAuth.request(path, method: 'DELETE');

  @override
  Future<Map<String, dynamic>> uploadMultipart(
    String path, {
    required Map<String, String> fields,
    required String fileField,
    required String filename,
    required List<int> bytes,
    required String contentType,
  }) => WebAuth.requestMultipart(
    path,
    fields: fields,
    fileField: fileField,
    filename: filename,
    bytes: bytes,
    contentType: contentType,
  );

  @override
  Future<List<int>> downloadBinary(String path) => WebAuth.download(path);
}