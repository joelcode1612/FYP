import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application/providers.dart';
import 'core/bootstrap/app_bootstrap.dart';
import 'core/bootstrap/startup_trace.dart';
import 'core/config/mobile_config.dart';
import 'core/routing/app_routes.dart';
import 'core/theme/sitewise_theme.dart';

/// Composition root.
///
/// Startup ordering was changed to remove a ~60 s blank screen on the
/// physical device. Previously `main()` awaited `Supabase.initialize()`
/// BEFORE `runApp`, so nothing was painted until the SDK (and the
/// Keystore-backed session store) finished. Device logcat for the 21:53 run
/// showed `Start proc` -> engine connected -> `Supabase init completed`
/// ~56 s later -> `Displayed ... +59s772ms`.
///
/// Now:
///   1. [AppBootstrap.start] kicks off the SINGLE Supabase initialization
///      without awaiting it, so it overlaps the first frame;
///   2. [runApp] mounts [AppStartGate] immediately — the branded splash is
///      visible within the first frame rather than after a minute;
///   3. [BootstrapAwareAuthService] (installed by [sitewiseOverrides]) makes
///      every session read await the same memoised bootstrap future, and
///      [AppStartGate] keeps the splash up until the shared [AuthNotifier]
///      has resolved the session.
///
/// No access is granted early: a workspace route still requires the FastAPI
/// `/api/v1/auth/me` verification inside `SupabaseAuthRepository`, and any
/// bootstrap/network failure fails closed to Sign In with a Retry action.
/// Supabase is still initialized exactly once and the persisted session is
/// still held in `SecureSessionLocalStorage` (Keystore/Keychain).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  StartupTrace.start();

  // Development-only first-frame marker. Registered before runApp so it fires
  // at the end of the first frame the app actually paints.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    StartupTrace.mark('first_frame');
    StartupTrace.report('first_frame');
  });

  // Fire-and-forget, memoised, exactly once. Starts before runApp so the
  // initialization overlaps frame production instead of following it.
  AppBootstrap.start();

  // Booleans and host names only — never key material. Runtime readiness is
  // logged again by AppBootstrap when the initialization completes.
  debugPrint(MobileConfig.statusLine);

  runApp(
    ProviderScope(overrides: sitewiseOverrides(), child: const SitewiseApp()),
  );
}

/// Root widget. Authentication comes first: '/' is the startup gate, which
/// restores and *verifies* the session and only then chooses between Sign In,
/// onboarding and the workspace. The composition root [ProviderScope] lives in
/// `main()` and installs [sitewiseOverrides] — the overrides that point the
/// shared notifiers at the services [ServiceLocator] owns — so every screen
/// and every guard reads the same auth and app state from the widget tree
/// instead of receiving it as a constructor argument.
class SitewiseApp extends ConsumerStatefulWidget {
  const SitewiseApp({super.key});

  @override
  ConsumerState<SitewiseApp> createState() => _SitewiseAppState();
}

class _SitewiseAppState extends ConsumerState<SitewiseApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(
        ref.read(assessmentViewModelProvider).pauseActive().catchError((
          Object error,
          StackTrace stack,
        ) {
          debugPrint('Questionnaire pause checkpoint failed.');
        }),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

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
