/// VM implementation for component tests; no browser session is available.
abstract final class WebAuth {
  static bool get configured => false;
  static Map<String, dynamic>? get profile => null;
  static String get error => 'The local authentication API is not configured.';
  static Future<void> initialize() async {}
  static Future<void> google([
    String role = 'entrepreneur',
    bool remember = true,
  ]) async => throw StateError(error);
  static Future<void> password(
    String email,
    String password, [
    bool remember = true,
  ]) async => throw StateError(error);
  static Future<String> signup(
    String email,
    String password,
    String name,
    String role,
  ) async => throw StateError(error);
  static Future<void> complete() async => throw StateError(error);
  static Future<void> signout() async {}
  static Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async => throw StateError(error);
}
