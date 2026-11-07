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
}