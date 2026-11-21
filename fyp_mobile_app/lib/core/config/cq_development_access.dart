import 'package:flutter/foundation.dart';
import 'dev_auth_bypass.dart';

/// Connects the existing test-bearer adapter only in an explicitly selected
/// private CQ lab. This does not mint credentials or authorize participation.
/// The backend still verifies the signed token, owner and fielding authority.
abstract final class CqDevelopmentAccess {
  static const _requested = bool.fromEnvironment('SITEWISE_ISOLATED_CQ_TEST');
  static const _testBase = String.fromEnvironment('CQ_TEST_BASE');
  static const _token = String.fromEnvironment('CQ_TEST_TOKEN');
  static const _apiBase = String.fromEnvironment('API_BASE_URL');

  static bool get enabled => permitted(
    debug: kDebugMode,
    bypass: devAuthBypassEnabled,
    requested: _requested,
    apiBase: _apiBase,
    testBase: _testBase,
    token: _token,
  );

  static String? get bearer => enabled ? _token : null;
  // A test credential is paired with its explicit private origin. Packaged
  // normal-app settings must never redirect it to the usual :8090 backend.
  static String? get apiBaseUrl => enabled ? _testBase : null;

  @visibleForTesting
  static bool permitted({
    required bool debug,
    required bool bypass,
    required bool requested,
    required String apiBase,
    required String testBase,
    required String token,
  }) {
    if (!debug || !bypass || !requested || token.trim().isEmpty) return false;
    final api = Uri.tryParse(apiBase), lab = Uri.tryParse(testBase);
    if (api == null || lab == null) return false;
    return api.scheme == 'http' &&
        const {'127.0.0.1', 'localhost', '::1'}.contains(api.host) &&
        api.port > 1023 &&
        // Existing application/DB ports are never selected as the private lab.
        !const {3080, 5432, 8000, 8090}.contains(api.port) &&
        api.userInfo.isEmpty &&
        api.query.isEmpty &&
        api.fragment.isEmpty &&
        (api.path.isEmpty || api.path == '/') &&
        api == lab;
  }
}
