import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/datasources/local/secure_session_local_storage.dart';
import '../config/mobile_config.dart';
import 'startup_trace.dart';

/// One-shot Supabase bootstrap that is deliberately NOT awaited by `main`.
///
/// The previous composition root did `await Supabase.initialize(...)` before
/// `runApp`, so the device showed a blank surface for the whole ~56 s init.
/// Here `runApp` mounts [AppStartGate] immediately and the asynchronous
/// initialization runs concurrently with the first frame.
///
/// [ready] is a memoised future created exactly once. The startup gate, the
/// route guards, the auth screen and Retry all wait on that SAME future (via
/// `BootstrapAwareAuthService`), which prevents both a premature
/// `Supabase.instance` read and a second `Supabase.initialize()` call — the
/// SDK throws on a duplicate initialization.
///
/// Security is unchanged: the stored session still lives in
/// [SecureSessionLocalStorage] (Keystore/Keychain), no workspace route opens
/// before FastAPI `/api/v1/auth/me` has verified the profile, and any init
/// or network failure fails closed into the Sign In screen with a retry.
abstract final class AppBootstrap {
  static Future<void>? _pending;

  /// Idempotent. Never throws — failures are recorded in [MobileConfig] and
  /// surfaced as a typed configuration failure by the repository.
  static Future<void> get ready => _pending ??= _initialize();

  /// Kicks initialization off without waiting for it. Safe to call repeatedly
  /// (hot restart, tests, embedding): the memoised future is shared.
  static void start() => unawaited(ready);

  static Future<void> _initialize() async {
    StartupTrace.mark('bootstrap_start');
    try {
      if (!AppConfig.hasSupabase) {
        MobileConfig.initializationError =
            'Supabase credentials were not supplied to this build.';
        return;
      }
      // Refuse to ship a secret/service-role key in a client binary.
      if (MobileConfig.hasUnsafeKey) {
        MobileConfig.initializationError =
            'A secret key was supplied where the publishable key belongs.';
        return;
      }
      if (!MobileConfig.supabaseUrlLooksValid) {
        MobileConfig.initializationError =
            'SUPABASE_URL is not a valid HTTPS URL.';
        return;
      }
      MobileConfig.initializationError = null;

      // Measured separately from the SDK call: Keystore-backed session
      // storage is the other candidate for the original ~56 s stall.
      final storage = _TracedSessionStorage();
      await storage.initialize();

      await StartupTrace.measure(
        'supabase_initialize',
        () => Supabase.initialize(
          url: AppConfig.supabaseUrl,
          publishableKey: AppConfig.supabaseAnonKey,
          authOptions: FlutterAuthClientOptions(
            // Tokens stay in the Keystore/Keychain, never plaintext storage.
            localStorage: storage,
            // Persisted sessions are restored by AuthNotifier.start() ->
            // currentUser() -> _client.currentSession, then re-verified
            // against FastAPI /api/v1/auth/me before any workspace opens.
            persistSession: true,
            autoRefreshToken: true,
            authFlowType: AuthFlowType.pkce,
            // Mobile registers no OAuth link handler, so accepting an auth
            // deep link here would be a promise this build cannot keep.
            detectSessionInUri: false,
          ),
        ),
      );
      MobileConfig.supabaseInitialized = true;
      MobileConfig.initializationError = null;
    } on Object {
      // Do NOT log the exception: Supabase errors can echo request data. The
      // repository still fails closed and the Sign In screen explains why.
      MobileConfig.supabaseInitialized = false;
      MobileConfig.initializationError =
          'Supabase initialization failed. Check the project URL and '
          'publishable key.';
    } finally {
      StartupTrace.mark('bootstrap_end');
      // Booleans and host names only — never key material. Logged here (not
      // in main) because the runtime init flag is only meaningful now.
      debugPrint(MobileConfig.statusLine);
      StartupTrace.report('bootstrap');
    }
  }
}

/// Delegates every operation to [SecureSessionLocalStorage] and adds timing
/// marks around the two cold-start storage operations. No persistence
/// behaviour is changed.
class _TracedSessionStorage extends SecureSessionLocalStorage {
  @override
  Future<void> initialize() async {
    StartupTrace.mark('secure_storage_start');
    try {
      await super.initialize();
    } finally {
      StartupTrace.mark('secure_storage_end');
    }
  }

  @override
  Future<bool> hasAccessToken() async {
    StartupTrace.mark('secure_session_read_start');
    try {
      return await super.hasAccessToken();
    } finally {
      StartupTrace.mark('secure_session_read_end');
    }
  }
}
