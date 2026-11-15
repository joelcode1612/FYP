import 'package:shared_logic/shared_logic.dart';

import 'auth_service.dart';

/// Bearer-aware [ApiClient] backed by the platform auth bridge ([WebAuth]).
///
/// The access token is attached by the bridge — the Supabase session in the
/// browser, the request's `sitewise_token` cookie during SSR — so this adapter
/// never sees, stores or logs it. Every call is same-origin (`/api/*`), proxied
/// to FastAPI, which enforces administrator + `aal2`; the client only transports.
class WebApiClient implements ApiClient {
  const WebApiClient();

  Future<Map<String, dynamic>> _request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    final Map<String, dynamic> result;
    try {
      result = await WebAuth.requestDetailed(path, method: method, body: body);
    } catch (_) {
      throw apiOperationFailure(mutation: method != 'GET');
    }
    if (result['ok'] != true) {
      throw apiOperationFailure(
        status: result['status'] as int?,
        code: result['code'] as String?,
        message: result['message'] as String?,
        mutation: method != 'GET',
      );
    }
    final payload = result['body'];
    if (payload is! Map<String, dynamic>) {
      throw const ResponseFormatFailure();
    }
    return payload;
  }

  @override
  Future<Map<String, dynamic>> put(String path, Map<String, dynamic> body) =>
      _request(path, method: 'PUT', body: body);

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
      _request(_withQuery(path, query));

  @override
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) =>
      _request(path, method: 'POST', body: body);

  @override
  Future<Map<String, dynamic>> patch(String path, Map<String, dynamic> body) =>
      _request(path, method: 'PATCH', body: body);

  @override
  Future<Map<String, dynamic>> delete(String path) =>
      _request(path, method: 'DELETE');

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
