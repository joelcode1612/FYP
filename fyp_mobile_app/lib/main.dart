import 'package:shared_logic/shared_logic.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';

import 'core/routing/app_routes.dart';
import 'core/theme/sitewise_theme.dart';

/// **Assessment-only launch switch.**
///
/// When `true` the app boots straight into the entrepreneur **Assess** hub
/// (`/entrepreneur/assess`) and skips the normal startup gate
/// (onboarding → auth → role home). This is the assessment-only entry used
/// for demoing / testing the Option A assessment flow without signing in.
///
/// Flip to `false` to restore the normal startup path.
const bool kAssessmentOnly = true;

/// Route the app opens on in assessment-only mode.
const String kAssessmentOnlyRoute = '/entrepreneur/assess';

void main() {
  // ProviderScope hosts the Riverpod container for MVVM feature work
  // (M2 assessment). The pre-existing AppCubit below is unrelated and keeps
  // working through BlocBuilder. The assessment-only launch switch is kept.
  runApp(
    const ProviderScope(
      child: SitewiseApp(assessmentOnly: kAssessmentOnly),
    ),
  );
}

/// Root widget. Normally boots to the public landing page (`/`); role entry
/// happens through its Log In / Get Started actions. Holds the single
/// [AppCubit] (role, preview, saved, compare) and rebuilds the [MaterialApp]
/// when it changes.
///
/// When [assessmentOnly] is `true` the initial navigator stack is a single
/// assessment page — no landing, onboarding or auth gate is pushed.
class SitewiseApp extends StatefulWidget {
  /// Boot directly into the assessment flow instead of the normal startup
  /// gate. Defaults to `false` so existing call sites (and widget tests that
  /// pump `const SitewiseApp()`) keep the full startup path.
  final bool assessmentOnly;

  const SitewiseApp({super.key, this.assessmentOnly = false});

  @override
  State<SitewiseApp> createState() => _SitewiseAppState();
}

class _SitewiseAppState extends State<SitewiseApp> {
  final AppCubit appState = AppCubit();

  @override
  Widget build(BuildContext context) {
    final startRoute = widget.assessmentOnly ? kAssessmentOnlyRoute : '/';

    return BlocBuilder<AppCubit, AppState>(
      bloc: appState,
      builder: (ctx, _) => MaterialApp(
        title: 'Sitewise — F&B Location Intelligence',
        debugShowCheckedModeBanner: false,
        theme: sitewiseTheme(),
        // '/' is the startup decision point (mobile onboarding / auth / role
        // home; web redirects to the public landing at '/landing').
        initialRoute: startRoute,
        // Assessment-only mode builds a one-page stack directly. Without this
        // override Flutter would also generate every parent prefix of the
        // route ('/' → '/entrepreneur' → '.../assess'), which would run the
        // onboarding/auth gate first.
        onGenerateInitialRoutes: widget.assessmentOnly
            ? (route) => <Route<dynamic>>[
                  AppRoutes.onGenerateRoute(
                    RouteSettings(name: route),
                    appState,
                  )!,
                ]
            : null,
        onGenerateRoute: (settings) =>
            AppRoutes.onGenerateRoute(settings, appState),
      ),
    );
  }
}
