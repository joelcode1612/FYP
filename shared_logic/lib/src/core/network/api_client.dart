import '../errors/app_failure.dart';

/// Bearer-aware transport port for the authenticated REST layer.
///
/// The contract carries no credentials: the platform implementation attaches
/// the Supabase access token (web: the `WebAuth` bridge — session token in the
/// browser, the request's `sitewise_token` cookie during SSR). Authorization
/// (role + `aal2`) is decided by the FastAPI backend, never here.
///
/// `ApiUserRepository` consumes this port; the demo-data repositories do not.
/// A non-2xx response throws, so callers surface their normal error state.
abstract class ApiClient {
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query});

  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body);

  Future<Map<String, dynamic>> patch(String path, Map<String, dynamic> body);

  Future<Map<String, dynamic>> delete(String path);

  /// Multipart form upload (used by the verification-evidence endpoint).
  /// [fields] are sent as plain form fields, [fileField] carries the bytes.
  Future<Map<String, dynamic>> uploadMultipart(
    String path, {
    required Map<String, String> fields,
    required String fileField,
    required String filename,
    required List<int> bytes,
    required String contentType,
  });

  /// Authenticated binary GET (used by the verification-document download
  /// endpoint); a non-2xx response throws with the backend's message.
  Future<List<int>> downloadBinary(String path);
}

/// Thrown when code calls the network while [AppConfig.usesDemoData].
class DemoModeFailure extends AppFailure {
  const DemoModeFailure() : super('Network is disabled in demo-data mode.');
}
