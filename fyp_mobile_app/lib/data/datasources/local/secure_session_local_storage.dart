import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Keystore/Keychain-backed session store handed to Supabase in place of its
/// default `SharedPreferences` persistence.
///
/// The Supabase session blob contains a live access token and refresh token;
/// `SharedPreferences` writes them to the app's data directory in plaintext,
/// readable by any rooted-device file dump and by Android `adb backup` on
/// some configurations. This adapter keeps the same values inside the
/// platform secure store (Android Keystore-backed encrypted preferences, iOS
/// Keychain) while satisfying [Supabase.initialize]'s `persistSession: false`
/// counterpart — see [SecureSessionLocalStorage.storageKey].
class SecureSessionLocalStorage extends LocalStorage {
  SecureSessionLocalStorage({FlutterSecureStorage? secure})
    : _secure = secure ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(),
            iOptions: IOSOptions(
              // A user-present authentication requirement would make session
              // restore fail silently at cold start; the protection required
              // here is encryption at rest, not a biometric gate.
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );

  static const String storageKey = 'sitewise.supabase.session';

  final FlutterSecureStorage _secure;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() async {
    final value = await _secure.read(key: storageKey);
    return value != null && value.isNotEmpty;
  }

  @override
  Future<String?> accessToken() => _secure.read(key: storageKey);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _secure.write(key: storageKey, value: persistSessionString);

  @override
  Future<void> removePersistedSession() =>
      _secure.delete(key: storageKey);
}
