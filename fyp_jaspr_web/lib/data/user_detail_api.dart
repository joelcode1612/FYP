import 'auth_service.dart';

/// Transport for the Admin user-detail screen's two calls.
///
/// `/api/v1/users/{id}` is read and written here rather than through
/// `ApiUserRepository` because the screen has to tell "no such account" (404)
/// apart from a refused write (the administrator + `aal2` 403) and a service
/// failure, while the `ApiClient` port answers all three by throwing without a
/// status. `WebAuth.requestDetailed` returns the outcome as data, so this file
/// only fixes the path and the single writable field.
///
/// A role change cannot be expressed through this signature on purpose: the
/// backend refuses any role payload (`role_change_not_supported`) and the
/// screen shows roles read-only.
abstract final class UserDetailApi {
  static String _path(String userId) =>
      '/api/v1/users/${Uri.encodeComponent(userId.trim())}';

  /// The authoritative profile row as `{ok, status, body}`, where `body` is the
  /// backend's `_profile_payload` map.
  static Future<Map<String, dynamic>> read(String userId) =>
      WebAuth.requestDetailed(_path(userId));

  /// The account-status write — the only change this screen may submit.
  static Future<Map<String, dynamic>> updateStatus(
    String userId,
    String accountStatus,
  ) => WebAuth.requestDetailed(
    _path(userId),
    method: 'PATCH',
    body: {'account_status': accountStatus},
  );
}
