import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'application/providers.dart';
import 'core/config/mobile_config.dart';
import 'core/routing/app_routes.dart';
import 'core/theme/sitewise_theme.dart';
import 'data/datasources/local/secure_session_local_storage.dart';

/// Guards against a second call (hot restart, tests, embedding) because
/// `Supabase.initialize()` is not idempotent.
bool _supabaseBootAttempted = false;

/// Boots the app only after the identity layer has had its chance to come up.
///
/// Supabase is initialised here and nowhere else, so exactly one process can
/// ever restore a session. A build without credentials starts anyway: the
/// repository then reports the service as unavailable and the startup gate
/// shows a retry screen instead of granting access. The difference now is that
/// the reason is recorded in [MobileConfig] and shown to the user instead of
/// being silently swallowed.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initializeSupabase();
  // Booleans and host names only — never key material.
  debugPrint(MobileConfig.statusLine);
  runApp(
    ProviderScope(
      overrides: sitewiseOverrides(),
      child: const SitewiseApp(),
    ),
  );
}

Future<void> _initializeSupabase() async {
  if (_supabaseBootAttempted) return;
  _supabaseBootAttempted = true;

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

  try {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseAnonKey,
      authOptions: FlutterAuthClientOptions(
        // Tokens live in the Keystore/Keychain, not in plaintext app storage.
        localStorage: SecureSessionLocalStorage(),
        // Persisted sessions are restored by AuthNotifier.start() ->
        // currentUser() -> _client.currentSession, then re-verified against
        // FastAPI /api/v1/auth/me before any workspace is opened.
        persistSession: true,
        autoRefreshToken: true,
        authFlowType: AuthFlowType.pkce,
        // Mobile registers no OAuth link handler, so accepting an auth
        // deep link here would be a promise this build cannot keep.
        detectSessionInUri: false,
      ),
    );
    MobileConfig.supabaseInitialized = true;
    MobileConfig.initializationError = null;
  } on Object {
    // Do not log the exception: Supabase errors can echo request data. The
    // repository still fails closed and the blocking view explains the state.
    MobileConfig.supabaseInitialized = false;
    MobileConfig.initializationError =
        'Supabase initialization failed. Check the project URL and '
        'publishable key.';
  }
}

/// Root widget. Authentication comes first: '/' is the startup gate, which
/// restores and *verifies* the session and only then chooses between Sign In,
/// onboarding and the workspace. The composition root [ProviderScope] lives in
/// `main()` and installs [sitewiseOverrides] — the overrides that point the
/// shared notifiers at the services [ServiceLocator] owns — so every screen
/// and every guard reads the same auth and app state from the widget tree
/// instead of receiving it as a constructor argument.
class SitewiseApp extends StatelessWidget {
  const SitewiseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sitewise — F&B Location Intelligence',
      debugShowCheckedModeBanner: false,
      theme: sitewiseTheme(),
      // '/' is the startup decision point (verify session -> auth /
      // onboarding / role home). Nothing else is reachable without it.
      initialRoute: '/',
      onGenerateRoute: AppRoutes.onGenerateRoute,
      onGenerateInitialRoutes: AppRoutes.generateInitialRoutes,
    );
  }
}
