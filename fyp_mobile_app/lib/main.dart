import 'package:shared_logic/shared_logic.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'application/services/service_locator.dart';
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
/// onboarding and the workspace. Holds the single [AppCubit] (role, preview,
/// saved, compare) plus the shared [AuthCubit], and passes both to the route
/// table so every screen and every guard reads the same state.
class SitewiseApp extends StatefulWidget {
  const SitewiseApp({super.key});

  @override
  State<SitewiseApp> createState() => _SitewiseAppState();
}

class _SitewiseAppState extends State<SitewiseApp> {
  final AppCubit appState = AppCubit();

  AuthCubit get _auth => ServiceLocator.authState;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AppCubit, AppState>(
      bloc: appState,
      builder: (ctx, _) => MaterialApp(
        title: 'Sitewise — F&B Location Intelligence',
        debugShowCheckedModeBanner: false,
        theme: sitewiseTheme(),
        // '/' is the startup decision point (verify session -> auth /
        // onboarding / role home). Nothing else is reachable without it.
        initialRoute: '/',
        onGenerateRoute: (settings) =>
            AppRoutes.onGenerateRoute(settings, appState, _auth),
      ),
    );
  }
}
