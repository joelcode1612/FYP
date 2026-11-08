import 'package:provider/provider.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'application/services/service_locator.dart';
import 'application/state/app_view_model.dart';
import 'application/state/auth_view_model.dart';
import 'core/routing/app_routes.dart';
import 'core/theme/sitewise_theme.dart';
import 'data/datasources/local/secure_session_local_storage.dart';

/// Boots the app only after the identity layer has had its chance to come up.
///
/// Supabase is initialised here and nowhere else, so exactly one process can
/// ever restore a session. A build without credentials starts anyway: the
/// repository then reports the service as unavailable and the startup gate
/// shows a retry screen instead of granting access.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (AppConfig.hasSupabase) {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseAnonKey,
      authOptions: FlutterAuthClientOptions(
        // Tokens live in the Keystore/Keychain, not in plaintext app storage.
        localStorage: SecureSessionLocalStorage(),
        persistSession: true,
        autoRefreshToken: true,
        authFlowType: AuthFlowType.pkce,
        // Mobile registers no OAuth link handler, so accepting an auth
        // deep link here would be a promise this build cannot keep.
        detectSessionInUri: false,
      ),
    );
  }

  runApp(const SitewiseApp());
}

/// Root widget. Authentication comes first: '/' is the startup gate, which
/// restores and *verifies* the session and only then chooses between Sign In,
/// onboarding and the workspace. The single [AppViewModel] (role, preview,
/// saved, compare) and the shared [AuthViewModel] are registered here through
/// `MultiProvider`, so every screen and every guard reads the same state from
/// the widget tree instead of receiving it as a constructor argument.
class SitewiseApp extends StatelessWidget {
  const SitewiseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // `.value` for both: the composition root owns these instances (and
        // tests swap the auth one), so the provider scope must never dispose
        // them.
        ChangeNotifierProvider<AppViewModel>.value(
          value: ServiceLocator.appViewModel,
        ),
        ChangeNotifierProvider<AuthViewModel>.value(
          value: ServiceLocator.authViewModel,
        ),
      ],
      child: MaterialApp(
        title: 'Sitewise — F&B Location Intelligence',
        debugShowCheckedModeBanner: false,
        theme: sitewiseTheme(),
        // '/' is the startup decision point (verify session -> auth /
        // onboarding / role home). Nothing else is reachable without it.
        initialRoute: '/',
        onGenerateRoute: AppRoutes.onGenerateRoute,
      ),
    );
  }
}
